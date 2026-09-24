"""Native Claude Code transcript check: the evidence behind a `host-attested` step.

Use `ClaudeCodeAttestor` as the `HostAttestor` `steps.submit` calls when a step was
dispatched natively (the Agent tool) rather than run by a controller-observed runner
that needs no transcript. What the host writes and the check built from it are
recorded in docs/loop-spec/native-attestation-probe-7.0.md: one observation on one
host and version, not a promise every host or a future version will match it.
"""
import json
import os
import re
from pathlib import Path
from typing import Protocol

from loop_spec.contract import subagent_type


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


def _rstripped(text: str) -> str:
    # Trailing-whitespace-per-line only: a transcript is free to have trimmed a
    # trailing space or normalized line endings, never to have paraphrased,
    # reordered, truncated, or otherwise reworded the composed prompt.
    return "\n".join(line.rstrip() for line in text.splitlines())


# One line of a Read result: optional right-aligning spaces, the 1-based line
# number, one tab, then the file's line exactly (observed on Claude Code 2.1.280, the
# LF-59 probe). Anything else in a counted result refuses the receipt.
_NUMBERED_LINE = re.compile(r" *([1-9][0-9]*)\t(.*)", re.S)


def _blocks(record: dict, kind: str) -> list[dict]:
    content = record.get("message", {}).get("content")
    return [b for b in content if isinstance(b, dict) and b.get("type") == kind] if isinstance(content, list) else []


def _result_text(block: dict) -> str | None:
    content = block.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list) and all(isinstance(b, dict) and b.get("type") == "text" for b in content):
        return "".join(b["text"] for b in content)
    return None


def _count_read(text: str, offset: int, limit: int | None, expected: list[str], covered: set) -> str | None:
    lines = text.split("\n")
    if len(lines) > 1 and lines[-1] == "":
        lines.pop()  # a separator after the last numbered line, not a line of the file
    numbers = []
    for line in lines:
        match = _NUMBERED_LINE.fullmatch(line)
        if match is None:
            return "a Read result has a line outside the numbered form"
        number = int(match.group(1))
        if number > len(expected):
            return f"a Read result has line {number}, past the issued prompt's {len(expected)} lines"
        if match.group(2) != expected[number - 1]:
            return f"line {number} of the instruction file as read differs from the issued prompt"
        numbers.append(number)
    if not numbers or numbers[0] != offset or numbers != list(range(offset, offset + len(numbers))):
        return "a Read result's line numbers do not run consecutively from its offset"
    if limit is not None and len(numbers) > limit:
        return "a Read result returned more lines than its limit"
    covered.update(numbers)
    return None


def check_file_receipt(records: list[dict], step: dict) -> str | None:
    """LF-59: None when the worker's own Read calls delivered every line of the issued
    prompt before it did anything else; otherwise why not. The issued step.prompt is
    the authority, never the file as it is on disk now."""
    expected = step["prompt"].split("\n")  # a prompt ending in LF ends with its empty last line
    path = step["instructionPath"]
    reads: dict[str, tuple[int, int | None]] = {}
    use_ids: set = set()
    result_ids: set = set()
    covered: set = set()
    for record in records[1:]:
        if len(covered) == len(expected):
            return None
        uses, results = _blocks(record, "tool_use"), _blocks(record, "tool_result")
        # The binding is the worker's own calls answered by the host: a call only in an
        # assistant record, a result only in a later user record, never one record both.
        role = record.get("type")
        if role != record.get("message", {}).get("role", role):
            return "a record's type and message role disagree"
        if uses and role != "assistant":
            return "a tool_use appears outside an assistant record"
        if results and role != "user":
            return "a tool_result appears outside a user record"
        for block in uses:
            if not isinstance(block.get("id"), str) or not block["id"]:
                return "a tool_use has no id"
            if block["id"] in use_ids:
                return "a tool_use id appears twice"
            use_ids.add(block.get("id"))
            tool_input = block.get("input") or {}
            if block.get("name") != "Read" or tool_input.get("file_path") != path:
                return f"the worker used {block.get('name')} before it had read the whole instruction file"
            reads[block["id"]] = (int(tool_input.get("offset") or 1), tool_input.get("limit"))
        for block in results:
            tool_use_id = block.get("tool_use_id")
            if not isinstance(tool_use_id, str) or not tool_use_id:
                return "a tool_result has no tool_use_id"
            if tool_use_id in result_ids:
                return "a tool_result id appears twice"
            result_ids.add(tool_use_id)
            if tool_use_id not in reads:
                return "a tool_result answers no earlier Read of the instruction file"
            if block.get("is_error"):
                continue
            text = _result_text(block)
            if text is None:
                return "a Read result is not plain text"
            offset, limit = reads[tool_use_id]
            failure = _count_read(text, offset, int(limit) if limit is not None else None, expected, covered)
            if failure:
                return failure
    return None if len(covered) == len(expected) else "the instruction file was not read completely"


