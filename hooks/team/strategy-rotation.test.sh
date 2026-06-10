#!/usr/bin/env bash
# Test suite for hooks/team/strategy-rotation.sh
# PostToolUse hook: consecutive-failure strategy rotation.
# Usage: bash hooks/team/strategy-rotation.test.sh
set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/strategy-rotation.sh"

PASS=0
FAIL=0

# check NAME EXPECTED_EXIT PAYLOAD [ENV_VARS...]
# Runs the hook with PAYLOAD on stdin, captures stdout, checks exit code.
# Sets LAST_OUTPUT to stdout of the hook call.
LAST_OUTPUT=""

check() {
  local name="$1"
  local expected_exit="$2"
  local payload="$3"
  shift 3
  local actual_exit=0
  local output=""

  output=$(printf '%s' "$payload" | env "$@" bash "$HOOK" 2>/dev/null) || actual_exit=$?

  LAST_OUTPUT="$output"

  if [[ "$actual_exit" -eq "$expected_exit" ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected exit $expected_exit, got $actual_exit)"
    ((FAIL++)) || true
  fi
}

# check_output NAME PATTERN
# Asserts LAST_OUTPUT matches PATTERN (grep -q).
check_output() {
  local name="$1"
  local pattern="$2"
  if printf '%s' "$LAST_OUTPUT" | grep -q "$pattern" 2>/dev/null; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (pattern '$pattern' not found in output: $LAST_OUTPUT)"
    ((FAIL++)) || true
  fi
}

# check_no_output NAME PATTERN
# Asserts LAST_OUTPUT does NOT match PATTERN.
check_no_output() {
  local name="$1"
  local pattern="$2"
  if ! printf '%s' "$LAST_OUTPUT" | grep -q "$pattern" 2>/dev/null; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (pattern '$pattern' unexpectedly found in output)"
    ((FAIL++)) || true
  fi
}

# Build a PostToolUse payload for a given tool name and exit code
payload_bash_failure() {
  printf '{"tool_name":"Bash","exit_code":1,"result":"error: command failed"}'
}

payload_bash_success() {
  printf '{"tool_name":"Bash","exit_code":0,"result":"ok"}'
}

payload_edit_failure() {
  printf '{"tool_name":"Edit","exit_code":1,"result":"FAIL: edit failed"}'
}

payload_other_tool() {
  printf '{"tool_name":"Read","exit_code":1,"result":"error"}'
}

# Use a unique session per test run to isolate state files
SESSION_KEY="test-session-$$"
STATE_FILE="${TMPDIR:-/tmp}/loop-spec-failures-${SESSION_KEY}.json"

# Clean up any leftover state from this session
cleanup() {
  rm -f "$STATE_FILE" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== strategy-rotation.sh tests ==="

# ── Case 1: kill switch ────────────────────────────────────────────────────
cleanup
check "kill switch: LOOP_SPEC_STRATEGY_ROTATION=0 -> exit 0 no output" 0 \
  "$(payload_bash_failure)" \
  LOOP_SPEC_STRATEGY_ROTATION=0 \
  CLAUDE_CODE_SESSION_ID="$SESSION_KEY"
check_no_output "kill switch: no additionalContext emitted" "additionalContext"

# ── Case 2: fail-open with malformed JSON state file ──────────────────────
cleanup
# Pre-seed a malformed state file
printf 'THIS IS NOT JSON' > "$STATE_FILE"
check "fail-open: malformed state file -> exit 0" 0 \
  "$(payload_bash_failure)" \
  CLAUDE_CODE_SESSION_ID="$SESSION_KEY" \
  LOOP_SPEC_STRATEGY_ROTATION_THRESHOLD=2

# ── Case 3: threshold trigger ─────────────────────────────────────────────
# Send 2 consecutive Bash failures; on the 2nd the hook should emit additionalContext
cleanup
# First failure (counter -> 1, below threshold of 2)
check "threshold trigger: first failure no output" 0 \
  "$(payload_bash_failure)" \
  CLAUDE_CODE_SESSION_ID="$SESSION_KEY" \
  LOOP_SPEC_STRATEGY_ROTATION_THRESHOLD=2
check_no_output "threshold trigger: no additionalContext after first failure" "additionalContext"

# Second failure (counter -> 2, at threshold -> emit)
check "threshold trigger: second failure exit 0" 0 \
  "$(payload_bash_failure)" \
  CLAUDE_CODE_SESSION_ID="$SESSION_KEY" \
  LOOP_SPEC_STRATEGY_ROTATION_THRESHOLD=2
check_output "threshold trigger: additionalContext emitted at threshold" "additionalContext"
check_output "threshold trigger: message mentions STOP or stop" "STOP\|[Ss]top"
check_output "threshold trigger: message mentions failure mode or approach" "approach\|[Ff]ailure"

# ── Case 4: success reset ─────────────────────────────────────────────────
# After the above 2 failures (counter=2), send a success -> counter resets.
# Then send one more failure -> counter=1, below threshold -> no additionalContext.
cleanup
# Build up: one failure
check "success reset: initial failure" 0 \
  "$(payload_bash_failure)" \
  CLAUDE_CODE_SESSION_ID="$SESSION_KEY" \
  LOOP_SPEC_STRATEGY_ROTATION_THRESHOLD=2

# Success: resets counter to 0
check "success reset: success resets counter exit 0" 0 \
  "$(payload_bash_success)" \
  CLAUDE_CODE_SESSION_ID="$SESSION_KEY" \
  LOOP_SPEC_STRATEGY_ROTATION_THRESHOLD=2
check_no_output "success reset: no additionalContext on success" "additionalContext"

# One more failure after reset -> counter=1, still below threshold=2 -> no output
check "success reset: post-reset failure below threshold exit 0" 0 \
  "$(payload_bash_failure)" \
  CLAUDE_CODE_SESSION_ID="$SESSION_KEY" \
  LOOP_SPEC_STRATEGY_ROTATION_THRESHOLD=2
check_no_output "success reset: no additionalContext after single post-reset failure" "additionalContext"

# ── Case 5: non-tracked tool ignored ──────────────────────────────────────
cleanup
check "non-tracked tool: Read tool exit 0 no output" 0 \
  "$(payload_other_tool)" \
  CLAUDE_CODE_SESSION_ID="$SESSION_KEY" \
  LOOP_SPEC_STRATEGY_ROTATION_THRESHOLD=2
check_no_output "non-tracked tool: no additionalContext" "additionalContext"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
