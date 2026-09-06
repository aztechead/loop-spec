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
  6. Asks a cheap judge model whether the diff matches the request and how over-built
     it is. The judge is advisory; check.sh is the acceptance.
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
DEFAULT_BUDGET = {"haiku": 8.0, "sonnet": 20.0, "opus": 40.0}
ROUND_TIMEOUT_S = 45 * 60
MAX_ROUNDS = 8
ALLOWED_TOOLS = ",".join((
    "Bash", "Read", "Write", "Edit", "MultiEdit", "Glob", "Grep", "Agent", "Skill",
    "TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "SendMessage", "TeamCreate",
    "TeamDelete", "EnterWorktree", "ExitWorktree", "ToolSearch", "WebFetch", "WebSearch"))


def sh(args, cwd, env=None, check=True, timeout=None):
    return subprocess.run(args, cwd=str(cwd), env=env, check=check, timeout=timeout,
                          capture_output=True, text=True)


def child_env():
    """The nested CLI must not inherit this session's plugin or project bindings."""
    env = {k: v for k, v in os.environ.items()
           if not k.startswith("LOOP_SPEC_")
           and k not in ("CLAUDE_PROJECT_DIR", "CLAUDE_SKILL_DIR", "CLAUDE_PLUGIN_ROOT")}
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


def prepare_workspace(task, run_dir, env):
    root = run_dir / task["id"]
    if root.exists():
        shutil.rmtree(root)
    project = root / "project"
    shutil.copytree(task["dir"] / "fixture", project)
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


def run_round(project, prompt, model, budget, env, log_path):
    cmd = ["claude", "-p", prompt, "--model", model,
           "--plugin-dir", str(REPO),
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
                              text=True, timeout=ROUND_TIMEOUT_S)
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


def judge(task, project, base, branch, env, log_path):
    diff = sh(["git", "diff", f"{base}..{branch}", "--", ".", ":(exclude)docs/loop-spec",
               ":(exclude).loop-spec", ":(exclude).claude"], cwd=project, env=env).stdout
    lines = diff.splitlines()
    if len(lines) > 400:
        diff = "\n".join(lines[:400]) + f"\n... ({len(lines) - 400} more diff lines)"
    prompt = (
        "You grade a code change against the request that produced it.\n"
        f"REQUEST:\n{task['prompt']}\n\nDIFF (project files only):\n{diff or '(empty diff)'}\n\n"
        "Answer with one JSON object and nothing else: "
        '{"meets_request": 0-3, "overbuilt": 0-3, "note": "<one sentence>"}. '
        "meets_request: 3 = does exactly what was asked, 0 = does not address it. "
        "overbuilt: 0 = no more than the request needs, 3 = large unrequested additions."
    )
    proc = subprocess.run(["claude", "-p", prompt, "--bare", "--model", "haiku",
                           "--max-turns", "1", "--output-format", "json"],
                          cwd=str(project), env=env, capture_output=True, text=True, timeout=300)
    log_path.write_text(proc.stdout + "\n--- stderr ---\n" + proc.stderr)
    try:
        text = json.loads(proc.stdout).get("result", "")
        m = re.search(r"\{.*\}", text, re.S)
        verdict = json.loads(m.group(0)) if m else {}
    except (json.JSONDecodeError, AttributeError):
        verdict = {}
    return {"meets_request": verdict.get("meets_request"),
            "overbuilt": verdict.get("overbuilt"),
            "note": str(verdict.get("note", ""))[:300]}


