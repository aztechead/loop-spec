#!/usr/bin/env bash
# plan-conflicts.sh - Emit the EXECUTE pre-flight conflict table from tasks.json.
#
# Why: "the scan is clean" without rows is not a scan. Superpowers v6.3.0
# records every file-sharing pair and every consume/produce mismatch before
# Task 1. The table is the probe; the ruling is still a model judgment after it.
#
# Usage:
#   plan-conflicts.sh table <tasks.json>
#   plan-conflicts.sh edges <tasks.json>
#
# `table` output: JSON {pairs:[{a,b,files,status}], interfaces:[{task,problem}],
# rows:N, reason:...}. status=overlap for shared files.
#
# `edges` is print-only: it NEVER writes <tasks.json>. It infers a blockedBy edge for
# every task whose interfaces.consumes, goal, or brief names another task id it does
# not already wait on ("consumes: task-003's module path"). It prints the updated array on stdout
# (the same JSON `table` readers expect), reporting `edge <task> -> <dep>` per addition
# on stderr. The caller decides what becomes durable: `cycle-
# driver.sh plan tasks` (lib/graph/driver.py cmd_plan) feeds this the extractor's
# output and publishes what comes back through publish_artifact under its held
# ingress token -- the one path allowed to write the registered tasks.json
# (lib/harness.sh protected-path). This script used to write the file itself, outside
# that publication boundary; a security hardening pass removed the write here rather
# than teach a Bash script to hold the token.
# Why infer at all: a live PLAN critique spent a round on exactly this omission while
# EXECUTE would have added the same edge from the interface row; inferring it before
# the render means the plan the challenger reads already has it. An edge that would
# close a cycle is refused (nothing printed, exit 1).
# Exit: 0 with JSON on stdout (fail-open for a missing optional interfaces field), 1 an
# inferred edge would close a cycle (nothing printed), 2 usage / unreadable.
set -euo pipefail

cmd="${1:-}"
[[ ( "$cmd" == "table" || "$cmd" == "edges" ) && $# -eq 2 ]] || {
  echo "usage: plan-conflicts.sh table|edges <tasks.json>" >&2
  exit 2
}
file="$2"
[[ -f "$file" ]] || { echo "plan-conflicts.sh: no such file $file" >&2; exit 2; }

python3 - "$cmd" "$file" <<'PY'
from __future__ import print_function
import json, re, sys

cmd, path = sys.argv[1], sys.argv[2]
try:
    tasks = json.load(open(path))
except (OSError, ValueError) as exc:
    sys.stderr.write("plan-conflicts.sh: %s\n" % exc)
    sys.exit(2)
if not isinstance(tasks, list):
    sys.stderr.write("plan-conflicts.sh: tasks must be a JSON array\n")
    sys.exit(2)

if cmd == "edges":
    ids = {t.get("id") for t in tasks if isinstance(t, dict)}
    ref = re.compile(r"\btask-\d{3}\b", re.I)
    deps = {t.get("id"): set(t.get("blockedBy") or []) for t in tasks if isinstance(t, dict)}

    def reaches(src, dst, seen=None):
        seen = set() if seen is None else seen
        for d in deps.get(src, ()):
            if d == dst:
                return True
            if d not in seen:
                seen.add(d)
                if reaches(d, dst, seen):
                    return True
        return False

    added = []
    for t in tasks:
        if not isinstance(t, dict):
            continue
        iface = t.get("interfaces") if isinstance(t.get("interfaces"), dict) else {}
        consumes = iface.get("consumes")
        parts = consumes if isinstance(consumes, list) else [consumes]
        # plan-tasks.sh extract names the heading text "subject"; an older sidecar wrote
        # "brief", and the gate's parity check treats them as one field.
        text = " ".join(str(x or "") for x in parts + [t.get("goal") or "", t.get("brief") or "", t.get("subject") or ""])
        for dep in sorted({m.lower() for m in ref.findall(text)}):
            if dep == t.get("id") or dep not in ids or dep in deps[t.get("id")]:
                continue
            if reaches(dep, t.get("id")):
                sys.stderr.write("plan-conflicts.sh: %s -> %s would close a cycle; nothing written\n" % (t.get("id"), dep))
                sys.exit(1)
            deps[t.get("id")].add(dep)
            added.append((t.get("id"), dep))
    if added:
        for t in tasks:
            if isinstance(t, dict) and t.get("id") in deps:
                extra = [d for d in sorted(deps[t.get("id")]) if d not in (t.get("blockedBy") or [])]
                if extra:
                    t["blockedBy"] = list(t.get("blockedBy") or []) + extra
    # print-only: the caller (cycle-driver.sh plan tasks) publishes the result through
    # publish_artifact under its held token; this script never writes <tasks.json>.
    for a, b in added:
        sys.stderr.write("edge %s -> %s\n" % (a, b))
    sys.stderr.write("plan-conflicts: %d edge(s) inferred\n" % len(added))
    print(json.dumps(tasks, indent=2))
    sys.exit(0)

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
