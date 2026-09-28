import re
import unittest
from pathlib import Path

from loop_spec import controller
from loop_spec.contract import EFFORT_LEVELS
from loop_spec.entries import ENTRIES

_SKILLS = Path(__file__).resolve().parents[3]


class EntryRegistryTests(unittest.TestCase):
    def test_every_entry_has_a_start_and_the_stub_says_the_same_use(self):
        self.assertEqual(set(controller._ENTRY_START), set(ENTRIES))
        for name, entry in ENTRIES.items():
            stub = _SKILLS / name / "SKILL.md"
            if not stub.exists():
                continue
            described = re.search(r"^description: (.+)$", stub.read_text(), re.M).group(1).strip().strip('"')
            self.assertEqual(described, entry.use, name)


class RunnerProtocolTests(unittest.TestCase):
    def test_every_entry_stub_cites_the_one_protocol_file_and_copies_none(self):
        # D5: the runner protocol lives in references/runner.md only.
        # Every entry stub that starts or resumes a run; status and the hub start none.
        stubs = [p for p in sorted(_SKILLS.glob("*/SKILL.md")) if p.parent.name not in ("loop-spec", "status")]
        self.assertEqual(len(stubs), 11)
        for path in stubs:
            stub = path.read_text()
            with self.subTest(entry=path.parent.name):
                self.assertIn("${CLAUDE_SKILL_DIR}/../loop-spec/references/runner.md", stub)
                self.assertNotIn("LOOP_SPEC_WAIT", stub)
        self.assertIn("LOOP_SPEC_WAIT", (_SKILLS / "loop-spec" / "references" / "runner.md").read_text())

    def test_one_worker_agent_per_effort_level_with_one_body(self):
        # F5: agents/worker-<level>.md at the plugin root, `effort:` matching, bodies equal.
        agents = _SKILLS.parent / "agents"
        bodies = set()
        for level in EFFORT_LEVELS:
            text = (agents / f"worker-{level}.md").read_text()
            with self.subTest(level=level):
                self.assertIn(f"\neffort: {level}\n", text)
                self.assertIn(f"\nname: worker-{level}\n", text)
            bodies.add(text.split("---", 2)[2])
        self.assertEqual(len(bodies), 1)


if __name__ == "__main__":
    unittest.main()
