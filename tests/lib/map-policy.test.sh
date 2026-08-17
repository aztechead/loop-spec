#!/usr/bin/env bash
set -euo pipefail

LIB="$(cd "$(dirname "$0")/../.." && pwd)/lib/map-policy.sh"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

check "bootstrap defaults on" "run" "$(bash "$LIB" bootstrap)"
check "refresh defaults on" "run" "$(bash "$LIB" refresh)"
check "bootstrap can be skipped" "skip" "$(LOOP_SPEC_MAP_BOOTSTRAP=0 bash "$LIB" bootstrap)"
check "refresh can be skipped" "skip" "$(LOOP_SPEC_MAP_REFRESH=0 bash "$LIB" refresh)"

set +e
LOOP_SPEC_MAP_BOOTSTRAP=maybe bash "$LIB" bootstrap >/dev/null 2>&1
invalid_rc=$?
bash "$LIB" unknown >/dev/null 2>&1
unknown_rc=$?
set -e
check "invalid policy exits 2" "2" "$invalid_rc"
check "unknown stage exits 2" "2" "$unknown_rc"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
