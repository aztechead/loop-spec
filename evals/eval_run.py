#!/usr/bin/env python3
"""Run the loop-spec outcome eval: one live cycle per task, then measure what came out.

Reader: a maintainer who wants to know whether a plugin change made cycles better,
cheaper, or worse. This is the only surface in the tree that runs a live model, so it
is NOT a test: tests/run-all.sh never registers it and CLAUDE.md tells agents not to
run it unasked. evals/run.sh is the launcher and holds the spend guard.

What one task run does:
  1. Copies evals/tasks/<id>/fixture into a fresh git repo with a bare `origin`
     (so DELIVER can push; there is no `gh`, so it stops at the pull-request step).
  2. Writes .loop-spec/profile.json with the `autonomous` preset.
  3. Runs `claude -p "/loop-spec:cycle autonomous <prompt>"` with this checkout as
     --plugin-dir, re-issuing the prompt while the cycle returns a paused result.
  4. Reads .loop-spec/last-result.json, the feature directory, and the git diff.
  5. Exports the feature branch and runs evals/tasks/<id>/check.sh against it.
  6. Reports over-build as app lines added over the task's reference size; a judge
     model that graded request match 3 of 3 on every run graded nothing.
  7. Writes evals/results/<run-id>/<id>.json and regenerates summary.md.

Exit: 0 when every requested task produced a result file (pass or fail); 1 when a task
crashed the driver; 2 bad invocation.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
TASKS_DIR = REPO / "evals" / "tasks"
RESULTS_DIR = REPO / "evals" / "results"
RUNS_DIR = REPO / "evals" / ".runs"
ARTIFACT_PREFIXES = ("docs/loop-spec/", ".loop-spec/", ".claude/")
DEFAULT_BUDGET = {"haiku": 8.0, "sonnet": 40.0, "opus": 80.0}
ROUND_TIMEOUT_S = 150 * 60  # --round-timeout-mins overrides; a six-task sonnet cycle ran 90 minutes and was killed in VERIFY
# The CLI ends the turn with this text, subtype "success", when the account's usage
# window is spent; ten concurrent runs hit it eleven minutes in and every record read
# as a plugin failure. A round that says this measured the account, not the plugin.
USAGE_LIMIT_RE = re.compile(r"hit your (?:session|usage|weekly|daily) limit|usage limit reached|rate.?limit", re.I)
# One round per phase (up to eight on the full route) plus a REDO, a rewind, or a
# recovery round: every phase hands off, so a delivered cycle is many rounds by design.
MAX_ROUNDS = 16
ALLOWED_TOOLS = ",".join((
    "Bash", "Read", "Write", "Edit", "MultiEdit", "Glob", "Grep", "Agent", "Skill",
    "TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "SendMessage", "TeamCreate",
    "TeamDelete", "EnterWorktree", "ExitWorktree", "ToolSearch", "WebFetch", "WebSearch"))


def sh(args, cwd, env=None, check=True, timeout=None):
    return subprocess.run(args, cwd=str(cwd), env=env, check=check, timeout=timeout,
                          capture_output=True, text=True)


# What makes a nested claude -p write into its parent's transcript instead of its own.
SESSION_IDENTITY = ("CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION",
                    "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_REMOTE_SESSION_ID",
                    "CLAUDE_CODE_SYNC_SESSION_REFS")


def child_env():
    """The nested CLI must not inherit this session's plugin or project bindings."""
    # The parent session's identity is dropped too: a nested `claude -p` that inherits
    # the session id and the remote-session plumbing appends every round to the parent's
    # transcript, and the phase-handoff guard then reads round one's phase as "already
    # run in this invocation" in round three. Measured: only dropping all of these gave
    # the child its own transcript. The launch stamp goes too: the CLI writes
    # CLAUDE_CODE_ENTRYPOINT only when it is unset, so a child under an attended session
    # inherited `remote_mobile`, answered the session-layer probe "attended", and never
    # took the session rung (final-sonnet-fastapi, round 7).
    env = {k: v for k, v in os.environ.items()
           if not k.startswith("LOOP_SPEC_")
           and k not in ("CLAUDE_PROJECT_DIR", "CLAUDE_SKILL_DIR", "CLAUDE_PLUGIN_ROOT")
           and k not in SESSION_IDENTITY and k != "CLAUDE_CODE_ENTRYPOINT"}
    # Fork mode backgrounds every Agent and ignores run_in_background on the call; the
    # 20260909-sonnet-fastapi run saw the launch stub on all eight dispatches and paid
    # a wait turn for each report. This is the harness's documented foreground switch.
    env["CLAUDE_CODE_DISABLE_BACKGROUND_TASKS"] = "1"
    env["GIT_AUTHOR_NAME"] = env["GIT_COMMITTER_NAME"] = "loop-spec-eval"
    env["GIT_AUTHOR_EMAIL"] = env["GIT_COMMITTER_EMAIL"] = "eval@loop-spec.invalid"
    return env


