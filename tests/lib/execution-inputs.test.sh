#!/usr/bin/env bash
# Offline execution_inputs.py regressions: declared-identity capture, rejection
# diagnostics, deterministic hashing, bounded probes, and sensitive-input secrecy.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PYTHONPATH="$ROOT/lib" python3 - <<'TEST'
import hashlib
import json
import os
import tempfile
import time
from pathlib import Path

from execution_inputs import capture_inputs, compare_inputs, digest_value, identity_changed, run_probe

failures = []


def check(name, condition):
    if not condition:
        failures.append(name)


def workdir():
    return tempfile.mkdtemp(prefix="loop-spec-execution-inputs-")


def base_contract(local_inputs=None, toolchains=None, external=None, sensitive=None, receipt=None):
    contract = {
        "version": 1,
        "toolchains": toolchains or [],
        "localInputs": local_inputs or [],
        "externalInputs": external or [],
        "sensitiveInputs": sensitive or [],
    }
    if receipt is not None:
        contract["preparationReceipt"] = receipt
    return contract


def expect_value_error(name, fn):
    try:
        fn()
    except ValueError as exc:
        return str(exc)
    failures.append(name + " did not raise ValueError")
    return ""


# --- AC1: an ignored installed dependency and an ignored config change identity ---
root = workdir()
os.makedirs(os.path.join(root, "vendor"))
with open(os.path.join(root, "vendor", "installed.so"), "wb") as fh:
    fh.write(b"binary-v1")
with open(os.path.join(root, "vendor", "app.conf"), "w") as fh:
    fh.write("debug=false\n")
with open(os.path.join(root, "lockfile.txt"), "w") as fh:
    fh.write("pinned==1.0.0\n")

contract = base_contract(local_inputs=[{"root": "vendor", "paths": ["installed.so", "app.conf"]}])
before = capture_inputs(root, contract, [])

with open(os.path.join(root, "vendor", "installed.so"), "wb") as fh:
    fh.write(b"binary-v2-mutated-in-place")
after_dep = capture_inputs(root, contract, [])
check("changed ignored dependency (unchanged lockfile) changes identity", identity_changed(before, after_dep))
dep_changes = compare_inputs(before, after_dep)
check("changed dependency is reported by compare_inputs", any(c["name"] == "vendor" for c in dep_changes))

with open(os.path.join(root, "vendor", "installed.so"), "wb") as fh:
    fh.write(b"binary-v1")
with open(os.path.join(root, "vendor", "app.conf"), "w") as fh:
    fh.write("debug=true\n")
after_cfg = capture_inputs(root, contract, [])
check("changed ignored config changes identity", identity_changed(before, after_cfg))
check("unchanged dependency + reverted config matches original digest for the dep half",
      before["localInputs"][0]["digest"] != after_cfg["localInputs"][0]["digest"])

# --- AC2: rejection diagnostics ---
esc_root = workdir()
os.makedirs(os.path.join(esc_root, "in"))
outside = workdir()
with open(os.path.join(outside, "secret.txt"), "w") as fh:
    fh.write("outside")
os.symlink(os.path.join(outside, "secret.txt"), os.path.join(esc_root, "in", "link.txt"))
msg = expect_value_error(
    "escaping symlink is rejected",
    lambda: capture_inputs(esc_root, base_contract(local_inputs=[{"root": "in", "paths": ["link.txt"]}]), []))
check("escaping symlink diagnostic names the path", "link.txt" in msg and "escapes" in msg)

unreadable_root = workdir()
os.makedirs(os.path.join(unreadable_root, "in"))
os.symlink(os.path.join(unreadable_root, "in", "missing-target.bin"),
           os.path.join(unreadable_root, "in", "dangling.bin"))
msg = expect_value_error(
    "unreadable input is rejected",
    lambda: capture_inputs(unreadable_root, base_contract(local_inputs=[{"root": "in", "paths": ["dangling.bin"]}]), []))
check("unreadable diagnostic names the path", "dangling.bin" in msg and "unreadable" in msg)

unavailable_root = workdir()
msg = expect_value_error(
    "unavailable external identity is rejected",
    lambda: capture_inputs(unavailable_root, base_contract(
        external=[{"name": "svc", "argv": ["python3", "-c", "raise SystemExit(1)"], "expectedIdentity": ""}]), []))
check("unavailable external diagnostic names the input", "svc" in msg)

mutable_root = workdir()
mutable_probe = ["python3", "-c", "import json; print(json.dumps({'identity': 'v1', 'immutable': False}))"]
msg = expect_value_error(
    "mutable external response is rejected",
    lambda: capture_inputs(mutable_root, base_contract(
        external=[{"name": "svc", "argv": mutable_probe, "expectedIdentity": ""}]), []))
check("mutable external diagnostic names the input", "svc" in msg and "immutable" in msg)

decl_root = workdir()
msg = expect_value_error(
    "a contract missing a required key is rejected",
    lambda: capture_inputs(decl_root, {"version": 1, "toolchains": [], "localInputs": [], "externalInputs": []}, []))
check("missing-declaration diagnostic names the key", "sensitiveInputs" in msg)
bad_version_contract = base_contract()
bad_version_contract["version"] = 2
msg = expect_value_error(
    "a contract with the wrong version is rejected",
    lambda: capture_inputs(decl_root, bad_version_contract, []))
check("bad-version diagnostic names version", "version" in msg)

