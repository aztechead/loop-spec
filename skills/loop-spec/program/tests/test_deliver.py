"""Unit tests for loop_spec.deliver: push, PR reconciliation, and exit choice.

No test calls the real `gh` or the network: `repo.run_gh` is patched with canned
JSON, and pushes go to a local bare remote so a real rejection can be exercised
without touching GitHub.
"""
# simplicity: this stdlib import block matches test_controller.py's own; there is no
# shared import-shape to factor out of six ordinary stdlib names.
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from loop_spec import deliver
from loop_spec import repo as repo_module
from loop_spec.steps import Product
from loop_spec.paths import FeaturePaths
from loop_spec.schema import load_schema, validate
from loop_spec.state import StateStore


def _git(cwd, *args):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True)


# simplicity: _init_repo/_head repeat test_repo.py's, test_baseline.py's, and
# test_execute.py's own copies verbatim; there is no shared test-fixture module in
# this tree yet, and adding one is a cross-file change outside this file's own scope.
def _init_repo(cwd):
    _git(cwd, "init", "-q", "-b", "main")
    _git(cwd, "config", "user.name", "Test")
    _git(cwd, "config", "user.email", "test@example.com")


def _head(cwd, ref="HEAD"):
    return subprocess.run(["git", "rev-parse", ref], cwd=cwd, capture_output=True, text=True).stdout.strip()


def _commit(cwd, filename, message):
    Path(cwd, filename).write_text(f"{filename}\n")
    _git(cwd, "add", filename)
    _git(cwd, "commit", "-q", "-m", message)


PR_VIEW_JSON = json.dumps({"number": 42, "url": "https://x/pull/42", "headRefName": "feature",
                            "headRefOid": "deadbeef", "baseRefName": "main"})


