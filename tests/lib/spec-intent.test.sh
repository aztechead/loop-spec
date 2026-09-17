#!/usr/bin/env bash
# Approval is recorded once, survives implementation edits, commits, and attempts to
# replace state, and before it exists the lint asks only that the sections it will
# cover are present.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$root" <<'PY'
import json
import os
import pathlib
import subprocess
import sys
import tempfile

plugin = pathlib.Path(sys.argv[1])
os.environ["LOOP_SPEC_CHECKPOINT_PR"] = "0"
sys.path.insert(0, str(plugin / "lib"))
from spec_intent import intent_digest

with tempfile.TemporaryDirectory() as temp:
    repo = pathlib.Path(temp)
    subprocess.run(["git", "init", "-q", temp], check=True)
    feature = repo / ".loop-spec/features/demo"
    docs = repo / "docs/loop-spec/features/demo"
    feature.mkdir(parents=True)
    docs.mkdir(parents=True)
    state = {"slug": "demo", "currentPhase": "spec", "autonomous": True}
    (feature / "feature.json").write_text(json.dumps(state))
    spec = docs / "SPEC.md"
    original = """---
route: full
unresolved_questions: []
---
# Demo
## Problem
Missing output.
## Goals
Return the requested output.
## Boundaries (what NOT to do)
Do not modify other commands.
## Constraints
Use existing helpers.
## Success criteria
### Good Enough
- [ ] The output check passes.
## Grounding
- none
"""
    spec.write_text(original)

    def call(script, *args, expected=0):
        result = subprocess.run(["bash", str(plugin / "lib" / script)] + list(args),
                                cwd=temp, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        assert result.returncode == expected, result.stdout
        return result.stdout

    call("artifact-lint.sh", "spec", str(spec), "--feature-dir", str(feature))
    spec.write_text(original.replace("Return the requested output.", "Return different output."))
    call("artifact-lint.sh", "spec", str(spec), "--feature-dir", str(feature))
    spec.write_text(original)
    call("cycle-driver.sh", "spec", "approve", "--feature-dir", str(feature), "--source", "autonomous")
    approval = json.loads((feature / "feature.json").read_text())["specApproval"]
    assert approval["source"] == "autonomous"
    assert approval["sha256"] == intent_digest(original)
    call("artifact-lint.sh", "spec", str(spec), "--feature-dir", str(feature))
    spec.write_text(original.replace("Use existing helpers.", "Reuse the parser."))
    call("artifact-lint.sh", "spec", str(spec), "--feature-dir", str(feature))
    spec.write_text(original.replace("Return the requested output.", "Return different output."))
    subprocess.run(["git", "add", "docs"], cwd=temp, check=True)
    subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.com",
                    "commit", "-qm", "Changed spec"], cwd=temp, check=True)
    assert "changed after approval" in call("artifact-lint.sh", "spec", str(spec),
                                            "--feature-dir", str(feature), expected=1)
    assert "phase entry refused" in call("cycle-driver.sh", "phase-begin", "spec", "--feature-dir", str(feature), expected=1)
    call("cycle-driver.sh", "spec", "approve", "--feature-dir", str(feature), "--source", "human", expected=1)
    call("feature-write.sh", "set", str(feature), "specApproval", "null", expected=1)
    call("feature-write.sh", str(feature), json.dumps(state), expected=1)
    spec.write_text(original)
    call("cycle-driver.sh", "spec", "approve", "--feature-dir", str(feature), "--source", "human")
    assert json.loads((feature / "feature.json").read_text())["specApproval"] == approval
    promoted = repo / ".loop-spec/features/promoted"
    promoted.mkdir()
    (promoted / "feature.json").write_text(json.dumps({"slug":"promoted"}))
    short = (plugin / "tests/fixtures/oneshot-SPEC.md").read_text()
    spec.write_text(short.replace("---\n", "---\nroute: full\n", 1))
    assert "non-empty goal" in call("artifact-lint.sh", "spec", str(spec),
                                    "--feature-dir", str(promoted), expected=1)
    attended = repo / ".loop-spec/features/attended"
    attended.mkdir()
    (attended / "feature.json").write_text(json.dumps({"slug": "attended", "currentPhase": "discuss"}))
    adocs = repo / "docs/loop-spec/features/attended"
    adocs.mkdir(parents=True)
    (adocs / "SPEC.md").write_text(original)
    call("cycle-driver.sh", "spec", "approve", "--feature-dir", str(attended))
    assert json.loads((attended / "feature.json").read_text())["specApproval"]["source"] == "human"
    for invalid in (original.replace("## Goals", "## Other"), original + "\n## Goals\nDuplicate\n"):
        try:
            intent_digest(invalid)
        except ValueError:
            pass
        else:
            raise AssertionError("missing/duplicate frozen section accepted")
print("PASS: pre-freeze edits pass lint, intent approval, tamper detection after commit, state protection, derived source, idempotency")
PY
