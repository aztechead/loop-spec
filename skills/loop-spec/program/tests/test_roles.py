"""Unit tests for loop_spec.roles: default/bound role loading and prompt composition."""
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from loop_spec import contract
from loop_spec.errors import LoopSpecError
from loop_spec.jsonio import atomic_write_json
from loop_spec.contract import EFFORT_LEVELS, ROLE_NAMES, role_meta
from loop_spec.roles import Role, compose_prompt, load_role, principles, repo_map, resolve_effort, resolve_model, role_contract
from loop_spec.schema import load_schema, validate


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


class RoleExampleTests(unittest.TestCase):
    def test_each_default_role_example_validates_against_its_schema(self):
        # A role's one example is copied by the model it guides; a stale one teaches the wrong shape.
        import re
        with tempfile.TemporaryDirectory() as tmp:
            for name in ROLE_NAMES:
                role = load_role(name, Path(tmp))
                block = re.search(r"## Example\n.*?```json\n(.*?)\n```", role.body, re.S)
                self.assertIsNotNone(block, name)
                self.assertEqual(validate(json.loads(block.group(1)), role.schema), [], name)


class CloseOutSchemaTests(unittest.TestCase):
    # LF-55: a close-out is task C-n; an ITERATE execute gap may name its repo.
    def test_implementer_result_accepts_plan_remediation_and_close_out_ids(self):
        with tempfile.TemporaryDirectory() as tmp:
            schema = load_role("implementer", Path(tmp)).schema
        for task_id in ("T-1", "R-2", "C-3"):
            result = {"taskId": task_id, "commits": [], "summary": "s", "verifyRun": {"command": "c", "exitStatus": 0}, "issues": []}
            self.assertEqual(validate(result, schema), [], task_id)

    def test_gap_repo_in_both_iterate_schemas_and_finding_id_only_in_the_product(self):
        with tempfile.TemporaryDirectory() as tmp:
            judge = load_role("iterate-judge", Path(tmp)).schema
        gap = {"target": "execute", "text": "x", "repo": "calc"}
        self.assertEqual(validate({"verdict": "unmet", "gaps": [gap], "caveats": []}, judge), [])
        self.assertNotEqual(validate({"verdict": "unmet", "gaps": [gap | {"findingId": "F-1"}], "caveats": []}, judge), [])
        product = {"exit": "rewind", "inputsDigest": "sha256:" + "0" * 64, "boundTo": {"requirements": None, "plan": None},
                   "verdict": "unmet", "gaps": [gap | {"findingId": "F-1"}], "caveats": [], "boundShas": {}}
        self.assertEqual(validate(product, load_schema("iterate")), [])


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

    def test_plugin_binding_reads_the_installed_version_and_resolves_its_placeholders(self):
        with tempfile.TemporaryDirectory() as fake_home, tempfile.TemporaryDirectory() as project_root:
            cache = Path(fake_home, ".claude", "plugins", "cache", "mkt", "myplug")
            for version in ("aaa-stale", "zzz-installed"):
                (cache / version / "skills" / "rev").mkdir(parents=True)
                (cache / version / ".claude-plugin").mkdir()
                (cache / version / ".claude-plugin" / "plugin.json").write_text(json.dumps({"name": "myplug"}))
                (cache / version / "skills" / "rev" / "SKILL.md").write_text(
                    f"{version} ${{CLAUDE_SKILL_DIR}}/ref.md ${{CLAUDE_PLUGIN_ROOT}}/bin\n")
            installed = cache / "zzz-installed"
            Path(fake_home, ".claude", "plugins", "installed_plugins.json").write_text(json.dumps(
                {"version": 2, "plugins": {"myplug@mkt": [{"scope": "user", "installPath": str(installed)}]}}))

            with patch("pathlib.Path.home", return_value=Path(fake_home)):
                role = load_role("reviser", Path(project_root), binding="myplug:rev")

            self.assertEqual(role.body.strip(), f"zzz-installed {installed}/skills/rev/ref.md {installed}/bin")

            # A malformed registry is skipped, not fatal: the cache, newest first, answers.
            Path(fake_home, ".claude", "plugins", "installed_plugins.json").write_text('{"plugins": ["not", "a", "map"]')
            os.utime(cache / "zzz-installed" / "skills" / "rev" / "SKILL.md", (1, 1))
            with patch("pathlib.Path.home", return_value=Path(fake_home)):
                self.assertTrue(load_role("reviser", Path(project_root), binding="myplug:rev").body.startswith("aaa-stale"))

    def test_plugin_root_resolves_only_in_a_plugin(self):
        with tempfile.TemporaryDirectory() as fake_home, tempfile.TemporaryDirectory() as project_root:
            skill_dir = Path(project_root, ".claude", "skills", "local")
            skill_dir.mkdir(parents=True)
            (skill_dir / "SKILL.md").write_text("${CLAUDE_SKILL_DIR} ${CLAUDE_PLUGIN_ROOT}\n")
            with patch("pathlib.Path.home", return_value=Path(fake_home)):
                role = load_role("reviser", Path(project_root), binding="local")
            self.assertEqual(role.body.strip(), f"{skill_dir} ${{CLAUDE_PLUGIN_ROOT}}")

    def test_a_plugin_loaded_by_path_resolves_through_loop_spec_plugin_dirs(self):
        with tempfile.TemporaryDirectory() as fake_home, tempfile.TemporaryDirectory() as plugin_dir:
            Path(plugin_dir, ".claude-plugin").mkdir()
            Path(plugin_dir, ".claude-plugin", "plugin.json").write_text(json.dumps({"name": "local-plug"}))
            Path(plugin_dir, "skills", "rev").mkdir(parents=True)
            Path(plugin_dir, "skills", "rev", "SKILL.md").write_text("Local body.\n")
            with patch("pathlib.Path.home", return_value=Path(fake_home)), \
                    patch.dict("os.environ", {"LOOP_SPEC_PLUGIN_DIRS": plugin_dir}):
                role = load_role("reviser", Path(fake_home), binding="local-plug:rev")
            self.assertEqual(role.body.strip(), "Local body.")

    def test_with_skills_follow_the_default_method(self):
        with tempfile.TemporaryDirectory() as fake_home, tempfile.TemporaryDirectory() as project_root:
            skill_dir = Path(project_root, ".claude", "skills", "pr-helper")
            skill_dir.mkdir(parents=True)
            (skill_dir / "SKILL.md").write_text("---\nname: pr-helper\n---\n\nRead ${CLAUDE_SKILL_DIR}/notes.md.\n")
            Path(project_root, ".loop-spec").mkdir()
            Path(project_root, ".loop-spec", "config.json").write_text(json.dumps({"roles": {"reviser": {"with": ["pr-helper"]}}}))

            with patch("pathlib.Path.home", return_value=Path(fake_home)):
                role = load_role("reviser", Path(project_root))

            default_body = load_role("reviser", Path(fake_home)).body.rstrip()
            self.assertTrue(role.body.startswith(default_body))
            self.assertTrue(role.body.endswith(f"### Also follow the `pr-helper` skill\n\nRead {skill_dir}/notes.md.\n"))
            self.assertEqual(role.source, "default")

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
        self.assertIn(role_contract("spec-writer"), prompt)
        self.assertIn("### note", prompt)
        self.assertIn("hello", prompt)
        self.assertIn(str(Path("/tmp/out/product.json")), prompt)

    def test_first_principles_precede_the_method_whatever_skill_is_bound(self):
        role = Role(name="implementer", body="A borrowed method.", schema={"type": "object"}, source="/elsewhere/SKILL.md", version="sha256:" + "0" * 64)
        prompt = compose_prompt(role, inputs={}, result_path=Path("/tmp/out/product.json"), cwd=Path("/tmp/out"), phase="execute")
        self.assertIn("first principles", principles())
        self.assertIn("## First principles\n" + principles(), prompt)
        self.assertLess(prompt.index("## First principles"), prompt.index("## Method"))

    def test_string_input_ending_in_newline_leaves_one_blank_line_before_the_next_section(self):
        role = Role(name="code-reviewer", body="Review.", schema={"type": "object"}, source="default", version="sha256:" + "0" * 64)
        diff = "diff --git a/x.py b/x.py\n@@ -1,3 +1,3 @@\n context\n \n-old\n+new\n"
        literal = "expected:\n\n\nthree blank-line gap"
        prompt = compose_prompt(role, inputs={"diff": diff, "literal": literal, "probes": {}},
                                result_path=Path("/tmp/out/product.json"), cwd=Path("/tmp/out"), phase="execute")
        self.assertIn("### diff\n" + diff.rstrip("\n") + "\n\n### literal\n", prompt)
        self.assertIn(" context\n \n-old\n+new", prompt)  # whitespace-only context line kept
        self.assertIn("### literal\n" + literal + "\n\n### probes", prompt)  # interior blank run kept

    def test_json_inputs_render_non_ascii_as_itself_and_keep_literal_escapes(self):
        # LF-57: a lead re-typing the prompt writes the character, never its \\u escape.
        role = Role(name="iterate-judge", body="Judge.", schema={"type": "object"}, source="default", version="sha256:" + "0" * 64)
        value = {"verdicts": [{"cause": "return 0 \u2014 matches", "note": "café 🙂"}], "literal": "the text \\u2014 stays six characters"}
        prompt = compose_prompt(role, inputs={"verify": value}, result_path=Path("/tmp/out/product.json"), cwd=Path("/tmp/out"), phase="iterate")
        self.assertIn('"cause": "return 0 \u2014 matches"', prompt)
        self.assertIn('"note": "café 🙂"', prompt)
        self.assertIn('"literal": "the text \\\\u2014 stays six characters"', prompt)
        block = prompt.split("### verify\n```json\n", 1)[1].split("\n```", 1)[0]
        self.assertEqual(json.loads(block), value)

    def test_a_long_multiline_string_nested_in_an_input_gets_its_own_section(self):
        # A diff or pasted log inside a dict/list rendered as one escaped JSON line,
        # over the read budget; it now follows its parent as real lines.
        role = Role(name="code-reviewer", body="Review.", schema={"type": "object"}, source="default", version="sha256:" + "0" * 64)
        long_text = "".join(f"+line {i} é\n" for i in range(200))
        value = [{"id": "T-1", "diff": long_text, "note": "short\ntext"}]
        prompt = compose_prompt(role, inputs={"tasks": value, "after": "x"},
                                result_path=Path("/tmp/out/product.json"), cwd=Path("/tmp/out"), phase="execute")
        block = prompt.split("### tasks\n```json\n", 1)[1].split("\n```", 1)[0]
        self.assertEqual(json.loads(block), [{"id": "T-1", "diff": "<see input tasks[0].diff>", "note": "short\ntext"}])
        self.assertIn("\n```\n\n### tasks[0].diff\n+line 0 é\n+line 1 é\n", prompt)
        self.assertIn("+line 199 é\n\n### after\nx", prompt)

    def test_debugger_contract_forbids_repair(self):
        # LF-22: the debugger lead step fixed a failing test in the user's own
        # checkout; the contract text reaching its prompt must say plainly it
        # does not, before anything else in the section.
        role = Role(name="debugger", body="Do the thing.", schema={"type": "object"}, source="default", version="sha256:" + "0" * 64)
        prompt = compose_prompt(role, inputs={}, result_path=Path("/tmp/out/product.json"), cwd=Path("/tmp/out"), phase="debug")
        self.assertIn(role_contract("debugger"), prompt)
        self.assertTrue(role_contract("debugger").startswith("You do not repair anything. You modify no file."))

    def test_spec_writer_contract_forbids_delivery_facts_as_criteria(self):
        # LF-26: the spec-writer wrote a criterion about a pull request existing,
        # which no VERIFY run can prove before DELIVER; the contract text must
        # name pull requests among the delivery facts a criterion is never about.
        self.assertIn("pull request", role_contract("spec-writer"))

    def test_planner_contract_names_inputs_repos_for_task_repo_names(self):
        # LF-31: the debugger wrote a compact plan task with repo "." instead of
        # a real repo name; the contract text must point at inputs.repos as the
        # only valid source for a task's repo field.
        self.assertIn("inputs.repos", role_contract("planner"))

    def test_no_contract_section_when_role_has_none(self):
        # Every real role name now has a contract.md (debugger's joined the
        # rest under LF-22); this exercises the "none" branch with a name that
        # deliberately is not one.
        role = Role(name="made-up-role", body="Do the thing.", schema={"type": "object"}, source="default", version="sha256:" + "0" * 64)
        prompt = compose_prompt(role, inputs={}, result_path=Path("/tmp/out/product.json"), cwd=Path("/tmp/out"), phase="debug")
        self.assertNotIn("## loop-spec contract", prompt)

    def test_micro_preset_reaches_the_composed_prompt(self):
        role = Role(name="spec-writer", body="Do the thing.", schema={"type": "object"}, source="default", version="sha256:" + "0" * 64)
        inputs = {"entry": {"mode": "fresh", "payload": {"preset": "micro"}}}
        prompt = compose_prompt(role, inputs=inputs, result_path=Path("/tmp/out/product.json"), cwd=Path("/tmp/out"), phase="spec")
        self.assertIn("micro", prompt)


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


