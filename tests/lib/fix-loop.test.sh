#!/usr/bin/env bash
# Tests for lib/fix-loop.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/lib/fix-loop.sh"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; ((FAIL++)) || true
  fi
}

check "max is 6" "6" "$(bash "$SCRIPT" max)"
check "attempt 0 is initial" "initial" "$(bash "$SCRIPT" action 0)"
check "attempt 1 is resume" "resume" "$(bash "$SCRIPT" action 1)"
check "attempt 3 is resume" "resume" "$(bash "$SCRIPT" action 3)"
check "attempt 4 is fresh-upgrade" "fresh-upgrade" "$(bash "$SCRIPT" action 4)"
check "attempt 5 is fresh-upgrade" "fresh-upgrade" "$(bash "$SCRIPT" action 5)"
check "attempt 6 is breaker" "breaker" "$(bash "$SCRIPT" action 6)"
check "attempt 9 is breaker" "breaker" "$(bash "$SCRIPT" action 9)"

check "live team is resumeable" "resumeable" "$(bash "$SCRIPT" live team)"
check "live implicit-named is resumeable" "resumeable" "$(bash "$SCRIPT" live implicit-named)"
check "live loop-fleet is resumeable" "resumeable" "$(bash "$SCRIPT" live loop-fleet)"
check "live subagent is oneshot" "oneshot" "$(bash "$SCRIPT" live subagent)"
check "live inline is oneshot" "oneshot" "$(bash "$SCRIPT" live inline)"
check "live workflow is oneshot" "oneshot" "$(bash "$SCRIPT" live workflow)"
check "live unknown is oneshot" "oneshot" "$(bash "$SCRIPT" live other)"

ec=0; bash "$SCRIPT" action >/dev/null 2>&1 || ec=$?
check "action without attempt exits 2" "2" "$ec"
ec=0; bash "$SCRIPT" bogus >/dev/null 2>&1 || ec=$?
check "unknown command exits 2" "2" "$ec"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
