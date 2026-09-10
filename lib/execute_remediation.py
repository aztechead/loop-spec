#!/usr/bin/env python3
# Publish VERIFY findings before acknowledging their queue snapshot.
# Usage: execute_remediation.py <feature-dir> <tasks-path>
# Output: {registered:N}; on failure {registered:0,error:message} and exit 1.
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

from feature_read import load_state
from feature_write import main as write_feature, publish, read_bounded, write_operation
from artifact_publication import capture_locked, locked_feature, publish_locked, stage


def register(feature_dir, sidecar, reader=load_state, writer=write_feature, publisher=publish, token=None, token_output=None):
    feature_dir, sidecar = Path(feature_dir), Path(sidecar)
    registry = {"tasks": str(sidecar.absolute())}
    with locked_feature(feature_dir):
        initial = load_state(feature_dir)
        guarded = initial.get("artifactPublication") is not None
        if guarded:
            current = capture_locked(feature_dir, registry)
            if token is None:
                token = current
            elif token != current:
                raise ValueError("stale publication token; discard pending remediation")
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
                if guarded:
                    refreshed = write_operation(feature_dir, "set", generation, ["artifacts", "remediationReceipt"],
                                                token=token, registry=registry)
                    if token_output:
                        publish(Path(token_output), json.dumps(refreshed).encode("utf-8"))
                else:
                    writer(["set", str(feature_dir), "artifacts.remediationReceipt", json.dumps(generation)])
            return 0
        tasks = json.loads(read_bounded(sidecar))
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
            task.setdefault("files", [])
            task.setdefault("blockedBy", [])
            if task.get("acceptanceCriteria") in (None, []):
                task["acceptanceCriteria"] = [task.get("subject") or task.get("brief")]
            if task.get("verifyCommand") in (None, ""):
                task["verifyCommand"] = default_verify
            if not isinstance(task["verifyCommand"], str) or not task["verifyCommand"].strip():
                raise ValueError("{} needs verifyCommand or commands.test before EXECUTE can dispatch it".format(task_id))
            task["retries"] = 0
            task.pop("status", None)
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
        receipt = hashlib.sha256(json.dumps([generation, queue], sort_keys=True,
                                           allow_nan=False).encode("utf-8")).hexdigest()
        if guarded:
            files = [{"source": stage(feature_dir, "remediation-" + uuid.uuid4().hex, candidate.encode("utf-8")),
                      "target": "tasks"}] if added else []
            updates = [{"path": "pendingRemediationTasks", "value": []},
                       {"path": "artifacts.remediationReceipt", "value": receipt}]
            with locked_feature(feature_dir):
                refreshed = publish_locked(feature_dir, token, {"version": 1, "files": files, "updates": updates},
                                           registry=registry, allowed_updates={entry["path"] for entry in updates})
            if token_output:
                publish(Path(token_output), json.dumps(refreshed).encode("utf-8"))
        else:
            if added:
                publisher(sidecar, candidate.encode("utf-8"))
            writer(["ack-remediation", str(feature_dir), json.dumps({"snapshot": queue,
                    "generation": generation, "receipt": receipt})])
        return len(added)


if __name__ == "__main__":
    try:
        if len(sys.argv) != 3:
            raise ValueError("usage: execute_remediation.py <feature-dir> <tasks-path>")
        incoming = os.environ.get("LOOP_SPEC_PUBLICATION_TOKEN")
        token = json.loads(read_bounded(Path(incoming))) if incoming else None
        print(json.dumps({"registered": register(*sys.argv[1:], token=token,
                                                token_output=os.environ.get("LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT"))}))
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        message = "execute-prepare: remediation intake failed: {}".format(exc)
        print(message, file=sys.stderr)
        print(json.dumps({"registered": 0, "error": message}))
        sys.exit(1)
