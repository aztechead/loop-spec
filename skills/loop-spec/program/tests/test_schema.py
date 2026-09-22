"""Unit tests for loop_spec.schema: the minimal validator and the bundled schemas."""
import json
import unittest

from loop_spec.schema import load_schema, validate

_SCHEMA_NAMES = [
    "context", "spec", "plan", "execute", "verify", "iterate",
    "deliver", "debug", "revise", "step", "question", "result", "answer",
]

_BOUND_TO = {"requirements": None, "plan": None}
_DIGEST = "sha256:" + "a" * 64


class KeywordTests(unittest.TestCase):
    def test_type_violation_and_valid(self):
        schema = {"type": "string"}
        self.assertEqual(validate(1, schema), ["$: expected string"])
        self.assertEqual(validate("ok", schema), [])

    def test_required_violation_and_valid(self):
        schema = {"type": "object", "required": ["a"]}
        self.assertEqual(validate({}, schema), ["$.a: required field missing"])
        self.assertEqual(validate({"a": 1}, schema), [])

    def test_properties_recurse_into_path(self):
        schema = {"type": "object", "properties": {"a": {"type": "string"}}}
        self.assertEqual(validate({"a": 1}, schema), ["$.a: expected string"])
        self.assertEqual(validate({"a": "x"}, schema), [])

    def test_additional_properties_false(self):
        schema = {"type": "object", "properties": {"a": {"type": "string"}}, "additionalProperties": False}
        self.assertEqual(validate({"a": "x", "b": 1}, schema), ["$.b: additional property not allowed"])
        self.assertEqual(validate({"a": "x"}, schema), [])

    def test_items_recurse_with_index_in_path(self):
        schema = {"type": "array", "items": {"type": "string"}}
        self.assertEqual(validate([1], schema), ["$[0]: expected string"])
        self.assertEqual(validate(["x"], schema), [])

    def test_enum_violation_and_valid(self):
        schema = {"enum": ["a", "b"]}
        self.assertEqual(validate("c", schema), ["$: expected one of ['a', 'b']"])
        self.assertEqual(validate("a", schema), [])

    def test_const_violation_and_valid(self):
        schema = {"const": 1}
        self.assertEqual(validate(2, schema), ["$: expected constant 1"])
        self.assertEqual(validate(1, schema), [])

    def test_min_items_violation_and_valid(self):
        schema = {"type": "array", "minItems": 1}
        self.assertEqual(validate([], schema), ["$: fewer than minItems 1"])
        self.assertEqual(validate([1], schema), [])

    def test_min_length_violation_and_valid(self):
        schema = {"type": "string", "minLength": 1}
        self.assertEqual(validate("", schema), ["$: shorter than minLength 1"])
        self.assertEqual(validate("x", schema), [])

    def test_pattern_violation_and_valid(self):
        schema = {"type": "string", "pattern": "^AC-[0-9]+$"}
        self.assertEqual(validate("nope", schema), ["$: does not match pattern ^AC-[0-9]+$"])
        self.assertEqual(validate("AC-1", schema), [])

    def test_one_of_violation_and_valid(self):
        schema = {"oneOf": [{"type": "string"}, {"type": "integer"}]}
        self.assertEqual(validate(1.5, schema), ["$: expected exactly one oneOf branch to match, 0 matched"])
        self.assertEqual(validate(1, schema), [])

    def test_any_of_violation_and_valid(self):
        schema = {"anyOf": [{"type": "string"}, {"type": "integer"}]}
        self.assertEqual(validate(1.5, schema), ["$: expected at least one anyOf branch to match"])
        self.assertEqual(validate("x", schema), [])

    def test_ref_to_defs(self):
        schema = {"$defs": {"pos": {"type": "integer"}}, "$ref": "#/$defs/pos"}
        self.assertEqual(validate(-1, schema), [])  # $ref subset has no minimum keyword; type is all it checks
        self.assertEqual(validate("x", schema), ["$: expected integer"])


