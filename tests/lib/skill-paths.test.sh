#!/usr/bin/env bash
# Execute the source-path export supplied by the registered session-start hook.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$root" <<'PY'
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
manifest = json.loads((root / "hooks/hooks.json").read_text())
commands = [hook["command"] for group in manifest["hooks"]["SessionStart"] for hook in group["hooks"]]
registered = next(command for command in commands if command.endswith("/skill-paths-inject.sh"))
hook = registered.replace("${CLAUDE_PLUGIN_ROOT}", str(root))
with tempfile.TemporaryDirectory() as temp:
    package = Path(temp) / "package with ' quotes"
    (package / "lib").mkdir(parents=True)
    (package / "lib/probe.sh").write_text("printf 'resolved\\n'\n")
    for name in ("spec", "loop-runner"):
        (package / "skills" / name / "references").mkdir(parents=True)
        (package / "skills" / name / "references/local.md").write_text(name)
    for harness in ("claude", "codex"):
        env = dict(os.environ, CLAUDE_PLUGIN_ROOT=str(package), PLUGIN_ROOT=str(package), LOOP_SPEC_HARNESS=harness)
        result = subprocess.run(["bash", hook], env=env, text=True, capture_output=True, check=True)
        context = json.loads(result.stdout)["hookSpecificOutput"]["additionalContext"]
        export = re.search(r"```bash\n(.*?)\n```", context, re.S).group(1)
        for name in ("spec", "loop-runner"):
            command = export.replace("<skill-name>", name)
            command += '\ncat "$LOOP_SPEC_SKILL_DIR/references/local.md"\nbash "$LOOP_SPEC_SKILL_DIR/../../lib/probe.sh"'
            observed = subprocess.run(["bash", "-c", command], cwd=temp, env=env, text=True, capture_output=True, check=True)
            assert observed.stdout == name + "resolved\n", observed
    for harness in ("opencode", "adk"):
        result = subprocess.run(["bash", hook], env=dict(os.environ, LOOP_SPEC_HARNESS=harness), text=True, capture_output=True, check=True)
        assert not result.stdout
print("PASS: registered path exports resolve shared and skill-local files across fresh shells, including quoted paths")
PY
