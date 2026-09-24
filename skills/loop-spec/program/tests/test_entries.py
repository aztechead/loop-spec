import re
import unittest
from pathlib import Path

from loop_spec import controller
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


if __name__ == "__main__":
    unittest.main()
