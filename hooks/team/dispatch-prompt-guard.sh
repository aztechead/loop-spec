#!/usr/bin/env bash
# PreToolUse hook: refuse an Agent dispatch whose prompt never became a brief.
#
# A live headless lead (the 2026-09-07 tf-meldn runs) wrote each implementer's
# brief to /tmp and dispatched `Agent({prompt: "$(cat /tmp/prompt-task-001.txt)"})`.
# The Agent tool is not a shell: both implementers started with a 31-character
# substitution as their whole assignment and only recovered because they guessed to
# `cat` the file themselves. This hook denies the two shapes a dispatch can take when the
# brief was never read: an unexpanded `$(...)` / backtick substitution, and a prompt too
# short to carry a task at all.
#
# Claude Code contract:
#   exit 0 = allow
#   exit 2 = deny (stderr shown to the model)
#
# Kill switch: LOOP_SPEC_DISPATCH_PROMPT_GUARD=0 -> exit 0.
# Fail-open: no payload, malformed JSON, no python3 -> exit 0.
#
# The per-line check only flags a line that is wholly `$(...)`, not a backtick span: a
# 6.6.1 live run denied a several-hundred-word review brief over a wrapped line that was
# only a backticked file path, and a spec-compliance brief whose acceptance criterion was
# a backticked shell command on its own line. Prose legitimately quotes a path or a
# command in backticks; only `$(...)` is the shape a lead's own dispatch call actually
# produces when `cat` never ran.
set -euo pipefail

if [[ "${LOOP_SPEC_DISPATCH_PROMPT_GUARD:-1}" == "0" ]]; then
  exit 0
fi

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
if str(payload.get("tool_name") or "") != "Agent":
    print("allow")
    raise SystemExit(0)
prompt = str((payload.get("tool_input") or {}).get("prompt") or "")
stripped = prompt.strip()
sub_line = next(((n, line.strip()) for n, line in enumerate(stripped.splitlines(), 1) if re.fullmatch(r"\$\([^)]*\)", line.strip())), None)
if re.fullmatch(r"\$\(.*\)|`.*`", stripped, re.S):
    # The whole prompt, not just one line, is a substitution or backtick span.
    print("substitution")
elif sub_line is not None:
    # A brief with one line that is only `$(cat ...)` shipped the placeholder, not the
    # file: a live pruner was dispatched twice for it. A backtick-only line is NOT this
    # shape (see header): prose legitimately quotes a path or command that way.
    print("substitution-line\t%d\t%s" % sub_line)
elif len(stripped) < 40:
    print("short")
else:
    print("allow")
')

case "$VERDICT" in
  substitution)
    echo "DENY: the Agent prompt is a shell substitution, not a brief. The Agent tool runs no shell; the agent would receive the literal text. Read the brief file (the dispatch packet's .brief, or the file you wrote) and pass its contents as the prompt. (Disable: LOOP_SPEC_DISPATCH_PROMPT_GUARD=0)" >&2
    exit 2 ;;
  substitution-line*)
    LINE_NO="$(cut -f2 <<<"$VERDICT")"; LINE_TEXT="$(cut -f3- <<<"$VERDICT")"
    echo "DENY: line $LINE_NO of the Agent prompt is an unexpanded shell substitution: $LINE_TEXT. The Agent tool runs no shell; the agent would receive the literal text. Read the brief file (the dispatch packet's .brief, or the file you wrote) and pass its contents as the prompt. (Disable: LOOP_SPEC_DISPATCH_PROMPT_GUARD=0)" >&2
    exit 2 ;;
  short)
    echo "DENY: the Agent prompt is under 40 characters; no task fits in that. Pass the full brief as the prompt. (Disable: LOOP_SPEC_DISPATCH_PROMPT_GUARD=0)" >&2
    exit 2 ;;
  *) exit 0 ;;
esac
