#!/usr/bin/env bash
# PreToolUse hook (Bash): a phase lead never launches a nested harness session.
#
# Why: after a HANDOFF the cycle skill says "print the marker and stop; the caller
# re-invokes". A live sonnet run did not stop: it wrote a round script around
# `claude -p /loop-spec:cycle` and spent its own budget a second time, and the
# handoff guard then denied the nested phase (docs/loop-spec/orchestrator-port-plan.md,
# WP4 finding). The prose rule is in skills/cycle/SKILL.md; this is its enforcement.
#
# Denies (exit 2, reason on stderr) a Bash command that launches a headless harness CLI
# (`claude -p`, `claude --print`, `codex exec`, `opencode run`, `adk run`), whether the
# launch is in the command text or in a script file the command names. The bundled
# launchers are the exceptions, because spawning sessions is their job:
# extensions/sessions/session_run.py (the EXECUTE session rung), the loop-runner
# scripts (the loop-fleet rung), and evals/eval_run.py (the outcome eval, which drives
# cycles from outside them).
#
# Stands down (exit 0) when LOOP_SPEC_NESTED_SESSION_GUARD=0, when the project has no
# .loop-spec/ directory (never hijack an unrelated project), when the tool is not Bash,
# and on any unreadable payload (fail-open, like every guard here). Registered for
# Claude Code in hooks/hooks.json; Codex, opencode, and ADK have no Bash PreToolUse
# wired to it, so there the cycle skill's sentence is the only rule.
set -euo pipefail

if [[ "${LOOP_SPEC_NESTED_SESSION_GUARD:-1}" == "0" ]]; then
  exit 0
fi
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
if [[ ! -d "$PROJECT_DIR/.loop-spec" && ! -d "$PWD/.loop-spec" ]]; then
  exit 0
fi
command -v python3 >/dev/null 2>&1 || exit 0

INPUT=$(cat)
VERDICT=$(printf '%s' "$INPUT" | NESTED_GUARD_CWD="$PWD" python3 -c '
import json
import os
import re
import shlex
import sys

LAUNCH = re.compile(r"(?:^|[\s;&|(`])(claude\s+(?:-p|--print)\b|codex\s+exec\b|opencode\s+run\b|adk\s+run\b)")
# The bundled launchers, matched as the path token the command runs, never as a
# substring anywhere in the line: a comment naming session_run.py next to a `claude -p`
# was a pass (port audit 1, F8).
LAUNCHERS = re.compile(r"(?:^|[\s\"\x27=])(?:[\w.~-]*/)*(?:extensions/sessions/session_run\.py|skills/loop-runner/scripts/[\w.-]+\.py|evals/eval_run\.py)(?=$|[\s\"\x27])")

try:
    payload = json.load(sys.stdin)
except Exception:
    print("allow")
    raise SystemExit(0)
if str(payload.get("tool_name") or "") != "Bash":
    print("allow")
    raise SystemExit(0)
command = str((payload.get("tool_input") or {}).get("command") or "")
# A launcher path in a comment is not a launcher the command runs.
if LAUNCHERS.search(re.sub(r"(?:^|\s)#.*$", "", command, flags=re.M)):
    print("allow")
    raise SystemExit(0)

found = LAUNCH.search(command)
where = "the command"
if not found:
    # A launch hidden in a script the command runs: read every existing file the
    # command names (bounded, so a large data file costs nothing).
    try:
        words = shlex.split(command)
    except ValueError:
        words = command.split()
    cwd = os.environ.get("NESTED_GUARD_CWD") or os.getcwd()
    for word in words:
        path = word if os.path.isabs(word) else os.path.join(cwd, word)
        if not os.path.isfile(path):
            continue
        try:
            with open(path, "rb") as fh:
                text = fh.read(64 * 1024).decode("utf-8", errors="replace")
        except OSError:
            continue
        if LAUNCHERS.search(" " + path):
            continue
        found = LAUNCH.search(text)
        if found:
            where = word
            break
if found:
    print("deny\t%s\t%s" % (found.group(1).split()[0] + " " + found.group(1).split()[1], where))
else:
    print("allow")
' 2>/dev/null || echo "allow")

case "$VERDICT" in
  deny*)
    IFS=$'\t' read -r _ launch where <<<"$VERDICT"
    cat >&2 <<MSG
loop-spec: a phase lead never launches a nested harness session ($launch in $where).
After HANDOFF, print the LOOP_SPEC_HANDOFF marker and stop; the caller re-invokes
/loop-spec:cycle. EXECUTE's session rung is launched by the driver
(cycle-driver.sh task run, through extensions/sessions/session_run.py) and the
loop-fleet rung through the loop-runner scripts (skills/cycle/SKILL.md, HANDOFF).
MSG
    exit 2
    ;;
esac
exit 0
