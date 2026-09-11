#!/usr/bin/env python3
"""Capture declared execution-input identities without guessing installed bytes.

Purpose
    Task-006 boundary between a task's declared PLAN.md `**Execution inputs:**`
    contract (`{version:1,toolchains,localInputs,externalInputs,sensitiveInputs,
    preparationReceipt?}`, each toolchain/external/sensitive item shaped
    `{name,argv,expectedIdentity}`, each local input `{root,paths}`) and the
    actual identity the driver observes before and after running a command.
    A lockfile or preparation receipt describes intended state, never installed
    bytes (SPEC "The driver owns execution observations"), so this module hashes
    what is actually on disk and runs only the probes the contract declared --
    it never discovers dependencies the contract left unnamed.

API
    capture_inputs(root, contract, outputs, runner=None, limits=None) -> dict
        Pure function (see MODULE RECORD SHAPE below). Raises ValueError with
        an actionable file-path or probe-name diagnostic on: a symlink
        escaping its declared root, an unreadable input, an unavailable or
        mutable external identity, a missing/malformed contract declaration,
        or an input/output path overlap. `runner` is the argv probe (defaults
        to `run_probe`/`_default_runner` below); `limits` overrides
        `outputBytes`/`timeoutSecs` (see LIMITS).
    compare_inputs(before, after) -> [{category, name, before, after}, ...]
        The declared identities that changed between two capture_inputs()
        records, one entry per changed toolchain/local root/external/sensitive
        name.
    identity_changed(before, after) -> bool
        True when the actual environment digest differs -- the single check a
        gate needs; compare_inputs() is for the diagnostic behind it.
    run_probe(argv, limits=None, runner=None) -> dict
        Bounded argv execution used internally and exposed for direct testing
        of the byte/time ceilings: {"stdout": bytes, "truncated": bool,
        "timedOut": bool, "returncode": int|None, "error": str|None}.

MODULE RECORD SHAPE (what capture_inputs returns)
    {"version": 1,
     "inputSetDigest": sha256 of the reviewed contract itself,
     "environmentDigest": sha256 of the actual observed identities below,
     "toolchains": [{"name": ..., "identity": ...}, ...],
     "localInputs": [{"root": ..., "digest": ..., "files": <count>}, ...],
     "externalInputs": [{"name": ..., "identity": ...}, ...],
     "sensitiveInputs": [{"name": ..., "identity": ...}, ...],
     "probeImplementation": sha256 of this module's own source bytes,
     "unsupported": []}
    `unsupported` is reserved for a future contract grammar; v1 declares only
    the four supported categories above, so it is always empty -- arbitrary
    dependency discovery stays explicitly unsupported (SPEC).

Design decision: preparationReceipt never stands in for validation
    SPEC: "A receipt or lockfile alone cannot stand in for that validation."
    capture_inputs() enforces this structurally: a contract carrying
    `preparationReceipt` with an empty `localInputs` array raises ValueError
    rather than returning a record -- there is no such thing as a
    PASS-eligible identity built from a receipt alone. Declare at least one
    localInputs root (even the same root the receipt describes) so the actual
    installed bytes are the thing hashed.

Usage
    from execution_inputs import capture_inputs, identity_changed
    before = capture_inputs(root, contract, outputs)
    ...run the command...
    after = capture_inputs(root, contract, outputs)
    if identity_changed(before, after):
        ...fail with compare_inputs(before, after) as the diagnostic...

Limits
    MAX_FILE_BYTES = 16 MiB per declared local-input file.
    MAX_FILES = 4096 declared local-input files per input set.
    DEFAULT_LIMITS = {"outputBytes": 64 KiB, "timeoutSecs": 30} for every
    toolchain/external/sensitive probe; override per call via `limits`.

Exit codes
    Library only, no CLI: importers see ValueError, never a process exit.
"""
import hashlib
import json
import os
import select
import signal
import subprocess
import time
from pathlib import Path

MAX_FILE_BYTES = 16 * 1024 * 1024
MAX_FILES = 4096
DEFAULT_LIMITS = {"outputBytes": 64 * 1024, "timeoutSecs": 30}
STREAM_CHUNK = 64 * 1024