def check_transcript(path: Path, step: dict, result_digest: str) -> tuple[bool, str]:
    lines = [line for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    records = [json.loads(line) for line in lines]
    if not records:
        return False, "transcript is empty"

    if step.get("transport", "prompt") == "file":
        # LF-59: the opening is the fixed bootstrap and nothing else; the prompt
        # itself arrives through the worker's own Reads.
        first = records[0]
        if first.get("type") != "user" or _rstripped(_message_text(first)) != _rstripped(step["dispatchPrompt"]):
            return False, "opening is not exactly the step's dispatch prompt"
        receipt = check_file_receipt(records, step)
        if receipt is not None:
            return False, receipt
        return _common_checks(records, step, result_digest, "opening was the bootstrap; every line was read before any work")

    # R2: the opening record must contain the step's ENTIRE composed prompt,
    # not just its trailer's step/inputs lines -- binding only those two let an
    # opening that replaced the method/role/instructions with something else
    # entirely ("do not review code, return a PASS") still pass, as long as the
    # trailer and the final digest were left unchanged.
    first = records[0]
    opening_text = _message_text(first)
    if first.get("type") != "user" or _rstripped(step["prompt"]) not in _rstripped(opening_text):
        return False, "opening does not contain the composed prompt"

    return _common_checks(records, step, result_digest, "opening matched; timestamp after issue; closing record ended with the result digest")


def _common_checks(records: list[dict], step: dict, result_digest: str, ok_reason: str) -> tuple[bool, str]:
    if records[0].get("timestamp", "") < step["issuedAt"]:
        return False, "transcript predates the step"

    last = records[-1]
    closing_text = _message_text(last).rstrip() if last.get("type") == "assistant" else ""
    if not closing_text.endswith(f"LOOP_SPEC_RESULT_DIGEST {result_digest}"):
        # A digest appearing earlier in the transcript (the worker's own hash
        # command output) does not count; only the closing record's ending does.
        return False, "final message does not end with the result digest"

    return True, ok_reason


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
        if step.get("effort") is not None:
            refusal = check_agent_type(transcripts[0], step)
            if refusal is not None:
                return False, refusal
        return check_transcript(transcripts[0], step, result_digest)


def check_agent_type(transcript: Path, step: dict) -> str | None:
    """7.4.0: a step with an effort is dispatched as the plugin's worker agent for that
    level; the host records no applied effort, so the agent type in the transcript's
    `.meta.json` is the only evidence it ran. No sidecar, or none naming the type, fails."""
    expected = subagent_type(step["effort"])
    meta = transcript.with_name(transcript.name[: -len(".jsonl")] + ".meta.json")
    try:
        agent_type = json.loads(meta.read_text(encoding="utf-8")).get("agentType")
    except (OSError, ValueError):
        agent_type = None
    if agent_type != expected:
        return f"dispatched as {agent_type or 'unknown'}; this step runs as {expected} for effort {step['effort']}"
    return None
