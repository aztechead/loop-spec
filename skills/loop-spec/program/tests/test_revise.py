"""Unit tests for loop_spec.revise: gap extraction and the reviser lead step.

No test calls the real `gh` or the network: gaps_from_pr tests patch
`loop_spec.repo.run_gh`; the step tests supply a fake `store.state["adoption"]`
directly rather than adopting a real PR (that adoption is the controller's job).
"""
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from loop_spec.steps import IssueStep, Product
from loop_spec.paths import FeaturePaths
from loop_spec.revise import adopted_range, gaps_from_pr, on_submit, step
from loop_spec.state import StateStore


# simplicity: _git/_init_repo/_commit repeat test_repo.py's, test_baseline.py's, and
# test_execute.py's own copies verbatim; there is no shared test-fixture module in
# this tree yet, and adding one is a cross-file change outside this file's own scope.
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


class GapsFromPrTests(unittest.TestCase):
    def test_collects_top_level_and_inline_comments(self):
        view_json = ('{"comments": [{"author": {"login": "alice"}, "body": "please add a test", '
                     '"url": "https://x/1", "createdAt": "2026-09-24T10:00:00Z"}], '
                     '"reviews": [{"author": {"login": "bob"}, "body": "", "url": "https://x/2"}]}')
        inline_json = ('[{"user": {"login": "carol"}, "body": "off by one here", "path": "a.py", "line": 12, '
                        '"html_url": "https://x/3", "created_at": "2026-09-24T11:00:00Z"}]')

        def fake_run_gh(repo, *args):
            if args[:2] == ("pr", "view"):
                return 0, view_json, ""
            return 0, inline_json, ""

        with patch("loop_spec.revise.repo_module.run_gh", side_effect=fake_run_gh):
            gaps = gaps_from_pr(Path("/fake/repo"), 7)

        self.assertEqual(len(gaps), 2)  # the empty-body review is dropped
        self.assertEqual(gaps[0]["author"], "alice")
        self.assertEqual(gaps[0]["body"], "please add a test")
        self.assertIsNone(gaps[0]["path"])
        self.assertEqual(gaps[1]["author"], "carol")
        self.assertEqual(gaps[1]["path"], "a.py")
        self.assertEqual(gaps[1]["line"], 12)
        # F2: a second revise round tells old comments from new by this.
        self.assertEqual([g["createdAt"] for g in gaps], ["2026-09-24T10:00:00Z", "2026-09-24T11:00:00Z"])

    def test_gh_pr_view_failure_raises(self):
        with patch("loop_spec.revise.repo_module.run_gh", return_value=(1, "", "not found")):
            with self.assertRaises(Exception):
                gaps_from_pr(Path("/fake/repo"), 7)


class StepTests(unittest.TestCase):
    # simplicity: setUp/tearDown are unittest's fixed method names, not a naming
    # choice; house-style.sh's camelCase deviation here is the same pre-existing
    # false positive test_execute.py, test_result.py, and test_postconditions.py hit.
    def setUp(self):
        # simplicity: this temp-dir-then-repo setup is the same accepted family as
        # the module-level _git/_init_repo marker above (test_execute.py has the
        # identical sequence in its own setUp).
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        _init_repo(self.repo)
        _commit(self.repo, "a.py", "init")
        base_sha = subprocess.run(["git", "rev-parse", "HEAD"], cwd=self.repo, capture_output=True, text=True).stdout.strip()
        _commit(self.repo, "b.py", "pr change")
        head_sha = subprocess.run(["git", "rev-parse", "HEAD"], cwd=self.repo, capture_output=True, text=True).stdout.strip()

        self.paths = FeaturePaths(root=self.tmp / "run")
        self.store = StateStore.create(self.paths, {"id": "run-1"}, "address review comments")
        self.store.state["repos"] = {"repo": {"path": str(self.repo), "baseSha": base_sha, "featureBranch": "pr-branch",
                                               "defaultBranch": "main", "lastKnownHead": head_sha}}
        self.store.state["adoption"] = {"repo": "repo", "number": 7, "url": "https://x/pull/7", "headRef": "pr-branch",
                                         "baseBranch": "main", "baseSha": base_sha, "headSha": head_sha}
        self.store.state["revise"] = {"gaps": [{"id": "G-1", "author": "alice", "body": "please add a test",
                                                 "path": None, "line": None, "url": "https://x/1"}], "product": None}
        self.store.save()
        self.ctx = {"attempt": {"id": "attempt-1"}, "inputs": {"digest": "sha256:" + "a" * 64},
                    "paths": {"projectRoot": str(self.repo)}}

    def tearDown(self):
        self._tmp.cleanup()

    def test_adopted_range_reads_the_adoption_record(self):
        base_sha, head_sha = adopted_range(self.store)
        self.assertEqual(base_sha, self.store.state["repos"]["repo"]["baseSha"])
        self.assertEqual(head_sha, self.store.state["adoption"]["headSha"])

    def test_step_issues_one_lead_step_naming_the_gap_and_pr(self):
        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, IssueStep)
        self.assertEqual(action.request["kind"], "lead")
        self.assertEqual(action.request["role"], "reviser")
        self.assertIn("please add a test", action.request["prompt"])
        self.assertIn("https://x/pull/7", action.request["prompt"])
        # LF-37: setUp's fixture never sets revise.prior; the request still builds,
        # and the prompt carries the key with no delivering run found.
        self.assertIn("### prior\nnull", action.request["prompt"])

    def test_step_carries_prior_spec_and_plan_when_found(self):
        # LF-37: controller._find_delivering_run_products fills revise.prior before
        # the step is ever issued; the reviser's own request just passes it through.
        self.store.state["revise"]["prior"] = {
            "slug": "delivered-run",
            "spec": {"criteria": [{"id": "AC-1", "text": "the greeting is friendly"}]},
            "plan": {"tasks": []},
        }
        action = step(self.store, self.paths, self.ctx)
        self.assertIn("### prior", action.request["prompt"])
        self.assertIn("AC-1", action.request["prompt"])

    def test_on_submit_then_step_yields_a_product(self):
        action = step(self.store, self.paths, self.ctx)
        result = {
            "spec": {"goal": "address review comments", "boundaries": [], "decisions": [], "openQuestions": [],
                     "criteria": [{"id": "AC-1", "text": "the test alice asked for exists"}]},
            "plan": {"tasks": [
                {"id": "T-0", "title": "adopted range", "dependsOn": [], "files": ["b.py"], "repo": "repo",
                 "verify": "sh verify.sh", "criteria": ["AC-1"], "featureAdded": None, "mustFlip": False},
            ], "prepare": None, "evidenceExceptions": []},
        }
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "step-1"}, result)

        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, Product)
        self.assertEqual(action.product["plan"]["tasks"][0]["id"], "T-0")


if __name__ == "__main__":
    unittest.main()
