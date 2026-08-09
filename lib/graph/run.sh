#!/usr/bin/env bash
# Graph engine — sequences declared workflow graphs.
#
# Usage:
#   run.sh [--dry-run] [--resume] --feature-dir DIR <graph.json>
#   run.sh --step [--resume] --feature-dir DIR <graph.json>
#
# --dry-run   traverse without dispatching node bodies or writing state; print
#             node/edge/kind per line, structural only.
# --resume    resolve the start node per docs/loop-spec/features/gdd/REMEDIATION-CONTRACT.md
#             sec 5 (pause record -> checkpoint ledger -> feature.json.currentPhase
#             pre-3.0 compat -> graph entry) instead of always starting at entry.
# --step      process at most one node and print its JSON dispatch descriptor to
#             stdout: {node, kind, body, model, effort, nextEdge, terminal, paused}.
#             Implies --resume (a step always continues from wherever the last
#             step/pause/checkpoint left off — see resolve_start() below). An
#             `agent` node's `nextEdge` is always null: its outgoing route may
#             depend on state the caller's dispatch has not written yet, so
#             routing is resolved lazily by the FOLLOWING --step call via
#             checkpoint-successor resolution, never guessed here on stale state.
#             `function`/`gate`/`subgraph` node bodies ARE dispatched in-process
#             during --step, exactly as they are without it.
#
# Exit codes:
#   0  completed traversal, or --step returned a descriptor (check "terminal")
#   4  paused at a human node (resumable)
#   1  validation / runtime failure (assert-reads violation, gate body failure,
#      nested subgraph failure)
#   2  bad invocation
#   5  a node had route edges and none was satisfied, with no routeDefault
#      (REMEDIATION-CONTRACT.md sec 3) — never a silent chain fallthrough.
#
# harness-neutral: never branches on harness; node bodies may via lib/harness.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DRY_RUN=0
RESUME=0
STEP=0
FEATURE_DIR=""
GRAPH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --resume) RESUME=1; shift ;;
    --step) STEP=1; shift ;;
    --feature-dir) FEATURE_DIR="${2:-}"; shift 2 ;;
    -*)
      echo "usage: run.sh [--dry-run] [--resume] [--step] --feature-dir DIR <graph.json>" >&2
      exit 2
      ;;
    *)
      GRAPH="$1"; shift
      ;;
  esac
done

[[ -n "$GRAPH" ]] || {
  echo "usage: run.sh [--dry-run] [--resume] [--step] --feature-dir DIR <graph.json>" >&2
  exit 2
}
[[ -f "$GRAPH" ]] || { echo "run.sh: graph not found: $GRAPH" >&2; exit 2; }

if [[ -z "$FEATURE_DIR" ]]; then
  echo "run.sh: --feature-dir DIR is required" >&2
  exit 2
fi

# --step always continues from the last resolved position — there is no such
# thing as a fresh --step invocation.
[[ "$STEP" == "1" ]] && RESUME=1

# Validate first
if ! bash "$SCRIPT_DIR/validate.sh" "$GRAPH" >/dev/null; then
  echo "run.sh: graph failed validation: $GRAPH" >&2
  bash "$SCRIPT_DIR/validate.sh" "$GRAPH" >&2 || true
  exit 1
fi

# Absolutized before any probe runs: route/admit probes execute with
# cwd=repoRoot (contract sec 1), so a --feature-dir relative to the caller's
# own cwd must be resolved before that cwd changes underneath it.
mkdir -p "$FEATURE_DIR"
FEATURE_DIR="$(cd "$FEATURE_DIR" && pwd)"

python3 - "$GRAPH" "$FEATURE_DIR" "$DRY_RUN" "$RESUME" "$STEP" "$REPO_ROOT" "$SCRIPT_DIR" <<'PY'
from __future__ import print_function

import json
import os
import re
import subprocess
import sys

graph_path, feature_dir, dry_run, resume, step_mode, repo_root, script_dir = sys.argv[1:8]
dry_run = dry_run == "1"
resume = resume == "1"
step_mode = step_mode == "1"

with open(graph_path, "r", encoding="utf-8") as fh:
    graph = json.load(fh)

nodes = {n["id"]: n for n in graph["nodes"]}
edges = graph["edges"]
entry = graph.get("entry")
if isinstance(entry, list):
    graph_start = entry[0]
else:
    graph_start = entry or graph["nodes"][0]["id"]

