"""Unit tests for loop_spec.defaults: the default (lead-run) SPEC/PLAN implementation."""
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from loop_spec.defaults import run_lead_phase
from loop_spec.jsonio import atomic_write_json, read_json


def _context(tmp: str) -> dict:
    return {
        "run": {"id": "run-1"}, "attempt": {"id": "attempt-1"}, "inputs": {"digest": "sha256:" + "a" * 64},
        "request": {"text": "add a widget", "digest": "sha256:" + "b" * 64},
        "products": {}, "state": {"requirementsRevision": None, "approval": None, "planRevision": None,
                                   "baseline": None, "ledger": {}, "budget": {}},
        "entry": {"mode": "fresh", "payload": None}, "repos": [{"name": "repo", "path": tmp}],
        "paths": {"stateDir": tmp, "writable": [], "projectRoot": tmp},
        "answers": {"byQuestion": {}, "policy": None}, "probes": {},
    }


class RunLeadPhaseTests(unittest.TestCase):
    def test_returns_2_with_a_valid_lead_step_request(self):
        with tempfile.TemporaryDirectory() as tmp:
            context_path = Path(tmp, "context.json")
            product_path = Path(tmp, "product.json")
            atomic_write_json(context_path, _context(tmp))

            code = run_lead_phase("spec", "spec-writer", context_path, product_path)

            self.assertEqual(code, 2)
            step = read_json(product_path.parent / "step.json")
            self.assertEqual(step["kind"], "lead")
            self.assertEqual(step["role"], "spec-writer")
            self.assertEqual(step["phase"], "spec")
            self.assertEqual(step["resultPath"], str(product_path))
            self.assertIn("## Method", step["prompt"])
            self.assertIn("## Output", step["prompt"])
            self.assertIn("### request", step["prompt"])
            self.assertIn("add a widget", step["prompt"])

    def test_returns_0_when_a_valid_product_already_exists(self):
        with tempfile.TemporaryDirectory() as tmp:
            context_path = Path(tmp, "context.json")
            product_path = Path(tmp, "product.json")
            atomic_write_json(context_path, _context(tmp))
            atomic_write_json(product_path, {
                "exit": "approved", "inputsDigest": "sha256:" + "a" * 64,
                "boundTo": {"requirements": None, "plan": None},
                "goal": "do the thing", "boundaries": [], "criteria": [{"id": "AC-1", "text": "it works"}],
                "decisions": [], "openQuestions": [],
            })

            code = run_lead_phase("spec", "spec-writer", context_path, product_path)

            self.assertEqual(code, 0)

    def test_model_env_override_lands_in_the_request(self):
        with tempfile.TemporaryDirectory() as tmp:
            context_path = Path(tmp, "context.json")
            product_path = Path(tmp, "product.json")
            atomic_write_json(context_path, _context(tmp))

            with patch.dict("os.environ", {"LOOP_SPEC_MODEL_SPEC_WRITER": "claude-opus"}, clear=False):
                run_lead_phase("spec", "spec-writer", context_path, product_path)

            step = read_json(product_path.parent / "step.json")
            self.assertEqual(step["model"], "claude-opus")

    def test_model_is_null_without_an_override(self):
        with tempfile.TemporaryDirectory() as tmp:
            context_path = Path(tmp, "context.json")
            product_path = Path(tmp, "product.json")
            atomic_write_json(context_path, _context(tmp))

            with patch.dict("os.environ", {}, clear=True):
                run_lead_phase("plan", "planner", context_path, product_path)

            step = read_json(product_path.parent / "step.json")
            self.assertIsNone(step["model"])
            self.assertEqual(step["role"], "planner")

    def test_dict_shaped_repos_does_not_crash(self):
        # state.repos (and so context.repos) is a dict keyed by repo name in the
        # real controller, not a list; run_lead_phase must resolve cwd from either
        # shape without raising.
        with tempfile.TemporaryDirectory() as tmp:
            context_path = Path(tmp, "context.json")
            product_path = Path(tmp, "product.json")
            context = _context(tmp)
            context["repos"] = {"myrepo": {"path": tmp}}
            atomic_write_json(context_path, context)

            code = run_lead_phase("spec", "spec-writer", context_path, product_path)

            self.assertEqual(code, 2)
            step = read_json(product_path.parent / "step.json")
            self.assertEqual(step["cwd"], tmp)


if __name__ == "__main__":
    unittest.main()
