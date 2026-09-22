"""Unit tests for loop_spec.steps: issue/submit/retire and evidence levels."""
import subprocess
import tempfile
import unittest
from pathlib import Path

from loop_spec import steps
from loop_spec.errors import LoopSpecError
from loop_spec.ids import digest, digest_bytes
from loop_spec.jsonio import atomic_write_json, read_json
from loop_spec.paths import FeaturePaths
from loop_spec.repo import add_worktree, head_sha
from loop_spec.state import StateStore

_RESULT_SCHEMA = {"type": "object", "required": ["ok"], "properties": {"ok": {"type": "boolean"}}}


class _FakeAttestor:
    def __init__(self, ok: bool, reason: str) -> None:
        self.ok = ok
        self.reason = reason

    def attest(self, step, result_digest, dispatch_name):
        return self.ok, self.reason


def _git(cwd, *args):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True)


class StepsTestCase(unittest.TestCase):
    def _store(self, tmp) -> tuple[StateStore, FeaturePaths]:
        paths = FeaturePaths(root=Path(tmp) / "feature")
        store = StateStore.create(paths, {"id": "run-1", "entry": "cycle"}, "do the thing")
        return store, paths

    def _issue(self, store, paths, **overrides) -> dict:
        kwargs = dict(
            phase="execute", attempt_id="attempt-1", kind="role", role="implementer",
            cwd=Path("/repo"), prompt="do the task", schema=_RESULT_SCHEMA,
            postconditions=["E1"], inputs_digest=digest({"x": 1}),
        )
        kwargs.update(overrides)
        return steps.issue(store, paths, **kwargs)


