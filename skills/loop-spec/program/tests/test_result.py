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
        table = {
            "converged": {"status": "completed", "outcome": "delivered", "converged": True, "workDelivered": True},
            "converged-with-caveats": {"status": "completed", "outcome": "delivered-draft", "converged": True, "workDelivered": True},
            "no-change": {"status": "completed", "outcome": "no-change-needed", "converged": True, "workDelivered": False},
            "escalated": {"status": "escalated", "outcome": "escalated", "converged": False, "workDelivered": False},
            "failed": {"status": "failed", "outcome": "failed", "converged": False, "workDelivered": False},
        }
        for classification, expected in table.items():
            with self.subTest(classification=classification):
                store, paths = _new_run(self.tmp / classification, classification, "deliver")
                path = result_module.write(store, paths, classification, reason="because")
                record = read_json(path)
                self.assertEqual(record["status"], expected["status"])
                self.assertEqual(record["outcome"], expected["outcome"])
                self.assertEqual(record["converged"], expected["converged"])
                self.assertEqual(record["workDelivered"], expected["workDelivered"])
                self.assertEqual(record["result"], classification)
                self.assertEqual(record["reason"], "because")
                self.assertEqual(record["noChangeReason"], "already-satisfied" if classification == "no-change" else None)
                self.assertEqual(record["retryable"], classification == "failed")
                self.assertEqual(store.state["result"]["classification"], classification)

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