REQUIRED_TOP_KEYS = {"version", "toolchains", "localInputs", "externalInputs", "sensitiveInputs"}
OPTIONAL_TOP_KEYS = {"preparationReceipt"}
PROBE_ITEM_KEYS = {"name", "argv", "expectedIdentity"}


def digest_value(value):
    """sha256 of canonical JSON, matching lib/requirements.py's digest() so an
    input-set digest and a requirement revision are computed the same way."""
    data = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(data.encode("utf-8")).hexdigest()


def _stream_digest(path):
    result = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(STREAM_CHUNK), b""):
            result.update(chunk)
    return result.hexdigest()


def _is_within(path, ancestor):
    try:
        return os.path.commonpath([path, ancestor]) == ancestor
    except ValueError:
        return False


def _validate_contract(contract):
    if not isinstance(contract, dict):
        raise ValueError("execution inputs contract must be a JSON object, got {}".format(type(contract).__name__))
    missing = REQUIRED_TOP_KEYS - set(contract)
    if missing:
        raise ValueError("execution inputs contract missing required key(s): {}".format(", ".join(sorted(missing))))
    unknown = set(contract) - REQUIRED_TOP_KEYS - OPTIONAL_TOP_KEYS
    if unknown:
        raise ValueError("execution inputs contract has unsupported key(s): {}".format(", ".join(sorted(unknown))))
    if contract.get("version") != 1:
        raise ValueError("execution inputs contract version must be 1, got {!r}".format(contract.get("version")))
    for key in ("toolchains", "localInputs", "externalInputs", "sensitiveInputs"):
        if not isinstance(contract[key], list):
            raise ValueError("execution inputs {} must be an array".format(key))
    if "preparationReceipt" in contract and not contract["localInputs"]:
        raise ValueError(
            "preparationReceipt cannot replace installed-input validation: declare at "
            "least one localInputs root so the actual installed bytes are hashed "
            "(SPEC: 'A receipt or lockfile alone cannot stand in for that validation')")


def _validate_probe_item(item, category):
    if not isinstance(item, dict) or set(item) != PROBE_ITEM_KEYS:
        got = sorted(item) if isinstance(item, dict) else type(item).__name__
        raise ValueError("{} item needs exactly name, argv, expectedIdentity (got {})".format(category, got))
    name = item["name"]
    if not isinstance(name, str) or not name.strip():
        raise ValueError("{} item name must be a non-empty string".format(category))
    argv = item["argv"]
    if not isinstance(argv, list) or not argv or not all(isinstance(a, str) for a in argv):
        raise ValueError("{} '{}' argv must be a non-empty array of strings".format(category, name))
    if not isinstance(item["expectedIdentity"], str):
        raise ValueError("{} '{}' expectedIdentity must be a string".format(category, name))


def _default_runner(argv, limits):
    """Run argv with no shell expansion, killing the whole process group on the
    output-byte ceiling or the wall-clock timeout so a hung or verbose probe
    never blocks the driver or leaves an orphan behind."""
    ceiling = limits["outputBytes"]
    timeout = limits["timeoutSecs"]
    try:
        proc = subprocess.Popen(list(argv), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 stdin=subprocess.DEVNULL, start_new_session=True)
    except OSError as exc:
        return {"stdout": b"", "truncated": False, "timedOut": False, "returncode": None,
                "error": "cannot start probe {!r}: {}".format(argv, exc)}
    chunks = []
    total = 0
    truncated = False
    timed_out = False
    deadline = time.monotonic() + timeout
    fd = proc.stdout.fileno()
    os.set_blocking(fd, False)
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                timed_out = True
                break
            ready, _, _ = select.select([fd], [], [], min(remaining, 0.5))
            if not ready:
                continue
            chunk = os.read(fd, STREAM_CHUNK)
            if not chunk:
                break
            if total < ceiling:
                chunks.append(chunk[:ceiling - total])
            total += len(chunk)
            if total >= ceiling:
                truncated = True
                break
    finally:
        if proc.poll() is None:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
        else:
            proc.wait()
    return {"stdout": b"".join(chunks), "truncated": truncated, "timedOut": timed_out,
            "returncode": proc.returncode, "error": None}


