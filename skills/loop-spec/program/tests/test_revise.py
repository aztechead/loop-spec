"""Unit tests for loop_spec.revise: gap extraction and the reviser lead step.

No test calls the real `gh` or the network: gaps_from_pr tests patch
`loop_spec.repo.run_gh`; the step tests supply a fake `store.state["adoption"]`
directly rather than adopting a real PR (that adoption is the controller's job).
"""
import json
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
    @staticmethod
    def _gh(issue=(), reviews=(), inline=(), threads=None, checks=None, calls=None):
        """A fake run_gh answering each REST endpoint gaps_from_pr reads with one page."""
        def fake_run_gh(repo, *args):
            if calls is not None:
                calls.append(args)
            if args[:2] == ("api", "graphql"):
                return (0, json.dumps(threads), "") if threads is not None else (1, "", "boom")
            if args[:2] == ("pr", "checks"):
                return (0, json.dumps(checks), "") if checks is not None else (1, "", "none")
            endpoint = args[-1]
            pages = inline if endpoint.endswith("pulls/7/comments") else reviews if endpoint.endswith("reviews") else issue
            return 0, json.dumps(pages if pages and isinstance(pages[0], list) else [list(pages)]), ""
        return fake_run_gh

    def test_collects_top_level_and_inline_comments(self):
        issue = [{"user": {"login": "alice"}, "body": "please add a test", "html_url": "https://x/1",
                  "created_at": "2026-09-24T10:00:00Z"}]
        reviews = [{"user": {"login": "bob"}, "body": "", "html_url": "https://x/2"}]
        inline = [{"user": {"login": "carol"}, "body": "off by one here", "path": "a.py", "line": 12,
                   "html_url": "https://x/3", "created_at": "2026-09-24T11:00:00Z"}]

        with patch("loop_spec.revise.repo_module.run_gh", side_effect=self._gh(issue, reviews, inline)):
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

    def test_inline_comments_from_every_page(self):
        # gh api --paginate --slurp returns one array per page; the REST default page is 30.
        pages = [[{"user": {"login": "u"}, "body": f"c{i}", "path": "a.py", "line": i} for i in range(30)],
                 [{"user": {"login": "u"}, "body": "c30", "path": "a.py", "line": 30}]]
        calls = []
        with patch("loop_spec.revise.repo_module.run_gh", side_effect=self._gh(inline=pages, calls=calls)):
            gaps = gaps_from_pr(Path("/fake/repo"), 7)

        self.assertEqual(len(gaps), 31)
        self.assertEqual(gaps[-1]["body"], "c30")
        self.assertTrue(all("--paginate" in c and "--slurp" in c for c in calls if c[0] == "api" and c[1] != "graphql"))

    def test_bot_and_marker_comments_dropped(self):
        # A GitHub Actions comment's REST login ends in [bot]; its type is Bot either way.
        issue = [{"user": {"login": "dependabot[bot]", "type": "Bot"}, "body": "bump"},
                 {"user": {"login": "github-actions", "type": "Bot"}, "body": "coverage report"},
                 {"user": {"login": "me"}, "body": "<!-- loop-spec:reply -->\nreplied"},
                 {"user": {"login": "alice"}, "body": "real"}]
        inline = [{"id": 5, "user": {"login": "app", "type": "Bot"}, "body": "bot inline", "path": "a.py"}]
        with patch("loop_spec.revise.repo_module.run_gh", side_effect=self._gh(issue, inline=inline)):
            gaps = gaps_from_pr(Path("/fake/repo"), 7)
        self.assertEqual([(g["author"], g["kind"]) for g in gaps], [("alice", "comment")])

    def test_resolved_and_outdated_threads_dropped(self):
        pages = [[{"id": 1, "user": {"login": "u"}, "body": "resolved", "path": "a.py"},
                  {"id": 2, "user": {"login": "u"}, "body": "outdated", "path": "a.py"},
                  {"id": 3, "user": {"login": "u"}, "body": "open", "path": "a.py"}]]
        threads = {"data": {"repository": {"pullRequest": {"reviewThreads": {"nodes": [
            {"isResolved": True, "isOutdated": False, "comments": {"nodes": [{"databaseId": 1}]}},
            {"isResolved": False, "isOutdated": True, "comments": {"nodes": [{"databaseId": 2}]}},
            {"isResolved": False, "isOutdated": False, "comments": {"nodes": [{"databaseId": 3}]}}]}}}}}

        with patch("loop_spec.revise.repo_module.run_gh", side_effect=self._gh(inline=pages, threads=threads)):
            gaps = gaps_from_pr(Path("/fake/repo"), 7)
        self.assertEqual([(g["body"], g["commentId"], g["kind"]) for g in gaps], [("open", 3, "inline")])

    def test_failed_thread_read_keeps_inline_comments(self):
        inline = [{"id": 9, "user": {"login": "u"}, "body": "kept", "path": "a.py"}]
        with patch("loop_spec.revise.repo_module.run_gh", side_effect=self._gh(inline=inline)):
            gaps = gaps_from_pr(Path("/fake/repo"), 7)
        self.assertEqual([g["body"] for g in gaps], ["kept"])

    def test_failing_check_becomes_gap(self):
        checks = [{"name": "lint", "state": "FAILURE", "link": "https://ci/1", "bucket": "fail"},
                  {"name": "unit", "state": "SUCCESS", "link": "https://ci/2", "bucket": "pass"}]
        with patch("loop_spec.revise.repo_module.run_gh", side_effect=self._gh(checks=checks)):
            gaps = gaps_from_pr(Path("/fake/repo"), 7)
        self.assertEqual([(g["kind"], g["author"], g["body"]) for g in gaps],
                         [("check", "ci", "CI check lint failed: https://ci/1")])

    def test_gh_failure_raises(self):
        with patch("loop_spec.revise.repo_module.run_gh", return_value=(1, "", "not found")):
            with self.assertRaises(Exception):
                gaps_from_pr(Path("/fake/repo"), 7)


