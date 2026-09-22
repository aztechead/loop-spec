"""Unit tests for loop_spec.verify: range selection, product assembly, exit choice."""
import subprocess
import tempfile
import unittest
from pathlib import Path

from loop_spec.execute import IssueStep, Product
from loop_spec.paths import FeaturePaths
from loop_spec.state import StateStore
from loop_spec.verify import on_submit, step


# simplicity: _git/_init_repo repeat test_repo.py's, test_baseline.py's, and
# test_execute.py's own copies verbatim; there is no shared test-fixture module
# in this tree yet, and adding one is a cross-file change outside this file's
# own scope.
def _git(cwd, *args):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True)


def _head(cwd):
    return subprocess.run(["git", "rev-parse", "HEAD"], cwd=cwd, capture_output=True, text=True, check=True).stdout.strip()


def _verdict(criterion, verdict, remediation=None):
    return {"criterion": criterion, "verdict": verdict,
            "evidence": {"command": "sh verify.sh", "sha": "deadbeef", "exitStatus": 0 if verdict == "pass" else 1,
                          "failureIdentities": [], "outputDigest": "sha256:" + "a" * 64} if verdict != "blocked" else None,
            "cause": None if verdict == "pass" else "it broke", "remediation": remediation}


def _verifier_result(verdicts, plan_gap=False, intent_gap=False):
    return {"verdicts": verdicts, "planGap": plan_gap, "intentGap": intent_gap}


class VerifyTests(unittest.TestCase):
    # simplicity: setUp/tearDown are unittest's fixed method names, not a
    # naming choice; house-style.sh's camelCase deviation here is the same
    # pre-existing false positive test_execute.py, test_result.py, and
    # test_postconditions.py already hit.
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        _git(self.repo, "init", "-q", "-b", "main")
        _git(self.repo, "config", "user.name", "Test")
        _git(self.repo, "config", "user.email", "test@example.com")
        Path(self.repo, "verify.sh").write_text("#!/bin/sh\nexit 0\n")
        _git(self.repo, "add", "verify.sh")
        _git(self.repo, "commit", "-q", "-m", "init")
        self.base_sha = _head(self.repo)
        Path(self.repo, "feature.py").write_text("x = 1\n")
        _git(self.repo, "add", "feature.py")
        _git(self.repo, "commit", "-q", "-m", "feature")
        self.head_sha = _head(self.repo)

        self.paths = FeaturePaths(root=self.tmp / "run")
        self.store = StateStore.create(self.paths, {"id": "run-1"}, "add a widget")
        self.store.state["repos"] = {"repo": {"path": str(self.repo), "baseSha": self.base_sha,
                                               "featureBranch": "feature", "defaultBranch": "main",
                                               "lastKnownHead": self.head_sha}}
        self.store.state["products"]["spec"] = {"exit": "approved", "product": {"criteria": [{"id": "AC-1", "text": "it works"}]}}
        self.store.state["products"]["plan"] = {"exit": "ready", "product": {
            "tasks": [{"id": "T-1", "title": "T-1", "dependsOn": [], "files": ["feature.py"], "repo": "repo",
                       "verify": "sh verify.sh", "criteria": ["AC-1"], "featureAdded": None, "mustFlip": False}],
            "prepare": None, "evidenceExceptions": [],
        }}
        self.store.state["products"]["execute"] = {"exit": "integrated", "product": {"heads": {"repo": self.head_sha}}}
        self.store.save()

        self.ctx = {"attempt": {"id": "attempt-1"}, "inputs": {"digest": "sha256:" + "a" * 64},
                    "paths": {"projectRoot": str(self.repo)}, "entry": {"mode": "fresh", "payload": None},
                    "probes": {}}

    def tearDown(self):
        self._tmp.cleanup()

    def _run_pass(self, verifier_result, reviewer_findings=None):
        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, IssueStep)
        self.assertEqual(action.request["role"], "verifier")
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "v-step"}, verifier_result)

        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, IssueStep)
        self.assertEqual(action.request["role"], "code-reviewer")
        range_ = self.store.state["verify"]["range"]
        reviewer_result = {"sha": self.head_sha, "reviewedRange": {"from": range_["from"], "to": range_["to"]},
                            "verdict": "pass", "findings": reviewer_findings or [], "securityDispositions": []}
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "r-step"}, reviewer_result)

        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, Product)
        return action.product

    def test_first_pass_reviews_the_full_diff(self):
        product = self._run_pass(_verifier_result([_verdict("AC-1", "pass")]))
        self.assertTrue(product["reviewedRange"]["full"])
        self.assertEqual(product["reviewedRange"]["from"], self.base_sha)
        self.assertEqual(product["reviewedRange"]["to"], self.head_sha)

    def test_delta_pass_reviews_from_the_last_reviewed_to(self):
        self.store.state["ledger"]["reviewedRanges"] = [{"id": "range-1", "from": self.base_sha, "to": self.base_sha, "full": True}]
        self.store.save()
        product = self._run_pass(_verifier_result([_verdict("AC-1", "pass")]))
        self.assertFalse(product["reviewedRange"]["full"])
        self.assertEqual(product["reviewedRange"]["from"], self.base_sha)

    def test_final_pass_forces_full_range(self):
        self.store.state["ledger"]["reviewedRanges"] = [{"id": "range-1", "from": self.base_sha, "to": self.base_sha, "full": True}]
        self.store.save()
        self.ctx["entry"]["payload"] = {"finalPass": True}
        product = self._run_pass(_verifier_result([_verdict("AC-1", "pass")]))
        self.assertTrue(product["reviewedRange"]["full"])

    def test_all_pass_exits_passed(self):
        product = self._run_pass(_verifier_result([_verdict("AC-1", "pass")]))
        self.assertEqual(product["exit"], "passed")

    def test_a_fail_exits_implementation_gap_with_a_remediation_task(self):
        product = self._run_pass(_verifier_result([_verdict("AC-1", "fail", {"files": ["feature.py"]})]))
        self.assertEqual(product["exit"], "implementation gap")
        self.assertEqual(len(product["remediationTasks"]), 1)
        task = product["remediationTasks"][0]
        self.assertEqual(task["files"], ["feature.py"])
        self.assertEqual(task["verify"], "sh verify.sh")
        self.assertEqual(task["criteria"], ["AC-1"])

    def test_a_blocked_verdict_exits_blocked(self):
        product = self._run_pass(_verifier_result([_verdict("AC-1", "blocked")]))
        self.assertEqual(product["exit"], "blocked")

    def test_plan_gap_flag_overrides_a_fail(self):
        product = self._run_pass(_verifier_result([_verdict("AC-1", "fail")], plan_gap=True))
        self.assertEqual(product["exit"], "plan gap")

    def test_reviewer_findings_get_fresh_ids(self):
        finding = {"id": "whatever-the-reviewer-said", "location": "feature.py:1", "cause": "x",
                   "severity": "Minor", "disposition": "open", "reason": None, "supersedes": None}
        product = self._run_pass(_verifier_result([_verdict("AC-1", "pass")]), reviewer_findings=[finding])
        self.assertEqual(len(product["findings"]), 1)
        self.assertNotEqual(product["findings"][0]["id"], "whatever-the-reviewer-said")
        self.assertTrue(product["findings"][0]["id"].startswith("finding-"))


if __name__ == "__main__":
    unittest.main()