def run_probe(argv, limits=None, runner=None):
    limits = dict(DEFAULT_LIMITS, **(limits or {}))
    runner = runner or _default_runner
    return runner(argv, limits)


def _run_probe_identity(category, item, runner, limits):
    _validate_probe_item(item, category)
    name = item["name"]
    result = run_probe(item["argv"], limits, runner)
    if result.get("error"):
        raise ValueError("{} '{}' probe unavailable: {}".format(category, name, result["error"]))
    if result.get("timedOut"):
        raise ValueError("{} '{}' probe exceeded {}s and was killed".format(category, name, limits["timeoutSecs"]))
    identity = result["stdout"].decode("utf-8", "replace").strip()
    if not identity:
        raise ValueError("{} '{}' probe produced no identity output".format(category, name))
    expected = item["expectedIdentity"]
    if expected and identity != expected:
        raise ValueError("{} '{}' identity {!r} does not match expectedIdentity {!r}".format(
            category, name, identity, expected))
    return {"name": name, "identity": identity}


def _run_external_identity(item, runner, limits):
    _validate_probe_item(item, "externalInputs")
    name = item["name"]
    result = run_probe(item["argv"], limits, runner)
    if result.get("error"):
        raise ValueError("externalInputs '{}' probe unavailable: {}".format(name, result["error"]))
    if result.get("timedOut"):
        raise ValueError("externalInputs '{}' probe exceeded {}s and was killed".format(name, limits["timeoutSecs"]))
    text = result["stdout"].decode("utf-8", "replace")
    try:
        payload = json.loads(text)
    except ValueError as exc:
        raise ValueError("externalInputs '{}' probe did not return JSON: {}".format(name, exc))
    identity = payload.get("identity") if isinstance(payload, dict) else None
    if not isinstance(identity, str) or not identity or payload.get("immutable") is not True:
        raise ValueError("externalInputs '{}' identity is unavailable or not immutable: {!r}".format(name, payload))
    expected = item["expectedIdentity"]
    if expected and identity != expected:
        raise ValueError("externalInputs '{}' identity {!r} does not match expectedIdentity {!r}".format(
            name, identity, expected))
    return {"name": name, "identity": identity}


def _expand_declared_path(entry_path):
    if entry_path.is_dir():
        for dirpath, dirnames, filenames in os.walk(str(entry_path), followlinks=True):
            dirnames.sort()
            for filename in sorted(filenames):
                yield Path(dirpath) / filename
    elif entry_path.exists() or entry_path.is_symlink():
        yield entry_path
    else:
        raise ValueError("localInputs path does not exist: {}".format(entry_path))


def _hash_local_input(root_real, item, output_reals):
    if not isinstance(item, dict) or set(item) != {"root", "paths"}:
        got = sorted(item) if isinstance(item, dict) else type(item).__name__
        raise ValueError("localInputs item needs exactly root and paths (got {})".format(got))
    declared_root = item["root"]
    paths = item["paths"]
    if not isinstance(declared_root, str) or not declared_root:
        raise ValueError("localInputs root must be a non-empty string")
    if not isinstance(paths, list) or not paths or not all(isinstance(p, str) and p for p in paths):
        raise ValueError("localInputs '{}' paths must be a non-empty array of strings".format(declared_root))
    root_dir = Path(declared_root) if os.path.isabs(declared_root) else Path(root_real) / declared_root
    if not root_dir.is_dir():
        raise ValueError("localInputs root is not a directory: {}".format(declared_root))
    declared_root_real = os.path.realpath(str(root_dir))
    for out in output_reals:
        if _is_within(out, declared_root_real) or _is_within(declared_root_real, out):
            raise ValueError("localInputs root '{}' overlaps a declared output path: {}".format(declared_root, out))
    entries = []
    seen = set()
    for rel in paths:
        if os.path.isabs(rel) or ".." in Path(rel).parts:
            raise ValueError("localInputs '{}' path escapes its root: {}".format(declared_root, rel))
        for file_path in _expand_declared_path(root_dir / rel):
            file_real = os.path.realpath(str(file_path))
            if not _is_within(file_real, declared_root_real):
                raise ValueError("localInputs '{}' path escapes its declared root via symlink: {}".format(
                    declared_root, file_path))
            relname = os.path.relpath(file_real, declared_root_real)
            if relname in seen:
                continue
            seen.add(relname)
            if not os.path.isfile(file_real) or not os.access(file_real, os.R_OK):
                raise ValueError("localInputs '{}' path is unreadable: {}".format(declared_root, file_path))
            if os.path.getsize(file_real) > MAX_FILE_BYTES:
                raise ValueError("localInputs '{}' file exceeds the {} byte ceiling: {}".format(
                    declared_root, MAX_FILE_BYTES, file_path))
            try:
                content_digest = _stream_digest(file_real)
            except OSError as exc:
                raise ValueError("localInputs '{}' path is unreadable: {} ({})".format(
                    declared_root, file_path, exc))
            entries.append({"path": relname, "type": "file", "digest": content_digest})
    entries.sort(key=lambda entry: entry["path"])
    return {"root": declared_root, "digest": digest_value(entries), "files": len(entries)}


