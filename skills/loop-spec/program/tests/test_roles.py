"""Unit tests for loop_spec.roles: default/bound role loading and prompt composition."""
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from loop_spec.errors import LoopSpecError
from loop_spec.roles import CONTRACTS, ROLE_NAMES, Role, compose_prompt, load_role
from loop_spec.schema import load_schema


class LoadDefaultRoleTests(unittest.TestCase):
    def test_every_default_role_loads(self):
        with tempfile.TemporaryDirectory() as tmp:
            for name in ROLE_NAMES:
                role = load_role(name, Path(tmp))
                self.assertEqual(role.name, name)
                self.assertEqual(role.source, "default")
                self.assertTrue(role.body.strip())
                self.assertIsInstance(role.schema, dict)
                self.assertTrue(role.version.startswith("sha256:"))


class LoadBoundRoleTests(unittest.TestCase):
    def test_bound_skill_found_under_home_keeps_default_schema(self):
        with tempfile.TemporaryDirectory() as fake_home, tempfile.TemporaryDirectory() as project_root:
            skill_dir = Path(fake_home, ".claude", "skills", "custom-spec")
            skill_dir.mkdir(parents=True)
            (skill_dir / "SKILL.md").write_text("---\nname: custom-spec\ndescription: x\n---\n\nCustom body.\n")

            with patch("pathlib.Path.home", return_value=Path(fake_home)):
                role = load_role("spec-writer", Path(project_root), binding="custom-spec")

            self.assertEqual(role.body.strip(), "Custom body.")
            self.assertEqual(role.source, str(skill_dir / "SKILL.md"))
            default_role = load_role("spec-writer", Path(project_root))
            self.assertEqual(role.schema, default_role.schema)

    def test_missing_binding_raises_naming_searched_paths(self):
        with tempfile.TemporaryDirectory() as fake_home, tempfile.TemporaryDirectory() as project_root:
            with patch("pathlib.Path.home", return_value=Path(fake_home)):
                with self.assertRaises(LoopSpecError) as ctx:
                    load_role("planner", Path(project_root), binding="does-not-exist")
            self.assertIn("does-not-exist", ctx.exception.message)
            self.assertIn(str(Path(project_root) / ".claude" / "skills" / "does-not-exist" / "SKILL.md"), ctx.exception.repair)


class ComposePromptTests(unittest.TestCase):
    def test_section_order(self):
        role = Role(name="spec-writer", body="Do the thing.", schema={"type": "object"}, source="default", version="sha256:" + "0" * 64)
        prompt = compose_prompt(role, inputs={"products": {"spec": None}, "note": "hello"}, result_path=Path("/tmp/out/product.json"), cwd=Path("/tmp/out"), phase="spec")
        method_at = prompt.index("## Method")
        contract_at = prompt.index("## loop-spec contract")
        inputs_at = prompt.index("## Inputs")
        output_at = prompt.index("## Output")
        self.assertLess(method_at, contract_at)
        self.assertLess(contract_at, inputs_at)
        self.assertLess(inputs_at, output_at)
        self.assertIn(CONTRACTS["spec-writer"], prompt)
        self.assertIn("### note", prompt)
        self.assertIn("hello", prompt)
        self.assertIn(str(Path("/tmp/out/product.json")), prompt)

    def test_no_contract_section_when_role_has_none(self):
        role = Role(name="debugger", body="Do the thing.", schema={"type": "object"}, source="default", version="sha256:" + "0" * 64)
        prompt = compose_prompt(role, inputs={}, result_path=Path("/tmp/out/product.json"), cwd=Path("/tmp/out"), phase="debug")
        self.assertNotIn("## loop-spec contract", prompt)


class RoleSchemaDriftGuardTests(unittest.TestCase):
    def test_role_schemas_equal_their_product_schemas(self):
        # verifier/iterate-judge are excluded: VERIFY/ITERATE dispatch them as one
        # step in a multi-step flow, so their role.schema is that step's own result
        # shape (see roles/verifier/schema.json, roles/iterate-judge/schema.json),
        # not the full verify.json/iterate.json product the module assembles itself.
        with tempfile.TemporaryDirectory() as tmp:
            pairs = [
                ("spec-writer", "spec"),
                ("planner", "plan"),
                ("debugger", "debug"),
                ("reviser", "revise"),
            ]
            for role_name, product_name in pairs:
                role = load_role(role_name, Path(tmp))
                self.assertEqual(role.schema, load_schema(product_name), role_name)


if __name__ == "__main__":
    unittest.main()
