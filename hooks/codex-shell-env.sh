#!/usr/bin/env bash
# Codex PreToolUse (Bash): prefix LOOP_SPEC_HARNESS / CLAUDE_PLUGIN_ROOT /
# CLAUDE_PROJECT_DIR / CLAUDE_SKILL_DIR onto the command the model is about
# to run. Codex has no shell.env plugin hook; this is the deterministic
# injection into every shell tool call.
#
# CLAUDE_SKILL_DIR defaults to $PLUGIN_ROOT/skills/cycle so
# ${CLAUDE_SKILL_DIR}/../../lib/... resolves to the package lib/ from any
# skill (every skill lives one directory under skills/). Skill-local files
# still need the re-export rule in skills/shared/codex-harness.md.
#
# Fail-open: malformed stdin or a missing command leaves the call unchanged.
set -euo pipefail
trap 'exit 0' ERR

PLUGIN_ROOT="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"

input=""
if [ ! -t 0 ]; then
  input="$(cat 2>/dev/null || true)"
fi
[[ -n "$input" ]] || exit 0

stdin_file="$(mktemp "${TMPDIR:-/tmp}/loop-spec-codex-shell-XXXXXX")"
trap 'rm -f "$stdin_file"; exit 0' EXIT ERR
printf '%s' "$input" > "$stdin_file"

# Heredoc would steal stdin from the JSON payload; read it from the temp file.
python3 - "$PLUGIN_ROOT" "$stdin_file" <<'PY'
import json, os, shlex, sys

plugin_root, path = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as fh:
        payload = json.load(fh)
except Exception:
    raise SystemExit(0)

if payload.get("tool_name") not in ("Bash", "bash"):
    raise SystemExit(0)

tool_input = payload.get("tool_input") or {}
command = tool_input.get("command")
if not isinstance(command, str) or not command.strip():
    raise SystemExit(0)

if "LOOP_SPEC_HARNESS=codex" in command:
    raise SystemExit(0)

cwd = payload.get("cwd") or os.getcwd()
skill_dir = os.environ.get("CLAUDE_SKILL_DIR") or os.path.join(plugin_root, "skills", "cycle")
prefix = " ".join((
    "export LOOP_SPEC_HARNESS=codex",
    "CLAUDE_PLUGIN_ROOT=" + shlex.quote(plugin_root),
    "CLAUDE_PROJECT_DIR=" + shlex.quote(cwd),
    "CLAUDE_SKILL_DIR=" + shlex.quote(skill_dir),
))
updated = dict(tool_input)
updated["command"] = prefix + "\n" + command
json.dump({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "allow",
        "updatedInput": updated,
    }
}, sys.stdout)
print()
PY
