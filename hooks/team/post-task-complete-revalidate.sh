#!/usr/bin/env bash
# TaskCompleted hook: evidence scanning for user-gate tasks.
#
# Claude Code contract:
#   exit 0  = allow
#   exit 2  = block (with stderr message shown to user)
#
# For tasks with userGate: true in metadata, scans the transcript window
# for AC: or PROVEN BY evidence tokens. If none are found, exits 2.
#
# Fail-open: empty or malformed JSON payload -> exit 0
# Kill-switch: LOOP_SPEC_USERGATE_GUARD=0 -> exit 0 unconditionally
#
# Trace log: pipe-separated lines appended to
#   ${LOOP_SPEC_USERGATE_TRACE_LOG:-/tmp/claude-hooks/loop-spec-user-gate-trace.log}
#   format: <ISO-8601>|post-task-complete-revalidate|<task-id>|<event>|<reason>
set -euo pipefail

TRACE_LOG="${LOOP_SPEC_USERGATE_TRACE_LOG:-/tmp/claude-hooks/loop-spec-user-gate-trace.log}"
mkdir -p "$(dirname "$TRACE_LOG")" 2>/dev/null || true

trace() {
  local tid="${1:-?}" event="${2:-?}" reason="${3:-}"
  printf '%s|post-task-complete-revalidate|%s|%s|%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$tid" "$event" "$reason" \
    >> "$TRACE_LOG" 2>/dev/null || true
}

# Kill-switch: allow unconditional bypass
if [[ "${LOOP_SPEC_USERGATE_GUARD:-1}" == "0" ]]; then
  trace "?" "skip" "guard=0"
  exit 0
fi

# Fail-open trap: any unexpected error -> exit 0
trap 'trace "?" "error" "trap-ERR"; exit 0' ERR

INPUT=$(cat)

# Fail-open: empty input
if [[ -z "${INPUT// }" ]]; then
  trace "?" "skip" "empty-input"
  exit 0
fi

# Parse the payload with python3; output key fields as shell-sourceable vars
PARSED=$(printf '%s' "$INPUT" | python3 -c "
import json, re, sys

try:
    d = json.loads(sys.stdin.read())
except Exception:
    print('PARSE_ERROR')
    sys.exit(0)

tool_input = d.get('tool_input') or {}
metadata = tool_input.get('metadata') or {}
task_id = tool_input.get('taskId') or '?'

user_gate = bool(metadata.get('userGate', False))

# Fail-open if transcript field is absent or not a list
raw_transcript = d.get('transcript')
if raw_transcript is None:
    # transcript absent: cannot enforce without evidence window
    print('task_id=' + task_id)
    print('user_gate=skip')
    print('evidence_found=true')
    print('axes_satisfied=true')
    sys.exit(0)

transcript = raw_transcript if isinstance(raw_transcript, list) else []
window_texts = []
for entry in transcript:
    if not isinstance(entry, dict):
        continue
    content = entry.get('content', '')
    if isinstance(content, str) and content.strip():
        window_texts.append(content)
    elif isinstance(content, list):
        for item in content:
            if isinstance(item, dict) and item.get('type') == 'text':
                t = item.get('text', '') or ''
                if t.strip():
                    window_texts.append(t)

# Scan for evidence tokens
ac_re = re.compile(r'\bAC\s*:', re.IGNORECASE)
pb_re = re.compile(r'\bPROVEN\s+BY\b', re.IGNORECASE)
evidence_found = any(ac_re.search(t) or pb_re.search(t) for t in window_texts)

# Also scan requireEvidenceTokens axes if present
req_tokens = metadata.get('requireEvidenceTokens')
axes_satisfied = True
if isinstance(req_tokens, list) and all(isinstance(a, list) for a in req_tokens) and req_tokens:
    corpus = ' '.join(window_texts)
    for axis in req_tokens:
        tokens = [str(tok) for tok in axis if tok]
        pattern = r'\b(' + '|'.join(re.escape(t) for t in tokens) + r')\b'
        if not re.search(pattern, corpus, re.IGNORECASE):
            axes_satisfied = False
            break

print('task_id=' + task_id)
print('user_gate=' + ('true' if user_gate else 'false'))
print('evidence_found=' + ('true' if evidence_found else 'false'))
print('axes_satisfied=' + ('true' if axes_satisfied else 'false'))
" 2>/dev/null || echo "PARSE_ERROR")

# Fail-open: python3 parse error
if [[ "$PARSED" == "PARSE_ERROR" ]] || [[ -z "$PARSED" ]]; then
  trace "?" "skip" "parse-error"
  exit 0
fi

# Source the parsed values into shell variables
TASK_ID="?"
USER_GATE="false"
EVIDENCE_FOUND="false"
AXES_SATISFIED="true"

while IFS='=' read -r key value; do
  case "$key" in
    task_id)      TASK_ID="$value" ;;
    user_gate)    USER_GATE="$value" ;;
    evidence_found) EVIDENCE_FOUND="$value" ;;
    axes_satisfied) AXES_SATISFIED="$value" ;;
  esac
done <<< "$PARSED"

trace "$TASK_ID" "enter" "user_gate=$USER_GATE"

# Non-gate task: pass through silently
if [[ "$USER_GATE" != "true" ]]; then
  trace "$TASK_ID" "pass" "not-a-gate-task"
  exit 0
fi

# Gate task: evidence required
if [[ "$EVIDENCE_FOUND" == "true" && "$AXES_SATISFIED" == "true" ]]; then
  trace "$TASK_ID" "pass" "evidence-on-record"
  exit 0
fi

trace "$TASK_ID" "block" "gate-without-evidence evidence=$EVIDENCE_FOUND axes=$AXES_SATISFIED"

{
  echo "DENY: user-gate task $TASK_ID closed without evidence."
  echo ""
  echo "Task $TASK_ID has userGate: true but no AC: or PROVEN BY tokens"
  echo "were found in the transcript window."
  echo ""
  echo "Before reclosing, post at least one line per acceptance criterion:"
  echo "  AC: <criterion> -- PROVEN BY <observed output>"
  echo ""
  echo "If evidence was already posted in different wording, re-state it"
  echo "in the canonical form above, then reclose the task."
  echo ""
  echo "(Runtime disable: LOOP_SPEC_USERGATE_GUARD=0. Trace: $TRACE_LOG)"
} >&2

exit 2