def capture_inputs(root, contract, outputs, runner=None, limits=None):
    _validate_contract(contract)
    root_path = Path(root)
    if not root_path.is_dir():
        raise ValueError("execution inputs root is not a directory: {}".format(root))
    root_real = os.path.realpath(str(root_path))
    limits = dict(DEFAULT_LIMITS, **(limits or {}))
    output_reals = {os.path.realpath(out if os.path.isabs(out) else os.path.join(root_real, out))
                     for out in (outputs or [])}

    toolchains = [_run_probe_identity("toolchains", item, runner, limits) for item in contract["toolchains"]]
    external = [_run_external_identity(item, runner, limits) for item in contract["externalInputs"]]
    sensitive = [_run_probe_identity("sensitiveInputs", item, runner, limits) for item in contract["sensitiveInputs"]]
    local = [_hash_local_input(root_real, item, output_reals) for item in contract["localInputs"]]

    total_files = sum(entry["files"] for entry in local)
    if total_files > MAX_FILES:
        raise ValueError("declared local input set has {} files, exceeds the {} file ceiling".format(
            total_files, MAX_FILES))

    environment_payload = {
        "toolchains": sorted(toolchains, key=lambda e: e["name"]),
        "externalInputs": sorted(external, key=lambda e: e["name"]),
        "sensitiveInputs": sorted(sensitive, key=lambda e: e["name"]),
        "localInputs": sorted([{"root": e["root"], "digest": e["digest"]} for e in local], key=lambda e: e["root"]),
    }
    return {
        "version": 1,
        "inputSetDigest": digest_value(contract),
        "environmentDigest": digest_value(environment_payload),
        "toolchains": toolchains,
        "localInputs": local,
        "externalInputs": external,
        "sensitiveInputs": sensitive,
        "probeImplementation": _stream_digest(__file__),
        "unsupported": [],
    }


def compare_inputs(before, after):
    """The declared identities that differ between two capture_inputs() records,
    one entry per changed name -- the diagnostic behind identity_changed()."""
    changes = []
    for category in ("toolchains", "externalInputs", "sensitiveInputs"):
        before_index = {entry["name"]: entry["identity"] for entry in before.get(category, [])}
        after_index = {entry["name"]: entry["identity"] for entry in after.get(category, [])}
        for name in sorted(set(before_index) | set(after_index)):
            if before_index.get(name) != after_index.get(name):
                changes.append({"category": category, "name": name,
                                 "before": before_index.get(name), "after": after_index.get(name)})
    before_local = {entry["root"]: entry["digest"] for entry in before.get("localInputs", [])}
    after_local = {entry["root"]: entry["digest"] for entry in after.get("localInputs", [])}
    for root in sorted(set(before_local) | set(after_local)):
        if before_local.get(root) != after_local.get(root):
            changes.append({"category": "localInputs", "name": root,
                             "before": before_local.get(root), "after": after_local.get(root)})
    return changes


def identity_changed(before, after):
    return before.get("environmentDigest") != after.get("environmentDigest")
