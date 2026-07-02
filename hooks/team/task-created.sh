#!/usr/bin/env bash
# PreToolUse hook: validate required task metadata fields at TaskCreate time.
#
# Claude Code contract:
#   exit 0  = allow
#   exit 2  = block (with stderr message shown to user)
#
# SCOPE: only tasks EXPLICITLY marked tool_input.metadata.loopSpec == true
# (written by EXECUTE Step 4) are validated. Every other TaskCreate — the main
# thread's ordinary task tracking, other plugins, other workflows — passes
# through untouched. Enforcing on unmarked tasks broke core Claude Code task
# tracking for any session with the plugin installed.
#
# The subject convention "task-NNN: ..." is deliberately NOT an enforcement
# trigger (it was, until 2.6.1): a session running the new plugin against an
# old task config / old PLAN run creates convention-named tasks with no
# metadata, and the regex turned that version skew into a hard DENY on every
# TaskCreate. Current EXECUTE always sets loopSpec: true, so the guard loses
# nothing on current installs; convention-named tasks without the marker pass
# through with an advisory on stderr (visible in verbose/hook logs, never a
# block).
#
# Validates that marked tasks carry: blockedBy, files, verifyCommand,
# acceptanceCriteria (the EXECUTE self-claim contract).
#
# Kill switch: LOOP_SPEC_TASK_GUARD=0 -> exit 0 unconditionally.
# Fail-open: malformed payload or python3 failure -> exit 0 (never error).
set -euo pipefail

# Fail-open: any unexpected error must not block the session.
trap 'exit 0' ERR

if [[ "${LOOP_SPEC_TASK_GUARD:-1}" == "0" ]]; then
  exit 0
fi

INPUT=$(cat 2>/dev/null) || true
[[ -z "$INPUT" ]] && exit 0

RESULT=$(printf '%s' "$INPUT" | python3 -c "
import json, re, sys

try:
    d = json.load(sys.stdin)
except Exception:
    print('SKIP')
    sys.exit(0)

tool_input = d.get('tool_input') or {}
metadata = tool_input.get('metadata') or {}
subject = tool_input.get('subject') or ''

marked = metadata.get('loopSpec') is True
convention_only = (not marked) and re.match(r'^task-[0-9]+:', subject)

if not marked:
    print('CONVENTION' if convention_only else 'SKIP')
    sys.exit(0)

required = ['blockedBy', 'files', 'verifyCommand', 'acceptanceCriteria']
missing = []
for field in required:
    if field not in metadata:
        missing.append(field)
        continue
    val = metadata[field]
    if field == 'verifyCommand' and (not isinstance(val, str) or not val.strip()):
        missing.append(field)
        continue
    if field == 'acceptanceCriteria' and (not isinstance(val, list) or len(val) == 0):
        missing.append(field)
        continue

if missing:
    print('MISSING:' + ','.join(missing))
else:
    print('OK')
" 2>/dev/null) || RESULT="SKIP"

case "$RESULT" in
  OK|SKIP|"")
    exit 0
    ;;
  CONVENTION)
    # Advisory only: convention-named but unmarked (old config / other workflow).
    echo "loop-spec: task subject matches the EXECUTE convention (task-NNN:) but carries no loopSpec marker; not enforcing the metadata contract on it. Current EXECUTE runs mark their tasks — this usually means an older task config or a different workflow." >&2
    exit 0
    ;;
  MISSING:*)
    MISSING_FIELDS="${RESULT#MISSING:}"
    echo "DENY: loop-spec task metadata missing or invalid required fields: $MISSING_FIELDS. EXECUTE tasks must carry blockedBy, files, verifyCommand, and acceptanceCriteria. (Disable: LOOP_SPEC_TASK_GUARD=0)" >&2
    exit 2
    ;;
  *)
    exit 0
    ;;
esac
