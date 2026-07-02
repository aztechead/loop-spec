#!/usr/bin/env bash
# Tests for lib/debug-budget.sh (bounded FIX-loop counters).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/lib/debug-budget.sh"
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

WORK="${TMPDIR:-/tmp}"; WORK="${WORK%/}/debug-budget-test.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bug"
BUG="$WORK/bug"

# bad invocation
ec=0; bash "$SCRIPT" hypothesis >/dev/null 2>&1 || ec=$?
check "missing bug_dir exits 1" "1" "$ec"
ec=0; bash "$SCRIPT" attempt "$BUG" >/dev/null 2>&1 || ec=$?
check "attempt before hypothesis exits 1" "1" "$ec"

# initial status
s="$(bash "$SCRIPT" status "$BUG")"
check "initial hypothesis 0" "0" "$(jq -r '.hypothesis' <<<"$s")"
check "default max hypotheses" "5" "$(jq -r '.max_hypotheses' <<<"$s")"
check "default max attempts" "3" "$(jq -r '.max_attempts' <<<"$s")"

# first hypothesis
out="$(bash "$SCRIPT" hypothesis "$BUG")"
check "h1 opens" "1" "$(jq -r '.hypothesis' <<<"$out")"
check "h1 leaves 4" "4" "$(jq -r '.hypotheses_left' <<<"$out")"

# attempts within budget
check "attempt 1" "1" "$(bash "$SCRIPT" attempt "$BUG" | jq -r '.attempts')"
check "attempt 2" "2" "$(bash "$SCRIPT" attempt "$BUG" | jq -r '.attempts')"
out="$(bash "$SCRIPT" attempt "$BUG")"
check "attempt 3" "3" "$(jq -r '.attempts' <<<"$out")"
check "attempt 3 leaves 0" "0" "$(jq -r '.attempts_left' <<<"$out")"

# 4th attempt exhausts
ec=0; out="$(bash "$SCRIPT" attempt "$BUG")" || ec=$?
check "attempt 4 exits 3" "3" "$ec"
check "attempt 4 flags exhausted" "true" "$(jq -r '.exhausted' <<<"$out")"

# next hypothesis resets attempts
out="$(bash "$SCRIPT" hypothesis "$BUG")"
check "h2 opens" "2" "$(jq -r '.hypothesis' <<<"$out")"
check "h2 attempts reset" "0" "$(jq -r '.attempts' <<<"$out")"
check "attempt after reset" "1" "$(bash "$SCRIPT" attempt "$BUG" | jq -r '.attempts')"

# hypothesis budget exhausts at max
for _ in 3 4 5; do bash "$SCRIPT" hypothesis "$BUG" >/dev/null; done
ec=0; out="$(bash "$SCRIPT" hypothesis "$BUG")" || ec=$?
check "hypothesis 6 exits 3" "3" "$ec"
check "hypothesis 6 flags exhausted" "true" "$(jq -r '.exhausted' <<<"$out")"

# state survives across invocations (it is a file, not context)
check "state persisted" "5" "$(bash "$SCRIPT" status "$BUG" | jq -r '.hypothesis')"

# env-tunable budgets
mkdir -p "$WORK/bug2"
out="$(LOOP_SPEC_DEBUG_MAX_HYPOTHESES=1 bash "$SCRIPT" hypothesis "$WORK/bug2")"
check "custom budget h1 ok" "1" "$(jq -r '.hypothesis' <<<"$out")"
ec=0; LOOP_SPEC_DEBUG_MAX_HYPOTHESES=1 bash "$SCRIPT" hypothesis "$WORK/bug2" >/dev/null || ec=$?
check "custom budget h2 exhausted" "3" "$ec"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
