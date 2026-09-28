"""Unit test for R6 (postconditions D8): a DELIVER product must cover exactly the
repos EXECUTE actually touched, with no row hiding a delivered, committed repo
behind `state: skipped` and no `delivered` row with a null PR. Pure logic against
a fake state -- D8 never touches git or gh, unlike D1/D2/D3."""
import unittest
from pathlib import Path

from loop_spec import postconditions


class _FakeStore:
    def __init__(self, state):
        self.state = state


def _state(execute_tasks):
    return {
        "products": {
            "plan": {"product": {"tasks": [{"id": "T-1", "repo": "repo"}, {"id": "T-2", "repo": "repo2"}]}},
            "execute": {"product": {"tasks": execute_tasks}},
        },
    }


def _boundary(execute_tasks, deliver_product, exit_):
    store = _FakeStore(_state(execute_tasks))
    return postconditions.Boundary(store, None, phase="deliver", product=deliver_product, exit=exit_,
                                    project_root=Path("."))


_BOTH_TOUCHED = [
    {"id": "T-1", "disposition": "done", "commits": ["c1"]},
    {"id": "T-2", "disposition": "done", "commits": ["c2"]},
]


class D8Tests(unittest.TestCase):
    def test_a_touched_committed_repo_reported_skipped_with_a_null_pr_is_rejected_naming_the_repo(self):
        # The auditor's exact counterexample: two EXECUTE commits (one per repo),
        # one DELIVER row honestly delivered, the other skipped with pr=null even
        # though its repo has an accepted, committed task.
        deliver_product = {"repos": [
            {"repo": "repo", "state": "delivered", "pr": {"number": 1, "url": "u", "headRef": "x"},
             "deliveredSha": "c1", "caveats": []},
            {"repo": "repo2", "state": "skipped", "pr": None, "deliveredSha": None, "caveats": []},
        ]}
        message = _boundary(_BOTH_TOUCHED, deliver_product, "delivered")._d8()
        self.assertIsNotNone(message)
        self.assertIn("repo2", message)

    def test_every_touched_repo_delivered_with_a_pr_holds(self):
        deliver_product = {"repos": [
            {"repo": "repo", "state": "delivered", "pr": {"number": 1, "url": "u", "headRef": "x"},
             "deliveredSha": "c1", "caveats": []},
            {"repo": "repo2", "state": "delivered", "pr": {"number": 2, "url": "u2", "headRef": "y"},
             "deliveredSha": "c2", "caveats": []},
        ]}
        self.assertIsNone(_boundary(_BOTH_TOUCHED, deliver_product, "delivered")._d8())

    def test_skipped_is_valid_for_a_repo_execute_did_not_touch(self):
        execute_tasks = [{"id": "T-1", "disposition": "done", "commits": ["c1"]},
                          {"id": "T-2", "disposition": "done", "commits": []}]
        deliver_product = {"repos": [
            {"repo": "repo", "state": "delivered", "pr": {"number": 1, "url": "u", "headRef": "x"},
             "deliveredSha": "c1", "caveats": []},
            {"repo": "repo2", "state": "skipped", "pr": None, "deliveredSha": None, "caveats": []},
        ]}
        self.assertIsNone(_boundary(execute_tasks, deliver_product, "delivered")._d8())

    def test_partially_delivered_still_rejects_a_delivered_row_with_a_null_pr(self):
        deliver_product = {"repos": [
            {"repo": "repo", "state": "delivered", "pr": None, "deliveredSha": "c1", "caveats": []},
            {"repo": "repo2", "state": "failed", "pr": None, "deliveredSha": None, "caveats": ["down"]},
        ]}
        message = _boundary(_BOTH_TOUCHED, deliver_product, "partially delivered")._d8()
        self.assertIsNotNone(message)
        self.assertIn("repo", message)

    def test_a_duplicate_repo_row_is_rejected(self):
        deliver_product = {"repos": [
            {"repo": "repo", "state": "delivered", "pr": {"number": 1, "url": "u", "headRef": "x"},
             "deliveredSha": "c1", "caveats": []},
            {"repo": "repo", "state": "delivered", "pr": {"number": 1, "url": "u", "headRef": "x"},
             "deliveredSha": "c1", "caveats": []},
            {"repo": "repo2", "state": "delivered", "pr": {"number": 2, "url": "u2", "headRef": "y"},
             "deliveredSha": "c2", "caveats": []},
        ]}
        message = _boundary(_BOTH_TOUCHED, deliver_product, "delivered")._d8()
        self.assertIsNotNone(message)
        self.assertIn("more than once", message)


if __name__ == "__main__":
    unittest.main()
