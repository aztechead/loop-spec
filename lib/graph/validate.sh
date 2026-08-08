#!/usr/bin/env bash
# Validate a loop-spec workflow graph against schema vocabulary + referential rules.
#
# Usage:
#   graph/validate.sh <graph.json>
#
# Output: one `FLAG <file>:<pointer>: <message>` per defect, then
#   graph-validate: ok
#   graph-validate: <n> flag(s)
# Exit: 0 clean, 1 any flag, 2 bad invocation.
#
# Referential rules beyond JSON shape:
#   - route.condition must be {probe,expects}; probe path must be an executable file
#   - edge endpoints must name declared nodes
#   - every node reachable from entry
#   - loop edges require numeric ceiling (+ strategy)
#   - fanin edges require join
#   - chain/route/fanout/fanin subgraph must be a DAG (loop edges excluded)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCHEMA="$REPO_ROOT/graph/schema.json"

if [[ $# -ne 1 ]]; then
  echo "usage: validate.sh <graph.json>" >&2
  exit 2
fi

GRAPH_PATH="$1"
if [[ ! -f "$GRAPH_PATH" || ! -r "$GRAPH_PATH" ]]; then
  echo "graph-validate: cannot read: $GRAPH_PATH" >&2
  exit 2
fi
if [[ ! -f "$SCHEMA" ]]; then
  echo "graph-validate: schema missing: $SCHEMA" >&2
  exit 2
fi

# Resolve to absolute for stable FLAG paths
GRAPH_ABS="$(cd "$(dirname "$GRAPH_PATH")" && pwd)/$(basename "$GRAPH_PATH")"

python3 - "$GRAPH_ABS" "$SCHEMA" "$REPO_ROOT" <<'PY'
from __future__ import print_function

import json
import os
import sys

graph_path, schema_path, repo_root = sys.argv[1], sys.argv[2], sys.argv[3]
flags = []

def flag(pointer, message):
    flags.append("FLAG %s:%s: %s" % (graph_path, pointer, message))

try:
    with open(graph_path, "r", encoding="utf-8") as fh:
        graph = json.load(fh)
except Exception as exc:
    print("graph-validate: cannot parse %s: %s" % (graph_path, exc), file=sys.stderr)
    sys.exit(2)

try:
    with open(schema_path, "r", encoding="utf-8") as fh:
        schema = json.load(fh)
except Exception as exc:
    print("graph-validate: cannot parse schema: %s" % exc, file=sys.stderr)
    sys.exit(2)

node_kinds = set(schema["definitions"]["node"]["properties"]["kind"]["enum"])
edge_kinds = set(schema["definitions"]["edge"]["properties"]["kind"]["enum"])
state_keys = set(schema["definitions"]["stateKey"]["enum"])
effort_vals = set(schema["definitions"]["effort"]["enum"])
acyclic_kinds = {"chain", "route", "fanout", "fanin"}

if not isinstance(graph, dict):
    flag("/", "graph must be a JSON object")
    for line in flags:
        print(line)
    print("graph-validate: %d flag(s)" % len(flags))
    sys.exit(1)

nodes = graph.get("nodes")
edges = graph.get("edges")
if not isinstance(nodes, list) or not nodes:
    flag("/nodes", "nodes must be a non-empty array")
    nodes = []
if not isinstance(edges, list):
    flag("/edges", "edges must be an array")
    edges = []

entry = graph.get("entry")
if entry is None and nodes:
    entry = nodes[0].get("id")
entries = entry if isinstance(entry, list) else ([entry] if entry else [])

node_ids = []
node_by_id = {}
for i, node in enumerate(nodes):
    ptr = "/nodes/%d" % i
    if not isinstance(node, dict):
        flag(ptr, "node must be an object")
        continue
    nid = node.get("id")
    if not isinstance(nid, str) or not nid:
        flag(ptr + "/id", "node id required")
        continue
    if nid in node_by_id:
        flag(ptr + "/id", "duplicate node id %r" % nid)
    node_ids.append(nid)
    node_by_id[nid] = node
    kind = node.get("kind")
    if kind not in node_kinds:
        flag(ptr + "/kind", "unknown node kind %r" % kind)
    for field in ("reads", "writes"):
        vals = node.get(field)
        if not isinstance(vals, list):
            flag(ptr + "/" + field, "%s must be an array" % field)
            continue
        for j, key in enumerate(vals):
            if key not in state_keys:
                flag("%s/%s/%d" % (ptr, field, j), "state key %r not in schema key space" % key)
    effort = node.get("effort")
    if effort not in effort_vals:
        flag(ptr + "/effort", "effort must be system1|system2")
    # Gate skippable must name a licensing probe
    skippable = node.get("skippable")
    if skippable is not None:
        if kind != "gate":
            flag(ptr + "/skippable", "only gate nodes may declare skippable")
        elif not isinstance(skippable, dict) or not skippable.get("probe"):
            flag(ptr + "/skippable", "skippable gate must name a licensing probe")
        else:
            probe = skippable["probe"]
            path = probe if os.path.isabs(probe) else os.path.join(repo_root, probe)
            if not (os.path.isfile(path) and os.access(path, os.X_OK)):
                flag(ptr + "/skippable/probe", "licensing probe not executable: %s" % probe)
    if node.get("authorizesDelivery") is True and effort == "system1":
        flag(ptr + "/effort", "delivery-authorizing node may not default to system1")

idset = set(node_ids)
for e in entries:
    if e not in idset:
        flag("/entry", "entry names undeclared node %r" % e)

for i, edge in enumerate(edges):
    ptr = "/edges/%d" % i
    if not isinstance(edge, dict):
        flag(ptr, "edge must be an object")
        continue
    kind = edge.get("kind")
    if kind not in edge_kinds:
        flag(ptr + "/kind", "unknown edge kind %r" % kind)
    frm = edge.get("from")
    to = edge.get("to")
    if frm not in idset:
        flag(ptr + "/from", "undeclared node %r" % frm)
    if to not in idset:
        flag(ptr + "/to", "undeclared node %r" % to)

    if kind == "route":
        cond = edge.get("condition")
        if not isinstance(cond, dict):
            flag(ptr + "/condition", "route condition must be {probe, expects} object, not prose")
        else:
            extras = set(cond.keys()) - {"probe", "expects"}
            if extras:
                flag(ptr + "/condition", "route condition additionalProperties not allowed: %s" % sorted(extras))
            if "probe" not in cond or "expects" not in cond:
                flag(ptr + "/condition", "route condition requires probe and expects")
            else:
                if not isinstance(cond["probe"], str) or not isinstance(cond["expects"], str):
                    flag(ptr + "/condition", "probe and expects must be strings")
                else:
                    probe = cond["probe"]
                    path = probe if os.path.isabs(probe) else os.path.join(repo_root, probe)
                    if not os.path.isfile(path):
                        flag(ptr + "/condition/probe", "probe path does not exist: %s" % probe)
                    elif not os.access(path, os.X_OK):
                        flag(ptr + "/condition/probe", "probe path is not executable: %s" % probe)

    if kind == "loop":
        ceiling = edge.get("ceiling")
        if not isinstance(ceiling, (int, float)) or isinstance(ceiling, bool) or ceiling <= 0:
            flag(ptr + "/ceiling", "loop edge requires numeric ceiling > 0")
        strategy = edge.get("strategy")
        if strategy not in ("unroll", "contain"):
            flag(ptr + "/strategy", "loop strategy must be unroll|contain")

    if kind == "fanin":
        if not edge.get("join"):
            flag(ptr + "/join", "fanin edge requires a join rule")

# Reachability from entry (following all edge kinds)
if idset and entries:
    adj = {nid: [] for nid in idset}
    for edge in edges:
        if not isinstance(edge, dict):
            continue
        frm, to = edge.get("from"), edge.get("to")
        if frm in adj and to in idset:
            adj[frm].append(to)
    seen = set()
    stack = [e for e in entries if e in idset]
    while stack:
        cur = stack.pop()
        if cur in seen:
            continue
        seen.add(cur)
        stack.extend(adj.get(cur, []))
    for nid in idset:
        if nid not in seen:
            flag("/nodes", "unreachable node %r from entry" % nid)

# DAG check on acyclic edge kinds only
dag_edges = []
for i, edge in enumerate(edges):
    if not isinstance(edge, dict):
        continue
    if edge.get("kind") in acyclic_kinds:
        frm, to = edge.get("from"), edge.get("to")
        if frm in idset and to in idset:
            dag_edges.append((frm, to, i))

if idset:
    indeg = {nid: 0 for nid in idset}
    succ = {nid: [] for nid in idset}
    for frm, to, _i in dag_edges:
        succ[frm].append(to)
        indeg[to] += 1
    ready = [nid for nid, d in indeg.items() if d == 0]
    visited = 0
    while ready:
        cur = ready.pop()
        visited += 1
        for nxt in succ[cur]:
            indeg[nxt] -= 1
            if indeg[nxt] == 0:
                ready.append(nxt)
    if visited != len(idset):
        flag("/edges", "cycle among chain/route/fanout/fanin edges (DAG required; use bounded loop)")

for line in flags:
    print(line)
if flags:
    print("graph-validate: %d flag(s)" % len(flags))
    sys.exit(1)
print("graph-validate: ok")
sys.exit(0)
PY
