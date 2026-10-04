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

    def test_title_prefers_the_spec_then_the_request_first_line(self):
        self.assertEqual(deliver.title(self.run), "Add lerp")
        self.spec(title="feat: add lerp")
        self.assertEqual(deliver.title(self.run), "feat: add lerp")

    def test_body_marks_each_criterion_by_its_verify_result(self):
        self.spec(decisions=["no clamping"])
        text = deliver.body(self.run, verified=True)
        self.assertIn("| pass | **AC-1** lerp(0, 10, 0.5) \\| 5.0 | `pytest -q` |", text)
        self.assertIn("| not checked | **AC-2** documented | reviewed, no command |", text)
        self.assertIn("## Decisions\n\n- no clamping", text)
        self.assertIn("clean checkout of `aaaaaaaaaaaa`", text)

    def test_an_unverified_body_says_so(self):
        self.spec()
        self.assertIn("**Not verified.**", deliver.body(self.run, verified=False))


if __name__ == "__main__":
    unittest.main()