out_edges = {}
for e in edges:
    out_edges.setdefault(e["from"], []).append(e)

loop_counts = {}   # (from,to) -> times taken
node_attempts = {}  # node id -> visits so far this process (fresh each invocation)


class RouteAbort(Exception):
    def __init__(self, node_id, diagnostics):
        super(RouteAbort, self).__init__(node_id)
        self.node_id = node_id
        self.diagnostics = diagnostics


def _feature_json():
    path = os.path.join(feature_dir, "feature.json")
    if not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None


def _slug():
    feat = _feature_json()
    if feat and isinstance(feat.get("slug"), str):
        return feat["slug"]
    return os.path.basename(os.path.normpath(feature_dir))


def _substitute(arg, node_id):
    return (arg.replace("{featureDir}", feature_dir)
               .replace("{repoRoot}", repo_root)
               .replace("{slug}", _slug())
               .replace("{node}", node_id))


def run_condition(cond, node_id):
    """Evaluate a {probe, args, expects} condition per REMEDIATION-CONTRACT.md
    sec 1-3: substitute placeholders, run the probe, match its FIRST
    whitespace-delimited stdout token against `expects` EXACTLY. Never a
    substring match. Unresolved (missing probe, non-zero exit, empty stdout)
    never satisfies -- "none" is an ordinary token like any other."""
    probe = cond.get("probe", "") or ""
    expects = cond.get("expects", "") or ""
    args = cond.get("args") or []
    path = probe if os.path.isabs(probe) else os.path.join(repo_root, probe)
    result = {"probe": probe, "args": args, "expects": expects,
              "resolved": False, "satisfied": False, "token": None, "reason": None}
    if not os.path.isfile(path) or not os.access(path, os.X_OK):
        result["reason"] = "missing-probe"
        return result
    sub_args = [_substitute(a, node_id) for a in args]
    try:
        proc = subprocess.run(["bash", path] + sub_args, cwd=repo_root,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               timeout=120)
    except Exception as exc:
        result["reason"] = "probe-error:%s" % exc
        return result
    if proc.returncode != 0:
        result["reason"] = "exit=%d" % proc.returncode
        return result
    stdout = proc.stdout.decode("utf-8", errors="replace")
    lines = stdout.splitlines()
    first_line = lines[0].strip() if lines else ""
    if not first_line:
        result["reason"] = "empty-stdout"
        return result
    token = first_line.split()[0]
    reason_text = first_line
    m = re.search(r"reason=(.*)$", first_line)
    if m:
        reason_text = m.group(1)
    result["resolved"] = True
    result["token"] = token
    result["reason"] = reason_text
    result["satisfied"] = (token == expects)
    return result


def pick_next(node_id):
    """Return (edge_dict, edge_kind_label, probe_path, probe_token, probe_reason).
    edge_dict is None at a true terminal (no candidates, or a loop ceiling
    exhausted with nothing else to take). Raises RouteAbort per contract sec 3
    when route edges exist and none is satisfied and no routeDefault is set --
    this NEVER falls through to a chain edge."""
    node = nodes[node_id]
    candidates = out_edges.get(node_id, [])
    routes = [e for e in candidates if e.get("kind") == "route"]
    chains = [e for e in candidates if e.get("kind") in ("chain", "fanout", "fanin")]
    loops = [e for e in candidates if e.get("kind") == "loop"]

    if routes:
        results = []
        for e in routes:
            cond = e.get("condition") or {}
            r = run_condition(cond, node_id)
            results.append((e, r))
            if r["satisfied"]:
                return (e, "route:%s" % r["token"], cond.get("probe"), r["token"], r["reason"])
        route_default = node.get("routeDefault")
        if route_default:
            synth = {"from": node_id, "to": route_default, "kind": "routeDefault"}
            return (synth, "routeDefault:%s" % route_default, None, None,
                    "no route satisfied; routeDefault=%s" % route_default)
        diag_lines = []
        for e, r in results:
            cond = e.get("condition") or {}
            diag_lines.append(
                "  to=%s probe=%s args=%s expects=%r -> resolved=%s satisfied=%s token=%r reason=%s"
                % (e.get("to"), cond.get("probe"), cond.get("args"), cond.get("expects"),
                   r["resolved"], r["satisfied"], r["token"], r["reason"]))
        raise RouteAbort(node_id, "\n".join(diag_lines))

    if chains:
        e = chains[0]
        return (e, e.get("kind", "chain"), None, None, e.get("kind", "chain"))

    if loops:
        for e in loops:
            key = (e["from"], e["to"])
            used = loop_counts.get(key, 0)
            ceiling = e.get("ceiling", 0)
            if used < ceiling:
                loop_counts[key] = used + 1
                return (e, "loop", None, None, "%d/%s" % (used + 1, ceiling))
        return (None, "loop-ceiling-exhausted", None, None, None)

    return (None, "terminal", None, None, None)


