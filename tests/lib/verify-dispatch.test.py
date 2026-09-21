#!/usr/bin/env python3
"""Verifier packet boundaries: faithful contracts, fresh inputs, and no bad dispatch."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "lib"))
import phase_snapshot
import verify_dispatch


class VerifyDispatchTest(unittest.TestCase):
    def setUp(self):
        self.repo = Path(tempfile.mkdtemp(prefix="verifier packet ")).resolve()
        self.git_repo(self.repo)
        self.fd = self.repo / ".loop-spec/features/packet"
        self.fd.mkdir(parents=True)
        self.feature = {"slug": "packet", "branch": "main", "baseSha": "base-source",
                        "models": {"verifier": "custom-model"},
                        "artifacts": {"spec": "docs/custom spec.md", "plan": "docs/custom plan.md",
                                      "verification": str(self.repo / "docs/custom verification.md")}}
        (self.fd / "feature.json").write_text(json.dumps(self.feature))
        self.instructions = phase_snapshot.render(ROOT, self.fd, "verify", "verify", "claude", {})
        self.prepared = {"route": "continue", "mode": {"acceptance": "run"},
                         "validation": {"ran": True, "rc": 0, "outcome": "accepted",
                                        "result": {"outcome": "accepted", "targets": [{"retained": ["known failure"]}]}}}

    def tearDown(self):
        shutil.rmtree(self.repo)

    def git_repo(self, path):
        subprocess.run(["git", "init", "-q", "-b", "main", str(path)], check=True)
        subprocess.run(["git", "-C", str(path), "-c", "user.name=test", "-c", "user.email=test@example.invalid",
                        "commit", "-q", "--allow-empty", "-m", "seed"], check=True)

    def render(self):
        return verify_dispatch.render(ROOT, self.fd, self.repo, self.feature, self.instructions, self.prepared)

    def assignment(self, packet):
        text = Path(packet["promptFile"]).read_text()
        return json.loads(text.split("```json\n", 1)[1].split("\n```", 1)[0]), text

    def test_faithful_sources_and_absolute_artifacts(self):
        packet = self.render()
        self.assertEqual(packet["model"], "custom-model")
        self.assertEqual(packet["subagentType"], "loop-spec:verifier")
        assignment, text = self.assignment(packet)
        snapshot = Path(self.instructions["manifest"]).parent
        for name in ("agents/verifier.md", "skills/shared/verification-grounding.md"):
            self.assertIn((snapshot / name).read_text(), text)
        self.assertEqual(assignment["validation_json"], self.prepared["validation"]["result"])
        self.assertEqual(assignment["spec_path"], str(self.repo / "docs/custom spec.md"))
        self.assertEqual(assignment["verification_path"], str(self.repo / "docs/custom verification.md"))
        self.assertTrue(Path(assignment["template_path"]).is_file())
        self.assertIn(snapshot, Path(assignment["template_path"]).parents)
        self.assertEqual(assignment["targets"][0]["candidate_sha"], subprocess.check_output(
            ["git", "-C", str(self.repo), "rev-parse", "HEAD"], text=True).strip())

    def test_failed_preparation_and_skipped_acceptance_emit_no_assignment(self):
        for route in ("remediate", "escalate"):
            self.prepared["route"] = route
            self.assertIsNone(self.render())
        self.prepared["route"] = "continue"
        self.prepared["mode"]["acceptance"] = "skip"
        self.assertIsNone(self.render())
        self.assertFalse((self.fd / "dispatch/verify-verifier-brief.md").exists())

    def test_validation_failure_is_not_relabelled_as_accepted(self):
        self.prepared["validation"]["outcome"] = "regression"
        with self.assertRaises(ValueError):
            self.render()
        self.assertFalse((self.fd / "dispatch/verify-verifier-brief.md").exists())

    def test_skipped_validation_is_explicit_not_a_fake_pass(self):
        self.prepared["validation"] = {"ran": False, "rc": 0, "outcome": None, "result": None}
        assignment, _ = self.assignment(self.render())
        self.assertFalse(assignment["repository_validation_ran"])
        self.assertIsNone(assignment["validation_json"])

    def test_tampered_snapshot_cannot_replace_existing_packet(self):
        packet = Path(self.render()["promptFile"])
        original = packet.read_bytes()
        source = Path(self.instructions["manifest"]).parent / "skills/shared/verification-grounding.md"
        source.chmod(0o644)
        source.write_text("tampered contract")
        with self.assertRaises(ValueError):
            self.render()
        self.assertEqual(packet.read_bytes(), original)

    def test_workspace_preserves_each_repository_base_and_revision(self):
        second = self.repo / "other repository"
        self.git_repo(second)
        subprocess.run(["git", "-C", str(second), "-c", "user.name=test", "-c", "user.email=test@example.invalid",
                        "commit", "-q", "--allow-empty", "-m", "second revision"], check=True)
        self.feature["workspace"] = {"mode": "multi", "repos": [
            {"path": ".", "branch": "main", "baseSha": "first-base"},
            {"path": "other repository", "branch": "main", "baseSha": "second-base"}]}
        assignment, _ = self.assignment(self.render())
        self.assertEqual([r["base_sha"] for r in assignment["targets"]], ["first-base", "second-base"])
        self.assertEqual([r["root"] for r in assignment["targets"]], [str(self.repo), str(second)])
        expected = [subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()
                    for path in (self.repo, second)]
        self.assertNotEqual(expected[0], expected[1])
        self.assertEqual([r["candidate_sha"] for r in assignment["targets"]], expected)


if __name__ == "__main__":
    unittest.main()
