#!/usr/bin/env bash
# Claude PreToolUse adapter: carry the canonical native session id into the
# shell process that actually runs a Bash command.
set -euo pipefail
input="$(cat)"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
session_id="$(LOOP_SPEC_IDENTITY_INPUT="$input" python3 "$ROOT/lib/session_identity.py" 2>/dev/null || true)"
[[ -n "$session_id" ]] || exit 0
LOOP_SPEC_HOOK_INPUT="$input" python3 - "$session_id" <<'PY'
import json, shlex, sys
import os
sid = sys.argv[1]
try:
    payload = json.loads(os.environ.get("LOOP_SPEC_HOOK_INPUT") or "")
except Exception:
    raise SystemExit(0)
if payload.get("tool_name") not in ("Bash", "bash"):
    raise SystemExit(0)
args = payload.get("tool_input") or {}
command = args.get("command")
expected = "export LOOP_SPEC_SESSION_ID=" + shlex.quote(sid)
if (not isinstance(command, str) or
        (command.splitlines() and command.splitlines()[0] in
         (expected, expected.replace("export ", "")))):
    raise SystemExit(0)
updated = dict(args)
updated["command"] = "export LOOP_SPEC_SESSION_ID=" + shlex.quote(sid) + "\n" + command
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
      "updatedInput": updated}}))
PY
