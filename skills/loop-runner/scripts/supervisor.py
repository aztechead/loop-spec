#!/usr/bin/env python3
"""
supervisor.py — plan → fleet. Layer 3 of loop-runner.

The supervisor is a thin dispatcher: it decides WHAT loops run and WHETHER to keep
going; each worker loop decides HOW to do its task. Its own logic stays mechanical —
read the plan, launch workers, read their result.json, apply policy — because the
intelligence lives in the workers, and a supervisor you can predict is a supervisor
you can trust overnight.

What it does per task, in dependency order (parallel where deps allow):
  1. Create an isolated git worktree on branch loop/<id> from the current base HEAD,
     so workers can never collide on files.
  2. Run loop.py there (subprocess, own state dir).
  3. Read result.json and act on halt_reason, not exit codes scraped from stdout:
       complete           → merge loop/<id> into base (dependents see the work)
       no_progress/thrash → retry once with the stall context appended, then escalate
       timeout            → no retry; escalate
       verifier_integrity → halt the whole fleet: nothing downstream is trustworthy
       agent_error        → retry once, then escalate
  4. Skip dependents of failed tasks; keep running independent tasks.

Output: .loop/fleet-result.json with per-task results + a human summary. Exit 0 only
if every task completed and merged.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, FIRST_COMPLETED, wait
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from planlib import validate_plan, topo_order  # noqa: E402

LOOP_PY = Path(__file__).resolve().parent / "loop.py"

RETRYABLE = {"no_progress", "verifier_thrash", "agent_error"}
FLEET_FATAL = {"verifier_integrity"}


def sh(cmd: list[str], cwd: Path, timeout: int = 300) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)


def read_result(res_path: Path, tid: str, log: Path) -> dict:
    """Parse result.json; return an agent_error dict on missing or corrupt file."""
    if not res_path.exists():
        return {"task_id": tid, "status": "halted", "halt_reason": "agent_error",
                "iterations": 0,
                "error": f"no result.json — see {log}"}
    try:
        return json.loads(res_path.read_text())
    except (json.JSONDecodeError, OSError) as e:
        return {"task_id": tid, "status": "halted", "halt_reason": "agent_error",
                "iterations": 0,
                "error": f"corrupt result.json ({e}) — see {log}"}


class Supervisor:
    def __init__(self, plan: dict, repo: Path, args):
        self.plan = plan
        self.repo = repo
        self.args = args
        self.tasks = {t["id"]: t for t in plan["tasks"]}
        self.results: dict[str, dict] = {}
        self.lock = threading.Lock()        # serializes merges
        self.fleet_fatal = False
        self.wt_root = repo.parent / f"{repo.name}-loop-worktrees"

    # ---------------------------------------------------------------- worktrees
    def worktree_for(self, tid: str) -> Path:
        wt = self.wt_root / tid
        branch = f"loop/{tid}"
        if wt.exists():
            return wt
        self.wt_root.mkdir(parents=True, exist_ok=True)
        r = sh(["git", "worktree", "add", str(wt), "-b", branch], self.repo)
        if r.returncode != 0:
            # branch may exist from a previous run — attach to it
            r = sh(["git", "worktree", "add", str(wt), branch], self.repo)
            if r.returncode != 0:
                raise RuntimeError(f"worktree for {tid} failed: {r.stderr.strip()}")
        return wt

    def merge(self, tid: str) -> bool:
        """Merge a completed task's branch into base so dependents build on it.
        A conflict here means two 'independent' tasks weren't — that's a planning
        error a model shouldn't paper over, so it halts the fleet for the human."""
        r = sh(["git", "merge", "--no-ff", "-m", f"loop({tid}): merge autonomous work",
                f"loop/{tid}"], self.repo)
        if r.returncode != 0:
            ra = sh(["git", "merge", "--abort"], self.repo)
            if ra.returncode != 0:
                print(f"⛔ merge --abort also failed (rc={ra.returncode}) — repository left "
                      f"mid-merge; resolve by hand before rerunning")
            print(f"⛔ merge conflict bringing loop/{tid} into base — tasks that the "
                  f"plan called independent touched the same code. Halting fleet; "
                  f"resolve by hand or recompile the plan with a dep between them.")
            self.fleet_fatal = True
            return False
        return True

    # ------------------------------------------------------------------ workers
    def run_task(self, tid: str) -> dict:
        try:
            t = self.tasks[tid]
            wt = self.repo if self.args.no_worktree else self.worktree_for(tid)

            attempt, nudge = 0, ""
            while True:
                attempt += 1

                cfg = {
                    "task": t["prompt"] + nudge,
                    "task_id": tid,
                    "verify": t["verify"],
                    "protected": t.get("protected", []),
                    "max_iterations": int(t.get("max_iterations", 10)),
                    "timeout_s": int(t.get("timeout_s", self.args.task_timeout)),
                    "mode": t.get("mode", "fresh"),
                    "allowed_tools": t.get("allowed_tools", "Read,Edit,Bash"),
                    "claude_bin": self.args.claude_bin,
                    "commit": True,           # durability: each productive tick is a commit
                    "reset": attempt > 1,     # retries start clean but keep the nudge
                }
                if self.args.model:
                    cfg["model"] = self.args.model
                if self.args.fallback_model:
                    cfg["fallback_model"] = self.args.fallback_model
                if self.args.retry_watchdog:
                    cfg["retry_watchdog"] = self.args.retry_watchdog
                cfg_path = wt / ".loop" / f"{tid}.config.json"
                cfg_path.parent.mkdir(parents=True, exist_ok=True)
                cfg_path.write_text(json.dumps(cfg, indent=2))

                print(f"\n▶ {tid} (attempt {attempt}) in {wt}")
                log = wt / ".loop" / f"{tid}.supervisor.log"
                with log.open("a") as lf:
                    subprocess.run([sys.executable, str(LOOP_PY), "--config", str(cfg_path)],
                                   cwd=wt, stdout=lf, stderr=subprocess.STDOUT)

                res_path = wt / ".loop" / tid / "result.json"
                res = read_result(res_path, tid, log)

                reason = res.get("halt_reason", "agent_error")
                if res.get("status") == "complete":
                    return res
                if reason in FLEET_FATAL:
                    self.fleet_fatal = True
                    return res
                if reason in RETRYABLE and attempt <= self.args.retries:
                    tail = ""
                    vf = res.get("verifier", {}).get("last_output_file")
                    if vf and Path(vf).exists():
                        tail = Path(vf).read_text()[-1500:]
                    nudge = (f"\n\n--- Retry context ---\nA previous autonomous attempt "
                             f"halted with '{reason}'. Do not repeat the same approach. "
                             f"Last verifier output:\n{tail}")
                    continue
                return res
        except Exception as e:
            print(f"⛔ {tid}: supervisor error: {e}")
            return {"task_id": tid, "status": "halted", "halt_reason": "supervisor_error",
                    "iterations": 0, "error": str(e)}

    # -------------------------------------------------------------------- fleet
    def run(self) -> int:
        order, _ = topo_order(self.plan["tasks"])
        done_merged: set[str] = set()
        failed: set[str] = set()
        pending = set(order)
        futures = {}

        def ready() -> list[str]:
            return [tid for tid in order if tid in pending
                    and all(d in done_merged for d in self.tasks[tid].get("deps", []))]

        with ThreadPoolExecutor(max_workers=max(1, self.args.parallel)) as ex:
            while pending or futures:
                if not self.fleet_fatal:
                    for tid in ready():
                        if len(futures) >= max(1, self.args.parallel):
                            break
                        pending.discard(tid)
                        futures[ex.submit(self.run_task, tid)] = tid
                if not futures:
                    break  # nothing running and nothing ready → blocked or fatal
                done, _ = wait(futures, return_when=FIRST_COMPLETED)
                for fut in done:
                    tid = futures.pop(fut)
                    res = fut.result()
                    self.results[tid] = res
                    if res.get("status") == "complete":
                        with self.lock:
                            ok = True if self.args.no_worktree else self.merge(tid)
                        if ok:
                            done_merged.add(tid)
                            print(f"✓ {tid} complete and merged "
                                  f"({res.get('iterations')} iters)")
                            if self.args.cleanup_worktrees and not self.args.no_worktree:
                                wt = self.wt_root / tid
                                rr = sh(["git", "worktree", "remove", "--force", str(wt)],
                                        self.repo)
                                if rr.returncode != 0:
                                    print(f"⚠ cleanup: worktree remove {wt} "
                                          f"failed (rc={rr.returncode})")
                                rb = sh(["git", "branch", "-d", f"loop/{tid}"], self.repo)
                                if rb.returncode != 0:
                                    print(f"⚠ cleanup: branch delete loop/{tid} "
                                          f"failed (rc={rb.returncode})")
                        else:
                            failed.add(tid)
                    else:
                        failed.add(tid)
                        print(f"✗ {tid} halted: {res.get('halt_reason')}")
                if self.fleet_fatal:
                    pending.clear()

        blocked = [tid for tid in order
                   if tid not in done_merged and tid not in failed and tid not in self.results]
        for tid in blocked:
            self.results[tid] = {"task_id": tid, "status": "skipped",
                                 "halt_reason": "dep_failed"}

        fleet = {
            "plan": self.args.plan,
            "completed": sorted(done_merged),
            "failed": sorted(failed),
            "skipped": blocked,
            "fleet_fatal": self.fleet_fatal,
            "tasks": self.results,
        }
        out = self.repo / ".loop" / "fleet-result.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(fleet, indent=2))

        print("\n" + "=" * 62)
        print(f"  FLEET {'COMPLETE' if not failed and not blocked else 'INCOMPLETE'}")
        print(f"  completed  : {', '.join(sorted(done_merged)) or '—'}")
        if failed:
            print(f"  failed     : " + ", ".join(
                f"{t}({self.results[t].get('halt_reason')})" for t in sorted(failed)))
        if blocked:
            print(f"  skipped    : {', '.join(blocked)} (upstream failed)")
        print(f"  result     : {out}")
        print("=" * 62)
        return 0 if not failed and not blocked else 1


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--plan", default="plan/tasks.json")
    p.add_argument("--parallel", type=int, default=1,
                   help="Max concurrent independent tasks (merges stay serialized).")
    p.add_argument("--retries", type=int, default=1,
                   help="Retries for stalls/thrash/agent errors. Timeout halts never retry.")
    p.add_argument("--task-timeout", type=int, default=3600)
    p.add_argument("--model", default="")
    p.add_argument("--fallback-model", default="", dest="fallback_model",
                   help="Per-tick fallback model on overload / model-unavailable "
                        "(passed to each loop's `claude -p --fallback-model`).")
    p.add_argument("--retry-watchdog", default="", dest="retry_watchdog",
                   help="CLAUDE_CODE_RETRY_WATCHDOG for each unattended loop tick "
                        "(recommended unattended retry mechanism, CC 2.1.186).")
    p.add_argument("--claude-bin", default="claude")
    p.add_argument("--no-worktree", action="store_true",
                   help="Run tasks in the repo itself (serial use only; no isolation).")
    p.add_argument("--cleanup-worktrees", action="store_true", default=False,
                   help="Remove each task's worktree and branch after a successful merge.")
    p.add_argument("--dry-run", action="store_true",
                   help="Validate the plan and print the schedule without running.")
    args = p.parse_args()

    plan = json.loads(Path(args.plan).read_text())
    errs = validate_plan(plan)
    if errs:
        print("✗ Plan invalid:\n- " + "\n- ".join(errs))
        return 2

    repo = Path.cwd()
    if sh(["git", "rev-parse", "--git-dir"], repo).returncode != 0:
        print("✗ Not a git repo — worktree isolation and merging require git.")
        return 2
    if not args.no_worktree and sh(["git", "status", "--porcelain"], repo).stdout.strip():
        print("✗ Working tree is dirty. Commit or stash first — worktrees branch from "
              "HEAD, so uncommitted work would be invisible to every worker.")
        return 2

    order, _ = topo_order(plan["tasks"])
    if args.dry_run:
        print("Schedule (dependency order):")
        for tid in order:
            t = next(x for x in plan["tasks"] if x["id"] == tid)
            deps = f"  ⇠ {', '.join(t.get('deps', []))}" if t.get("deps") else ""
            print(f"  • {tid:<24} verify: {t['verify'][:60]}{deps}")
        return 0

    return Supervisor(plan, repo, args).run()


if __name__ == "__main__":
    sys.exit(main())
