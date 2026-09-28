"""Unit tests for loop_spec.external: the external placeholder implementation."""
import tempfile
import unittest
from pathlib import Path

from loop_spec.external import PHASE_EXITS, PHASE_POSTCONDITIONS, POSTCONDITION_TEXT, run
from loop_spec.jsonio import atomic_write_json, read_json

_ENVELOPE = {
    "run": {"id": "run-1"}, "attempt": {"id": "attempt-1"}, "inputs": {"digest": "sha256:" + "a" * 64},
    "products": {}, "state": {"requirementsRevision": None, "approval": None, "planRevision": None,
                               "baseline": None, "ledger": {}, "budget": {}},
    "entry": {"mode": "fresh", "payload": None}, "repos": [{"name": "repo", "path": "/repo"}],
    "paths": {"stateDir": "/state", "writable": []},
    "answers": {"byQuestion": {}, "policy": None}, "probes": {},
}

_VALID_SPEC_PRODUCT = {
    "exit": "approved", "inputsDigest": "sha256:" + "a" * 64,
    "boundTo": {"requirements": None, "plan": None},
    "goal": "do the thing", "boundaries": [], "criteria": [{"id": "AC-1", "text": "it works"}],
    "decisions": [], "openQuestions": [],
}


class ExternalRunTests(unittest.TestCase):
    def test_step_lists_the_phases_postconditions_and_exits(self):
        with tempfile.TemporaryDirectory() as tmp:
            context_path = Path(tmp) / "context.json"
            product_path = Path(tmp) / "product.json"
            atomic_write_json(context_path, _ENVELOPE)
            code = run(context_path, product_path, "spec")
            self.assertEqual(code, 2)
            step = read_json(product_path.parent / "step.json")
            for exit_name in PHASE_EXITS["spec"]:
                self.assertIn(exit_name, step["prompt"])
            self.assertEqual(step["postconditions"], PHASE_POSTCONDITIONS["spec"])
            for pid in PHASE_POSTCONDITIONS["spec"]:
                self.assertIn(POSTCONDITION_TEXT[pid], step["prompt"])

    def test_returns_0_when_product_exists_and_validates(self):
        with tempfile.TemporaryDirectory() as tmp:
            context_path = Path(tmp) / "context.json"
            product_path = Path(tmp) / "product.json"
            atomic_write_json(context_path, _ENVELOPE)
            atomic_write_json(product_path, _VALID_SPEC_PRODUCT)
            code = run(context_path, product_path, "spec")
            self.assertEqual(code, 0)

    def test_postcondition_text_covers_every_id_in_phase_postconditions(self):
        # T1 is the shared cross-phase budget postcondition (referenced by several
        # phases' backward exits, not owned by any one phase's list), so
        # POSTCONDITION_TEXT legitimately has one entry beyond PHASE_POSTCONDITIONS.
        every_id = {pid for ids in PHASE_POSTCONDITIONS.values() for pid in ids}
        self.assertTrue(every_id.issubset(POSTCONDITION_TEXT.keys()))


if __name__ == "__main__":
    unittest.main()
