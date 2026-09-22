"""Unit tests for the post-hardening item 3, Part A: EXECUTE issuing a whole wave
of independent tasks at once (execute.IssueSteps/Wait) and the controller/cli
surfacing every step of that wave as its own LOOP_SPEC_NEXT line.

A separate file, not test_execute.py/test_controller.py (both under concurrent
edit elsewhere): the module-level tests below duplicate test_execute.py's own
git/baseline setup rather than import it, matching this tree's established
"no shared test-fixture module" convention (see test_execute.py's own comment
on _git/_init_repo).
"""
import contextlib
import io
import subprocess
import tempfile
import unittest
from pathlib import Path

from loop_spec import cli
from loop_spec import controller
from loop_spec import postconditions
from loop_spec.baseline import BaselineEntry, run_command
from loop_spec.execute import IssueStep, IssueSteps, Wait, _final_product, on_submit, step
from loop_spec.jsonio import read_json
from loop_spec.paths import FeaturePaths
from loop_spec.state import StateStore


def _git(cwd, *args):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True)


def _init_repo(cwd):
    _git(cwd, "init", "-q", "-b", "main")
    _git(cwd, "config", "user.name", "Test")
    _git(cwd, "config", "user.email", "test@example.com")
    Path(cwd, "verify.sh").write_text("#!/bin/sh\nexit 0\n")
    _git(cwd, "add", "verify.sh")
    _git(cwd, "commit", "-q", "-m", "init")


def _commit(cwd, filename, message):
    Path(cwd, filename).write_text(f"{filename}\n")
    _git(cwd, "add", filename)
    _git(cwd, "commit", "-q", "-m", message)


def _head(cwd):
    return subprocess.run(["git", "rev-parse", "HEAD"], cwd=cwd, capture_output=True, text=True, check=True).stdout.strip()


def _parents(cwd, sha):
    out = subprocess.run(["git", "log", "-1", "--format=%P", sha], cwd=cwd, capture_output=True, text=True, check=True).stdout
    return out.split()


def _porcelain_status(cwd):
    return subprocess.run(["git", "status", "--porcelain"], cwd=cwd, capture_output=True, text=True, check=True).stdout


def _plan_task(task_id, verify="sh verify.sh", depends_on=None):
    return {
        "id": task_id, "title": task_id, "dependsOn": depends_on or [], "files": [f"{task_id}.txt"],
        "repo": "repo", "verify": verify, "criteria": ["AC-1"], "featureAdded": None, "mustFlip": False,
    }


def _pass_review(sha, from_sha, to_sha):
    return {"sha": sha, "reviewedRange": {"from": from_sha, "to": to_sha}, "verdict": "pass",
            "findings": [], "securityDispositions": []}


def _implementer_result(task_id, worktree, filename):
    _commit(worktree, filename, f"implement {task_id}")
    return {"taskId": task_id, "commits": [_head(worktree)], "summary": f"did {task_id}",
            "verifyRun": {"command": "sh verify.sh", "exitStatus": 0}, "issues": []}


