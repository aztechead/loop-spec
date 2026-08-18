#!/usr/bin/env python3
"""Validate graph structure and its repository references.

lib/graph/validate.sh derives state keys and resolves paths. This module keeps
the graph rules in ordinary Python that readers and Python tooling can inspect.
"""

from __future__ import print_function

import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from paths import repo_path  # noqa: E402

graph_path, schema_path, repo_root, skeleton_keys_json = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
# Strict adds the rules a PUBLISHED graph must meet on top of the rules every
# graph must meet. A synthetic graph exercising routing or ceilings has no reader
# to serve and stays valid without them; a graph people review does not.
strict = len(sys.argv) > 5 and sys.argv[5] == "1"
flags = []

def flag(pointer, message):
    flags.append("FLAG %s:%s: %s" % (graph_path, pointer, message))

try:
    with open(graph_path, "r", encoding="utf-8") as fh:
        graph = json.load(fh)
except Exception as exc:
    # Unreadable/unparseable content is a defect (exit 1), not a usage error —
    # fail safe so a corrupt graph never looks clean.
    print("FLAG %s:1: cannot parse graph: %s" % (graph_path, exc))
    print("graph-validate: 1 flag(s)")
    sys.exit(1)

try:
    with open(schema_path, "r", encoding="utf-8") as fh:
        schema = json.load(fh)
except Exception as exc:
    print("graph-validate: cannot parse schema: %s" % exc, file=sys.stderr)
    sys.exit(2)

try:
    skeleton_keys = set(json.loads(skeleton_keys_json))
except Exception as exc:
    print("graph-validate: cannot parse derived skeleton keys: %s" % exc, file=sys.stderr)
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

# Probe --answers results are cached: several conditions across a graph often
# name the same probe, and each is a subprocess call.
_answers_cache = {}

def probe_answers(path):
    """Run `<probe> --answers`. Returns (set_of_tokens, None) when resolved, or
    (None, reason) when the probe cannot be trusted to enumerate its own answer
    space -- either result is cached by absolute path."""
    if path in _answers_cache:
        return _answers_cache[path]
    try:
        proc = subprocess.run(["bash", path, "--answers"], cwd=repo_root,
                               capture_output=True, text=True, timeout=15)
    except Exception as exc:
        result = (None, "cannot run --answers: %s" % exc)
    else:
        if proc.returncode != 0:
            result = (None, "--answers exited %d" % proc.returncode)
        else:
            answers = {line.strip() for line in proc.stdout.splitlines() if line.strip()}
            result = (answers, None) if answers else (None, "--answers printed no answer tokens")
    _answers_cache[path] = result
    return result

def check_condition(cond, ptr, label):
    """Validate a {probe, args, expects} object -- a route edge's `condition` or
    a human node's `admit` (contract sec 1/4, same shape). Checks shape, probe
    executability, and that `expects` is a member of the probe's own declared
    answer set: the rule that would have caught the shipped engine naming
    probes that never emit the token a route expected (REMEDIATION-CONTRACT.md
    sec 2/3)."""
    if not isinstance(cond, dict):
        flag(ptr, "%s must be {probe, args, expects} object, not prose" % label)
        return
    extras = set(cond.keys()) - {"probe", "args", "expects"}
    if extras:
        flag(ptr, "%s additionalProperties not allowed: %s" % (label, sorted(extras)))
    missing = {"probe", "args", "expects"} - set(cond.keys())
    if missing:
        flag(ptr, "%s requires probe, args, and expects (missing: %s)" % (label, sorted(missing)))

    probe = cond.get("probe")
    probe_path = None
    if "probe" in cond:
        if not isinstance(probe, str):
            flag(ptr + "/probe", "probe must be a string")
        else:
            path = repo_path(probe, repo_root)
            if not os.path.isfile(path):
                flag(ptr + "/probe", "probe path does not exist: %s" % probe)
            elif not os.access(path, os.X_OK):
                flag(ptr + "/probe", "probe path is not executable: %s" % probe)
            else:
                probe_path = path

    if "args" in cond:
        args = cond.get("args")
        if not isinstance(args, list) or any(not isinstance(a, str) for a in args):
            flag(ptr + "/args", "args must be an array of strings")

    if "expects" in cond:
        expects = cond.get("expects")
        if not isinstance(expects, str):
            flag(ptr + "/expects", "expects must be a string")
        elif "|" in expects:
            flag(ptr + "/expects", "expects %r contains '|' -- alternation is illegal, declare separate edges" % expects)
        elif probe_path is not None:
            answers, err = probe_answers(probe_path)
            if err is not None:
                flag(ptr + "/expects", "cannot verify expects against %s --answers: %s" % (probe, err))
            elif expects not in answers:
                flag(ptr + "/expects", "expects %r is not a member of %s --answers" % (expects, probe))

BODY_ARG_PLACEHOLDERS = {"{featureDir}", "{repoRoot}", "{featureRepoRoot}", "{slug}", "{node}", "{baseSha}"}
PLACEHOLDER_RE = re.compile(r"\{[A-Za-z][A-Za-z0-9]*\}")


