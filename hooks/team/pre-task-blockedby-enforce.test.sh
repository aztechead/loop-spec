#!/usr/bin/env bash
# Test suite for hooks/team/pre-task-blockedby-enforce.sh
# PreToolUse (TaskUpdate) hook: blockedBy dependency enforcement.
# Usage: bash hooks/team/pre-task-blockedby-enforce.test.sh
set -euo pipefail

HOOK="$(dirname "$0")/pre-task-blockedby-enforce.sh"
TRACE_LOG="${TMPDIR:-/tmp}/pre-blockedby-test-$$.log"

PASS=0
FAIL=0

check() {
  local name="$1"
  local expected_exit="$2"
  local payload="$3"
  local extra_env="${4:-}"
  local actual_exit=0

  if [[ -n "$extra_env" ]]; then
    echo "$payload" | env SUPER_SPEC_BLOCKEDBY_TRACE_LOG="$TRACE_LOG" $extra_env bash "$HOOK" >/dev/null 2>&1 || actual_exit=$?
  else
    echo "$payload" | env SUPER_SPEC_BLOCKEDBY_TRACE_LOG="$TRACE_LOG" bash "$HOOK" >/dev/null 2>&1 || actual_exit=$?
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
payload_update() {
  local task_id="$1"
  local status="$2"
  local blocked_by_json="${3:-[]}"
  local tasks_json="${4:-null}"
  if [[ "$tasks_json" == "null" ]]; then
    printf '{"tool_name":"TaskUpdate","tool_input":{"taskId":"%s","status":"%s","metadata":{"blockedBy":%s}}}' \
      "$task_id" "$status" "$blocked_by_json"
  else
    printf '{"tool_name":"TaskUpdate","tool_input":{"taskId":"%s","status":"%s","metadata":{"blockedBy":%s}},"tasks":%s}' \
      "$task_id" "$status" "$blocked_by_json" "$tasks_json"
  fi
}

echo "=== pre-task-blockedby-enforce.sh tests ==="

# a: kill-switch: SUPER_SPEC_BLOCKEDBY_GUARD=0 -> exit 0 regardless of payload
check "a: kill-switch exit 0" 0 \
  "$(payload_update "task-002" "in_progress" '["task-001"]' '[{"id":"task-001","status":"pending"}]')" \
  "SUPER_SPEC_BLOCKEDBY_GUARD=0"

# b: fail-open: empty payload -> exit 0
check "b: fail-open empty payload" 0 ""

# c: fail-open: malformed JSON -> exit 0
check "c: fail-open malformed JSON" 0 "not-valid-json{{"

# d: status != in_progress: status=completed -> exit 0 (hook skips)
check "d: status=completed passthrough" 0 \
  "$(payload_update "task-002" "completed" '["task-001"]' '[{"id":"task-001","status":"pending"}]')"

# e: status != in_progress: status=pending -> exit 0 (hook skips)
check "e: status=pending passthrough" 0 \
  "$(payload_update "task-002" "pending" '["task-001"]' '[{"id":"task-001","status":"pending"}]')"

# f: all-clear: blockedBy=[], status=in_progress -> exit 0
check "f: all-clear empty blockedBy" 0 \
  "$(payload_update "task-002" "in_progress" '[]' '[{"id":"task-001","status":"pending"}]')"

# g: all-clear: all blockedBy completed -> exit 0
check "g: all blockedBy completed" 0 \
  "$(payload_update "task-002" "in_progress" '["task-001"]' '[{"id":"task-001","status":"completed"}]')"

# h: blocked dep: blockedBy=["task-001"], task-001 status=pending -> exit 2
check "h: blocked dep pending -> exit 2" 2 \
  "$(payload_update "task-002" "in_progress" '["task-001"]' '[{"id":"task-001","status":"pending"}]')"

# i: blocked dep: blockedBy=["task-001"], task-001 status=in_progress -> exit 2
check "i: blocked dep in_progress -> exit 2" 2 \
  "$(payload_update "task-002" "in_progress" '["task-001"]' '[{"id":"task-001","status":"in_progress"}]')"

# j: fail-open: tasks field absent from payload -> exit 0 (cannot enforce)
check "j: fail-open no tasks field" 0 \
  "$(payload_update "task-002" "in_progress" '["task-001"]')"

# k: multiple blockedBy, one not done -> exit 2
TASKS_JSON='[{"id":"task-001","status":"completed"},{"id":"task-003","status":"pending"}]'
check "k: multiple blockedBy one not done -> exit 2" 2 \
  "$(payload_update "task-004" "in_progress" '["task-001","task-003"]' "$TASKS_JSON")"

# l: multiple blockedBy, all completed -> exit 0
TASKS_JSON_ALL_DONE='[{"id":"task-001","status":"completed"},{"id":"task-003","status":"completed"}]'
check "l: multiple blockedBy all completed -> exit 0" 0 \
  "$(payload_update "task-004" "in_progress" '["task-001","task-003"]' "$TASKS_JSON_ALL_DONE")"

# m: trace-log line written: verify at least one line was appended during tests
if [[ -f "$TRACE_LOG" ]] && [[ -s "$TRACE_LOG" ]]; then
  TRACE_LINE=$(head -1 "$TRACE_LOG")
  if echo "$TRACE_LINE" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\|pre-task-blockedby-enforce\|'; then
    echo "PASS: m: trace-log pipe-separated line written"
    ((PASS++)) || true
  else
    echo "FAIL: m: trace-log line format unexpected: $TRACE_LINE"
    ((FAIL++)) || true
  fi
else
  echo "FAIL: m: trace-log file not written or empty"
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
