#!/usr/bin/env python3
# Feature-state transactions: lock before reading, preserve the old inode until replace.
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile


def parse_json(value):
    try:
        parsed = json.loads(value)
        # Python accepts NaN/Infinity by default; feature state must be portable JSON.
        json.dumps(parsed, allow_nan=False)
        return parsed
    except ValueError as exc:
        raise ValueError("invalid JSON; strings must be JSON-quoted") from exc


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
        directory = os.open(str(path.parent), os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def main(args):
    operation = "replace"
    keys = []
    if len(args) == 4 and args[0] in ("set", "append"):
        operation, directory, dot_path, raw = args
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*", dot_path):
            raise ValueError("invalid dot_path: {}; array indices are not supported".format(dot_path))
        keys = dot_path.split(".")
        if keys[0] in ("currentGate", "gateHistory") and os.environ.get("LOOP_SPEC_GATE_WRITE") != "1":
            raise ValueError("{} is written only by lib/graph/gate.sh; use gate.sh open|round|fail|pass".format(keys[0]))
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

    path = directory / "feature.json"
    # Never unlink the lock: waiters must keep sharing the same inode after a crash.
    with (directory / ".feature-write.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        previous = path.read_bytes() if path.exists() else None
        if operation == "replace":
            state = value
        else:
            if previous is None:
                raise ValueError("feature.json not found in {}".format(directory))
            state = parse_json(previous)
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

        content = (json.dumps(state, indent=2, ensure_ascii=False, allow_nan=False) + "\n").encode("utf-8")
        if previous is not None:
            publish(directory / "feature.json.bak", previous)
        publish(path, content)
        # Store adapters see writes in the same order as local readers. An adapter
        # must not invoke the writer recursively for this feature while persisting.
        store = Path(__file__).parent / "supervisor" / "store.sh"
        result = subprocess.run(["bash", str(store), "persist", str(directory), "feature-write"],
                                stdout=subprocess.DEVNULL)
        if result.returncode:
            raise OSError("store persist failed for {} (LOOP_SPEC_STORE); local state was written".format(directory))
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