def check_body_args(node, ptr):
    """A body's argument vector is declared, not improvised. The engine
    substitutes a closed placeholder set; an undeclared one would reach the
    script verbatim, so it is rejected here rather than at dispatch."""
    args = node.get("bodyArgs")
    if args is None:
        return
    if not isinstance(args, list) or any(not isinstance(a, str) for a in args):
        flag(ptr + "/bodyArgs", "bodyArgs must be an array of strings")
        return
    body = node.get("body")
    if node.get("kind") not in ("function", "gate") or not isinstance(body, str) or not body.endswith(".sh"):
        flag(ptr + "/bodyArgs", "only a function/gate node with a .sh body may declare bodyArgs")
    for j, arg in enumerate(args):
        for found in PLACEHOLDER_RE.findall(arg):
            if found not in BODY_ARG_PLACEHOLDERS:
                flag("%s/bodyArgs/%d" % (ptr, j),
                     "unknown placeholder %s (legal: %s)" % (found, ", ".join(sorted(BODY_ARG_PLACEHOLDERS))))


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
    label = node.get("label")
    if label is not None and (not isinstance(label, str) or not label.strip()):
        flag(ptr + "/label", "label must be a non-empty string when present")
    elif strict and label is None:
        # The engine falls back to the node id, so a missing label never crashes
        # -- it silently publishes an identifier where a reader expects a name.
        flag(ptr + "/label", "published graph node %r has no human-facing label" % nid)
    for field in ("reads", "writes", "optionalReads"):
        vals = node.get(field)
        if vals is None and field == "optionalReads":
            continue
        if not isinstance(vals, list):
            flag(ptr + "/" + field, "%s must be an array" % field)
            continue
        for j, key in enumerate(vals):
            if key not in state_keys:
                flag("%s/%s/%d" % (ptr, field, j), "state key %r not in schema key space" % key)
    # A key is either asserted on entry or explicitly nullable, never both --
    # declaring both hides which rule the engine actually applies.
    both = set(node.get("reads") or []) & set(node.get("optionalReads") or [])
    if both:
        flag(ptr + "/optionalReads",
             "keys declared in both reads and optionalReads: %s" % sorted(both))
    check_body_args(node, ptr)
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
            path = repo_path(probe, repo_root)
            if not (os.path.isfile(path) and os.access(path, os.X_OK)):
                flag(ptr + "/skippable/probe", "licensing probe not executable: %s" % probe)
    if node.get("authorizesDelivery") is True and effort == "system1":
        flag(ptr + "/effort", "delivery-authorizing node may not default to system1")
    # Human admit gate (contract sec 4): same {probe,args,expects} shape as a
    # route condition, restricted to human nodes like skippable is to gates.
    admit = node.get("admit")
    if admit is not None:
        if kind != "human":
            flag(ptr + "/admit", "only human nodes may declare admit")
        check_condition(admit, ptr + "/admit", "admit condition")
    route_default = node.get("routeDefault")
    if route_default is not None and not isinstance(route_default, str):
        flag(ptr + "/routeDefault", "routeDefault must be a string node id")
    # A body that looks like a repo path (contains '/') must actually exist --
    # otherwise a renamed/deleted skill or lib script validates clean.
    body = node.get("body")
    if isinstance(body, str) and "/" in body:
        bpath = repo_path(body, repo_root)
        if not os.path.isfile(bpath):
            flag(ptr + "/body", "body path does not exist in the tree: %s" % body)

idset = set(node_ids)
for e in entries:
    if e not in idset:
        flag("/entry", "entry names undeclared node %r" % e)

# routeDefault must name a declared node, checked once idset is known.
for i, node in enumerate(nodes):
    if isinstance(node, dict) and isinstance(node.get("routeDefault"), str):
        if node["routeDefault"] not in idset:
            flag("/nodes/%d/routeDefault" % i, "routeDefault names undeclared node %r" % node["routeDefault"])

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
        check_condition(edge.get("condition"), ptr + "/condition", "route condition")

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

# Producer/consumer: every read key is written by some node, or is a
# feature-init skeleton key present before any phase runs (derived above from a
# real `feature-init.sh skeleton` run -- a hardcoded copy of this set drifted
# twice and stopped catching the class of bug it exists for).
written = set()
for node in nodes:
    if isinstance(node, dict):
        for key in node.get("writes") or []:
            written.add(key)
for i, node in enumerate(nodes):
    if not isinstance(node, dict):
        continue
    for field in ("reads", "optionalReads"):
        for j, key in enumerate(node.get(field) or []):
            if key not in written and key not in skeleton_keys:
                flag(
                    "/nodes/%d/%s/%d" % (i, field, j),
                    "read key %r is never written by any node and is not a feature-init skeleton key" % key,
                )

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

# DAG check on chain/route/fanout/fanin. A route back-edge is permitted only
# when that EXACT (from,to) pair also carries a bounded loop edge (contract
# sec 9) -- scoping on the source node alone (as shipped) would exempt every
# route from that node, letting an uncovered cycle validate clean.
loop_pairs = set()
for edge in edges:
    if isinstance(edge, dict) and edge.get("kind") == "loop":
        if isinstance(edge.get("ceiling"), (int, float)) and not isinstance(edge.get("ceiling"), bool):
            loop_pairs.add((edge.get("from"), edge.get("to")))

dag_edges = []
for i, edge in enumerate(edges):
    if not isinstance(edge, dict):
        continue
    kind = edge.get("kind")
    if kind not in acyclic_kinds:
        continue
    frm, to = edge.get("from"), edge.get("to")
    if frm not in idset or to not in idset:
        continue
    # A rewind route covered by a loop ceiling on its own exact (from,to) pair
    # is the declared form of ITERATE/DELIVER re-entry; it is not a free cycle.
    if kind == "route" and (frm, to) in loop_pairs:
        continue
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
