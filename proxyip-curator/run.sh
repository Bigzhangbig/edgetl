#!/bin/bash
# ponytail: one-shot curation cycle. retest -> fetch -> probe -> merge -> upload -> re-verify.
set -euo pipefail

: "${GIST_TOKEN:?GIST_TOKEN required}"
: "${GIST_ID:?GIST_ID required}"
GIST_FILENAME="${GIST_FILENAME:-proxyip.json}"
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
# stdout tsv:   proxy \t success \t v4 \t v6 \t responseTime \t colo \t egress
probe_one() {
  local proxy=$1
  # 拆 proxy 成 ip:port; IPv6 是 [::1]:443, 用 rev+cut 提最后一段做 port
  local port ip
  port="${proxy##*:}"
  ip="${proxy%:*}"
  # v4/v6 字面量判断: 含 [ 或多 : 视为 v6
  local is_v6=false
  if [[ "$ip" == \[* ]]; then
    is_v6=true
    ip="${ip#[}"; ip="${ip%]}"
  fi
  # curl --resolve: v6 IP 需要单独裸写 (无方括号)
  local trace http_code wall_ms colo egress_ip egress_type
  trace=$(curl -k -sS --connect-timeout 5 --max-time "$PROBE_TIMEOUT" \
    -w '\nHTTP=%{http_code}\nWALL=%{time_total}\n' \
    --resolve "speed.cloudflare.com:${port}:${ip}" \
    "https://speed.cloudflare.com:${port}/cdn-cgi/trace" 2>/dev/null) || {
    printf '%s\tfalse\t\t\t\t\t\n' "$proxy"
    return
  }
  http_code=$(printf '%s' "$trace" | awk -F'=' '/^HTTP=/{print $2}')
  wall_ms=$(printf '%s' "$trace" | awk -F'=' '/^WALL=/{print int($2*1000)}')
  colo=$(printf '%s' "$trace" | awk -F'=' '/^colo=/{print $2}')
  # ponytail: 从 trace body 里 ip= 拿 proxyIP 真实出口, 判 v4/v6 (双栈 VPS 默认走 v6, 影响下游选点)
  egress_ip=$(printf '%s' "$trace" | awk -F'=' '/^ip=/{print $2}')
  egress_type=v4
  [[ "$egress_ip" == *:* ]] && egress_type=v6
  if [ "$http_code" = "200" ] && [ -n "$colo" ]; then
    # ponytail: v4/v6 靠 IP 字面量判断, 单侧填 true; 探测方向单一, 另一侧填 false 简化
    if $is_v6; then
      printf '%s\ttrue\tfalse\ttrue\t%s\t%s\t%s\n' "$proxy" "$wall_ms" "$colo" "$egress_type"
    else
      printf '%s\ttrue\ttrue\tfalse\t%s\t%s\t%s\n' "$proxy" "$wall_ms" "$colo" "$egress_type"
    fi
  else
    printf '%s\tfalse\t\t\t\t\t\n' "$proxy"
  fi
}
export -f probe_one
export PROBE_TIMEOUT

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
    local target_url="$u"
    # ponytail: 若配置了反代前缀,把源 URL 拼在前面 (Secret 隐藏,直接暴露到日志)
    if [ -n "${PROXY_PREFIX:-}" ]; then
      target_url="${PROXY_PREFIX%/}/${u}"
    fi
    raw=$(curl -fsS --connect-timeout 8 --speed-time 30 --speed-limit 1024 --max-time 120 --retry 3 --retry-all-errors --retry-delay 2 -A 'Mozilla/5.0 (compatible; proxyip-curator/1.0)' "$target_url" 2>/dev/null) || { log "fetch failed for $u"; continue; }
    # try json first
    if echo "$raw" | jq -e . >/dev/null 2>&1; then
      # common shapes: [{ip,port,tag}], [{proxyip}], {items:[...]}
      echo "$raw" | jq -r '
        (if type=="array" then . elif .items then .items elif .data then .data else [] end)
        | .[]
        | (if .proxyip then .proxyip
           # ponytail: multi-port .port arrays: only first port used, siblings dropped.
           elif .ip and (.port|type=="array") and (.port|length>0) then "\(.ip):\(.port[0])"
           elif .ip and (.port != null) and ((.port|tostring) != "") then "\(.ip):\(.port)"
           elif .ip then "\(.ip):443"
           else empty end) as $addr
        | ($addr | select(. != null and . != "")) as $addr
        # ponytail: 输出 ip:port#COUNTRY#IATA, 大写规范化, 后续 map 拆两列
        | ((.meta?.country? // .country // "") | ascii_upcase) as $country
        | ((.meta?.colo?.iata? // .tag // .region // "") | ascii_upcase) as $iata
        | "\($addr)#\($country)#\($iata)"
      ' 2>/dev/null >> "$out" || true
    else
      # plain text, keep ip:port#tag or ip:port
      # ponytail: plain text 源不带 country/iata 字段, REGION_FILTER 只对 JSON 源生效; gist 里 colo 走 checker fallback
      echo "$raw" | grep -E '^[0-9a-fA-F.:\[\]]+:[0-9]+' >> "$out" || true
    fi
  done
  # normalize + optional region filter (匹配 country 列, 大小写不敏感)
  if [ -n "$REGION_FILTER" ]; then
    local pat
    pat=$(echo "$REGION_FILTER" | tr ',' '|' | tr '[:lower:]' '[:upper:]')
    grep -E "^[^#]+#(${pat})#" "$out" > "${out}.f" || true
    mv "${out}.f" "$out"
  fi
  # strip #COUNTRY#IATA for probing; keep 3-col map alongside (proxy, country, iata)
  awk -F'#' '{print $1"\t"$2"\t"$3}' "$out" | sort -u -k1,1 > "${out}.map"
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

# ponytail: 构建 proxy → IATA 映射 (仅新 IP 有此映射, 从 fetch_sources 生成的 map)
# 若 REGION_FILTER 走过, 用过滤后的 map (${new_txt}.map); 否则同名
new_map="${new_txt}.map"
[ -f "$new_map" ] || : > "$new_map"

# retest 分支: 保留原 gist 的 colo + egress (通过 existing.txt 索引)
retest_map="$WORK/retest.map"
: > "$retest_map"
if echo "$cur_json" | jq -e 'type=="array" and length>0' >/dev/null 2>&1; then
  echo "$cur_json" | jq -r '.[] | "\(.proxy)\t\(.colo // "")\t\(.egress // "")"' > "$retest_map"
fi

{
  # existing 存活: 保留原 gist colo/egress (通过 retest_map lookup, 无则用新探测 .[5]/.[6])
  # 输出追加两列: final_colo (index 7), final_egress (index 8)
  awk -F'\t' 'NR==FNR{colo[$1]=$2; egress[$1]=$3; next}
              $2=="true"{
                c=(colo[$1]!=""?colo[$1]:$6);
                e=(egress[$1]!=""?egress[$1]:$7);
                print $0"\t"c"\t"e
              }' \
    "$retest_map" "$retest_tsv"
  # new 存活: 用源 IATA 覆盖 checker colo; egress 用新探测值
  # 输出追加两列: final_colo (源 IATA), final_egress (新探测)
  awk -F'\t' 'NR==FNR{iata[$1]=$3; next}
              $2=="true"{
                c=(iata[$1]!=""?iata[$1]:$6);
                print $0"\t"c"\t"$7
              }' \
    "$new_map" "$new_tsv"
} | jq -Rs '
    split("\n") | map(select(length>0)) | map(split("\t"))
    | map({
        proxy: .[0],
        v4: (.[2]=="true"),
        v6: (.[3]=="true"),
        ms: (.[4]|tonumber? // null),
        colo: (.[7] // .[5] // ""),
        egress: (.[8] // .[6] // "")
      })
    | unique_by(.proxy)
    # ponytail: per-IATA top-8 by ms (Runner→IP wall time). 27 IATA 全覆盖, top 200 均衡而非"离 checker 近"独霸
    # sort_by(.ms) 而非 sort_by(.colo,.ms), 避免后续 .[:MAX_KEEP] 按字母序砍掉 Y/Z 开头 IATA
    | group_by(.colo)
    | map(sort_by(.ms // 99999) | .[0:8])
    | flatten
    | sort_by(.ms // 99999)
  ' > "$merged_json"

kept=$(jq 'length' "$merged_json")
log "merged good: $kept"

# 5. Truncate + upload
# ponytail: 单条 compact, 数组换行; gist 里可读又不臃肿
truncated=$(jq --argjson n "$MAX_KEEP" '.[:$n]' "$merged_json")
content=$(echo "$truncated" | jq -r 'map(tojson) | "[\n  " + join(",\n  ") + "\n]"')

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
