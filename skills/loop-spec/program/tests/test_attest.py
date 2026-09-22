"""Unit tests for loop_spec.attest: the native transcript check, hand-written fixtures."""
import json
import tempfile
import unittest
from pathlib import Path

from loop_spec.attest import ClaudeCodeAttestor, find_transcripts

_ISSUED_AT = "2026-09-22T10:00:00+00:00"
_RESULT_DIGEST = "sha256:" + "a" * 64
_STEP = {
    "prompt": "do the task\n--- loop-spec step ---\nstep: step-1\ninputs: sha256:" + "b" * 64 + "\nphase: execute\n",
    "issuedAt": _ISSUED_AT,
}


def _write_transcript(path: Path, records: list[dict]) -> None:
    path.write_text("\n".join(json.dumps(r) for r in records) + "\n", encoding="utf-8")


def _valid_records(closing_extra: str = "") -> list[dict]:
    return [
        {"type": "user", "timestamp": "2026-09-22T10:00:05+00:00", "message": {"content": _STEP["prompt"]}},
        {"type": "assistant", "timestamp": "2026-09-22T10:00:06+00:00", "message": {"content": "working..."}},
        {"type": "assistant", "timestamp": "2026-09-22T10:00:10+00:00",
         "message": {"content": f"done. LOOP_SPEC_RESULT_DIGEST {_RESULT_DIGEST}{closing_extra}"}},
    ]


class AttestorTests(unittest.TestCase):
    def _attestor(self, claude_home: Path, session_id: str = "session-1") -> ClaudeCodeAttestor:
        return ClaudeCodeAttestor(session_id=session_id, project_cwd=Path("/repo"), claude_home=claude_home)

    def _subagents_dir(self, claude_home: Path, session_id: str = "session-1") -> Path:
        d = claude_home / "projects" / "-repo" / session_id / "subagents"
        d.mkdir(parents=True, exist_ok=True)
        return d

    def test_valid_transcript_is_host_attested(self):
        with tempfile.TemporaryDirectory() as tmp:
            claude_home = Path(tmp)
            subagents = self._subagents_dir(claude_home)
            _write_transcript(subagents / "agent-aworker-1-0123456789abcdef.jsonl", _valid_records())
            ok, reason = self._attestor(claude_home).attest(_STEP, _RESULT_DIGEST, "worker-1")
            self.assertTrue(ok, reason)

    def _attest_records(self, records: list[dict]) -> tuple[bool, str]:
        with tempfile.TemporaryDirectory() as tmp:
            claude_home = Path(tmp)
            subagents = self._subagents_dir(claude_home)
            _write_transcript(subagents / "agent-aworker-1-0123456789abcdef.jsonl", records)
            return self._attestor(claude_home).attest(_STEP, _RESULT_DIGEST, "worker-1")

    def test_two_transcripts_is_unattested(self):
        with tempfile.TemporaryDirectory() as tmp:
            claude_home = Path(tmp)
            subagents = self._subagents_dir(claude_home)
            _write_transcript(subagents / "agent-aworker-1-0123456789abcdef.jsonl", _valid_records())
            _write_transcript(subagents / "agent-aworker-1-fedcba9876543210.jsonl", _valid_records())
            ok, reason = self._attestor(claude_home).attest(_STEP, _RESULT_DIGEST, "worker-1")
            self.assertFalse(ok)
            self.assertIn("found 2", reason)

    def test_opening_missing_step_line_is_unattested(self):
        records = _valid_records()
        records[0] = {"type": "user", "timestamp": "2026-09-22T10:00:05+00:00", "message": {"content": "an unrelated prompt"}}
        ok, reason = self._attest_records(records)
        self.assertFalse(ok)
        self.assertEqual(reason, "opening does not contain the composed prompt")

    def test_timestamp_before_issue_is_unattested(self):
        records = _valid_records()
        records[0]["timestamp"] = "2026-09-22T09:00:00+00:00"  # before _ISSUED_AT
        ok, reason = self._attest_records(records)
        self.assertFalse(ok)
        self.assertEqual(reason, "transcript predates the step")

    def test_digest_only_in_the_middle_is_unattested(self):
        records = _valid_records()
        records[1]["message"]["content"] = f"LOOP_SPEC_RESULT_DIGEST {_RESULT_DIGEST} (draft, not final)"
        records[2]["message"]["content"] = "actually let me redo this"
        ok, reason = self._attest_records(records)
        self.assertFalse(ok)
        self.assertEqual(reason, "final message does not end with the result digest")

    def test_digest_present_but_followed_by_more_text_is_unattested(self):
        records = _valid_records(closing_extra="\nthanks for reading")
        ok, reason = self._attest_records(records)
        self.assertFalse(ok)
        self.assertEqual(reason, "final message does not end with the result digest")


