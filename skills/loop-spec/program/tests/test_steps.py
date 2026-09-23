"""Unit tests for loop_spec.steps: issue/submit/retire and evidence levels."""
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

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

    def test_a_role_step_gets_a_file_transport_with_one_terminal_lf_in_both_copies(self):
        # LF-59: the worker reads the prompt from a file; step.prompt stays the authority.
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            record = self._issue(store, paths, prompt="do the task — café\n\n\tindented")
            self.assertEqual(record["transport"], "file")
            self.assertTrue(record["prompt"].endswith("`.\n") and not record["prompt"].endswith("\n\n"))
            self.assertEqual(Path(record["instructionPath"]).read_bytes(), record["prompt"].encode("utf-8"))
            self.assertIn(record["stepAttemptId"], record["dispatchPrompt"])
            self.assertIn(record["instructionPath"], record["dispatchPrompt"])
            self.assertIn("Read tool", record["dispatchPrompt"])

    def test_lead_and_external_steps_keep_the_prompt_transport(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            for kind in ("lead", "external"):
                record = self._issue(store, paths, kind=kind)
                self.assertNotIn("transport", record)
                self.assertNotIn("dispatchPrompt", record)

    def test_a_carriage_return_in_a_role_prompt_is_refused_at_issue(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            with self.assertRaises(LoopSpecError):
                self._issue(store, paths, prompt="line one\r\nline two")


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

    def _sdk_receipt(self, step_id, result_digest, session_id="sess-1"):
        return {
            "stepAttemptId": step_id, "sessionId": session_id, "resultDigest": result_digest,
            "sdkVersion": "0.2.157", "cliVersion": "2.1.277", "finishedAt": "2026-01-01T00:00:00+00:00",
            "unverifiedLive": True,
        }

    def test_matching_sdk_receipt_is_controller_observed(self):
        # R2: the receipt lives under the state home (paths.steps_dir), never
        # beside the worker-writable result, and this run's own state must say
        # an SDK session actually launched it.
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            store.state["run"]["runner"] = "sdk"
            record = self._issue(store, paths)
            result_path = Path(record["resultPath"])
            atomic_write_json(result_path, {"ok": True})
            result_digest = digest_bytes(result_path.read_bytes())
            atomic_write_json(paths.steps_dir / record["stepAttemptId"] / "receipt.json",
                               self._sdk_receipt(record["stepAttemptId"], result_digest))
            submission = steps.submit(store, paths, step_id=record["stepAttemptId"], dispatch_name=None, host=None)
            self.assertEqual(submission.evidence_level, "controller-observed")
            attestation = store.state["steps"]["submissions"][record["stepAttemptId"]]["attestation"]
            self.assertEqual(attestation, {"ok": True, "kind": "sdk-receipt", "sessionId": "sess-1"})

    def test_mismatched_sdk_receipt_is_unattested(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            store.state["run"]["runner"] = "sdk"
            record = self._issue(store, paths)
            result_path = Path(record["resultPath"])
            atomic_write_json(result_path, {"ok": True})
            atomic_write_json(paths.steps_dir / record["stepAttemptId"] / "receipt.json",
                               self._sdk_receipt(record["stepAttemptId"], "sha256:" + "0" * 64))
            submission = steps.submit(store, paths, step_id=record["stepAttemptId"], dispatch_name=None, host=None)
            self.assertEqual(submission.evidence_level, "unattested")
            attestation = store.state["steps"]["submissions"][record["stepAttemptId"]]["attestation"]
            self.assertEqual(attestation, {"ok": False, "reason": "sdk receipt digest mismatch"})

    def test_receipt_beside_the_result_on_a_native_run_is_ignored(self):
        # R2: the OLD location (beside the worker-writable result) is exactly
        # what let a result's own author fabricate "controller-observed"
        # evidence with no SDK session at all -- a receipt there is no longer
        # even looked at; this native (non-sdk) run falls through to the normal
        # host-attestation path (host=None here) and is plainly unattested.
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            record = self._issue(store, paths)
            result_path = Path(record["resultPath"])
            atomic_write_json(result_path, {"ok": True})
            result_digest = digest_bytes(result_path.read_bytes())
            atomic_write_json(result_path.with_name("sdk-receipt.json"),
                               self._sdk_receipt(record["stepAttemptId"], result_digest))
            submission = steps.submit(store, paths, step_id=record["stepAttemptId"], dispatch_name=None, host=None)
            self.assertEqual(submission.evidence_level, "unattested")

    def test_correctly_placed_receipt_without_runner_sdk_is_ignored(self):
        # Even in the right location with a correct digest, a receipt is not
        # evidence unless the run's own state says an SDK session launched it
        # -- otherwise anything (or anyone) that could reach the state home
        # could plant one for a run nothing here ever launched under the SDK.
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            record = self._issue(store, paths)
            result_path = Path(record["resultPath"])
            atomic_write_json(result_path, {"ok": True})
            result_digest = digest_bytes(result_path.read_bytes())
            atomic_write_json(paths.steps_dir / record["stepAttemptId"] / "receipt.json",
                               self._sdk_receipt(record["stepAttemptId"], result_digest))
            submission = steps.submit(store, paths, step_id=record["stepAttemptId"], dispatch_name=None, host=None)
            self.assertEqual(submission.evidence_level, "unattested")


def hex_heavy_prompt(hex_lines: int = 1300) -> str:
    """LF-61: the shape of e2e-lf59b's failing review prompt (a prose header, then a diff
    of sha256 hex literals, then the step trailer), generated deterministically."""
    import hashlib
    header = [f"Review rule {i}: every finding names a file, a line, and a cause." for i in range(300)]
    diff = [f'+    "{hashlib.sha256(str(i).encode()).hexdigest()}",' for i in range(hex_lines)]
    return "\n".join(header + diff + ["--- loop-spec step ---", "When done, write your JSON result."]) + "\n"


def _rendered(prompt: str, offset: int, limit: int) -> int:
    lines = prompt.split("\n")
    return sum(len(f"{n}\t{lines[n - 1]}\n".encode()) for n in range(offset, offset + limit))


class ReadScheduleTests(StepsTestCase):
    """LF-61: the program, not the worker, chooses the Read ranges."""

    def test_a_hex_heavy_prompt_is_covered_exactly_once_within_the_budget(self):
        prompt = hex_heavy_prompt()
        schedule = steps.read_schedule(prompt)
        total = len(prompt.split("\n"))
        self.assertEqual(schedule[0]["offset"], 1)
        for before, after in zip(schedule, schedule[1:]):
            self.assertEqual(after["offset"], before["offset"] + before["limit"])  # contiguous, in order
        self.assertEqual(sum(r["limit"] for r in schedule), total)
        self.assertTrue(all(r["offset"] >= 1 and r["limit"] >= 1 for r in schedule))
        self.assertTrue(all(_rendered(prompt, r["offset"], r["limit"]) <= steps.READ_BUDGET_BYTES for r in schedule))
        self.assertLess(schedule[0]["offset"] + schedule[0]["limit"] - 1, 537)  # the host's failing first page is split

    def test_multibyte_lines_and_the_budget_boundary(self):
        line = "é" * 27  # 54 bytes; rendered "1\t" + 54 + "\n" = 57
        self.assertEqual(steps.read_schedule(line + "\n" + line, budget=57), [{"offset": 1, "limit": 1}, {"offset": 2, "limit": 1}])
        with self.assertRaisesRegex(LoopSpecError, "line 1 .* 57 bytes, over the supported 56-byte read budget"):
            steps.read_schedule(line, budget=56)

    def test_an_over_budget_line_issues_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            with self.assertRaisesRegex(LoopSpecError, "execute code-reviewer step not issued: line 2 "):
                self._issue(store, paths, role="code-reviewer", prompt="ok\n" + "é" * 9000)
            self.assertEqual(store.state["steps"]["open"], [])
            self.assertEqual(list(paths.steps_dir.glob("*")) if paths.steps_dir.exists() else [], [])

    def test_the_bootstrap_lists_every_call_and_keeps_a_unicode_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = FeaturePaths(root=Path(tmp) / "fëature-日本")
            store = StateStore.create(paths, {"id": "run-1", "entry": "cycle"}, "do the thing")
            record = self._issue(store, paths, role="code-reviewer", prompt=hex_heavy_prompt(400))
            self.assertIn(f"The instruction file {record['instructionPath']} has ", record["dispatchPrompt"])
            self.assertIn("fëature-日本", record["dispatchPrompt"])
            calls = [f"{i}. offset={r['offset']} limit={r['limit']}" for i, r in enumerate(record["readSchedule"], 1)]
            self.assertGreater(len(calls), 1)
            self.assertIn("\n".join(calls), record["dispatchPrompt"])
            self.assertNotIn("\r", record["dispatchPrompt"])


class AttestationRequiredRoleTests(StepsTestCase):
    """LF-30's post-hardening item 2: a plan-critic/code-reviewer/iterate-judge step
    with nothing behind it but the transcript is never accepted unattested -- the
    program refuses and re-dispatches instead, bounded by retry_limit()."""

    def test_unattested_plan_critic_is_not_retired_and_carries_a_redispatch_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            record = self._issue(store, paths, role="plan-critic")
            atomic_write_json(Path(record["resultPath"]), {"ok": True})
            submission = steps.submit(
                store, paths, step_id=record["stepAttemptId"], dispatch_name="worker-1",
                host=_FakeAttestor(False, "final message does not end with the result digest"),
            )
            self.assertEqual(submission.evidence_level, "unattested")
            self.assertEqual(submission.redispatch, f"{record['stepAttemptId']}-2")
            self.assertTrue(any(s["stepAttemptId"] == record["stepAttemptId"] for s in store.state["steps"]["open"]))
            self.assertNotIn(record["stepAttemptId"], store.state["steps"]["retired"])
            self.assertNotIn(record["stepAttemptId"], store.state["steps"]["submissions"])
            open_record = next(s for s in store.state["steps"]["open"] if s["stepAttemptId"] == record["stepAttemptId"])
            self.assertEqual(open_record["attestationAttempts"], 1)

    def test_past_the_retry_limit_without_an_opt_in_the_step_is_refused(self):
        # LF-60: exhaustion is never an implicit waiver; nothing is accepted.
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            record = self._issue(store, paths, role="code-reviewer")
            step_id = record["stepAttemptId"]
            atomic_write_json(Path(record["resultPath"]), {"ok": True})
            host = _FakeAttestor(False, "opening does not contain the composed prompt")

            with patch.dict("os.environ", {"LOOP_SPEC_STEP_RETRIES": "1"}):
                first = steps.submit(store, paths, step_id=step_id, dispatch_name="worker-1", host=host, project_root=Path(tmp))
                self.assertIsNotNone(first.redispatch)
                second = steps.submit(store, paths, step_id=step_id, dispatch_name="worker-2", host=host, project_root=Path(tmp))

            self.assertEqual((second.redispatch, second.refused), (None, "opening does not contain the composed prompt"))
            reopened = StateStore.open(paths)  # retire and the refusal were saved together
            self.assertIn(step_id, reopened.state["steps"]["retired"])
            self.assertNotIn(step_id, reopened.state["steps"]["submissions"])
            self.assertEqual({k: v for k, v in reopened.state["steps"]["refused"][step_id].items() if k != "at"},
                             {"role": "code-reviewer", "phase": "execute", "cwd": "/repo", "attempts": 2,
                              "reason": "opening does not contain the composed prompt", "questionId": None, "ownerReset": False})
            self.assertIsNone(reopened.state.get("attestationWaivers"))
            self.assertFalse((paths.steps_dir / step_id / "result.json").exists())
            self.assertTrue((paths.steps_dir / step_id / "refused-result.json").is_file())
            with self.assertRaisesRegex(LoopSpecError, "retired"):  # a late result for it
                steps.submit(store, paths, step_id=step_id, dispatch_name="worker-3", host=host, project_root=Path(tmp))

    def test_each_opt_in_key_covers_its_own_roles_only(self):
        # LF-60 R1: four configs x three roles, with no host (a refusal path of its own).
        configs = {"neither": {}, "review": {"review": {"accept": "unattested"}},
                   "judgment": {"judgment": {"accept": "unattested"}},
                   "both": {"review": {"accept": "unattested"}, "judgment": {"accept": "unattested"}}}
        for name, evidence in configs.items():
            for role in ("code-reviewer", "plan-critic", "iterate-judge"):
                with self.subTest(config=name, role=role), tempfile.TemporaryDirectory() as tmp:
                    atomic_write_json(Path(tmp) / ".loop-spec" / "config.json", {"evidence": evidence})
                    store, paths = self._store(tmp)
                    record = self._issue(store, paths, role=role)
                    atomic_write_json(Path(record["resultPath"]), {"ok": True})
                    submission = steps.submit(store, paths, step_id=record["stepAttemptId"], dispatch_name=None,
                                              host=None, project_root=Path(tmp))
                    family = "review" if role == "code-reviewer" else "judgment"
                    if family in evidence:
                        self.assertIsNone(submission.refused)
                        self.assertEqual(store.state["attestationWaivers"], [
                            {"kind": "evidence.unattested-step", "step": record["stepAttemptId"], "role": role,
                             "attempts": 1, "policy": f"evidence.{family}.accept", "source": "config"}])
                    else:
                        self.assertEqual(submission.refused, "no host attestor")
                        self.assertNotIn(record["stepAttemptId"], store.state["steps"]["submissions"])

    def test_an_sdk_receipt_for_another_digest_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            store.state["run"]["runner"] = "sdk"
            record = self._issue(store, paths, role="iterate-judge")
            atomic_write_json(Path(record["resultPath"]), {"ok": True})
            atomic_write_json(paths.steps_dir / record["stepAttemptId"] / "receipt.json",
                              {"stepAttemptId": record["stepAttemptId"], "resultDigest": "sha256:" + "0" * 64})
            submission = steps.submit(store, paths, step_id=record["stepAttemptId"], dispatch_name=None,
                                      host=_FakeAttestor(True, "ok"), project_root=Path(tmp))
            self.assertEqual(submission.refused, "sdk receipt digest mismatch")

    def test_a_cached_judgment_counts_only_with_accepted_evidence_or_an_opt_in(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            store.state["steps"]["submissions"].update({"s-ok": {"evidenceLevel": "host-attested"},
                                                        "s-weak": {"evidenceLevel": "unattested"}})
            self.assertTrue(steps.evidence_accepted(store, Path(tmp), "s-ok", "plan-critic"))
            self.assertFalse(steps.evidence_accepted(store, Path(tmp), "s-weak", "plan-critic"))
            self.assertFalse(steps.evidence_accepted(store, Path(tmp), None, "plan-critic"))  # no provenance
            atomic_write_json(Path(tmp) / ".loop-spec" / "config.json", {"evidence": {"judgment": {"accept": "unattested"}}})
            self.assertTrue(steps.evidence_accepted(store, Path(tmp), "s-weak", "plan-critic"))
            self.assertTrue(steps.evidence_accepted(store, Path(tmp), "s-weak", "plan-critic"))
            self.assertFalse(steps.evidence_accepted(store, Path(tmp), "s-weak", "code-reviewer"))
            self.assertEqual([w["step"] for w in store.state["attestationWaivers"]], ["s-weak"])  # once, on replay too

    def test_an_opt_in_other_than_unattested_is_a_config_error(self):
        from loop_spec.contract import load_config
        with tempfile.TemporaryDirectory() as tmp:
            atomic_write_json(Path(tmp) / ".loop-spec" / "config.json", {"evidence": {"judgment": {"accept": "yes"}}})
            with self.assertRaisesRegex(LoopSpecError, "evidence.judgment.accept"):
                load_config(Path(tmp))

    def test_implementer_role_is_accepted_unattested_on_the_first_submit(self):
        # implementer is not in ATTESTATION_REQUIRED_ROLES: its own evidence is the
        # task's verify command, so an unattested transcript is accepted as today.
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            record = self._issue(store, paths, role="implementer")
            atomic_write_json(Path(record["resultPath"]), {"ok": True})
            submission = steps.submit(
                store, paths, step_id=record["stepAttemptId"], dispatch_name="worker-1",
                host=_FakeAttestor(False, "opening does not contain the composed prompt"),
            )
            self.assertEqual(submission.evidence_level, "unattested")
            self.assertIsNone(submission.redispatch)
            self.assertIn(record["stepAttemptId"], store.state["steps"]["retired"])

    def test_a_later_successful_attestation_retires_the_step_host_attested(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            record = self._issue(store, paths, role="iterate-judge")
            atomic_write_json(Path(record["resultPath"]), {"ok": True})
            failing_submission = steps.submit(
                store, paths, step_id=record["stepAttemptId"], dispatch_name="worker-1",
                host=_FakeAttestor(False, "opening does not contain the composed prompt"),
            )
            self.assertIsNotNone(failing_submission.redispatch)

            submission = steps.submit(
                store, paths, step_id=record["stepAttemptId"], dispatch_name=failing_submission.redispatch,
                host=_FakeAttestor(True, "matched"),
            )
            self.assertEqual(submission.evidence_level, "host-attested")
            self.assertIsNone(submission.redispatch)
            self.assertIn(record["stepAttemptId"], store.state["steps"]["retired"])
            self.assertNotIn(record["stepAttemptId"], [s["stepAttemptId"] for s in store.state["steps"]["open"]])


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

    def test_confirm_terminated_keeps_a_dirty_worktree_and_records_the_backlog(self):
        # LF-51/8A: confirm_terminated no longer force-deletes -- the operator's
        # confirmation means termination is KNOWN, not that an uncommitted edit
        # sitting in the worktree is safe to throw away.
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
            (worktree / "scratch.txt").write_text("uncommitted", encoding="utf-8")
            record = self._issue(store, paths, cwd=worktree)
            step_id = record["stepAttemptId"]

            steps.retire(store, paths, step_id=step_id, reason="worker cancelled")
            steps.confirm_terminated(store, paths, step_id=step_id, repo=repo)

            self.assertTrue(worktree.exists())
            self.assertTrue((worktree / "scratch.txt").exists())
            self.assertEqual(store.state["steps"]["quarantined"], [])
            self.assertEqual(store.state["cleanupBacklog"], [{"path": str(worktree), "reason": "uncommitted changes"}])
            self.assertIn(step_id, store.state["steps"]["terminated"])


class WritersKnownTerminatedTests(StepsTestCase):
    def _worktree(self, tmp):
        repo = Path(tmp) / "repo"
        repo.mkdir()
        _git(repo, "init", "-q")
        _git(repo, "config", "user.email", "test@example.com")
        _git(repo, "config", "user.name", "Test")
        (repo / "README.md").write_text("hi", encoding="utf-8")
        _git(repo, "add", "README.md")
        _git(repo, "commit", "-q", "-m", "init")
        worktree = Path(tmp) / "wt"
        add_worktree(repo, worktree, detach_at=head_sha(repo))
        return worktree

    def test_writers_known_terminated(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, paths = self._store(tmp)
            worktree = self._worktree(tmp)

            # No step has ever run there: nothing to know, so nothing is unknown.
            self.assertTrue(steps.writers_known_terminated(store, paths, worktree))

            # An open step: unknown.
            open_record = self._issue(store, paths, cwd=worktree)
            self.assertFalse(steps.writers_known_terminated(store, paths, worktree))

            # Retired but unattested: still unknown.
            step_id = open_record["stepAttemptId"]
            store.state["steps"]["open"] = [s for s in store.state["steps"]["open"] if s["stepAttemptId"] != step_id]
            store.state["steps"]["retired"].append(step_id)
            store.state["steps"]["submissions"][step_id] = {"evidenceLevel": "unattested"}
            self.assertFalse(steps.writers_known_terminated(store, paths, worktree))

            # Retired and host-attested: known terminated.
            store.state["steps"]["submissions"][step_id] = {"evidenceLevel": "host-attested"}
            self.assertTrue(steps.writers_known_terminated(store, paths, worktree))


if __name__ == "__main__":
    unittest.main()
