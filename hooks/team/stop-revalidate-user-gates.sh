#!/usr/bin/env bash
# Stop hook: plan-complete safety net for user-gate evidence.
#
# Claude Code contract:
#   exit 0  = allow (stop proceeds)
#   exit 2  = block (with stderr message shown to user)
#
# Fires on the Stop event. Blocks when BOTH conditions hold:
#
#   1. The last assistant message in the transcript contains a plan-complete
#      phrase (e.g., "all gates passed", "plan complete", "all tasks completed").
#
#   2. At least one closed userGate:true task has no AC: / PROVEN BY evidence
#      in the transcript after its close index.
#
# Assumption about payload: the Stop event delivers a JSON object with a
# top-level "transcript_path" field pointing to a JSONL session file. If this
# field is absent or the file does not exist, the hook exits 0 (fail-open).
#
# Escape hatch: set SUPER_SPEC_USERGATE_STOP_GUARD=0 to disable.
set -euo pipefail

TRACE_LOG="${SUPER_SPEC_USERGATE_TRACE_LOG:-/tmp/claude-hooks/super-spec-user-gate-trace.log}"
mkdir -p "$(dirname "$TRACE_LOG")" 2>/dev/null || true

trace() {
  local task_id="${1:-?}" event="${2:-}" reason="${3:-}"
  printf '%s|stop-revalidate-user-gates|%s|%s|%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$task_id" "$event" "$reason" \
    >> "$TRACE_LOG" 2>/dev/null || true
}

# Kill-switch: SUPER_SPEC_USERGATE_STOP_GUARD=0 disables the hook.
if [[ "${SUPER_SPEC_USERGATE_STOP_GUARD:-1}" == "0" ]]; then
  trace "?" "skip" "stop-guard=0"
  exit 0
fi

# Fail-open: any unhandled error must not block the user.
trap 'trace "?" "error" "trap-ERR"; exit 0' ERR

INPUT=$(cat)

# stop_hook_active guard: when Claude Code is already continuing because of a
# previous Stop-hook block, do not block again. Claude Code force-overrides
# after 8 consecutive blocks; re-blocking only wastes turns. Exit 0 early.
if printf '%s' "$INPUT" | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin).get('stop_hook_active') else 1)" 2>/dev/null; then
  trace "?" "skip" "stop_hook_active"
  exit 0
fi

# Extract transcript_path from payload (fail-open if absent or unreadable).
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(d.get('transcript_path', '') or '')
except Exception:
    print('')
" 2>/dev/null || true)

if [[ -z "$TRANSCRIPT_PATH" || ! -f "$TRANSCRIPT_PATH" ]]; then
  trace "?" "skip" "no-transcript"
  exit 0
fi

trace "?" "enter" "transcript=$TRANSCRIPT_PATH"

# Scan the transcript JSONL to:
#   - reconstruct closed userGate tasks (via TaskCreate + TaskUpdate)
#   - detect plan-complete phrase in the last assistant text
#   - check for AC:/PROVEN BY evidence after each gate's close index
PY_SCAN='
import json, re, sys

path = sys.argv[1]

try:
    with open(path) as f:
        lines = f.readlines()
except Exception:
    print(json.dumps({"has_completion_claim": False, "blocked_gates": [], "total_tasks": 0}))
    sys.exit(0)

tasks = {}
# id -> {subject, description, status, userGate, closedAtIdx}
assistant_texts = []  # list of (line_idx, text)
last_text = ""
next_id = 1

for idx, line in enumerate(lines):
    try:
        entry = json.loads(line)
    except Exception:
        continue
    if entry.get("type") != "assistant":
        continue
    msg = entry.get("message") or {}
    for c in (msg.get("content") or []):
        if not isinstance(c, dict):
            continue
        ctype = c.get("type", "")
        if ctype == "text":
            txt = (c.get("text") or "").strip()
            if txt:
                assistant_texts.append((idx, txt))
                last_text = txt
        elif ctype == "tool_use":
            name = c.get("name", "")
            inp = c.get("input") or {}
            if name == "TaskCreate":
                tid = str(inp.get("taskId", next_id))
                tasks[tid] = {
                    "subject": inp.get("subject", ""),
                    "description": inp.get("description", "") or "",
                    "status": "pending",
                    "userGate": False,
                    "closedAtIdx": None,
                }
                try:
                    next_id = max(next_id, int(tid) + 1)
                except (ValueError, TypeError):
                    next_id += 1
            elif name == "TaskUpdate":
                tid = str(inp.get("taskId", ""))
                if tid not in tasks:
                    tasks[tid] = {
                        "subject": "",
                        "description": "",
                        "status": "pending",
                        "userGate": False,
                        "closedAtIdx": None,
                    }
                if inp.get("subject"):
                    tasks[tid]["subject"] = inp["subject"]
                if inp.get("description"):
                    tasks[tid]["description"] = inp["description"]
                new_status = inp.get("status")
                if new_status:
                    tasks[tid]["status"] = new_status
                    if new_status == "completed":
                        tasks[tid]["closedAtIdx"] = idx
                try:
                    next_id = max(next_id, int(tid) + 1)
                except (ValueError, TypeError):
                    pass