def emit_trace(node_id, edge_label, probe, reason, effort):
    if dry_run:
        return
    subprocess.call([
        "bash", os.path.join(script_dir, "trace.sh"), "emit", feature_dir, "dispatch",
        "--node", node_id,
        "--edge", edge_label,
        "--probe", probe or "none",
        "--probe-reason", reason or "none",
        "--effort", effort or "system2",
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


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


def assert_reads(node_id):
    """lib/graph/state.sh assert-reads on node entry (REMEDIATION-CONTRACT.md
    sec 7). Read-only against feature.json; run even in dry-run for structural
    validation, but only when a feature.json actually exists -- a synthetic
    graph exercised before any feature is initialized has nothing to assert."""
    if not os.path.isfile(os.path.join(feature_dir, "feature.json")):
        return True, ""
    proc = subprocess.run([
        "bash", os.path.join(repo_root, "lib", "graph", "state.sh"), "assert-reads",
        "--feature-dir", feature_dir, "--node", node_id, "--graph", graph_path,
    ], cwd=repo_root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    return proc.returncode == 0, proc.stderr.decode("utf-8", errors="replace")


def check_conflict(test_exit):
    """lib/conflict-monitor.sh after a node body reports failure (sec 7)."""
    try:
        proc = subprocess.run([
            "bash", os.path.join(repo_root, "lib", "conflict-monitor.sh"), "check",
            "--test-exit", str(test_exit),
        ], cwd=repo_root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        if proc.returncode == 0:
            out = proc.stdout.decode("utf-8", errors="replace").strip()
            if out:
                return out.splitlines()[0]
    except Exception:
        pass
    return "conflict=unknown reason=conflict-monitor-unresolved"


def compute_effort(node_id, node, attempt):
    """lib/effort-probe.sh computes the runtime mode; the declared node.effort
    is a DEFAULT the probe may only raise, never lower (sec 7). Inputs the
    generic engine can honestly derive: width from mergeQueue length, changed
    file count + security signal from a git diff against feature.json.baseSha
    (same derivation lib/graph/probes/plan-critique.sh uses), task count from
    pendingRemediationTasks, attempt from this process's visit count for the
    node. Anything undiscoverable is passed as unresolved input, which
    effort-probe.sh itself fails safe toward system2 on -- it never silently
    invents a signal."""
    declared = node.get("effort") or "system2"
    kind = node.get("kind") or ""
    feat = _feature_json() or {}

    width = "1"
    merge_queue = feat.get("mergeQueue")
    if isinstance(merge_queue, list) and merge_queue:
        width = str(len(merge_queue))

    pending = feat.get("pendingRemediationTasks")
    task_count = str(len(pending)) if isinstance(pending, list) else "0"

    changed_files = "0"
    security_signal = "none"
    base_sha = feat.get("baseSha")
    if isinstance(base_sha, str) and base_sha:
        try:
            diff = subprocess.run(
                ["git", "-C", repo_root, "diff", "--name-only", "--diff-filter=d",
                 base_sha, "HEAD", "--"],
                cwd=repo_root, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                timeout=30)
            if diff.returncode == 0:
                files = [f for f in diff.stdout.decode("utf-8", errors="replace").splitlines() if f.strip()]
                changed_files = str(len(files))
                if files:
                    sec = subprocess.run(
                        ["bash", os.path.join(repo_root, "lib", "security-signal.sh"), "first"]
                        + [os.path.join(repo_root, f) for f in files],
                        cwd=repo_root, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        timeout=30)
                    security_signal = "matched" if sec.returncode == 0 else "none"
        except Exception:
            pass

    authorizes = "true" if node.get("authorizesDelivery") else "false"
    cmd = ["bash", os.path.join(repo_root, "lib", "effort-probe.sh"),
           "--node-kind", kind, "--security-signal", security_signal,
           "--width", width, "--changed-files", changed_files,
           "--task-count", task_count, "--attempt", str(attempt),
           "--authorizes-delivery", authorizes, "--node-id", node_id]
    try:
        proc = subprocess.run(cmd, cwd=repo_root, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, timeout=30)
        out = proc.stdout.decode("utf-8", errors="replace").strip()
        if proc.returncode == 0 and out:
            m = re.match(r"mode=(system1|system2)\s+reason=(.*)$", out.splitlines()[0])
            if m:
                probe_mode, probe_reason = m.group(1), m.group(2)
                final = "system2" if (declared == "system2" or probe_mode == "system2") else "system1"
                return final, probe_reason
    except Exception:
        pass
    return declared, "effort-probe-unresolved"


def resolve_model(node_id, kind):
    """Best-effort model resolution via lib/feature-init.sh phase-model, the
    canonical alias resolver -- only meaningful for the seven canonical phase
    ids; anything else (subgraph roles, function/gate bodies) has no phase
    alias and resolves to null (inherits session/role default)."""
    if kind != "agent":
        return None
    try:
        proc = subprocess.run(
            ["bash", os.path.join(repo_root, "lib", "feature-init.sh"), "phase-model", node_id],
            cwd=repo_root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
        if proc.returncode == 0:
            val = proc.stdout.decode("utf-8", errors="replace").strip()
            return val or None
    except Exception:
        pass
    return None


CYCLE_RESULT = os.path.realpath(os.path.join(repo_root, "lib", "cycle-result.sh"))


def _is_cycle_result_body(body_path):
    try:
        return os.path.realpath(body_path) == CYCLE_RESULT
    except Exception:
        return False


def publish_result(status, summary):
    """The canonical terminal-result constructor (REMEDIATION-CONTRACT.md sec 8)
    -- never a hand-built result dict. Same target as the pre-remediation
    hand-built result.json (feature_dir/result.json), plus the fix: this also
    publishes .loop-spec/last-result.json, which the old hand-built object
    never touched. Observability contract: best-effort, never gates the
    engine's own exit code."""
    if dry_run:
        return
    subprocess.call([
        "bash", os.path.join(repo_root, "lib", "cycle-result.sh"), "write", feature_dir,
        "--status", status, "--summary", summary,
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def dispatch_body(node_id, node, kind):
    """Dispatch a function/gate body in-process. Returns None when there is
    nothing to run (no body, or a non-script body — e.g. a gate with only a
    `skippable` probe and no action script). cycle-result.sh is never dispatched
    generically here — see publish_result(); calling it with no arguments is
    the exact bug this contract exists to fix (sec 8)."""
    body = node.get("body") or ""
    if not body.endswith(".sh"):
        return None
    body_path = body if os.path.isabs(body) else os.path.join(repo_root, body)
    if not os.path.isfile(body_path):
        return None
    if _is_cycle_result_body(body_path):
        return None
    proc = subprocess.call(["bash", body_path], cwd=repo_root,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return proc


def dispatch_subgraph(node):
    """Nested run — for real, matching the parent's own mode (contract sec 6):
    a dry-run parent dry-runs its nested graph structurally; a real parent
    really runs it. Never unconditionally --dry-run regardless of the parent's
    mode, which was the shipped bug. Returns the nested run.sh exit code."""
    nested = node.get("graph")
    if not nested:
        return 0
    nested_path = nested if os.path.isabs(nested) else os.path.join(repo_root, nested)
    cmd = ["bash", os.path.join(script_dir, "run.sh"), "--feature-dir", feature_dir, nested_path]
    if dry_run:
        cmd.insert(2, "--dry-run")
    return subprocess.call(cmd)


def process_node(current, admitting, defer_agent_routing):
    """Process exactly one node: assert-reads, compute effort, dispatch what
    can run in-process, trace with the REAL probe/reason, checkpoint, then
    (unless deferred) pick the next edge. Shared by full-traversal and --step
    so the two never diverge in what "processing a node" means.

    Returns a dict:
      status: "paused" | "terminal" | "advance" | "deferred"
      descriptor: the --step JSON shape
      next: (next_node_id, next_admitting_label) or None
    """
    node = nodes[current]
    kind = node.get("kind")
    body = node.get("body")
    attempt = node_attempts.get(current, 0)
    node_attempts[current] = attempt + 1

    if not dry_run:
        ok, err = assert_reads(current)
        if not ok:
            publish_result("failed", "state contract violation at node %s" % current)
            print("run.sh: state.sh assert-reads failed for node %s" % current, file=sys.stderr)
            if err:
                print(err, file=sys.stderr, end="")
            sys.exit(1)

    effort, effort_reason = (node.get("effort") or "system2", "dry-run") if dry_run \
        else compute_effort(current, node, attempt)
    model = resolve_model(current, kind)

    # Phase pointer: the graph owns successors, so the engine advances
    # currentPhase when entering a phase node — never before start-node
    # resolution (contract sec 5) and never for a dry run.
    phase_ids = {
        "spec", "discuss", "plan", "execute", "verify", "iterate", "deliver", "completed",
    }
    if not dry_run and current in phase_ids:
        feat_path = os.path.join(feature_dir, "feature.json")
        if os.path.isfile(feat_path):
            fw = os.environ.get("LOOP_SPEC_FEATURE_WRITE") or os.path.join(
                repo_root, "lib", "feature-write.sh")
            subprocess.call(
                ["bash", fw, "set", feature_dir, "currentPhase", json.dumps(current)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    if not step_mode:
        print("%s\t%s\t%s" % (current, admitting, kind))

    # Human admit gate (contract sec 4): admitted -> pause; unresolved or not
    # admitted -> skip (never dispatched either way — a human node has no body).
    if kind == "human":
        admit = node.get("admit")
        admitted = False
        admit_probe, admit_token, admit_reason = None, None, None
        if admit:
            r = run_condition(admit, current)
            admitted = r["satisfied"]
            admit_probe = admit.get("probe")
            admit_token = r["token"]
            admit_reason = r["reason"]
        if admitted and not dry_run:
            emit_trace(current, admitting, admit_probe, admit_reason, effort)
            checkpoint(current, admitting, effort)
            pause = {"paused": True, "node": current, "edge": admitting, "featureDir": feature_dir}
            with open(os.path.join(feature_dir, "graph-pause.json"), "w", encoding="utf-8") as fh:
                json.dump(pause, fh)
            publish_result("paused", "paused at human node %s" % current)
            descriptor = {"node": current, "kind": kind, "body": body, "model": model,
                           "effort": effort, "nextEdge": admitting, "terminal": False,
                           "paused": True}
            if not step_mode:
                print("run.sh: paused at human node %s" % current, file=sys.stderr)
            return {"status": "paused", "descriptor": descriptor, "next": None}
        # Not admitted (or an unresolved/absent admit): skip, fall through to
        # ordinary routing exactly like any other node — the gates that must
        # never be skipped are `gate` nodes, not `human` nodes (sec 4).

    if kind == "subgraph" and not dry_run:
        rc = dispatch_subgraph(node)
        if rc != 0:
            emit_trace(current, admitting, None, "subgraph-failed:%d" % rc, effort)
            checkpoint(current, admitting, effort)
            sys.exit(rc)

    dispatch_rc = None
    if kind in ("function", "gate") and not dry_run:
        dispatch_rc = dispatch_body(current, node, kind)
        if dispatch_rc is not None and dispatch_rc != 0:
            conflict_line = check_conflict(dispatch_rc)
            if kind == "gate":
                emit_trace(current, admitting, body, "gate-failed:%d %s" % (dispatch_rc, conflict_line), effort)
                checkpoint(current, admitting, effort)
                publish_result("failed", "gate %s failed (exit %d); %s" % (current, dispatch_rc, conflict_line))
                print("run.sh: gate %s failed (exit %d); %s" % (current, dispatch_rc, conflict_line), file=sys.stderr)
                sys.exit(1)
            print("run.sh: function %s body failed (exit %d); %s" % (current, dispatch_rc, conflict_line), file=sys.stderr)

    if kind == "function" and dispatch_rc is None and body and _is_cycle_result_body(
            body if os.path.isabs(body) else os.path.join(repo_root, body)) and not dry_run:
        publish_result("completed", "completed at %s" % current)

    emit_trace(current, admitting, None, effort_reason, effort)
    checkpoint(current, admitting, effort)

    descriptor = {"node": current, "kind": kind, "body": body, "model": model,
                  "effort": effort, "nextEdge": admitting, "terminal": False, "paused": False}

    if kind == "agent" and defer_agent_routing:
        descriptor["nextEdge"] = None
        return {"status": "deferred", "descriptor": descriptor, "next": None}

    edge, edge_label, probe_path, probe_token, probe_reason = pick_next(current)
    if probe_path is not None or probe_token is not None:
        # A route actually fired for this node's outgoing edge: re-trace with
        # the real probe/token so the trail is reconstructable (contract sec 7)
        # instead of the departing "probe=none reason=admitting-edge" stamp.
        emit_trace(current, "%s:%s->%s" % (edge.get("kind"), current, edge["to"]),
                   probe_path, probe_token or probe_reason, effort)
    if edge is None:
        publish_result("completed", "completed at %s (%s)" % (current, edge_label))
        descriptor["terminal"] = True
        return {"status": "terminal", "descriptor": descriptor, "next": None}
    next_admitting = "%s:%s->%s" % (edge.get("kind"), edge["from"], edge["to"])
    return {"status": "advance", "descriptor": descriptor,
            "next": (edge["to"], next_admitting)}


def resolve_start():
    """Start-node resolution (REMEDIATION-CONTRACT.md sec 5), in priority
    order. The engine MUST NOT write currentPhase before this returns — nothing
    here writes state, it only reads the pause record / ledger / feature.json
    and (for the first two) evaluates the resolved node's own outgoing edges to
    find its successor. Returns (node_id, admitting_label)."""
    # 1. Pause record -> successor of the paused node; delete the pause record
    #    (re-entering the paused node is the deadlock this replaces).
    pause_path = os.path.join(feature_dir, "graph-pause.json")
    if os.path.isfile(pause_path):
        try:
            with open(pause_path, "r", encoding="utf-8") as fh:
                pause = json.load(fh)
        except Exception:
            pause = None
        os.remove(pause_path)
        paused_node = pause.get("node") if pause else None
        if paused_node in nodes:
            edge, edge_label, _p, _t, _r = pick_next(paused_node)
            if edge is not None:
                return edge["to"], "%s:%s->%s" % (edge.get("kind"), edge["from"], edge["to"])
            # Paused node turned out terminal (graph reshaped under us) — fall
            # through to the ledger/currentPhase/entry chain below.

    # 2. Non-empty checkpoint ledger -> successor of the last checkpointed node.
    latest = latest_checkpoint()
    if not latest.get("empty"):
        last_node = latest.get("node")
        if last_node in nodes:
            edge, edge_label, _p, _t, _r = pick_next(last_node)
            if edge is not None:
                return edge["to"], "%s:%s->%s" % (edge.get("kind"), edge["from"], edge["to"])

    # 3. feature.json.currentPhase (pre-3.0 compatibility path): a feature
    #    created before the ledger existed resumes where its committed state
    #    says, never at the graph's start node.
    feat = _feature_json()
    if feat is not None:
        current_phase = feat.get("currentPhase")
        if isinstance(current_phase, str) and current_phase in nodes:
            return current_phase, "resume:currentPhase=%s" % current_phase

    # 4. The graph's start node.
    return graph_start, "entry"


def _abort(abort):
    # RouteAbort can surface from resolve_start() too (pick_next() evaluates
    # the resumed/checkpointed node's own routes against CURRENT state, which
    # may no longer resolve the way it did when that node first ran) -- both
    # call sites below share this handler so a resume-time abort gets the same
    # exit 5 + diagnostic as a mid-traversal one, never an uncaught traceback.
    diag = "run.sh: no route satisfied at node %r and no routeDefault declared\n%s" % (
        abort.node_id, abort.diagnostics)
    print(diag, file=sys.stderr)
    publish_result("failed", "no route satisfied at node %s" % abort.node_id)
    sys.exit(5)


if step_mode:
    try:
        current, admitting = resolve_start()
        result = process_node(current, admitting, defer_agent_routing=True)
    except RouteAbort as abort:
        _abort(abort)
    print(json.dumps(result["descriptor"]))
    if result["status"] == "paused":
        sys.exit(4)
    sys.exit(0)

# Full traversal (dry-run or real). Resume resolution runs only when asked;
# a plain invocation always starts fresh at the graph's entry node.
try:
    if resume:
        current, admitting = resolve_start()
    else:
        current, admitting = graph_start, "entry"

    steps = 0
    max_steps = 10000
    while current and steps < max_steps:
        steps += 1
        result = process_node(current, admitting, defer_agent_routing=False)
        if result["status"] == "paused":
            sys.exit(4)
        if result["status"] == "terminal":
            break
        current, admitting = result["next"]
except RouteAbort as abort:
    _abort(abort)

if steps >= max_steps:
    print("run.sh: step ceiling exceeded (possible unbounded traversal)", file=sys.stderr)
    sys.exit(1)

sys.exit(0)
PY
