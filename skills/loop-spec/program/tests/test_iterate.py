"""Unit tests for loop_spec.iterate: the exit-choice table."""
import subprocess
import tempfile
import unittest
from pathlib import Path

from loop_spec.execute import IssueStep, Product
from loop_spec.iterate import on_submit, step
from loop_spec.paths import FeaturePaths
from loop_spec.state import StateStore

from tests._product_checks import assert_product_holds


# simplicity: _git/_init_repo repeat test_repo.py's, test_baseline.py's, and
# test_execute.py's own copies verbatim; there is no shared test-fixture module
# in this tree yet, and adding one is a cross-file change outside this file's
# own scope.
def _git(cwd, *args):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True)


def _head(cwd):
    return subprocess.run(["git", "rev-parse", "HEAD"], cwd=cwd, capture_output=True, text=True, check=True).stdout.strip()


def _finding(finding_id, severity, disposition):
    return {"id": finding_id, "location": "a.py:1", "cause": "x", "severity": severity,
            "disposition": disposition, "reason": "because", "supersedes": None}


class IterateTests(unittest.TestCase):
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
        Path(self.repo, "a.py").write_text("x = 1\n")
        _git(self.repo, "add", "a.py")
        _git(self.repo, "commit", "-q", "-m", "init")
        self.base_sha = _head(self.repo)
        # LF-28: a repo with no commits since base is untouched (no checkout, no
        # reviewer step); this fixture is a genuinely touched repo, like a real
        # integrated run.
        Path(self.repo, "b.py").write_text("y = 1\n")
        _git(self.repo, "add", "b.py")
        _git(self.repo, "commit", "-q", "-m", "feature")
        self.head_sha = _head(self.repo)

        self.paths = FeaturePaths(root=self.tmp / "run")
        self.store = StateStore.create(self.paths, {"id": "run-1"}, "add a widget")
        # simplicity: this single-repo state.repos entry repeats test_verify.py's
        # fixture; no shared test-fixture module exists in this tree yet.
        self.store.state["repos"] = {"repo": {"path": str(self.repo), "baseSha": self.base_sha,
                                               "featureBranch": "feature", "defaultBranch": "main",
                                               "lastKnownHead": self.head_sha}}
        self.store.state["products"]["execute"] = {"exit": "integrated", "product": {"heads": {"repo": self.head_sha}}}
        self.store.state["products"]["spec"] = {"exit": "approved", "product": {"criteria": [{"id": "AC-1", "text": "it works"}]}}
        self.store.state["products"]["verify"] = {"exit": "passed", "product": {"verdicts": []}}
        self.checkout = self.paths.checkouts_dir / f"verify-{self.head_sha[:12]}"
        self.checkout.mkdir(parents=True)
        self.store.save()

        self.ctx = {"attempt": {"id": "attempt-1"}, "inputs": {"digest": "sha256:" + "a" * 64},
                    "paths": {"projectRoot": str(self.repo)}, "entry": {"mode": "fresh", "payload": None},
                    "probes": {}}

    def tearDown(self):
        self._tmp.cleanup()

    def _judge_result(self, verdict, gaps):
        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, IssueStep)
        result = {"verdict": verdict, "gaps": gaps, "caveats": []}
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "step-1"}, result)
        return step(self.store, self.paths, self.ctx)

    def test_met_with_no_open_finding_converges(self):
        action = self._judge_result("met", [])
        self.assertIsInstance(action, Product)
        self.assertEqual(action.product["exit"], "converged")
        self.assertEqual(action.product["boundShas"], {"repo": self.head_sha})
        assert_product_holds(self, self.store, self.paths, self.repo, "iterate", action.product)

    def test_met_with_accepted_finding_converges_with_caveats(self):
        self.store.state["ledger"]["findings"] = [_finding("F-1", "Minor", "deferred")]
        action = self._judge_result("met", [])
        self.assertEqual(action.product["exit"], "converged with caveats")
        self.assertEqual(action.product["caveats"], ["F-1"])
        assert_product_holds(self, self.store, self.paths, self.repo, "iterate", action.product)

    def test_met_with_critical_open_finding_and_budget_room_rewinds(self):
        # A "met" verdict over an open Critical finding is reconciled to "unmet"
        # with a synthesized gap (_final_product) before the four exit rules ever
        # see it, so it rewinds like any other unmet verdict with a routable gap.
        self.store.state["ledger"]["findings"] = [_finding("F-1", "Critical", "open")]
        action = self._judge_result("met", [])
        self.assertEqual(action.product["exit"], "rewind")
        self.assertEqual(action.product["verdict"], "unmet")
        self.assertEqual(action.product["gaps"], [{"target": "execute", "text": "open finding F-1 (Critical): x"}])
        assert_product_holds(self, self.store, self.paths, self.repo, "iterate", action.product)

    def test_met_with_critical_open_finding_and_no_budget_room_escalates(self):
        self.store.state["ledger"]["findings"] = [_finding("F-1", "Critical", "open")]
        self.store.state["budget"]["spent"] = self.store.state["budget"]["limit"]
        self.store.save()
        action = self._judge_result("met", [])
        self.assertEqual(action.product["exit"], "escalated")
        self.assertEqual(action.product["verdict"], "unmet")
        assert_product_holds(self, self.store, self.paths, self.repo, "iterate", action.product)

    def test_met_with_minor_open_finding_converges_with_caveats_and_defers_it(self):
        # LF-46: nobody used to disposition a non-Critical open finding, so it
        # forced "unmet" forever. The program now defers a Minor one itself.
        self.store.state["ledger"]["findings"] = [_finding("F-1", "Minor", "open")]
        action = self._judge_result("met", [])
        self.assertEqual(action.product["exit"], "converged with caveats")
        self.assertEqual(action.product["caveats"], ["F-1"])
        finding = self.store.state["ledger"]["findings"][0]
        self.assertEqual(finding["disposition"], "deferred")
        self.assertEqual(finding["reason"], "left open at ITERATE; deferred by policy")
        assert_product_holds(self, self.store, self.paths, self.repo, "iterate", action.product)

    def test_met_with_important_open_finding_and_budget_room_rewinds_to_plan(self):
        self.store.state["ledger"]["findings"] = [_finding("F-1", "Important", "open")]
        action = self._judge_result("met", [])
        self.assertEqual(action.product["exit"], "rewind")
        self.assertEqual(action.product["verdict"], "unmet")
        self.assertEqual(action.product["gaps"], [{"target": "plan", "text": "open finding F-1 (Important) at a.py:1: x"}])
        # A gap that routes it, not a disposition -- Important-with-room is not
        # deferred; it stays open until PLAN's remediation closes it.
        self.assertEqual(self.store.state["ledger"]["findings"][0]["disposition"], "open")
        assert_product_holds(self, self.store, self.paths, self.repo, "iterate", action.product)

    def test_met_with_important_open_finding_and_no_budget_room_defers_and_converges_with_caveats(self):
        self.store.state["ledger"]["findings"] = [_finding("F-1", "Important", "open")]
        self.store.state["budget"]["spent"] = self.store.state["budget"]["limit"]
        self.store.save()
        action = self._judge_result("met", [])
        self.assertEqual(action.product["exit"], "converged with caveats")
        self.assertEqual(action.product["caveats"], ["F-1"])
        finding = self.store.state["ledger"]["findings"][0]
        self.assertEqual(finding["disposition"], "deferred")
        self.assertEqual(finding["reason"], "left open at ITERATE; deferred by policy")
        assert_product_holds(self, self.store, self.paths, self.repo, "iterate", action.product)

    def test_unmet_with_no_gaps_escalates_and_holds_i4(self):
        action = self._judge_result("unmet", [])
        self.assertEqual(action.product["exit"], "escalated")
        assert_product_holds(self, self.store, self.paths, self.repo, "iterate", action.product)

    def test_unmet_with_gaps_and_budget_room_rewinds(self):
        action = self._judge_result("unmet", [{"target": "plan", "text": "missing a case"}])
        self.assertEqual(action.product["exit"], "rewind")
        assert_product_holds(self, self.store, self.paths, self.repo, "iterate", action.product)

    def test_unmet_without_budget_room_escalates(self):
        self.store.state["budget"]["spent"] = self.store.state["budget"]["limit"]
        self.store.save()
        action = self._judge_result("unmet", [{"target": "plan", "text": "missing a case"}])
        self.assertEqual(action.product["exit"], "escalated")
        assert_product_holds(self, self.store, self.paths, self.repo, "iterate", action.product)

    def test_prior_gaps_accumulate_across_a_rewind_and_a_new_head(self):
        self._judge_result("unmet", [{"target": "plan", "text": "first gap"}])
        self.assertEqual(self.store.state["iterate"]["priorGaps"], [{"target": "plan", "text": "first gap"}])

        # A rewind moves the run elsewhere and back; VERIFY produces a new head, and
        # ITERATE must issue a fresh judge call rather than replaying the old result.
        Path(self.repo, "c.py").write_text("z = 3\n")
        _git(self.repo, "add", "c.py")
        _git(self.repo, "commit", "-q", "-m", "second")
        new_head = _head(self.repo)
        self.store.state["products"]["execute"]["product"]["heads"]["repo"] = new_head
        (self.paths.checkouts_dir / f"verify-{new_head[:12]}").mkdir(parents=True, exist_ok=True)
        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, IssueStep)

    def test_legacy_iterate_state_reinitializes_and_emits_module_state_reset(self):
        # A run whose state.iterate predates the per-repo shape (LF-28) has
        # "boundSha" (singular) instead of "boundShas"; a hand-built dict in that
        # old shape stands in for one such old run and must not KeyError on
        # resume, and priorGaps (unaffected by the rename) survives the reset.
        self.store.state["iterate"] = {
            "priorGaps": [{"target": "plan", "text": "an earlier gap"}],
            "judgeStep": "step-old", "judge": {"verdict": "met", "gaps": [], "caveats": []},
            "boundSha": self.head_sha,
        }
        self.store.save()

        action = step(self.store, self.paths, self.ctx)

        self.assertIsInstance(action, IssueStep)
        self.assertEqual(self.store.state["iterate"]["priorGaps"], [{"target": "plan", "text": "an earlier gap"}])
        self.assertIn("boundShas", self.store.state["iterate"])
        events_text = self.paths.events_jsonl.read_text()
        self.assertIn('"module_state_reset"', events_text)
        self.assertIn("boundShas", events_text)


if __name__ == "__main__":
    unittest.main()