# Classify userGate from task description metadata block.
for tid, t in tasks.items():
    desc = t["description"]
    m = re.search(r"```json:metadata\s*\n(.*?)\n```", desc, re.DOTALL)
    if m:
        try:
            meta = json.loads(m.group(1))
            if meta.get("userGate"):
                t["userGate"] = True
        except Exception:
            pass
    if "USER-ORDERED GATE" in desc.upper():
        t["userGate"] = True

# Plan-complete phrases to detect in the last assistant message.
keywords = [
    "plan complete",
    "plan is complete",
    "plan finished",
    "implementation complete",
    "implementation is complete",
    "all tasks complete",
    "all tasks completed",
    "all tasks done",
    "all gates passed",
    "both gates passed",
    "both gates pass",
    "gate passed",
    "gate passes",
    "verification gate passed",
    "complete",
    "done",
]
low = last_text.lower()
has_completion_claim = any(k in low for k in keywords)

blocked_gates = []
if has_completion_claim:
    for tid, t in tasks.items():
        if t["status"] != "completed":
            continue
        if not t["userGate"]:
            continue
        close_idx = t["closedAtIdx"] or 0
        proof_found = False
        for (i, txt) in assistant_texts:
            if i <= close_idx:
                continue
            if re.search(r"\bAC\s*:", txt, re.IGNORECASE) or \
               re.search(r"\bPROVEN\s+BY\b", txt, re.IGNORECASE):
                proof_found = True
                break
        if not proof_found:
            blocked_gates.append({"id": tid, "subject": t["subject"]})

print(json.dumps({
    "has_completion_claim": has_completion_claim,
    "blocked_gates": blocked_gates,
    "total_tasks": len(tasks),
}))
'

RESULT=$(python3 -c "$PY_SCAN" "$TRANSCRIPT_PATH" 2>/dev/null || echo "{}")

BLOCKED_COUNT=$(printf '%s' "$RESULT" | jq -r '.blocked_gates | length // 0' 2>/dev/null || echo "0")
HAS_CLAIM=$(printf '%s' "$RESULT" | jq -r '.has_completion_claim // false' 2>/dev/null || echo "false")
TOTAL=$(printf '%s' "$RESULT" | jq -r '.total_tasks // 0' 2>/dev/null || echo "0")

trace "?" "scanned" "tasks=$TOTAL claim=$HAS_CLAIM blocked_gates=$BLOCKED_COUNT"

if [[ "${BLOCKED_COUNT:-0}" -le 0 ]]; then
  trace "?" "pass" "no-unproven-gates"
  exit 0
fi

trace "?" "block" "unproven_gates=$BLOCKED_COUNT"

{
  echo "PLAN-COMPLETE CLAIM DETECTED -- GATES MISSING EVIDENCE"
  echo
  echo "You signalled the plan or gates as complete, but the transcript shows"
  echo "$BLOCKED_COUNT user-gate task(s) closed without per-criterion proof in"
  echo "subsequent assistant messages."
  echo
  echo "For each gate listed below, reopen it and post AC:/PROVEN BY evidence:"
  echo
  printf '%s' "$RESULT" | jq -r '.blocked_gates[] | "  - Task #" + .id + ": " + .subject' 2>/dev/null || true
  echo
  echo "Evidence must appear in the form:"
  echo "  Gate: <subject>"
  echo "  AC: <criterion> -- PROVEN BY <exact command/output/result>"
  echo
  echo "(To disable this check, set SUPER_SPEC_USERGATE_STOP_GUARD=0.)"
} >&2

exit 2