class PlanCriticSchemaTests(unittest.TestCase):
    """LF-54: `recommendation` is optional in the schema (older and bound critics stay
    valid in 7.0.x) and well-formed when present."""

    def test_recommendation_is_optional_and_checked(self):
        with tempfile.TemporaryDirectory() as tmp:
            schema = load_role("plan-critic", Path(tmp)).schema
        finding = {"id": "F-1", "location": "T-1.verify", "cause": "c", "severity": "Critical"}
        self.assertEqual(validate({"findings": [finding]}, schema), [])
        ok = dict(finding, recommendation={"action": "reject", "reason": "compared by identity"})
        self.assertEqual(validate({"findings": [ok]}, schema), [])
        bad = dict(finding, recommendation={"action": "close", "reason": "x"})
        self.assertNotEqual(validate({"findings": [bad]}, schema), [])


class RepoMapTests(unittest.TestCase):
    def test_start_is_the_adopted_head_or_the_base(self):
        # F1: an adopted PR's repo starts at the PR head (lastKnownHead), a fresh repo at its base.
        repos = {
            "adopted": {"path": "/a", "baseSha": "b" * 40, "lastKnownHead": "h" * 40},
            "fresh": {"path": "/f", "baseSha": "c" * 40, "lastKnownHead": "c" * 40},
        }
        mapped = repo_map(repos)
        self.assertEqual(mapped["adopted"], {"path": "/a", "baseSha": "b" * 40, "startSha": "h" * 40,
                                             "codePath": "/a", "codeSha": "h" * 40})
        self.assertEqual(mapped["fresh"]["startSha"], "c" * 40)
        # 7.4.2: the code checkout the program made, when there is one.
        repos["adopted"]["codeCheckout"] = {"path": "/run/checkouts/code-adopted", "sha": "h" * 40}
        self.assertEqual(repo_map(repos)["adopted"]["codePath"], "/run/checkouts/code-adopted")


