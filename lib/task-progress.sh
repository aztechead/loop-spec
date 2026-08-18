#!/usr/bin/env bash
# Record which PLAN tasks have been published, so resume continues remaining
# work instead of rediscovering progress from git.
#
# Why: cycle resume used to pay a full repository-wide suite, and EXECUTE
# "re-ran from scratch" by inferring merges from live branch state. Both are
# archaeology. PLAN already persisted the task list as tasks.json; the only
# missing fact is which ids have been published onto feat/{slug}. This probe
# is that fact: one file, one status field, readable without a checkout.
#
# Usage:
#   task-progress.sh done PATH            ids with status=done, one per line
#   task-progress.sh remaining PATH       ids not yet done, one per line
#   task-progress.sh mark-done PATH ID    set that task's status to done
#
# A missing or empty status is pending. Exit: 0 ok, 1 unknown id / unreadable
# file, 2 bad invocation.
set -euo pipefail

usage() {
  echo "usage: task-progress.sh done PATH | remaining PATH | mark-done PATH ID" >&2
  exit 2
}

cmd="${1:-}"
path="${2:-}"
case "$cmd" in
  done|remaining)
    [[ -n "$path" && $# -eq 2 ]] || usage
    ;;
  mark-done)
    [[ -n "$path" && -n "${3:-}" && $# -eq 3 ]] || usage
    ;;
  *) usage ;;
esac

python3 - "$cmd" "$path" "${3:-}" <<'PY'
import json
import os
import sys

cmd, path, task_id = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    with open(path, "r", encoding="utf-8") as fh:
        tasks = json.load(fh)
except OSError as exc:
    print("task-progress: cannot read %s: %s" % (path, exc), file=sys.stderr)
    sys.exit(1)
except json.JSONDecodeError as exc:
    print("task-progress: %s is not JSON: %s" % (path, exc), file=sys.stderr)
    sys.exit(1)

if not isinstance(tasks, list):
    print("task-progress: %s must be a JSON array" % path, file=sys.stderr)
    sys.exit(1)


def is_done(task):
    return isinstance(task, dict) and task.get("status") == "done"


if cmd in ("done", "remaining"):
    want_done = cmd == "done"
    for task in tasks:
        if not isinstance(task, dict):
            continue
        tid = task.get("id")
        if not isinstance(tid, str) or not tid:
            continue
        if is_done(task) == want_done:
            print(tid)
    sys.exit(0)

found = False
for task in tasks:
    if isinstance(task, dict) and task.get("id") == task_id:
        task["status"] = "done"
        found = True
        break
if not found:
    print("task-progress: unknown task id %s in %s" % (task_id, path), file=sys.stderr)
    sys.exit(1)

tmp = path + ".tmp"
try:
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(tasks, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, path)
except OSError as exc:
    try:
        os.remove(tmp)
    except OSError:
        pass
    print("task-progress: cannot write %s: %s" % (path, exc), file=sys.stderr)
    sys.exit(1)
PY
