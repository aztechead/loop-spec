#!/usr/bin/env bash
set -euo pipefail

LIB="$(cd "$(dirname "$0")/../.." && pwd)/lib/state-commit-policy.sh"
PASS=0
FAIL=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}
check "phase commits remain the default" "phase" "$(bash "$LIB" mode)"
check "squash mode defers state to delivery" "final" \
  "$(LOOP_SPEC_SQUASH_STATE_COMMITS=1 bash "$LIB" mode)"
set +e
LOOP_SPEC_SQUASH_STATE_COMMITS=maybe bash "$LIB" mode >/dev/null 2>&1
rc=$?
set -e
check "invalid value exits 2" "2" "$rc"
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