if __name__ == "__main__":
    unittest.main()


class MetaNameLayoutTests(unittest.TestCase):
    """Claude Code 2.1.278 names transcripts by agent id and keeps the dispatch name in .meta.json."""

    def test_session_found_under_another_project_key(self):
        # LF-34: the lookup keys on the session id, not on this process's cwd; a lead
        # whose shell moved into the results dir still attests its workers.
        import json as _json
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            subagents = home / "projects" / "-repo" / "sess" / "subagents"
            subagents.mkdir(parents=True)
            _write_transcript(subagents / "agent-a7b7490498fde8aac.jsonl", _valid_records())
            (subagents / "agent-a7b7490498fde8aac.meta.json").write_text(_json.dumps({"name": "worker-1"}))
            found = find_transcripts(home, Path("/repo/.loop-spec/results/slug"), "sess", "worker-1")
            self.assertEqual([p.name for p in found], ["agent-a7b7490498fde8aac.jsonl"])
            self.assertEqual(find_transcripts(home, Path("/repo"), "other-sess", "worker-1"), [])

    def test_meta_name_or_agent_id_matches(self):
        import json as _json
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            subagents = home / "projects" / "-repo" / "sess" / "subagents"
            subagents.mkdir(parents=True)
            _write_transcript(subagents / "agent-a7b7490498fde8aac.jsonl", _valid_records())
            (subagents / "agent-a7b7490498fde8aac.meta.json").write_text(_json.dumps({"name": "worker-1"}))
            by_name = find_transcripts(home, Path("/repo"), "sess", "worker-1")
            by_id = find_transcripts(home, Path("/repo"), "sess", "a7b7490498fde8aac")
            self.assertEqual([p.name for p in by_name], ["agent-a7b7490498fde8aac.jsonl"])
            self.assertEqual(by_name, by_id)
            self.assertEqual(find_transcripts(home, Path("/repo"), "sess", "other"), [])

    def test_redispatch_name_matches_exactly_not_its_original_step(self):
        # A redispatched attestation-required step is named "<stepId>-2"; the exact
        # meta-name match must find that transcript and not the original "<stepId>"
        # one, even though "step-x" is a prefix of "step-x-2".
        import json as _json
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            subagents = home / "projects" / "-repo" / "sess" / "subagents"
            subagents.mkdir(parents=True)
            _write_transcript(subagents / "agent-aoriginal.jsonl", _valid_records())
            (subagents / "agent-aoriginal.meta.json").write_text(_json.dumps({"name": "step-x"}))
            _write_transcript(subagents / "agent-aretry.jsonl", _valid_records())
            (subagents / "agent-aretry.meta.json").write_text(_json.dumps({"name": "step-x-2"}))

            found = find_transcripts(home, Path("/repo"), "sess", "step-x-2")
            self.assertEqual([p.name for p in found], ["agent-aretry.jsonl"])
            found_original = find_transcripts(home, Path("/repo"), "sess", "step-x")
            self.assertEqual([p.name for p in found_original], ["agent-aoriginal.jsonl"])
