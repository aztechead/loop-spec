#!/usr/bin/env bash
# Supply source-skill paths to harnesses that need shell exports.
set -euo pipefail
case "${LOOP_SPEC_HARNESS:-claude}" in opencode|adk) exit 0 ;; esac
plugin_root="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
python3 - "$plugin_root" <<'PY'
import json
import os
import shlex
import sys

root = os.path.realpath(sys.argv[1])
command = "export LOOP_SPEC_SKILL_DIR=" + shlex.quote(os.path.join(root, "skills", "<skill-name>"))
context = (
    "loop-spec skill paths: Before each shell call that uses a bundled skill path, "
    "set LOOP_SPEC_SKILL_DIR to the active source skill's directory. "
    "Replace <skill-name> below with the source skill name, such as spec or loop-runner. "
    "Use the skill whose instructions you are executing, including after a cross-skill read.\n"
    "```bash\n" + command + "\n```\n"
    "Claude Code's native CLAUDE_SKILL_DIR substitution remains available for older integrations. "
    "Shared loop-spec instructions use LOOP_SPEC_SKILL_DIR. "
    "Rendered phase snapshots already contain absolute paths and need no export."
)
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": context}}))
PY