class DeliverTests(unittest.TestCase):
    # simplicity: setUp/tearDown are unittest's fixed method names, not a naming
    # choice; house-style.sh's camelCase deviation here is the same pre-existing
    # false positive test_execute.py, test_result.py, and test_postconditions.py hit.
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.remote = self.tmp / "remote.git"
        self.remote.mkdir()
        _git(self.remote, "init", "-q", "--bare", "-b", "main")

        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        _init_repo(self.repo)
        _commit(self.repo, "a.py", "init")
        self.base_sha = _head(self.repo)
        _git(self.repo, "remote", "add", "origin", str(self.remote))
        _git(self.repo, "push", "origin", "main")

        _git(self.repo, "checkout", "-q", "-b", "feature")
        _commit(self.repo, "b.py", "feature work")
        self.head_sha = _head(self.repo)
        _git(self.repo, "checkout", "-q", "main")

        self.paths = FeaturePaths(root=self.tmp / "run")
        self.store = StateStore.create(self.paths, {"id": "run-1", "slug": "widget"}, "add a widget")
        self.store.state["repos"] = {"repo": {"path": str(self.repo), "baseSha": self.base_sha,
                                               "featureBranch": "feature", "defaultBranch": "main",
                                               "lastKnownHead": self.head_sha}}
        self.store.state["credentialChecks"] = {"repo": {
            "git_ok": True, "gh_ok": True, "checked": ["git ls-remote --exit-code origin HEAD", "gh auth status"],
            "failedCommand": None, "repair": None,
        }}
        self.store.state["products"]["execute"] = {"exit": "integrated", "product": {"heads": {"repo": self.head_sha}}}
        self.store.state["products"]["spec"] = {"exit": "approved", "product": {
            "goal": "add a widget", "boundaries": [], "criteria": [{"id": "AC-1", "text": "it works"}],
            "decisions": [], "openQuestions": [],
        }}
        self.store.state["products"]["verify"] = {"exit": "passed", "product": {"verdicts": []}}
        self.store.state["products"]["iterate"] = {"exit": "converged", "product": {"gaps": []}}
        self.store.save()

        self.ctx = {"attempt": {"id": "attempt-1"}, "inputs": {"digest": "sha256:" + "a" * 64},
                    "paths": {"projectRoot": str(self.repo)}, "entry": {"mode": "fresh", "payload": None}}

    def tearDown(self):
        self._tmp.cleanup()

    def _run_gh_reconcile(self, existing=None):
        existing_json = json.dumps(existing or [])

        def fake_run_gh(repo, *args):
            if args[:2] == ("pr", "list"):
                return 0, existing_json, ""
            if args[:2] == ("pr", "create"):
                return 0, "https://x/pull/42\n", ""
            if args[:2] == ("pr", "view"):
                return 0, PR_VIEW_JSON, ""
            raise AssertionError(f"unexpected gh call: {args}")
        return patch("loop_spec.deliver.repo_module.run_gh", side_effect=fake_run_gh)

    def test_delivers_a_touched_repo_by_pushing_and_creating_a_pr(self):
        with self._run_gh_reconcile():
            action = deliver.run(self.store, self.paths, self.ctx)

        self.assertIsInstance(action, Product)
        self.assertEqual(action.product["exit"], "delivered")
        entry = action.product["repos"][0]
        self.assertEqual(entry["state"], "delivered")
        self.assertEqual(entry["pr"]["number"], 42)
        self.assertEqual(entry["deliveredSha"], self.head_sha)
        self.assertEqual(_head(self.remote, "feature"), self.head_sha)  # actually pushed
        # LF-48: the PR body file never lands in the worktree (it made the checkout
        # dirty, and terminal cleanup then kept it as backlog).
        execute_repos = (self.store.state.get("execute") or {}).get("repos") or {}
        worktree = Path(execute_repos["repo"]["worktree"]) if "repo" in execute_repos else self.repo
        self.assertFalse(list(worktree.glob(".loop-spec-pr-body*")))
        self.assertTrue(repo_module.is_clean(worktree))

    def test_skips_an_untouched_repo(self):
        self.store.state["products"]["execute"]["product"]["heads"]["repo"] = self.base_sha
        self.store.save()
        with self._run_gh_reconcile():
            action = deliver.run(self.store, self.paths, self.ctx)
        entry = action.product["repos"][0]
        self.assertEqual(entry["state"], "skipped")
        self.assertIsNone(entry["pr"])
        self.assertEqual(action.product["exit"], "delivered")

    def test_no_change_on_an_adopted_pr_names_the_pr_and_writes_nothing(self):
        # 7.4.1: the open PR already does what was asked; its commits sit after base,
        # but a no-change run pushes nothing and makes no gh call.
        self.store.state["products"]["execute"]["exit"] = "no change"
        self.store.state["adoption"] = {"repo": "repo", "number": 7, "url": "https://x/pull/7", "headRef": "feature",
                                         "baseBranch": "main", "baseSha": self.base_sha, "headSha": self.head_sha}
        self.store.save()
        with patch("loop_spec.deliver.repo_module.run_gh", side_effect=AssertionError("no gh call on no change")):
            action = deliver.run(self.store, self.paths, self.ctx)
        entry = action.product["repos"][0]
        self.assertEqual(entry["state"], "skipped")
        self.assertIsNone(entry["deliveredSha"])
        self.assertEqual(entry["pr"], {"number": 7, "url": "https://x/pull/7", "headRef": "feature",
                                       "headSha": self.head_sha, "base": "main"})
        self.assertEqual(action.product["exit"], "delivered")
        self.assertNotEqual(_head(self.remote, "feature"), self.head_sha)  # nothing pushed

    def test_reuses_an_existing_open_pr_without_creating_a_new_one(self):
        calls = []

        def fake_run_gh(repo, *args):
            calls.append(args)
            if args[:2] == ("pr", "list"):
                return 0, json.dumps([{"number": 42, "url": "https://x/pull/42",
                                        "headRefOid": self.head_sha, "baseRefName": "main"}]), ""
            if args[:2] == ("pr", "view"):
                return 0, PR_VIEW_JSON, ""
            if args[:2] == ("pr", "edit"):
                return edit_result
            raise AssertionError(f"unexpected gh call: {args}")

        edit_result = (0, "", "")
        with patch("loop_spec.deliver.repo_module.run_gh", side_effect=fake_run_gh):
            action = deliver.run(self.store, self.paths, self.ctx)

        self.assertEqual(action.product["repos"][0]["state"], "delivered")
        self.assertFalse(any(c[:2] == ("pr", "create") for c in calls))
        # 7.1.0: the existing PR's body is refreshed; a failed edit is a caveat only.
        self.assertTrue(any(c[:3] == ("pr", "edit", "42") for c in calls))
        edit_result = (1, "", "HTTP 403")
        with patch("loop_spec.deliver.repo_module.run_gh", side_effect=fake_run_gh):
            action = deliver.run(self.store, self.paths, self.ctx)
        row = action.product["repos"][0]
        self.assertEqual((row["state"], row["pr"]["number"]), ("delivered", 42))
        self.assertIn("PR body was not updated", row["caveats"][0])

    def test_failed_credential_check_blocks_delivery(self):
        check = self.store.state["credentialChecks"]["repo"]
        check["gh_ok"] = False
        check["failedCommand"] = "gh auth status"
        check["repair"] = "run: gh auth login"
        self.store.save()
        with self._run_gh_reconcile():
            action = deliver.run(self.store, self.paths, self.ctx)
        self.assertEqual(action.product["exit"], "delivery blocked")
        entry = action.product["repos"][0]
        self.assertEqual(entry["state"], "failed")
        # LF-21(b): quotes the recorded failedCommand/repair, not a generic
        # "re-run loop-spec status" pointer.
        self.assertIn("gh credential check failed: gh auth status", entry["caveats"][0])
        self.assertIn("run: gh auth login", entry["caveats"][0])

    def test_a_real_push_rejection_blocks_delivery_without_forcing(self):
        # A second clone pushes a divergent commit to origin/feature first, so our
        # repo's own push is a genuine non-fast-forward rejection, not a mock.
        other = self.tmp / "other"
        _git(self.tmp, "clone", "-q", str(self.remote), str(other))
        _git(other, "checkout", "-q", "-b", "feature")
        _commit(other, "c.py", "someone else's change")
        _git(other, "push", "-q", "origin", "feature")

        with self._run_gh_reconcile():
            action = deliver.run(self.store, self.paths, self.ctx)

        self.assertEqual(action.product["exit"], "delivery blocked")
        self.assertEqual(action.product["repos"][0]["state"], "failed")
        self.assertIn("push rejected", action.product["repos"][0]["caveats"][0])

    def test_a_locally_moved_feature_branch_is_not_pushed_and_the_row_is_failed(self):
        # R8: a commit landed on the feature branch after VERIFY's accepted head
        # must never get pushed just because it is what the branch currently
        # points at -- caught before the push, not by D1 noticing afterward.
        _git(self.repo, "checkout", "-q", "feature")
        _commit(self.repo, "c.py", "sneaked in after verify")
        _git(self.repo, "checkout", "-q", "main")

        with self._run_gh_reconcile():
            action = deliver.run(self.store, self.paths, self.ctx)

        entry = action.product["repos"][0]
        self.assertEqual(entry["state"], "failed")
        self.assertIsNone(entry["pr"])
        self.assertIn("feature branch moved after VERIFY", entry["caveats"][0])
        # EA-runs item 2: the caveat keeps the commits (a rescue branch), never a hard reset.
        self.assertIn("branch loop-spec-rescue-", entry["caveats"][0])
        self.assertIn("reset --keep", entry["caveats"][0])
        self.assertNotIn("--hard", entry["caveats"][0])
        self.assertEqual(action.product["exit"], "delivery blocked")  # LF-58: nothing delivered
        self.assertIsNone(repo_module.branch_sha(self.remote, "feature"))  # never pushed at all

    def test_normal_delivery_pushes_exactly_the_verified_sha_by_value(self):
        with self._run_gh_reconcile():
            action = deliver.run(self.store, self.paths, self.ctx)
        self.assertEqual(action.product["repos"][0]["state"], "delivered")
        self.assertEqual(action.product["repos"][0]["deliveredSha"], self.head_sha)
        self.assertEqual(_head(self.remote, "feature"), self.head_sha)

    def test_draft_flag_set_when_iterate_converged_with_caveats(self):
        self.store.state["products"]["iterate"]["exit"] = "converged with caveats"
        self.store.save()
        create_args = []

        def fake_run_gh(repo, *args):
            if args[:2] == ("pr", "list"):
                return 0, "[]", ""
            if args[:2] == ("pr", "create"):
                create_args.extend(args)
                return 0, "https://x/pull/42\n", ""
            if args[:2] == ("pr", "view"):
                return 0, PR_VIEW_JSON, ""
            raise AssertionError(f"unexpected gh call: {args}")

        with patch("loop_spec.deliver.repo_module.run_gh", side_effect=fake_run_gh):
            deliver.run(self.store, self.paths, self.ctx)

        self.assertIn("--draft", create_args)

    # --- LF-58: one repo's failure never stops the others --------------------

    def _add_second_repo(self, name="second"):
        remote = self.tmp / f"{name}.git"
        remote.mkdir()
        _git(remote, "init", "-q", "--bare", "-b", "main")
        repo = self.tmp / name
        repo.mkdir()
        _init_repo(repo)
        _commit(repo, "a.py", "init")
        base = _head(repo)
        _git(repo, "remote", "add", "origin", str(remote))
        _git(repo, "push", "origin", "main")
        _git(repo, "checkout", "-q", "-b", "feature")
        _commit(repo, "b.py", "work")
        head = _head(repo)
        _git(repo, "checkout", "-q", "main")
        self.store.state["repos"][name] = {"path": str(repo), "baseSha": base, "featureBranch": "feature",
                                           "defaultBranch": "main", "lastKnownHead": head}
        self.store.state["credentialChecks"][name] = dict(self.store.state["credentialChecks"]["repo"])
        self.store.state["products"]["execute"]["product"]["heads"][name] = head
        self.store.save()
        return repo, remote, head

    def _deliver(self):
        with self._run_gh_reconcile():
            product = deliver.run(self.store, self.paths, self.ctx).product
        self.assertEqual(validate(product, load_schema("deliver")), [])
        return product, {r["repo"]: r for r in product["repos"]}

    def test_a_failed_first_repo_still_lets_the_second_deliver(self):
        second, second_remote, second_head = self._add_second_repo()
        _git(self.repo, "config", "remote.origin.pushurl", "/nonexistent/remote.git")
        product, rows = self._deliver()
        self.assertEqual(product["exit"], "partially delivered")
        self.assertEqual(rows["repo"]["state"], "failed")
        self.assertIn("check origin's push URL", rows["repo"]["caveats"][0])
        self.assertIn("does not appear to be a git repository", rows["repo"]["caveats"][0])  # raw stderr kept
        self.assertEqual((rows["second"]["state"], rows["second"]["deliveredSha"]), ("delivered", second_head))
        self.assertEqual(_head(second_remote, "feature"), second_head)

    def test_a_failed_last_repo_keeps_the_first_delivery(self):
        second, _, _ = self._add_second_repo()
        _git(second, "config", "remote.origin.pushurl", "/nonexistent/remote.git")
        product, rows = self._deliver()
        self.assertEqual(product["exit"], "partially delivered")
        self.assertEqual((rows["repo"]["state"], rows["second"]["state"]), ("delivered", "failed"))

    def test_every_push_failing_is_delivery_blocked_naming_each_cause(self):
        second, _, _ = self._add_second_repo()
        for repo in (self.repo, second):
            _git(repo, "config", "remote.origin.pushurl", "/nonexistent/remote.git")
        product, rows = self._deliver()
        self.assertEqual(product["exit"], "delivery blocked")
        self.assertTrue(all(r["state"] == "failed" and r["caveats"] for r in rows.values()))

    def test_one_refused_credential_blocks_before_any_remote_write(self):
        second, second_remote, _ = self._add_second_repo()
        self.store.state["credentialChecks"]["second"].update({"gh_ok": False, "failedCommand": "gh auth status", "repair": "run: gh auth login"})
        self.store.save()
        product, rows = self._deliver()
        self.assertEqual(product["exit"], "delivery blocked")
        self.assertIn("gh credential check failed", rows["second"]["caveats"][0])
        self.assertIn("not attempted", rows["repo"]["caveats"][0])
        self.assertIsNone(repo_module.branch_sha(self.remote, "feature"))
        self.assertIsNone(repo_module.branch_sha(second_remote, "feature"))

    def test_a_push_that_lands_before_the_pr_fails_records_what_was_published(self):
        def fake_run_gh(repo, *args):
            if args[:2] == ("pr", "list"):
                return 0, "[]", ""
            if args[:2] == ("pr", "create"):
                return 1, "", "GraphQL: rate limited"
            raise AssertionError(f"unexpected gh call: {args}")
        with patch("loop_spec.deliver.repo_module.run_gh", side_effect=fake_run_gh):
            product = deliver.run(self.store, self.paths, self.ctx).product
        self.assertEqual(validate(product, load_schema("deliver")), [])
        row = product["repos"][0]
        self.assertEqual((row["state"], row["publishedSha"], row["deliveredSha"]), ("failed", self.head_sha, None))
        self.assertIn("rate limited", row["caveats"][0])
        self.assertEqual(_head(self.remote, "feature"), self.head_sha)

    def _refuse_credentials(self):
        self.store.state["credentialChecks"]["repo"].update({"gh_ok": False, "failedCommand": "gh auth status", "repair": "run: gh auth login"})
        self.store.save()

    def test_a_published_branch_survives_a_reentry_refused_by_credentials(self):
        # LF-58 review: push -> PR failure -> re-enter -> credential refusal -> stop.
        def failing_create(repo, *args):
            if args[:2] == ("pr", "list"):
                return 0, "[]", ""
            return 1, "", "GraphQL: rate limited"
        with patch("loop_spec.deliver.repo_module.run_gh", side_effect=failing_create):
            deliver.run(self.store, self.paths, self.ctx)
        self._refuse_credentials()
        product, rows = self._deliver()
        self.assertEqual(product["exit"], "delivery blocked")
        self.assertEqual(rows["repo"]["publishedSha"], self.head_sha)
        self.assertTrue(any(c.startswith("published: ") for c in rows["repo"]["caveats"]))
        self.assertEqual(_head(self.remote, "feature"), self.head_sha)  # the remote still has it


    def test_an_earlier_pr_survives_a_reentry_refused_by_credentials(self):
        with self._run_gh_reconcile():
            deliver.run(self.store, self.paths, self.ctx)
        self._refuse_credentials()
        _, rows = self._deliver()
        self.assertEqual((rows["repo"]["state"], rows["repo"]["pr"]["number"], rows["repo"]["publishedSha"]),
                         ("failed", 42, self.head_sha))

    def test_an_earlier_pr_survives_a_retried_push_whose_pr_lookup_fails(self):
        # LF-58 review: prior PR -> successful push retry -> PR lookup failure -> stop.
        with self._run_gh_reconcile():
            deliver.run(self.store, self.paths, self.ctx)
        self.ctx["attempt"] = {"id": "attempt-retry"}
        with patch("loop_spec.deliver.repo_module.run_gh", return_value=(1, "", "HTTP 502")):
            product = deliver.run(self.store, self.paths, self.ctx).product
        self.assertEqual(validate(product, load_schema("deliver")), [])
        row = product["repos"][0]
        self.assertEqual((row["state"], row["pr"]["number"], row["publishedSha"]), ("failed", 42, self.head_sha))
        self.assertIn("HTTP 502", row["caveats"][0])
        record = self.store.state["deliverPublished"]["repo"]
        self.assertEqual((record["pr"]["number"], record["attemptId"]), (42, "attempt-retry"))
        self.assertNotEqual(record["prAttemptId"], "attempt-retry")  # the PR was not re-seen this attempt

    def test_push_repair_names_divergence_only_when_git_says_so(self):
        self.assertIn("fetch, reconcile", deliver._push_repair("! [rejected] feature -> feature (non-fast-forward)"))
        self.assertIn("fetch, reconcile", deliver._push_repair("! [rejected] feature -> feature (fetch first)"))
        self.assertIn("check origin's push URL", deliver._push_repair("! [rejected] v1 -> v1 (already exists)"))