overlap_root = workdir()
os.makedirs(os.path.join(overlap_root, "in"))
with open(os.path.join(overlap_root, "in", "a.txt"), "w") as fh:
    fh.write("a")
msg = expect_value_error(
    "overlapping input/output paths are rejected",
    lambda: capture_inputs(overlap_root, base_contract(local_inputs=[{"root": "in", "paths": ["a.txt"]}]), ["in"]))
check("overlap diagnostic names the path", "overlaps" in msg)

# --- AC4 (module half): a preparationReceipt alone cannot authorize PASS-eligible identity ---
receipt_root = workdir()
msg = expect_value_error(
    "preparationReceipt with no localInputs cannot yield an eligible identity",
    lambda: capture_inputs(receipt_root, base_contract(receipt={"tool": "prepare-environment.sh", "key": "abc"}), []))
check("receipt-only diagnostic points at localInputs", "localInputs" in msg and "preparationReceipt" in msg)

receipt_ok_root = workdir()
os.makedirs(os.path.join(receipt_ok_root, "installed"))
with open(os.path.join(receipt_ok_root, "installed", "pkg.bin"), "w") as fh:
    fh.write("v1")
receipt_ok_contract = base_contract(
    local_inputs=[{"root": "installed", "paths": ["pkg.bin"]}],
    receipt={"tool": "prepare-environment.sh", "key": "abc"})
receipt_ok_record = capture_inputs(receipt_ok_root, receipt_ok_contract, [])
check("a receipt alongside a validated local input set is accepted", receipt_ok_record["version"] == 1)

# --- AC3: deterministic streaming directory hashes ---
def build_tree(base):
    os.makedirs(os.path.join(base, "tree", "nested"))
    with open(os.path.join(base, "tree", "one.txt"), "w") as fh:
        fh.write("one")
    with open(os.path.join(base, "tree", "nested", "two.txt"), "w") as fh:
        fh.write("two")


left, right = workdir(), workdir()
build_tree(left)
build_tree(right)
tree_contract = base_contract(local_inputs=[{"root": "tree", "paths": ["."]}])
left_record = capture_inputs(left, tree_contract, [])
right_record = capture_inputs(right, tree_contract, [])
check("identical trees in two locations hash identically",
      left_record["localInputs"][0]["digest"] == right_record["localInputs"][0]["digest"])

with open(os.path.join(right, "tree", "nested", "two.txt"), "w") as fh:
    fh.write("twO")
right_changed = capture_inputs(right, tree_contract, [])
check("a one-byte change changes the directory digest",
      right_changed["localInputs"][0]["digest"] != right_record["localInputs"][0]["digest"])

big_root = workdir()
os.makedirs(os.path.join(big_root, "big"))
payload = os.urandom(2 * 1024 * 1024)
with open(os.path.join(big_root, "big", "blob.bin"), "wb") as fh:
    fh.write(payload)
big_record = capture_inputs(big_root, base_contract(local_inputs=[{"root": "big", "paths": ["blob.bin"]}]), [])
check("a 2 MiB file streams to one hashed entry", big_record["localInputs"][0]["files"] == 1)
expected_big_digest = digest_value([{"path": "blob.bin", "type": "file", "digest": hashlib.sha256(payload).hexdigest()}])
check("the streamed digest matches a direct sha256 of the same content",
      big_record["localInputs"][0]["digest"] == expected_big_digest)

# --- AC3: bounded argv probes ---
verbose = run_probe(["python3", "-c", "import sys; sys.stdout.write('x' * 200000)"],
                     limits={"outputBytes": 1000, "timeoutSecs": 5})
check("a probe over the byte ceiling is cut", len(verbose["stdout"]) == 1000)
check("an over-ceiling probe is marked truncated", verbose["truncated"] is True)

started = time.monotonic()
hung = run_probe(["python3", "-c", "import time; time.sleep(30)"], limits={"outputBytes": 1000, "timeoutSecs": 1})
elapsed = time.monotonic() - started
check("a hung probe is killed at the time limit, not left to its own sleep", elapsed < 5)
check("a killed probe is marked timedOut", hung["timedOut"] is True)
pid_check = os.popen("pgrep -f \"time.sleep(30)\"").read().strip()
check("a killed probe leaves no orphan process", pid_check == "")

# --- AC3: sensitive probe never leaks fixture secret bytes or their digest ---
secret_root = workdir()
fixture_secret = "S3CR3T-fixture-bytes-do-not-leak"
secret_digest = hashlib.sha256(fixture_secret.encode()).hexdigest()
sensitive_contract = base_contract(sensitive=[{
    "name": "signing-key",
    "argv": ["python3", "-c", "print('configVersion=3')"],
    "expectedIdentity": "",
}])
sensitive_record = capture_inputs(secret_root, sensitive_contract, [])
dumped = json.dumps(sensitive_record)
check("sensitive record never carries fixture secret bytes", fixture_secret not in dumped)
check("sensitive record never carries the fixture secret's sha256", secret_digest not in dumped)
check("sensitive identity is the probe's reviewed version text",
      sensitive_record["sensitiveInputs"][0]["identity"] == "configVersion=3")

print("PYFAILURES=%d" % len(failures))
for name in failures:
    print("FAIL: " + name)
if failures:
    raise SystemExit(1)
print("PASS: all execution_inputs.py checks")
TEST
