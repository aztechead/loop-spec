#!/usr/bin/env bash
# The outer loop follows fresh handoffs and fails closed on stale or failed sessions.
set -euo pipefail
if ! python3 -c "import tomllib" 2>/dev/null; then
  echo "SKIP: cycle launcher requires Python 3.11"
  exit 0
fi
root="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$root" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

plugin = Path(sys.argv[1])
with tempfile.TemporaryDirectory() as temp:
    base = Path(temp)
    profiles = base / "profiles"
    profiles.mkdir()
    fake = base / "fake.py"
    fake.write_text('''import json, os, pathlib, sys, time
assert os.environ["LOOP_SPEC_AUTONOMOUS"] == "1"
assert os.environ["LOOP_SPEC_NON_INTERACTIVE"] == "1"
assert os.environ["LOOP_SPEC_ANSWER_TITLE"] == "Pinned title"
p = pathlib.Path("count")
n = int(p.read_text()) + 1 if p.exists() else 1
p.write_text(str(n))
mode = os.environ["FAKE_MODE"]
if mode == "timeout": time.sleep(5)
if mode == "stale": sys.exit(0)
handoff = mode == "cap" or (mode == "success" and n == 1)
result = {"schema":1, "loopSpecVersion":"test", "phaseReached":"plan",
          "status":"paused" if handoff or mode == "pause" else "completed",
          "reason":"phase-handoff" if handoff else "human-gate" if mode == "pause" else None,
          "converged":not handoff and mode != "pause"}
if mode == "forged": result["status"] = "failed"
if mode == "escalate": result.update(status="escalated", converged=False)
pathlib.Path(".loop-spec/last-result.json").write_text(json.dumps(result))
sys.exit(7 if mode == "failed" else 0)
''')
    (profiles / "codex.toml").write_text(
        'binary = ' + json.dumps(sys.executable) + '\nlaunch_args = [' + json.dumps(str(fake)) + ']\n'
        'cycle_entry = "entry {task}"\ncycle_resume = "resume"\nmodel_flag = "--model"\n')
    for mode, expected, count in (("success", "completed", 2), ("stale", "failed", 1),
                                  ("cap", "exhausted", 2), ("failed", "failed", 1),
                                  ("pause", "paused", 1), ("timeout", "failed", 1),
                                  ("forged", "failed", 1), ("escalate", "escalated", 1)):
        root = base / mode
        root.mkdir()
        (root / ".loop-spec").mkdir()
        prompt = root / "task.txt"
        prompt.write_text("Implement a small change.")
        if mode == "stale":
            (root / ".loop-spec/last-result.json").write_text(json.dumps(
                {"schema":1, "loopSpecVersion":"test", "status":"completed", "converged":True}))
        env = dict(os.environ, LOOP_SPEC_SESSION_PROFILES=str(profiles), FAKE_MODE=mode,
                   LOOP_SPEC_ANSWER_TITLE="Pinned title")
        result = subprocess.run(["bash", str(plugin / "lib/cycle-launch.sh"), "--profile", "codex",
                                 "--cwd", str(root), "--prompt-file", str(prompt),
                                 "--max-invocations", "2", "--timeout", "0.2" if mode == "timeout" else "5"],
                                env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert result.returncode == (0 if mode == "success" else 1), result.stderr + result.stdout
        report = json.loads(result.stdout)
        assert report["status"] == expected, report
        assert report["invocations"] == count, report
        assert json.loads((root / ".loop-spec/launcher-result.json").read_text()) == report
        print("PASS: outer launcher " + mode)
PY
