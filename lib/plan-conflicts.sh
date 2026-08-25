#!/usr/bin/env bash
# plan-conflicts.sh - Emit the EXECUTE pre-flight conflict table from tasks.json.
#
# Why: "the scan is clean" without rows is not a scan. Superpowers v6.3.0
# records every file-sharing pair and every consume/produce mismatch before
# Task 1. The table is the probe; the ruling is still a model judgment after it.
#
# Usage:
#   plan-conflicts.sh table <tasks.json>
#
# Output: JSON {pairs:[{a,b,files,status}], interfaces:[{task,problem}],
# rows:N, reason:...}. status=overlap for shared files.
# Exit: 0 always with JSON (fail-open for a missing optional interfaces field),
# 2 usage / unreadable.
set -euo pipefail

[[ "${1:-}" == "table" && $# -eq 2 ]] || {
  echo "usage: plan-conflicts.sh table <tasks.json>" >&2
  exit 2
}
file="$2"
[[ -f "$file" ]] || { echo "plan-conflicts.sh: no such file $file" >&2; exit 2; }

python3 - "$file" <<'PY'
from __future__ import print_function
import json, sys

path = sys.argv[1]
try:
    tasks = json.load(open(path))
except (OSError, ValueError) as exc:
    sys.stderr.write("plan-conflicts.sh: %s\n" % exc)
    sys.exit(2)
if not isinstance(tasks, list):
    sys.stderr.write("plan-conflicts.sh: tasks must be a JSON array\n")
    sys.exit(2)

pairs = []
for i, a in enumerate(tasks):
    if not isinstance(a, dict):
        continue
    af = set(a.get("files") or [])
    for b in tasks[i + 1:]:
        if not isinstance(b, dict):
            continue
        shared = sorted(af & set(b.get("files") or []))
        if shared:
            pairs.append({
                "a": a.get("id"),
                "b": b.get("id"),
                "files": shared,
                "status": "overlap",
            })

interfaces = []
produced = {}
for t in tasks:
    if not isinstance(t, dict):
        continue
    iface = t.get("interfaces") or {}
    if isinstance(iface, dict):
        prod = iface.get("produces")
        if isinstance(prod, str) and prod.strip() and prod.strip().lower() != "none":
            produced[prod.strip()] = t.get("id")
        elif isinstance(prod, list):
            for p in prod:
                if isinstance(p, str) and p.strip():
                    produced[p.strip()] = t.get("id")

for t in tasks:
    if not isinstance(t, dict):
        continue
    iface = t.get("interfaces") or {}
    consumes = []
    if isinstance(iface, dict):
        c = iface.get("consumes")
        if isinstance(c, str) and c.strip() and c.strip().lower() != "none":
            consumes = [c.strip()]
        elif isinstance(c, list):
            consumes = [x.strip() for x in c if isinstance(x, str) and x.strip()]
    for item in consumes:
        if item not in produced:
            interfaces.append({
                "task": t.get("id"),
                "problem": "consumes %r with no producer" % item,
            })

rows = len(pairs) + len(interfaces)
reason = "clean" if rows == 0 else "conflicts"
print(json.dumps({
    "pairs": pairs,
    "interfaces": interfaces,
    "rows": rows,
    "reason": reason,
}))
PY
