#!/usr/bin/env bash
# Test suite for hooks/team/post-task-complete-revalidate.sh
# TaskCompleted hook: evidence scanning for user-gate tasks.
# Usage: bash hooks/team/post-task-complete-revalidate.test.sh
set -euo pipefail

HOOK="$(dirname "$0")/post-task-complete-revalidate.sh"

PASS=0
FAIL=0

# Use a temp trace log so tests don't pollute the real one
TRACE_LOG="${TMPDIR:-/tmp}/post-task-complete-revalidate-test-$$.log"
export LOOP_SPEC_USERGATE_TRACE_LOG="$TRACE_LOG"

check() {
  local name="$1"
  local expected_exit="$2"
  local payload="$3"
  local env_prefix="${4:-}"
  local actual_exit=0

  if [[ -n "$env_prefix" ]]; then
    echo "$payload" | env $env_prefix bash "$HOOK" >/dev/null 2>&1 || actual_exit=$?
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

# Payload helpers
payload_gate_task_with_transcript() {
  local task_id="${1:-task-001}"
  local transcript_content="${2:-}"
  printf '{"tool_name":"TaskCompleted","tool_input":{"taskId":"%s","metadata":{"userGate":true,"blockedBy":[],"files":["foo.sh"],"verifyCommand":"bash t.sh","acceptanceCriteria":["it works"]}},"transcript":%s}' \
    "$task_id" "$transcript_content"
}

payload_non_gate_task() {
  local task_id="${1:-task-001}"
  printf '{"tool_name":"TaskCompleted","tool_input":{"taskId":"%s","metadata":{"userGate":false,"blockedBy":[],"files":["foo.sh"],"verifyCommand":"bash t.sh","acceptanceCriteria":["it works"]}}}' \
    "$task_id"
}

# Transcript with evidence tokens
TRANSCRIPT_WITH_EVIDENCE='[{"role":"assistant","content":"AC: it works -- PROVEN BY exit 0 from bash test.sh"}]'

# Transcript without evidence tokens
TRANSCRIPT_WITHOUT_EVIDENCE='[{"role":"assistant","content":"I completed the task."}]'

echo "=== post-task-complete-revalidate.sh tests ==="

# (a) kill-switch: LOOP_SPEC_USERGATE_GUARD=0 -> exit 0 regardless of payload
check "a: kill-switch guard=0 exits 0" 0 \
  "$(payload_gate_task_with_transcript "task-001" "$TRANSCRIPT_WITHOUT_EVIDENCE")" \
  "LOOP_SPEC_USERGATE_GUARD=0"

# (b) fail-open: empty payload -> exit 0
check "b: fail-open empty payload exits 0" 0 \
  ""

# (c) fail-open: malformed JSON payload -> exit 0
check "c: fail-open malformed JSON exits 0" 0 \
  "not valid json at all {"

# (d) non-gate task (no userGate or userGate=false) -> exit 0
check "d: non-gate task exits 0" 0 \
  "$(payload_non_gate_task "task-002")"

# (e) gate task with AC: and PROVEN BY in transcript -> exit 0 (match)
check "e: gate task with evidence exits 0" 0 \
  "$(payload_gate_task_with_transcript "task-003" "$TRANSCRIPT_WITH_EVIDENCE")"

# (e2) gate task with absent transcript field -> exit 0 (fail-open: cannot enforce without evidence window)
check "e2: gate task absent transcript exits 0" 0 \
  "$(payload_non_gate_task "task-001" | python3 -c "import json,sys; d=json.load(sys.stdin); d['tool_input']['metadata']['userGate']=True; print(json.dumps(d))" 2>/dev/null || printf '{"tool_name":"TaskCompleted","tool_input":{"taskId":"task-001","metadata":{"userGate":true,"blockedBy":[],"files":["foo.sh"],"verifyCommand":"bash t.sh","acceptanceCriteria":["it works"]}}}')"

# (f) gate task with no evidence tokens in transcript -> exit 2 (miss)
check "f: gate task without evidence exits 2" 2 \
  "$(payload_gate_task_with_transcript "task-004" "$TRANSCRIPT_WITHOUT_EVIDENCE")"

# (g) trace-log line written: after the above invocations the log file must exist
# and contain at least one pipe-separated line
if [[ -f "$TRACE_LOG" ]] && grep -q "|post-task-complete-revalidate|" "$TRACE_LOG" 2>/dev/null; then
  echo "PASS: g: trace-log contains pipe-separated lines"
  ((PASS++)) || true
else
  echo "FAIL: g: trace-log missing or malformed (file: $TRACE_LOG)"
  ((FAIL++)) || true
fi

# Cleanup
rm -f "$TRACE_LOG"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
