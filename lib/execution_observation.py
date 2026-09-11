#!/usr/bin/env python3
"""Run one required command and publish a bounded, driver-owned observation record.

Purpose
    Task-007 boundary that replaces buffered command capture (the old
    lib/graph/driver.py `observe()`) with an actual record: a clean-tree check
    before and after the command, a bounded/hashed output spool instead of an
    unbounded `subprocess.PIPE`, and a schema-1 JSON record the caller's
    VERIFICATION row can reference by execution ID instead of writing PASS/FAIL
    itself (SPEC "The driver owns execution observations"). Only this module
    decides `status`; a caller that wants to change a row's PASS/FAIL has
    nothing to edit but the command it re-runs.

API
    observe(feature_dir, root, binding, command, contract, outputs=(),
            limits=None, inputs=execution_inputs, runner=None, git=None) -> dict
        binding = {"owner": ..., "requirement": "GE-NNN", "revision": ..., "scenario": ...}.
        Legacy route: owner None, requirement the positional "GE-NNN", revision
        None, scenario None -- the shape lib/graph/driver.py's frontmatter
        `criteria:` map has always used. v1 route: all four fields, from the
        inventory's `scenario_checks[GE-ID/SC-ID]` entry.
        `contract` is the task-006 execution-inputs object bound to this one
        check (`lib/execution_inputs.py`'s `{version,toolchains,localInputs,
        externalInputs,sensitiveInputs}`), or None on the legacy route, which
        declares no execution inputs at all -- see LEGACY ROUTE below for what
        that means for `status`. Runs `command` through `bash -c` in the
        feature root, in its own session/process group, streaming combined
        stdout+stderr to `observations/<execution-id>.output` under
        `feature_dir` while hashing incrementally and keeping a 64 KiB
        in-memory display tail. `outputs` names additional declared output
        paths (besides that spool file, which this function adds itself) so
        `contract`'s localInputs hashing never overlaps them. `limits`
        overrides `outputBytes` (default 16 MiB) / `timeoutSecs` (default
        `LOOP_SPEC_PHASE_TIMEOUT_MINS` minutes, else 60); both must be
        positive. `inputs` is the `execution_inputs` module (or a test double
        exposing `capture_inputs`/`identity_changed`/`compare_inputs`).
        `runner`/`git` are the process/git collaborators `_run_bounded` and
        `_git` use by default; a test supplies fakes to force a timeout,
        overflow, or a mid-command HEAD/status change without an actual repo.
        Writes `observations/<execution-id>.json` (atomically, via
        `feature_write.publish`) and returns the parsed record (see RECORD
        SCHEMA). Never raises for a failing/timed-out/dirty command -- those
        are FAIL records with a `failureReason`; it raises ValueError only for
        a malformed `binding`/`contract`/`limits` or an unreadable feature
        state.
    validate_record(record, current) -> (eligible, reasons)
        Pure comparison: `eligible` is True only when every field in `current`
        equals its counterpart in `record` (see FRESHNESS TUPLE below) and
        `record["status"] == "PASS"`. `reasons` names every mismatch, empty
        when eligible. Never touches disk or `artifactPublication.generation`
        -- CAS generation is bumped by every unrelated publish and is not a
        freshness signal (PLAN "Publication and execution setup"); the caller
        builds `current` from a fresh read of state/SPEC/PLAN/the output file
        (see `read_output_digest` below) and passes it in already computed, so
        this stays a pure function two collaborators (a test, or the driver)
        can call without a live git checkout.
    read_output_digest(feature_dir, record) -> str|None
        sha256 of `record["output"]["path"]`'s CURRENT bytes under
        `feature_dir`, for building a `validate_record` `current["outputDigest"]`
        without re-deriving the path-join/read-bounded dance at every call
        site. None when the file is missing (a caller then treats that as a
        mismatch itself -- this helper does not decide eligibility).
    current_binding(feature_dir, root, binding, command, contract, git=None,
                     inputs=execution_inputs, runner=None) -> dict
        Task-008 boundary: recomputes the FRESHNESS TUPLE's live half for one v1
        VERIFICATION row -- the examined HEAD, the command digest, and (when
        `contract` names execution inputs) a fresh probe of the declared input
        identities -- without running `command`. A grounding/floor gate calls
        this instead of `observe()` because checking a row must never itself
        write a new observation; only `spec fill`'s reviewed command, run
        through `observe()`, does that. Callers add `current["outputDigest"]`
        (`read_output_digest`) before `validate_record`.
    eligible_row(feature_dir, root, binding, command, contract, execution_id,
                 git=None, inputs=execution_inputs, runner=None) -> (eligible, reasons)
        Loads `observations/<execution_id>.json` and decides whether it still
        supports a v1 row's PASS: `eligible_row` reports a missing or unparsable
        record itself (`reasons` names it), then defers to `validate_record`
        against a fresh `current_binding(...)` for everything else. Shared by
        lib/verification-grounding-lint.sh and lib/converged-floor.sh so neither
        reimplements the freshness rebuild.

RECORD SCHEMA (schema 1, what observe() writes and returns)
    {"schema": 1, "executionId": <uuid4 hex>,
     "owner": {"repository":...,"feature":...}|null,
     "requirement": "GE-NNN", "scenario": "SC-NNN"|null, "revision": sha256|null,
     "command": <the exact shell command>, "commandDigest": sha256(command utf-8),
     "eligibleForV1": bool,                 # see LEGACY ROUTE
     "exitCode": int|null,                  # null only on a killed timeout/overflow
     "status": "PASS"|"FAIL", "failureReason": str|null,
     "output": {"path": "observations/<id>.output" (relative to feature_dir),
                "digest": sha256 of the bytes actually spooled,
                "complete": bool,           # false on ceiling/timeout truncation
                "digestLabel": "partial"}   # present only when not complete
     "examinedHeads": [{"root": <abs path>, "before": sha|null, "after": sha|null}],
     "statusChanged": bool,                 # `git status` porcelain differed before/after
     "authoritativeHashes": {"spec": sha256|null, "plan": sha256|null,
                              "commandInput": sha256({"command":...,"executionInputs":...})},
     "inputSetDigest": sha256|null,         # contract's own digest, from execution_inputs
     "environmentDigest": sha256|null,      # actual observed identity, from execution_inputs
     "environment": {"status":"unknown","reason":str} | {"status":"known","before":{...},"after":{...}},
     "publicationGenerationAtCapture": int, "evidenceEpoch": int,
     "startedAt": "...Z", "endedAt": "...Z"}
    `examinedHeads` has one entry today (`root`); multi-repository workspace
    checks add entries the same shape, never a different one.

FRESHNESS TUPLE (what validate_record compares, `current[...]` against `record[...]`)
    owner, requirement, revision, scenario, commandDigest, inputSetDigest,
    examinedHeads, environmentDigest, evidenceEpoch, plus `current["outputDigest"]`
    against `record["output"]["digest"]` and `record["output"]["complete"]`.
    Never `publicationGenerationAtCapture` against a later
    `artifactPublication.generation`: a record stays eligible across many
    intervening publications as long as every field above still matches
    (PLAN "Publication and execution setup" -- CAS is not a freshness test).

LEGACY ROUTE (contract is None)
    PLAN: "Unknown dependency or environment identity cannot be represented as
    verified current evidence" -- taken literally, every legacy-route record
    would be FAIL forever, because the legacy `criteria:` map declares no
    execution-inputs contract at all. That would break every existing legacy
    oneshot fixture at this intermediate revision, and PLAN task-008 AC3 keeps
    those fixtures passing unchanged through the whole 7.x window. Design
    decision, stated once here rather than re-derived at each call site: when
    `contract is None`, `status` is exit/clean-tree only (today's semantics --
    exit 0 AND identical before/after HEAD/status/SPEC/PLAN hashes), the
    record's `environment` is always `{"status":"unknown","reason":"legacy
    contract declares no execution inputs"}`, and `eligibleForV1` is False so
    a v1-only consumer (task-008's grounding lint) can refuse it outright
    without re-deriving "was this a legacy check" from the absence of a
    contract itself. When `contract` is not None (the v1 route), the full PLAN
    rule applies: an environment capture failure or a changed identity is a
    FAIL like any other freshness break, and `eligibleForV1` is True.

Limits
    OUTPUT_CEILING = 16 MiB (`limits["outputBytes"]`).
    DISPLAY_TAIL = 64 KiB kept in memory regardless of the ceiling.
    Default timeout: `LOOP_SPEC_PHASE_TIMEOUT_MINS` minutes (env), else 60.
    Both must be positive; a non-positive override raises ValueError.

Exit codes
    Library only, no CLI: importers see ValueError, never a process exit.
"""
import hashlib
import json
import os
import select
import signal
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import execution_inputs  # noqa: E402
import feature_read  # noqa: E402
from artifact_publication import artifact_paths  # noqa: E402
from feature_write import publish, read_bounded  # noqa: E402