def run_task(task_id, model, run_id, budget):
    task = load_task(task_id)
    env = child_env()
    run_dir = RUNS_DIR / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    project, base = prepare_workspace(task, run_dir, env)
    root = project.parent
    prompt = f"/loop-spec:cycle autonomous {task['prompt']}"
    rounds = []
    spent = 0.0
    result = None
    for n in range(1, MAX_ROUNDS + 1):
        remaining = budget - spent
        if remaining <= 0.5:
            break
        print(f"[{task_id}/{model}] round {n} budget {remaining:.2f}", flush=True)
        r = run_round(project, prompt, model, remaining, env, root / f"round-{n}.log")
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
        if r["timed_out"] or status != "paused":
            break
    feature_file = newest([f for r in roots(project, env)
                           for f in (r / ".loop-spec" / "features").glob("*/feature.json")])
    fdir = feature_file.parent if feature_file else None
    feature = read_json(feature_file) if feature_file else None
    branch = branch_of(project, result, feature, env)
    app, artifacts, protected_touched, commits = diff_metrics(
        project, base, branch, task.get("protected", []), env)
    checks = export_and_check(task, project, branch, root, env)
    verdict = judge(task, project, base, branch, env, root / "judge.log")
    events = 0
    if fdir and (fdir / "events.jsonl").is_file():
        events = sum(1 for _ in (fdir / "events.jsonl").open())
    passed = sum(1 for c in checks.values() if c["pass"])
    record = {
        "task": task_id, "size": task.get("size"), "kind": task.get("kind"),
        "model": model, "run_id": run_id, "plugin_version": plugin_version(),
        "rounds": len(rounds),
        "cost_usd": round(spent, 4),
        "minutes": round(sum(r["seconds"] for r in rounds) / 60, 1),
        "turns": sum(r["num_turns"] or 0 for r in rounds),
        "subagents": sum(r["subagents_spawned"] or 0 for r in rounds),
        "tokens": {k: sum(r[k] or 0 for r in rounds) for k in
                   ("input_tokens", "output_tokens", "cache_read_tokens", "cache_create_tokens")},
        "timed_out": any(r["timed_out"] for r in rounds),
        "result": {k: (result or {}).get(k) for k in
                   ("status", "outcome", "reason", "phaseReached", "converged", "summary")},
        "iterations": ((feature or {}).get("iterate") or {}).get("iterations")
        if isinstance((feature or {}).get("iterate"), dict) else None,
        "events": events,
        "branch": branch, "commits": commits,
        "app_diff": app, "artifact_diff": artifacts,
        "overbuild_ratio": round(app["added"] / max(task.get("reference_app_lines", 1), 1), 2),
        "protected_touched": protected_touched,
        "checks": checks, "checks_passed": passed, "checks_total": len(checks),
        "accepted": bool(checks) and passed == len(checks) and not protected_touched,
        "judge": verdict,
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
             f"Plugin {records[0].get('plugin_version')}, model {records[0].get('model')}, "
             f"{len(records)} task(s). Acceptance is `check.sh`; the judge is advisory.", "",
             "| task | accepted | checks | phase | status | rounds | turns | agents | cost USD | min | app files | app +/- | artifact + | over-build | protected touched | judge meets/over |",
             "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in records:
        j = r.get("judge") or {}
        lines.append(
            f"| {r['task']} | {'yes' if r['accepted'] else 'NO'} | {r['checks_passed']}/{r['checks_total']} "
            f"| {r['result'].get('phaseReached')} | {r['result'].get('status')} | {r['rounds']} | {r['turns']} "
            f"| {r['subagents']} | {r['cost_usd']:.2f} | {r['minutes']} | {r['app_diff']['files']} "
            f"| +{r['app_diff']['added']}/-{r['app_diff']['removed']} | +{r['artifact_diff']['added']} "
            f"| {r['overbuild_ratio']}x | {', '.join(r['protected_touched']) or '-'} "
            f"| {j.get('meets_request')}/{j.get('overbuilt')} |")
    total_cost = sum(r["cost_usd"] for r in records)
    accepted = sum(1 for r in records if r["accepted"])
    lines += ["", f"Accepted {accepted}/{len(records)}. Total cost USD {total_cost:.2f}. "
                  f"Total minutes {sum(r['minutes'] for r in records):.1f}.", ""]
    for r in records:
        failed = [f"{k}: {v['note']}".rstrip(": ") for k, v in r["checks"].items() if not v["pass"]]
        if failed or r["protected_touched"]:
            lines.append(f"- **{r['task']}** failed: {'; '.join(failed) or 'protected file changed'}")
        if r["result"].get("reason"):
            lines.append(f"- {r['task']} terminal reason: {r['result']['reason']}")
    (out_dir / "summary.md").write_text("\n".join(lines) + "\n")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--model", required=True)
    ap.add_argument("--tasks", default="all", help="comma list of task ids, or all")
    ap.add_argument("--parallel", type=int, default=1)
    ap.add_argument("--budget-usd", type=float, default=None, help="per task; default by model")
    ap.add_argument("--run-id", default=None)
    ap.add_argument("--confirm-spend", action="store_true")
    args = ap.parse_args(argv)
    if os.environ.get("LOOP_SPEC_EVAL_LIVE") != "1" or not args.confirm_spend:
        print("eval_run: refusing to spend money. Set LOOP_SPEC_EVAL_LIVE=1 and pass "
              "--confirm-spend. Read evals/README.md first.", file=sys.stderr)
        return 2
    if shutil.which("claude") is None:
        print("eval_run: no `claude` on PATH", file=sys.stderr)
        return 2
    task_ids = ([p.name for p in sorted(TASKS_DIR.iterdir()) if (p / "task.json").is_file()]
                if args.tasks == "all" else args.tasks.split(","))
    budget = args.budget_usd or DEFAULT_BUDGET.get(args.model, 10.0)
    run_id = args.run_id or f"{dt.datetime.now(dt.timezone.utc):%Y%m%d-%H%M}-{args.model}"
    print(f"eval_run: run {run_id}, tasks {task_ids}, budget {budget} USD per task", flush=True)
    failures = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.parallel)) as pool:
        futures = {pool.submit(run_task, t, args.model, run_id, budget): t for t in task_ids}
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
