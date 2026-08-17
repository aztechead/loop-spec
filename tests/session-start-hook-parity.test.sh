#!/usr/bin/env bash
# The Claude manifest is the lifecycle contract. Every adapter that claims a
# SessionStart bridge must carry that exact ordered script list.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

python3 - <<'PY'
import ast
import json
from pathlib import Path
import re

root = Path(".")
manifest = json.loads((root / "hooks/hooks.json").read_text(encoding="utf-8"))
prefix = "${CLAUDE_PLUGIN_ROOT}/"
expected = []
for registration in manifest["hooks"]["SessionStart"]:
    for hook in registration["hooks"]:
        command = hook.get("command", "")
        if not command.startswith(prefix):
            raise SystemExit(f"FAIL: SessionStart command is not package-relative: {command}")
        expected.append(command[len(prefix):])

bridge_tree = ast.parse(
    (root / "extensions/adk/loop_spec_adk/bridge.py").read_text(encoding="utf-8")
)
adk = None
for node in bridge_tree.body:
    if isinstance(node, ast.Assign) and any(
        isinstance(target, ast.Name) and target.id == "SESSION_START_HOOKS"
        for target in node.targets
    ):
        adk = list(ast.literal_eval(node.value))
        break
if adk is None:
    raise SystemExit("FAIL: ADK SESSION_START_HOOKS assignment is missing")

opencode_source = (root / "extensions/opencode/loop-spec.ts").read_text(encoding="utf-8")
match = re.search(r"const SESSION_START_SCRIPTS = \[(.*?)\];", opencode_source, re.S)
if not match:
    raise SystemExit("FAIL: OpenCode SESSION_START_SCRIPTS assignment is missing")
opencode = re.findall(r'"([^"]+)"', match.group(1))

failures = 0
for name, actual in (("ADK", adk), ("OpenCode", opencode)):
    if actual == expected:
        print(f"PASS: {name} SessionStart scripts exactly match hooks/hooks.json")
    else:
        failures += 1
        print(f"FAIL: {name} SessionStart scripts differ")
        print(f"  expected: {expected}")
        print(f"  actual:   {actual}")

if len(expected) == len(set(expected)):
    print("PASS: canonical SessionStart list has no duplicates")
else:
    failures += 1
    print("FAIL: canonical SessionStart list contains duplicates")

missing = [path for path in expected if not (root / path).is_file()]
if not missing:
    print("PASS: every canonical SessionStart script exists")
else:
    failures += 1
    print(f"FAIL: missing SessionStart scripts: {missing}")

print(f"Results: {4 - failures} passed, {failures} failed")
raise SystemExit(1 if failures else 0)
PY