OUTPUT_CEILING = 16 * 1024 * 1024
DISPLAY_TAIL = 64 * 1024
STREAM_CHUNK = 64 * 1024
GRACE_SECS = 2.0


def _now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _digest_bytes(data):
    return hashlib.sha256(data).hexdigest()


# simplicity: this streaming-hash loop repeats execution_inputs._stream_digest's
# shape; that helper is private to task-006's module and outside this task's
# file-ownership list (PLAN "Task Files"), so it is not imported or promoted
# to a shared module here rather than editing a file this task does not own.
def _hash_file(path):
    if path is None or not path.is_file():
        return None
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(STREAM_CHUNK), b""):
            result.update(chunk)
    return result.hexdigest()


# simplicity: named (not inlined) so `observe`'s `git` parameter has an explicit
# default to fall back on -- the same injectable-collaborator shape as
# execution_inputs.run_probe/_default_runner, which lets a test swap in a fake
# that reports a HEAD/status change mid-command without a real git invocation.
def _default_git(args, cwd):
    proc = subprocess.run(["git"] + list(args), cwd=str(cwd), stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, universal_newlines=True)
    return proc.stdout.strip() if proc.returncode == 0 else None


def _spec_plan_paths(feature_dir, state):
    """Best-effort absolute SPEC.md/PLAN.md paths for the authoring-artifact hash
    (SPEC "Fingerprint authoritative spec, plan ... separately"). Reuses
    artifact_publication's own registered-target resolution so this never grows
    a second, divergent notion of where those files live; a feature with no
    resolvable root/slug (a bare fixture) yields (None, None) rather than raising
    -- the clean-tree check still runs on git status/HEAD alone."""
    try:
        paths = artifact_paths(Path(feature_dir), state)
    except ValueError:
        return None, None
    return paths.get("spec"), paths.get("plan")


