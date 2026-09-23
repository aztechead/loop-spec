"""Unit tests for loop_spec.verify: range selection, product assembly, exit choice."""
import subprocess
import tempfile
import unittest
from pathlib import Path

from loop_spec.execute import IssueStep, Product
from loop_spec.paths import FeaturePaths
from loop_spec.state import StateStore
from loop_spec.verify import on_step_refused, on_submit as _on_submit, step


def on_submit(store, paths, step_record, result):
    # steps.submit records an accepted submission before routing it (LF-60 checks it).
    store.state["steps"]["submissions"][step_record["stepAttemptId"]] = {"evidenceLevel": "host-attested"}
    _on_submit(store, paths, step_record, result)

from tests._product_checks import assert_product_holds


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

    def _run_pass(self, verifier_result, reviewer_findings=None, repos=("repo",)):
        # V3 (evidence SHA is the verified head) and V4 (the program's own
        # re-run matched) are ordinarily settled by controller.py's own
        # verified_heads/_run_verify_reruns, which drives EXECUTE and re-runs
        # each criterion's command after accepting the product -- neither ever
        # runs here, since this helper drives verify.step/on_submit directly.
        # Standing in for both keeps a "passed" product from failing a Boundary
        # check for a reason that has nothing to do with what a test asserts.
        for v in verifier_result["verdicts"]:
            if v["evidence"] is not None:
                v["evidence"]["sha"] = self.head_sha
            if v["verdict"] in ("pass", "fail"):
                self.store.state.setdefault("verifyRuns", {})[v["criterion"]] = {"matched": True}
        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, IssueStep)
        self.assertEqual(action.request["role"], "verifier")
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "v-step"}, verifier_result)

        for repo_name in repos:
            action = step(self.store, self.paths, self.ctx)
            self.assertIsInstance(action, IssueStep)
            self.assertEqual(action.request["role"], "code-reviewer")
            range_ = self.store.state["verify"]["ranges"][repo_name]
            reviewer_result = {"sha": range_["to"], "reviewedRange": {"from": range_["from"], "to": range_["to"]},
                                "verdict": "pass", "findings": reviewer_findings or [], "securityDispositions": []}
            on_submit(self.store, self.paths, action.request | {"stepAttemptId": f"r-step-{repo_name}"}, reviewer_result)

        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, Product)
        return action.product

    def test_first_pass_reviews_the_full_diff(self):
        product = self._run_pass(_verifier_result([_verdict("AC-1", "pass")]))
        range_ = product["reviewedRanges"][0]
        self.assertEqual(range_["repo"], "repo")
        self.assertTrue(range_["full"])
        self.assertEqual(range_["from"], self.base_sha)
        self.assertEqual(range_["to"], self.head_sha)
        assert_product_holds(self, self.store, self.paths, self.repo, "verify", product)

    def test_delta_pass_reviews_from_the_last_reviewed_to(self):
        self.store.state["ledger"]["reviewedRanges"] = [
            {"id": "range-1", "repo": "repo", "from": self.base_sha, "to": self.base_sha, "full": True, "byStep": "r-prior"},
        ]
        self.store.state["steps"]["submissions"]["r-prior"] = {"evidenceLevel": "host-attested"}
        self.store.save()
        product = self._run_pass(_verifier_result([_verdict("AC-1", "pass")]))
        range_ = product["reviewedRanges"][0]
        self.assertFalse(range_["full"])
        self.assertEqual(range_["from"], self.base_sha)
        assert_product_holds(self, self.store, self.paths, self.repo, "verify", product)

    def test_final_pass_forces_full_range(self):
        self.store.state["ledger"]["reviewedRanges"] = [
            {"id": "range-1", "repo": "repo", "from": self.base_sha, "to": self.base_sha, "full": True},
        ]
        self.store.save()
        self.ctx["entry"]["payload"] = {"finalPass": True}
        product = self._run_pass(_verifier_result([_verdict("AC-1", "pass")]))
        self.assertTrue(product["reviewedRanges"][0]["full"])
        assert_product_holds(self, self.store, self.paths, self.repo, "verify", product)

    def test_an_untrusted_range_at_the_same_head_is_reviewed_again_in_full(self):
        # LF-60: no byStep (a pre-LF-60 range) or an unattested one is never reused
        # and never a delta base: base..head in full, not an empty delta.
        for by_step, level in ((None, None), ("r-old", "unattested")):
            with self.subTest(by_step=by_step):
                self.store.state.pop("verify", None)
                self.store.state["ledger"]["reviewedRanges"] = [
                    {"id": "range-1", "repo": "repo", "from": self.base_sha, "to": self.head_sha, "full": True, "byStep": by_step},
                ]
                if level:
                    self.store.state["steps"]["submissions"][by_step] = {"evidenceLevel": level}
                self.store.save()
                product = self._run_pass(_verifier_result([_verdict("AC-1", "pass")]))
                self.assertEqual(product["reviewedRanges"][0],
                                 {"repo": "repo", "from": self.base_sha, "to": self.head_sha, "full": True})

    def test_a_refused_review_is_found_by_its_checkout_and_reissued_in_a_fresh_one(self):
        # LF-60: reviewerSteps is written only on an accepted submit, so the refused
        # step's checkout names its repo; the quarantined checkout is not reused.
        verifier_result = _verifier_result([_verdict("AC-1", "pass")])
        verifier_result["verdicts"][0]["evidence"]["sha"] = self.head_sha
        self.store.state.setdefault("verifyRuns", {})["AC-1"] = {"matched": True}
        action = step(self.store, self.paths, self.ctx)
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "v-step"}, verifier_result)
        refused_cwd = step(self.store, self.paths, self.ctx).request["cwd"]
        on_step_refused(self.store, self.paths, "r-x", {"role": "code-reviewer", "cwd": refused_cwd, "reason": "no transcript"})
        verify_state = self.store.state["verify"]
        self.assertNotEqual(verify_state["checkouts"]["repo"], refused_cwd)
        self.assertTrue(Path(verify_state["checkouts"]["repo"]).is_dir())
        action = step(self.store, self.paths, self.ctx)
        self.assertEqual((action.request["role"], action.request["cwd"]), ("code-reviewer", verify_state["checkouts"]["repo"]))
        self.assertEqual((verify_state["pendingReviews"], verify_state["ranges"]["repo"]["full"]), (["repo"], True))

    def test_same_inputs_state_re_reviews_a_repo_whose_review_is_not_accepted(self):
        # LF-60 audit 3.4: VERIFY state kept for the same inputs, phase done, with a
        # reviewer accepted under the old auto-waiver: the repo goes back to review.
        product = self._run_pass(_verifier_result([_verdict("AC-1", "pass")]))
        self.store.state["steps"]["submissions"]["r-step-repo"] = {"evidenceLevel": "unattested"}
        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, IssueStep)
        self.assertEqual(action.request["role"], "code-reviewer")
        verify_state = self.store.state["verify"]
        self.assertEqual((verify_state["phase"], verify_state["pendingReviews"]), ("reviewing", ["repo"]))
        self.assertTrue(verify_state["ranges"]["repo"]["full"])

    def test_final_pass_on_an_unchanged_head_reuses_the_prior_range_with_no_reviewer_step(self):
        # LF-47: ITERATE rewound to EXECUTE with nothing to do, then VERIFY
        # re-entered as a final pass on the SAME head an earlier pass already
        # reviewed in full -- the verifier still runs, but no reviewer step is
        # issued a second time for a range nothing has changed since.
        self.store.state["ledger"]["reviewedRanges"] = [
            {"id": "range-1", "repo": "repo", "from": self.base_sha, "to": self.head_sha, "full": True, "byStep": "r-prior"},
        ]
        self.store.state["steps"]["submissions"]["r-prior"] = {"evidenceLevel": "host-attested"}
        self.store.save()
        self.ctx["entry"]["payload"] = {"finalPass": True}

        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, IssueStep)
        self.assertEqual(action.request["role"], "verifier")

        verifier_result = _verifier_result([_verdict("AC-1", "pass")])
        for v in verifier_result["verdicts"]:
            v["evidence"]["sha"] = self.head_sha
            self.store.state.setdefault("verifyRuns", {})[v["criterion"]] = {"matched": True}
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "v-step"}, verifier_result)

        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, Product)  # no reviewer step issued
        product = action.product
        self.assertEqual(product["reviewedRanges"], [{"repo": "repo", "from": self.base_sha, "to": self.head_sha, "full": True}])
        events_text = self.paths.events_jsonl.read_text()
        self.assertIn('"review_reused"', events_text)
        assert_product_holds(self, self.store, self.paths, self.repo, "verify", product)

    def test_all_pass_exits_passed(self):
        product = self._run_pass(_verifier_result([_verdict("AC-1", "pass")]))
        self.assertEqual(product["exit"], "passed")
        # LF-28: evidence names the repo the criterion actually belongs to (the
        # repo of the task that covers it), not left for the reader to guess.
        self.assertEqual(product["verdicts"][0]["evidence"]["repo"], "repo")
        assert_product_holds(self, self.store, self.paths, self.repo, "verify", product)

    def test_a_fail_exits_implementation_gap_with_a_remediation_task(self):
        product = self._run_pass(_verifier_result([_verdict("AC-1", "fail", {"files": ["feature.py"]})]))
        self.assertEqual(product["exit"], "implementation gap")
        self.assertEqual(len(product["remediationTasks"]), 1)
        task = product["remediationTasks"][0]
        self.assertEqual(task["files"], ["feature.py"])
        self.assertEqual(task["verify"], "sh verify.sh")
        self.assertEqual(task["criteria"], ["AC-1"])
        self.assertEqual(task["repo"], "repo")
        assert_product_holds(self, self.store, self.paths, self.repo, "verify", product)

    def test_a_blocked_verdict_exits_blocked(self):
        product = self._run_pass(_verifier_result([_verdict("AC-1", "blocked")]))
        self.assertEqual(product["exit"], "blocked")
        assert_product_holds(self, self.store, self.paths, self.repo, "verify", product, check_boundary=False)

    def test_plan_gap_flag_overrides_a_fail(self):
        product = self._run_pass(_verifier_result([_verdict("AC-1", "fail")], plan_gap=True))
        self.assertEqual(product["exit"], "plan gap")
        assert_product_holds(self, self.store, self.paths, self.repo, "verify", product, check_boundary=False)

    def test_gap_flags_need_a_failing_verdict(self):
        # LF-45: a flag with every verdict passing is a note (often a criterion
        # an evidenceExceptions entry already covers), never a route.
        product = self._run_pass(_verifier_result([_verdict("AC-1", "pass")], plan_gap=True))
        self.assertEqual(product["exit"], "passed")
        events_text = self.paths.events_jsonl.read_text()
        self.assertIn('"verify_gap_flag_ignored"', events_text)
        self.assertIn('"planGap": true', events_text)
        assert_product_holds(self, self.store, self.paths, self.repo, "verify", product)

    def test_intent_gap_flag_with_a_failing_verdict_routes(self):
        product = self._run_pass(_verifier_result([_verdict("AC-1", "fail")], intent_gap=True))
        self.assertEqual(product["exit"], "intent gap")
        assert_product_holds(self, self.store, self.paths, self.repo, "verify", product, check_boundary=False)

    def test_verifier_step_carries_evidence_exceptions(self):
        plan_product = self.store.state["products"]["plan"]["product"]
        plan_product["evidenceExceptions"] = [{"criterion": "AC-1", "reason": "flaky in CI"}]
        self.store.save()
        action = step(self.store, self.paths, self.ctx)
        self.assertIn("### evidenceExceptions", action.request["prompt"])
        self.assertIn("AC-1", action.request["prompt"])

    def test_reviewer_findings_get_fresh_ids(self):
        finding = {"id": "whatever-the-reviewer-said", "location": "feature.py:1", "cause": "x",
                   "severity": "Minor", "disposition": "open", "reason": None, "supersedes": None}
        product = self._run_pass(_verifier_result([_verdict("AC-1", "pass")]), reviewer_findings=[finding])
        self.assertEqual(len(product["findings"]), 1)
        self.assertNotEqual(product["findings"][0]["id"], "whatever-the-reviewer-said")
        self.assertTrue(product["findings"][0]["id"].startswith("finding-"))
        self.assertEqual(product["findings"][0]["repo"], "repo")
        assert_product_holds(self, self.store, self.paths, self.repo, "verify", product)

    def test_reviewer_repeats_an_open_ledger_finding_and_keeps_its_id(self):
        self.store.state["ledger"]["findings"] = [{
            "id": "finding-known", "repo": "repo", "location": "feature.py:1", "cause": "x",
            "severity": "Minor", "disposition": "open", "reason": None, "supersedes": None,
            "sha": self.head_sha, "rangeId": "range-0",
        }]
        self.store.save()
        finding = {"id": "finding-known", "location": "feature.py:1", "cause": "x",
                   "severity": "Minor", "disposition": "open", "reason": None, "supersedes": None}
        product = self._run_pass(_verifier_result([_verdict("AC-1", "pass")]), reviewer_findings=[finding])
        self.assertEqual(len(product["findings"]), 1)
        self.assertEqual(product["findings"][0]["id"], "finding-known")

    def test_reviewer_echoes_a_closed_ledger_finding_and_it_is_dropped(self):
        self.store.state["ledger"]["findings"] = [{
            "id": "finding-known", "repo": "repo", "location": "feature.py:1", "cause": "x",
            "severity": "Minor", "disposition": "fixed", "reason": "patched",
            "supersedes": None, "sha": self.head_sha, "rangeId": "range-0",
        }]
        self.store.save()
        finding = {"id": "finding-known", "location": "feature.py:1", "cause": "x",
                   "severity": "Minor", "disposition": "fixed", "reason": "patched", "supersedes": None}
        product = self._run_pass(_verifier_result([_verdict("AC-1", "pass")]), reviewer_findings=[finding])
        self.assertEqual(product["findings"], [])
        events_text = self.paths.events_jsonl.read_text()
        self.assertIn('"finding_echo_ignored"', events_text)

    def test_reviewer_reopens_a_closed_ledger_finding_with_a_fresh_id(self):
        self.store.state["ledger"]["findings"] = [{
            "id": "finding-known", "repo": "repo", "location": "feature.py:1", "cause": "x",
            "severity": "Minor", "disposition": "fixed", "reason": "patched",
            "supersedes": None, "sha": self.head_sha, "rangeId": "range-0",
        }]
        self.store.save()
        finding = {"id": "finding-known", "location": "feature.py:1", "cause": "x",
                   "severity": "Minor", "disposition": "open", "reason": None,
                   "supersedes": {"kind": "finding", "id": "finding-known"}}
        product = self._run_pass(_verifier_result([_verdict("AC-1", "pass")]), reviewer_findings=[finding])
        self.assertEqual(len(product["findings"]), 1)
        self.assertNotEqual(product["findings"][0]["id"], "finding-known")
        self.assertTrue(product["findings"][0]["id"].startswith("finding-"))

    def test_legacy_verify_state_reinitializes_and_emits_module_state_reset(self):
        # A run whose state.verify predates the per-repo shape (LF-28) has no
        # "reviewers" key at all; a hand-built dict in that old shape stands in
        # for one such old run and must not KeyError on resume.
        self.store.state["verify"] = {
            "head": self.base_sha, "range": {"from": self.base_sha, "to": self.head_sha, "full": True},
            "rangeProbes": {}, "phase": "verifying",
            "verifierStep": None, "reviewerStep": None, "verifier": None, "reviewer": None,
            "pass": 1,
        }
        self.store.save()

        action = step(self.store, self.paths, self.ctx)

        self.assertIsInstance(action, IssueStep)
        self.assertEqual(action.request["role"], "verifier")
        self.assertIn("reviewers", self.store.state["verify"])
        events_text = self.paths.events_jsonl.read_text()
        self.assertIn('"module_state_reset"', events_text)
        self.assertIn("reviewers", events_text)

    def test_v4_rejection_reissues_the_verifier_and_does_not_reclear_within_the_same_attempt(self):
        # LF-30: a bare-interpreter evidence command re-ran differently in the
        # program's clean checkout (V4); the verifier must be re-issued with the
        # failure as its reason, not silently replay the same rejected product.
        self._run_pass(_verifier_result([_verdict("AC-1", "pass")]))
        last_verifier_step = self.store.state["verify"]["verifierStep"]

        rejection_ctx = self.ctx | {
            "attempt": {"id": "attempt-2"},
            "entry": {"mode": "remediation", "payload": {"rejected": {
                "exit": "passed",
                "failures": [{"id": "V4", "message": "criterion AC-1: no matching re-run recorded"}],
            }}},
        }
        action = step(self.store, self.paths, rejection_ctx)
        self.assertIsInstance(action, IssueStep)
        self.assertEqual(action.request["role"], "verifier")
        self.assertEqual(action.request["retryOf"], last_verifier_step)
        self.assertIn("AC-1", action.request["reason"])
        self.assertIsNone(self.store.state["verify"]["verifier"])

        # A later step() call in this same attempt must not re-clear: simulate a
        # re-invocation after a fresh result already landed some other way.
        sentinel = _verifier_result([_verdict("AC-1", "pass")])
        self.store.state["verify"]["verifier"] = sentinel
        self.store.state["verify"]["phase"] = "done"
        action = step(self.store, self.paths, rejection_ctx)
        self.assertIsInstance(action, Product)
        self.assertEqual(self.store.state["verify"]["verifier"], sentinel)


