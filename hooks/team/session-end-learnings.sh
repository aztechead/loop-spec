#!/usr/bin/env bash
# Stop hook: append structured JSONL learning entry at session end.
#
# Appends one JSONL line to .super-spec/learnings.jsonl and trims the file
# to the last 50 lines (FIFO cap). Infers a heuristic lesson from session
# signals extracted from the Stop payload.
#
# JSONL schema per line:
#   {"timestamp":"<ISO-8601>","sessionId":"<id>","taskType":"<inferred>",
#    "approach":"<inferred>","outcome":"<success|partial|error>","lesson":"<heuristic>"}
#
# Heuristics:
#   - agent count > 3   -> lesson: "parallel dispatch effective"
#   - errors present    -> lesson: "partial outcome detected"
#   Both signals: first match (agent count) wins.
#
# Kill switch: SUPER_SPEC_LEARNINGS=0 -> exit 0 immediately, file untouched.
# Fail-open:   trap 'exit 0' ERR
#
# Hook event: Stop (SessionEnd not universally available; Stop fires reliably)

set -euo pipefail

# Kill switch.
if [[ "${SUPER_SPEC_LEARNINGS:-1}" == "0" ]]; then
  exit 0
fi

# Fail-open: any unexpected error must not block the session.
trap 'exit 0' ERR

# Session identification.
SESSION="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-$$}}"

# Target file path.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
SUPER_SPEC_DIR="${PROJECT_DIR}/.super-spec"
LEARNINGS_FILE="${SUPER_SPEC_DIR}/learnings.jsonl"

# Read stdin (Stop payload). Tolerate empty input.
if [ -t 0 ]; then
  INPUT=""
else
  INPUT=$(cat 2>/dev/null || true)
fi

# Parse session signals from payload via python3 inline. Fail-open on any error.
SIGNALS=""
if [[ -n "$INPUT" ]] && command -v python3 &>/dev/null; then
  SIGNALS=$(printf '%s' "$INPUT" | python3 -c "
import sys, json

try:
    d = json.load(sys.stdin)
except Exception:
    print('agent_count=0 error_count=0 task_type=general')
    sys.exit(0)

# Agent / tool call count heuristic: look for transcript length or agent_calls.
agent_count = 0
error_count = 0
task_type = 'general'

# Try top-level fields first.
agent_count = int(d.get('total_agent_calls', d.get('agent_calls', 0)) or 0)

# Count errors from a top-level errors list.
errors = d.get('errors', [])
if isinstance(errors, list):
    error_count = len(errors)
elif isinstance(errors, int):
    error_count = errors

# If agent_count is still 0, estimate from transcript length.
if agent_count == 0:
    transcript = d.get('transcript', [])
    if isinstance(transcript, list):
        agent_msgs = [m for m in transcript if isinstance(m, dict) and m.get('role') == 'assistant']
        agent_count = len(agent_msgs)

# Infer task type from workflow field if present.
workflow = str(d.get('workflow', '') or '')
if workflow in ('probe', 'discover', 'research'):
    task_type = 'research'
elif workflow in ('tangle', 'develop', 'build'):
    task_type = 'implementation'
elif workflow in ('ink', 'deliver', 'review'):
    task_type = 'review'
elif workflow in ('debug', 'fix'):
    task_type = 'debugging'

print('agent_count={} error_count={} task_type={}'.format(agent_count, error_count, task_type))
" 2>/dev/null) || SIGNALS=""
fi

# Default signals if parsing produced nothing.
if [[ -z "$SIGNALS" ]]; then
  SIGNALS="agent_count=0 error_count=0 task_type=general"
fi

# Extract individual values.
AGENT_COUNT=$(printf '%s' "$SIGNALS" | grep -oE 'agent_count=[0-9]+' | cut -d= -f2 || echo 0)
ERROR_COUNT=$(printf '%s' "$SIGNALS" | grep -oE 'error_count=[0-9]+' | cut -d= -f2 || echo 0)
TASK_TYPE=$(printf '%s' "$SIGNALS" | grep -oE 'task_type=[a-z_]+' | cut -d= -f2 || echo general)

AGENT_COUNT="${AGENT_COUNT:-0}"
ERROR_COUNT="${ERROR_COUNT:-0}"
TASK_TYPE="${TASK_TYPE:-general}"

# Determine outcome.
if [[ "${ERROR_COUNT}" -gt 0 ]]; then
  OUTCOME="partial"
else
  OUTCOME="success"
fi

# Heuristic lesson: agent count takes priority.
if [[ "${AGENT_COUNT}" -gt 3 ]]; then
  LESSON="parallel dispatch effective"
elif [[ "${ERROR_COUNT}" -gt 0 ]]; then
  LESSON="partial outcome detected"
else
  LESSON="session completed"
fi

# Build approach summary.
APPROACH="agents=${AGENT_COUNT} task_type=${TASK_TYPE}"

# Timestamp.
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)

# Construct JSONL line via python3 to ensure correct JSON escaping.
JSONL_LINE=""
if command -v python3 &>/dev/null; then
  JSONL_LINE=$(python3 -c "
import json, sys
line = {
    'timestamp': sys.argv[1],
    'sessionId': sys.argv[2],
    'taskType':  sys.argv[3],
    'approach':  sys.argv[4],
    'outcome':   sys.argv[5],
    'lesson':    sys.argv[6],
}
print(json.dumps(line))
" "$TIMESTAMP" "$SESSION" "$TASK_TYPE" "$APPROACH" "$OUTCOME" "$LESSON" 2>/dev/null) || JSONL_LINE=""
fi

# Fallback: build line without python3 (basic escaping via printf).
if [[ -z "$JSONL_LINE" ]]; then
  JSONL_LINE=$(printf '{"timestamp":"%s","sessionId":"%s","taskType":"%s","approach":"%s","outcome":"%s","lesson":"%s"}' \
    "$TIMESTAMP" "$SESSION" "$TASK_TYPE" "$APPROACH" "$OUTCOME" "$LESSON")
fi

# Ensure target directory exists.
mkdir -p "$SUPER_SPEC_DIR"

# Append JSONL line.
printf '%s\n' "$JSONL_LINE" >> "$LEARNINGS_FILE"

# FIFO cap: trim to last 50 lines.
LINE_COUNT=$(wc -l < "$LEARNINGS_FILE" 2>/dev/null | tr -d ' ' || echo 0)
if [[ "${LINE_COUNT}" -gt 50 ]]; then
  TMPFILE=$(mktemp "${TMPDIR:-/tmp}/super-spec-learnings-cap-XXXXXX")
  tail -n 50 "$LEARNINGS_FILE" > "$TMPFILE"
  mv "$TMPFILE" "$LEARNINGS_FILE"
fi

exit 0
