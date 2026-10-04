"""loop_spec.dag: graph problems, readiness, and waves."""
import unittest

from loop_spec import dag


def task(tid, *deps, criteria=()):
    return {"id": tid, "title": tid, "dependsOn": list(deps), "criteria": list(criteria)}


class ProblemsTests(unittest.TestCase):
    def test_a_sound_graph_has_none(self):
        self.assertEqual(dag.problems([task("T-1"), task("T-2", "T-1")]), [])

    def test_names_unknown_dependencies_duplicates_and_missing_ids(self):
        found = dag.problems([task("T-1", "T-9"), task("T-1"), {"title": "no id"}])
        self.assertIn("T-1 depends on T-9, which is not in the plan", found)
        self.assertIn("task id T-1 is used more than once", found)
        self.assertIn("task #3 has no id", found)

    def test_names_the_cycle(self):
        found = dag.problems([task("T-1", "T-3"), task("T-2", "T-1"), task("T-3", "T-2")])
        self.assertEqual(found, ["dependency cycle: T-1 -> T-3 -> T-2 -> T-1"])

    def test_a_self_dependency_is_a_cycle(self):
        self.assertEqual(dag.problems([task("T-1", "T-1")]), ["dependency cycle: T-1 -> T-1"])

    def test_an_empty_plan_is_a_problem(self):
        self.assertEqual(dag.problems([]), ["the plan has no tasks"])


class ReadyTests(unittest.TestCase):
    TASKS = [task("T-1"), task("T-2"), task("T-3", "T-1", "T-2")]

    def test_tasks_without_dependencies_start_ready(self):
        self.assertEqual([t["id"] for t in dag.ready(self.TASKS, {})], ["T-1", "T-2"])

    def test_a_task_is_ready_only_once_every_dependency_is_done(self):
        self.assertEqual([t["id"] for t in dag.ready(self.TASKS, {"T-1": "done", "T-2": "doing"})], [])
        self.assertEqual([t["id"] for t in dag.ready(self.TASKS, {"T-1": "done", "T-2": "done"})], ["T-3"])

    def test_waiting_on_names_the_unfinished_dependencies(self):
        self.assertEqual(dag.waiting_on(self.TASKS[2], {"T-1": "done"}), ["T-2"])

    def test_all_done_only_when_every_task_is(self):
        self.assertFalse(dag.all_done(self.TASKS, {"T-1": "done", "T-2": "done"}))
        self.assertTrue(dag.all_done(self.TASKS, {"T-1": "done", "T-2": "done", "T-3": "done"}))

    def test_uncovered_lists_criteria_no_task_names(self):
        criteria = [{"id": "AC-1"}, {"id": "AC-2"}]
        self.assertEqual(dag.uncovered(criteria, [task("T-1", criteria=["AC-1"])]), ["AC-2"])


if __name__ == "__main__":
    unittest.main()