class IssueTests(StepsTestCase):
    def test_issue_writes_step_json_with_trailer(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            record = self._issue(store, paths)
            on_disk = (paths.steps_dir / record["stepAttemptId"] / "step.json").read_text(encoding="utf-8")
            self.assertIn("--- loop-spec step ---", on_disk)
            self.assertIn(f"step: {record['stepAttemptId']}", on_disk)
            self.assertIn("LOOP_SPEC_RESULT_DIGEST", on_disk)


class SubmitTests(StepsTestCase):
    def test_submit_missing_result(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            record = self._issue(store, paths)
            with self.assertRaises(LoopSpecError):
                steps.submit(store, paths, step_id=record["stepAttemptId"], dispatch_name=None, host=None)

    def test_submit_partial_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            record = self._issue(store, paths)
            Path(record["resultPath"]).write_text('{"ok": true', encoding="utf-8")
            with self.assertRaises(LoopSpecError):
                steps.submit(store, paths, step_id=record["stepAttemptId"], dispatch_name=None, host=None)

    def test_submit_schema_invalid_result_leaves_step_open(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            record = self._issue(store, paths)
            atomic_write_json(Path(record["resultPath"]), {"wrong": "shape"})
            with self.assertRaises(LoopSpecError):
                steps.submit(store, paths, step_id=record["stepAttemptId"], dispatch_name=None, host=None)
            self.assertTrue(any(s["stepAttemptId"] == record["stepAttemptId"] for s in store.state["steps"]["open"]))

    def test_result_file_override_reads_from_the_given_path_instead(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            record = self._issue(store, paths)
            elsewhere = Path(tmp) / "results" / "written-by-the-worker.json"
            elsewhere.parent.mkdir(parents=True)
            atomic_write_json(elsewhere, {"ok": True})
            submission = steps.submit(store, paths, step_id=record["stepAttemptId"], dispatch_name=None,
                                       host=None, result_file=elsewhere)
            self.assertEqual(submission.result, {"ok": True})
            self.assertEqual(submission.result_digest, digest_bytes(elsewhere.read_bytes()))
            self.assertFalse(Path(record["resultPath"]).exists())
            self.assertEqual(store.state["steps"]["submissions"][record["stepAttemptId"]]["digest"],
                              submission.result_digest)

    def test_default_result_path_is_under_the_results_dir(self):
        # LF-27: issue()'s own default (no result_path override) must land under
        # paths.results_dir (the project root), not the state home -- a live
        # model, under Claude Code's default permission mode, cannot always
        # write there even with the Write tool allow-listed.
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            record = self._issue(store, paths)
            self.assertEqual(Path(record["resultPath"]).parent, paths.results_dir)

    def test_submit_records_a_copy_of_the_result_in_the_state_home(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            record = self._issue(store, paths)
            atomic_write_json(Path(record["resultPath"]), {"ok": True})

            steps.submit(store, paths, step_id=record["stepAttemptId"], dispatch_name=None, host=None)

            record_path = paths.steps_dir / record["stepAttemptId"] / "result.json"
            self.assertEqual(read_json(record_path), {"ok": True})

    def test_same_digest_twice_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            record = self._issue(store, paths)
            atomic_write_json(Path(record["resultPath"]), {"ok": True})
            first = steps.submit(store, paths, step_id=record["stepAttemptId"], dispatch_name=None, host=None)
            second = steps.submit(store, paths, step_id=record["stepAttemptId"], dispatch_name=None, host=None)
            self.assertEqual(first.result_digest, second.result_digest)

    def test_different_digest_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            record = self._issue(store, paths)
            atomic_write_json(Path(record["resultPath"]), {"ok": True})
            steps.submit(store, paths, step_id=record["stepAttemptId"], dispatch_name=None, host=None)
            atomic_write_json(Path(record["resultPath"]), {"ok": False})
            with self.assertRaises(LoopSpecError):
                steps.submit(store, paths, step_id=record["stepAttemptId"], dispatch_name=None, host=None)

    def test_retired_id_rejected(self):
        # Retired via steps.retire() (rejected/superseded), not via a successful
        # submission: no submissions[id] entry exists, so the replay path cannot
        # apply and the plain "is retired" refusal must fire.
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            record = self._issue(store, paths)
            steps.retire(store, paths, step_id=record["stepAttemptId"], reason="superseded by a new attempt")
            atomic_write_json(Path(record["resultPath"]), {"ok": True})
            with self.assertRaises(LoopSpecError):
                steps.submit(store, paths, step_id=record["stepAttemptId"], dispatch_name=None, host=None)

    def test_external_kind_is_human_attested(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            record = self._issue(store, paths, kind="external", role=None)
            atomic_write_json(Path(record["resultPath"]), {"ok": True})
            submission = steps.submit(store, paths, step_id=record["stepAttemptId"], dispatch_name=None, host=None)
            self.assertEqual(submission.evidence_level, "human-attested")

    def test_no_dispatch_is_unattested(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            record = self._issue(store, paths)
            atomic_write_json(Path(record["resultPath"]), {"ok": True})
            submission = steps.submit(store, paths, step_id=record["stepAttemptId"], dispatch_name=None, host=_FakeAttestor(True, "n/a"))
            self.assertEqual(submission.evidence_level, "unattested")

    def test_fake_attestor_ok_is_host_attested(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            record = self._issue(store, paths)
            atomic_write_json(Path(record["resultPath"]), {"ok": True})
            submission = steps.submit(store, paths, step_id=record["stepAttemptId"], dispatch_name="worker-1", host=_FakeAttestor(True, "matched"))
            self.assertEqual(submission.evidence_level, "host-attested")

    def test_fake_attestor_fail_is_unattested_with_reason(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            record = self._issue(store, paths)
            atomic_write_json(Path(record["resultPath"]), {"ok": True})
            submission = steps.submit(store, paths, step_id=record["stepAttemptId"], dispatch_name="worker-1", host=_FakeAttestor(False, "opening mismatch"))
            self.assertEqual(submission.evidence_level, "unattested")
            self.assertEqual(store.state["steps"]["submissions"][record["stepAttemptId"]]["attestation"]["reason"], "opening mismatch")

    def test_matching_sdk_receipt_is_controller_observed(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            record = self._issue(store, paths)
            result_path = Path(record["resultPath"])
            atomic_write_json(result_path, {"ok": True})
            result_digest = digest_bytes(result_path.read_bytes())
            atomic_write_json(result_path.with_name("sdk-receipt.json"), {
                "stepAttemptId": record["stepAttemptId"], "sessionId": "sess-1", "resultDigest": result_digest,
                "sdkVersion": "0.2.157", "cliVersion": "2.1.277", "finishedAt": "2026-01-01T00:00:00+00:00",
                "unverifiedLive": True,
            })
            submission = steps.submit(store, paths, step_id=record["stepAttemptId"], dispatch_name=None, host=None)
            self.assertEqual(submission.evidence_level, "controller-observed")
            attestation = store.state["steps"]["submissions"][record["stepAttemptId"]]["attestation"]
            self.assertEqual(attestation, {"ok": True, "kind": "sdk-receipt", "sessionId": "sess-1"})

    def test_mismatched_sdk_receipt_is_unattested(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            record = self._issue(store, paths)
            result_path = Path(record["resultPath"])
            atomic_write_json(result_path, {"ok": True})
            atomic_write_json(result_path.with_name("sdk-receipt.json"), {
                "stepAttemptId": record["stepAttemptId"], "sessionId": "sess-1", "resultDigest": "sha256:" + "0" * 64,
                "sdkVersion": "0.2.157", "cliVersion": "2.1.277", "finishedAt": "2026-01-01T00:00:00+00:00",
                "unverifiedLive": True,
            })
            submission = steps.submit(store, paths, step_id=record["stepAttemptId"], dispatch_name=None, host=None)
            self.assertEqual(submission.evidence_level, "unattested")
            attestation = store.state["steps"]["submissions"][record["stepAttemptId"]]["attestation"]
            self.assertEqual(attestation, {"ok": False, "reason": "sdk receipt digest mismatch"})


class RetireTests(StepsTestCase):
    def test_retire_quarantines_a_worktree_path_and_confirm_terminated_deletes_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            repo = Path(tmp) / "repo"
            repo.mkdir()
            _git(repo, "init", "-q")
            _git(repo, "config", "user.email", "test@example.com")
            _git(repo, "config", "user.name", "Test")
            (repo / "README.md").write_text("hi", encoding="utf-8")
            _git(repo, "add", "README.md")
            _git(repo, "commit", "-q", "-m", "init")

            worktree = paths.worktrees_dir / "step-1"
            add_worktree(repo, worktree, detach_at=head_sha(repo))
            record = self._issue(store, paths, cwd=worktree)

            steps.retire(store, paths, step_id=record["stepAttemptId"], reason="worker cancelled")
            self.assertTrue(worktree.exists())
            self.assertEqual(len(store.state["steps"]["quarantined"]), 1)

            steps.confirm_terminated(store, paths, step_id=record["stepAttemptId"], repo=repo)
            self.assertFalse(worktree.exists())
            self.assertEqual(store.state["steps"]["quarantined"], [])


if __name__ == "__main__":
    unittest.main()
