"""Unit tests for loop_spec.debug: base-run recording and compact_products."""
import subprocess
import tempfile
import unittest
from pathlib import Path

from loop_spec.debug import compact_products, on_submit, record_base_runs, step
from loop_spec.execute import IssueStep, Product
from loop_spec.paths import FeaturePaths
from loop_spec.state import StateStore


# simplicity: _git/_init_repo repeat test_repo.py's, test_baseline.py's, and
# test_execute.py's own copies verbatim; there is no shared test-fixture module
# in this tree yet, and adding one is a cross-file change outside this file's
# own scope.
def _git(cwd, *args):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True)


def _init_repo(cwd):
    _git(cwd, "init", "-q", "-b", "main")
    _git(cwd, "config", "user.name", "Test")
    _git(cwd, "config", "user.email", "test@example.com")


def _new_repo(tmp: Path) -> Path:
    repo = tmp / "repo"
    repo.mkdir()
    _init_repo(repo)
    return repo


def _head(cwd):
    return subprocess.run(["git", "rev-parse", "HEAD"], cwd=cwd, capture_output=True, text=True).stdout.strip()


def _debug_product(reproduction_command, original_command=None):
    return {
        "exit": "reproduced", "inputsDigest": "sha256:" + "a" * 64,
        "boundTo": {"requirements": None, "plan": None},
        "reproduction": {"command": reproduction_command, "failureDigest": "sha256:" + "b" * 64, "reason": None},
        "original": {"command": original_command, "failureDigest": "sha256:" + "c" * 64, "reason": "renamed the script"}
                    if original_command else None,
        "diagnosis": "an off-by-one in the widget counter",
        "spec": {"goal": "fix the bug", "boundaries": [], "criteria": [{"id": "AC-1", "text": "no longer crashes"}],
                  "decisions": [], "openQuestions": []},
        "plan": {"tasks": [{"id": "T-1", "title": "fix it", "dependsOn": [], "files": ["a.py"], "repo": "repo",
                             "verify": "old-command", "criteria": ["AC-1"], "featureAdded": None, "mustFlip": False}],
                  "prepare": None, "evidenceExceptions": []},
    }


class RecordBaseRunsTests(unittest.TestCase):
    # simplicity: setUp/tearDown are unittest's fixed method names, not a
    # naming choice; house-style.sh's camelCase deviation here is the same
    # pre-existing false positive test_execute.py, test_result.py, and
    # test_postconditions.py already hit.
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.repo = _new_repo(self.tmp)
        Path(self.repo, "repro.sh").write_text("#!/bin/sh\nexit 1\n")
        Path(self.repo, "old-repro.sh").write_text("#!/bin/sh\nexit 1\n")
        # LF-23: a real shim (pyenv's, say) is itself a valid, spawnable script that
        # exits 127 to report a missing binary -- subprocess.run never raises for it,
        # unlike a genuinely absent command.
        Path(self.repo, "missing-binary-shim.sh").write_text("#!/bin/sh\nexit 127\n")
        _git(self.repo, "add", "repro.sh", "old-repro.sh", "missing-binary-shim.sh")
        _git(self.repo, "commit", "-q", "-m", "init")
        self.base_sha = _head(self.repo)

        self.paths = FeaturePaths(root=self.tmp / "run")
        self.store = StateStore.create(self.paths, {"id": "run-1"}, "fix the crash")

    def tearDown(self):
        self._tmp.cleanup()

    def test_failing_reproduction_stores_a_nonzero_base_run(self):
        product = _debug_product("sh repro.sh")
        record_base_runs(self.store, self.paths, product, self.repo, self.base_sha)
        self.assertEqual(self.store.state["debug"]["baseRun"]["exitStatus"], 1)
        self.assertNotIn("originalRun", self.store.state["debug"])

    def test_an_original_reproduction_is_also_recorded(self):
        product = _debug_product("sh repro.sh", original_command="sh old-repro.sh")
        record_base_runs(self.store, self.paths, product, self.repo, self.base_sha)
        self.assertEqual(self.store.state["debug"]["originalRun"]["exitStatus"], 1)

    def test_a_reproduction_naming_a_missing_binary_records_command_not_found(self):
        # LF-23: run_command itself never sets errorClass for a shim's own 127 (no
        # FileNotFoundError was raised); record_base_runs backfills it so B1's
        # message can name what actually went wrong.
        product = _debug_product("sh missing-binary-shim.sh")
        record_base_runs(self.store, self.paths, product, self.repo, self.base_sha)
        self.assertEqual(self.store.state["debug"]["baseRun"]["exitStatus"], 127)
        self.assertEqual(self.store.state["debug"]["baseRun"]["errorClass"], "command-not-found")


class CompactProductsTests(unittest.TestCase):
    def test_marks_the_task_must_flip_with_the_reproduction_as_verify(self):
        product = _debug_product("sh repro.sh")
        spec, plan = compact_products(product)
        self.assertEqual(spec["goal"], "fix the bug")
        self.assertEqual(len(plan["tasks"]), 1)
        task = plan["tasks"][0]
        self.assertTrue(task["mustFlip"])
        self.assertEqual(task["verify"], "sh repro.sh")


class StepTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.repo = _new_repo(self.tmp)
        Path(self.repo, "a.py").write_text("x = 1\n")
        _git(self.repo, "add", "a.py")
        _git(self.repo, "commit", "-q", "-m", "init")
        base_sha = _head(self.repo)

        self.paths = FeaturePaths(root=self.tmp / "run")
        self.store = StateStore.create(self.paths, {"id": "run-1"}, "fix the crash")
        self.store.state["repos"] = {"repo": {"path": str(self.repo), "baseSha": base_sha, "featureBranch": "feature",
                                               "defaultBranch": "main", "lastKnownHead": base_sha}}
        self.store.save()
        self.ctx = {"attempt": {"id": "attempt-1"}, "inputs": {"digest": "sha256:" + "a" * 64},
                    "paths": {"projectRoot": str(self.repo)}, "request": {"text": "fix the crash"},
                    "entry": {"mode": "fresh", "payload": None}, "state": {}, "answers": {}, "probes": {}}

    def tearDown(self):
        self._tmp.cleanup()

    def test_step_issues_one_lead_step_then_on_submit_yields_a_product(self):
        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, IssueStep)
        self.assertEqual(action.request["kind"], "lead")
        self.assertEqual(action.request["role"], "debugger")

        result = _debug_product("sh repro.sh")
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "step-1"}, result)

        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, Product)
        self.assertEqual(action.product["exit"], "reproduced")


if __name__ == "__main__":
    unittest.main()
