#!/usr/bin/env bash
# Test suite for hooks/team/output-compressor.sh
# PostToolUse hook: large output compression.
# Usage: bash hooks/team/output-compressor.test.sh
set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/output-compressor.sh"

PASS=0
FAIL=0
LAST_OUTPUT=""
LAST_EXIT=0

# Unique session key per test run to isolate debounce state files.
SESSION_KEY="test-compressor-$$"
DEBOUNCE_FILE="${TMPDIR:-/tmp}/super-spec-compress-${SESSION_KEY}.count"

cleanup() {
  rm -f "$DEBOUNCE_FILE" 2>/dev/null || true
}
trap cleanup EXIT

# check NAME EXPECTED_EXIT PAYLOAD [ENV_VARS...]
check() {
  local name="$1"
  local expected_exit="$2"
  local payload="$3"
  shift 3
  LAST_EXIT=0
  LAST_OUTPUT=""
  LAST_OUTPUT=$(printf '%s' "$payload" | env "$@" bash "$HOOK" 2>/dev/null) || LAST_EXIT=$?
  if [[ "$LAST_EXIT" -eq "$expected_exit" ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected exit $expected_exit, got $LAST_EXIT)"
    ((FAIL++)) || true
  fi
}

check_output() {
  local name="$1"
  local pattern="$2"
  if printf '%s' "$LAST_OUTPUT" | grep -q "$pattern" 2>/dev/null; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (pattern '$pattern' not found in: $LAST_OUTPUT)"
    ((FAIL++)) || true
  fi
}

check_no_output() {
  local name="$1"
  local pattern="$2"
  if ! printf '%s' "$LAST_OUTPUT" | grep -q "$pattern" 2>/dev/null; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (pattern '$pattern' unexpectedly found in: $LAST_OUTPUT)"
    ((FAIL++)) || true
  fi
}

# Build a PostToolUse payload with a given output string.
make_payload() {
  local output="$1"
  python3 -c "
import json, sys
output = sys.argv[1]
print(json.dumps({'tool_name': 'Read', 'output': output}))
" "$output"
}

# Generate a string longer than 3000 chars.
big_string() {
  python3 -c "print('x' * 3100)"
}

# Generate a JSON array with many items, total > 3000 chars.
big_json_array() {
  python3 -c "
import json
items = [{'id': i, 'name': 'item-' + str(i), 'value': 'data-' * 20} for i in range(20)]
print(json.dumps(items))
"
}

# Generate a JSON array payload (output field contains the JSON array string > 3000 chars).
big_json_array_payload() {
  python3 -c "
import json
# value field is 200 chars to ensure arr_str > 3000 chars total
items = [{'id': i, 'name': 'item-' + str(i), 'value': 'data-' * 40} for i in range(20)]
arr_str = json.dumps(items)
print(json.dumps({'tool_name': 'Read', 'output': arr_str}))
"
}

# Advance debounce counter to the 3rd call (so next call triggers compression).
advance_to_third_call() {
  # Write count=2 so the next increment makes it 3 (divisible by 3).
  printf '2' > "$DEBOUNCE_FILE"
}

echo "=== output-compressor.sh tests ==="

# ── Case 1: kill switch ───────────────────────────────────────────────────────
cleanup
advance_to_third_call
check "kill switch: SUPER_SPEC_COMPRESSOR=0 -> exit 0" 0 \
  "$(make_payload "$(big_string)")" \
  SUPER_SPEC_COMPRESSOR=0 \
  CLAUDE_CODE_SESSION_ID="$SESSION_KEY"
check_no_output "kill switch: no output emitted" "decision"

# ── Case 2: threshold trigger - output above 3000 chars compresses ────────────
cleanup
advance_to_third_call
check "threshold trigger: large output -> exit 0" 0 \
  "$(make_payload "$(big_string)")" \
  SUPER_SPEC_COMPRESSOR=1 \
  CLAUDE_CODE_SESSION_ID="$SESSION_KEY"
check_output "threshold trigger: hookSpecificOutput shape" "hookSpecificOutput"
check_output "threshold trigger: additionalContext present" "additionalContext"

# ── Case 3: threshold not reached - small output passes through silently ──────
cleanup
advance_to_third_call
check "threshold not reached: small output -> exit 0 no output" 0 \
  "$(make_payload "small output")" \
  SUPER_SPEC_COMPRESSOR=1 \
  CLAUDE_CODE_SESSION_ID="$SESSION_KEY"
check_no_output "threshold not reached: no compression output" "decision"

# ── Case 4: JSON array shape - first and last items present in summary ─────────
cleanup
advance_to_third_call
check "JSON array shape: large array -> exit 0" 0 \
  "$(big_json_array_payload)" \
  SUPER_SPEC_COMPRESSOR=1 \
  CLAUDE_CODE_SESSION_ID="$SESSION_KEY"
check_output "JSON array shape: additionalContext present" "additionalContext"
check_output "JSON array shape: mentions item count (20 items)" "20"
check_output "JSON array shape: mentions first/last items" "First 2\|first_items\|last_items\|Last 2"

# ── Case 5: fail-open - malformed JSON input exits 0 silently ─────────────────
cleanup
advance_to_third_call
check "fail-open: malformed JSON -> exit 0" 0 \
  "THIS IS NOT JSON AT ALL" \
  SUPER_SPEC_COMPRESSOR=1 \
  CLAUDE_CODE_SESSION_ID="$SESSION_KEY"
check_no_output "fail-open: no output on malformed input" "decision"

# ── Case 6: debounce - only every 3rd call triggers compression ───────────────
cleanup
# Reset debounce state (count=0).
# First call: count becomes 1, not divisible by 3 -> no output.
check "debounce: first call no output" 0 \
  "$(make_payload "$(big_string)")" \
  SUPER_SPEC_COMPRESSOR=1 \
  CLAUDE_CODE_SESSION_ID="$SESSION_KEY"
check_no_output "debounce: first call silent" "decision"

# Second call: count becomes 2, not divisible by 3 -> no output.
check "debounce: second call no output" 0 \
  "$(make_payload "$(big_string)")" \
  SUPER_SPEC_COMPRESSOR=1 \
  CLAUDE_CODE_SESSION_ID="$SESSION_KEY"
check_no_output "debounce: second call silent" "decision"

# Third call: count becomes 3, divisible by 3 -> compression fires.
check "debounce: third call compresses" 0 \
  "$(make_payload "$(big_string)")" \
  SUPER_SPEC_COMPRESSOR=1 \
  CLAUDE_CODE_SESSION_ID="$SESSION_KEY"
check_output "debounce: third call emits additionalContext" "additionalContext"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
