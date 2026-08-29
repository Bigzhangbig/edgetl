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

normalized=$(normalize_json_candidates "$FIXTURES/source.json" | sort)
expected_normalized=$'198.51.100.20:443\tCA\tYTO\n203.0.113.10:443\tUS\tLAX\n203.0.113.10:8443\tUS\tLAX'
assert_eq "$expected_normalized" "$normalized" "JSON expands every port and drops IPv6"

filtered=$(filter_gist_ipv4_json "$(< "$FIXTURES/current-gist.json")")
expected_filtered='[{"proxy":"203.0.113.40:443","v4":true,"v6":false,"ms":120,"colo":"LAX","egress":"v6"}]'
assert_eq "$expected_filtered" "$filtered" "legacy Gist is cleaned to valid literal IPv4"

printf 'PASS: proxyip curator policy\n'