def load_task(task_id):
    path = TASKS_DIR / task_id / "task.json"
    if not path.is_file():
        raise SystemExit(f"eval_run: no task at {path}")
    task = json.loads(path.read_text())
    task["dir"] = path.parent
    return task


def plugin_snapshot(run_dir):
    """A copy of the checkout for the cycle to load, so a cycle that edits its own
    plugin (one sonnet run edited lib/runtime-ignore.sh) touches the copy, and the
    diff against a second pristine copy records the tampering instead of hiding it."""
    snap = run_dir / "plugin"
    pristine = run_dir / "plugin-pristine"
    if not snap.exists():
        ignore = shutil.ignore_patterns(".git", ".runs", "results", "__pycache__", "*.pyc", "node_modules")
        shutil.copytree(REPO, snap, ignore=ignore, symlinks=True)
        shutil.copytree(snap, pristine, symlinks=True)
    return snap


def workarounds(project, env):
    """Things a cycle did to its host that the plugin never asked for."""
    found = []
    if not (project / ".loop-spec" / "profile.json").is_file():
        found.append("deleted .loop-spec/profile.json")
    # The plugin writes its own exclude lines (lib/runtime-ignore.sh); only a line it
    # does not write counts as the model's doing.
    exclude = project / ".git" / "info" / "exclude"
    own = set(re.findall(r"'(/\.loop-spec/[^']+)'", (REPO / "lib" / "runtime-ignore.sh").read_text()))
    if exclude.is_file() and any("profile.json" in l and l.strip() not in own for l in exclude.read_text().splitlines()):
        found.append("added profile.json to .git/info/exclude")
    if (project / ".gitignore").is_file() and "profile.json" in (project / ".gitignore").read_text():
        found.append("added profile.json to .gitignore")
    return found


