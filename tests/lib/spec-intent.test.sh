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

# AC3: under a v1 contract, implementation-only writes never move the frozen Goals and
# Boundaries bytes or the approval record; a Goal edit is refused exactly as legacy.
python3 - "$root" <<'PY'
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

plugin = pathlib.Path(sys.argv[1])
os.environ["LOOP_SPEC_CHECKPOINT_PR"] = "0"
sys.path.insert(0, str(plugin / "lib"))
from requirements import initialize_contract, parse_spec, reconcile_inventory

owner = {"repository": "stable-repo", "feature": "v1demo"}
contract = initialize_contract(owner, "v1")

with tempfile.TemporaryDirectory() as temp:
    repo = pathlib.Path(temp)
    subprocess.run(["git", "init", "-q", temp], check=True)
    feature = repo / ".loop-spec/features/v1demo"
    docs = repo / "docs/loop-spec/features/v1demo"
    feature.mkdir(parents=True)
    docs.mkdir(parents=True)
    state = {"slug": "v1demo", "currentPhase": "spec", "autonomous": True,
             "requirementsContract": contract,
             "artifactPublication": {"version": 1, "generation": 0, "evidenceEpoch": 0,
                                      "migration": None, "participantsVersion": 1}}
    (feature / "feature.json").write_text(json.dumps(state))
    spec = docs / "SPEC.md"
    original = """---
route: full
unresolved_questions: []
requirements_version: 1
requirements_owner: {"repository":"stable-repo","feature":"v1demo"}
scenario_checks: {}
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

## Implementation notes

- src/output.py: not yet touched

## Success criteria

### Good Enough

- [ ] GE-001: The output check passes.
  - SC-001: Running the check exits 0.

## Grounding

- none
"""
    spec.write_text(original)
    # Mirror the reconciliation a real `spec write` ingest already performed: the
    # fixture's own GE-001 must be on the ledger before a fill can allocate GE-002.
    contract = reconcile_inventory(contract, parse_spec(original, str(spec), contract))
    state["requirementsContract"] = contract
    (feature / "feature.json").write_text(json.dumps(state))

    def call(script, *args, expected=0):
        result = subprocess.run(["bash", str(plugin / "lib" / script)] + list(args),
                                cwd=temp, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        assert result.returncode == expected, result.stdout
        return result.stdout

    def section(text, heading):
        m = re.search(r"^## %s\s*$\n(.*?)(?=^## |\Z)" % re.escape(heading), text, re.M | re.S)
        return m.group(0)

    call("cycle-driver.sh", "spec", "approve", "--feature-dir", str(feature), "--source", "autonomous")
    approval_before = json.loads((feature / "feature.json").read_text())["specApproval"]
    goals_before = section(original, "Goals")
    boundaries_before = section(original, "Boundaries (what NOT to do)")

    inputs = json.dumps({"version": 1, "toolchains": [], "localInputs": [], "externalInputs": [], "sensitiveInputs": []})
    call("cycle-driver.sh", "spec", "fill", "--feature-dir", str(feature),
         "--command", "true", "--expect", "a second outcome", "--execution-inputs", inputs)
    call("cycle-driver.sh", "spec", "fill", "--feature-dir", str(feature),
         "--grounding", "src/output.py:1 - the one code path")
    call("cycle-driver.sh", "spec", "fill", "--feature-dir", str(feature),
         "--file", "src/output.py", "--note", "wires the new outcome")

    after = spec.read_text()
    assert "GE-002" in after, "batch-free fills still allocate a fresh stable ID: " + after
    assert section(after, "Goals") == goals_before, "an implementation-only fill moved Goals"
    assert section(after, "Boundaries (what NOT to do)") == boundaries_before, \
        "an implementation-only fill moved Boundaries"
    approval_after = json.loads((feature / "feature.json").read_text())["specApproval"]
    assert approval_after == approval_before, "an implementation-only fill moved specApproval"
    print("PASS: v1 implementation-only fills preserve Goals/Boundaries bytes and specApproval")

    changed_goal = after.replace("Return the requested output.", "Return a different output.")
    draft = repo / "draft.md"
    draft.write_text(changed_goal)
    call("cycle-driver.sh", "spec", "write", "--feature-dir", str(feature), "--file", str(draft))
    subprocess.run(["git", "add", "docs"], cwd=temp, check=True)
    subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.com",
                    "commit", "-qm", "Changed goal"], cwd=temp, check=True)
    assert "changed after approval" in call("artifact-lint.sh", "spec", str(spec),
                                            "--feature-dir", str(feature), expected=1)
    print("PASS: v1 Goal edit is refused by the intent check exactly as legacy")
PY
