"""Unit tests for loop_spec.render: the PR body and the three artifact renderers."""
import tempfile
import unittest
from pathlib import Path

from loop_spec.paths import FeaturePaths
from loop_spec.render import plan_md, pr_body, spec_md, verification_md
from loop_spec.state import StateStore


def _store(tmp: Path) -> StateStore:
    paths = FeaturePaths(root=tmp / "run")
    store = StateStore.create(paths, {"id": "run-1"}, "add a widget")
    store.state["products"]["spec"] = {"exit": "approved", "product": {
        "goal": "add a widget", "boundaries": ["no new dependencies"],
        "criteria": [{"id": "AC-1", "text": "the widget renders"}],
        "decisions": [{"id": "D-1", "text": "use the existing renderer"}], "openQuestions": [],
    }}
    store.state["products"]["plan"] = {"exit": "ready", "product": {
        "tasks": [{"id": "T-1", "title": "add the widget", "dependsOn": [], "files": ["widget.py"], "repo": "repo",
                   "verify": "sh verify.sh", "criteria": ["AC-1"], "featureAdded": None, "mustFlip": False}],
        "prepare": None, "evidenceExceptions": [],
    }}
    store.state["products"]["verify"] = {"exit": "passed", "product": {
        "verdicts": [{"criterion": "AC-1", "verdict": "pass",
                      "evidence": {"command": "sh verify.sh", "sha": "abc123", "exitStatus": 0,
                                   "failureIdentities": [], "outputDigest": "sha256:" + "a" * 64},
                      "cause": None}],
    }}
    store.state["products"]["iterate"] = {"exit": "converged", "product": {"gaps": []}}
    store.save()
    return store


class RenderTests(unittest.TestCase):
    # simplicity: setUp/tearDown are unittest's fixed method names, not a naming
    # choice; house-style.sh's camelCase deviation here is the same pre-existing
    # false positive test_execute.py, test_result.py, and test_postconditions.py hit.
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.store = _store(Path(self._tmp.name))

    def tearDown(self):
        self._tmp.cleanup()

    def test_spec_md_includes_goal_and_criteria(self):
        text = spec_md(self.store)
        self.assertIn("add a widget", text)
        self.assertIn("AC-1", text)
        self.assertIn("the widget renders", text)

    def test_plan_md_includes_the_task_row(self):
        text = plan_md(self.store)
        self.assertIn("T-1", text)
        self.assertIn("sh verify.sh", text)

    def test_verification_md_includes_the_verdict(self):
        text = verification_md(self.store)
        self.assertIn("AC-1", text)
        self.assertIn("pass", text)

    def test_pr_body_includes_goal_boundaries_and_generated_line(self):
        text = pr_body(self.store)
        self.assertIn("add a widget", text)
        self.assertIn("no new dependencies", text)
        self.assertIn("Generated with loop-spec", text)
        self.assertIn("### Outstanding\nnone", text)

    def test_pr_body_lists_open_findings_and_gaps_as_outstanding(self):
        self.store.state["ledger"]["findings"] = [
            {"id": "F-1", "location": "a.py:1", "cause": "x", "severity": "Minor",
             "disposition": "open", "reason": None, "supersedes": None},
        ]
        self.store.state["products"]["iterate"]["product"]["gaps"] = [{"target": "plan", "text": "missing a case"}]
        text = pr_body(self.store)
        self.assertIn("F-1", text)
        self.assertIn("missing a case", text)


if __name__ == "__main__":
    unittest.main()


class CriticSectionTests(unittest.TestCase):
    def test_rejected_critical_findings_of_the_delivered_plan_are_listed(self):
        with tempfile.TemporaryDirectory() as t:
            store = _store(Path(t))
            store.state["revisions"]["plan"] = "sha256:plan"
            store.state["critic"] = {"planRevision": "sha256:plan", "findings": [
                {"id": "F-1", "location": "T-1", "cause": "verify runs one file.", "severity": "Critical",
                 "disposition": "rejected", "reason": "VERIFY runs the suite"},
                {"id": "F-2", "location": "T-1", "cause": "minor.", "severity": "Minor", "disposition": "rejected", "reason": "x"},
            ]}
            body = pr_body(store)
            self.assertIn("F-1 at T-1: verify runs one file. Rejected: VERIFY runs the suite", body)
            self.assertNotIn("F-2", body)
            store.state["critic"]["planRevision"] = "sha256:older"
            self.assertNotIn("### Plan critic", pr_body(store))