class ExecuteStepIssuesWholeWaveTests(unittest.TestCase):
    """T-1 and T-2 independent (both wave 1), T-3 depends on both (wave 2)."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        _init_repo(self.repo)
        self.base_sha = _head(self.repo)
        _git(self.repo, "branch", "feature", self.base_sha)

        self.paths = FeaturePaths(root=self.tmp / "run")
        self.store = StateStore.create(self.paths, {"id": "run-1", "slug": "add-widgets"}, "add widgets")
        self.store.state["repos"] = {
            "repo": {"path": str(self.repo), "baseSha": self.base_sha, "featureBranch": "feature",
                     "defaultBranch": "main", "lastKnownHead": self.base_sha},
        }
        self.store.state["products"]["spec"] = {
            "exit": "approved", "boundTo": {"requirements": None, "plan": None},
            "product": {"criteria": [{"id": "AC-1", "text": "it works"}]},
        }
        self.plan_tasks = [_plan_task("T-1"), _plan_task("T-2"), _plan_task("T-3", depends_on=["T-1", "T-2"])]
        self.store.state["products"]["plan"] = {
            "exit": "ready", "boundTo": {"requirements": None, "plan": None}, "product": {"tasks": self.plan_tasks},
        }
        baseline_run = run_command("sh verify.sh", self.repo, self.base_sha)
        entry = BaselineEntry(command="sh verify.sh", task=None, status="ran", run=baseline_run)
        self.store.state["baseline"] = {"entries": {"sh verify.sh": entry.to_dict()}}
        self.store.state["implementations"]["phases"]["execute"] = "external"
        self.store.save()

        self.ctx = {"attempt": {"id": "attempt-1"}, "inputs": {"digest": "sha256:" + "a" * 64},
                    "paths": {"projectRoot": str(self.repo)}, "probes": {},
                    "entry": {"mode": "fresh", "payload": None}}

    def tearDown(self):
        self._tmp.cleanup()

    def _worktree_and_task(self, request):
        task_id = next(tid for tid, t in self.store.state["execute"]["tasks"].items()
                        if t["worktree"] == request["cwd"])
        return Path(request["cwd"]), task_id

    def test_wave_of_two_independent_tasks_issues_both_at_once(self):
        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, IssueSteps)
        self.assertEqual(len(action.requests), 2)
        self.assertEqual({r["role"] for r in action.requests}, {"implementer"})
        worktrees_and_tasks = [self._worktree_and_task(r) for r in action.requests]
        self.assertEqual({tid for _, tid in worktrees_and_tasks}, {"T-1", "T-2"})
        by_task = {tid: (wt, req) for (wt, tid), req in zip(worktrees_and_tasks, action.requests)}

        # Submit only T-1's implement. T-2's implement step is still open, but
        # requests-to-issue always win over open-steps-to-wait-on (see step()'s
        # own ordering), and T-1 has just become "probing" with a review to
        # build -- so this returns T-1's review as a single IssueStep, not Wait.
        # execute.step() never mints step ids itself (steps.issue() does that,
        # in the real controller path this test bypasses); simulate the program
        # having actually issued both requests, the same way it would for a real
        # IssueSteps wave, so Wait's own open-step lookup (by worktree cwd in
        # store.state["steps"]["open"]) has something real to find below.
        for tid, (wt, req) in by_task.items():
            self.store.state["steps"]["open"].append({"stepAttemptId": f"impl-{tid}-open", "cwd": str(wt)})

        t1_worktree, _ = by_task["T-1"]
        on_submit(self.store, self.paths, by_task["T-1"][1] | {"stepAttemptId": "impl-t1"},
                  _implementer_result("T-1", t1_worktree, "T-1.txt"))
        self.store.state["steps"]["open"] = [s for s in self.store.state["steps"]["open"] if s["stepAttemptId"] != "impl-T-1-open"]
        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, IssueStep)
        self.assertEqual(action.request["role"], "code-reviewer")
        t1_head = _head(t1_worktree)
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "rev-t1"},
                  _pass_review(t1_head, self.base_sha, t1_head))
        self.assertEqual(self.store.state["execute"]["tasks"]["T-1"]["status"], "done")

        # T-1 is now terminal and T-2's implement is still the only open step in
        # the wave: nothing left to actively issue, so this is exactly Wait's
        # case ("non-terminal tasks, nothing pending/probing, a step already
        # open") -- assert the precise shape, not just "not a Pause".
        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, Wait)
        self.assertEqual(action.open, ["impl-T-2-open"])

        t2_worktree, _ = by_task["T-2"]
        on_submit(self.store, self.paths, by_task["T-2"][1] | {"stepAttemptId": "impl-t2"},
                  _implementer_result("T-2", t2_worktree, "T-2.txt"))
        self.store.state["steps"]["open"] = [s for s in self.store.state["steps"]["open"] if s["stepAttemptId"] != "impl-T-2-open"]
        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, IssueStep)
        self.assertEqual(action.request["role"], "code-reviewer")

        # T-2's own worktree forked from the ORIGINAL feature head (both T-1
        # and T-2 were issued from the same head, so they could run in
        # parallel); T-1 has since merged and moved that head. T-2 is reviewed
        # against its OWN fork point (self.base_sha), matching what
        # _review_request actually built, and _on_review_submit now merges a
        # divergent sibling with a real (--no-ff) merge commit instead of
        # assuming the feature head has not moved.
        t2_head = _head(t2_worktree)
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "rev-t2"},
                  _pass_review(t2_head, self.base_sha, t2_head))
        self.assertEqual(self.store.state["execute"]["tasks"]["T-2"]["status"], "done")
        self.assertEqual(self.store.state["execute"]["tasks"]["T-2"]["commits"], [t2_head])

        new_feature_head = self.store.state["execute"]["repos"]["repo"]["head"]
        self.assertEqual(len(_parents(self.repo, new_feature_head)), 2, "T-2 integrated as a merge commit")

        # E4/E5 read the accepted product's "tasks", built the same way
        # _final_product does; T-3 is still pending, which is fine for E4/E5 --
        # they only look at done/adopted tasks.
        execute_state = self.store.state["execute"]
        product = _final_product(self.store, self.ctx, execute_state)
        boundary = postconditions.Boundary(self.store, self.paths, phase="execute", product=product,
                                            exit=product["exit"], project_root=self.repo)
        self.assertIsNone(boundary._e4(), "merge commits must not count as task commits")
        self.assertIsNone(boundary._e5(), "each task's commits must sit inside its own reviewed range")

        # Wave 1 is now fully done; wave 2 (T-3, depending on both) has exactly
        # one task, so it is always a single IssueStep regardless of the wave
        # collection logic above.
        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, IssueStep)
        self.assertEqual(action.request["role"], "implementer")
        _, t3_task_id = self._worktree_and_task(action.request)
        self.assertEqual(t3_task_id, "T-3")


class ConflictDuringIntegrationTests(unittest.TestCase):
    """T-1 and T-2 both edit the same line of the same file: once T-1 has
    integrated, T-2's own --no-ff merge attempt conflicts and execute.py must
    send T-2 back to implement on the new head, leaving no half-finished merge
    behind."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        _init_repo(self.repo)
        Path(self.repo, "shared.txt").write_text("original\n")
        _git(self.repo, "add", "shared.txt")
        _git(self.repo, "commit", "-q", "-m", "add shared.txt")
        self.base_sha = _head(self.repo)
        _git(self.repo, "branch", "feature", self.base_sha)

        self.paths = FeaturePaths(root=self.tmp / "run")
        self.store = StateStore.create(self.paths, {"id": "run-1", "slug": "edit-shared"}, "edit shared.txt")
        self.store.state["repos"] = {
            "repo": {"path": str(self.repo), "baseSha": self.base_sha, "featureBranch": "feature",
                     "defaultBranch": "main", "lastKnownHead": self.base_sha},
        }
        self.store.state["products"]["spec"] = {
            "exit": "approved", "boundTo": {"requirements": None, "plan": None},
            "product": {"criteria": [{"id": "AC-1", "text": "it works"}]},
        }
        t1 = _plan_task("T-1")
        t1["files"] = ["shared.txt"]
        t2 = _plan_task("T-2")
        t2["files"] = ["shared.txt"]
        self.store.state["products"]["plan"] = {
            "exit": "ready", "boundTo": {"requirements": None, "plan": None}, "product": {"tasks": [t1, t2]},
        }
        baseline_run = run_command("sh verify.sh", self.repo, self.base_sha)
        entry = BaselineEntry(command="sh verify.sh", task=None, status="ran", run=baseline_run)
        self.store.state["baseline"] = {"entries": {"sh verify.sh": entry.to_dict()}}
        self.store.state["implementations"]["phases"]["execute"] = "external"
        self.store.save()

        self.ctx = {"attempt": {"id": "attempt-1"}, "inputs": {"digest": "sha256:" + "a" * 64},
                    "paths": {"projectRoot": str(self.repo)}, "probes": {},
                    "entry": {"mode": "fresh", "payload": None}}

    def tearDown(self):
        self._tmp.cleanup()

    def _worktree_and_task(self, request):
        task_id = next(tid for tid, t in self.store.state["execute"]["tasks"].items()
                        if t["worktree"] == request["cwd"])
        return Path(request["cwd"]), task_id

    def _edit_shared_line(self, worktree, text, message):
        Path(worktree, "shared.txt").write_text(text)
        _git(worktree, "add", "shared.txt")
        _git(worktree, "commit", "-q", "-m", message)

    def test_a_conflicting_sibling_goes_back_to_implement_on_the_new_head(self):
        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, IssueSteps)
        by_task = {}
        for request in action.requests:
            wt, tid = self._worktree_and_task(request)
            by_task[tid] = (wt, request)
            self.store.state["steps"]["open"].append({"stepAttemptId": f"impl-{tid}-open", "cwd": str(wt)})

        t1_worktree, t1_request = by_task["T-1"]
        self._edit_shared_line(t1_worktree, "from T-1\n", "T-1: rewrite the shared line")
        t1_result = {"taskId": "T-1", "commits": [_head(t1_worktree)], "summary": "did T-1",
                     "verifyRun": {"command": "sh verify.sh", "exitStatus": 0}, "issues": []}
        on_submit(self.store, self.paths, t1_request | {"stepAttemptId": "impl-t1"}, t1_result)

        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, IssueStep)
        t1_head = _head(t1_worktree)
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "rev-t1"},
                  _pass_review(t1_head, self.base_sha, t1_head))
        self.assertEqual(self.store.state["execute"]["tasks"]["T-1"]["status"], "done")
        feature_head_after_t1 = self.store.state["execute"]["repos"]["repo"]["head"]

        t2_worktree, t2_request = by_task["T-2"]
        self._edit_shared_line(t2_worktree, "from T-2\n", "T-2: rewrite the shared line differently")
        t2_result = {"taskId": "T-2", "commits": [_head(t2_worktree)], "summary": "did T-2",
                     "verifyRun": {"command": "sh verify.sh", "exitStatus": 0}, "issues": []}
        on_submit(self.store, self.paths, t2_request | {"stepAttemptId": "impl-t2"}, t2_result)

        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, IssueStep)
        self.assertEqual(action.request["role"], "code-reviewer")
        t2_head = _head(t2_worktree)
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "rev-t2"},
                  _pass_review(t2_head, self.base_sha, t2_head))

        task_state = self.store.state["execute"]["tasks"]["T-2"]
        self.assertEqual(task_state["status"], "pending")
        self.assertEqual(task_state["retries"], 1)
        self.assertIn("conflicts with the feature head", task_state["reason"])
        self.assertEqual(task_state["forkedFrom"], feature_head_after_t1)
        self.assertTrue(Path(task_state["worktree"]).is_dir())

        # No half-merge left behind: the feature branch is exactly where T-1's
        # merge left it, and its worktree is clean.
        self.assertEqual(self.store.state["execute"]["repos"]["repo"]["head"], feature_head_after_t1)
        feature_worktree = Path(self.store.state["execute"]["repos"]["repo"]["worktree"])
        self.assertEqual(_porcelain_status(feature_worktree), "")


