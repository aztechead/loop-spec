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
import os
import shlex
import signal
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, FIRST_COMPLETED, wait
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from planlib import validate_plan, topo_order  # noqa: E402

LOOP_PY = Path(__file__).resolve().parent / "loop.py"
INTEGRATE_TASK = Path(__file__).resolve().parents[3] / "lib" / "integrate-task.sh"
PREPARE_ENVIRONMENT = Path(__file__).resolve().parents[3] / "lib" / "prepare-environment.sh"
FEATURE_VALIDATION = Path(__file__).resolve().parents[3] / "lib" / "feature-validation.sh"

RETRYABLE = {"no_progress", "verifier_thrash", "agent_error"}
FLEET_FATAL = {"verifier_integrity"}
ACTIVE_PROCESS_GROUPS: set[int] = set()
ACTIVE_PROCESS_GROUPS_LOCK = threading.Lock()
CANCEL_EVENT = threading.Event()


class FleetCancelled(RuntimeError):
    pass


def sh(cmd: list[str], cwd: Path, timeout: int = 300) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)


def run_bounded_process(cmd: list[str], cwd: Path, log: Path, timeout: int) -> int:
    """Run one worker in its own process group and kill the whole group on timeout."""
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("a") as lf:
        with ACTIVE_PROCESS_GROUPS_LOCK:
            if CANCEL_EVENT.is_set():
                raise FleetCancelled("fleet cancelled before worker startup")
            proc = subprocess.Popen(cmd, cwd=cwd, stdout=lf, stderr=subprocess.STDOUT,
                                    start_new_session=True)
            pgid = proc.pid  # start_new_session makes the child its process-group leader
            ACTIVE_PROCESS_GROUPS.add(pgid)
        try:
            try:
                return proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(pgid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(pgid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    proc.wait()
                raise
        finally:
            with ACTIVE_PROCESS_GROUPS_LOCK:
                ACTIVE_PROCESS_GROUPS.discard(pgid)


def terminate_active_workers() -> None:
    """Terminate every worker process group currently owned by this supervisor."""
    CANCEL_EVENT.set()
    with ACTIVE_PROCESS_GROUPS_LOCK:
        groups = list(ACTIVE_PROCESS_GROUPS)
    for pgid in groups:
        try:
            os.killpg(pgid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    if groups:
        time.sleep(0.2)
    for pgid in groups:
        try:
            os.killpg(pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def handle_termination(signum, _frame) -> None:
    terminate_active_workers()
    raise SystemExit(128 + signum)


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
        CANCEL_EVENT.clear()
        self.plan = plan
        self.repo = repo
        self.args = args
        self.tasks = {t["id"]: t for t in plan["tasks"]}
        self.results: dict[str, dict] = {}
        self.done_merged: set[str] = set()
        self.failed: set[str] = set()
        self.lock = threading.Lock()        # serializes merges
        self.fleet_fatal = False
        self.wt_root = repo.parent / f"{repo.name}-loop-worktrees"

    def write_fleet(self, status: str, completed=None, failed=None, skipped=None) -> Path:
        """Persist fleet state before dispatch and at terminal completion."""
        completed = sorted(completed or [])
        failed = sorted(failed or [])
        skipped = list(skipped or [])
        costs = [r.get("total_cost_usd") for r in self.results.values()
                 if isinstance(r.get("total_cost_usd"), (int, float))]
        fleet = {
            "status": status,
            "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "plan": self.args.plan,
            "completed": completed,
            "failed": failed,
            "skipped": skipped,
            "fleet_fatal": self.fleet_fatal,
            "total_cost_usd": round(sum(costs), 6) if costs else None,
            "tasks": self.results,
        }
        out = self.repo / ".loop" / "fleet-result.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        tmp = out.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(fleet, indent=2))
        tmp.replace(out)
        return out

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
        feature_branch = sh(["git", "symbolic-ref", "--quiet", "--short", "HEAD"],
                            self.repo).stdout.strip()
        wt = self.wt_root / tid
        verify_command = self.tasks[tid]["verify"]
        feature_dir = getattr(self.args, "feature_dir", "")
        if feature_dir:
            candidate_feature_dir = wt / feature_dir
            verify_command += (f" && bash {shlex.quote(str(FEATURE_VALIDATION))} compare "
                               f"{shlex.quote(str(candidate_feature_dir))}")
        preflight = sh([
            "bash", str(INTEGRATE_TASK),
            "--feature-root", str(self.repo),
            "--feature-branch", feature_branch,
            "--task-worktree", str(wt),
            "--task-branch", f"loop/{tid}",
            "--verify", verify_command,
            "--preflight-only",
        ], self.repo)
        try:
            integration = json.loads(preflight.stdout)
        except json.JSONDecodeError:
            integration = {"reason": "invalid-helper-result", "detail": "non-JSON output"}
        candidate = integration.get("candidate")
        feature_before = integration.get("featureBefore")
        candidate_valid = (isinstance(candidate, str) and len(candidate) in (40, 64)
                           and all(c in "0123456789abcdef" for c in candidate))
        feature_before_valid = (isinstance(feature_before, str)
                                and len(feature_before) in (40, 64)
                                and all(c in "0123456789abcdef" for c in feature_before))
        if (preflight.returncode != 0 or integration.get("status") != "success"
                or not candidate_valid or not feature_before_valid):
            reason = integration.get("reason", "integration-preflight-failed")
            detail = integration.get("detail", "unknown")
            if not candidate_valid or not feature_before_valid:
                reason, detail = "invalid-helper-result", "missing immutable candidate contract"
            print(f"⛔ integration preflight for loop/{tid} failed: {reason}: {detail}")
            if preflight.stderr.strip():
                print(preflight.stderr.strip())
            if reason == "rebase-conflict":
                self.fleet_fatal = True
            return False

        current_feature = sh(["git", "rev-parse", "HEAD"], self.repo)
        if (current_feature.returncode != 0
                or current_feature.stdout.strip() != feature_before):
            print(f"⛔ feature branch moved after integration preflight for loop/{tid}")
            return False

        # Preserve loop-fleet's merge-commit history contract after the shared
        # helper has rebased and verified the exact prospective candidate.
        r = sh(["git", "merge", "--no-ff", "-m", f"loop({tid}): merge autonomous work",
                candidate], self.repo)
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

            if CANCEL_EVENT.is_set():
                return {"task_id": tid, "status": "halted",
                        "halt_reason": "fleet_aborted", "iterations": 0,
                        "error": "fleet cancelled before environment preparation"}

            print(f"TASK_START id={tid} worktree={wt}", flush=True)

            prepare_args = ["bash", str(PREPARE_ENVIRONMENT), "run", "--root", str(wt)]
            prepare_command = getattr(self.args, "prepare_command", None)
            if prepare_command is not None:
                prepare_args.extend(["--command", prepare_command])
            prepare_log = wt / ".loop" / f"{tid}.prepare.log"
            try:
                prepare_rc = run_bounded_process(prepare_args, wt, prepare_log, 300)
            except FleetCancelled as exc:
                return {"task_id": tid, "status": "halted",
                        "halt_reason": "fleet_aborted", "iterations": 0,
                        "error": str(exc)}
            except subprocess.TimeoutExpired:
                return {"task_id": tid, "status": "halted",
                        "halt_reason": "environment_error", "iterations": 0,
                        "error": f"environment preparation timed out; see {prepare_log}"}
            if CANCEL_EVENT.is_set():
                return {"task_id": tid, "status": "halted",
                        "halt_reason": "fleet_aborted", "iterations": 0,
                        "error": "fleet cancelled during environment preparation"}
            if prepare_rc != 0:
                detail = prepare_log.read_text(errors="replace")[-2000:] \
                    if prepare_log.exists() else "environment preparation failed"
                return {"task_id": tid, "status": "halted", "halt_reason": "environment_error",
                        "iterations": 0, "error": detail.strip()}

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
                    "agent_cli": self.args.agent_cli,
                    "commit": True,           # durability: each productive tick is a commit
                    "reset": attempt > 1,     # retries start clean but keep the nudge
                }
                if self.args.model:
                    cfg["model"] = self.args.model
                if self.args.fallback_model:
                    cfg["fallback_model"] = self.args.fallback_model
                if self.args.retry_watchdog:
                    cfg["retry_watchdog"] = self.args.retry_watchdog
                if self.args.max_budget_usd > 0:
                    cfg["max_budget_usd"] = self.args.max_budget_usd
                cfg_path = wt / ".loop" / f"{tid}.config.json"
                cfg_path.parent.mkdir(parents=True, exist_ok=True)
                cfg_path.write_text(json.dumps(cfg, indent=2))

                print(f"\nTASK_ATTEMPT id={tid} attempt={attempt} worktree={wt}", flush=True)
                log = wt / ".loop" / f"{tid}.supervisor.log"
                try:
                    run_bounded_process(
                        [sys.executable, str(LOOP_PY), "--config", str(cfg_path)],
                        wt, log, max(1, cfg["timeout_s"] + 30))
                except subprocess.TimeoutExpired:
                    message = (f"loop-fleet supervisor made no progress within the task "
                               f"timeout plus shutdown grace; see {log}")
                    print(f"TASK_TIMEOUT id={tid} error={message}", flush=True)
                    return {"task_id": tid, "status": "halted",
                            "halt_reason": "supervisor_timeout", "iterations": 0,
                            "error": message}
                except FleetCancelled as exc:
                    return {"task_id": tid, "status": "halted",
                            "halt_reason": "fleet_aborted", "iterations": 0,
                            "error": str(exc)}

                res_path = wt / ".loop" / tid / "result.json"
                res = read_result(res_path, tid, log)

                reason = res.get("halt_reason", "agent_error")
                if res.get("status") == "complete":
                    return res
                if reason in FLEET_FATAL:
                    self.fleet_fatal = True
                    CANCEL_EVENT.set()
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
            print(f"TASK_ERROR id={tid} error={e}", flush=True)
            return {"task_id": tid, "status": "halted", "halt_reason": "supervisor_error",
                    "iterations": 0, "error": str(e)}

    # -------------------------------------------------------------------- fleet
    def run(self) -> int:
        try:
            return self._run()
        except BaseException as exc:
            self.fleet_fatal = True
            terminate_active_workers()
            self.results["__supervisor__"] = {
                "task_id": "__supervisor__", "status": "halted",
                "halt_reason": "supervisor_error", "iterations": 0,
                "error": str(exc) or exc.__class__.__name__,
            }
            self.write_fleet("incomplete", self.done_merged,
                             self.failed | {"__supervisor__"})
            print(f"FLEET_ERROR error={exc or exc.__class__.__name__}", flush=True)
            raise

    def _run(self) -> int:
        order, _ = topo_order(self.plan["tasks"])
        done_merged = self.done_merged
        failed = self.failed
        pending = set(order)
        futures = {}

        out = self.write_fleet("running")
        print(f"FLEET_START tasks={len(order)} parallel={max(1, self.args.parallel)} "
              f"result={out}", flush=True)

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
                        if self.fleet_fatal:
                            res = dict(res)
                            res.update(status="halted", halt_reason="fleet_aborted",
                                       error="fleet halted before integration")
                            self.results[tid] = res
                            failed.add(tid)
                            continue
                        try:
                            with self.lock:
                                ok = True if self.args.no_worktree else self.merge(tid)
                        except Exception as exc:
                            ok = False
                            res = dict(res)
                            res.update(status="halted", halt_reason="supervisor_error",
                                       error=str(exc))
                            self.results[tid] = res
                            print(f"TASK_ERROR id={tid} integration={exc}", flush=True)
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
                            if res.get("status") == "complete":
                                res = dict(res)
                                res.update(status="halted", halt_reason="integration_error",
                                           error="exact-candidate integration preflight failed")
                                self.results[tid] = res
                            failed.add(tid)
                    else:
                        failed.add(tid)
                        print(f"✗ {tid} halted: {res.get('halt_reason')}")
                if self.fleet_fatal:
                    pending.clear()
                    terminate_active_workers()
                self.write_fleet("running", done_merged, failed)

        blocked = [tid for tid in order
                   if tid not in done_merged and tid not in failed and tid not in self.results]
        for tid in blocked:
            self.results[tid] = {"task_id": tid, "status": "skipped",
                                 "halt_reason": "dep_failed"}

        status = "complete" if not failed and not blocked else "incomplete"
        out = self.write_fleet(status, done_merged, failed, blocked)

        print("\n" + "=" * 62)
        print(f"  FLEET {'COMPLETE' if not failed and not blocked else 'INCOMPLETE'}")
        print(f"  completed  : {', '.join(sorted(done_merged)) or '—'}")
        if failed:
            print(f"  failed     : " + ", ".join(
                f"{t}({self.results[t].get('halt_reason')})" for t in sorted(failed)))
        if blocked:
            print(f"  skipped    : {', '.join(blocked)} (upstream failed)")
        print(f"  result     : {out}")
        print("=" * 62, flush=True)
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
    p.add_argument("--max-budget-usd", type=float, default=0.0, dest="max_budget_usd",
                   help="PER-TASK cumulative USD cap handed to each loop; a task "
                        "halts budget_exhausted at the cap. Fleet-wide worst case "
                        "is this times the number of tasks (0 = unbounded).")
    p.add_argument("--claude-bin", default="claude")
    p.add_argument("--agent-cli", choices=["claude", "pi", "opencode"], default="",
                   dest="agent_cli",
                   help="Headless protocol for every loop tick: claude -p JSON vs "
                        "pi --mode json vs opencode run --format json events "
                         "(default: auto from the binary name).")
    p.add_argument("--feature-dir", default="",
                   help="Feature-state path relative to the repository; enables exact-candidate baseline comparison.")
    p.add_argument("--prepare-command", default=None,
                   help="Persisted feature preparation command (empty explicitly disables detection).")
    p.add_argument("--no-worktree", action="store_true",
                   help="Run tasks in the repo itself (serial use only; no isolation).")
    p.add_argument("--cleanup-worktrees", action="store_true", default=False,
                   help="Remove each task's worktree and branch after a successful merge.")
    p.add_argument("--dry-run", action="store_true",
                   help="Validate the plan and print the schedule without running.")
    args = p.parse_args()

    signal.signal(signal.SIGTERM, handle_termination)
    signal.signal(signal.SIGINT, handle_termination)

    if not args.dry_run:
        stale_result = Path.cwd() / ".loop" / "fleet-result.json"
        try:
            stale_result.unlink()
        except FileNotFoundError:
            pass
        except OSError as exc:
            print(f"Cannot clear stale fleet result: {exc}")
            return 2

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