def prepare_workspace(task, run_dir, env):
    root = run_dir / task["id"]
    if root.exists():
        shutil.rmtree(root)
    project = root / "project"
    shutil.copytree(task["dir"] / "fixture", project,
                    ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    origin = root / "origin.git"
    sh(["git", "init", "--bare", "-q", str(origin)], cwd=root, env=env)
    sh(["git", "init", "-q", "-b", "main"], cwd=project, env=env)
    sh(["git", "add", "-A"], cwd=project, env=env)
    sh(["git", "commit", "-q", "-m", "fixture"], cwd=project, env=env)
    sh(["git", "remote", "add", "origin", str(origin)], cwd=project, env=env)
    sh(["git", "push", "-q", "-u", "origin", "main"], cwd=project, env=env)
    (project / ".loop-spec").mkdir()
    (project / ".loop-spec" / "profile.json").write_text(
        json.dumps({"preset": "autonomous"}, indent=2) + "\n")
    base = sh(["git", "rev-parse", "HEAD"], cwd=project, env=env).stdout.strip()
    return project, base


def run_round(project, prompt, model, budget, env, log_path, plugin_dir, timeout_s=None):
    cmd = ["claude", "-p", prompt, "--model", model,
           "--plugin-dir", str(plugin_dir),
           # bypassPermissions is refused for root, which CI containers often are;
           # acceptEdits plus an explicit allow-list is the portable equivalent.
           "--permission-mode", "acceptEdits",
           "--allowedTools", ALLOWED_TOOLS,
           "--setting-sources", "project",
           "--output-format", "json",
           "--max-budget-usd", f"{budget:.2f}"]
    started = time.time()
    try:
        proc = subprocess.run(cmd, cwd=str(project), env=env, capture_output=True,
                              text=True, timeout=timeout_s or ROUND_TIMEOUT_S)
        timed_out = False
        stdout, stderr, rc = proc.stdout, proc.stderr, proc.returncode
    except subprocess.TimeoutExpired as exc:
        timed_out = True
        stdout = (exc.stdout or b"").decode() if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        stderr = (exc.stderr or b"").decode() if isinstance(exc.stderr, bytes) else (exc.stderr or "")
        rc = -1
    elapsed = time.time() - started
    log_path.write_text(stdout + "\n--- stderr ---\n" + stderr)
    payload = None
    for candidate in (stdout.strip(), stdout.strip().splitlines()[-1] if stdout.strip() else ""):
        try:
            payload = json.loads(candidate)
            break
        except (json.JSONDecodeError, TypeError):
            continue
    payload = payload if isinstance(payload, dict) else {}
    usage = payload.get("usage") or {}
    return {
        "rc": rc, "timed_out": timed_out, "seconds": round(elapsed, 1),
        "subtype": payload.get("subtype"), "is_error": payload.get("is_error"),
        "cost_usd": payload.get("total_cost_usd"),
        "num_turns": payload.get("num_turns"),
        "input_tokens": usage.get("input_tokens"),
        "output_tokens": usage.get("output_tokens"),
        "cache_read_tokens": usage.get("cache_read_input_tokens"),
        "cache_create_tokens": usage.get("cache_creation_input_tokens"),
        "subagents_spawned": (payload.get("subagent_stats") or {}).get("spawned"),
        "result_text": (payload.get("result") or "")[:2000],
        "stderr_tail": stderr[-1500:],
        "cut_off": "usage-limit" if USAGE_LIMIT_RE.search(payload.get("result") or "") else None,
    }


def read_json(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError):
        return None


def roots(project, env):
    """The project plus every worktree the cycle made: state can live in any of them."""
    out = sh(["git", "worktree", "list", "--porcelain"], cwd=project, env=env, check=False).stdout
    paths = [Path(line.split(" ", 1)[1]) for line in out.splitlines() if line.startswith("worktree ")]
    return [project] + [p for p in paths if p != project]


def newest(paths):
    paths = [p for p in paths if p.is_file()]
    return max(paths, key=lambda p: p.stat().st_mtime) if paths else None


def branch_of(project, result, feature, env):
    for candidate in ((result or {}).get("branch"), (feature or {}).get("branch")):
        if candidate and sh(["git", "rev-parse", "--verify", "-q", candidate],
                            cwd=project, env=env, check=False).returncode == 0:
            return candidate
    out = sh(["git", "for-each-ref", "--sort=-committerdate", "--format=%(refname:short)",
              "refs/heads/"], cwd=project, env=env).stdout.split()
    return next((b for b in out if b != "main"), "main")


def diff_metrics(project, base, branch, protected, env):
    numstat = sh(["git", "diff", "--numstat", f"{base}..{branch}"], cwd=project, env=env).stdout
    app = {"files": 0, "added": 0, "removed": 0, "paths": []}
    artifacts = {"files": 0, "added": 0, "removed": 0}
    for line in numstat.splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        add, rem, path = parts
        add = int(add) if add.isdigit() else 0
        rem = int(rem) if rem.isdigit() else 0
        bucket = artifacts if path.startswith(ARTIFACT_PREFIXES) else app
        bucket["files"] += 1
        bucket["added"] += add
        bucket["removed"] += rem
        if bucket is app:
            app["paths"].append(path)
    changed = set(app["paths"])
    protected_touched = sorted(p for p in protected if p in changed)
    commits = sh(["git", "rev-list", "--count", f"{base}..{branch}"], cwd=project, env=env).stdout.strip()
    return app, artifacts, protected_touched, int(commits or 0)


def export_and_check(task, project, branch, root, env):
    checkout = root / "checkout"
    if checkout.exists():
        shutil.rmtree(checkout)
    checkout.mkdir()
    archive = subprocess.run(["git", "archive", branch], cwd=str(project), env=env,
                             capture_output=True, check=True)
    subprocess.run(["tar", "-x", "-C", str(checkout)], input=archive.stdout, check=True)
    shutil.copy(task["dir"] / "check.sh", checkout / "check.sh")
    proc = subprocess.run(["bash", "check.sh"], cwd=str(checkout), env=env,
                          capture_output=True, text=True, timeout=300)
    checks = {}
    for line in proc.stdout.splitlines():
        m = re.match(r"CHECK (\S+) (PASS|FAIL)(?: (.*))?", line)
        if m:
            checks[m.group(1)] = {"pass": m.group(2) == "PASS", "note": m.group(3) or ""}
    return checks


def run_task(task_id, model, run_id, budget, measure_only=False, commit=None, timeout_s=None):
    task = load_task(task_id)
    env = child_env()
    run_dir = RUNS_DIR / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    root = run_dir / task_id
    project = root / "project"
    rounds = []
    spent = 0.0
    result = None
    if measure_only:
        # Re-score a workspace an earlier run paid for; keep its round figures.
        prior = read_json(RESULTS_DIR / run_id / f"{task_id}.json") or {}
        # The record's model is the one that ran; the flag on a re-score is not.
        model = prior.get("model") or model
        rounds = prior.get("rounds_detail") or []
        for r in rounds:
            r.setdefault("result_text", prior.get("last_result_text", ""))
            r.setdefault("stderr_tail", prior.get("last_stderr_tail", ""))
            r.setdefault("cut_off", "usage-limit" if USAGE_LIMIT_RE.search(r["result_text"]) else None)
        spent = prior.get("cost_usd") or 0.0
        base = sh(["git", "rev-list", "--max-parents=0", "main"], cwd=project, env=env).stdout.strip()
        result = read_json(newest([r / ".loop-spec" / "last-result.json" for r in roots(project, env)]) or "")
    else:
        project, base = prepare_workspace(task, run_dir, env)
    plugin_dir = plugin_snapshot(run_dir)
    # Every phase returns and the next round starts the lead in a fresh context: the
    # 20260909-sonnet-fastapi-3 lead re-read ~277k tokens on each of 569 calls in one
    # continuous session, 71 percent of that run's cost.
    prompt = f"/loop-spec:cycle autonomous {task['prompt']}"
    for n in range(1, MAX_ROUNDS + 1):
        if measure_only:
            break
        remaining = budget - spent
        if remaining <= 0.5:
            break
        print(f"[{task_id}/{model}] round {n} budget {remaining:.2f}", flush=True)
        r = run_round(project, prompt, model, remaining, env, root / f"round-{n}.log", plugin_dir, timeout_s)
        rounds.append(r)
        spent += r["cost_usd"] or 0.0
        result = read_json(newest([r / ".loop-spec" / "last-result.json" for r in roots(project, env)]) or "")
        status = (result or {}).get("status")
        print(f"[{task_id}/{model}] round {n} sdk={r['subtype']} cost={r['cost_usd']} "
              f"turns={r['num_turns']} status={status} phase={(result or {}).get('phaseReached')}",
              flush=True)
        if r["subtype"] is None:
            print(f"[{task_id}/{model}] round {n} produced no result payload; stderr tail: "
                  f"{r['stderr_tail'][-300:]!r}", flush=True)
        if r["cut_off"]:
            print(f"[{task_id}/{model}] round {n} CUT OFF by the account usage limit: "
                  f"{r['result_text'][:120]!r}; this record measures the account, not the plugin",
                  flush=True)
        if r["timed_out"] or status != "paused":
            break
    # Completion removes feature.json and leaves feature.json.bak; either names the dir.
    feature_file = newest([f for r in roots(project, env) for pattern in ("*/feature.json", "*/feature.json.bak")
                           for f in (r / ".loop-spec" / "features").glob(pattern)])
    fdir = feature_file.parent if feature_file else None
    feature = read_json(feature_file) if feature_file else None
    branch = branch_of(project, result, feature, env)
    app, artifacts, protected_touched, commits = diff_metrics(
        project, base, branch, task.get("protected", []), env)
    checks = export_and_check(task, project, branch, root, env)
    # DELIVER's word is the sidecar; feature.json's delivery block stays pending after it.
    delivery = read_json(fdir / "delivery.json") if fdir and (fdir / "delivery.json").is_file() else None
    delivery_status = (delivery or (feature or {}).get("delivery") or {}).get("status")
    events = 0
    redo = {"rounds": 0, "by_class": {}}
    if fdir and (fdir / "events.jsonl").is_file():
        for line in (fdir / "events.jsonl").open():
            events += 1
            try:
                e = json.loads(line)
            except ValueError:
                continue
            # The driver emits one per REDO answer, with the bracketed label of every
            # FLAG line (orchestrator-port-followup-3.md, N1): the record says which
            # gate bounced the lead, not just how often.
            if e.get("event") == "redo":
                redo["rounds"] += 1
                for label, n in ((e.get("data") or {}).get("classes") or {}).items():
                    redo["by_class"][label] = redo["by_class"].get(label, 0) + int(n or 0)
    passed = sum(1 for c in checks.values() if c["pass"])
    record = {
        "task": task_id, "size": task.get("size"), "kind": task.get("kind"),
        "model": model, "run_id": run_id, "plugin_version": plugin_version(),
        # The commit the snapshot was taken from, read once at launch: a record scored
        # after later edits must not report the tree as dirty.
        "plugin_commit": commit or plugin_commit(),
        "rounds": len(rounds),
        "cost_usd": round(spent, 4),
        "minutes": round(sum(r["seconds"] for r in rounds) / 60, 1),
        "turns": sum(r["num_turns"] or 0 for r in rounds),
        "subagents": sum(r["subagents_spawned"] or 0 for r in rounds),
        "tokens": {k: sum(r[k] or 0 for r in rounds) for k in
                   ("input_tokens", "output_tokens", "cache_read_tokens", "cache_create_tokens")},
        "timed_out": any(r["timed_out"] for r in rounds),
        "cut_off": next((r["cut_off"] for r in rounds if r.get("cut_off")), None),
        "result": {k: (result or {}).get(k) for k in
                   ("status", "outcome", "reason", "phaseReached", "converged", "summary")},
        # cycle-result.sh stamps schema and loopSpecVersion; a pointer without them was
        # written by hand (the 6.1.0 readme-sync and 6.2.0 wc-json runs both did).
        "forged_result": bool(result) and not (result.get("schema") and result.get("loopSpecVersion")),
        "iterations": ((feature or {}).get("iterate") or {}).get("used"),
        # The driver writes feature.json when the cycle begins; a run with no feature
        # never entered a phase, whatever the lead edited (the dda2cca wc-json run
        # followed the ad-hoc micro directive instead and stopped with nothing).
        "cycle_begun": feature_file is not None,
        # The pass bar (orchestrator-port-plan.md, WP1): a delivered run at or under
        # every figure. Recorded so the stopping rule is read, not argued.
        "bar": bar_verdict(task.get("bar"), spent, artifacts, sum(r["seconds"] for r in rounds) / 60, len(rounds)),
        "phase": (feature or {}).get("currentPhase"),
        "delivery_status": delivery_status,
        "delivered": delivery_status in ("ready-for-review", "delivered-draft", "pushed-no-pr"),
        "events": events,
        "redo": redo,
        # The classes a driver-written shape makes impossible; a live run records zero here.
        "format_redo": sum(redo["by_class"].get(c, 0) for c in FORMAT_CLASSES),
        "branch": branch, "commits": commits,
        "app_diff": app, "artifact_diff": artifacts,
        "overbuild_ratio": round(app["added"] / max(task.get("reference_app_lines", 1), 1), 2),
        "protected_touched": protected_touched,
        "plugin_tampered": [line for line in subprocess.run(
            ["diff", "-rq", "-x", "__pycache__", "-x", "*.pyc", str(run_dir / "plugin-pristine"), str(run_dir / "plugin")],
            capture_output=True, text=True).stdout.splitlines() if line.strip()],
        "workarounds": workarounds(project, env),
        "checks": checks, "checks_passed": passed, "checks_total": len(checks),
        "accepted": bool(checks) and passed == len(checks) and not protected_touched,
        "rounds_detail": [{k: v for k, v in r.items() if k not in ("result_text", "stderr_tail")}
                          for r in rounds],
        "last_result_text": rounds[-1]["result_text"] if rounds else "",
        "last_stderr_tail": rounds[-1]["stderr_tail"] if rounds else "",
        "workspace": str(root),
    }
    out_dir = RESULTS_DIR / run_id
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / f"{task_id}.json").write_text(json.dumps(record, indent=2) + "\n")
    write_summary(out_dir)
    print(f"[{task_id}/{model}] accepted={record['accepted']} checks={passed}/{len(checks)} "
          f"cost={spent:.2f} minutes={record['minutes']}", flush=True)
    return record


