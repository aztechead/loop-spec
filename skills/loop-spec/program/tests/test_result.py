"""Unit tests for loop_spec.result: the terminal record's field table per
classification, the last-result copy rule, and paused's non-terminal state."""
import contextlib
import io
import tempfile
import unittest
from pathlib import Path

from loop_spec import result as result_module
from loop_spec.jsonio import read_json
from loop_spec.paths import FeaturePaths
from loop_spec.state import StateStore

_RUN_FIELDS = {"id": "run-1", "entry": "cycle", "cycleType": "full", "createdAt": "2026-01-01T00:00:00+00:00"}


def _new_run(root: Path, slug: str, phase: str, request_text: str = "greet the user"):
    paths = FeaturePaths(root=root)
    store = StateStore.create(paths, dict(_RUN_FIELDS, slug=slug), request_text)
    store.state["phase"]["current"] = phase
    store.save()
    return store, paths


def _pr(number: int) -> dict:
    return {"number": number, "url": f"https://example/pull/{number}", "headRef": "feature"}


def _verify_passed(store) -> None:
    # R7: verification.status is read from this, not guessed from the classification
    # -- boundTo matches state["revisions"]'s all-None default untouched.
    store.state["products"]["verify"] = {"exit": "passed", "product": {"boundTo": {"requirements": None, "plan": None}}}


def _deliver(store, targets: list[dict]) -> None:
    store.state["products"]["deliver"] = {"product": {"repos": targets}}


class ResultTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        # result.write() prints a LOOP_SPEC_RESULT marker line on every call; keep it
        # out of the real test-runner output.
        redirect = contextlib.redirect_stdout(io.StringIO())
        redirect.__enter__()
        self.addCleanup(redirect.__exit__, None, None, None)

    def test_classification_field_table(self):
        # R7: per ROADMAP-7.0.md's schema-1 compatibility table (~line 713),
        # `converged` is true only for a result 6.9 would also call converged --
        # `converged-with-caveats` is a draft left for human sign-off, so it stays
        # false despite having delivered work. `workDelivered` and
        # `verification.status` are delivery/VERIFY facts, not classification
        # shortcuts, so each row sets up (or withholds) real DELIVER/VERIFY state.
        delivered_target = [{"repo": "repo", "state": "delivered", "pr": _pr(1), "deliveredSha": "a" * 40, "caveats": []}]
        table = {
            "converged": {"status": "completed", "outcome": "delivered", "converged": True,
                          "workDelivered": True, "verification": "passed",
                          "setup": lambda s: (_verify_passed(s), _deliver(s, delivered_target))},
            "converged-with-caveats": {"status": "completed", "outcome": "delivered-draft", "converged": False,
                                       "workDelivered": True, "verification": "passed",
                                       "setup": lambda s: (_verify_passed(s), _deliver(s, delivered_target))},
            "no-change": {"status": "completed", "outcome": "no-change-needed", "converged": True,
                          "workDelivered": False, "verification": "passed", "setup": _verify_passed},
            "escalated": {"status": "escalated", "outcome": "escalated", "converged": False,
                          "workDelivered": False, "verification": "not-run", "setup": lambda s: None},
            "failed": {"status": "failed", "outcome": "failed", "converged": False,
                       "workDelivered": False, "verification": "not-run", "setup": lambda s: None},
        }
        for classification, expected in table.items():
            with self.subTest(classification=classification):
                store, paths = _new_run(self.tmp / classification, classification, "deliver")
                expected["setup"](store)
                path = result_module.write(store, paths, classification, reason="because")
                record = read_json(path)
                self.assertEqual(record["status"], expected["status"])
                self.assertEqual(record["outcome"], expected["outcome"])
                self.assertEqual(record["converged"], expected["converged"])
                self.assertEqual(record["workDelivered"], expected["workDelivered"])
                self.assertEqual(record["verification"]["status"], expected["verification"])
                self.assertEqual(record["result"], classification)
                self.assertEqual(record["reason"], "because")
                self.assertEqual(record["noChangeReason"], "already-satisfied" if classification == "no-change" else None)
                self.assertEqual(record["retryable"], classification == "failed")
                self.assertEqual(store.state["result"]["classification"], classification)

    def test_escalated_partial_draft_delivers_one_of_two_targets(self):
        # A run that escalated in ITERATE but whose operator policy allowed a
        # partial draft: one repo actually reached "delivered", the other did not.
        # workDelivered reads true from that fact alone; `converged` stays false --
        # escalated is never a result 6.9 would call converged.
        store, paths = _new_run(self.tmp / "partial", "partial", "deliver")
        _verify_passed(store)
        _deliver(store, [
            {"repo": "repo-a", "state": "delivered", "pr": _pr(1), "deliveredSha": "a" * 40, "caveats": []},
            {"repo": "repo-b", "state": "failed", "pr": None, "deliveredSha": None, "caveats": ["credential check failed"]},
        ])
        record = read_json(result_module.write(store, paths, "escalated", reason="partial draft", partially_delivered=True))
        self.assertFalse(record["converged"])
        self.assertTrue(record["workDelivered"])
        self.assertEqual(record["verification"]["status"], "passed")
        self.assertTrue(record["partiallyDelivered"])

    def test_no_change_names_the_adopted_pr_it_found_already_done(self):
        # 7.4.1: a no-change run on an open PR is a success that names the PR (D6's
        # skipped row) and delivered nothing.
        store, paths = _new_run(self.tmp / "nochange", "nochange", "deliver")
        _verify_passed(store)
        _deliver(store, [{"repo": "repo", "state": "skipped", "pr": _pr(7), "deliveredSha": None, "caveats": []}])
        record = read_json(result_module.write(store, paths, "no-change"))
        self.assertEqual(record["prUrl"], "https://example/pull/7")
        self.assertEqual(record["outcome"], "no-change-needed")
        self.assertTrue(record["converged"])
        self.assertFalse(record["workDelivered"])

    def test_a_stop_after_one_repo_published_reports_partial_delivery(self):
        # LF-58: the stop path passes no flag; the per-repo facts decide. A skipped
        # (untouched) repo beside a delivered one is not partial.
        store, paths = _new_run(self.tmp / "stop", "stop", "deliver")
        _verify_passed(store)
        _deliver(store, [
            {"repo": "calc", "state": "delivered", "pr": _pr(13), "deliveredSha": "a" * 40, "caveats": []},
            {"repo": "textutil", "state": "failed", "pr": None, "deliveredSha": None, "caveats": ["push rejected"]},
        ])
        record = read_json(result_module.write(store, paths, "escalated", reason="deliver paused; operator chose 'stop'"))
        self.assertTrue(record["partiallyDelivered"])
        self.assertTrue(record["workDelivered"])
        store2, paths2 = _new_run(self.tmp / "skip", "skip", "deliver")
        _verify_passed(store2)
        _deliver(store2, [
            {"repo": "calc", "state": "delivered", "pr": _pr(1), "deliveredSha": "a" * 40, "caveats": []},
            {"repo": "docs", "state": "skipped", "pr": None, "deliveredSha": None, "caveats": []},
        ])
        self.assertFalse(read_json(result_module.write(store2, paths2, "converged"))["partiallyDelivered"])

    def test_verification_passed_but_delivery_blocked_delivers_nothing(self):
        # VERIFY passed and ITERATE converged, but DELIVER could not publish
        # anything (credentials failed, the operator answered stop) -- the run
        # still escalates, but that must not hide that VERIFY itself passed.
        store, paths = _new_run(self.tmp / "blocked", "blocked", "deliver")
        _verify_passed(store)
        _deliver(store, [{"repo": "repo", "state": "failed", "pr": None, "deliveredSha": None,
                           "caveats": ["gh credentials could not be refreshed"]}])
        record = read_json(result_module.write(store, paths, "escalated", reason="delivery blocked"))
        self.assertFalse(record["converged"])
        self.assertFalse(record["workDelivered"])
        self.assertEqual(record["verification"]["status"], "passed")

    def test_last_result_copy(self):
        store, paths = _new_run(self.tmp / "repo-id" / "feature-a", "a", "deliver")
        result_module.write(store, paths, "converged")
        self.assertTrue(paths.last_result_json.is_file())
        self.assertEqual(read_json(paths.last_result_json), read_json(paths.result_json))

    def test_paused_does_not_set_state_result_or_touch_last_result(self):
        # last-result.json is scoped to the repo-id directory (root.parent), shared by
        # every feature under it; a pause must leave a prior terminal run's copy alone.
        store_a, paths_a = _new_run(self.tmp / "repo-id" / "feature-a", "a", "deliver")
        result_module.write(store_a, paths_a, "converged")
        prior_last_result = read_json(paths_a.last_result_json)

        store_b, paths_b = _new_run(self.tmp / "repo-id" / "feature-b", "b", "verify")
        result_module.write(store_b, paths_b, "paused", reason="waiting on an operator answer")

        self.assertIsNone(store_b.state["result"])
        record = read_json(paths_b.result_json)
        self.assertEqual(record["status"], "paused")
        self.assertEqual(read_json(paths_b.last_result_json), prior_last_result)


if __name__ == "__main__":
    unittest.main()
