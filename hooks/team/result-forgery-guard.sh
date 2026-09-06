#!/usr/bin/env bash
# PreToolUse hook (Bash): the terminal result and the feature state are written by
# lib/cycle-result.sh and lib/feature-write.sh, never by a shell redirection.
#
# Claude Code contract:
#   exit 0 = allow
#   exit 2 = deny (stderr shown to the model)
#
# Why: twice in the evals a lead whose result the writer refused wrote
# .loop-spec/last-result.json itself -- once with the Write tool, once with a heredoc --
# and a supervisor read a completed run that had never reached DELIVER
# (evals/findings-2026-09-06.md). hooks/restrict-agent-paths.sh covers Write and Edit;
# this covers the shell: `>`, `>>`, `tee`, `cp`, `mv`, `install`, `sed -i`, and a Python
# `open(..., "w")` whose target is one of the contract files. Reading them stays free.
#
# Contract files (by basename, anywhere under .loop-spec/):
#   last-result.json result.json active-run.json feature.json delivery.json
#
# Stands down (exit 0) when the project has no .loop-spec/ dir, when python3 is
# missing, or when the payload is malformed. Kill switch: LOOP_SPEC_FORGERY_GUARD=0.
set -uo pipefail

[[ "${LOOP_SPEC_FORGERY_GUARD:-1}" == "0" ]] && exit 0
if [[ ! -d "${CLAUDE_PROJECT_DIR:-$PWD}/.loop-spec" && ! -d "$PWD/.loop-spec" ]]; then exit 0; fi
command -v python3 >/dev/null 2>&1 || exit 0

INPUT="$(cat)"
VERDICT="$(LOOP_SPEC_GUARD_INPUT="$INPUT" python3 - <<'PY' 2>/dev/null || true
import json, os, re, sys
try:
    payload = json.loads(os.environ.get("LOOP_SPEC_GUARD_INPUT") or "")
except ValueError:
    sys.exit(0)
if payload.get("tool_name") != "Bash":
    sys.exit(0)
command = str((payload.get("tool_input") or {}).get("command") or "")
files = r"(?:last-result|result|active-run|feature|delivery)\.json"
target = r"\S*" + files + r"\b"
patterns = [
    r">>?\s*" + target,                                   # cat > x.json, jq ... >> x.json
    r"\btee\b[^\n;&|]*" + target,                         # ... | tee x.json
    r"\b(?:cp|mv|install)\b[^\n;&|]*\s" + target,         # cp tmp x.json
    r"\bsed\b[^\n;&|]*-i[^\n;&|]*" + target,              # sed -i ... x.json
    r"open\(\s*\\?['\"][^'\"]*" + files + r"\\?['\"]\s*,\s*\\?['\"][wa]",  # open("x.json", "w"), quotes maybe \-escaped
]
for pat in patterns:
    m = re.search(pat, command)
    if m:
        print(m.group(0)[:120])
        break
PY
)"
[[ -n "$VERDICT" ]] || exit 0
echo "DENY: '$VERDICT' writes a loop-spec contract file by hand. The terminal result is published only by lib/cycle-result.sh (write, write-terminal) and feature state only by lib/feature-write.sh; a result those writers refuse is a run that has not earned it. Return to the cycle, or publish the honest status with --reason. (Disable: LOOP_SPEC_FORGERY_GUARD=0)" >&2
exit 2