FORMAT_CLASSES = ("artifact-lint", "verification-grounding", "misplaced", "oneshot-shape", "review-triage", "converged-floor")


def bar_verdict(bar, cost, artifacts, minutes, rounds):
    """{met, over:[...]} against the task's bar, or None when the task sets none."""
    if not bar:
        return None
    over = []
    if cost > bar.get("cost_usd", float("inf")):
        over.append("cost %.2f > %.2f USD" % (cost, bar["cost_usd"]))
    if artifacts["added"] > bar.get("artifact_lines", float("inf")):
        over.append("artifact lines %d > %d" % (artifacts["added"], bar["artifact_lines"]))
    if minutes > bar.get("minutes", float("inf")):
        over.append("minutes %.1f > %s" % (minutes, bar["minutes"]))
    if rounds > 1:
        over.append("rounds %d > 1" % rounds)
    return {"met": not over, "over": over}


def plugin_commit():
    """The checkout the snapshot was taken from; a version number alone cannot tell two
    builds of one release apart."""
    try:
        head = sh(["git", "rev-parse", "--short", "HEAD"], cwd=REPO, check=False).stdout.strip()
        dirty = sh(["git", "status", "--porcelain", "--", "lib", "hooks", "skills", "graph"],
                   cwd=REPO, check=False).stdout.strip()
        return head + ("-dirty" if dirty else "")
    except OSError:
        return None


