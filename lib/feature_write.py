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
        target = state
        if operation not in ("ack-remediation", "reconcile-inventory"):
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


def main(args):
    token = None
    if "--token" in args:
        index = args.index("--token")
        if index != len(args) - 2:
            raise ValueError("--token PATH must be the final arguments")
        token = parse_json(read_bounded(Path(args[index + 1])))
        args = args[:index]
    operation = "replace"
    keys = []
    if len(args) == 4 and args[0] in ("set", "append"):
        operation, directory, dot_path, raw = args
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*", dot_path):
            raise ValueError("invalid dot_path: {}; array indices are not supported".format(dot_path))
        keys = dot_path.split(".")
        if keys[0] in ("currentGate", "gateHistory") and os.environ.get("LOOP_SPEC_GATE_WRITE") != "1":
            raise ValueError("{} is written only by lib/graph/gate.sh; use gate.sh open|round|fail|pass".format(keys[0]))
    elif len(args) == 3 and args[0] in ("ack-remediation", "reconcile-inventory"):
        operation, directory, raw = args
    elif len(args) == 2:
        directory, raw = args
    else:
        raise ValueError("usage: feature-write.sh <dir> <json-object> | set|append <dir> <dot_path> <json-value>")

    directory = Path(directory)
    if not directory.is_dir():
        raise ValueError("feature_dir does not exist: {}".format(directory))
    value = parse_json(raw)
    if operation == "replace" and not isinstance(value, dict):
        raise ValueError("feature state must be one JSON object")

    from artifact_publication import capture_locked, locked_feature, refuse_pending
    with locked_feature(directory):
        refuse_pending(directory)
        if token is not None:
            if (not isinstance(token, dict) or type(token.get("generation")) is not int
                    or type(token.get("version")) is not int or token != capture_locked(directory)):
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
        if token is not None:
            print(json.dumps(capture_locked(directory), sort_keys=True))
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
