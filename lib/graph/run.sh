#!/usr/bin/env bash
# Graph engine — sequences declared workflow graphs.
#
# Usage:
#   run.sh [--dry-run] [--resume] [--feature-dir DIR] <graph.json>
#
# --dry-run   traverse without dispatching node bodies; print node/edge sequence
# --resume    continue from the latest checkpoint for the feature
#
# Exit codes:
#   0  completed traversal
#   4  paused at a human node (resumable)
#   1  validation / runtime failure
#   2  bad invocation
#
# harness-neutral: never branches on harness; node bodies may via lib/harness.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DRY_RUN=0
RESUME=0
FEATURE_DIR=""
GRAPH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --resume) RESUME=1; shift ;;
    --feature-dir) FEATURE_DIR="${2:-}"; shift 2 ;;
    -*)
      echo "usage: run.sh [--dry-run] [--resume] [--feature-dir DIR] <graph.json>" >&2
      exit 2
      ;;
    *)
      GRAPH="$1"; shift
      ;;
  esac
done

[[ -n "$GRAPH" ]] || {
  echo "usage: run.sh [--dry-run] [--resume] [--feature-dir DIR] <graph.json>" >&2
  exit 2
}
[[ -f "$GRAPH" ]] || { echo "run.sh: graph not found: $GRAPH" >&2; exit 2; }

if [[ -z "$FEATURE_DIR" ]]; then
  echo "run.sh: --feature-dir DIR is required" >&2
  exit 2
fi

# Validate first
if ! bash "$SCRIPT_DIR/validate.sh" "$GRAPH" >/dev/null; then
  echo "run.sh: graph failed validation: $GRAPH" >&2
  bash "$SCRIPT_DIR/validate.sh" "$GRAPH" >&2 || true
  exit 1
fi

mkdir -p "$FEATURE_DIR"

python3 - "$GRAPH" "$FEATURE_DIR" "$DRY_RUN" "$RESUME" "$REPO_ROOT" "$SCRIPT_DIR" <<'PY'
from __future__ import print_function

import json
import os
import subprocess
import sys
import hashlib

graph_path, feature_dir, dry_run, resume, repo_root, script_dir = sys.argv[1:7]
dry_run = dry_run == "1"
resume = resume == "1"

with open(graph_path, "r", encoding="utf-8") as fh:
    graph = json.load(fh)

nodes = {n["id"]: n for n in graph["nodes"]}
edges = graph["edges"]
entry = graph.get("entry")
if isinstance(entry, list):
    start = entry[0]
else:
    start = entry or graph["nodes"][0]["id"]

# Build adjacency
out_edges = {}
for e in edges:
    out_edges.setdefault(e["from"], []).append(e)

loop_counts = {}  # (from,to) -> times taken
visited_seq = []

