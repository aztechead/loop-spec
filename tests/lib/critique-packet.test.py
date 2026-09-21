#!/usr/bin/env python3
"""Black-box critique packet regressions; Python 3.7 stdlib only."""
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import unittest
import unittest.mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STEP = ROOT / "lib" / "critique-step.sh"
TASKS = """
## Tasks
### task-001: endpoint
**Goal:** endpoint works
**Files:**
- `api.py`
**Verify:** `pytest tests/test_api.py`
**Acceptance criteria:**
- endpoint returns the expected response
**BlockedBy:** []

### task-002: CSV
**Goal:** CSV works
**Files:**
- `csv.py`
**Verify:** `pytest tests/test_csv.py`
**Acceptance criteria:**
- CSV contains the expected rows
**BlockedBy:** []
"""



def snapshot_render(feature, phase="plan"):
    spec = importlib.util.spec_from_file_location("phase_snapshot", str(ROOT / "lib/phase_snapshot.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.render(str(ROOT), str(feature), phase, phase, "claude", {})


class CritiquePacketTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="critique-packet-"))
        self.feature = self.tmp / "feature"
        self.feature.mkdir()
        subprocess.run(["git", "init", "-q", str(self.tmp)], check=True)
        init = subprocess.run([
            "bash", str(ROOT / "lib/feature-init.sh"), "skeleton", "--mode", "single",
            "--slug", "packet-test", "--now", "2026-09-20T00:00:00Z", "--style", "auto",
            "--title", "packet", "--branch", "feat/packet", "--base-sha", "deadbeef",
            "--base-branch", "main", "--worktree", "", "--prepare", "", "--test", "",
            "--lint", "", "--typecheck", ""], cwd=str(self.feature), capture_output=True,
            text=True, check=True)
        (self.feature / "feature.json").write_text(init.stdout)
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        self.artifact = self.repo / "docs/custom plan &.md"
        self.artifact.parent.mkdir(parents=True)
        self.artifact.write_text("# Plan\n\nInitial\n" + TASKS)
        self.data = json.loads((self.feature / "feature.json").read_text())
        self.data["artifacts"] = {"spec": str(self.repo / "docs/custom spec &.md"), "evidence": str(self.repo / "docs/custom evidence &.md")}
        Path(self.data["artifacts"]["spec"]).write_text("# Spec\n")
        Path(self.data["artifacts"]["evidence"]).write_text("# Evidence\n")
        rendered = snapshot_render(self.feature)
        self.data["driverNext"] = {"phase": "plan", "instructions": rendered}
        (self.feature / "feature.json").write_text(json.dumps(self.data) + "\n")

    def tearDown(self):
        shutil.rmtree(str(self.tmp))

    def run_step(self, command, *args, input_text=None, check=True):
        result = subprocess.run(["bash", str(STEP), command] + list(args) + ["--feature-dir", str(self.feature)], input=input_text, text=True, capture_output=True)
        if check and result.returncode:
            raise AssertionError("critique-step failed: %s" % result.stderr)
        return result

    def open_gate(self, name="plan-critique"):
        return json.loads(self.run_step("open", "--phase", "plan", "--gate", name, "--artifact", str(self.artifact)).stdout)

    def test_shared_readme_refused_before_review_and_repair_preserves_scope(self):
        original = (self.feature / "feature.json").read_bytes()
        stale = self.feature / "tasks.json"
        stale.write_text('[]\n')
        shared = TASKS.replace('- `api.py`', '- `api.py`\n- `README.md`').replace(
            '- `csv.py`', '- `csv.py`\n- `README.md`')
        self.artifact.write_text("# Plan\n" + shared)
        with unittest.mock.patch.dict(os.environ, {"LOOP_SPEC_PLAN_MIN_WIDTH": "2"}):
            failed = self.run_step("open", "--phase", "plan", "--gate", "plan-critique",
                                   "--artifact", str(self.artifact), check=False)
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn("README.md (task-001,task-002)", failed.stderr)
            self.assertEqual((self.feature / "feature.json").read_bytes(), original)
            self.assertFalse((self.feature / "gate-logs/plan-critique-state.json").exists())
            self.assertFalse((self.feature / "gate-logs/plan-critique-round-1-prompt.md").exists())
            self.assertEqual(stale.read_text(), '[]\n')
            # One downstream owner retains both examples and checks in this delivery.
            docs = """
### task-003: document both operations
**Goal:** readers can call the endpoint and export CSV
**Files:**
- `README.md`
**Verify:** `pytest tests/test_readme_examples.py`
**Acceptance criteria:**
- endpoint and CSV examples produce the documented output
**BlockedBy:** [task-001, task-002]
"""
            self.artifact.write_text("# Plan\n" + TASKS + docs)
            opened = self.open_gate()
            self.assertTrue(Path(opened["promptFile"]).is_file())
            self.assertEqual(stale.read_text(), '[]\n')
            packet = Path(opened["promptFile"]).read_bytes()
            state = (self.feature / "feature.json").read_bytes()
            self.artifact.write_text("# Plan\n" + shared)
            failed_resume = self.run_step("resume", check=False)
            self.assertNotEqual(failed_resume.returncode, 0)
            self.assertEqual((self.feature / "feature.json").read_bytes(), state)
            self.assertEqual(Path(opened["promptFile"]).read_bytes(), packet)

    def test_invalid_plan_and_cycle_refused_before_review(self):
        for plan in ("# Plan without tasks\n", TASKS.replace(
                '**BlockedBy:** []', '**BlockedBy:** [task-002]', 1)):
            self.artifact.write_text(plan)
            if "task-002]" in plan:
                self.artifact.write_text(plan.rsplit('**BlockedBy:** []', 1)[0] +
                                         '**BlockedBy:** [task-001]\n')
            result = self.run_step("open", "--phase", "plan", "--gate", "plan-critique",
                                   "--artifact", str(self.artifact), check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((self.feature / "gate-logs/plan-critique-state.json").exists())

    def test_width_one_still_rejects_overlap_cycles(self):
        tasks = [
            {"id": "task-001", "files": ["a.py"], "blockedBy": ["task-003"],
             "verifyCommand": "pytest tests/test_a.py"},
            {"id": "task-002", "files": ["a.py", "b.py"], "blockedBy": [],
             "verifyCommand": "pytest tests/test_b.py"},
            {"id": "task-003", "files": ["b.py"], "blockedBy": [],
             "verifyCommand": "pytest tests/test_c.py"}]
        path = self.feature / "tasks.json"
        path.write_text(json.dumps(tasks))
        with unittest.mock.patch.dict(os.environ, {"LOOP_SPEC_PLAN_MIN_WIDTH": "1"}):
            result = subprocess.run(["bash", str(ROOT / "lib/plan-structure.sh"),
                                     str(self.feature), str(path)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("form a cycle", result.stdout)

    def test_non_plan_critique_does_not_require_task_blocks(self):
        self.data["driverNext"] = {"phase": "spec", "instructions": snapshot_render(self.feature, "spec")}
        (self.feature / "feature.json").write_text(json.dumps(self.data) + "\n")
        self.artifact.write_text("# Specification without task blocks\n")
        opened = self.run_step("open", "--phase", "spec", "--gate", "spec-critique",
                               "--artifact", str(self.artifact))
        self.assertTrue(Path(json.loads(opened.stdout)["promptFile"]).is_file())

    def test_snapshot_tamper_and_custom_paths_fail_closed(self):
        opened = self.open_gate()
        packet = Path(opened["promptFile"])
        self.assertIn(str(self.artifact), packet.read_text())
        manifest = Path(self.data["driverNext"]["instructions"]["manifest"])
        target = manifest.parent / "skills/shared/team-prompts/critic.md"
        target.chmod(0o644)
        target.write_text(target.read_text() + "\nTAMPER\n")
        manifest.chmod(0o644)
        manifest_data = json.loads(manifest.read_text())
        manifest_data["outputs"]["skills/shared/team-prompts/critic.md"] = hashlib.sha256(target.read_bytes()).hexdigest()
        manifest.write_text(json.dumps(manifest_data, sort_keys=True, indent=2) + "\n")
        result = self.run_step("pass", check=False)
        self.assertEqual(result.returncode, 0)
        # A new open verifies the original recorded manifest and refuses tamper.
        result = self.run_step("open", "--phase", "plan", "--gate", "tampered", "--artifact", str(self.artifact), check=False)
        self.assertEqual(result.returncode, 1)
        state = json.loads((self.feature / "feature.json").read_text())
        self.assertIsNone(state["currentGate"]["phase"])

    def test_reopen_refusal_preserves_packet_bytes(self):
        opened = self.open_gate()
        packet = Path(opened["promptFile"])
        original = packet.read_bytes()
        refused = self.run_step("open", "--phase", "plan", "--gate", "again", "--artifact", str(self.artifact), check=False)
        self.assertNotEqual(refused.returncode, 0)
        self.assertEqual(packet.read_bytes(), original)

    def test_delta_resume_kind_model_and_legacy_sidecar(self):
        data = json.loads((self.feature / "feature.json").read_text())
        data["models"]["challenger"] = "custom-model"
        (self.feature / "feature.json").write_text(json.dumps(data) + "\n")
        self.open_gate()
        self.run_step("findings", "--reply", "-", input_text="FINDINGS:\n[major] fix\n")
        self.run_step("fail", "--fix-list", "-", input_text="[major] fix\n")
        self.artifact.write_text("# Plan\n\nFixed\n" + TASKS)
        revised = json.loads(self.run_step("revised").stdout)
        delta_diff = Path(revised["diffPath"])
        saved_diff = delta_diff.read_bytes()
        delta_diff.unlink()
        before_missing = json.loads((self.feature / "feature.json").read_text())["currentGate"]
        missing = self.run_step("resume", check=False)
        self.assertEqual(missing.returncode, 1)
        self.assertEqual(json.loads((self.feature / "feature.json").read_text())["currentGate"], before_missing)
        delta_diff.write_bytes(saved_diff)
        resumed = json.loads(self.run_step("resume").stdout)
        self.assertEqual(resumed["promptFile"], revised["promptFile"])
        self.assertEqual(resumed.get("kind"), "delta")
        self.assertEqual(resumed.get("model"), "custom-model")
        self.assertIn("Delta re-verify pass", Path(resumed["promptFile"]).read_text())
        self.assertEqual(json.loads((self.feature / "feature.json").read_text())["currentGate"]["round"], 1)

        self.run_step("pass")
        opened = self.open_gate("legacy")
        state_file = self.feature / "gate-logs/legacy-state.json"
        state = json.loads(state_file.read_text())
        Path(opened["promptFile"]).unlink()
        state.pop("promptFile", None)
        state_file.write_text(json.dumps(state) + "\n")
        before = json.loads((self.feature / "feature.json").read_text())["currentGate"]
        resumed = json.loads(self.run_step("resume").stdout)
        self.assertTrue(Path(resumed["promptFile"]).exists())
        self.assertEqual(json.loads((self.feature / "feature.json").read_text())["currentGate"], before)

    def test_legacy_round_one_resume_has_findings_kind_and_prior_context(self):
        self.open_gate("legacy-round-one")
        self.run_step("findings", "--reply", "-", input_text="FINDINGS:\n[major] preserve context\n")
        state_file = self.feature / "gate-logs/legacy-round-one-state.json"
        state = json.loads(state_file.read_text())
        Path(state["promptFile"]).unlink()
        state.pop("promptFile", None)
        state.pop("kind", None)
        state_file.write_text(json.dumps(state) + "\n")
        (self.feature / "gate-logs/legacy-round-one-delta.diff").write_text("stale delta\n")
        resumed = json.loads(self.run_step("resume").stdout)
        self.assertEqual(resumed.get("kind"), "findings")
        self.assertTrue(Path(resumed["promptFile"]).exists())
        first_packet = Path(resumed["promptFile"]).read_text()
        self.assertIn("Resume context:", first_packet)
        resumed_again = json.loads(self.run_step("resume").stdout)
        second_packet = Path(resumed_again["promptFile"]).read_text()
        self.assertEqual(resumed_again["promptFile"], resumed["promptFile"])
        self.assertEqual(second_packet, first_packet)

    def test_malformed_record_and_missing_section_fail_before_open(self):
        data = json.loads((self.feature / "feature.json").read_text())
        data["driverNext"]["instructions"]["sha256"] = "wrong"
        (self.feature / "feature.json").write_text(json.dumps(data) + "\n")
        result = self.run_step("open", "--phase", "plan", "--gate", "bad-record", "--artifact", str(self.artifact), check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIsNone(json.loads((self.feature / "feature.json").read_text())["currentGate"]["phase"])

    def test_missing_required_section_with_consistent_manifest_fails(self):
        data = json.loads((self.feature / "feature.json").read_text())
        manifest = Path(data["driverNext"]["instructions"]["manifest"])
        directory = manifest.parent
        target = directory / "skills/shared/team-prompts/critic.md"
        target.chmod(0o644)
        target.write_text(target.read_text().replace("## Rules", ""))
        manifest.chmod(0o644)
        md = json.loads(manifest.read_text())
        md["outputs"]["skills/shared/team-prompts/critic.md"] = hashlib.sha256(target.read_bytes()).hexdigest()
        prompt = directory / md["prompt"]
        prompt.chmod(0o644)
        prompt.write_text(prompt.read_text().replace("## Rules", ""))
        md["outputs"][md["prompt"]] = hashlib.sha256(prompt.read_bytes()).hexdigest()
        manifest.write_text(json.dumps(md, sort_keys=True, indent=2) + "\n")
        data["driverNext"]["instructions"]["sha256"] = hashlib.sha256(manifest.read_bytes()).hexdigest()
        data["driverNext"]["instructions"]["promptSha256"] = hashlib.sha256(prompt.read_bytes()).hexdigest()
        (self.feature / "feature.json").write_text(json.dumps(data) + "\n")
        result = self.run_step("open", "--phase", "plan", "--gate", "section-loss", "--artifact", str(self.artifact), check=False)
        self.assertEqual(result.returncode, 1)

    def test_packet_budget_is_below_full_contract_plus_equivalent_metadata(self):
        opened = self.open_gate()
        packet_size = Path(opened["promptFile"]).stat().st_size
        template_size = (ROOT / "skills/shared/team-prompts/critic.md").stat().st_size
        metadata = sum(len(str(self.data["artifacts"][key]).encode()) for key in ("spec", "evidence")) + len(str(self.artifact).encode()) + len("[major] fixed finding\n".encode())
        self.assertLessEqual(packet_size + len("[major] fixed finding\n".encode()), template_size + metadata)

    def test_recorded_snapshot_wins_over_other_snapshot_and_relative_feature_path(self):
        recorded = self.data["driverNext"]["instructions"]["manifest"]
        selected_dir = Path(recorded).parent
        selected_critic = selected_dir / "skills/shared/team-prompts/critic.md"
        selected_critic.chmod(0o644)
        selected_critic.write_text(selected_critic.read_text() + "\nSELECTED-SNAPSHOT\n")
        selected_prompt = selected_dir / json.loads(Path(recorded).read_text())["prompt"]
        selected_prompt.chmod(0o644)
        selected_prompt.write_text(selected_prompt.read_text() + "\nSELECTED-SNAPSHOT\n")
        selected_manifest = Path(recorded)
        selected_manifest.chmod(0o644)
        selected_data = json.loads(selected_manifest.read_text())
        selected_data["outputs"]["skills/shared/team-prompts/critic.md"] = hashlib.sha256(selected_critic.read_bytes()).hexdigest()
        selected_data["outputs"][selected_data["prompt"]] = hashlib.sha256(selected_prompt.read_bytes()).hexdigest()
        selected_manifest.write_text(json.dumps(selected_data, sort_keys=True, indent=2) + "\n")
        self.data["driverNext"]["instructions"]["sha256"] = hashlib.sha256(selected_manifest.read_bytes()).hexdigest()
        self.data["driverNext"]["instructions"]["promptSha256"] = hashlib.sha256(selected_prompt.read_bytes()).hexdigest()
        (self.feature / "feature.json").write_text(json.dumps(self.data) + "\n")
        snapshot_render(self.feature)  # creates a second stale snapshot
        relative_feature = os.path.relpath(str(self.feature), str(self.tmp))
        result = subprocess.run(["bash", str(STEP), "open", "--phase", "plan", "--gate", "selected", "--artifact", str(self.artifact), "--feature-dir", relative_feature], cwd=str(self.tmp), text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        opened = json.loads(result.stdout)
        self.assertTrue(Path(opened["promptFile"]).is_absolute())
        self.assertIn("SELECTED-SNAPSHOT", Path(opened["promptFile"]).read_text())


if __name__ == "__main__":
    unittest.main()
