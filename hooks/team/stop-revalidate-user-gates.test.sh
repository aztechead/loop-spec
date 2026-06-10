#!/usr/bin/env bash
# Test suite for hooks/team/stop-revalidate-user-gates.sh
# Stop hook: plan-complete safety net for user-gate evidence.
# Usage: bash hooks/team/stop-revalidate-user-gates.test.sh
set -euo pipefail

HOOK="$(dirname "$0")/stop-revalidate-user-gates.sh"
TMPDIR_TESTS="${TMPDIR:-/tmp}/stop-revalidate-user-gates-tests-$$"
mkdir -p "$TMPDIR_TESTS"

PASS=0
FAIL=0

check() {
  local name="$1"
  local expected_exit="$2"
  local payload="$3"
  shift 3
  local extra_env=("$@")
  local actual_exit=0

  if [[ ${#extra_env[@]} -gt 0 ]]; then
    echo "$payload" | env "${extra_env[@]}" bash "$HOOK" >/dev/null 2>&1 || actual_exit=$?
  else
    echo "$payload" | bash "$HOOK" >/dev/null 2>&1 || actual_exit=$?
  fi

  if [[ "$actual_exit" -eq "$expected_exit" ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected exit $expected_exit, got $actual_exit)"
    ((FAIL++)) || true
  fi
}

# ---- transcript helpers ----

# Write a JSONL transcript to a temp file and return the path.
make_transcript() {
  local path="$TMPDIR_TESTS/transcript-$$.jsonl"
  printf '%s' "$1" > "$path"
  echo "$path"
}

# Single assistant text message as a JSONL line.
assistant_text_line() {
  local text="$1"
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":%s}]}}\n' \
    "$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$text")"
}

# TaskCreate line for a userGate task.
# The description contains a metadata fence with newlines, so we JSON-encode it
# with python3 to avoid embedding raw newlines inside a JSON string.
task_create_gate_line() {
  local id="$1"
  local subject="$2"
  python3 -c "
import json, sys
tid, subj = sys.argv[1], sys.argv[2]
desc = '\`\`\`json:metadata\n{\"userGate\":true}\n\`\`\`'
obj = {
  'type': 'assistant',
  'message': {
    'content': [{
      'type': 'tool_use',
      'name': 'TaskCreate',
      'input': {'taskId': tid, 'subject': subj, 'description': desc}
    }]
  }
}
print(json.dumps(obj))
" "$id" "$subject"
}

# TaskUpdate line marking a task completed.
task_update_complete_line() {
  local id="$1"
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskUpdate","input":{"taskId":"%s","status":"completed"}}]}}\n' \
    "$id"
}

# Build a Stop payload referencing a transcript file path.
payload_with_transcript() {
  local transcript_path="$1"
  printf '{"transcript_path":"%s"}' "$transcript_path"
}

# Build a Stop payload with stop_hook_active=true (continuation after a block).
payload_stop_hook_active() {
  local transcript_path="$1"
  printf '{"stop_hook_active":true,"transcript_path":"%s"}' "$transcript_path"
}

# Empty payload.
payload_empty() {
  printf ''
}

# Malformed JSON payload.
payload_bad_json() {
  printf 'NOT_JSON{'
}

# No transcript_path field.
payload_no_transcript() {
  printf '{"stop_hook_active":true}'
}

TRACE_LOG="$TMPDIR_TESTS/trace-$$.log"

echo "=== stop-revalidate-user-gates.sh tests ==="

# (a) kill-switch: SUPER_SPEC_USERGATE_STOP_GUARD=0 -> exit 0
check "a: kill-switch SUPER_SPEC_USERGATE_STOP_GUARD=0 ALLOW" 0 \
  "$(payload_no_transcript)" \
  "SUPER_SPEC_USERGATE_STOP_GUARD=0" \
  "SUPER_SPEC_USERGATE_TRACE_LOG=$TRACE_LOG"

# (b) fail-open: empty payload -> exit 0
check "b: fail-open empty payload ALLOW" 0 \
  "$(payload_empty)" \
  "SUPER_SPEC_USERGATE_TRACE_LOG=$TRACE_LOG"

# (c) fail-open: malformed JSON -> exit 0
check "c: fail-open malformed JSON ALLOW" 0 \
  "$(payload_bad_json)" \
  "SUPER_SPEC_USERGATE_TRACE_LOG=$TRACE_LOG"

# (d) no-trigger: last assistant message has no plan-complete phrase -> exit 0
#     Has a gate task closed, but no plan-complete phrase in final message.
T_NO_TRIGGER="$TMPDIR_TESTS/t-no-trigger.jsonl"
{
  task_create_gate_line "1" "Some gate task"
  task_update_complete_line "1"
  assistant_text_line "Still working on the task."
} > "$T_NO_TRIGGER"

check "d: no-trigger no plan-complete phrase ALLOW" 0 \
  "$(payload_with_transcript "$T_NO_TRIGGER")" \
  "SUPER_SPEC_USERGATE_TRACE_LOG=$TRACE_LOG"

# (e) all-proven: plan-complete phrase present, gate task has AC:/PROVEN BY -> exit 0
T_ALL_PROVEN="$TMPDIR_TESTS/t-all-proven.jsonl"
{
  task_create_gate_line "1" "Deploy gate"
  task_update_complete_line "1"
  assistant_text_line "AC: deployment verified. PROVEN BY running smoke test and observing 200 response."
  assistant_text_line "All gates passed and the plan is complete."
} > "$T_ALL_PROVEN"

check "e: all-proven all gates have evidence ALLOW" 0 \
  "$(payload_with_transcript "$T_ALL_PROVEN")" \
  "SUPER_SPEC_USERGATE_TRACE_LOG=$TRACE_LOG"

# (f) blocked: plan-complete phrase present, one gate task missing evidence -> exit 2
T_BLOCKED="$TMPDIR_TESTS/t-blocked.jsonl"
{
  task_create_gate_line "1" "Integration gate"
  task_update_complete_line "1"
  assistant_text_line "All tasks completed."
} > "$T_BLOCKED"

check "f: blocked gate missing evidence DENY" 2 \
  "$(payload_with_transcript "$T_BLOCKED")" \
  "SUPER_SPEC_USERGATE_TRACE_LOG=$TRACE_LOG"

# (f2) stop_hook_active guard: same blocking transcript but stop_hook_active=true
#      -> exit 0 (must not re-block a Stop-hook continuation, per Claude Code docs)
check "f2: stop_hook_active continuation ALLOW (no re-block)" 0 \
  "$(payload_stop_hook_active "$T_BLOCKED")" \
  "SUPER_SPEC_USERGATE_TRACE_LOG=$TRACE_LOG"

# (g) trace-log line written: log file contains pipe-separated line after invocations
if [[ -f "$TRACE_LOG" ]]; then
  if grep -q "|stop-revalidate-user-gates|" "$TRACE_LOG" 2>/dev/null; then
    echo "PASS: g: trace-log line written with correct format"
    ((PASS++)) || true
  else
    echo "FAIL: g: trace-log exists but missing pipe-separated line with hook name"
    ((FAIL++)) || true
  fi
else
  echo "FAIL: g: trace-log file not created at $TRACE_LOG"
  ((FAIL++)) || true
fi

# Cleanup
rm -rf "$TMPDIR_TESTS"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
