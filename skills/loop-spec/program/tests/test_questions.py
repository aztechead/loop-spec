"""Unit tests for loop_spec.questions: ask/answer, retirement, and default policy."""
import tempfile
import unittest
from pathlib import Path

from loop_spec import questions
from loop_spec.errors import LoopSpecError
from loop_spec.paths import FeaturePaths
from loop_spec.state import StateStore


class QuestionsTests(unittest.TestCase):
    def _store(self, tmp) -> tuple[StateStore, FeaturePaths]:
        paths = FeaturePaths(root=Path(tmp) / "feature")
        store = StateStore.create(paths, {"id": "run-1", "entry": "cycle"}, "do the thing")
        return store, paths

    def _ask(self, store, paths, **overrides):
        kwargs = dict(
            phase="spec", attempt_id="attempt-1", text="proceed?", kind="approval",
            options=[{"value": "approve", "label": "Approve"}], default_value="approve", payload=None,
        )
        kwargs.update(overrides)
        return questions.ask(store, paths, **kwargs)

    def test_ask_refuses_a_second_open(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            self._ask(store, paths)
            with self.assertRaises(LoopSpecError):
                self._ask(store, paths)

    def test_answer_retired_id_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            record = self._ask(store, paths)
            questions.answer(store, paths, question_id=record["questionId"], value="approve")
            with self.assertRaises(LoopSpecError):
                questions.answer(store, paths, question_id=record["questionId"], value="approve")

    def test_answer_wrong_id_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            self._ask(store, paths)
            with self.assertRaises(LoopSpecError):
                questions.answer(store, paths, question_id="question-bogus", value="approve")

    def test_run_scope_sets_policy(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            record = self._ask(store, paths)
            questions.answer(store, paths, question_id=record["questionId"], value="approve", scope="run")
            self.assertEqual(store.state["questions"]["policy"], "default")

    def test_policy_answers_a_defaulted_question_and_lists_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            store.state["questions"]["policy"] = "default"
            record = self._ask(store, paths, default_value="approve")  # LF-62: ask applies the policy itself
            resolved = store.state["questions"]["answered"][record["questionId"]]
            self.assertEqual((resolved["value"], resolved["by"]), ("approve", "policy"))
            self.assertEqual(store.state["questions"]["policyAnswered"], [record["questionId"]])
            self.assertIsNone(store.state["questions"]["open"])

    def test_without_the_default_policy_a_defaulted_question_stays_open(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            record = self._ask(store, paths, default_value="approve")
            self.assertEqual(store.state["questions"]["open"]["questionId"], record["questionId"])
            self.assertEqual(store.state["questions"]["policyAnswered"], [])

    def test_a_deferred_ask_writes_no_state_even_when_the_policy_answers(self):
        # LF-62: save=False defers the policy answer too; the caller links and saves once.
        from loop_spec.state import StateStore
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            store.state["questions"]["policy"] = "default"
            store.save()
            record = questions.ask(store, paths, phase="plan", attempt_id="a-1", text="?", kind="text",
                                   options=[], default_value="spec gap", payload=None, save=False)
            on_disk = StateStore.open(paths).state["questions"]
            self.assertEqual((on_disk["open"], on_disk["answered"], on_disk["policyAnswered"]), (None, {}, []))
            self.assertEqual(store.state["questions"]["answered"][record["questionId"]]["by"], "policy")

    def test_policy_leaves_an_undefaulted_question_open(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            store.state["questions"]["policy"] = "default"
            record = self._ask(store, paths, default_value=None)
            resolved = questions.resolve_policy_answer(store, paths, record)
            self.assertIsNone(resolved)
            self.assertIsNotNone(store.state["questions"]["open"])


if __name__ == "__main__":
    unittest.main()