class ControllerAndCliSurfaceWholeWaveTests(unittest.TestCase):
    """continue_run/cli.py surfacing execute.py's IssueSteps as several
    LOOP_SPEC_NEXT lines, driven through the default (not "external") stepped
    dispatch so contract.py's steps.json path is actually exercised."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        _init_repo(self.repo)
        self.base_sha = _head(self.repo)
        _git(self.repo, "branch", "feature", self.base_sha)

        self.paths = FeaturePaths(root=self.tmp / "run")
        self.store = StateStore.create(self.paths, {"id": "run-1", "slug": "add-widgets"}, "add widgets")
        self.store.state["repos"] = {
            "repo": {"path": str(self.repo), "baseSha": self.base_sha, "featureBranch": "feature",
                     "defaultBranch": "main", "lastKnownHead": self.base_sha},
        }
        self.store.state["products"]["spec"] = {
            "exit": "approved", "boundTo": {"requirements": None, "plan": None},
            "product": {"criteria": [{"id": "AC-1", "text": "it works"}]},
        }
        self.store.state["products"]["plan"] = {
            "exit": "ready", "boundTo": {"requirements": None, "plan": None},
            "product": {"tasks": [_plan_task("T-1"), _plan_task("T-2")]},
        }
        baseline_run = run_command("sh verify.sh", self.repo, self.base_sha)
        entry = BaselineEntry(command="sh verify.sh", task=None, status="ran", run=baseline_run)
        self.store.state["baseline"] = {"entries": {"sh verify.sh": entry.to_dict()}}
        self.store.state["implementations"]["phases"]["execute"] = "default"
        self.store.state["phase"]["current"] = "execute"
        self.store.save()

    def tearDown(self):
        self._tmp.cleanup()

    def test_continue_run_yields_two_chained_next_entries(self):
        next_ = controller.continue_run(self.store, self.paths, project_root=self.repo)
        self.assertEqual(next_.kind, "step")
        self.assertEqual(len(next_.also), 1)
        paths = [next_.path, *[n.path for n in next_.also]]
        self.assertEqual(len(set(paths)), 2)
        for p in paths:
            self.assertEqual(read_json(p)["role"], "implementer")

    def test_cli_prints_one_loop_spec_next_line_per_step(self):
        next_ = controller.continue_run(self.store, self.paths, project_root=self.repo)
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            cli._print_next(self.paths, next_)
        lines = [line for line in buffer.getvalue().splitlines() if line.startswith("LOOP_SPEC_NEXT ")]
        self.assertEqual(len(lines), 2)


if __name__ == "__main__":
    unittest.main()
