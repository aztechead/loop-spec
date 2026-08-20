#!/usr/bin/env bash
# Codex SessionStart: export the loop-spec env contract, then run the same
# ordered inject scripts Claude Code registers in hooks/hooks.json.
#
# Codex plugin hooks receive PLUGIN_ROOT (and CLAUDE_PLUGIN_ROOT as a
# compatibility alias). They do not stamp LOOP_SPEC_HARNESS into the model's
# shell tool — that is hooks/codex-shell-env.sh plus the installer-written
# shell_environment_policy.set block. This script only has to (1) identify
# the harness for the inject scripts themselves and (2) merge their
# additionalContext onto stdout in the Codex SessionStart shape.
#
# Canonical script list — keep in lockstep with hooks/hooks.json SessionStart:
# SESSION_START_SCRIPTS below is what tests/session-start-hook-parity.test.sh
# reads. Adding a Claude SessionStart hook without adding it here is a
# contract break.
#
# Fail-open: a broken inject must not block the session.
set -euo pipefail
trap 'printf "{}\n"; exit 0' ERR

# Canonical SessionStart scripts — keep in lockstep with hooks/hooks.json
SESSION_START_SCRIPTS=(
  hooks/team/discipline-inject.sh
  hooks/team/grill-inject.sh
  hooks/team/simplicity-inject.sh
  hooks/team/human-code-inject.sh
  hooks/team/rules-inject.sh
  hooks/team/micro-inject.sh
)

PLUGIN_ROOT="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
export PLUGIN_ROOT
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$PLUGIN_ROOT}"
export LOOP_SPEC_HARNESS=codex

input=""
if [ ! -t 0 ]; then
  input="$(cat 2>/dev/null || true)"
fi
cwd="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print(d.get("cwd") or "")
' 2>/dev/null || true)"
export CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-${cwd:-$PWD}}"

contexts=()
contexts+=("loop-spec Codex harness is active. Apply skills/shared/codex-harness.md for tool, dispatch, HITL, and execution-root substitutions. Plugin root: ${PLUGIN_ROOT}. AskUserQuestion maps to request_user_input: when a human is attached, call it and wait through SPEC, DISCUSS, and PLAN. Do not self-answer unless autonomous or LOOP_SPEC_NON_INTERACTIVE=1. If request_user_input is missing, print the question with numbered options and end the turn.")

stdin_file="$(mktemp "${TMPDIR:-/tmp}/loop-spec-codex-session-XXXXXX")"
trap 'rm -f "$stdin_file"; printf "{}\n"; exit 0' ERR
printf '%s' "$input" > "$stdin_file"

for rel in "${SESSION_START_SCRIPTS[@]}"; do
  script="$PLUGIN_ROOT/$rel"
  [[ -f "$script" ]] || continue
  out="$(LOOP_SPEC_HARNESS=codex CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
         CLAUDE_PROJECT_DIR="$CLAUDE_PROJECT_DIR" \
         bash "$script" < "$stdin_file" 2>/dev/null || true)"
  extra="$(printf '%s' "$out" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    raise SystemExit
try:
    d = json.loads(raw)
except Exception:
    print(raw)
    raise SystemExit
ctx = (
    (d.get("hookSpecificOutput") or {}).get("additionalContext")
    or d.get("additionalContext")
    or ""
)
if ctx:
    print(ctx)
' 2>/dev/null || true)"
  [[ -n "$extra" ]] && contexts+=("$extra")
done
rm -f "$stdin_file"

merged="$(printf '%s\n\n' "${contexts[@]}")"
python3 -c '
import json, sys
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": sys.argv[1],
    }
}))
' "$merged"
