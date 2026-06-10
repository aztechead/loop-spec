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
  2. Run loop.py there (subprocess, own state dir, own budget — clamped to whatever
     remains of the FLEET budget, so N workers can't multiply your ceiling away).
  3. Read result.json and act on halt_reason, not exit codes scraped from stdout:
       complete           → merge loop/<id> into base (dependents see the work)
       no_progress/thrash → retry once with the stall context appended, then escalate
       budget/timeout     → no retry (retrying a budget halt re-spends it); escalate
       verifier_integrity → halt the whole fleet: nothing downstream is trustworthy
       agent_error        → retry once, then escalate
  4. Skip dependents of failed tasks; keep running independent tasks.
  5. Stop launching anything once the fleet budget is spent.

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


class Supervisor:
    def __init__(self, plan: dict, repo: Path, args):
        self.plan = plan
        self.repo = repo
        self.args = args
        self.tasks = {t["id"]: t for t in plan["tasks"]}
        self.results: dict[str, dict] = {}
        self.fleet_budget = float(args.fleet_budget or plan.get("fleet_budget_usd", 20.0))
        self.spent = 0.0
        self.lock = threading.Lock()        # serializes merges + budget accounting
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
            sh(["git", "merge", "--abort"], self.repo)
            print(f"⛔ merge conflict bringing loop/{tid} into base — tasks that the "
                  f"plan called independent touched the same code. Halting fleet; "
                  f"resolve by hand or recompile the plan with a dep between them.")
            self.fleet_fatal = True
            return False
        return True

    # ------------------------------------------------------------------ workers
    def run_task(self, tid: str) -> dict:
        t = self.tasks[tid]
        wt = self.repo if self.args.no_worktree else self.worktree_for(tid)

        attempt, nudge = 0, ""
        while True:
            attempt += 1
            with self.lock:
                remaining = self.fleet_budget - self.spent
            if remaining <= 0:
                return {"task_id": tid, "status": "halted", "halt_reason": "fleet_budget",
                        "cost_usd": 0.0, "iterations": 0}
            budget = min(float(t.get("budget_usd", 4.0)), remaining)

            cfg = {
                "task": t["prompt"] + nudge,
                "task_id": tid,
                "verify": t["verify"],
                "protected": t.get("protected", []),
                "budget_usd": budget,
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
            cfg_path = wt / ".loop" / f"{tid}.config.json"
            cfg_path.parent.mkdir(parents=True, exist_ok=True)
            cfg_path.write_text(json.dumps(cfg, indent=2))

            print(f"\n▶ {tid} (attempt {attempt}, budget ${budget:.2f}, "
                  f"fleet ${self.spent:.2f}/${self.fleet_budget:.2f}) in {wt}")
            log = wt / ".loop" / f"{tid}.supervisor.log"
            with log.open("a") as lf:
                subprocess.run([sys.executable, str(LOOP_PY), "--config", str(cfg_path)],
                               cwd=wt, stdout=lf, stderr=subprocess.STDOUT)

            res_path = wt / ".loop" / tid / "result.json"
            if not res_path.exists():
                res = {"task_id": tid, "status": "halted", "halt_reason": "agent_error",
                       "cost_usd": 0.0, "iterations": 0,
                       "error": f"no result.json — see {log}"}
            else:
                res = json.loads(res_path.read_text())

            with self.lock:
                self.spent += float(res.get("cost_usd", 0.0))

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
                                  f"(${res.get('cost_usd', 0):.2f}, "
                                  f"{res.get('iterations')} iters)")
                        else:
                            failed.add(tid)
                    else:
                        failed.add(tid)
                        print(f"✗ {tid} halted: {res.get('halt_reason')} "
                              f"(${res.get('cost_usd', 0):.2f})")
                if self.fleet_fatal:
                    pending.clear()

        blocked = [tid for tid in order
                   if tid not in done_merged and tid not in failed and tid not in self.results]
        for tid in blocked:
            self.results[tid] = {"task_id": tid, "status": "skipped",
                                 "halt_reason": "dep_failed"}

        fleet = {
            "plan": self.args.plan,
            "fleet_budget_usd": self.fleet_budget,
            "spent_usd": round(self.spent, 4),
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
        print(f"  spent      : ${self.spent:.2f} of ${self.fleet_budget:.2f}")
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
    p.add_argument("--fleet-budget", type=float, default=None,
                   help="Override the plan's fleet ceiling.")
    p.add_argument("--parallel", type=int, default=1,
                   help="Max concurrent independent tasks (merges stay serialized).")
    p.add_argument("--retries", type=int, default=1,
                   help="Retries for stalls/thrash/agent errors. Budget halts never retry.")
    p.add_argument("--task-timeout", type=int, default=3600)
    p.add_argument("--model", default="")
    p.add_argument("--claude-bin", default="claude")
    p.add_argument("--no-worktree", action="store_true",
                   help="Run tasks in the repo itself (serial use only; no isolation).")
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
            print(f"  • {tid:<24} ${t.get('budget_usd', 0):.2f}  "
                  f"verify: {t['verify'][:60]}{deps}")
        print(f"Fleet budget: ${args.fleet_budget or plan.get('fleet_budget_usd')}")
        return 0

    return Supervisor(plan, repo, args).run()


if __name__ == "__main__":
    sys.exit(main())
