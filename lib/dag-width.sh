#!/usr/bin/env bash
# Compute the structural width W of an EXECUTE task DAG.
#
# W is the peak number of tasks that become simultaneously runnable across a
# topological wave simulation (Kahn's algorithm): repeatedly take every task
# whose blockedBy edges are all satisfied, record the size of that ready set,
# mark them done, repeat. W = max ready-set size over all waves.
#
# This is the realized wave-by-wave parallelism the DAG exposes -- the same
# `ready` quantity lib/workflows/execute-dag.js computes per wave, but measured
# uncapped (independent of maxParallelImplementers) and before any dispatch.
# The EXECUTE concurrency ladder reads W to choose subagent vs team vs workflow.
#
# Input: a JSON array of tasks on stdin OR as $1. Each element must have an
#        `id` (string) and a `blockedBy` (array of ids; missing/null = []).
#        The blockedBy passed here must already be the UNION of explicit PLAN.md
#        edges and synthetic file-overlap edges (execute SKILL Step 2b).
#
# Output: a single integer W on stdout. Empty task set -> 0. Single task -> 1.
#         A dependency cycle (no task ever becomes ready) -> exit 3 with the
#         partial W computed so far on stderr; the orchestrator treats an
#         unresolvable cycle as a deadlock escalation, not a width signal.
#
# Always reads ids/edges as opaque strings; never executes task content.
set -euo pipefail

input="${1:-}"
if [[ -z "$input" ]]; then
  input="$(cat)"
fi

printf '%s' "$input" | python3 -c '
import json, sys

try:
    tasks = json.load(sys.stdin)
except Exception as e:
    sys.stderr.write("dag-width: invalid JSON: %s\n" % e)
    sys.exit(2)

if not isinstance(tasks, list):
    sys.stderr.write("dag-width: expected a JSON array of tasks\n")
    sys.exit(2)

ids = []
deps = {}
for t in tasks:
    tid = t.get("id")
    if tid is None:
        sys.stderr.write("dag-width: task missing id\n")
        sys.exit(2)
    ids.append(tid)
    deps[tid] = list(t.get("blockedBy") or [])

idset = set(ids)
# Ignore edges pointing at ids not in the set (defensive; a dangling dep
# cannot block, so it never constrains width).
for tid in deps:
    deps[tid] = [d for d in deps[tid] if d in idset]

if not ids:
    print(0)
    sys.exit(0)

done = set()
width = 0
remaining = set(ids)
while remaining:
    ready = [tid for tid in remaining if all(d in done for d in deps[tid])]
    if not ready:
        # Cycle or otherwise unsatisfiable remainder.
        sys.stderr.write(
            "dag-width: dependency cycle among %d task(s); partial W=%d\n"
            % (len(remaining), width)
        )
        print(width)
        sys.exit(3)
    width = max(width, len(ready))
    for tid in ready:
        done.add(tid)
        remaining.discard(tid)

print(width)
'
