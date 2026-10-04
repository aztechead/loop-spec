#!/usr/bin/env python3
"""Run the ablation study in docs/loop-spec/ablation-plan.md.

Each run builds a fresh fixture repository with a local bare `origin`, applies the
arm's overlay (config and stub skills, untracked and excluded), and runs `claude -p`
on the task's request: bare for A0, as `/loop-spec:<entry>` with the arm's plugin
directory otherwise. After the process exits it grades the tree with the task's
hidden oracle and records cost, turns and loop-spec's own counts. `--check-oracles`
runs no model: it checks each oracle fails at base, fails on the task's known-wrong
solution, and passes on its reference solution.
"""
import argparse
import json
import logging
import os
import random
import re
import shutil
import subprocess
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

log = logging.getLogger("ablation_eval")
HERE = Path(__file__).resolve().parent / "ablation"
GIT = ["git", "-c", "user.email=eval@loop-spec", "-c", "user.name=eval"]
# The parent session's identity must not leak into the child: attestation keys on
# CLAUDE_CODE_SESSION_ID, and CLAUDECODE makes the child refuse to start.
STRIP_ENV = ("CLAUDECODE", "CLAUDE_CODE_SESSION_ID")


def write_files(root: Path, files: dict) -> None:
    for rel, text in files.items():
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        (root / rel).write_text(text)


def git(cwd: Path, *args: str) -> str:
    return subprocess.run([*GIT, *args], cwd=cwd, check=True, capture_output=True, text=True).stdout


def make_fixture(tmp: Path, task: dict) -> Path:
    repo, origin = tmp / "repo", tmp / "origin.git"
    repo.mkdir()
    write_files(repo, task["fixture"])
    git(repo, "init", "-q", "-b", "main")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "fixture")
    subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(origin)], check=True)
    git(repo, "remote", "add", "origin", str(origin))
    git(repo, "push", "-q", "-u", "origin", "main")
    return repo


def run_oracle(tree: Path, oracle: Path, timeout: int = 120) -> tuple[bool, str]:
    work = Path(tempfile.mkdtemp(prefix="grade-"))
    try:
        shutil.copytree(tree, work / "t", ignore=shutil.ignore_patterns(".git", ".loop-spec", ".claude"))
        shutil.copy(oracle, work / "t" / "_ablation_oracle.py")
        proc = subprocess.run(["python3", "-m", "unittest", "-q", "_ablation_oracle"], cwd=work / "t",
                              capture_output=True, text=True, timeout=timeout)
        return proc.returncode == 0, (proc.stdout + proc.stderr)[-2000:]
    except subprocess.TimeoutExpired:
        return False, "oracle timed out"
    finally:
        shutil.rmtree(work, ignore_errors=True)


def check_oracles(tasks: list) -> bool:
    ok = True
    for task in tasks:
        oracle = HERE / task["oracle"]
        with tempfile.TemporaryDirectory() as tmp:
            tree = Path(tmp)
            write_files(tree, task["fixture"])
            base, _ = run_oracle(tree, oracle)
            write_files(tree, task.get("wrong") or {})
            wrong, _ = run_oracle(tree, oracle) if task.get("wrong") else (False, "")
            write_files(tree, task["fixture"])
            write_files(tree, task["reference"])
            ref, out = run_oracle(tree, oracle)
        good = not base and not wrong and ref
        ok &= good
        log.info("%s: base %s, wrong %s, reference %s -> %s%s", task["id"], "pass" if base else "fail",
                 "pass" if wrong else "fail", "pass" if ref else "fail", "ok" if good else "BAD",
                 "" if ref else "\n" + out)
    return ok


def parse_stream(path: Path) -> dict:
    info = {"init": None, "usage": None, "lastText": ""}
    for line in path.read_text(errors="replace").splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if event.get("type") == "system" and event.get("subtype") == "init":
            info["init"] = {"model": event.get("model"), "version": event.get("claude_code_version"),
                            "permissionMode": event.get("permissionMode"), "sessionId": event.get("session_id"),
                            "plugins": [p.get("name") for p in event.get("plugins", [])]}
        elif event.get("type") == "assistant":
            texts = [c.get("text", "") for c in event.get("message", {}).get("content", []) if c.get("type") == "text"]
            if any(t.strip() for t in texts):
                info["lastText"] = "\n".join(texts)
        elif event.get("type") == "result":
            info["usage"] = {k: event.get(k) for k in ("subtype", "is_error", "total_cost_usd", "duration_ms", "num_turns")}
            if event.get("result"):
                info["lastText"] = event["result"]
    return info


def loop_spec_records(home: Path) -> dict:
    results = sorted(home.glob("*/*/result.json"))
    if not results:
        return {"result": None}
    run_dir = results[-1].parent
    result = json.loads(results[-1].read_text())
    kinds: dict = {}
    events = run_dir / "events.jsonl"
    for line in (events.read_text().splitlines() if events.exists() else []):
        try:
            kind = json.loads(line).get("kind") or json.loads(line).get("type")
        except ValueError:
            continue
        kinds[kind] = kinds.get(kind, 0) + 1
    roles: dict = {}
    for step in run_dir.glob("**/step.json"):
        try:
            role = json.loads(step.read_text()).get("role")
        except ValueError:
            continue
        roles[role] = roles.get(role, 0) + 1
    keep = ("result", "status", "phaseReached", "rewinds", "weakenedAssurance", "noChangeReason", "slug")
    return {"result": {k: result.get(k) for k in keep}, "eventCounts": kinds, "stepsByRole": roles}


