#!/usr/bin/env bash
# PreToolUse hook: block TaskUpdate(status=in_progress) when the task's
# blockedBy list still points at uncompleted tasks.
#
# Claude Code contract:
#   exit 0  = allow
#   exit 2  = block (with stderr message shown to user)
#
# Fires on PreToolUse with matcher=TaskUpdate. When status=in_progress:
#   1. Extract tool_input.metadata.blockedBy and tool_input.taskId.
#   2. Look up each blockedBy task in the payload's top-level "tasks" array.
#   3. If any blockedBy task is not "completed", refuse with exit 2.
#
# Fail-open: if the payload is malformed, empty, or missing the "tasks"
# field entirely, exit 0. Enforcement requires peer status data.
#
# Kill switch: SUPER_SPEC_BLOCKEDBY_GUARD=0 disables enforcement entirely.
#
# Trace log: every decision writes a pipe-separated line to
# ${SUPER_SPEC_BLOCKEDBY_TRACE_LOG:-/tmp/claude-hooks/super-spec-user-gate-trace.log}
set -euo pipefail

TRACE_LOG="${SUPER_SPEC_BLOCKEDBY_TRACE_LOG:-/tmp/claude-hooks/super-spec-user-gate-trace.log}"
mkdir -p "$(dirname "$TRACE_LOG")" 2>/dev/null || true

trace() {
  local tid="${1:-?}" event="${2:-?}" reason="${3:-}"
  printf '%s|pre-task-blockedby-enforce|%s|%s|%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$tid" "$event" "$reason" \
    >> "$TRACE_LOG" 2>/dev/null || true
}

if [[ "${SUPER_SPEC_BLOCKEDBY_GUARD:-1}" == "0" ]]; then
  trace "?" "skip" "guard=0"
  exit 0
fi

INPUT=$(cat)

# Fail-open on empty or malformed JSON
RESULT=$(printf '%s' "$INPUT" | python3 -c "
import json, sys

try:
    d = json.loads(sys.stdin.read())
except Exception:
    print('FAIL_OPEN:malformed-json')
    sys.exit(0)

tool_input = d.get('tool_input') or {}
status = tool_input.get('status') or ''

if status != 'in_progress':
    print('SKIP:status=' + status)
    sys.exit(0)

task_id = str(tool_input.get('taskId') or '')
if not task_id:
    print('FAIL_OPEN:no-task-id')
    sys.exit(0)

metadata = tool_input.get('metadata') or {}
blocked_by = metadata.get('blockedBy') or []
if not isinstance(blocked_by, list):
    blocked_by = []

if not blocked_by:
    print('CLEAR:' + task_id + ':no-blocked-by')
    sys.exit(0)

# Look up peer task statuses from the payload 'tasks' array.
# If absent, fail-open: we cannot enforce without peer data.
tasks_list = d.get('tasks')
if tasks_list is None:
    print('FAIL_OPEN:no-tasks-field')
    sys.exit(0)

# Build id->status map
task_map = {}
for t in (tasks_list if isinstance(tasks_list, list) else []):
    tid = str(t.get('id') or t.get('taskId') or '')
    tstatus = str(t.get('status') or 'unknown')
    if tid:
        task_map[tid] = tstatus

missing = []
for bid in blocked_by:
    bid = str(bid)
    bstatus = task_map.get(bid, 'unknown')
    if bstatus != 'completed':
        missing.append(bid + ':' + bstatus)

if missing:
    print('BLOCK:' + task_id + ':' + '|'.join(missing))
else:
    print('CLEAR:' + task_id + ':all-done')
" 2>/dev/null || echo "FAIL_OPEN:python-error")

# Parse the result token
case "$RESULT" in
  FAIL_OPEN:*)
    reason="${RESULT#FAIL_OPEN:}"
    trace "?" "skip" "$reason"
    exit 0
    ;;
  SKIP:*)
    reason="${RESULT#SKIP:}"
    trace "?" "skip" "$reason"
    exit 0
    ;;
  CLEAR:*)
    rest="${RESULT#CLEAR:}"
    task_id="${rest%%:*}"
    reason="${rest#*:}"
    trace "$task_id" "pass" "$reason"
    exit 0
    ;;
  BLOCK:*)
    rest="${RESULT#BLOCK:}"
    task_id="${rest%%:*}"
    blockers="${rest#*:}"
    trace "$task_id" "block" "$blockers"
    {
      echo "DENY: task $task_id is blocked by uncompleted dependencies."
      echo ""
      IFS='|' read -ra BLOCKER_LIST <<< "$blockers"
      for entry in "${BLOCKER_LIST[@]}"; do
        bid="${entry%%:*}"
        bstatus="${entry#*:}"
        echo "  - task $bid (status: $bstatus)"
      done
      echo ""
      echo "Complete or cancel the listed tasks before starting task $task_id."
      echo "(Disable: SUPER_SPEC_BLOCKEDBY_GUARD=0)"
    } >&2
    exit 2
    ;;
  *)
    trace "?" "skip" "unexpected-result"
    exit 0
    ;;
esac