if __name__ == "__main__":
    unittest.main()


class PrTitleTests(unittest.TestCase):
    def test_long_title_is_cut_at_a_word_boundary(self):
        # LF-36: the live debug run's PR title ended mid-word ("test_preexisti").
        title = "Correct the wrong expected value in tests/test_calc.py::test_preexisting_failure so it asserts add(2, 2) == 4"
        cut = deliver.pr_title(title)
        self.assertLessEqual(len(cut), 70)
        self.assertTrue(cut.endswith("..."))
        self.assertIn(cut[:-3], title)
        self.assertTrue(title.startswith(cut[:-3]))
        self.assertEqual(title[len(cut) - 3], " ")
        self.assertEqual(deliver.pr_title("short"), "short")
        self.assertEqual(deliver.pr_title("Add a flag\n\nthat exports  rows"), "Add a flag that exports rows")


class AcceptedRemoteTests(DeliverTests.__bases__[0]):
    """7.1.0: deliver.acceptRemotePaths lets DELIVER accept commits someone else put
    on the branch after the verified SHA, when they touch only allowed paths that the
    verified change never touches. The verified SHA stays the delivered one."""

    def setUp(self):
        DeliverTests.setUp(self)
        self.addCleanup(self._tmp.cleanup)
        (self.repo / ".loop-spec").mkdir()
        (self.repo / ".loop-spec" / "config.json").write_text(
            json.dumps({"deliver": {"acceptRemotePaths": ["CHANGELOG.md"]}}))
        _git(self.repo, "push", "-q", "origin", f"{self.head_sha}:refs/heads/feature")

    def _bot_commit(self, filename):
        bot = self.tmp / "bot"
        _git(self.tmp, "clone", "-q", "-b", "feature", str(self.remote), str(bot))
        _git(bot, "config", "user.name", "bot")
        _git(bot, "config", "user.email", "bot@example.com")
        Path(bot, filename).write_text("written by the bot\n")
        _git(bot, "add", filename)
        _git(bot, "commit", "-q", "-m", f"bot: touch {filename}")
        _git(bot, "push", "-q", "origin", "feature")
        return _head(bot)

    def _gh(self, head, create=(0, "https://x/pull/42\n", "")):
        view = json.dumps({"number": 42, "url": "https://x/pull/42", "headRefName": "feature",
                           "headRefOid": head, "baseRefName": "main"})

        def fake_run_gh(repo, *args):
            if args[:2] == ("pr", "list"):
                return 0, "[]", ""
            if args[:2] == ("pr", "create"):
                return create
            if args[:2] == ("pr", "view"):
                return 0, view, ""
            raise AssertionError(f"unexpected gh call: {args}")
        return fake_run_gh

    def _boundary(self, product):
        from loop_spec import postconditions
        return postconditions.Boundary(self.store, self.paths, phase="deliver", product=product,
                                       exit=product["exit"], project_root=self.repo)

    def test_an_allowed_bot_commit_is_accepted_without_a_push_and_d1_d2_hold(self):
        bot_head = self._bot_commit("CHANGELOG.md")
        with patch("loop_spec.deliver.repo_module.run_gh", side_effect=self._gh(bot_head)):
            action = deliver.run(self.store, self.paths, self.ctx)
        row = action.product["repos"][0]
        self.assertEqual((action.product["exit"], row["deliveredSha"]), ("delivered", self.head_sha))
        self.assertEqual(row["acceptedRemote"]["head"], bot_head)
        self.assertEqual(row["acceptedRemote"]["paths"], ["CHANGELOG.md"])
        self.assertEqual(_head(self.remote, "feature"), bot_head)  # nothing was pushed over it
        self.assertEqual(validate(action.product, load_schema("deliver")), [])
        boundary = self._boundary(action.product)
        self.assertIsNone(boundary._d1())
        with patch("loop_spec.postconditions.repo_module.run_gh",
                   return_value=(0, json.dumps({"state": "OPEN", "headRefName": "feature",
                                                "headRefOid": bot_head, "baseRefName": "main"}), "")):
            self.assertIsNone(boundary._d2())
        # A PR that names the verified SHA while the remote holds the extension is one
        # head too few: D2 holds both to the head D1 observed.
        with patch("loop_spec.postconditions.repo_module.run_gh",
                   return_value=(0, json.dumps({"state": "OPEN", "headRefName": "feature",
                                                "headRefOid": self.head_sha, "baseRefName": "main"}), "")):
            self.assertIsNotNone(boundary._d2())
        # An invented path in the recorded extension no longer matches what D1 recomputes.
        forged = json.loads(json.dumps(action.product))
        forged["repos"][0]["acceptedRemote"]["paths"] = ["CHANGELOG.md", "b.py"]
        self.assertIsNotNone(self._boundary(forged)._d1())

    def test_a_bot_push_between_the_fetch_and_the_push_is_rechecked_once(self):
        bot_head = self._bot_commit("CHANGELOG.md")
        real = deliver._accept_extension
        calls = []

        def first_sees_nothing(*args):
            calls.append(args)
            return (None, None) if len(calls) == 1 else real(*args)
        with patch("loop_spec.deliver._accept_extension", side_effect=first_sees_nothing), \
             patch("loop_spec.deliver.repo_module.run_gh", side_effect=self._gh(bot_head)):
            action = deliver.run(self.store, self.paths, self.ctx)
        row = action.product["repos"][0]
        self.assertEqual((row["state"], row["acceptedRemote"]["head"], len(calls)), ("delivered", bot_head, 2))

    def test_a_bot_commit_on_a_verified_path_is_refused(self):
        self._bot_commit("b.py")
        with patch("loop_spec.deliver.repo_module.run_gh", side_effect=self._gh("x")):
            action = deliver.run(self.store, self.paths, self.ctx)
        row = action.product["repos"][0]
        self.assertEqual((action.product["exit"], row["state"]), ("delivery blocked", "failed"))
        self.assertIn("touch b.py", row["caveats"][0])

    def test_accepted_extension_is_kept_when_the_pr_step_then_fails(self):
        self._bot_commit("CHANGELOG.md")
        with patch("loop_spec.deliver.repo_module.run_gh", side_effect=self._gh("x", create=(1, "", "boom"))):
            action = deliver.run(self.store, self.paths, self.ctx)
        row = action.product["repos"][0]
        self.assertEqual(row["state"], "failed")
        self.assertIn("no push", row["caveats"][0])
        published = self.store.state["deliverPublished"]["repo"]
        self.assertEqual((published["observed"], published["acceptedRemote"]["paths"]), (True, ["CHANGELOG.md"]))

    def test_without_the_config_key_a_bot_commit_still_blocks(self):
        (self.repo / ".loop-spec" / "config.json").write_text("{}")
        self._bot_commit("CHANGELOG.md")
        with patch("loop_spec.deliver.repo_module.run_gh", side_effect=self._gh("x")):
            action = deliver.run(self.store, self.paths, self.ctx)
        self.assertIn("push rejected", action.product["repos"][0]["caveats"][0])