def plugin_version():
    try:
        return json.loads((REPO / ".claude-plugin" / "plugin.json").read_text()).get("version")
    except (OSError, json.JSONDecodeError):
        return None


def write_summary(out_dir):
    records = [read_json(p) for p in sorted(out_dir.glob("*.json"))]
    records = [r for r in records if r]
    if not records:
        return
    lines = [f"# Eval run {out_dir.name}", "",
             f"Plugin {records[0].get('plugin_version')} at {records[0].get('plugin_commit')}, "
             f"model {records[0].get('model')}, "
             f"{len(records)} task(s). Acceptance is `check.sh`; over-build is app lines added over the task's reference size.", "",
             "| task | accepted | delivered | checks | phase | status | rounds | turns | agents | cost USD | min | app files | app +/- | artifact + | over-build | protected touched |",
             "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in records:
        lines.append(
            f"| {r['task']} | {'yes' if r['accepted'] else 'NO'} | {'yes' if r.get('delivered') else 'no'} "
            f"| {r['checks_passed']}/{r['checks_total']} "
            f"| {r.get('phase')} | {r['result'].get('status') or ('no cycle' if not r.get('cycle_begun') else None)} | {r['rounds']} | {r['turns']} "
            f"| {r['subagents']} | {r['cost_usd']:.2f} | {r['minutes']} | {r['app_diff']['files']} "
            f"| +{r['app_diff']['added']}/-{r['app_diff']['removed']} | +{r['artifact_diff']['added']} "
            f"| {r['overbuild_ratio']}x | {', '.join(r['protected_touched']) or '-'} |")
    total_cost = sum(r["cost_usd"] for r in records)
    accepted = sum(1 for r in records if r["accepted"])
    delivered = sum(1 for r in records if r.get("delivered"))
    cut = sum(1 for r in records if r.get("cut_off"))
    lines += ["", f"Accepted {accepted}/{len(records)}. Delivered {delivered}/{len(records)}. "
                  f"Total cost USD {total_cost:.2f}. "
                  f"Total minutes {sum(r['minutes'] for r in records):.1f}."
                  + (f" CUT OFF by the account usage limit: {cut}/{len(records)}; those rows measure "
                     f"the account, not the plugin. Re-run them after the window resets." if cut else ""), ""]
    for r in records:
        if r.get("cut_off"):
            lines.append(f"- **{r['task']}** cut off by the account usage limit after {r['minutes']} min; not a plugin outcome")
        bar = r.get("bar")
        if bar is not None:
            if bar["met"] and r.get("delivered"):
                lines.append(f"- **{r['task']}** at the bar: delivered in one round at or under every figure")
            else:
                lines.append(f"- **{r['task']}** over the bar: {'; '.join(bar['over']) or 'not delivered'}")
            redo = r.get("redo") or {}
            if redo.get("rounds"):
                by = ", ".join(f"{k} {v}" for k, v in sorted(redo.get("by_class", {}).items()))
                lines.append(f"- **{r['task']}** REDO rounds: {redo['rounds']} ({by}); format classes: {r.get('format_redo', 0)}")
        if not r.get("cycle_begun"):
            lines.append(f"- **{r['task']}** never began a cycle: the driver wrote no feature.json, so the row measures the entry, not the plugin's phases")
        if r.get("forged_result"):
            lines.append(f"- **{r['task']}** wrote its terminal result by hand (no schema or version stamp): status untrusted")
        failed = [f"{k}: {v['note']}".rstrip(": ") for k, v in r["checks"].items() if not v["pass"]]
        if failed or r["protected_touched"]:
            lines.append(f"- **{r['task']}** failed: {'; '.join(failed) or 'protected file changed'}")
        for w in r.get("workarounds") or []:
            lines.append(f"- {r['task']} workaround: {w}")
        for t in r.get("plugin_tampered") or []:
            lines.append(f"- {r['task']} EDITED THE PLUGIN: {t}")
        if r["result"].get("reason"):
            lines.append(f"- {r['task']} terminal reason: {r['result']['reason']}")
    (out_dir / "summary.md").write_text("\n".join(lines) + "\n")


def preflight(models):
    """Prove, for about three cents, every condition whose failure cost a re-run last time:
    the CLI is on PATH and signed in; a tool call runs under the permission mode the
    driver uses (bypass is refused for root); the fixtures carry no compiled files; the plugin checkout is committed, so the snapshot
    and the record's commit agree. Returns a list of failures; empty means go."""
    failures = []
    if shutil.which("claude") is None:
        return ["no `claude` on PATH"]
    env = child_env()
    for model in models:
        proc = subprocess.run(["claude", "-p", "Run exactly this shell command and reply with its output only: echo preflight-ok",
                               "--model", model, "--max-turns", "3", "--permission-mode", "acceptEdits",
                               "--allowedTools", ALLOWED_TOOLS, "--setting-sources", "project", "--output-format", "json"],
                              capture_output=True, text=True, timeout=180, env=env, cwd=str(REPO))
        try:
            payload = json.loads(proc.stdout)
        except json.JSONDecodeError:
            payload = {}
        if USAGE_LIMIT_RE.search(payload.get("result") or ""):
            failures.append(f"{model}: the account usage limit is active ({payload.get('result')!r}); "
                            "every round would end at once")
        elif payload.get("is_error") or "preflight-ok" not in (payload.get("result") or ""):
            failures.append(f"{model}: a tool call under acceptEdits did not run "
                            f"(result={str(payload.get('result') or proc.stderr)[:160]!r})")
    stray = [str(f) for f in TASKS_DIR.rglob("*") if f.name == "__pycache__" or f.suffix == ".pyc"]
    if stray:
        failures.append(f"fixtures carry compiled files: {stray[:3]}")
    dirty = sh(["git", "status", "--porcelain", "--", "lib", "hooks", "skills", "graph", "evals/eval_run.py", "evals/tasks"],
               cwd=REPO, check=False).stdout.strip()
    if dirty:
        failures.append("the plugin checkout has uncommitted changes; commit (after the gate) so the snapshot "
                        "and the record's commit agree:\n" + dirty)
    free_gb = shutil.disk_usage(str(REPO)).free / 1e9
    if free_gb < 1.0:
        failures.append(f"only {free_gb:.1f} GB free under {REPO}")
    return failures


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--model", required=True)
    ap.add_argument("--tasks", default="all", help="comma list of task ids, or all")
    ap.add_argument("--parallel", type=int, default=1)
    ap.add_argument("--budget-usd", type=float, default=None, help="per task; default by model")
    ap.add_argument("--run-id", default=None)
    ap.add_argument("--confirm-spend", action="store_true")
    ap.add_argument("--round-timeout-mins", type=int, default=None,
                    help="kill a round after this many minutes (default 150)")
    ap.add_argument("--measure-only", action="store_true",
                    help="re-score the workspaces of --run-id without running a cycle (free)")
    ap.add_argument("--preflight-only", action="store_true", help="run the preflight checks and stop")
    ap.add_argument("--skip-preflight", action="store_true", help="start without the checks (not advised)")
    args = ap.parse_args(argv)
    if args.measure_only and not args.run_id:
        print("eval_run: --measure-only needs --run-id", file=sys.stderr)
        return 2
    if not args.measure_only and (os.environ.get("LOOP_SPEC_EVAL_LIVE") != "1" or not args.confirm_spend):
        print("eval_run: refusing to spend money. Set LOOP_SPEC_EVAL_LIVE=1 and pass "
              "--confirm-spend. Read evals/README.md first.", file=sys.stderr)
        return 2
    if shutil.which("claude") is None:
        print("eval_run: no `claude` on PATH", file=sys.stderr)
        return 2
    if not args.measure_only and not args.skip_preflight:
        problems = preflight([args.model])
        for problem in problems:
            print(f"eval_run: preflight: {problem}", file=sys.stderr)
        if problems:
            print("eval_run: refusing to start; every item above cost a re-run last time", file=sys.stderr)
            return 2
        print("eval_run: preflight ok (CLI, permissions, fixtures, clean checkout, disk)", flush=True)
        if args.preflight_only:
            return 0
    task_ids = ([p.name for p in sorted(TASKS_DIR.iterdir()) if (p / "task.json").is_file()]
                if args.tasks == "all" else args.tasks.split(","))
    budget = args.budget_usd or DEFAULT_BUDGET.get(args.model, 10.0)
    run_id = args.run_id or f"{dt.datetime.now(dt.timezone.utc):%Y%m%d-%H%M}-{args.model}"
    commit = plugin_commit()
    print(f"eval_run: run {run_id}, tasks {task_ids}, budget {budget} USD per task, plugin {commit}", flush=True)
    failures = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.parallel)) as pool:
        timeout_s = args.round_timeout_mins * 60 if args.round_timeout_mins else None
        futures = {pool.submit(run_task, t, args.model, run_id, budget, args.measure_only, commit,
                               timeout_s): t
                   for t in task_ids}
        for fut in concurrent.futures.as_completed(futures):
            try:
                fut.result()
            except Exception as exc:  # a crashed task must not hide the others
                failures += 1
                print(f"eval_run: task {futures[fut]} crashed: {exc!r}", file=sys.stderr, flush=True)
    print(f"eval_run: results in {RESULTS_DIR / run_id}", flush=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
