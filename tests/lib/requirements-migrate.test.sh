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

from requirements_migrate import apply, build_preview, build_status, resume, rollback
from requirements import bootstrap_state
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


def repo(spec=SPEC, plan=PLAN, verification=VERIFICATION, state=None, name="demo", bootstrap=True):
    """bootstrap=True (the default, and apply's own precondition) mirrors an
    incomplete legacy cycle that has already been through one ordinary phase
    transition, so artifactPublication exists; a handful of task-010 fixtures
    below pass bootstrap=False or supply their own artifactPublication to
    exercise a state that never got that far."""
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
    default_state = {"slug": "demo", "currentPhase": "execute", "schemaVersion": 7,
                      "artifacts": {"spec": "docs/loop-spec/features/demo/SPEC.md",
                                    "plan": "docs/loop-spec/features/demo/PLAN.md",
                                    "verification": "docs/loop-spec/features/demo/VERIFICATION.md"}}
    if state:
        default_state.update(state)
    if bootstrap and "artifactPublication" not in default_state:
        default_state = bootstrap_state(default_state, {"repository": "repo-" + name, "feature": "demo"}, format="legacy")
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

# CLI contract: bad invocation (missing --preview/--digest/--transaction) is exit 2.
launcher = plugin / "lib" / "requirements-migrate.sh"
for command in ("apply", "resume", "rollback"):
    result = subprocess.run(["bash", str(launcher), command, "--feature-dir", str(feature)],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    check("%s without its required flag exits 2" % command, result.returncode == 2)

preview_stdout = subprocess.run(["bash", str(launcher), "preview", "--feature-dir", str(feature)],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
check("the launcher's preview exits 0", preview_stdout.returncode == 0)
check("the launcher's preview JSON matches the module call",
      json.loads(preview_stdout.stdout)["previewDigest"] == first["previewDigest"])


# --- task-011: apply, resume, rollback -----------------------------------

def new_transaction(**state_overrides):
    root, feature = repo(state=state_overrides or None)
    preview = build_preview(feature)
    preview_path = feature / "preview.json"
    preview_path.write_text(json.dumps(preview, sort_keys=True), encoding="utf-8")
    return root, feature, preview, preview_path


# AC1: apply rejects a changed source, a stale --digest, a second simultaneous
# apply, and a completed cycle -- all before replacing any artifact; originals
# land byte-for-byte in immutable generation storage.
root, feature, preview, preview_path = new_transaction()
(feature.parent.parent.parent / "docs/loop-spec/features/demo/SPEC.md").write_text(
    SPEC.replace("Return the requested output.", "Return a changed output."), encoding="utf-8")
try:
    apply(feature, preview_path, preview["previewDigest"])
    failures.append("apply accepted a changed SPEC source (not refused)")
except ValueError as exc:
    check("apply refuses a source changed since preview, naming the differing key",
          "changed since this preview was approved" in str(exc))
checks += 1
(feature.parent.parent.parent / "docs/loop-spec/features/demo/SPEC.md").write_text(SPEC, encoding="utf-8")

root, feature, preview, preview_path = new_transaction()
try:
    apply(feature, preview_path, "0" * 64)
    failures.append("apply accepted a --digest that does not match the preview file")
except ValueError as exc:
    check("apply refuses a stale/incorrect --digest", "does not match" in str(exc))
checks += 1

root, feature, preview, preview_path = new_transaction()
before_apply = tree_digest(root)
result = apply(feature, preview_path, preview["previewDigest"])
check("apply commits the transaction", result["phase"] == "committed")
try:
    apply(feature, preview_path, preview["previewDigest"])
    failures.append("a second simultaneous apply of an already-applied preview was accepted")
except ValueError as exc:
    check("a second apply of the same preview is refused (already v1)", "already v1" in str(exc))
checks += 1
originals_dir = feature / "migration-generations" / preview["id"] / "originals"
check("the original SPEC.md is preserved byte-for-byte",
      (originals_dir / "SPEC.md").read_bytes().decode("utf-8") == SPEC)
check("the original PLAN.md is preserved byte-for-byte",
      (originals_dir / "PLAN.md").read_bytes().decode("utf-8") == PLAN)
check("the preserved originals are read-only (0400)",
      oct(originals_dir.joinpath("SPEC.md").stat().st_mode & 0o777) == "0o400")
new_state = json.loads((feature / "feature.json").read_text())
check("the applied contract is v1", new_state["requirementsContract"]["format"] == "v1")
check("generation advanced twice (marker + final publish), never decreasing",
      new_state["artifactPublication"]["generation"] >= 2)
check("evidenceEpoch advanced by exactly one", new_state["artifactPublication"]["evidenceEpoch"] == 1)
check("the migration marker is cleared on commit", new_state["artifactPublication"]["migration"] is None)

root, feature, preview, preview_path = new_transaction()
state_path = feature / "feature.json"
state_now = json.loads(state_path.read_text())
state_now["currentPhase"] = "completed"
state_path.write_text(json.dumps(state_now), encoding="utf-8")
try:
    apply(feature, preview_path, preview["previewDigest"])
    failures.append("apply accepted a cycle completed after the preview was taken")
except ValueError as exc:
    check("apply refuses a cycle completed since the preview, before touching any artifact",
          "completed cycle" in str(exc))
checks += 1
check("refusing a completed cycle at apply-time leaves no migration-generations directory",
      not (feature / "migration-generations").exists())

root, feature, preview, preview_path = new_transaction()
state_path = feature / "feature.json"
state_now = json.loads(state_path.read_text())
state_now["artifactPublication"]["participantsVersion"] = 2
state_path.write_text(json.dumps(state_now), encoding="utf-8")
try:
    apply(feature, preview_path, preview["previewDigest"])
    failures.append("apply accepted an unsupported participant")
except ValueError as exc:
    check("apply refuses an unsupported participant", "participantsVersion" in str(exc))
checks += 1

# AC2: failure injection at every documented boundary; status/resume finishes
# the same transaction without reallocating IDs, and replay is idempotent.
for point in ("backup", "marker", "spec", "plan", "state", "receipt"):
    root, feature, preview, preview_path = new_transaction()

    def crash(name, point=point):
        if name == point:
            raise RuntimeError("injected failure at " + point)

    try:
        apply(feature, preview_path, preview["previewDigest"], failure=crash)
        failures.append("apply at %s did not raise" % point)
    except RuntimeError:
        pass
    checks += 1
    transaction_dir = feature / "migration-generations" / preview["id"]
    if point == "backup":
        # nothing durable yet -- the transaction never became visible; re-apply
        check("status reports no transaction after a backup-only crash",
              build_status(feature)["migration"] == "none")
        finished = apply(feature, preview_path, preview["previewDigest"])
    else:
        # "state" and "receipt" fire once the final publish already cleared
        # feature.json's migration field, so the journal on disk -- not the
        # top-level migration field -- is the durable proof a transaction is
        # still pending resume.
        check("the transaction journal survives a %s crash" % point, (transaction_dir / "marker.json").is_file())
        finished = resume(feature, preview["id"])
        checks += 1
    check("%s: resume/re-apply finishes the transaction" % point, finished["phase"] == "committed")
    check("%s: the same transaction ID is reused, never reallocated" % point, finished["transaction"] == preview["id"])
    finished_state = json.loads((feature / "feature.json").read_text())
    check("%s: the finished contract is v1" % point, finished_state["requirementsContract"]["format"] == "v1")
    replay = resume(feature, preview["id"])
    check("%s: replay of a finished transaction is idempotent" % point,
          replay == {"transaction": preview["id"], "phase": "committed", "resumed": False})

# AC3: a legacy reader's ingress token captured before the marker becomes
# durable cannot publish after migration (stale by generation).
root, feature, preview, preview_path = new_transaction()
sys.path.insert(0, str(plugin / "lib"))
import feature_write
stale_token = feature_write.begin_operation(feature)
apply(feature, preview_path, preview["previewDigest"])
try:
    feature_write.write_operation(feature, "set", "blocked", ("currentPhase",), token=stale_token)
    failures.append("a stale pre-migration token was accepted after migration")
except ValueError as exc:
    check("a legacy reader's stale token is refused after migration", "stale" in str(exc))
checks += 1

# Unfinished migration blocks phase entry (phase-exit's own equivalent case is
# already pinned at tests/lib/phase-exit.test.sh:585-596, exercising the exact
# artifactPublication.migration field apply sets).
root2, feature2, preview2, preview_path2 = new_transaction()

def crash_at_marker(point):
    if point == "marker":
        raise RuntimeError("stop mid-migration")

try:
    apply(feature2, preview_path2, preview2["previewDigest"], failure=crash_at_marker)
except RuntimeError:
    pass
entry = subprocess.run(["bash", str(plugin / "lib" / "phase-entry.sh"), "execute", "--feature-dir", str(feature2)],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
check("an unfinished migration blocks phase-entry.sh", "publication" in entry.stdout and entry.returncode != 0)
resume(feature2, preview2["id"])

# AC4: rollback restores originals only while the migrated files are
# untouched, refuses actionable conflicts, and never rolls generation back.
root, feature, preview, preview_path = new_transaction()
result = apply(feature, preview_path, preview["previewDigest"])
post_apply_state = json.loads((feature / "feature.json").read_text())["artifactPublication"]
before_generation, before_epoch = post_apply_state["generation"], post_apply_state["evidenceEpoch"]
undone = rollback(feature, result["transaction"])
check("rollback reports the transaction rolled back", undone["phase"] == "rolled-back")
spec_path = feature.parent.parent.parent / "docs/loop-spec/features/demo/SPEC.md"
check("rollback restores the original SPEC bytes", spec_path.read_text(encoding="utf-8") == SPEC)
plan_path = feature.parent.parent.parent / "docs/loop-spec/features/demo/PLAN.md"
check("rollback restores the original PLAN bytes", plan_path.read_text(encoding="utf-8") == PLAN)
rolled_back_state = json.loads((feature / "feature.json").read_text())
check("rollback restores the pre-migration contract", rolled_back_state["requirementsContract"]["format"] == "legacy")
check("rollback advances generation, never backward",
      rolled_back_state["artifactPublication"]["generation"] == before_generation + 1)
check("rollback advances evidenceEpoch, never backward",
      rolled_back_state["artifactPublication"]["evidenceEpoch"] == before_epoch + 1)
try:
    rollback(feature, result["transaction"])
    failures.append("a second rollback of an already-rolled-back transaction was accepted")
except ValueError as exc:
    check("a second rollback refuses (not committed)", "not committed" in str(exc))
checks += 1

root, feature, preview, preview_path = new_transaction()
result = apply(feature, preview_path, preview["previewDigest"])
spec_path = feature.parent.parent.parent / "docs/loop-spec/features/demo/SPEC.md"
edited = spec_path.read_text(encoding="utf-8") + "\nedited by hand after migration\n"
spec_path.write_text(edited, encoding="utf-8")
try:
    rollback(feature, result["transaction"])
    failures.append("rollback silently overwrote a post-migration hand edit")
except ValueError as exc:
    message = str(exc)
    check("rollback refuses a later edit, naming the file",
          "SPEC.md" in message and "refuses changed artifact" in message)
    check("rollback's conflict names both the expected and found hash",
          "expected" in message and "found" in message)
checks += 1
check("rollback's conflict refusal leaves the hand edit untouched", spec_path.read_text(encoding="utf-8") == edited)

assert not failures, "FAILURES:\n  " + "\n  ".join(failures)
print("PASS: requirements-migrate preview/status/apply/resume/rollback regressions (%d checks)" % checks)
PY
