#!/usr/bin/env bash
# Test suite for hooks/team/budget-gate.sh
# PreToolUse hook: enforces session cost budget ceiling.
# Usage: bash hooks/team/budget-gate.test.sh
set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/budget-gate.sh"

PASS=0
FAIL=0

TRACE_LOG="${TMPDIR:-/tmp}/budget-gate-test-$$.log"
export SUPER_SPEC_BUDGET_TRACE_LOG="$TRACE_LOG"

# check <name> <expected_exit> <stdin_payload> [env_vars...]
# Captures stdout and stderr separately.
check() {
  local name="$1"
  local expected_exit="$2"
  local payload="$3"
  shift 3
  local actual_exit=0
  local actual_stdout

  actual_stdout=$(printf '%s' "$payload" | env "$@" bash "$HOOK" 2>/dev/null) || actual_exit=$?

  if [[ "$actual_exit" -eq "$expected_exit" ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected exit $expected_exit, got $actual_exit)"
    ((FAIL++)) || true
  fi
  # Return stdout to caller via global so callers can inspect it.
  LAST_STDOUT="$actual_stdout"
}

# check_stdout_contains <name> <expected_exit> <needle> <payload> [env_vars...]
check_stdout_contains() {
  local name="$1"
  local expected_exit="$2"
  local needle="$3"
  local payload="$4"
  shift 4
  local actual_exit=0
  local actual_stdout

  actual_stdout=$(printf '%s' "$payload" | env "$@" bash "$HOOK" 2>/dev/null) || actual_exit=$?

  local exit_ok=0
  local content_ok=0
  [[ "$actual_exit" -eq "$expected_exit" ]] && exit_ok=1
  echo "$actual_stdout" | grep -q "$needle" && content_ok=1

  if [[ "$exit_ok" -eq 1 && "$content_ok" -eq 1 ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (exit expected=$expected_exit got=$actual_exit; needle='$needle' found=$content_ok)"
    ((FAIL++)) || true
  fi
}

EMPTY_PAYLOAD='{}'

echo "=== budget-gate.sh tests ==="

# 1. No ceiling: SUPER_SPEC_MAX_COST_USD unset -> exit 0 unconditionally
check "1: no ceiling (MAX unset) exits 0" 0 \
  "$EMPTY_PAYLOAD" \
  SUPER_SPEC_SESSION_COST_USD=999

# 2. Kill switch: SUPER_SPEC_BUDGET_GUARD=0, over budget -> still exit 0
check "2: kill switch GUARD=0 exits 0 even when over budget" 0 \
  "$EMPTY_PAYLOAD" \
  SUPER_SPEC_MAX_COST_USD=10 \
  SUPER_SPEC_SESSION_COST_USD=20 \
  SUPER_SPEC_BUDGET_GUARD=0

# 3. Warn at 80%: cost=8, max=10 -> exit 0, stdout contains "WARNING"
check_stdout_contains "3: warn at 80% exits 0 with WARNING in stdout" 0 \
  "WARNING" \
  "$EMPTY_PAYLOAD" \
  SUPER_SPEC_MAX_COST_USD=10 \
  SUPER_SPEC_SESSION_COST_USD=8

# 4. Block at 100%: cost=10, max=10 -> exit 2
check "4: block at 100% exits 2" 2 \
  "$EMPTY_PAYLOAD" \
  SUPER_SPEC_MAX_COST_USD=10 \
  SUPER_SPEC_SESSION_COST_USD=10

# 5. Fail-open: malformed metrics-session.json -> exit 0
TMPDIR_TESTS="${TMPDIR:-/tmp}/budget-gate-tests-$$"
mkdir -p "$TMPDIR_TESTS"
printf 'not valid json {{{' > "$TMPDIR_TESTS/metrics-session.json"

actual_exit=0
(cd "$TMPDIR_TESTS" && printf '%s' "$EMPTY_PAYLOAD" | \
  SUPER_SPEC_MAX_COST_USD=10 bash "$HOOK" >/dev/null 2>/dev/null) || actual_exit=$?
if [[ "$actual_exit" -eq 0 ]]; then
  echo "PASS: 5: fail-open malformed metrics-session.json exits 0"
  ((PASS++)) || true
else
  echo "FAIL: 5: fail-open malformed metrics-session.json (expected 0, got $actual_exit)"
  ((FAIL++)) || true
fi

# 6. Block above 100%: cost=15, max=10 -> exit 2
check "6: block above 100% exits 2" 2 \
  "$EMPTY_PAYLOAD" \
  SUPER_SPEC_MAX_COST_USD=10 \
  SUPER_SPEC_SESSION_COST_USD=15

# 7. Below 80%: cost=7.9, max=10 -> exit 0, no WARNING in stdout
actual_exit=0
actual_stdout=$(printf '%s' "$EMPTY_PAYLOAD" | \
  SUPER_SPEC_MAX_COST_USD=10 SUPER_SPEC_SESSION_COST_USD=7.9 bash "$HOOK" 2>/dev/null) || actual_exit=$?
if [[ "$actual_exit" -eq 0 ]] && ! echo "$actual_stdout" | grep -q "WARNING"; then
  echo "PASS: 7: below 80% exits 0 silently"
  ((PASS++)) || true
else
  echo "FAIL: 7: below 80% (exit=$actual_exit stdout='$actual_stdout')"
  ((FAIL++)) || true
fi

# 8. metrics-session.json cost source: write valid JSON, no env var -> should warn at 80%
printf '{"totals":{"estimated_cost_usd":8.5}}' > "$TMPDIR_TESTS/metrics-session.json"
actual_exit=0
actual_stdout=$(cd "$TMPDIR_TESTS" && printf '%s' "$EMPTY_PAYLOAD" | \
  SUPER_SPEC_MAX_COST_USD=10 bash "$HOOK" 2>/dev/null) || actual_exit=$?
if [[ "$actual_exit" -eq 0 ]] && echo "$actual_stdout" | grep -q "WARNING"; then
  echo "PASS: 8: metrics-session.json cost source warns at 80%"
  ((PASS++)) || true
else
  echo "FAIL: 8: metrics-session.json cost source (exit=$actual_exit stdout='$actual_stdout')"
  ((FAIL++)) || true
fi

# Cleanup
rm -rf "$TMPDIR_TESTS"
rm -f "$TRACE_LOG"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
