#!/usr/bin/env bash

# Address policy shared by the curator's source and legacy-Gist handling.
# A proxy is eligible for the IPv4 pool only when its literal address and port
# are both valid.  Metadata such as v4=true is intentionally not trusted.

is_valid_port() {
  local port=${1:-}
  [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
  local number=$((10#$port))
  (( number >= 1 && number <= 65535 ))
}

is_ipv4_literal() {
  local ip=${1:-}
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

  local octet
  local -a octets
  IFS='.' read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do
    local number=$((10#$octet))
    (( number >= 0 && number <= 255 )) || return 1
  done
}

format_proxy_address() {
  local address=${1:-}
  local port=${2:-443}
  if [[ "$address" == \[*\] ]]; then
    address=${address:1:${#address}-2}
  fi
  if [[ "$address" == *:* ]]; then
    printf '[%s]:%s\n' "$address" "$port"
  else
    printf '%s:%s\n' "$address" "$port"
  fi
}

normalize_proxy_value() {
  local raw=${1:-}
  raw=${raw%%#*}
  raw=$(printf '%s' "$raw" | tr -d '[:space:]')
  [ -n "$raw" ] || return 1

  if [[ "$raw" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
    local ip=${BASH_REMATCH[1]} port=${BASH_REMATCH[2]}
    is_valid_port "$port" || return 1
    format_proxy_address "$ip" "$port"
  elif [[ "$raw" =~ ^\[([^]]+)\]$ ]]; then
    format_proxy_address "${BASH_REMATCH[1]}" 443
  elif [[ "$raw" =~ ^([^:]+):([0-9]+)$ ]]; then
    local ip=${BASH_REMATCH[1]} port=${BASH_REMATCH[2]}
    is_valid_port "$port" || return 1
    format_proxy_address "$ip" "$port"
  elif [[ "$raw" == *:* ]]; then
    # An unbracketed IPv6 literal has no unambiguous port boundary; treat it
    # as an address with the default port and bracket it before use.
    format_proxy_address "$raw" 443
  else
    format_proxy_address "$raw" 443
  fi
}

is_ipv4_proxy() {
  local raw=${1:-}
  raw=${raw%%#*}
  raw=$(printf '%s' "$raw" | tr -d '[:space:]')
  [[ "$raw" =~ ^([^:]+):([0-9]+)$ ]] || return 1
  local ip=${BASH_REMATCH[1]} port=${BASH_REMATCH[2]}
  is_ipv4_literal "$ip" || return 1
  is_valid_port "$port"
}

normalize_json_candidates() {
  local source_file=${1:?JSON source file required}
  jq -r '
    def entries:
      if type == "array" then .
      elif .items then .items
      elif .data then .data
      elif .list then .list
      else [] end;
    def valid_ipv4($ip):
      ($ip | test("^([0-9]{1,3}\\.){3}[0-9]{1,3}$"))
      and (($ip | split(".") | all(.[]; (tonumber >= 0 and tonumber <= 255))));
    def valid_port($port):
      (($port | tostring | test("^[0-9]{1,5}$"))
       and (($port | tonumber) >= 1 and ($port | tonumber) <= 65535));
    entries[]
    | ((.meta?.country? // .country // "") | tostring | ascii_upcase) as $country
    | ((.meta?.colo?.iata? // .tag // .region // "") | tostring | ascii_upcase) as $iata
    | if .proxyip? != null then
        [(.proxyip | tostring), null, $country, $iata]
      elif .ip? != null then
        (if (.port | type) == "array" then .port[]
         elif .port == null or (.port | tostring) == "" then 443
         else .port end) as $port
        | [(.ip | tostring), $port, $country, $iata]
      else empty end
    | . as $row
    | ($row[0] | tostring) as $raw
    | if $row[1] != null and ($row[1] | tostring) != "" then
        if valid_ipv4($raw) and valid_port($row[1]) then
          "\($raw):\($row[1]|tonumber)\t\($row[2])\t\($row[3])"
        else empty end
      elif ($raw | test("^([0-9]{1,3}\\.){3}[0-9]{1,3}:[0-9]{1,5}$")) then
        ($raw | capture("^(?<ip>([0-9]{1,3}\\.){3}[0-9]{1,3}):(?<port>[0-9]{1,5})$")) as $parts
        | if valid_ipv4($parts.ip) and valid_port($parts.port) then
            "\($parts.ip):\($parts.port|tonumber)\t\($row[2])\t\($row[3])"
          else empty end
      elif valid_ipv4($raw) then
        "\($raw):443\t\($row[2])\t\($row[3])"
      else empty end
  ' "$source_file" 2>/dev/null | sort -u
}

normalize_text_candidates() {
  local source_file=${1:?text source file required}
  awk -F'#' '
    BEGIN { OFS="\t" }
    {
      address=$1
      gsub(/[[:space:]]/, "", address)
      country=toupper($2)
      iata=toupper($3)
      ip=address
      port=443
      if (address ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$/) {
        split(address, parts, ":")
        ip=parts[1]
        port=parts[2]
      } else if (address !~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/) {
        next
      }
      if (ip !~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/ || port !~ /^[0-9]{1,5}$/ || port < 1 || port > 65535) next
      split(ip, octets, /\./)
      for (i=1; i<=4; i++) if (octets[i] > 255) next
      print ip ":" port, country, iata
    }
  ' "$source_file" | sort -u
}

select_probe_candidates() {
  local candidate_file=${1:?candidate file required}
  local map_file=${2:?candidate map required}
  local max_candidates=${3:?candidate cap required}
  local output_file=${4:?candidate output required}
  local count iata_count remaining

  count=$(wc -l < "$candidate_file")
  if [ "$count" -le "$max_candidates" ]; then
    [ "$candidate_file" = "$output_file" ] || cp "$candidate_file" "$output_file"
    return 0
  fi

  local cap_file="${output_file}.cap"
  local iata_file="${output_file}.iata"
  awk -F'\t' '!seen[$3]++ {print $1}' "$map_file" > "$iata_file"
  iata_count=$(wc -l < "$iata_file")
  if [ "$iata_count" -ge "$max_candidates" ]; then
    head -n "$max_candidates" "$iata_file" > "$cap_file"
  else
    cp "$iata_file" "$cap_file"
    remaining=$((max_candidates - iata_count))
    local remainder_file="${output_file}.remaining"
    grep -Fvx -f "$cap_file" "$candidate_file" | shuf -n "$remaining" > "$remainder_file" || true
    cat "$remainder_file" >> "$cap_file"
  fi
  mv "$cap_file" "$output_file"
}

filter_gist_ipv4_json() {
  local content=${1:-}
  printf '%s' "$content" \
    | jq -c 'if type == "array" then .[] else empty end' 2>/dev/null \
    | while IFS= read -r item; do
        local proxy
        proxy=$(printf '%s' "$item" | jq -r '.proxy // empty')
        if is_ipv4_proxy "$proxy"; then
          # egress has no source marker in the legacy schema; force a fresh
          # trusted-checker result instead of carrying stale metadata forward.
          printf '%s' "$item" | jq -c 'del(.egress)'
        fi
      done \
    | jq -s -c '.'
}

classify_checker_egress() {
  local response=${1:-}
  local success egress_ip
  success=$(printf '%s' "$response" | jq -r '.success // false' 2>/dev/null || true)
  [ "$success" = "true" ] || return 0
  egress_ip=$(printf '%s' "$response" | jq -r 'if (.egress_ip | type) == "string" then .egress_ip else empty end' 2>/dev/null || true)
  if is_ipv4_literal "$egress_ip"; then
    printf 'v4\n'
  elif [[ "$egress_ip" == *:* && "$egress_ip" =~ ^[0-9A-Fa-f:.]+$ ]]; then
    printf 'v6\n'
  fi
}
