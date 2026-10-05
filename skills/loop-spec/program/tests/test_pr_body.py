"""loop_spec.deliver's PR title and body, built from a run's files."""
import json
import tempfile
import unittest
from pathlib import Path

from loop_spec import deliver
from loop_spec.runs import Run


class BodyTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.run = Run(Path(self._tmp.name), "lerp")
        self.run.dir.mkdir(parents=True)
        self.run.state = {"request": "Add lerp\nwith tests", "slug": "lerp",
                          "verify": {"sha": "a" * 40, "passed": True, "results": [
                              {"name": "AC-1", "command": "pytest -q", "exit": 0},
                              {"name": "AC-2", "command": None}]}}

    def tearDown(self):
        self._tmp.cleanup()

    def spec(self, **fields):
        self.run.spec_path.write_text(json.dumps({"goal": "calc has lerp", "criteria": [
            {"id": "AC-1", "text": "lerp(0, 10, 0.5) | 5.0", "check": "pytest -q"},
            {"id": "AC-2", "text": "documented"}], **fields}))
        state, self.run = self.run.state, Run(self.run.project, "lerp")  # a Run reads spec.json once
        self.run.state = state

    def test_title_prefers_the_spec_then_the_request_first_line(self):
        self.assertEqual(deliver.title(self.run), "Add lerp")
        self.spec(title="feat: add lerp")
        self.assertEqual(deliver.title(self.run), "feat: add lerp")

    def test_the_body_is_pr_md_with_the_criteria_folded_below(self):
        self.spec()
        (self.run.dir / "pr.md").write_text("## Why the change\n\nCallers need lerp.\n")
        text = deliver.body(self.run, verified=True)
        self.assertTrue(text.startswith("## Why the change\n\nCallers need lerp.\n\n<!-- loop-spec:verification -->\n<details>"))
        self.assertIn("<summary>Acceptance criteria: checked in a clean checkout of `aaaaaaaaaaaa`", text)
        self.assertIn("| pass | **AC-1** lerp(0, 10, 0.5) \\| 5.0 | `pytest -q` |", text)
        self.assertIn("| not checked | **AC-2** documented | no command; judged in review |", text)
        self.assertTrue(text.rstrip().endswith("<!-- /loop-spec:verification -->"))

    def test_a_multi_line_check_is_one_code_span_per_line(self):
        self.run.spec_path.write_text(json.dumps({"goal": "g", "criteria": [
            {"id": "AC-1", "text": "t", "check": "pytest -q\ngrep 'a|b' x"}]}))
        state, self.run = self.run.state, Run(self.run.project, "lerp")
        self.run.state = state
        text = "\n".join(deliver._verification(self.run, True))
        self.assertIn("| `pytest -q`<br>`grep 'a\\|b' x` |", text)

    def test_fold_replaces_the_marked_region_and_an_older_unmarked_block(self):
        self.spec()
        section = "\n".join(deliver._verification(self.run, True))
        marked = "intro\n\n" + section.replace("aaaaaaaaaaaa", "bbbbbbbbbbbb") + "\n\nfooter\n"
        folded = deliver.fold(marked, section)
        self.assertEqual((folded.count("loop-spec:verification -->"), "bbbb" in folded, folded.startswith("intro"),
                          folded.rstrip().endswith("footer")), (2, False, True, True))
        legacy = "intro\n\n" + section.replace(deliver.VERIFY_OPEN + "\n", "").replace("\n" + deliver.VERIFY_CLOSE, "")
        folded = deliver.fold(legacy, section)
        self.assertEqual((folded.count("<details>"), folded.startswith("intro\n\n" + deliver.VERIFY_OPEN)), (1, True))

    def test_an_unverified_body_says_so(self):
        self.spec()
        (self.run.dir / "pr.md").write_text("x\n")
        self.assertIn("NOT verified", deliver.body(self.run, verified=False))

    def test_the_bundled_visual_pr_template_ships_with_its_license(self):
        self.assertTrue(deliver.VISUAL_PR.is_file())
        self.assertIn("## Why the change", deliver.VISUAL_PR.read_text())
        self.assertIn("MIT License", (deliver.VISUAL_PR.parent / "LICENSE").read_text())


if __name__ == "__main__":
    unittest.main()