def _status_excludes(root, feature_dir, spec_path, plan_path):
    """Relative pathspecs the dirty-tree check excludes: the feature's own
    driver-owned state (already gitignored, excluded here for the record's own
    honesty rather than reliance on .gitignore) and the two authoring artifacts,
    which are permitted to sit uncommitted mid-cycle and are fingerprinted by
    hash instead (SPEC/PLAN "excluding only the enumerated driver output/state
    files and separately fingerprinted authoring artifacts")."""
    excludes = []
    for candidate in (Path(feature_dir), spec_path, plan_path):
        if candidate is None:
            continue
        try:
            relative = os.path.relpath(str(candidate), str(root))
        except ValueError:
            continue
        if not relative.startswith(".."):
            excludes.append(relative)
    return excludes


def _capture_clean_identity(git, root, feature_dir, spec_path, plan_path):
    excludes = _status_excludes(root, feature_dir, spec_path, plan_path)
    status_args = ["status", "--porcelain", "--untracked-files=all", "--", "."]
    status_args += [":(exclude)%s" % path for path in excludes]
    return {
        "head": git(["rev-parse", "HEAD"], root),
        "status": git(status_args, root),
        "spec": _hash_file(spec_path),
        "plan": _hash_file(plan_path),
    }


def _run_bounded(command, root, limits, output_path):
    """Stream `bash -c command`'s combined stdout+stderr to `output_path`, hashing
    incrementally and keeping a bounded tail, while enforcing the byte ceiling
    and wall-clock timeout by killing and reaping the WHOLE process group
    (`start_new_session=True` makes the child its own group leader, so a
    grandchild it spawns dies with it too). Returns
    {"exitCode": int|None, "digest": hex, "complete": bool, "tail": bytes,
     "failure": str|None}; `exitCode` is None only when the process had to be
    killed before it exited on its own.

    simplicity: the non-blocking select/read loop below repeats the shape of
    execution_inputs._default_runner's own bounded probe read; that helper is
    private to task-006's module (outside this task's file-ownership list), and
    this loop also spools to disk and keeps a display tail, which that one does
    not, so the two are not the same function wearing different names -- a
    shared extraction would need a third file this task does not own either."""
    ceiling = limits["outputBytes"]
    timeout = limits["timeoutSecs"]
    hasher = hashlib.sha256()
    tail = bytearray()
    written = 0
    truncated = False
    timed_out = False
    failure = None
    output_path.parent.mkdir(parents=True, exist_ok=True)
    # PYTHONDONTWRITEBYTECODE: a command that imports a repo-local module (the
    # common shape of a Good Enough check, `python3 -c "from x import y; ..."`)
    # otherwise leaves a fresh __pycache__/*.pyc as an untracked file every run --
    # not a source change, but the clean-tree check cannot tell that from one
    # without knowing Python wrote it, so the child is told not to.
    child_env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    try:
        proc = subprocess.Popen(["bash", "-c", command], cwd=str(root), stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                 start_new_session=True, env=child_env)
    except OSError as exc:
        publish(output_path, b"")
        return {"exitCode": None, "digest": _digest_bytes(b""), "complete": True,
                "tail": b"", "failure": "cannot start command: {}".format(exc)}
    fd = proc.stdout.fileno()
    os.set_blocking(fd, False)
    deadline = time.monotonic() + timeout
    with open(str(output_path), "wb") as spool:
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
                keep = chunk[:max(0, ceiling - written)]
                if keep:
                    spool.write(keep)
                    hasher.update(keep)
                    written += len(keep)
                tail.extend(chunk)
                del tail[:-DISPLAY_TAIL]
                if len(keep) < len(chunk):
                    # The ceiling was crossed on this chunk: stop reading and kill
                    # the child now rather than draining an unbounded verbose
                    # writer to natural completion or the wall-clock timeout.
                    truncated = True
                    break
        finally:
            spool.flush()
            os.fsync(spool.fileno())
    if timed_out or truncated:
        failure = ("execution exceeded {}s and was killed".format(timeout) if timed_out
                   else "output exceeded the {} byte ceiling and was killed".format(ceiling))
        try:
            pgid = os.getpgid(proc.pid)
            os.killpg(pgid, signal.SIGTERM)
            deadline = time.monotonic() + GRACE_SECS
            while proc.poll() is None and time.monotonic() < deadline:
                time.sleep(0.05)
            if proc.poll() is None:
                os.killpg(pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    exit_code = None if (timed_out or truncated) else proc.returncode
    return {"exitCode": exit_code, "digest": hasher.hexdigest(), "complete": not (timed_out or truncated),
            "tail": bytes(tail[-DISPLAY_TAIL:]), "failure": failure}


def _validate_binding(binding):
    if not isinstance(binding, dict) or "requirement" not in binding:
        raise ValueError("binding requires at least a requirement id")
    requirement = binding["requirement"]
    if not isinstance(requirement, str) or not requirement:
        raise ValueError("binding requirement must be a non-empty string")
    return {"owner": binding.get("owner"), "requirement": requirement,
            "revision": binding.get("revision"), "scenario": binding.get("scenario")}


def _validate_limits(limits):
    default_timeout = int(os.environ.get("LOOP_SPEC_PHASE_TIMEOUT_MINS") or 60) * 60
    merged = {"outputBytes": OUTPUT_CEILING, "timeoutSecs": default_timeout}
    merged.update(limits or {})
    for key in ("outputBytes", "timeoutSecs"):
        if not isinstance(merged[key], int) or merged[key] <= 0:
            raise ValueError("execution observation limits.{} must be a positive integer".format(key))
    return merged


def observe(feature_dir, root, binding, command, contract, outputs=(), limits=None,
            inputs=execution_inputs, runner=None, git=None):
    feature_dir = Path(feature_dir)
    root = Path(root)
    binding = _validate_binding(binding)
    if not isinstance(command, str) or not command.strip():
        raise ValueError("execution observation requires a non-empty command")
    limits = _validate_limits(limits)
    git = git or _default_git
    execution_id = uuid.uuid4().hex
    started = _now()

    state = feature_read.load_state(str(feature_dir))
    publication = state.get("artifactPublication") or {}
    generation = publication.get("generation", 0)
    evidence_epoch = publication.get("evidenceEpoch", 0)
    spec_path, plan_path = _spec_plan_paths(feature_dir, state)

    before = _capture_clean_identity(git, root, feature_dir, spec_path, plan_path)
    output_relative = "observations/{}.output".format(execution_id)
    output_path = feature_dir / output_relative
    final_outputs = tuple(outputs) + (str(output_path),)

    env_before, env_error = None, None
    if contract is not None:
        try:
            env_before = inputs.capture_inputs(str(root), contract, final_outputs, runner=runner)
        except ValueError as exc:
            env_error = str(exc)

    run_result = _run_bounded(command, root, limits, output_path)

    after = _capture_clean_identity(git, root, feature_dir, spec_path, plan_path)
    env_after = None
    if contract is not None and env_error is None:
        try:
            env_after = inputs.capture_inputs(str(root), contract, final_outputs, runner=runner)
        except ValueError as exc:
            env_error = str(exc)

    head_ok = before["head"] == after["head"]
    status_ok = before["status"] == after["status"]
    spec_ok = before["spec"] == after["spec"]
    plan_ok = before["plan"] == after["plan"]
    clean_ok = head_ok and status_ok and spec_ok and plan_ok

    eligible_for_v1 = contract is not None
    if contract is None:
        environment = {"status": "unknown", "reason": "legacy contract declares no execution inputs"}
        environment_digest = None
        input_set_digest = None
        env_ok = True
    elif env_error is not None:
        environment = {"status": "unknown", "reason": env_error}
        environment_digest = None
        input_set_digest = execution_inputs.digest_value(contract)
        env_ok = False
    else:
        environment = {"status": "known", "before": env_before, "after": env_after}
        environment_digest = env_after["environmentDigest"]
        input_set_digest = env_after["inputSetDigest"]
        env_ok = not inputs.identity_changed(env_before, env_after)

    failure_reason = None
    if run_result["failure"]:
        failure_reason = run_result["failure"]
    elif run_result["exitCode"] != 0:
        failure_reason = "command exited {}".format(run_result["exitCode"])
    elif not head_ok:
        failure_reason = "HEAD changed during execution ({}: {} -> {})".format(root, before["head"], after["head"])
    elif not status_ok:
        before_paths = {line[3:] for line in (before["status"] or "").splitlines() if line}
        after_paths = {line[3:] for line in (after["status"] or "").splitlines() if line}
        changed = sorted(before_paths.union(after_paths))
        failure_reason = "commit or restore {} and rerun verification".format(", ".join(changed) or "the changed inputs")
    elif not spec_ok or not plan_ok:
        failure_reason = "authoring artifact changed during execution (SPEC.md/PLAN.md hash mismatch)"
    elif contract is not None and env_error is not None:
        failure_reason = "declared execution input unavailable: {}".format(env_error)
    elif contract is not None and not env_ok:
        changes = inputs.compare_inputs(env_before, env_after)
        failure_reason = "declared execution inputs changed during execution: {}".format(
            ", ".join("{}/{}".format(c["category"], c["name"]) for c in changes) or "unknown input")

    status = "PASS" if (clean_ok and env_ok and run_result["complete"] and run_result["exitCode"] == 0) else "FAIL"

    output_record = {"path": output_relative, "digest": run_result["digest"], "complete": run_result["complete"]}
    if not run_result["complete"]:
        output_record["digestLabel"] = "partial"

    command_input_text = json.dumps({"command": command, "executionInputs": contract},
                                     sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    command_input_digest = hashlib.sha256(command_input_text.encode("utf-8")).hexdigest()
    record = {
        "schema": 1, "executionId": execution_id,
        "owner": binding["owner"], "requirement": binding["requirement"],
        "scenario": binding["scenario"], "revision": binding["revision"],
        "command": command, "commandDigest": _digest_bytes(command.encode("utf-8")),
        "eligibleForV1": eligible_for_v1,
        "exitCode": run_result["exitCode"], "status": status, "failureReason": failure_reason,
        "output": output_record,
        "examinedHeads": [{"root": str(root), "before": before["head"], "after": after["head"]}],
        "statusChanged": not status_ok,
        "authoritativeHashes": {"spec": after["spec"], "plan": after["plan"], "commandInput": command_input_digest},
        "inputSetDigest": input_set_digest, "environmentDigest": environment_digest,
        "environment": environment,
        "publicationGenerationAtCapture": generation, "evidenceEpoch": evidence_epoch,
        "startedAt": started, "endedAt": _now(),
    }
    publish(feature_dir / "observations" / "{}.json".format(execution_id),
            (json.dumps(record, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8"))
    record["displayTail"] = run_result["tail"].decode("utf-8", "replace")
    return record


def read_output_digest(feature_dir, record):
    path = Path(feature_dir) / record["output"]["path"]
    if not path.is_file():
        return None
    try:
        return _digest_bytes(read_bounded(path, limit=OUTPUT_CEILING))
    except ValueError:
        return None


FRESHNESS_FIELDS = ("owner", "requirement", "revision", "scenario", "commandDigest",
                    "inputSetDigest", "examinedHeads", "environmentDigest", "evidenceEpoch")


def current_binding(feature_dir, root, binding, command, contract, git=None,
                     inputs=execution_inputs, runner=None):
    """See module docstring. Never runs `command` -- only re-derives what a fresh
    `observe()` of it would currently see."""
    binding = _validate_binding(binding)
    git = git or _default_git
    root = Path(root)
    state = feature_read.load_state(str(feature_dir))
    evidence_epoch = (state.get("artifactPublication") or {}).get("evidenceEpoch", 0)
    head = git(["rev-parse", "HEAD"], root)
    input_set_digest = environment_digest = None
    if contract is not None:
        try:
            captured = inputs.capture_inputs(str(root), contract, (), runner=runner)
        except ValueError:
            captured = None
        if captured is not None:
            input_set_digest = captured["inputSetDigest"]
            environment_digest = captured["environmentDigest"]
    return {
        "owner": binding["owner"], "requirement": binding["requirement"],
        "revision": binding["revision"], "scenario": binding["scenario"],
        "commandDigest": _digest_bytes(command.encode("utf-8")),
        "inputSetDigest": input_set_digest,
        "examinedHeads": [{"root": str(root), "before": head, "after": head}],
        "environmentDigest": environment_digest,
        "evidenceEpoch": evidence_epoch,
    }


def eligible_row(feature_dir, root, binding, command, contract, execution_id, git=None,
                  inputs=execution_inputs, runner=None):
    """See module docstring."""
    feature_dir = Path(feature_dir)
    record_path = feature_dir / "observations" / "{}.json".format(execution_id)
    if not record_path.is_file():
        return False, ["no observation record for execution {}".format(execution_id)]
    try:
        record = json.loads(record_path.read_text(encoding="utf-8"))
    except ValueError as exc:
        return False, ["observation record for execution {} is not valid JSON: {}".format(execution_id, exc)]
    current = current_binding(feature_dir, root, binding, command, contract,
                               git=git, inputs=inputs, runner=runner)
    current["outputDigest"] = read_output_digest(feature_dir, record)
    return validate_record(record, current)


def validate_record(record, current):
    reasons = []
    for field in FRESHNESS_FIELDS:
        if record.get(field) != current.get(field):
            reasons.append("{} changed".format(field))
    if record.get("output", {}).get("digest") != current.get("outputDigest"):
        reasons.append("output digest changed")
    if record.get("output", {}).get("complete") is not True:
        reasons.append("output is not complete")
    if record.get("status") != "PASS":
        reasons.append("record status is not PASS")
    return (not reasons, reasons)
