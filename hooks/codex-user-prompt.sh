#!/usr/bin/env bash
# Codex UserPromptSubmit: stamp LOOP_SPEC_HARNESS=codex for plugin hooks
# that only receive PLUGIN_ROOT, then run the shared done-criteria inject.
# Fail-open: a broken inject must not block the prompt.
set -euo pipefail
trap 'exit 0' ERR

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

printf '%s' "$input" | bash "$PLUGIN_ROOT/hooks/team/done-criteria.sh"