class RemoteExtensionTests(unittest.TestCase):
    """repo.remote_extension reads every path of every extension commit, NUL-safe."""

    def test_touched_then_restored_and_renamed_paths_all_count(self):
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            remote = tmp / "r.git"
            remote.mkdir()
            _git(remote, "init", "-q", "--bare", "-b", "main")
            work = tmp / "w"
            work.mkdir()
            _init_repo(work)
            _commit(work, "a.py", "base")
            base = _head(work)
            _commit(work, "b c.py", "verified")
            verified = _head(work)
            _git(work, "remote", "add", "origin", str(remote))
            (work / "b c.py").write_text("changed\n")
            _git(work, "commit", "-qam", "bot touches")
            _git(work, "revert", "--no-edit", "HEAD")
            _git(work, "mv", "a.py", "CHANGELOG.md")
            _git(work, "commit", "-qm", "bot renames")
            _git(work, "push", "-q", "origin", "HEAD:refs/heads/feature")
            ext = repo_module.remote_extension(work, "feature", verified, base, ["CHANGELOG.md"])
        self.assertEqual(ext["state"], "extension")
        self.assertEqual(ext["paths"], ["CHANGELOG.md", "a.py", "b c.py"])
        self.assertEqual(ext["refused"], ["a.py", "b c.py"])
        self.assertEqual(len(ext["commits"]), 3)
