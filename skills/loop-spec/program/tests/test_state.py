"""Unit tests for loop_spec.state.StateStore: single writer, digest guard, round-trip."""
import tempfile
import unittest
from pathlib import Path

from loop_spec.errors import LoopSpecError
from loop_spec.paths import FeaturePaths
from loop_spec.state import StateStore


class StateStoreTests(unittest.TestCase):
    def _paths(self, tmp) -> FeaturePaths:
        return FeaturePaths(root=Path(tmp) / "feature")

    def test_create_refuses_over_existing(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = self._paths(tmp)
            StateStore.create(paths, {"id": "run-1", "entry": "cycle"}, "do the thing")
            with self.assertRaises(LoopSpecError):
                StateStore.create(paths, {"id": "run-2", "entry": "cycle"}, "again")

    def test_open_refuses_when_state_edited_out_of_band(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = self._paths(tmp)
            StateStore.create(paths, {"id": "run-1", "entry": "cycle"}, "do the thing")
            paths.state_json.write_text('{"schema": 1, "tampered": true}', encoding="utf-8")
            with self.assertRaises(LoopSpecError):
                StateStore.open(paths)

    def test_open_refuses_when_sidecar_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = self._paths(tmp)
            StateStore.create(paths, {"id": "run-1", "entry": "cycle"}, "do the thing")
            (paths.state_json.parent / "state.digest").unlink()
            with self.assertRaises(LoopSpecError):
                StateStore.open(paths)

    def test_save_then_open_round_trips(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = self._paths(tmp)
            store = StateStore.create(paths, {"id": "run-1", "entry": "cycle"}, "do the thing")
            store.state["phase"]["current"] = "spec"
            store.save()
            reopened = StateStore.open(paths)
            self.assertEqual(reopened.state["phase"]["current"], "spec")
            self.assertEqual(reopened.state["run"]["id"], "run-1")


if __name__ == "__main__":
    unittest.main()
