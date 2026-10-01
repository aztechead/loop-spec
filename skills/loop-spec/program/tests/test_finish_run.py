"""Unit tests for controller._finish_run (R5: worktree cleanup skips a protected
or dirty one) and controller._write_terminal_result (R7 residual: a DELIVER
`partially delivered` exit after a converged ITERATE must not classify as
`converged`)."""
import contextlib
import io
import subprocess
import tempfile
import unittest
from pathlib import Path

from loop_spec import controller
from loop_spec.jsonio import read_json
from loop_spec.paths import FeaturePaths
from loop_spec.repo import add_worktree, create_feature_branch, head_sha
from loop_spec.state import StateStore

_RUN_FIELDS = {"id": "run-1", "entry": "cycle", "cycleType": "full", "createdAt": "2026-01-01T00:00:00+00:00"}


def _git(cwd, *args):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True)


def _init_repo(cwd):
    _git(cwd, "init", "-q", "-b", "main")
    _git(cwd, "config", "user.name", "Test")
    _git(cwd, "config", "user.email", "test@example.com")


def _commit(cwd, filename, message):
    Path(cwd, filename).write_text(f"{filename}\n")
    _git(cwd, "add", filename)
    _git(cwd, "commit", "-q", "-m", message)


class FinishRunWorktreeCleanupTests(unittest.TestCase):
    def test_an_open_steps_dirty_worktree_survives_and_is_reported_a_finished_one_is_removed(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            repo_dir = tmp / "repo"
            repo_dir.mkdir()
            _init_repo(repo_dir)
            _commit(repo_dir, "a.txt", "first")
            sha = head_sha(repo_dir)
            create_feature_branch(repo_dir, "feat/open", sha)
            create_feature_branch(repo_dir, "feat/done", sha)

            paths = FeaturePaths(root=tmp / "state" / "feature-a")
            store = StateStore.create(paths, dict(_RUN_FIELDS, slug="feature-a"), "do the thing")
            store.state["phase"]["current"] = "deliver"
            store.state["repos"] = {"repo": {"path": str(repo_dir), "baseSha": sha, "featureBranch": "feat/open",
                                              "defaultBranch": "main", "lastKnownHead": sha}}

            open_wt = paths.root / "worktrees" / "task-open"
            add_worktree(repo_dir, open_wt, branch="feat/open")
            Path(open_wt, "scratch.txt").write_text("uncommitted\n")
            store.state["steps"]["open"] = [{"stepAttemptId": "step-1", "kind": "role", "role": "implementer",
                                              "phase": "execute", "cwd": str(open_wt)}]

            done_wt = paths.root / "worktrees" / "task-done"
            add_worktree(repo_dir, done_wt, branch="feat/done")

            with contextlib.redirect_stdout(io.StringIO()):
                controller._finish_run(store, paths, "converged")

            self.assertTrue(open_wt.is_dir(), "an open step's own worktree must survive a terminal result")
            self.assertFalse(done_wt.exists(), "a finished task's worktree with no open step must be removed")

            record = read_json(paths.result_json)
            self.assertEqual(record["cleanupBacklog"], [{"path": str(open_wt.resolve()), "reason": "open step or quarantined"}])


class WriteTerminalResultPartialDeliveryTests(unittest.TestCase):
    def test_partially_delivered_after_converged_iterate_escalates_naming_the_undelivered_repo(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = FeaturePaths(root=Path(tmp) / "state" / "feature-a")
            store = StateStore.create(paths, dict(_RUN_FIELDS, slug="feature-a"), "do the thing")
            store.state["phase"]["current"] = "deliver"
            store.state["repos"] = {}
            store.state["products"]["execute"] = {"exit": "integrated", "product": {"tasks": [], "heads": {}}}
            store.state["products"]["iterate"] = {"exit": "converged", "product": {"verdict": "met", "gaps": [], "caveats": []}}
            store.state["products"]["deliver"] = {"exit": "partially delivered", "product": {"repos": [
                {"repo": "repo-a", "state": "delivered", "pr": {"number": 1, "url": "u", "headRef": "x"},
                 "deliveredSha": "a" * 40, "caveats": []},
                {"repo": "repo-b", "state": "failed", "pr": None, "deliveredSha": None,
                 "caveats": ["credential check failed"]},
            ]}}
            store.save()

            with contextlib.redirect_stdout(io.StringIO()):
                controller._write_terminal_result(store, paths, "deliver", "partially delivered")

            record = read_json(paths.result_json)
            self.assertEqual(record["result"], "escalated")
            self.assertEqual(record["status"], "escalated")
            self.assertFalse(record["converged"])
            self.assertTrue(record["workDelivered"])
            self.assertTrue(record["partiallyDelivered"])
            self.assertIn("repo-b", record["reason"])
            self.assertNotIn("repo-a", record["reason"])


class EscalationReasonTests(unittest.TestCase):
    def _escalated_store(self, tmp, gaps):
        paths = FeaturePaths(root=Path(tmp) / "state" / "feature-a")
        store = StateStore.create(paths, dict(_RUN_FIELDS, slug="feature-a"), "do the thing")
        store.state["phase"]["current"] = "iterate"
        store.state["repos"] = {}
        store.state["products"]["execute"] = {"exit": "integrated", "product": {"tasks": [], "heads": {}}}
        store.state["products"]["iterate"] = {"exit": "escalated", "product": {"verdict": "unmet", "gaps": gaps, "caveats": []}}
        store.save()
        return store, paths

    def _write(self, store, paths):
        with contextlib.redirect_stdout(io.StringIO()):
            controller._write_terminal_result(store, paths, "iterate", "escalated")
        return read_json(paths.result_json)

    def test_an_iterate_escalation_names_the_open_gaps_as_its_reason(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._escalated_store(tmp, [{"target": "execute", "text": "greet() does not strip the period"}])
            record = self._write(store, paths)
        self.assertEqual(record["result"], "escalated")
        self.assertIn("greet() does not strip the period", record["reason"])

    def test_an_iterate_escalation_with_no_gap_says_so(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._escalated_store(tmp, [])
            record = self._write(store, paths)
        self.assertEqual(record["reason"], "ITERATE judged the requirements unmet with no gap to close")

    def test_a_result_with_no_named_reason_falls_back_to_its_summary(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._escalated_store(tmp, [])
            with contextlib.redirect_stdout(io.StringIO()):
                controller._finish_run(store, paths, "failed")
            record = read_json(paths.result_json)
        self.assertEqual(record["reason"], record["summary"])
        self.assertTrue(record["reason"])


if __name__ == "__main__":
    unittest.main()