class RepliesTests(unittest.TestCase):
    def test_replies_join_each_response_with_its_gap(self):
        from types import SimpleNamespace
        from loop_spec.revise import replies
        store = SimpleNamespace(state={"revise": {"gaps": [
            {"id": "G-1", "kind": "inline", "url": "https://x/1", "commentId": 4, "author": "alice", "body": "b"}]}})
        product = {"responses": [{"gap": "G-1", "disposition": "declined", "note": "why"},
                                 {"gap": "G-9", "disposition": "addressed", "note": "unknown gap"}]}
        self.assertEqual(replies(store, product), [{"gap": "G-1", "disposition": "declined", "note": "why",
                                                    "kind": "inline", "url": "https://x/1", "commentId": 4,
                                                    "author": "alice"}])

    def test_revise_schema_requires_responses_in_both_copies(self):
        root = Path(__file__).resolve().parents[1]
        for path in (root / "loop_spec" / "schemas" / "revise.json", root.parent / "roles" / "reviser" / "schema.json"):
            self.assertIn("responses", json.loads(path.read_text())["required"])


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

    def test_step_keeps_a_large_comment_body_on_real_lines(self):
        from loop_spec.steps import read_schedule
        log = "".join(f"FAILED tests/test_a.py::test_{i:04d} - AssertionError\n" for i in range(500))
        self.store.state["revise"]["gaps"][0]["body"] = log
        action = step(self.store, self.paths, self.ctx)
        read_schedule(action.request["prompt"])
        self.assertIn("### gap:G-1\nFAILED tests/test_a.py::test_0000", action.request["prompt"])

    def test_step_carries_prior_spec_and_plan_when_found(self):
        # LF-37: controller._find_delivering_run_products fills adoption.prior (core
        # state, D4) before the step is ever issued; the request passes it through.
        self.store.state["adoption"]["prior"] = {
            "slug": "delivered-run",
            "spec": {"criteria": [{"id": "AC-1", "text": "the greeting is friendly"}]},
            "plan": {"tasks": []},
        }
        action = step(self.store, self.paths, self.ctx)
        self.assertIn("### prior", action.request["prompt"])
        self.assertIn("delivered-run", action.request["prompt"])
        self.assertIn("the greeting is friendly", action.request["prompt"])

    def test_step_carries_the_issue_the_pr_closes(self):
        self.store.state["issue"] = {"repo": "repo", "number": 9, "title": "Add a percent helper",
                                     "url": "u", "body": "whole == 0 raises ValueError"}
        action = step(self.store, self.paths, self.ctx)
        self.assertIn("### issue", action.request["prompt"])
        self.assertIn("whole == 0 raises ValueError", action.request["prompt"])

    def test_step_fetches_the_comments_once_when_its_bucket_has_none(self):
        # D4: revise fetches its own gaps on its first step; an empty list is a PR
        # with no comments and is never fetched again.
        self.store.state["revise"] = {"product": None}
        with patch("loop_spec.revise.gaps_from_pr", return_value=[]) as fetch:
            step(self.store, self.paths, self.ctx)
            step(self.store, self.paths, self.ctx)
        fetch.assert_called_once_with(self.repo, 7)
        self.assertEqual(self.store.state["revise"]["gaps"], [])

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
