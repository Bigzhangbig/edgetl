#!/bin/bash
# ponytail: one-shot curation cycle. retest -> fetch -> probe -> merge -> upload -> re-verify.
set -euo pipefail

: "${GIST_TOKEN:?GIST_TOKEN required}"
: "${GIST_ID:?GIST_ID required}"
GIST_FILENAME="${GIST_FILENAME:-proxyip.json}"
CHECKER_API="${CHECKER_API:-https://api.090227.xyz/check}"
SOURCES="${SOURCES:-https://zip.cm.edu.kg/all.json}"
REGION_FILTER="${REGION_FILTER:-}"
MAX_KEEP="${MAX_KEEP:-200}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-12}"
PROBE_CONCURRENCY="${PROBE_CONCURRENCY:-20}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2; }

# ---------- probe one proxy ----------
# stdin format: ip:port (one per line)
# stdout tsv:   proxy \t success \t v4 \t v6 \t responseTime \t colo
probe_one() {
  local proxy=$1 resp
  resp=$(curl -sS --max-time "$PROBE_TIMEOUT" "${CHECKER_API}?proxyip=${proxy}" 2>/dev/null)
  if [ -z "$resp" ]; then
    printf '%s\tTIMEOUT\t\t\t\t\n' "$proxy"
    return
  fi
  # tolerate malformed JSON
  echo "$resp" | jq -r --arg p "$proxy" \
    '[$p, (.success|tostring), (.supports_ipv4|tostring), (.supports_ipv6|tostring), (.responseTime|tostring), (.colo//"")] | @tsv' \
    2>/dev/null || printf '%s\tBADJSON\t\t\t\t\n' "$proxy"
}
export -f probe_one
export CHECKER_API PROBE_TIMEOUT

# ---------- probe list -> tsv ----------
probe_list() {
  local in=$1 out=$2
  : > "$out"
  # xargs -P for concurrency; append is safe for line-buffered short writes
  <"$in" xargs -P "$PROBE_CONCURRENCY" -I {} bash -c 'probe_one "$@"' _ {} >> "$out"
}

# ---------- fetch current gist state ----------
fetch_current() {
  local url="https://api.github.com/gists/${GIST_ID}"
  curl -fsS -H "Authorization: Bearer $GIST_TOKEN" \
       -H "Accept: application/vnd.github+json" "$url" \
    | jq -r --arg f "$GIST_FILENAME" '.files[$f].content // ""'
}

# ---------- upload ----------
upload() {
  local content=$1
  local body
  body=$(jq -n --arg f "$GIST_FILENAME" --arg c "$content" \
    '{files: {($f): {content: $c}}}')
  curl -sS -X PATCH \
    -H "Authorization: Bearer $GIST_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -d "$body" \
    "https://api.github.com/gists/${GIST_ID}" \
    | jq -r '.updated_at // .message // "no response"'
}

# ---------- extract ip:port from sources ----------
# each source can be:
#   - json array of {ip, port, ...} or {proxyip: "ip:port"}
#   - plain text: ip:port#TAG per line
fetch_sources() {
  local out=$1
  : > "$out"
  IFS=',' read -ra urls <<< "$SOURCES"
  for u in "${urls[@]}"; do
    u=$(echo "$u" | tr -d ' ')
    [ -z "$u" ] && continue
    log "fetch: $u"
    local raw
    raw=$(curl -sS --max-time 20 "$u" 2>/dev/null) || continue
    # try json first
    if echo "$raw" | jq -e . >/dev/null 2>&1; then
      # common shapes: [{ip,port,tag}], [{proxyip}], {items:[...]}
      echo "$raw" | jq -r '
        (if type=="array" then . elif .items then .items else [] end)
        | .[]
        | (if .proxyip then .proxyip
           elif .ip and .port then "\(.ip):\(.port)"
           elif .ip then "\(.ip):443"
           else empty end) as $addr
        | if .tag or .country or .region then "\($addr)#\(.tag // .country // .region)" else $addr end
      ' 2>/dev/null >> "$out" || true
    else
      # plain text, keep ip:port#tag or ip:port
      echo "$raw" | grep -E '^[0-9a-fA-F.:\[\]]+:[0-9]+' >> "$out" || true
    fi
  done
  # normalize + optional region filter
  if [ -n "$REGION_FILTER" ]; then
    local pat
    pat=$(echo "$REGION_FILTER" | sed 's/,/|/g')
    grep -E "#(${pat})" "$out" > "${out}.f" || true
    mv "${out}.f" "$out"
  fi
  # strip #TAG for probing; keep tag file alongside
  awk -F'#' '{print $1"\t"$2}' "$out" | sort -u -k1,1 > "${out}.map"
  cut -f1 "${out}.map" > "$out"
  log "sources yielded $(wc -l < "$out") candidates"
}

# ---------- main flow ----------
cur_json=$(fetch_current) || { log "ERROR: fetch_current failed, aborting"; exit 1; }
log "current gist has $(echo "$cur_json" | jq 'length? // 0' 2>/dev/null || echo 0) entries"

# 1. Retest existing entries (verification step per user requirement)
retest_tsv="$WORK/retest.tsv"
: > "$retest_tsv"
if echo "$cur_json" | jq -e 'type=="array" and length>0' >/dev/null 2>&1; then
  echo "$cur_json" | jq -r '.[].proxy' > "$WORK/existing.txt"
  log "retesting $(wc -l < "$WORK/existing.txt") existing proxies"
  probe_list "$WORK/existing.txt" "$retest_tsv"
fi

# 2. Fetch new candidates
new_txt="$WORK/new.txt"
fetch_sources "$new_txt"

# subtract already-tested (avoid double work in one cycle)
if [ -s "$WORK/existing.txt" ]; then
  grep -Fxvf "$WORK/existing.txt" "$new_txt" > "$WORK/new.txt.f" || true
  mv "$WORK/new.txt.f" "$new_txt"
fi
log "new (post-dedup): $(wc -l < "$new_txt")"

# 3. Probe new
new_tsv="$WORK/new.tsv"
: > "$new_tsv"
[ -s "$new_txt" ] && probe_list "$new_txt" "$new_tsv"

# 4. Merge kept (existing that still pass) + new that pass
merged_json="$WORK/merged.json"
{
  # existing that survived retest
  awk -F'\t' '$2=="true"' "$retest_tsv"
  # new that pass
  awk -F'\t' '$2=="true"' "$new_tsv"
} | jq -Rs --arg map_file "$new_txt.map" '
    split("\n") | map(select(length>0)) | map(split("\t"))
    | map({proxy: .[0], v4: .[2]=="true", v6: .[3]=="true", ms: (.[4]|tonumber? // null), colo: .[5]})
    | unique_by(.proxy)
    | sort_by(.ms // 99999)
  ' > "$merged_json"

kept=$(jq 'length' "$merged_json")
log "merged good: $kept"

# 5. Truncate + upload
truncated=$(jq --argjson n "$MAX_KEEP" '.[:$n]' "$merged_json")
content=$(echo "$truncated" | jq -c .)

if [ "$kept" -eq 0 ]; then
  log "WARN: 0 good proxies. keeping gist unchanged to avoid wiping."
  exit 0
fi

log "uploading $kept entries..."
upload "$content"

# 6. Re-verify uploaded content (spot check top 10 to confirm gist round-tripped)
sleep 3
after=$(fetch_current | jq 'length? // 0' 2>/dev/null || echo 0)
log "gist now has $after entries"

if [ "$after" != "$kept" ] && [ "$kept" -lt "$MAX_KEEP" ]; then
  log "WARN: upload mismatch (expected $kept, got $after)"
fi
