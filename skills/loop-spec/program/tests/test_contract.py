"""Unit tests for loop_spec.contract: resolution precedence and the process contract."""
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from loop_spec import contract
from loop_spec.errors import LoopSpecError
from loop_spec.jsonio import atomic_write_json, read_json
from loop_spec.paths import FeaturePaths


def _envelope(attempt_id: str, tmp: str, paths: FeaturePaths) -> dict:
    return {
        "run": {"id": "run-1"}, "attempt": {"id": attempt_id}, "inputs": {"digest": "sha256:" + "a" * 64},
        "request": {"text": "add a widget", "digest": "sha256:" + "b" * 64},
        "products": {}, "state": {"requirementsRevision": None, "approval": None, "planRevision": None,
                                   "baseline": None, "ledger": {}, "budget": {}},
        "entry": {"mode": "fresh", "payload": None}, "repos": [{"name": "repo", "path": str(tmp)}],
        "paths": {"stateDir": str(paths.root), "writable": [], "projectRoot": str(tmp)},
        "answers": {"byQuestion": {}, "policy": None}, "probes": {},
    }


class ResolveImplementationTests(unittest.TestCase):
    def test_env_wins_over_config_and_default(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".loop-spec").mkdir()
            atomic_write_json(root / ".loop-spec" / "config.json", {"phases": {"spec": "external"}})
            with patch.dict("os.environ", {"LOOP_SPEC_PHASE_SPEC": "skill-x"}, clear=True):
                self.assertEqual(contract.resolve_implementation(root, "spec"), "skill-x")

    def test_config_wins_over_default(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".loop-spec").mkdir()
            atomic_write_json(root / ".loop-spec" / "config.json", {"phases": {"spec": "external"}})
            with patch.dict("os.environ", {}, clear=True):
                self.assertEqual(contract.resolve_implementation(root, "spec"), "external")

    def test_default_when_nothing_configured(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict("os.environ", {}, clear=True):
            self.assertEqual(contract.resolve_implementation(Path(tmp), "spec"), "default")

    def test_resolve_role_same_precedence(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict("os.environ", {"LOOP_SPEC_ROLE_IMPLEMENTER": "custom"}, clear=True):
            self.assertEqual(contract.resolve_role(Path(tmp), "implementer"), "custom")


class InvokeTests(unittest.TestCase):
    def test_invoke_external_returns_2_with_a_valid_step(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = FeaturePaths(root=Path(tmp) / "feature")
            attempt_id = "attempt-1"
            contract.write_context(paths, attempt_id, _envelope(attempt_id, tmp, paths))
            outcome = contract.invoke(paths, phase="spec", attempt_id=attempt_id, implementation="external", program_launcher=Path("/bin/true"))
            self.assertEqual(outcome.code, 2)
            self.assertEqual(outcome.kind, "step")

    # simplicity: shares its tmp/paths/write_context/invoke setup with the test
    # above (duplication-scan flags ~8 lines); each test stays readable top to
    # bottom on its own, and the two differ in the one line that matters
    # (implementation="external" vs "default") plus their own assertions.
    def test_invoke_default_dispatches_a_lead_step_for_spec(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = FeaturePaths(root=Path(tmp) / "feature")
            attempt_id = "attempt-1"
            contract.write_context(paths, attempt_id, _envelope(attempt_id, tmp, paths))
            outcome = contract.invoke(paths, phase="spec", attempt_id=attempt_id, implementation="default", program_launcher=Path("/bin/true"))
            self.assertEqual(outcome.code, 2)
            self.assertEqual(outcome.kind, "step")
            step = read_json(outcome.path)
            self.assertEqual(step["kind"], "lead")
            self.assertEqual(step["role"], "spec-writer")

    def test_invoke_default_raises_for_a_phase_with_no_default_yet(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = FeaturePaths(root=Path(tmp) / "feature")
            with self.assertRaises(LoopSpecError):
                contract.invoke(paths, phase="verify", attempt_id="attempt-1", implementation="default", program_launcher=Path("/bin/true"))

    def test_invoke_default_execute_needs_a_store(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = FeaturePaths(root=Path(tmp) / "feature")
            with self.assertRaises(LoopSpecError):
                contract.invoke(paths, phase="execute", attempt_id="attempt-1", implementation="default", program_launcher=Path("/bin/true"))

    # simplicity: three near-identical dispatch bodies (duplication-scan would flag
    # them together); each proves a DIFFERENT execute.py return type converts to its
    # own file+code, and collapsing them into one parametrized test would hide which
    # conversion broke when only one fails.
    def test_invoke_default_execute_converts_issue_step(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = FeaturePaths(root=Path(tmp) / "feature")
            attempt_id = "attempt-1"
            contract.write_context(paths, attempt_id, _envelope(attempt_id, tmp, paths))
            from loop_spec import execute as execute_module
            request = {
                "kind": "role", "role": "implementer", "phase": "execute", "cwd": str(tmp),
                "prompt": "do it", "resultPath": str(Path(tmp) / "result.json"), "schema": {},
                "postconditions": [], "attempt": attempt_id, "inputsDigest": "sha256:" + "a" * 64,
                "retryOf": None, "reason": None,
            }
            with patch.object(execute_module, "step", return_value=execute_module.IssueStep(request)):
                outcome = contract.invoke(paths, phase="execute", attempt_id=attempt_id, implementation="default", program_launcher=Path("/bin/true"), store=Mock())
            self.assertEqual(outcome.code, 2)
            self.assertEqual(outcome.kind, "step")
            self.assertEqual(read_json(outcome.path)["role"], "implementer")

    def test_invoke_default_execute_converts_product(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = FeaturePaths(root=Path(tmp) / "feature")
            attempt_id = "attempt-1"
            contract.write_context(paths, attempt_id, _envelope(attempt_id, tmp, paths))
            from loop_spec import execute as execute_module
            product = {
                "exit": "no change", "inputsDigest": "sha256:" + "a" * 64,
                "boundTo": {"requirements": None, "plan": None}, "tasks": [], "issues": [], "heads": {},
            }
            with patch.object(execute_module, "step", return_value=execute_module.Product(product)):
                outcome = contract.invoke(paths, phase="execute", attempt_id=attempt_id, implementation="default", program_launcher=Path("/bin/true"), store=Mock())
            self.assertEqual(outcome.code, 0)
            self.assertEqual(outcome.kind, "product")

    def test_invoke_default_execute_converts_pause(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = FeaturePaths(root=Path(tmp) / "feature")
            attempt_id = "attempt-1"
            contract.write_context(paths, attempt_id, _envelope(attempt_id, tmp, paths))
            from loop_spec import execute as execute_module
            question = {
                "attempt": attempt_id, "phase": "execute", "text": "the feature branch moved; how should the run proceed?",
                "options": [{"value": "resume", "label": "resume"}, {"value": "abort", "label": "abort"}],
                "defaultValue": None, "kind": "blocked", "payload": {},
            }
            with patch.object(execute_module, "step", return_value=execute_module.Pause(question)):
                outcome = contract.invoke(paths, phase="execute", attempt_id=attempt_id, implementation="default", program_launcher=Path("/bin/true"), store=Mock())
            self.assertEqual(outcome.code, 3)
            self.assertEqual(outcome.kind, "question")

    def test_invoke_bound_skill_raises(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = FeaturePaths(root=Path(tmp) / "feature")
            with self.assertRaises(LoopSpecError):
                contract.invoke(paths, phase="spec", attempt_id="attempt-1", implementation="a-bound-skill", program_launcher=Path("/bin/true"))


class ValidateRequestTests(unittest.TestCase):
    def test_step_request_drops_id_fields_from_required(self):
        request = {
            "kind": "external", "role": None, "phase": "execute", "cwd": ".", "prompt": "x",
            "resultPath": "result.json", "schema": {}, "postconditions": [], "attempt": "attempt-1",
            "inputsDigest": "sha256:" + "a" * 64, "retryOf": None, "reason": None,
        }
        self.assertEqual(contract.validate_request("step", request), [])

    def test_question_request_drops_id_fields_from_required(self):
        request = {
            "attempt": "attempt-1", "phase": "spec", "text": "proceed?", "options": [],
            "defaultValue": None, "kind": "approval", "payload": None,
        }
        self.assertEqual(contract.validate_request("question", request), [])


if __name__ == "__main__":
    unittest.main()
