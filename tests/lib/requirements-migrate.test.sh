#!/usr/bin/env bash
# Offline regressions for the read-only legacy-to-v1 migration preview/status CLI.
# simplicity: the import list and repo()/tree_digest() fixture below repeat the
# git-init-a-temp-feature-directory shape tests/lib/spec-intent.test.sh already
# uses; no shared Python fixture module exists for bash-heredoc suites, and
# extracting one is a repo-wide restructuring this task does not own.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PYTHONPATH="$ROOT/lib" python3 - "$ROOT" <<'PY'
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

plugin = Path(sys.argv[1])
sys.path.insert(0, str(plugin / "lib"))

from requirements_migrate import build_preview, build_status
from spec_intent import intent_digest

SPEC = """---
route: full
unresolved_questions: []
criteria: {"The output check passes.": "bash tests/check.sh"}
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
- [ ] The second check passes with `bash tests/second.sh`.
### Exceptional
- [ ] A nicety.
## Grounding
- none
"""

PLAN = """# Plan

## Task DAG

| ID | Subject | BlockedBy |
|----|---------|-----------|
| task-001 | Do it | - |

## Tasks

### task-001: Do it

**Files:**
- lib/x.sh

**Verify:** `bash tests/x.test.sh` -> exit 0.

## Spec coverage

- The output check passes. -> task-001
- The second check passes with `bash tests/second.sh`. -> task-999
"""

VERIFICATION = "# VERIFICATION\n\n- The output check passes -> PASS\n"


def repo(spec=SPEC, plan=PLAN, verification=VERIFICATION, state=None, name="demo"):
    root = Path(tempfile.mkdtemp())
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    feature = root / ".loop-spec/features/demo"
    docs = root / "docs/loop-spec/features/demo"
    feature.mkdir(parents=True)
    docs.mkdir(parents=True)
    (docs / "SPEC.md").write_text(spec, encoding="utf-8")
    (docs / "PLAN.md").write_text(plan, encoding="utf-8")
    if verification is not None:
        (docs / "VERIFICATION.md").write_text(verification, encoding="utf-8")
    default_state = {"slug": "demo", "currentPhase": "execute",
                      "artifacts": {"spec": "docs/loop-spec/features/demo/SPEC.md",
                                    "plan": "docs/loop-spec/features/demo/PLAN.md",
                                    "verification": "docs/loop-spec/features/demo/VERIFICATION.md"}}
    if state:
        default_state.update(state)
    (feature / "feature.json").write_text(json.dumps(default_state), encoding="utf-8")
    subprocess.run(["git", "add", "-A"], cwd=root, check=True)
    subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "init"],
                    cwd=root, check=True)
    return root, feature


def tree_digest(root):
    """Hash every byte under root, .git included, so a preview call that
    writes anything anywhere is caught."""
    result = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        if path.is_file():
            result.update(str(path.relative_to(root)).encode())
            result.update(path.read_bytes())
    return result.hexdigest()


failures = []
checks = 0


def check(label, condition):
    global checks
    checks += 1
    if not condition:
        failures.append(label)


def refused(feature, label, matcher):
    """The one refuse-then-assert-the-diagnostic shape every AC3 case below shares."""
    try:
        build_preview(feature)
    except ValueError as exc:
        check(label, matcher(str(exc)))
    else:
        failures.append(label + " (not refused)")


# --- AC1: preview is pure and reproducible -------------------------------
root, feature = repo()
before = tree_digest(root)
first = build_preview(feature)
second = build_preview(feature)
after = tree_digest(root)
check("preview writes nothing to the repository tree", before == after)
check("preview twice gives byte-identical JSON",
      json.dumps(first, sort_keys=True) == json.dumps(second, sort_keys=True))
check("preview digest is stable across calls", first["previewDigest"] == second["previewDigest"])
check("status reports no marker before any migration", build_status(feature) == {"migration": "none"})

# --- AC2: original-order allocation, byte preservation, explicit-only scenarios, unresolved relations
allocations = sorted(first["proposedRequirementsContract"]["issued"])
check("GE IDs allocated in original document order", allocations == ["GE-001", "GE-002"])
check("requirement text carries the exact criterion text, nothing invented",
      "GE-001: The output check passes." in first["proposedSpec"]["text"]
      and "GE-002: The second check passes with `bash tests/second.sh`." in first["proposedSpec"]["text"])
check("each requirement gets exactly one SC-001 scenario derived from its own criterion text",
      first["proposedSpec"]["text"].count("SC-001:") == 2)
check("Goal/Boundary bytes are byte-identical to the original", intent_digest(first["proposedSpec"]["text"]) == intent_digest(SPEC))
check("explicit frontmatter command is carried into scenario_checks, never invented",
      '"GE-001/SC-001":{"command":"bash tests/check.sh"}' in first["proposedSpec"]["text"])