class BundledSchemaTests(unittest.TestCase):
    def test_every_schema_file_loads(self):
        for name in _SCHEMA_NAMES:
            with self.subTest(name=name):
                schema = load_schema(name)
                self.assertIsInstance(schema, dict)

    def test_minimal_spec_instance_validates(self):
        instance = {
            "exit": "needs answer", "inputsDigest": _DIGEST, "boundTo": _BOUND_TO,
            "goal": "do the thing", "boundaries": [], "criteria": [{"id": "AC-1", "text": "it works"}],
            "decisions": [], "openQuestions": [],
        }
        self.assertEqual(validate(instance, load_schema("spec")), [])

    def test_minimal_plan_instance_validates(self):
        instance = {
            "exit": "ready", "inputsDigest": _DIGEST, "boundTo": _BOUND_TO,
            "tasks": [{
                "id": "T-1", "title": "do it", "dependsOn": [], "files": ["a.py"],
                "repo": ".", "verify": "python3 -m unittest", "criteria": ["AC-1"],
                "featureAdded": None, "mustFlip": False,
            }],
            "prepare": None, "evidenceExceptions": [],
        }
        self.assertEqual(validate(instance, load_schema("plan")), [])

    def test_minimal_execute_instance_validates(self):
        instance = {
            "exit": "no change", "inputsDigest": _DIGEST, "boundTo": _BOUND_TO,
            "tasks": [{"id": "T-1", "disposition": "done", "evidence": None, "commits": [], "review": None}],
            "issues": [], "heads": {"origin": "a" * 40},
        }
        self.assertEqual(validate(instance, load_schema("execute")), [])

    def test_minimal_question_instance_validates(self):
        instance = {
            "questionId": "question-1", "attempt": "attempt-1", "phase": "spec",
            "text": "proceed?", "options": [{"value": "yes", "label": "Yes"}],
            "defaultValue": None, "kind": "approval", "payload": None, "askedAt": "2026-09-21T00:00:00+00:00",
        }
        self.assertEqual(validate(instance, load_schema("question")), [])

    def test_minimal_step_instance_validates(self):
        instance = {
            "stepAttemptId": "step-1", "kind": "role", "role": "implementer", "phase": "execute",
            "cwd": ".", "prompt": "do it", "resultPath": "result.json", "schema": {},
            "postconditions": [], "attempt": "attempt-1", "inputsDigest": _DIGEST,
            "issuedAt": "2026-09-21T00:00:00+00:00", "retryOf": None, "reason": None,
        }
        self.assertEqual(validate(instance, load_schema("step")), [])

    def test_unknown_top_level_key_fails(self):
        instance = {
            "exit": "needs answer", "inputsDigest": _DIGEST, "boundTo": _BOUND_TO,
            "goal": "do the thing", "boundaries": [], "criteria": [{"id": "AC-1", "text": "it works"}],
            "decisions": [], "openQuestions": [], "somethingUnexpected": True,
        }
        errors = validate(instance, load_schema("spec"))
        self.assertTrue(any("somethingUnexpected" in e for e in errors))

    def test_verify_plan_task_def_matches_plan_schema(self):
        # verify.json can only $ref within its own document, so it carries its own copy
        # of the plan task shape; this pins the copy against drift from plan.json.
        verify_schema = load_schema("verify")
        plan_schema = load_schema("plan")
        self.assertEqual(verify_schema["$defs"]["planTask"], plan_schema["properties"]["tasks"]["items"])

    def test_debug_spec_and_plan_defs_match_products_minus_envelope(self):
        # Same reasoning as above: debug.json embeds the spec/plan product shapes
        # verbatim except for the exit/inputsDigest/boundTo envelope debug.json's own
        # top level already carries.
        debug_schema = load_schema("debug")
        spec_schema = load_schema("spec")
        plan_schema = load_schema("plan")

        def without_envelope(schema):
            schema = json.loads(json.dumps(schema))
            for key in ("exit", "inputsDigest", "boundTo"):
                schema["properties"].pop(key, None)
                if key in schema.get("required", []):
                    schema["required"].remove(key)
            return schema

        self.assertEqual(debug_schema["$defs"]["spec"], without_envelope(spec_schema))
        self.assertEqual(debug_schema["$defs"]["plan"], without_envelope(plan_schema))


if __name__ == "__main__":
    unittest.main()