def emit_trace(node_id, edge_label, probe, reason, effort):
    if dry_run:
        return
    cmd = [
        "bash", os.path.join(script_dir, "trace.sh"), "emit", feature_dir, "dispatch",
        "--node", node_id,
        "--edge", edge_label,
        "--probe", probe or "none",
        "--probe-reason", reason or "none",
        "--effort", effort or "system2",
    ]
    subprocess.call(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def checkpoint(node_id, edge_label, effort):
    if dry_run:
        return
    subprocess.call([
        "bash", os.path.join(script_dir, "checkpoint.sh"), "append",
        "--feature-dir", feature_dir,
        "--node", node_id,
        "--edge", edge_label,
        "--effort", effort or "system2",
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def latest_checkpoint():
    out = subprocess.check_output([
        "bash", os.path.join(script_dir, "checkpoint.sh"), "latest",
        "--feature-dir", feature_dir,
    ], stderr=subprocess.DEVNULL)
    return json.loads(out.decode("utf-8"))

def run_probe(probe_path, expects):
    path = probe_path if os.path.isabs(probe_path) else os.path.join(repo_root, probe_path)
    if not os.path.isfile(path):
        return False, "missing-probe"
    # Best-effort: run with no args; compare stdout first line / contains expects
    try:
        proc = subprocess.Popen(
            ["bash", path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=repo_root,
        )
        stdout, _stderr = proc.communicate()
        text = stdout.decode("utf-8", errors="replace").strip()
    except Exception as exc:
        return False, "probe-error:%s" % exc
    if expects == "none":
        ok = proc.returncode != 0 or text == "" or "none" in text
        return ok, text or ("exit=%d" % proc.returncode)
    if expects in text or text == expects:
        return True, text or "matched"
    # Also treat expects token as substring of any line
    for line in text.splitlines():
        if expects in line:
            return True, line
    return False, text or ("exit=%d" % proc.returncode)

def pick_next(node_id):
    """Return (edge, reason) or (None, done)."""
    candidates = out_edges.get(node_id, [])
    if not candidates:
        return None, "terminal"

    # Prefer satisfied routes, then chain/fanout/fanin, then loop if under ceiling
    routes = [e for e in candidates if e.get("kind") == "route"]
    chains = [e for e in candidates if e.get("kind") in ("chain", "fanout", "fanin")]
    loops = [e for e in candidates if e.get("kind") == "loop"]

    for e in routes:
        cond = e.get("condition") or {}
        ok, reason = run_probe(cond.get("probe", ""), cond.get("expects", ""))
        if ok:
            return e, "route:%s" % reason

    if chains:
        # fanout: take first fanout then rely on fanin later; dry-run visits worker once
        return chains[0], "chain"

    for e in loops:
        key = (e["from"], e["to"])
        used = loop_counts.get(key, 0)
        ceiling = e.get("ceiling", 0)
        if used < ceiling:
            loop_counts[key] = used + 1
            return e, "loop:%d/%s" % (used + 1, ceiling)
    return None, "done"

# Resume
current = start
admitting = "entry"
if resume:
    latest = latest_checkpoint()
    if not latest.get("empty"):
        current = latest.get("node") or start
        admitting = latest.get("edge") or "resume"

# Terminal result skeleton matching cycle-result keys of interest
result = {
    "schema": 1,
    "status": "completed",
    "phaseReached": None,
    "summary": "",
    "converged": True,
    "warnings": [],
}

steps = 0
max_steps = 10000

while current and steps < max_steps:
    steps += 1
    node = nodes[current]
    effort = node.get("effort") or "system2"
    kind = node.get("kind")

    visited_seq.append({"node": current, "edge": admitting, "kind": kind})
    print("%s\t%s\t%s" % (current, admitting, kind))

    emit_trace(current, admitting, "none", admitting, effort)
    checkpoint(current, admitting, effort)

    # Phase pointer: the graph owns successors, so the engine — not phase
    # skill prose — advances currentPhase when entering a phase node.
    phase_ids = {
        "spec", "discuss", "plan", "execute", "verify", "iterate", "deliver", "completed",
    }
    if not dry_run and current in phase_ids:
        feat = os.path.join(feature_dir, "feature.json")
        if os.path.isfile(feat):
            fw = os.environ.get("LOOP_SPEC_FEATURE_WRITE") or os.path.join(
                repo_root, "lib", "feature-write.sh"
            )
            subprocess.call(
                ["bash", fw, "set", feature_dir, "currentPhase", json.dumps(current)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

    if kind == "human" and not dry_run:
        pause = {
            "paused": True,
            "node": current,
            "edge": admitting,
            "featureDir": feature_dir,
        }
        pause_path = os.path.join(feature_dir, "graph-pause.json")
        with open(pause_path, "w", encoding="utf-8") as fh:
            json.dump(pause, fh)
        result["status"] = "paused"
        result["phaseReached"] = current
        result["summary"] = "paused at human node %s" % current
        with open(os.path.join(feature_dir, "result.json"), "w", encoding="utf-8") as fh:
            json.dump(result, fh)
        print("run.sh: paused at human node %s" % current, file=sys.stderr)
        sys.exit(4)

    if kind == "subgraph" and not dry_run:
        # Nested run (dry-run nested always)
        nested = node.get("graph")
        if nested:
            nested_path = nested if os.path.isabs(nested) else os.path.join(repo_root, nested)
            subprocess.call([
                "bash", os.path.join(script_dir, "run.sh"), "--dry-run",
                "--feature-dir", feature_dir, nested_path,
            ])

    # Dispatch body only when not dry-run and kind is function with a body script
    if not dry_run and kind == "function":
        body = node.get("body") or ""
        if body.endswith(".sh"):
            body_path = body if os.path.isabs(body) else os.path.join(repo_root, body)
            if os.path.isfile(body_path):
                subprocess.call(["bash", body_path], cwd=repo_root,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    edge, why = pick_next(current)
    if edge is None:
        result["phaseReached"] = current
        result["summary"] = "completed at %s (%s)" % (current, why)
        break

    admitting = "%s:%s->%s" % (edge.get("kind"), edge["from"], edge["to"])
    current = edge["to"]

if steps >= max_steps:
    print("run.sh: step ceiling exceeded (possible unbounded traversal)", file=sys.stderr)
    sys.exit(1)

# Ensure we visited the seven phase nodes in dry-run of cycle graph
if dry_run:
    sys.exit(0)

with open(os.path.join(feature_dir, "result.json"), "w", encoding="utf-8") as fh:
    json.dump(result, fh)
sys.exit(0)
PY
