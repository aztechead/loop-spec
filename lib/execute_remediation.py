#!/usr/bin/env python3
# Publish VERIFY findings before acknowledging their queue snapshot.
# Usage: execute_remediation.py <feature-dir> <tasks-path>
# Output: {registered:N}; on failure {registered:0,error:message} and exit 1.
import fcntl
import hashlib
import json
from pathlib import Path
import subprocess
import sys

from feature_read import load_state
from feature_write import main as write_feature, publish
from verify_command import validate as validate_command


def normalize_task(raw, default_verify, index):
    """The same full-shape contract at VERIFY intake and EXECUTE publication."""
    label = "pendingRemediationTasks[{}]".format(index)
    if not isinstance(raw, dict):
        raise ValueError(label + " must be a task object")
    task = dict(raw)
    for key, value in (("id", task.get("id")), ("subject", task.get("subject") or task.get("brief"))):
        if not isinstance(value, str) or not value.strip():
            raise ValueError(label + "." + key + " must be a non-empty string")
        task[key] = value
    for key in ("files", "blockedBy"):
        task.setdefault(key, [])
    if task.get("verifyCommand") in (None, ""):
        task["verifyCommand"] = default_verify
    if not isinstance(task["verifyCommand"], str) or not task["verifyCommand"].strip():
        raise ValueError(label + " needs verifyCommand or commands.test")
    validate_command(task["verifyCommand"])
    if task.get("acceptanceCriteria") in (None, []):
        task["acceptanceCriteria"] = [task["subject"]]
    for key in ("files", "blockedBy", "acceptanceCriteria"):
        values = task[key]
        if not isinstance(values, list) or any(not isinstance(v, str) or not v.strip() for v in values):
            raise ValueError(label + "." + key + " must be an array of non-empty strings")
    task["retries"] = 0
    task.pop("status", None)
    return task


def normalize_queue(queue, default_verify):
    if not isinstance(queue, list):
        raise ValueError("pendingRemediationTasks must be an array")
    return [normalize_task(raw, default_verify, index) for index, raw in enumerate(queue)]


def register(feature_dir, sidecar, reader=load_state, writer=write_feature, publisher=publish):
    feature_dir, sidecar = Path(feature_dir), Path(sidecar)
    # Serialize preparers without blocking appenders on the feature writer's lock.
    with (feature_dir / ".execute-remediation.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        feature = reader(str(feature_dir))
        queue = feature.get("pendingRemediationTasks", [])
        if not isinstance(queue, list):
            raise ValueError("pendingRemediationTasks must be an array; repair the queue before retrying EXECUTE")
        artifacts = feature.get("artifacts")
        if not isinstance(artifacts, dict):
            if not queue:
                return 0
            raise ValueError("artifacts must be an object with the tasks path")
        generation = artifacts.get("remediationReceipt")
        if generation is not None and not isinstance(generation, str):
            raise ValueError("artifacts.remediationReceipt must be a string")
        if not queue:
            if generation is not None:
                # Local acknowledgment can outlive a failed store persist.
                writer(["set", str(feature_dir), "artifacts.remediationReceipt", json.dumps(generation)])
            return 0
        tasks = json.loads(sidecar.read_text(encoding="utf-8"))
        if not isinstance(tasks, list) or any(not isinstance(task, dict) for task in tasks):
            raise ValueError("{} must be an array of task objects".format(sidecar))
        ids = {task.get("id") for task in tasks}
        published = {task["remediationReceipt"]: task for task in tasks
                     if isinstance(task.get("remediationReceipt"), str)}
        commands = feature.get("commands") or {}
        default_verify = commands.get("test") if isinstance(commands, dict) else None
        added = []
        renamed = {}
        for index, raw in enumerate(queue):
            if not isinstance(raw, dict):
                raise ValueError("pendingRemediationTasks[{}] must be a task object".format(index))
            task = dict(raw)
            task_id = task.get("id")
            if not isinstance(task_id, str) or not task_id.strip():
                raise ValueError("pendingRemediationTasks[{}].id must be a non-empty string".format(index))
            # Appending a suffix must not change identities already published before a crash.
            receipt = hashlib.sha256(json.dumps([generation, index, raw], sort_keys=True,
                                               allow_nan=False).encode("utf-8")).hexdigest()
            if receipt in published:
                renamed[task_id] = published[receipt]["id"] if task_id not in renamed else None
                continue
            task = normalize_task(raw, default_verify, index)
            task["remediationReceipt"] = receipt
            if task_id in ids:
                task["id"] = task_id + "+remediate-" + receipt
                if task["id"] in ids:
                    raise ValueError("remediation task ID collision for {}; repair the queue".format(task["id"]))
            if task_id in renamed:
                renamed[task_id] = None
            else:
                renamed[task_id] = task["id"]
            ids.add(task["id"])
            added.append(task)
        for task in added:
            blockers = task.get("blockedBy")
            if not isinstance(blockers, list) or any(not isinstance(item, str) for item in blockers):
                raise ValueError("{}.blockedBy must be an array of strings".format(task["id"]))
            blockers = list(blockers)
            task["blockedBy"] = blockers
            for index, blocker in enumerate(blockers):
                if blocker in renamed:
                    if renamed[blocker] is None:
                        raise ValueError("{}.blockedBy names ambiguous queued ID {}; use distinct task IDs".format(task["id"], blocker))
                    blockers[index] = renamed[blocker]
        candidate = json.dumps(tasks + added, indent=2, allow_nan=False) + "\n"
        lint = subprocess.run(["bash", str(Path(__file__).parent / "artifact-lint.sh"), "tasks", "-"],
                              input=candidate, text=True, capture_output=True)
        if lint.returncode:
            raise ValueError("remediation sidecar validation failed; repair pendingRemediationTasks: "
                             + (lint.stdout or lint.stderr).strip())
        if added:
            publisher(sidecar, candidate.encode("utf-8"))
        receipt = hashlib.sha256(json.dumps([generation, queue], sort_keys=True,
                                           allow_nan=False).encode("utf-8")).hexdigest()
        writer(["ack-remediation", str(feature_dir), json.dumps({"snapshot": queue,
                "generation": generation, "receipt": receipt})])
        return len(added)


if __name__ == "__main__":
    try:
        if len(sys.argv) != 3:
            raise ValueError("usage: execute_remediation.py <feature-dir> <tasks-path> | --normalize <default-verify>")
        if sys.argv[1] == "--normalize":
            print(json.dumps(normalize_queue(json.load(sys.stdin), sys.argv[2])))
        else:
            print(json.dumps({"registered": register(*sys.argv[1:])}))
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        message = "execute-prepare: remediation intake failed: {}".format(exc)
        print(message, file=sys.stderr)
        print(json.dumps({"registered": 0, "error": message}))
        sys.exit(1)
