#!/usr/bin/env python3
"""Execute a validated loop-spec workflow graph.

lib/graph/run.sh owns shell argument parsing and path setup. This module owns
workflow traversal so readers and Python tooling can see the engine as Python.
It is harness-neutral: node bodies, not graph traversal, adapt dispatch.
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


PLACEHOLDER_RE = re.compile(r"\{[A-Za-z][A-Za-z0-9]*\}")
_repo_root_cache = []


def _base_sha():
    """Top-level feature.json.baseSha. Empty in workspace mode (the SHA lives
    per repo); bodies that diff the feature must take {featureDir} instead."""
    feat = _feature_json()
    if feat and isinstance(feat.get("baseSha"), str) and feat["baseSha"]:
        return feat["baseSha"]
    return ""


def _feature_repo_root():
    """The git repository holding the feature — not repo_root, which is the
    loop-spec install and is the same directory only when self-hosting. Empty
    when feature_dir is not inside a git work tree (workspace root). Derived
    the way lib/graph/probes/plan-critique.sh derives the single-repo case."""
    if not _repo_root_cache:
        try:
            out = subprocess.check_output(
                ["git", "-C", feature_dir, "rev-parse", "--show-toplevel"],
                stderr=subprocess.DEVNULL, timeout=30)
            _repo_root_cache.append(out.decode("utf-8", errors="replace").strip())
        except Exception:
            _repo_root_cache.append("")
    return _repo_root_cache[0]


def _placeholders(node_id):
    """The closed placeholder set graph/schema.json documents, resolved against
    current state. An empty value means the state it names is absent — the
    caller decides whether that is tolerable."""
    return {
        "{featureDir}": feature_dir,
        "{repoRoot}": repo_root,
        "{featureRepoRoot}": _feature_repo_root(),
        "{slug}": _slug(),
        "{node}": node_id,
        "{baseSha}": _base_sha(),
    }


def _substitute(arg, node_id):
    for token, value in _placeholders(node_id).items():
        arg = arg.replace(token, value)
    return arg


def run_condition(cond, node_id):
    """Evaluate a {probe, args, expects} condition per REMEDIATION-CONTRACT.md
    sec 1-3: substitute placeholders, run the probe, match its FIRST
    whitespace-delimited stdout token against `expects` EXACTLY. Never a
    substring match. Unresolved (missing probe, non-zero exit, empty stdout)
    never satisfies -- "none" is an ordinary token like any other."""
    probe = cond.get("probe", "") or ""
    expects = cond.get("expects", "") or ""
    args = cond.get("args") or []
    path = repo_path(probe, repo_root)
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
    """Resume is a lookup, and a lookup that cannot answer must say "nothing
    here" rather than abort the run: an unreadable or unparseable ledger falls
    back to the remaining start-node resolution chain (contract sec 5) instead
    of a traceback."""
    try:
        out = subprocess.check_output([
            "bash", os.path.join(script_dir, "checkpoint.sh"), "latest",
            "--feature-dir", feature_dir,
        ], stderr=subprocess.DEVNULL)
        return json.loads(out.decode("utf-8"))
    except Exception:
        return {"empty": True}


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
        # Any probe failure is the same answer to the caller: unknown. The line
        # below carries it, so the exception detail buys nothing here.
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
            # A signal that cannot be measured stays "none"; effort-probe below reads
            # the defaults set above and reports the reason it used them.
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
        # The declared mode is the fallback by design, and the reason returned below
        # tells the caller the probe never resolved.
        pass
    return declared, "effort-probe-unresolved"


CYCLE_RESULT = os.path.realpath(os.path.join(repo_root, "lib", "cycle-result.sh"))

# Working phases an operator (and the console) can be *in*. `completed` is a
# pointer the engine writes, not a phase that emits start/end markers.
PHASE_NODE_IDS = (
    "spec", "discuss", "plan", "execute", "verify", "iterate", "deliver",
)
PHASE_POINTER_IDS = PHASE_NODE_IDS + ("completed",)
EDGE_KIND_RE = re.compile(
    r"^(?:chain|route|fanout|fanin|loop|routeDefault):(.+)->(.+)$"
)


def _is_cycle_result_body(body_path):
    try:
        return os.path.realpath(body_path) == CYCLE_RESULT
    except Exception:
        return False


def emit_phase_boundaries(current, admitting):
    """phase_start / phase_end at node transitions (REMEDIATION-CONTRACT.md sec 7).

    The cycle skill used to ask the agent to run `events.sh emit` as prose, so a
    coder who ran the work inline skipped every marker and the console saw
    phase=unknown. The engine already owns the transition; it is the one caller
    that cannot skip it.

    Markers share stderr with the `[PHASE]` console line. --step's JSON
    descriptor and the full-traversal TSV both occupy stdout, and the cycle
    snippet captures --step stdout (`step_json=$(run.sh --step)`), so putting
    LOOP_SPEC_PHASE_* on stdout would both break jq and trap the only greppable
    record inside a variable the session log never sees.
    """
    if dry_run:
        return
    events = os.environ.get("LOOP_SPEC_EVENTS") or os.path.join(
        repo_root, "lib", "events.sh")
    leaving = None
    match = EDGE_KIND_RE.match(admitting or "")
    if match:
        src = match.group(1)
        if src in PHASE_NODE_IDS:
            leaving = src
    nxt = current
    if current not in PHASE_NODE_IDS and current != "completed":
        feat = _feature_json() or {}
        cur = feat.get("currentPhase")
        if isinstance(cur, str) and cur and cur != leaving:
            nxt = cur
    try:
        if leaving:
            subprocess.call(
                ["bash", events, "emit", feature_dir, "phase_end",
                 "--phase", leaving, "--data", json.dumps({"next": nxt})],
                stdout=sys.stderr)
        if current in PHASE_NODE_IDS:
            subprocess.call(
                ["bash", events, "emit", feature_dir, "phase_start",
                 "--phase", current],
                stdout=sys.stderr)
    except Exception:
        # Markers are observability, never control flow: a run that cannot emit one
        # still has to finish the phase it is in.
        pass


def publish_result(status, summary):
    """The canonical terminal-result constructor (REMEDIATION-CONTRACT.md sec 8)
    -- never a hand-built result dict. Same target as the pre-remediation
    hand-built result.json (feature_dir/result.json), plus the fix: this also
    publishes .loop-spec/last-result.json, which the old hand-built object
    never touched.

    LOOP_SPEC_RESULT shares stderr with the phase markers: --step stdout is the
    JSON descriptor, and swallowing this write is how a delivered cycle left
    last-result.json on an interrupted pointer the agent could not overwrite.
    """
    if dry_run:
        return 0
    feat = _feature_json() or {}
    if status == "completed":
        iterate = feat.get("iterate") if isinstance(feat.get("iterate"), dict) else {}
        last = iterate.get("lastVerdict") if isinstance(iterate, dict) else None
        if isinstance(last, dict):
            verdict_summary = last.get("summary")
            if isinstance(verdict_summary, str) and verdict_summary.strip():
                summary = verdict_summary.strip()
    cmd = [
        "bash", os.path.join(repo_root, "lib", "cycle-result.sh"), "write", feature_dir,
        "--status", status, "--summary", summary,
    ]
    pr_url = feat.get("prUrl")
    if isinstance(pr_url, str) and pr_url:
        cmd.extend(["--pr-url", pr_url])
    try:
        rc = subprocess.call(cmd, stdout=sys.stderr)
    except Exception as exc:
        print("run.sh: TERMINAL RESULT NOT PUBLISHED (%s)" % exc, file=sys.stderr)
        return 1
    if rc != 0:
        print("run.sh: TERMINAL RESULT NOT PUBLISHED (cycle-result.sh write rc=%s)" % rc,
              file=sys.stderr)
    return rc


UNRESOLVED_BODY_ARG = 64


def dispatch_body(node_id, node, kind):
    """Dispatch a function/gate body in-process with its declared `bodyArgs`.
    Returns (exit_code, output), or (None, "") when there is nothing to run (no
    body, or a non-script body — e.g. a gate whose body names an agent rather
    than a script). cycle-result.sh is never dispatched generically here —
    see publish_result(); calling it with no arguments is the exact bug this
    contract exists to fix (sec 8).

    A body that REQUIRES arguments gets them the same way a route probe does:
    declared on the node, substituted here. Invoked bare, the VERIFY scans exit
    2 — a usage error the gate then reads as a real finding, which is how a
    sound change was blocked at VERIFY in every graph-driven run. An
    unsubstitutable placeholder is a dispatch failure with its own exit code,
    never an empty argument handed to the script."""
    body = node.get("body") or ""
    if not body.endswith(".sh"):
        return None, ""
    body_path = repo_path(body, repo_root)
    if not os.path.isfile(body_path):
        return None, ""
    if _is_cycle_result_body(body_path):
        return None, ""
    args = []
    placeholders = _placeholders(node_id)
    for raw in node.get("bodyArgs") or []:
        unresolved = [t for t in PLACEHOLDER_RE.findall(raw) if not placeholders.get(t)]
        if unresolved:
            return UNRESOLVED_BODY_ARG, "unresolved bodyArgs placeholder %s on node %s" % (
                ", ".join(sorted(set(unresolved))), node_id)
        args.append(_substitute(raw, node_id))
    proc = subprocess.run(["bash", body_path] + args, cwd=repo_root,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return proc.returncode, proc.stdout.decode("utf-8", errors="replace").strip()


def dispatch_subgraph(node):
    """Nested run — for real, matching the parent's own mode (contract sec 6):
    a dry-run parent dry-runs its nested graph structurally; a real parent
    really runs it. Never unconditionally --dry-run regardless of the parent's
    mode, which was the shipped bug. Returns the nested run.sh exit code."""
    nested = node.get("graph")
    if not nested:
        return 0
    nested_path = repo_path(nested, repo_root)
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
    label = node.get("label") or current
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

    # Phase pointer: the graph owns successors, so the engine advances
    # currentPhase when entering a phase node — never before start-node
    # resolution (contract sec 5) and never for a dry run. The same
    # transition is what emits phase_start/phase_end: close the phase named
    # by the admitting edge, then open the node we are entering.
    emit_phase_boundaries(current, admitting)
    if not dry_run and current in PHASE_POINTER_IDS:
        feat_path = os.path.join(feature_dir, "feature.json")
        if os.path.isfile(feat_path):
            fw = os.environ.get("LOOP_SPEC_FEATURE_WRITE") or os.path.join(
                repo_root, "lib", "feature-write.sh")
            subprocess.call(
                ["bash", fw, "set", feature_dir, "currentPhase", json.dumps(current)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    if not step_mode:
        print("%s\t%s\t%s\t%s" % (current, admitting, kind, label))

    # Human admit gate (contract sec 4): admitted -> pause; unresolved or not
    # admitted -> skip (never dispatched either way — a human node has no body).
    if kind == "human":
        admit = node.get("admit")
        admitted = False
        resolved = False
        admit_probe, admit_token, admit_reason = None, None, None
        if admit:
            r = run_condition(admit, current)
            admitted = r["satisfied"]
            resolved = r["resolved"]
            admit_probe = admit.get("probe")
            admit_token = r["token"]
            admit_reason = r["reason"]
        # An unresolved admit is not a skip. Skipping is a decision, and only a
        # probe that ANSWERED has made one -- an unreadable feature.json or an
        # execStyle outside the enum means nobody decided, and falling through
        # there silently drops the human gate for the rest of the run. A dry run
        # still walks past, exactly as it walks past an admitted pause below:
        # it is a topology traversal, not an execution.
        if not resolved and not dry_run:
            detail = "human node %s: admit unresolved (%s); refusing to skip a human gate" % (
                current, admit_reason or "no admit condition declared")
            emit_trace(current, admitting, admit_probe,
                       "human-admit-unresolved:%s" % (admit_reason or "no-admit"), effort)
            checkpoint(current, admitting, effort)
            publish_result("failed", detail)
            print("run.sh: %s" % detail, file=sys.stderr)
            sys.exit(1)
        if admitted and not dry_run:
            emit_trace(current, admitting, admit_probe, admit_reason, effort)
            checkpoint(current, admitting, effort)
            pause = {"paused": True, "node": current, "edge": admitting, "featureDir": feature_dir}
            with open(os.path.join(feature_dir, "graph-pause.json"), "w", encoding="utf-8") as fh:
                json.dump(pause, fh)
            publish_result("paused", "paused at human node %s" % current)
            descriptor = {"node": current, "label": label, "kind": kind, "body": body,
                           "effort": effort, "nextEdge": admitting, "terminal": False,
                           "paused": True}
            if not step_mode:
                print("run.sh: paused at human node %s" % current, file=sys.stderr)
            return {"status": "paused", "descriptor": descriptor, "next": None}
        # Resolved and not admitted: skip, fall through to ordinary routing
        # exactly like any other node — `auto` and `review-only` answer
        # `gate=skip` here, and an answered skip is the run's own policy (sec 4).

    if kind == "subgraph" and not dry_run:
        rc = dispatch_subgraph(node)
        if rc != 0:
            emit_trace(current, admitting, None, "subgraph-failed:%d" % rc, effort)
            checkpoint(current, admitting, effort)
            sys.exit(rc)

    dispatch_rc = None
    if kind in ("function", "gate") and not dry_run:
        dispatch_rc, dispatch_out = dispatch_body(current, node, kind)
        if dispatch_rc is not None and dispatch_rc != 0:
            conflict_line = check_conflict(dispatch_rc)
            detail = "%s failed (exit %d); %s" % (current, dispatch_rc, conflict_line)
            if kind == "gate":
                emit_trace(current, admitting, body, "gate-failed:%d %s" % (dispatch_rc, conflict_line), effort)
                checkpoint(current, admitting, effort)
                publish_result("failed", "gate %s" % detail)
                print("run.sh: gate %s" % detail, file=sys.stderr)
                # The body's own diagnostic is what tells a reader whether the
                # gate found signals or could not run at all.
                if dispatch_out:
                    print(dispatch_out, file=sys.stderr)
                sys.exit(1)
            print("run.sh: function body %s" % detail, file=sys.stderr)
            if dispatch_out:
                print(dispatch_out, file=sys.stderr)

    if kind == "function" and dispatch_rc is None and body and _is_cycle_result_body(
            repo_path(body, repo_root)) and not dry_run:
        if publish_result("completed", "completed at %s" % current) != 0:
            sys.exit(3)

    emit_trace(current, admitting, None, effort_reason, effort)
    checkpoint(current, admitting, effort)

    descriptor = {"node": current, "label": label, "kind": kind, "body": body,
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
        # Only `completed` is the DELIVER→converged publication. Any other
        # dead-end (nested subgraph, synthetic terminal) is not a delivered
        # cycle and must not stamp last-result.json completed.
        if current == "completed":
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