def graded_tree(tmp: Path, repo: Path, arm: dict) -> tuple[Path, str]:
    if arm["entry"] is None:
        return repo, "working tree"
    clone = tmp / "graded"
    subprocess.run(["git", "clone", "-q", str(tmp / "origin.git"), str(clone)], check=True)
    branches = [b.strip() for b in git(clone, "branch", "-r", "--sort=-committerdate", "--format=%(refname:short)").splitlines()
                if b.strip() and b.strip() not in ("origin/main", "origin/HEAD", "origin")]
    if not branches:
        return clone, "base (nothing pushed)"
    git(clone, "checkout", "-q", branches[0])
    return clone, branches[0]


def one_run(task: dict, arm: dict, idx: int, args, plugins: dict, note: str) -> dict:
    tag = f"abl-{arm['id']}-{task['id']}-{idx}".lower()
    run_out = Path(args.out) / "runs" / tag
    run_out.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(prefix=tag + "-"))
    repo = make_fixture(tmp, task)
    if arm.get("overlay"):
        shutil.copytree(HERE / arm["overlay"], repo, dirs_exist_ok=True)
        with open(repo / ".git" / "info" / "exclude", "a") as f:
            f.write(".claude/\n.loop-spec/\n")
    env = {k: v for k, v in os.environ.items() if k not in STRIP_ENV}
    env.update(arm.get("env") or {})
    env["LOOP_SPEC_HOME"] = str(tmp / "home")
    cmd = ["claude", "-p"]
    if arm["entry"] is None:
        cmd.append(task["request"])
    else:
        cmd += [f"/loop-spec:{arm['entry']} {task['request']} {note.format(entry=arm['entry'])}",
                "--plugin-dir", plugins[arm["plugin"]]]
    cmd += ["--model", args.model, "--permission-mode", args.permission_mode, "--output-format", "stream-json", "--verbose"]
    stream = run_out / "stream.jsonl"
    start = time.time()
    with open(stream, "w") as out, open(run_out / "stderr.txt", "w") as err:
        try:
            proc = subprocess.run(cmd, cwd=repo, env=env, stdout=out, stderr=err, timeout=args.timeout)
            exit_code = proc.returncode
        except subprocess.TimeoutExpired:
            exit_code = "timeout"
    record = {"tag": tag, "arm": arm["id"], "task": task["id"], "run": idx, "exit": exit_code,
              "wallSeconds": round(time.time() - start, 1)}
    record.update(parse_stream(stream))
    if arm["entry"] is not None:
        record.update(loop_spec_records(tmp / "home"))
        events = sorted((tmp / "home").glob("*/*/events.jsonl"))
        if events:
            shutil.copy(events[-1], run_out / "events.jsonl")
    tree, graded = graded_tree(tmp, repo, arm)
    passed, oracle_out = run_oracle(tree, HERE / task["oracle"])
    unchanged = all((tree / p).read_text() == task["fixture"][p] for p in task.get("unchanged", []))
    flagged = bool(task.get("flag")) and bool(re.search(task["flag"], record["lastText"] or "", re.I))
    record.update({"graded": graded, "oraclePass": passed, "unchanged": unchanged, "premiseFlag": flagged,
                   "pass": passed and unchanged and (flagged or not task.get("flagRequired"))})
    (run_out / "oracle.txt").write_text(oracle_out)
    shutil.rmtree(tmp, ignore_errors=True)
    usage = record.get("usage") or {}
    log.info("%s: pass=%s flag=%s cost=%s turns=%s graded=%s", tag, record["pass"], flagged,
             usage.get("total_cost_usd"), usage.get("num_turns"), graded)
    return record


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--tasks", default=str(HERE / "tasks-pilot.json"))
    ap.add_argument("--arms", default=str(HERE / "arms.json"))
    ap.add_argument("--plugin", action="append", default=[], help="name=path of a plugin worktree an arm names")
    ap.add_argument("--plan", help="JSON list of [arm, task] pairs to run instead of every pair")
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--model", default="sonnet")
    ap.add_argument("--permission-mode", required=False)
    ap.add_argument("--workers", type=int, default=2)
    ap.add_argument("--timeout", type=int, default=3000)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--out", default="ablation-out")
    ap.add_argument("--check-oracles", action="store_true")
    args = ap.parse_args()
    tasks = {t["id"]: t for t in json.loads(Path(args.tasks).read_text())}
    if args.check_oracles:
        raise SystemExit(0 if check_oracles(list(tasks.values())) else 1)
    if not args.permission_mode:
        ap.error("--permission-mode is required for a live run")
    spec = json.loads(Path(args.arms).read_text())
    arms = {a["id"]: a for a in spec["arms"]}
    plugins = dict(p.split("=", 1) for p in args.plugin)
    pairs = json.loads(Path(args.plan).read_text()) if args.plan else [[a, t] for a in arms for t in tasks]
    jobs = [(tasks[t], arms[a], i) for a, t in pairs for i in range(1, args.runs + 1)]
    random.Random(args.seed).shuffle(jobs)
    Path(args.out).mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(args.workers) as pool, open(Path(args.out) / "runs.jsonl", "a") as sink:
        for record in pool.map(lambda j: one_run(*j, args, plugins, spec["operatorNote"]), jobs):
            sink.write(json.dumps(record) + "\n")
            sink.flush()


if __name__ == "__main__":
    main()
