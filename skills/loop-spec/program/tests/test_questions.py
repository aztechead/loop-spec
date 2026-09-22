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
            record = self._ask(store, paths, default_value="approve")
            resolved = questions.resolve_policy_answer(store, paths, record)
            self.assertIsNotNone(resolved)
            self.assertEqual(resolved["value"], "approve")
            self.assertEqual(resolved["by"], "policy")
            self.assertIn(record["questionId"], store.state["questions"]["policyAnswered"])
            self.assertIsNone(store.state["questions"]["open"])

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
