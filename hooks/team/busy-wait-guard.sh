#!/usr/bin/env bash
# PreToolUse hook: block a Bash call whose only work is sleeping.
#
# A live headless cycle (evals/findings-2026-09-07-tf-meldn.md) waited for a teammate's
# SendMessage reply with `for i in $(seq 1 100); do sleep 6; done`, launched in the
# background, then read the empty output file and launched another: twenty-four rounds,
# three turns each, for a reply the harness would have delivered by resuming the turn.
# skills/shared/dispatch.md says "dispatch, then stop"; this hook is the tool-boundary
# backstop for the leads that do not believe it under `claude -p`.
#
# Denied: a command whose every simple command is `sleep`, a `for`/`seq` loop around
# `sleep`, or a read-only peek (echo, cat, tail, head, wc, ls, stat, date, grep, jq,
# ps, pgrep, test, printf, true). A `sleep` beside real work (`sleep 2; kill $pid`, an
# `until`/`while` condition loop, a build, a probe) passes: the wait has a purpose.
#
# Claude Code contract:
#   exit 0 = allow
#   exit 2 = deny (stderr shown to the model)
#
# Kill switch: LOOP_SPEC_BUSY_WAIT_GUARD=0 -> exit 0.
# Fail-open: no payload, malformed JSON, no python3 -> exit 0.
set -euo pipefail

if [[ "${LOOP_SPEC_BUSY_WAIT_GUARD:-1}" == "0" ]]; then
  exit 0
fi

# Scope first: this hook sees every Bash call in every project the operator opens.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
if [[ ! -d "$PROJECT_DIR/.loop-spec" && ! -d "$PWD/.loop-spec" ]]; then
  exit 0
fi

trap 'exit 0' ERR
command -v python3 &>/dev/null || exit 0

INPUT=$(cat 2>/dev/null) || true
[[ -z "$INPUT" ]] && exit 0

VERDICT=$(printf '%s' "$INPUT" | python3 -c '
import json
import re
import sys

try:
    payload = json.load(sys.stdin)
except Exception:
    print("allow")
    raise SystemExit(0)

if str(payload.get("tool_name") or "") != "Bash":
    print("allow")
    raise SystemExit(0)
command = str((payload.get("tool_input") or {}).get("command") or "")
if not re.search(r"(?<![\w-])sleep\s+\d", command):
    print("allow")
    raise SystemExit(0)
# A condition loop is a real wait on a real signal.
if re.search(r"(?<![\w-])(until|while)\s", command):
    print("allow")
    raise SystemExit(0)

PEEK = {"echo", "cat", "tail", "head", "wc", "ls", "stat", "date", "grep", "jq", "ps",
        "pgrep", "test", "[", "printf", "true", ":", "sleep", "seq"}
# Strip loop scaffolding so only the simple commands remain.
body = re.sub(r"\bfor\s+\w+\s+in\s+[^;]*;\s*do\b", ";", command)
body = re.sub(r"\b(do|done|then|fi)\b", ";", body)
body = body.replace("$(", " ").replace(")", " ").replace("`", " ")
for piece in re.split(r"[;&|\n]+", body):
    piece = piece.strip()
    if not piece:
        continue
    first = piece.split()[0]
    if "=" in first and not first.startswith("="):
        # VAR=... assignment prefix; look at the word after it
        words = piece.split()
        first = words[1] if len(words) > 1 else "true"
    if first not in PEEK:
        print("allow")
        raise SystemExit(0)
print("deny")
')

if [[ "$VERDICT" == "deny" ]]; then
  echo "DENY: sleep is not a wait. Dispatch, then stop: the harness resumes this turn when the Agent returns, the teammate replies, or the background task exits, under claude -p too. Do independent lead work or end the turn; never sleep, in the foreground or as a background task you then poll. (skills/shared/dispatch.md, Waiting. Disable: LOOP_SPEC_BUSY_WAIT_GUARD=0)" >&2
  exit 2
fi
exit 0
