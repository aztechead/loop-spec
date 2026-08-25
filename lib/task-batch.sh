#!/usr/bin/env bash
# task-batch.sh - Collapse same-shape PLAN tasks into one dispatch.
#
# Why: twenty identical one-line edits should not cost twenty implementer
# seats. Superpowers v6.3.0 batches small same-shape work. Fail-closed: no
# batchGroup, a blockedBy edge, or overlapping files with a different group
# keeps today's one-task-one-dispatch.
#
# Usage:
#   task-batch.sh collapse <tasks.json>
#
# Output: a JSON array. Ungrouped tasks pass through. A collapsed group is one
# object with the first member's id, unioned files, memberIds[], and the shared
# verifyCommand. Reviewers assert every listed file appears in the diff.
#
# Exit: 0 success, 2 usage / unreadable JSON.
set -euo pipefail

[[ "${1:-}" == "collapse" && $# -eq 2 ]] || { echo "usage: task-batch.sh collapse <tasks.json>" >&2; exit 2; }
file="$2"
[[ -f "$file" ]] || { echo "task-batch.sh: no such file $file" >&2; exit 2; }

python3 - "$file" <<'PY'
from __future__ import print_function
import json, sys

path = sys.argv[1]
try:
    tasks = json.load(open(path))
except (OSError, ValueError) as exc:
    sys.stderr.write("task-batch.sh: %s\n" % exc)
    sys.exit(2)
if not isinstance(tasks, list):
    sys.stderr.write("task-batch.sh: tasks must be a JSON array\n")
    sys.exit(2)

def files_of(t):
    return list(t.get("files") or [])

groups = {}
for t in tasks:
    if not isinstance(t, dict):
        continue
    key = t.get("batchGroup")
    if isinstance(key, str) and key.strip():
        groups.setdefault(key, []).append(t)

collapsible = {}
for key, members in groups.items():
    if len(members) < 2:
        continue
    ids = [m.get("id") for m in members]
    member_ids = set(ids)
    vcs = {(m.get("verifyCommand") or "").strip() for m in members}
    if len(vcs) != 1 or not next(iter(vcs)):
        continue
    blocked = False
    for m in members:
        for dep in (m.get("blockedBy") or []):
            if dep not in member_ids:
                blocked = True
    if blocked:
        continue
    seen = []
    overlap = False
    for m in members:
        for f in files_of(m):
            if f in seen:
                overlap = True
            seen.append(f)
    if overlap:
        continue
    first = dict(members[0])
    first["files"] = seen
    first["memberIds"] = ids
    first["brief"] = (first.get("brief") or first.get("subject") or "") + \
        "\n\nBatch %s: apply the same change to every listed file." % key
    collapsible[key] = first

emitted = set()
out = []
for t in tasks:
    if not isinstance(t, dict):
        out.append(t)
        continue
    key = t.get("batchGroup")
    if isinstance(key, str) and key in collapsible:
        if key not in emitted:
            out.append(collapsible[key])
            emitted.add(key)
        continue
    out.append(t)

print(json.dumps(out, indent=2))
PY
