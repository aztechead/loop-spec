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
    # The session's transcript dir is keyed by the cwd Claude Code STARTED in, which is
    # not necessarily the cwd this process runs in (LF-34: a lead's `cd` into the
    # results dir moved Path.cwd() and every later lookup found nothing). The session
    # id is unique across projects, so glob it under every project key; project_cwd is
    # kept only as the first candidate so the common case stays one directory.
    projects = Path(claude_home) / "projects"
    candidates = [projects / str(project_cwd).replace("/", "-") / session_id / "subagents"]
    candidates += [d for d in sorted(projects.glob(f"*/{session_id}/subagents")) if d not in candidates]
    subagents_dirs = [d for d in candidates if d.is_dir()]
    if not subagents_dirs:
        return []
    # Claude Code 2.1.278 names the file by agent id (`agent-<id>.jsonl`) and keeps the
    # dispatch name in the `.meta.json` sidecar (live finding LF-10; the probe record had
    # the name in the file name). Accept either spelling of the dispatch: the Agent
    # tool's name, or the agent id it returned.
    matches: list[Path] = []
    for meta in sorted(m for d in subagents_dirs for m in d.glob("agent-*.meta.json")):
        transcript = meta.with_name(meta.name[: -len(".meta.json")] + ".jsonl")
        if not transcript.exists():
            continue
        try:
            name = json.loads(meta.read_text(encoding="utf-8")).get("name")
        except (OSError, ValueError):
            name = None
        agent_id = meta.name[len("agent-"): -len(".meta.json")]
        if name == dispatch_name or agent_id == dispatch_name:
            matches.append(transcript)
    if not matches:
        matches = sorted(m for d in subagents_dirs for m in d.glob(f"agent-a{dispatch_name}-*.jsonl"))
    return matches


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
