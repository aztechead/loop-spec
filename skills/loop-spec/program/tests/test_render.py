"""Unit tests for loop_spec.render: the PR body and the three artifact renderers."""
import tempfile
import unittest
from pathlib import Path

from loop_spec.paths import FeaturePaths
from loop_spec.render import BODY_BEGIN, BODY_END, fill_template, merge_body, plan_md, pr_body, pr_template, spec_md, verification_md
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

    def test_pr_body_is_marked_and_carries_why_criteria_text_issue_owner_and_siblings(self):
        self.store.state["issue"] = {"repo": "repo", "number": 12}
        self.store.state["operator"] = {"login": "ada"}
        text = pr_body(self.store, "repo", [("web", "https://x/pull/9")])
        self.assertTrue(text.startswith(BODY_BEGIN) and text.rstrip().endswith(BODY_END))
        for needle in ("### Why", "use the existing renderer", "| the widget renders |", "Closes #12",
                       "for @ada", "- web: https://x/pull/9"):
            self.assertIn(needle, text)
        self.assertNotIn("Rewinds used", text)
        other = pr_body(self.store, "elsewhere")
        self.assertNotIn("Closes #", other)

    def test_merge_body_keeps_human_text_in_each_of_the_three_shapes(self):
        new = pr_body(self.store)
        marked = "intro\n\n" + pr_body(self.store).replace("add a widget", "old") + "\nfooter\n"
        merged = merge_body(marked, new)
        self.assertTrue(merged.startswith("intro\n\n" + BODY_BEGIN))
        self.assertTrue(merged.endswith(BODY_END + "\n\nfooter\n"))
        self.assertNotIn("## old", merged)
        legacy = "intro\n\n## old goal\n\n### Acceptance\n\nGenerated with loop-spec 7.8.3\n\nmy note\n"
        merged = merge_body(legacy, new)
        self.assertTrue(merged.startswith("intro\n\n" + BODY_BEGIN))
        self.assertTrue(merged.endswith(BODY_END + "\n\nmy note\n"))
        self.assertNotIn("old goal", merged)
        plain = merge_body("Fixes the thing.\n", new)
        self.assertTrue(plain.startswith("Fixes the thing.\n\n" + BODY_BEGIN))

    def test_pr_template_is_read_at_the_given_commit(self):
        import subprocess
        with tempfile.TemporaryDirectory() as t:
            repo = Path(t)
            git = lambda *a: subprocess.run(["git", "-C", t, *a], check=True, capture_output=True, text=True)
            git("init", "-q", "-b", "main")
            git("config", "user.name", "T")
            git("config", "user.email", "t@example.com")
            (repo / "README").write_text("r\n")
            git("add", ".")
            git("commit", "-q", "-m", "first")
            first = git("rev-parse", "HEAD").stdout.strip()
            (repo / ".github").mkdir()
            (repo / ".github" / "pull_request_template.md").write_text("## Checklist\n")
            git("add", ".")
            git("commit", "-q", "-m", "x")
            sha = git("rev-parse", "HEAD").stdout.strip()
            (repo / ".github" / "pull_request_template.md").write_text("changed in the working tree\n")
            self.assertEqual(pr_template(repo, sha), "## Checklist\n")
            self.assertIsNone(pr_template(repo, first))

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


class ReviewerBodyTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.store = _store(Path(self._tmp.name))

    def tearDown(self):
        self._tmp.cleanup()

    def test_the_table_has_no_command_column_and_how_to_test_lists_each_command_once(self):
        verdicts = self.store.state["products"]["verify"]["product"]["verdicts"]
        verdicts.append(dict(verdicts[0], criterion="AC-2"))
        self.store.state["products"]["spec"]["product"]["criteria"].append({"id": "AC-2", "text": "two"})
        body = pr_body(self.store)
        self.assertIn("| Criterion | Text | Verdict |", body)
        self.assertNotIn("| Command |", body)
        self.assertEqual(body.count("sh verify.sh"), 1)
        self.assertIn("### How to test\n\n```sh\nsh verify.sh\n```\n\nVerified at abc123", body)

    def test_a_long_critic_cause_is_truncated(self):
        self.store.state["revisions"]["plan"] = "sha256:plan"
        self.store.state["critic"] = {"planRevision": "sha256:plan", "findings": [
            {"id": "F-1", "location": "T-1", "cause": "c" * 500, "severity": "Critical",
             "disposition": "rejected", "reason": "r" * 500}]}
        body = pr_body(self.store)
        self.assertNotIn("c" * 301, body)
        self.assertNotIn("r" * 301, body)
        self.assertIn("c" * 290 + "...", body)

    def test_the_owner_line_names_the_pr_number_when_known(self):
        self.store.state["operator"] = {"login": "ada"}
        self.assertIn("`/loop-spec:revise 7`", pr_body(self.store, number=7))
        self.assertIn("`/loop-spec:revise` with this PR's number", pr_body(self.store))

    def test_a_template_fills_placeholder_sections_and_leaves_checklists(self):
        template = ("## Summary\n\n<!-- what changed -->\n\n## How to test\n\n<!-- steps -->\n\n"
                    "## Checklist\n\n- [ ] docs updated\n")
        filled = fill_template(template, self.store, ["sh verify.sh"])
        self.assertIn("## Summary\n\nadd a widget\n\n- use the existing renderer", filled)
        self.assertIn("## How to test\n\n```sh\nsh verify.sh\n```", filled)
        self.assertIn("## Checklist\n\n- [ ] docs updated\n", filled)
        self.assertNotIn("<!--", filled)
        kept = fill_template("## Summary\n\nmy own text\n", self.store, [])
        self.assertEqual(kept, "## Summary\n\nmy own text\n")
