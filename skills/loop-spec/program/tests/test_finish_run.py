"""Unit test for R5: controller._finish_run must not force-remove a worktree
that is an open step's cwd or has uncommitted changes, and must carry any
skipped path into the terminal result's cleanupBacklog field."""
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


if __name__ == "__main__":
    unittest.main()
