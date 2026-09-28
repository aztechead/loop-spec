"""Unit tests for loop_spec.budget: the shared rewind budget (T1)."""
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from loop_spec import budget
from loop_spec.paths import FeaturePaths
from loop_spec.state import StateStore


def _store(tmp) -> StateStore:
    paths = FeaturePaths(root=Path(tmp) / "feature")
    return StateStore.create(paths, {"id": "run-1", "entry": "cycle"}, "do the thing")


class BudgetTests(unittest.TestCase):
    def test_default_limit_is_two(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict("os.environ", {}, clear=True):
            self.assertEqual(budget.limit(_store(tmp)), 2)

    def test_env_override(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict("os.environ", {"LOOP_SPEC_REWIND_BUDGET": "5"}, clear=True):
            self.assertEqual(budget.limit(_store(tmp)), 5)

    def test_spend_twice_then_raise(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict("os.environ", {}, clear=True):
            store = _store(tmp)
            budget.spend(store, from_phase="plan", exit="spec gap", to_phase="spec", attempt_id="attempt-1", reason="gap")
            budget.spend(store, from_phase="verify", exit="plan gap", to_phase="plan", attempt_id="attempt-2", reason="gap")
            self.assertFalse(budget.has_room(store))
            with self.assertRaises(budget.BudgetExhausted):
                budget.spend(store, from_phase="verify", exit="plan gap", to_phase="plan", attempt_id="attempt-3", reason="gap")

    def test_idempotent_replay_of_same_attempt_and_exit(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict("os.environ", {}, clear=True):
            store = _store(tmp)
            first = budget.spend(store, from_phase="plan", exit="spec gap", to_phase="spec", attempt_id="attempt-1", reason="gap")
            second = budget.spend(store, from_phase="plan", exit="spec gap", to_phase="spec", attempt_id="attempt-1", reason="gap")
            self.assertEqual(first, second)
            self.assertEqual(store.state["budget"]["spent"], 1)

    def test_transitions_recorded(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict("os.environ", {}, clear=True):
            store = _store(tmp)
            record = budget.spend(store, from_phase="plan", exit="spec gap", to_phase="spec", attempt_id="attempt-1", reason="gap")
            self.assertEqual(store.state["budget"]["transitions"], [record])
            self.assertEqual(record["from"], "plan")
            self.assertEqual(record["to"], "spec")


if __name__ == "__main__":
    unittest.main()
