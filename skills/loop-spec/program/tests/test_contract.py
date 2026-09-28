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
            from loop_spec import steps as steps_module
            request = {
                "kind": "role", "role": "implementer", "phase": "execute", "cwd": str(tmp),
                "prompt": "do it", "resultPath": str(Path(tmp) / "result.json"), "schema": {},
                "postconditions": [], "attempt": attempt_id, "inputsDigest": "sha256:" + "a" * 64,
                "retryOf": None, "reason": None,
            }
            with patch.object(execute_module, "step", return_value=steps_module.IssueStep(request)):
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
            from loop_spec import steps as steps_module
            product = {
                "exit": "no change", "inputsDigest": "sha256:" + "a" * 64,
                "boundTo": {"requirements": None, "plan": None}, "tasks": [], "issues": [], "heads": {},
            }
            with patch.object(execute_module, "step", return_value=steps_module.Product(product)):
                outcome = contract.invoke(paths, phase="execute", attempt_id=attempt_id, implementation="default", program_launcher=Path("/bin/true"), store=Mock())
            self.assertEqual(outcome.code, 0)
            self.assertEqual(outcome.kind, "product")

    def test_invoke_names_the_implementation_and_phase_for_an_invalid_product(self):
        # LF-25: a bad product's error must say WHO produced it, not just list schema
        # errors, so a reader debugging a "failed" run does not blame the code that
        # merely validated it.
        with tempfile.TemporaryDirectory() as tmp:
            paths = FeaturePaths(root=Path(tmp) / "feature")
            attempt_id = "attempt-1"
            contract.write_context(paths, attempt_id, _envelope(attempt_id, tmp, paths))
            from loop_spec import execute as execute_module
            from loop_spec import steps as steps_module
            invalid_product = {"exit": "no change", "inputsDigest": "sha256:" + "a" * 64}  # missing required fields
            with patch.object(execute_module, "step", return_value=steps_module.Product(invalid_product)):
                outcome = contract.invoke(paths, phase="execute", attempt_id=attempt_id, implementation="default", program_launcher=Path("/bin/true"), store=Mock())
            self.assertEqual(outcome.kind, "error")
            self.assertTrue(outcome.stderr.startswith("default EXECUTE implementation produced an invalid product: "))

    def test_invoke_default_execute_converts_pause(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = FeaturePaths(root=Path(tmp) / "feature")
            attempt_id = "attempt-1"
            contract.write_context(paths, attempt_id, _envelope(attempt_id, tmp, paths))
            from loop_spec import execute as execute_module
            from loop_spec import steps as steps_module
            question = {
                "attempt": attempt_id, "phase": "execute", "text": "the feature branch moved; how should the run proceed?",
                "options": [{"value": "resume", "label": "resume"}, {"value": "abort", "label": "abort"}],
                "defaultValue": None, "kind": "blocked", "payload": {},
            }
            with patch.object(execute_module, "step", return_value=steps_module.Pause(question)):
                outcome = contract.invoke(paths, phase="execute", attempt_id=attempt_id, implementation="default", program_launcher=Path("/bin/true"), store=Mock())
            self.assertEqual(outcome.code, 3)
            self.assertEqual(outcome.kind, "question")

    def test_invoke_batch_then_single_within_one_attempt_returns_the_new_single_request(self):
        # R1: a wave's shape can change call to call within the SAME attempt id (two
        # tasks in flight collapsing to one review left) -- the stale steps.json a
        # PRIOR call wrote must not shadow this call's real step.json.
        with tempfile.TemporaryDirectory() as tmp:
            paths = FeaturePaths(root=Path(tmp) / "feature")
            attempt_id = "attempt-1"
            contract.write_context(paths, attempt_id, _envelope(attempt_id, tmp, paths))
            from loop_spec import execute as execute_module
            from loop_spec import steps as steps_module

            def _request(role, task_id):
                return {
                    "kind": "role", "role": role, "phase": "execute", "cwd": str(tmp),
                    "prompt": f"do {task_id}", "resultPath": str(Path(tmp) / f"{task_id}.json"), "schema": {},
                    "postconditions": [], "attempt": attempt_id, "inputsDigest": "sha256:" + "a" * 64,
                    "retryOf": None, "reason": None,
                }

            old_a, old_b = _request("implementer", "T-1"), _request("implementer", "T-2")
            with patch.object(execute_module, "step", return_value=steps_module.IssueSteps([old_a, old_b])):
                first = contract.invoke(paths, phase="execute", attempt_id=attempt_id, implementation="default", program_launcher=Path("/bin/true"), store=Mock())
            self.assertEqual(first.kind, "steps")

            new_review = _request("code-reviewer", "T-1")
            with patch.object(execute_module, "step", return_value=steps_module.IssueStep(new_review)):
                second = contract.invoke(paths, phase="execute", attempt_id=attempt_id, implementation="default", program_launcher=Path("/bin/true"), store=Mock())
            self.assertEqual(second.kind, "step")
            self.assertEqual(read_json(second.path)["role"], "code-reviewer")

    def test_invoke_single_then_batch_within_one_attempt_returns_the_new_batch(self):
        # The reverse shape change: a stale single step.json must not survive to be
        # read as "the" request once the same attempt issues a fresh batch.
        with tempfile.TemporaryDirectory() as tmp:
            paths = FeaturePaths(root=Path(tmp) / "feature")
            attempt_id = "attempt-1"
            contract.write_context(paths, attempt_id, _envelope(attempt_id, tmp, paths))
            from loop_spec import execute as execute_module
            from loop_spec import steps as steps_module

            def _request(role, task_id):
                return {
                    "kind": "role", "role": role, "phase": "execute", "cwd": str(tmp),
                    "prompt": f"do {task_id}", "resultPath": str(Path(tmp) / f"{task_id}.json"), "schema": {},
                    "postconditions": [], "attempt": attempt_id, "inputsDigest": "sha256:" + "a" * 64,
                    "retryOf": None, "reason": None,
                }

            old_single = _request("implementer", "T-1")
            with patch.object(execute_module, "step", return_value=steps_module.IssueStep(old_single)):
                first = contract.invoke(paths, phase="execute", attempt_id=attempt_id, implementation="default", program_launcher=Path("/bin/true"), store=Mock())
            self.assertEqual(first.kind, "step")

            new_a, new_b = _request("implementer", "T-2"), _request("implementer", "T-3")
            with patch.object(execute_module, "step", return_value=steps_module.IssueSteps([new_a, new_b])):
                second = contract.invoke(paths, phase="execute", attempt_id=attempt_id, implementation="default", program_launcher=Path("/bin/true"), store=Mock())
            self.assertEqual(second.kind, "steps")
            requests = read_json(second.path)
            self.assertEqual({r["prompt"] for r in requests}, {"do T-2", "do T-3"})

    def test_invoke_bound_skill_raises(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = FeaturePaths(root=Path(tmp) / "feature")
            with self.assertRaises(LoopSpecError) as ctx:
                contract.invoke(paths, phase="spec", attempt_id="attempt-1", implementation="a-bound-skill", program_launcher=Path("/bin/true"))
            # roadmap 5: a bound implementation is a ROLE binding, not a third phase
            # kind -- the message points at "roles", not at some future M5 support.
            self.assertIn("must be default or external", ctx.exception.message)
            self.assertIn("roles.<role>", ctx.exception.message)


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


class AcceptRemotePathsConfigTests(unittest.TestCase):
    def test_accepts_a_list_of_globs_and_refuses_anything_else(self):
        from loop_spec.contract import load_config
        from loop_spec.errors import LoopSpecError
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            (root / ".loop-spec").mkdir()
            config = root / ".loop-spec" / "config.json"
            config.write_text('{"deliver": {"acceptRemotePaths": ["CHANGELOG.md", "docs/*.md"]}}')
            self.assertEqual(load_config(root)["deliver"]["acceptRemotePaths"], ["CHANGELOG.md", "docs/*.md"])
            config.write_text('{"deliver": {"acceptRemotePaths": "CHANGELOG.md"}}')
            with self.assertRaises(LoopSpecError):
                load_config(root)
