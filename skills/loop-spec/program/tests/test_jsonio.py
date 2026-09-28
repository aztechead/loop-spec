"""Unit tests for loop_spec.jsonio: atomic writes and append-only JSONL."""
import tempfile
import unittest
from pathlib import Path

from loop_spec.jsonio import append_jsonl, atomic_write_json, read_json


class AtomicWriteJsonTests(unittest.TestCase):
    def test_leaves_no_temp_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "state.json"
            atomic_write_json(target, {"a": 1})
            names = {p.name for p in Path(tmp).iterdir()}
            self.assertEqual(names, {"state.json"})
            self.assertEqual(read_json(target), {"a": 1})


class AppendJsonlTests(unittest.TestCase):
    def test_appends_one_line_per_call(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "events.jsonl"
            append_jsonl(target, {"event": "a"})
            append_jsonl(target, {"event": "b"})
            lines = target.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(lines), 2)


if __name__ == "__main__":
    unittest.main()