check("explicit inline backtick command is carried into scenario_checks",
      '"GE-002/SC-001":{"command":"bash tests/second.sh"}' in first["proposedSpec"]["text"])
unresolved = first["proposedPlan"]["unresolved"]
check("dangling task-999 mapping is reported unresolved by file/line, not silently mapped",
      any(u["reason"] == "dangling task reference" and u["line"] > 0
          and u["criterion"].startswith("The second check") for u in unresolved))
check("unresolved entries never invent a task or command",
      all(set(u) == {"file", "line", "criterion", "tasks", "reason"} for u in unresolved))
check("the unambiguous mapping is applied to task-001's PLAN text",
      '"requirement":"GE-001"' in first["proposedPlan"]["text"] and "task-001" in first["proposedPlan"]["text"])

# specApproval preservation: approve the original SPEC, then preview must keep the same intent digest
root2, feature2 = repo(state={"specApproval": {"source": "human", "sha256": intent_digest(SPEC)}})
approved_preview = build_preview(feature2)
check("an approved SPEC's Goal/Boundary bytes survive migration",
      intent_digest(approved_preview["proposedSpec"]["text"]) == intent_digest(SPEC))

# a candidate that could not preserve the approved intent must be refused, never silently rewritten
root3, feature3 = repo(spec=SPEC.replace("Return the requested output.", "Return a different output."),
                        state={"specApproval": {"source": "human", "sha256": intent_digest(SPEC)}})
refused(feature3, "refusal names the approval conflict", lambda msg: "approved intent" in msg)

# --- AC3: refuse before any write; VERIFICATION stays historical ----------
root4, feature4 = repo(state={"currentPhase": "completed"})
before4 = tree_digest(root4)
refused(feature4, "completed cycle is refused", lambda msg: "completed cycle" in msg)
check("refusing a completed cycle writes nothing", tree_digest(root4) == before4)

unsupported_spec = SPEC.replace("### Good Enough\n", "")
root5, feature5 = repo(spec=unsupported_spec)
before5 = tree_digest(root5)
refused(feature5, "missing Good Enough section is an unsupported shape", lambda msg: "Good Enough" in msg)
check("refusing an unsupported shape writes nothing", tree_digest(root5) == before5)

already_v1_spec = "---\nrequirements_version: 1\n" + SPEC[3:]
root6, feature6 = repo(spec=already_v1_spec)
refused(feature6, "a SPEC that already declares requirements_version is refused",
        lambda msg: "already declares requirements_version" in msg)

root7, feature7 = repo()
big = feature7.parent.parent.parent / "docs/loop-spec/features/demo/SPEC.md"
os.truncate(big, 16 * 1024 * 1024 + 1)
before7 = tree_digest(root7)
refused(feature7, "an oversized SPEC is refused with a file/line diagnostic",
        lambda msg: "SPEC.md:1:" in msg and "16 MiB" in msg)
check("refusing an oversized SPEC writes nothing", tree_digest(root7) == before7)

root8, feature8 = repo(state={"artifactPublication": {"version": 1, "generation": 0, "evidenceEpoch": 0,
                                                       "migration": None, "participantsVersion": 2}})
refused(feature8, "an unsupported participant is refused", lambda msg: "unsupported participant" in msg)

root9, feature9 = repo(state={"requirementsContract": {"version": 1, "format": "v1",
                                                        "owner": {"repository": "r", "feature": "demo"},
                                                        "inventoryDigest": None, "nextRequirementId": 1,
                                                        "issued": {}, "retired": [], "retiredScenarios": {}}})
refused(feature9, "a feature already on v1 is refused as nothing to migrate", lambda msg: "already v1" in msg)

historical = build_preview(feature)["historical"]
check("old VERIFICATION is listed historical with its own digest",
      historical["verification"] is not None
      and historical["verification"]["sha256"] == hashlib.sha256(VERIFICATION.encode()).hexdigest())
check("historical VERIFICATION note requires fresh observations", "fresh v1 observations" in historical["note"])

# CLI contract: apply/resume/rollback are fixed but not implemented in this revision.
launcher = plugin / "lib" / "requirements-migrate.sh"
for command in ("apply", "resume", "rollback"):
    result = subprocess.run(["bash", str(launcher), command, "--feature-dir", str(feature)],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    check("%s exits 2 (not implemented in this revision)" % command, result.returncode == 2)
    check("%s names itself unimplemented" % command, "not implemented in this revision" in result.stdout)

preview_stdout = subprocess.run(["bash", str(launcher), "preview", "--feature-dir", str(feature)],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
check("the launcher's preview exits 0", preview_stdout.returncode == 0)
check("the launcher's preview JSON matches the module call",
      json.loads(preview_stdout.stdout)["previewDigest"] == first["previewDigest"])

assert not failures, "FAILURES:\n  " + "\n  ".join(failures)
print("PASS: requirements-migrate preview/status regressions (%d checks)" % checks)
PY
