"""Unit tests for loop_spec.budget: the backward-transition progress rule (T1, T2)."""
import tempfile
import unittest
from pathlib import Path

from loop_spec import budget
from loop_spec.paths import FeaturePaths
from loop_spec.state import StateStore


def _store(tmp) -> StateStore:
    paths = FeaturePaths(root=Path(tmp) / "feature")
    return StateStore.create(paths, {"id": "run-1", "entry": "cycle"}, "do the thing")


def _spend(store, n, exit="plan gap", frm="verify", cause="c", fp="f"):
    return budget.spend(store, from_phase=frm, exit=exit, to_phase="plan", attempt_id=f"attempt-{n}",
                        reason="gap", cause=cause, fingerprint=fp)


class RepeatOfTests(unittest.TestCase):
    def test_a_new_cause_never_repeats_however_many_came_before(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = _store(tmp)
            for n in range(6):
                self.assertIsNone(budget.repeat_of(store, "verify", "plan gap", f"cause-{n}", f"fp-{n}"))
                _spend(store, n, cause=f"cause-{n}", fp=f"fp-{n}")

    def test_same_cause_on_a_changed_state_recurred(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = _store(tmp)
            _spend(store, 1)
            self.assertEqual(budget.repeat_of(store, "verify", "plan gap", "c", "other"), "recurred")

    def test_same_state_is_identical_whatever_the_cause(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = _store(tmp)
            _spend(store, 1)
            self.assertEqual(budget.repeat_of(store, "verify", "plan gap", "c", "f"), "identical")
            self.assertEqual(budget.repeat_of(store, "verify", "plan gap", "reworded", "f"), "identical")
            self.assertIsNone(budget.repeat_of(store, "verify", "intent gap", "c", "f"))  # another exit

    def test_a_transition_recorded_without_cause_or_fingerprint_never_matches(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = _store(tmp)
            store.state["budget"]["transitions"].append(
                {"from": "verify", "exit": "plan gap", "to": "plan", "attemptId": "a", "reason": "gap", "at": "t"})
            self.assertIsNone(budget.repeat_of(store, "verify", "plan gap", "c", "f"))


class SpendTests(unittest.TestCase):
    def test_idempotent_replay_of_same_attempt_and_exit(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = _store(tmp)
            first = _spend(store, 1, exit="spec gap", frm="plan")
            second = _spend(store, 1, exit="spec gap", frm="plan")
            self.assertEqual(first, second)
            self.assertEqual(len(store.state["budget"]["transitions"]), 1)

    def test_transitions_record_cause_and_fingerprint(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = _store(tmp)
            record = _spend(store, 1, exit="spec gap", frm="plan", cause="x", fp="y")
            self.assertEqual(store.state["budget"]["transitions"], [record])
            self.assertEqual((record["from"], record["to"], record["cause"], record["fingerprint"]), ("plan", "plan", "x", "y"))

    def test_base_moves_count_to_their_limit_and_restart_after_the_operator_continues(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = _store(tmp)
            for n in range(budget.BASE_MOVE_LIMIT):
                self.assertTrue(budget.base_move_room(store))
                _spend(store, n, exit="base moved", frm="deliver", cause=None, fp=None)
            self.assertFalse(budget.base_move_room(store))
            store.state["budget"]["baseMovesContinuedAt"] = len(store.state["budget"]["transitions"])
            self.assertTrue(budget.base_move_room(store))
            self.assertEqual(budget.base_moves(store), 0)


if __name__ == "__main__":
    unittest.main()
