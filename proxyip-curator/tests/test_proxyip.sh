#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
LIB="$ROOT/proxyip-curator/lib.sh"
FIXTURES="$ROOT/proxyip-curator/tests/fixtures"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected=$1 actual=$2 label=$3
  [ "$expected" = "$actual" ] || fail "$label (expected=$expected, actual=$actual)"
}

if [ ! -f "$LIB" ]; then
  fail "expected proxyip-curator/lib.sh to provide the normalization policy"
fi

# shellcheck source=/dev/null
. "$LIB"

assert_eq "true" "$(is_ipv4_proxy '203.0.113.10:443#US' && printf true || printf false)" "IPv4 with tag"
assert_eq "false" "$(is_ipv4_proxy '[2001:db8::10]:443' && printf true || printf false)" "IPv6 rejected by strict IPv4 policy"
assert_eq "false" "$(is_ipv4_proxy '203.0.113.999:443' && printf true || printf false)" "invalid IPv4 octet rejected"
assert_eq "false" "$(is_ipv4_proxy '203.0.113.10:99999' && printf true || printf false)" "invalid port rejected"
assert_eq '[2001:db8::10]:443' "$(format_proxy_address '2001:db8::10' 443)" "IPv6 is bracketed at the boundary"
assert_eq "" "$(classify_checker_egress '{"success":true,"ip":"198.51.100.99"}')" "direct probe fields do not imply egress"
assert_eq "v4" "$(classify_checker_egress '{"success":true,"egress_ip":"198.51.100.99"}')" "trusted checker IPv4 egress"
assert_eq "v6" "$(classify_checker_egress '{"success":true,"egress_ip":"2001:db8::99"}')" "trusted checker IPv6 egress"
assert_eq "" "$(classify_checker_egress '{"success":false,"egress_ip":"198.51.100.99"}')" "failed checker does not imply egress"

normalized=$(normalize_json_candidates "$FIXTURES/source.json" | sort)
expected_normalized=$'198.51.100.20:443\tCA\tYTO\n203.0.113.10:443\tUS\tLAX\n203.0.113.10:8443\tUS\tLAX'
assert_eq "$expected_normalized" "$normalized" "JSON expands every port and drops IPv6"

normalized_text=$(normalize_text_candidates "$FIXTURES/source.txt" | sort)
expected_text=$'198.51.100.30:443\tCA\t\n203.0.113.30:443\tUS\t'
assert_eq "$expected_text" "$normalized_text" "plain-text source is normalized and drops IPv6"

tmp_dir=$(mktemp -d)
tmp_candidates="$tmp_dir/candidates"
tmp_map="$tmp_dir/candidates.map"
tmp_selected="$tmp_dir/selected"
cleanup() {
  rm -f "$tmp_candidates"
  rm -f "$tmp_map"
  rm -f "$tmp_selected"
  rm -f "$tmp_selected.cap"
  rm -f "$tmp_selected.iata"
  rm -f "$tmp_selected.remaining"
  rmdir "$tmp_dir" 2>/dev/null || true
}
trap cleanup EXIT
normalize_json_candidates "$FIXTURES/source.json" > "$tmp_map"
cut -f1 "$tmp_map" > "$tmp_candidates"
select_probe_candidates "$tmp_candidates" "$tmp_map" 2 "$tmp_selected"
selected=$(sort "$tmp_selected")
expected_selected=$'198.51.100.20:443\n203.0.113.10:443'
assert_eq "$expected_selected" "$selected" "probe cap keeps one candidate per IATA"

filtered=$(filter_gist_ipv4_json "$(< "$FIXTURES/current-gist.json")")
expected_filtered='[{"proxy":"203.0.113.40:443","v4":true,"v6":false,"ms":120,"colo":"LAX"}]'
assert_eq "$expected_filtered" "$filtered" "legacy Gist is cleaned to valid literal IPv4"

printf 'PASS: proxyip curator policy\n'
