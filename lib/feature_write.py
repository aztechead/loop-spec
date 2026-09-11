#!/usr/bin/env python3
# Feature-state transactions: lock before reading, preserve the old inode until replace.
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

from requirements import reconcile_inventory, validate_transition


def parse_json(value):
    try:
        parsed = json.loads(value)
        # Python accepts NaN/Infinity by default; feature state must be portable JSON.
        json.dumps(parsed, allow_nan=False)
        return parsed
    except ValueError as exc:
        raise ValueError("invalid JSON; strings must be JSON-quoted") from exc


def read_bounded(path, limit=16 * 1024 * 1024):
    with path.open("rb") as stream:
        content = stream.read(limit + 1)
    if len(content) > limit:
        raise ValueError("{} exceeds {} byte read limit".format(path, limit))
    return content


def sync_directory(path):
    descriptor = os.open(str(path), os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def publish(path, content):
    descriptor, temporary = tempfile.mkstemp(prefix="." + path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(descriptor, "wb") as stream:
            if path.exists():
                os.fchmod(stream.fileno(), stat.S_IMODE(path.stat().st_mode))
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        sync_directory(path.parent)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def _validate_write_keys(dot_path):
    """The set/append path grammar, shared by a single write and every batch entry."""
    if not isinstance(dot_path, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*", dot_path):
        raise ValueError("invalid feature write path")
    keys = dot_path.split(".")
    if keys[0] in ("currentGate", "gateHistory") and os.environ.get("LOOP_SPEC_GATE_WRITE") != "1":
        raise ValueError("{} is written only by lib/graph/gate.sh; use gate.sh open|round|fail|pass".format(keys[0]))
    return keys


def _apply_set_or_append(state, operation, value, keys):
    """Mutate state in place at the dotted path; the one traversal set/append and
    every batch entry share, so a batch's atomicity is just prepare_state's own
    single-pass mutation run more than once before the tail checks below run."""
    dot_path = ".".join(keys)
    target = state
    for key in keys[:-1]:
        if not isinstance(target, dict):
            raise ValueError("{} crosses a non-object value".format(dot_path))
        if target.get(key) is None:
            target[key] = {}
        target = target[key]
    if not isinstance(target, dict):
        raise ValueError("{} requires an object parent".format(dot_path))
    if operation == "append":
        current = target.get(keys[-1])
        if current is not None and not isinstance(current, list):
            raise ValueError("append target at {} is not an array".format(dot_path))
        value = (current or []) + [value]
    target[keys[-1]] = value


def prepare_state(directory, previous, operation, value, keys=()):
    dot_path = ".".join(keys)
    if operation == "replace":
        state = value
    else:
        if previous is None:
            raise ValueError("feature.json not found in {}".format(directory))
        state = parse_json(previous)
        if operation == "ack-remediation":
            if not isinstance(value, dict) or not isinstance(value.get("snapshot"), list) or not value["snapshot"]:
                raise ValueError("ack-remediation requires a non-empty snapshot array")
            artifacts = state.get("artifacts")
            if not isinstance(artifacts, dict):
                raise ValueError("ack-remediation requires artifacts to be an object")
            queue = state.get("pendingRemediationTasks")
            snapshot = value["snapshot"]
            if (not isinstance(queue, list) or queue[:len(snapshot)] != snapshot
                    or artifacts.get("remediationReceipt") != value.get("generation")):
                raise ValueError("pendingRemediationTasks changed before acknowledgment; retry execute preparation")
            receipt = value.get("receipt")
            if not isinstance(receipt, str) or not receipt:
                raise ValueError("ack-remediation requires a non-empty receipt")
            state["pendingRemediationTasks"] = queue[len(snapshot):]
            artifacts["remediationReceipt"] = receipt
        if operation == "reconcile-inventory":
            if "requirementsContract" not in state:
                raise ValueError("reconcile-inventory requires an initialized requirementsContract")
            state["requirementsContract"] = reconcile_inventory(state["requirementsContract"], value)
        if operation == "batch":
            # Every entry applies to the SAME in-memory state before it is ever written,
            # so a later entry's failure raises before write_state_locked runs and the
            # whole batch is still atomic even though prepare_state has no rollback.
            if not isinstance(value, list) or not value:
                raise ValueError("batch requires a non-empty JSON array of entries")
            for entry in value:
                if not isinstance(entry, dict) or set(entry) != {"op", "path", "value"}:
                    raise ValueError("invalid batch entry; each requires op, path, and value")
                if entry["op"] not in ("set", "append"):
                    raise ValueError("batch entries support set or append only")
                entry_keys = _validate_write_keys(entry["path"])
                _apply_set_or_append(state, entry["op"], entry["value"], entry_keys)
        if operation not in ("ack-remediation", "reconcile-inventory", "batch"):
            _apply_set_or_append(state, operation, value, keys)

    if previous is not None:
        approved = parse_json(previous).get("specApproval")
        if approved is not None and state.get("specApproval") != approved:
            raise ValueError("specApproval is immutable; restore approved intent and request a new intent decision")

    old_state = parse_json(previous) if previous is not None else {}
    validate_transition(old_state, state)
    if (previous is not None and "requirementsContract" not in old_state
            and state.get("requirementsContract", {}).get("format") == "v1"):
        raise ValueError("existing legacy state requires explicit migration before v1")

    return state


def state_snapshot(directory):
    path = directory / "feature.json"
    return path.read_bytes() if path.exists() else None


def write_state_locked(directory, state, previous):
    path = directory / "feature.json"
    content = (json.dumps(state, indent=2, ensure_ascii=False, allow_nan=False) + "\n").encode("utf-8")
    if previous is not None:
        publish(directory / "feature.json.bak", previous)
    publish(path, content)


def persist(directory):
    store = Path(__file__).parent / "supervisor" / "store.sh"
    result = subprocess.run(["bash", str(store), "persist", str(directory), "feature-write"],
                            stdout=subprocess.DEVNULL)
    if result.returncode:
        raise OSError("store persist failed for {} (LOOP_SPEC_STORE); local state was written".format(directory))


def participant_registry(directory):
    """Rebind the known tasks sidecar after a checkout relocation."""
    from feature_read import load_state
    directory = Path(directory).absolute()
    if not (directory / "feature.json").exists():
        return None
    pointer = load_state(directory).get("artifacts", {}).get("tasks")
    if not isinstance(pointer, str) or not Path(pointer).is_absolute():
        return None
    source = Path(pointer)
    if (source.name == "tasks.json" and source.parent.name == directory.name
            and source.parent.parent.name == "features" and source.parent.parent.parent.name == ".loop-spec"
            and source.parent != directory):
        return {"tasks": "tasks.json"}
    return None


def begin_operation(directory, token=None, registry=None, bootstrap=True):
    """Capture before reading producer inputs, or validate a caller's original token."""
    from artifact_publication import capture_locked, locked_feature, refuse_pending
    from feature_read import load_state
    directory = Path(directory)
    with locked_feature(directory):
        refuse_pending(directory)
        if registry is None:
            registry = participant_registry(directory)
        feature = load_state(directory)
        if (bootstrap and not feature.get("artifactPublication") and feature.get("schemaVersion") == 7
                and feature.get("currentPhase") != "completed"):
            if token is not None:
                raise ValueError("stale publication token; feature has no matching publication contract")
            from requirements import bootstrap_state
            import uuid
            owner = {"repository": str(uuid.uuid4()), "feature": feature["slug"]}
            feature = bootstrap_state(feature, owner, format="legacy")
            previous = state_snapshot(directory)
            write_state_locked(directory, feature, previous)
            persist(directory)
        current = capture_locked(directory, registry) if feature.get("artifactPublication") else None
        if token is not None and token != current:
            raise ValueError("stale publication token; discard the pending operation")
        return current


def write_operation(directory, operation, value, keys=(), token=None, registry=None):
    """Apply one trusted controller operation with its original ingress token.

    Registry paths come from the controller, never from token input paths.
    """
    directory = Path(directory)
    if operation not in ("replace", "set", "append", "ack-remediation", "reconcile-inventory", "batch"):
        raise ValueError("unknown feature write operation: {}".format(operation))
    if operation in ("set", "append"):
        _validate_write_keys(".".join(keys))
    if operation == "replace" and not isinstance(value, dict):
        raise ValueError("feature state must be one JSON object")
    from artifact_publication import capture_locked, locked_feature, refuse_pending
    # A bare, token-less "replace" is feature-write.sh's only unconditional form and
    # the sole legitimate way feature.json does not yet exist here (finalize and
    # init_workspace guard the not-yet-exists case themselves before calling in).
    with locked_feature(directory, create=(operation == "replace" and token is None)):
        refuse_pending(directory)
        if registry is None:
            registry = participant_registry(directory)
        if token is not None:
            if (not isinstance(token, dict) or type(token.get("generation")) is not int
                    or type(token.get("version")) is not int or token != capture_locked(directory, registry)):
                raise ValueError("stale publication token; discard the pending state update")
        path = directory / "feature.json"
        previous = state_snapshot(directory)
        state = prepare_state(directory, previous, operation, value, keys)
        publication = state.get("artifactPublication")
        if previous is not None and publication:
            old_publication = parse_json(previous).get("artifactPublication")
            if old_publication:
                if publication != old_publication:
                    raise ValueError("artifactPublication is managed by publication transactions")
                publication["generation"] += 1
        write_state_locked(directory, state, previous)
        persist(directory)
        return capture_locked(directory, registry) if token is not None else None


def main(args):
    token = None
    if "--token" in args:
        index = args.index("--token")
        if index != len(args) - 2:
            raise ValueError("--token PATH must be the final arguments")
        token = parse_json(read_bounded(Path(args[index + 1])))
        args = args[:index]
    if len(args) == 2 and args[0] in ("ingress", "ingress-read"):
        print(json.dumps(begin_operation(args[1], token=token, bootstrap=args[0] == "ingress"), sort_keys=True))
        return 0
    operation = "replace"
    keys = []
    if len(args) == 4 and args[0] in ("set", "append"):
        operation, directory, dot_path, raw = args
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*", dot_path):
            raise ValueError("invalid dot_path: {}; array indices are not supported".format(dot_path))
        keys = dot_path.split(".")
    elif len(args) == 3 and args[0] in ("ack-remediation", "reconcile-inventory", "batch"):
        operation, directory, raw = args
    elif len(args) == 2:
        directory, raw = args
    else:
        raise ValueError("usage: feature-write.sh <dir> <json-object> | set|append <dir> <dot_path> <json-value> | batch <dir> <json-array>")

    directory = Path(directory)
    if not directory.is_dir():
        raise ValueError("feature_dir does not exist: {}".format(directory))
    value = parse_json(raw)
    if operation == "replace" and not isinstance(value, dict):
        raise ValueError("feature state must be one JSON object")
    if operation == "batch" and not isinstance(value, list):
        raise ValueError("batch requires a JSON array")

    refreshed = write_operation(directory, operation, value, keys, token=token)
    if refreshed is not None:
        print(json.dumps(refreshed, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except ValueError as exc:
        print("feature-write: {}".format(exc), file=sys.stderr)
        sys.exit(1)
    except OSError as exc:
        print("feature-write: I/O failure: {}".format(exc), file=sys.stderr)
        sys.exit(2)