class ResolveEffortTests(unittest.TestCase):
    """F5: a role's effort resolves like its model: env, then config, else the role's default."""

    def _root(self, tmp: str, roles: dict) -> Path:
        root = Path(tmp)
        (root / ".loop-spec").mkdir()
        atomic_write_json(root / ".loop-spec" / "config.json", {"roles": roles})
        return root

    def test_env_beats_config_beats_default(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = self._root(tmp, {"code-reviewer": {"effort": "high"}, "verifier": {"effort": None}})
            with patch.dict("os.environ", {"LOOP_SPEC_EFFORT_CODE_REVIEWER": "low"}, clear=True):
                self.assertEqual(resolve_effort(root, "code-reviewer"), "low")
            with patch.dict("os.environ", {}, clear=True):
                self.assertEqual(resolve_effort(root, "code-reviewer"), "high")
                self.assertEqual(resolve_effort(root, "implementer"), "medium")  # 7.7.4 default
                self.assertIsNone(resolve_effort(root, "verifier"))  # an explicit null inherits
                self.assertIsNone(resolve_effort(root, "planner"))  # a lead role has no default

    def test_a_level_outside_the_host_list_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = self._root(tmp, {"code-reviewer": {"effort": "extreme"}})
            with self.assertRaises(LoopSpecError):  # at the first config read, not mid-step
                contract.load_config(root)
        with tempfile.TemporaryDirectory() as tmp:
            root = self._root(tmp, {})
            with patch.dict("os.environ", {"LOOP_SPEC_EFFORT_IMPLEMENTER": "turbo"}, clear=True):
                with self.assertRaises(LoopSpecError):
                    resolve_effort(root, "implementer")


class RoleRegistryTests(unittest.TestCase):
    """7.5.0: a role's own directory declares what the program knows about it; the core
    names no role in a table of its own."""

    def test_every_role_declares_valid_facts(self):
        for name in ROLE_NAMES:
            meta = role_meta(name)
            with self.subTest(role=name):
                self.assertEqual("model" in meta, "effort" in meta)  # a dispatch default names both
                self.assertIn(meta.get("effort", "high"), EFFORT_LEVELS)
                self.assertIn(meta.get("evidence", "judgment"), ("judgment", "review"))

    def test_the_judgment_roles_require_attestation(self):
        # LF-60's four: nothing but the transcript backs their evidence.
        self.assertEqual({name: role_meta(name).get("evidence") for name in ROLE_NAMES if role_meta(name).get("evidence")},
                         {"code-reviewer": "review", "iterate-judge": "judgment", "plan-critic": "judgment", "router": "judgment"})


class ResolveModelTests(unittest.TestCase):
    """Post-hardening item 3, Part B: every role dispatch's model, not just
    SPEC/PLAN's. roles.<role> config accepts both shapes: a plain string is
    still just the binding (contract.resolve_role), an object also carries a
    model (roles.resolve_model); contract.resolve_role reads the same object's
    "binding" so the two never disagree about which skill is bound."""

    def test_env_wins_over_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".loop-spec").mkdir()
            atomic_write_json(root / ".loop-spec" / "config.json",
                               {"roles": {"implementer": {"binding": "custom-skill", "model": "config-model"}}})
            with patch.dict("os.environ", {"LOOP_SPEC_MODEL_IMPLEMENTER": "env-model"}, clear=True):
                self.assertEqual(resolve_model(root, "implementer"), "env-model")

    def test_object_form_config_yields_binding_and_model(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".loop-spec").mkdir()
            atomic_write_json(root / ".loop-spec" / "config.json",
                               {"roles": {"code-reviewer": {"binding": "custom-skill", "model": "config-model"}}})
            with patch.dict("os.environ", {}, clear=True):
                self.assertEqual(contract.resolve_role(root, "code-reviewer"), "custom-skill")
                self.assertEqual(resolve_model(root, "code-reviewer"), "config-model")

    def test_string_form_config_yields_binding_and_the_default_model(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".loop-spec").mkdir()
            atomic_write_json(root / ".loop-spec" / "config.json", {"roles": {"verifier": "custom-skill"}})
            with patch.dict("os.environ", {}, clear=True):
                self.assertEqual(contract.resolve_role(root, "verifier"), "custom-skill")
                self.assertEqual(resolve_model(root, "verifier"), "sonnet")

    def test_nothing_configured_is_the_default(self):
        # 7.5.0: judgment on Opus, implementation on Sonnet; a lead role inherits the session.
        with tempfile.TemporaryDirectory() as tmp, patch.dict("os.environ", {}, clear=True):
            self.assertEqual({r: resolve_model(Path(tmp), r) for r in ("code-reviewer", "implementer", "planner")},
                             {"code-reviewer": "opus", "implementer": "sonnet", "planner": None})

    def test_phase_model_beats_the_role_default_but_not_the_role_setting(self):
        # 6.x's LOOP_SPEC_PHASE_MODEL_<PHASE>: every role in the phase, unless its own is set.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".loop-spec").mkdir()
            atomic_write_json(root / ".loop-spec" / "config.json",
                               {"roles": {"plan-critic": {"binding": "plan-critic", "model": "config-model"},
                                          "spec-writer": {"binding": "spec-writer", "model": None}}})
            env = {"LOOP_SPEC_PHASE_MODEL_PLAN": "phase-model", "LOOP_SPEC_MODEL_IMPLEMENTER": "role-env"}
            with patch.dict("os.environ", env, clear=True):
                self.assertEqual(resolve_model(root, "planner", "plan"), "phase-model")
                self.assertEqual(resolve_model(root, "plan-critic", "plan"), "config-model")
                self.assertEqual(resolve_model(root, "implementer", "plan"), "role-env")
                self.assertEqual(resolve_model(root, "verifier", "verify"), "sonnet")
                self.assertIsNone(resolve_model(root, "planner"))
            with patch.dict("os.environ", {"LOOP_SPEC_PHASE_MODEL_SPEC": "phase-model"}, clear=True):
                self.assertIsNone(resolve_model(root, "spec-writer", "spec"))  # explicit null inherits


if __name__ == "__main__":
    unittest.main()