class WorkspaceVerifyTests(unittest.TestCase):
    """LF-28: a workspace run with two touched repos -- one clean checkout and one
    reviewer step per repo, evidence and findings naming the repo they belong to,
    an untouched third repo getting neither."""

    def _repo(self, name):
        repo = self.tmp / name
        repo.mkdir()
        _git(repo, "init", "-q", "-b", "main")
        _git(repo, "config", "user.name", "Test")
        _git(repo, "config", "user.email", "test@example.com")
        Path(repo, "verify.sh").write_text("#!/bin/sh\nexit 0\n")
        _git(repo, "add", "verify.sh")
        _git(repo, "commit", "-q", "-m", "init")
        base_sha = _head(repo)
        Path(repo, f"{name}.py").write_text("x = 1\n")
        _git(repo, "add", f"{name}.py")
        _git(repo, "commit", "-q", "-m", "feature")
        return repo, base_sha, _head(repo)

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.calc, self.calc_base, self.calc_head = self._repo("calc")
        self.textutil, self.textutil_base, self.textutil_head = self._repo("textutil")
        self.untouched, self.untouched_base, _ = self._repo("untouched")

        self.paths = FeaturePaths(root=self.tmp / "run")
        self.store = StateStore.create(self.paths, {"id": "run-1"}, "add calc and textutil helpers")
        self.store.state["repos"] = {
            "calc": {"path": str(self.calc), "baseSha": self.calc_base, "featureBranch": "feature",
                     "defaultBranch": "main", "lastKnownHead": self.calc_head},
            "textutil": {"path": str(self.textutil), "baseSha": self.textutil_base, "featureBranch": "feature",
                         "defaultBranch": "main", "lastKnownHead": self.textutil_head},
            "untouched": {"path": str(self.untouched), "baseSha": self.untouched_base, "featureBranch": "feature",
                          "defaultBranch": "main", "lastKnownHead": self.untouched_base},
        }
        self.store.state["products"]["spec"] = {"exit": "approved", "product": {
            "criteria": [{"id": "AC-1", "text": "calc works"}, {"id": "AC-2", "text": "textutil works"}],
        }}
        self.store.state["products"]["plan"] = {"exit": "ready", "product": {
            "tasks": [
                {"id": "T-1", "title": "T-1", "dependsOn": [], "files": ["calc.py"], "repo": "calc",
                 "verify": "sh verify.sh", "criteria": ["AC-1"], "featureAdded": None, "mustFlip": False},
                {"id": "T-2", "title": "T-2", "dependsOn": [], "files": ["textutil.py"], "repo": "textutil",
                 "verify": "sh verify.sh", "criteria": ["AC-2"], "featureAdded": None, "mustFlip": False},
            ],
            "prepare": None, "evidenceExceptions": [],
        }}
        self.store.state["products"]["execute"] = {"exit": "integrated", "product": {"heads": {
            "calc": self.calc_head, "textutil": self.textutil_head, "untouched": self.untouched_base,
        }}}
        self.store.save()

        self.ctx = {"attempt": {"id": "attempt-1"}, "inputs": {"digest": "sha256:" + "a" * 64},
                    "paths": {"projectRoot": str(self.calc)}, "entry": {"mode": "fresh", "payload": None},
                    "probes": {}}

    def tearDown(self):
        self._tmp.cleanup()

    def _run_full_pass(self):
        """One verifier step (both criteria pass), then one reviewer step per
        touched repo -- the shared setup the untouched-repo test and the V7
        reviewer-retry test both need before their own assertions."""
        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, IssueStep)
        self.assertEqual(action.request["role"], "verifier")
        verifier_result = _verifier_result([_verdict("AC-1", "pass"), _verdict("AC-2", "pass")])
        # V3/V4 need each criterion's own repo's real head and a matching re-run
        # record -- see VerifyTests._run_pass for why (controller.py settles both
        # for a real run; this helper drives verify.step/on_submit directly).
        head_by_criterion = {"AC-1": self.calc_head, "AC-2": self.textutil_head}
        for v in verifier_result["verdicts"]:
            v["evidence"]["sha"] = head_by_criterion[v["criterion"]]
            self.store.state.setdefault("verifyRuns", {})[v["criterion"]] = {"matched": True}
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "v-step"}, verifier_result)

        seen_repos = []
        for _ in range(2):
            action = step(self.store, self.paths, self.ctx)
            self.assertIsInstance(action, IssueStep)
            self.assertEqual(action.request["role"], "code-reviewer")
            repo_name = next(name for name, r in self.store.state["verify"]["ranges"].items()
                              if action.request["cwd"] == self.store.state["verify"]["checkouts"][name])
            seen_repos.append(repo_name)
            range_ = self.store.state["verify"]["ranges"][repo_name]
            reviewer_result = {"sha": range_["to"], "reviewedRange": {"from": range_["from"], "to": range_["to"]},
                                "verdict": "pass", "findings": [], "securityDispositions": []}
            on_submit(self.store, self.paths, action.request | {"stepAttemptId": f"r-{repo_name}"}, reviewer_result)
        return seen_repos

    def test_two_touched_repos_get_one_reviewer_step_each_and_the_untouched_one_gets_none(self):
        seen_repos = self._run_full_pass()

        self.assertEqual(set(seen_repos), {"calc", "textutil"})
        self.assertNotIn("untouched", self.store.state["verify"]["checkouts"])

        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, Product)
        product = action.product
        self.assertEqual({r["repo"] for r in product["reviewedRanges"]}, {"calc", "textutil"})
        evidence_by_criterion = {v["criterion"]: v["evidence"]["repo"] for v in product["verdicts"]}
        self.assertEqual(evidence_by_criterion, {"AC-1": "calc", "AC-2": "textutil"})
        assert_product_holds(self, self.store, self.paths, self.calc, "verify", product)

    def test_v7_rejection_reissues_only_the_named_repos_reviewer_step(self):
        # LF-30: the message names its repo ("repo textutil: ..."); only that
        # repo's reviewer is reset and re-issued, calc's own result stays.
        self._run_full_pass()
        calc_reviewer = self.store.state["verify"]["reviewers"]["calc"]
        last_textutil_step = self.store.state["verify"]["reviewerSteps"]["textutil"]

        rejection_ctx = self.ctx | {
            "attempt": {"id": "attempt-2"},
            "entry": {"mode": "remediation", "payload": {"rejected": {
                "exit": "passed",
                "failures": [{"id": "V7", "message": "repo textutil: reviewed range does not continue from the last reviewed SHA"}],
            }}},
        }
        action = step(self.store, self.paths, rejection_ctx)

        self.assertIsInstance(action, IssueStep)
        self.assertEqual(action.request["role"], "code-reviewer")
        self.assertEqual(action.request["retryOf"], last_textutil_step)
        self.assertIn("textutil", action.request["reason"])
        self.assertNotIn("textutil", self.store.state["verify"]["reviewers"])
        self.assertEqual(self.store.state["verify"]["reviewers"]["calc"], calc_reviewer)


if __name__ == "__main__":
    unittest.main()
