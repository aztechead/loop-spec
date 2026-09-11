#!/usr/bin/env bash
# Offline execution_observation.py regressions: bounded/hashed command capture, the
# clean-tree and declared-input freshness checks that decide PASS/FAIL, and the
# publication-generation-vs-evidenceEpoch freshness distinction (task-007).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PYTHONPATH="$ROOT/lib" python3 - <<'TEST'
import json
import os
import subprocess
import tempfile
import time
from pathlib import Path

from execution_observation import observe, validate_record, read_output_digest, FRESHNESS_FIELDS
import artifact_publication as ap

failures = []


def check(name, condition):
    if not condition:
        failures.append(name)


def workdir(prefix="fixture"):
    return Path(tempfile.mkdtemp(prefix="loop-spec-execution-observation-" + prefix + "-"))


def git_repo():
    root = workdir("repo")
    subprocess.run(["git", "init", "-q"], cwd=root, check=True)
    subprocess.run(["git", "config", "user.email", "a@a.com"], cwd=root, check=True)
    subprocess.run(["git", "config", "user.name", "a"], cwd=root, check=True)
    (root / "tracked.txt").write_text("hello\n")
    subprocess.run(["git", "add", "-A"], cwd=root, check=True)
    subprocess.run(["git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "init"], cwd=root, check=True)
    return root


def feature_dir(generation=0, evidence_epoch=0):
    fd = workdir("feature")
    (fd / "SPEC.md").write_text("# spec v1\n")
    (fd / "PLAN.md").write_text("# plan v1\n")
    state = {"slug": "fixture", "currentPhase": "oneshot", "artifacts": {"spec": "SPEC.md", "plan": "PLAN.md"},
             "artifactPublication": {"version": 1, "generation": generation, "evidenceEpoch": evidence_epoch,
                                      "migration": None, "participantsVersion": 1}}
    (fd / "feature.json").write_text(json.dumps(state))
    return fd


def legacy_binding(row="GE-001"):
    return {"owner": None, "requirement": row, "revision": None, "scenario": None}


def bump_evidence_epoch(fd, value):
    state = json.loads((fd / "feature.json").read_text())
    state["artifactPublication"]["evidenceEpoch"] = value
    (fd / "feature.json").write_text(json.dumps(state))


def current_for(record, fd):
    """The freshness tuple validate_record compares, recomputed fresh -- exactly
    what a caller (a test, or the driver's own next `verification run`) would
    build from a re-read of state/SPEC/PLAN/the output file, never from the
    record's own claims about itself."""
    state = json.loads((fd / "feature.json").read_text())
    current = {key: record[key] for key in FRESHNESS_FIELDS}
    current["evidenceEpoch"] = state["artifactPublication"]["evidenceEpoch"]
    current["outputDigest"] = read_output_digest(fd, record)
    return current

# --- AC1: exit 0, identical HEAD/inputs/generation -> PASS ------------------------
root = git_repo()
fd = feature_dir()
record = observe(fd, root, legacy_binding(), "exit 0", None)
check("AC1: a clean exit 0 is PASS", record["status"] == "PASS")
check("AC1: PASS carries no failure reason", record["failureReason"] is None)
check("AC1: examined HEAD is unchanged", record["examinedHeads"][0]["before"] == record["examinedHeads"][0]["after"])
check("AC1: environment is unknown on the legacy route", record["environment"]["status"] == "unknown")
check("AC1: eligibleForV1 is false on the legacy route", record["eligibleForV1"] is False)
check("AC1: the record file lands under observations/", (fd / "observations" / (record["executionId"] + ".json")).is_file())
check("AC1: the output spool lands next to it", (fd / record["output"]["path"]).is_file())
eligible, reasons = validate_record(record, current_for(record, fd))
check("AC1: an unchanged record validates eligible", eligible)
check("AC1: an eligible record names no reasons", reasons == [])

# A source edit during the command
edited = observe(fd, root, legacy_binding("GE-002"), "echo more >> tracked.txt", None)
check("AC1: a source edit during the command is non-PASS", edited["status"] == "FAIL")
check("AC1: the reason names commit-or-restore", "commit or restore" in (edited["failureReason"] or ""))
subprocess.run(["git", "checkout", "--", "tracked.txt"], cwd=root, check=True)

# A new non-ignored untracked file
untracked = observe(fd, root, legacy_binding("GE-003"), "touch new-untracked.txt", None)
check("AC1: a new untracked file during the command is non-PASS", untracked["status"] == "FAIL")
check("AC1: the reason names the new path", "new-untracked.txt" in (untracked["failureReason"] or ""))
os.remove(root / "new-untracked.txt")

# A changed SPEC.md/PLAN.md hash
spec_changed = observe(fd, root, legacy_binding("GE-004"),
                        "printf 'changed\\n' >> " + str(fd / "SPEC.md"), None)
check("AC1: a SPEC.md edit during the command is non-PASS", spec_changed["status"] == "FAIL")
check("AC1: the reason names the authoring artifact", "authoring artifact" in (spec_changed["failureReason"] or ""))
(fd / "SPEC.md").write_text("# spec v1\n")

# An unknown/unavailable environment identity (the v1 route)
bad_contract = {"version": 1, "toolchains": [], "localInputs": [], "externalInputs": [
    {"name": "svc", "argv": ["python3", "-c", "print('not json')"], "expectedIdentity": ""}], "sensitiveInputs": []}
unknown_env = observe(fd, root, {"owner": {"repository": "r", "feature": "fixture"}, "requirement": "GE-005",
                                  "revision": "a" * 64, "scenario": "SC-001"}, "exit 0", bad_contract)
check("AC1: an unavailable external identity is non-PASS", unknown_env["status"] == "FAIL")
check("AC1: eligibleForV1 is true once a contract is declared", unknown_env["eligibleForV1"] is True)
check("AC1: the reason names the unavailable input", "unavailable" in (unknown_env["failureReason"] or ""))
check("AC1: environment is recorded unknown, not silently dropped", unknown_env["environment"]["status"] == "unknown")

# --- AC2: a verbose child stays within the byte ceiling and display tail ---------
verbose = observe(fd, root, legacy_binding("GE-006"),
                   "python3 -c \"import sys; sys.stdout.write('x' * 5000000)\"", None,
                   limits={"outputBytes": 1000, "timeoutSecs": 10})
spool_size = os.path.getsize(fd / verbose["output"]["path"])
check("AC2: the spool stays within the byte ceiling", spool_size <= 1000)
check("AC2: the retained display tail stays within 64 KiB", len(verbose["displayTail"].encode("utf-8")) <= 64 * 1024)
check("AC2: an over-ceiling capture is marked partial", verbose["output"].get("digestLabel") == "partial")
check("AC2: an over-ceiling capture is never PASS", verbose["status"] == "FAIL")
check("AC2: an over-ceiling capture is marked incomplete", verbose["output"]["complete"] is False)

# A timed-out child with a grandchild: both are reaped, no zombie survives.
pidfile = fd / "pgid.txt"
cmd = "echo $$ > %s; sleep 300 & wait" % pidfile
started = time.monotonic()
timed_out = observe(fd, root, legacy_binding("GE-007"), cmd, None, limits={"outputBytes": 16 * 1024 * 1024, "timeoutSecs": 2})
elapsed = time.monotonic() - started
check("AC2: a hung child is killed at the timeout, not left to its own sleep", elapsed < 15)
check("AC2: a killed command is never PASS", timed_out["status"] == "FAIL")
check("AC2: the reason names the timeout", "exceeded" in (timed_out["failureReason"] or ""))
check("AC2: a killed command's exit is recorded null", timed_out["exitCode"] is None)
pgid = int(pidfile.read_text().strip())
survivors = "1"
for _ in range(20):
    survivors = subprocess.run(["ps", "-o", "pid=", "-g", str(pgid)], stdout=subprocess.PIPE, text=True).stdout.strip()
    if not survivors:
        break
    time.sleep(0.5)
check("AC2: the child and its grandchild are both gone afterward", survivors == "")

# --- AC4: two commands, two publications, an untouched evidenceEpoch stays eligible
fd4 = feature_dir(generation=0, evidence_epoch=0)
root4 = git_repo()
r1 = observe(fd4, root4, legacy_binding("GE-001"), "exit 0", None)
r2 = observe(fd4, root4, legacy_binding("GE-002"), "exit 0", None)
check("AC4: both sequential commands observe cleanly", r1["status"] == "PASS" and r2["status"] == "PASS")

registry = {"verification": "verification.md"}
old_token = ap.capture_locked(fd4, registry)
# First publication: the VERIFICATION projection.
source = ap.stage(fd4, "v1", b"first")
manifest = {"version": 1, "files": [{"source": source, "target": "verification"}], "updates": []}
with ap.locked_feature(fd4):
    refreshed = ap.publish_locked(fd4, old_token, manifest, registry=registry)
check("AC4: the first publication advances the generation", refreshed["generation"] == old_token["generation"] + 1)

# Second publication: an ordinary ledger/state-shaped update through the same seam.
source2 = ap.stage(fd4, "v2", b"second")
manifest2 = {"version": 1, "files": [{"source": source2, "target": "verification"}], "updates": []}
with ap.locked_feature(fd4):
    refreshed2 = ap.publish_locked(fd4, refreshed, manifest2, registry=registry)
check("AC4: the second publication advances the generation again", refreshed2["generation"] == refreshed["generation"] + 1)

eligible1, reasons1 = validate_record(r1, current_for(r1, fd4))
eligible2, reasons2 = validate_record(r2, current_for(r2, fd4))
check("AC4: record 1 stays eligible across two intervening publications", eligible1)
check("AC4: record 2 stays eligible across two intervening publications", eligible2)
check("AC4: eligibility never re-derives from the generation number", "publicationGenerationAtCapture" not in FRESHNESS_FIELDS)

# A concurrent producer holding the pre-publication (now stale) token still fails.
stale_manifest = {"version": 1, "files": [{"source": ap.stage(fd4, "v3", b"third"), "target": "verification"}], "updates": []}
stale_failed = False
try:
    with ap.locked_feature(fd4):
        ap.publish_locked(fd4, old_token, stale_manifest, registry=registry)
except ValueError:
    stale_failed = True
check("AC4: a producer on the old ingress token cannot publish after an intervening generation change", stale_failed)

# Migration/rollback bumps evidenceEpoch (simulated directly, as a migration would):
# both records -- otherwise untouched -- become ineligible.
bump_evidence_epoch(fd4, 1)
eligible1_after, reasons1_after = validate_record(r1, current_for(r1, fd4))
eligible2_after, reasons2_after = validate_record(r2, current_for(r2, fd4))
check("AC4: an evidenceEpoch bump invalidates record 1", not eligible1_after)
check("AC4: an evidenceEpoch bump invalidates record 2", not eligible2_after)
check("AC4: the invalidation names evidenceEpoch, not the generation", "evidenceEpoch changed" in reasons1_after)

print("PYFAILURES=%d" % len(failures))
for name in failures:
    print("FAIL: " + name)
if failures:
    raise SystemExit(1)
print("PASS: all execution_observation.py checks")
TEST
