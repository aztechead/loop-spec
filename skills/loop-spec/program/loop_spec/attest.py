"""Native Claude Code transcript check: the evidence behind a `host-attested` step.

Use `ClaudeCodeAttestor` as the `HostAttestor` `steps.submit` calls when a step was
dispatched natively (the Agent tool) rather than run by a controller-observed runner
that needs no transcript. What the host writes and the check built from it are
recorded in docs/loop-spec/native-attestation-probe-7.0.md: one observation on one
host and version, not a promise every host or a future version will match it.
"""
import json
import os
from pathlib import Path
from typing import Protocol


class HostAttestor(Protocol):
    def attest(self, step: dict, result_digest: str, dispatch_name: str) -> tuple[bool, str]: ...


def find_transcripts(claude_home: Path, project_cwd: Path, session_id: str, dispatch_name: str) -> list[Path]:
    cwd_key = str(project_cwd).replace("/", "-")
    subagents_dir = Path(claude_home) / "projects" / cwd_key / session_id / "subagents"
    if not subagents_dir.is_dir():
        return []
    return sorted(subagents_dir.glob(f"agent-a{dispatch_name}-*.jsonl"))


def _message_text(record: dict) -> str:
    content = record.get("message", {}).get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(block.get("text", "") for block in content if block.get("type") == "text")
    return ""


def check_transcript(path: Path, step: dict, result_digest: str) -> tuple[bool, str]:
    lines = [line for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    records = [json.loads(line) for line in lines]
    if not records:
        return False, "transcript is empty"

    # The trailer's first two lines are the identity the opening record must echo;
    # the rest of the composed prompt is free text a transcript could paraphrase.
    trailer_lines = step["prompt"].splitlines()
    step_line = next((line for line in trailer_lines if line.startswith("step: ")), "")
    inputs_line = next((line for line in trailer_lines if line.startswith("inputs: ")), "")

    first = records[0]
    opening_text = _message_text(first)
    if first.get("type") != "user" or step_line not in opening_text or inputs_line not in opening_text:
        return False, "opening does not contain the composed prompt"

    if first.get("timestamp", "") < step["issuedAt"]:
        return False, "transcript predates the step"

    last = records[-1]
    closing_text = _message_text(last).rstrip() if last.get("type") == "assistant" else ""
    if not closing_text.endswith(f"LOOP_SPEC_RESULT_DIGEST {result_digest}"):
        # A digest appearing earlier in the transcript (the worker's own hash
        # command output) does not count; only the closing record's ending does.
        return False, "final message does not end with the result digest"

    return True, "opening matched; timestamp after issue; closing record ended with the result digest"


class ClaudeCodeAttestor:
    def __init__(self, session_id: str | None = None, project_cwd: Path | None = None, claude_home: Path | None = None) -> None:
        self.session_id = session_id if session_id is not None else os.environ.get("CLAUDE_CODE_SESSION_ID")
        self.project_cwd = project_cwd if project_cwd is not None else Path.cwd()
        self.claude_home = claude_home if claude_home is not None else Path.home() / ".claude"

    def attest(self, step: dict, result_digest: str, dispatch_name: str) -> tuple[bool, str]:
        if not self.session_id:
            return False, "no CLAUDE_CODE_SESSION_ID"
        transcripts = find_transcripts(self.claude_home, self.project_cwd, self.session_id, dispatch_name)
        if len(transcripts) != 1:
            return False, f"expected exactly one transcript for {dispatch_name}, found {len(transcripts)}"
        return check_transcript(transcripts[0], step, result_digest)
