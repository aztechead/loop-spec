"""Unit tests for loop_spec.sdk_runner: message mapping, fail-closed result writing,
and the can_use_tool policy.

No test calls the real SDK or the network: `sys.modules["claude_agent_sdk"]` is
patched with a small fake module providing just the names sdk_runner.py uses, and
fake message dataclasses here structurally mirror the real SDK's (see sdk-facts.md).
"""
import json
import sys
import tempfile
import types
import unittest
from dataclasses import dataclass, field
from pathlib import Path
from unittest.mock import patch

from loop_spec.errors import LoopSpecError
from loop_spec.sdk_runner import event_from_message, policy, run_step_sdk


@dataclass
class TextBlock:
    text: str


@dataclass
class ToolUseBlock:
    id: str
    name: str
    input: dict


@dataclass
class AssistantMessage:
    content: list
    model: str = "claude"


@dataclass
class ResultMessage:
    subtype: str
    duration_ms: int = 0
    duration_api_ms: int = 0
    is_error: bool = False
    num_turns: int = 1
    session_id: str = "session-1"
    total_cost_usd: float | None = None
    structured_output: object = None
    permission_denials: list | None = None


@dataclass
class PermissionResultAllow:
    behavior: str = "allow"
    updated_input: dict | None = None
    updated_permissions: list | None = None


@dataclass
class PermissionResultDeny:
    behavior: str = "deny"
    message: str = ""
    interrupt: bool = False


@dataclass
class ClaudeAgentOptions:
    cwd: str | None = None
    model: str | None = None
    permission_mode: str | None = None
    plugins: list = field(default_factory=list)
    setting_sources: list | None = None
    output_format: dict | None = None
    can_use_tool: object = None


def _fake_sdk_module(messages: list) -> types.ModuleType:
    module = types.ModuleType("claude_agent_sdk")
    module.PermissionResultAllow = PermissionResultAllow
    module.PermissionResultDeny = PermissionResultDeny
    module.ClaudeAgentOptions = ClaudeAgentOptions

    async def fake_query(*, prompt, options=None, transport=None):
        for msg in messages:
            yield msg

    module.query = fake_query
    return module


class EventFromMessageTests(unittest.TestCase):
    def test_text_block_maps_to_worker_text(self):
        self.assertEqual(event_from_message(TextBlock(text="hello")), {"kind": "worker_text", "text": "hello"})

    def test_tool_use_block_maps_to_worker_tool_use(self):
        event = event_from_message(ToolUseBlock(id="1", name="Read", input={"file_path": "a.py"}))
        self.assertEqual(event, {"kind": "worker_tool_use", "name": "Read"})

    def test_result_message_maps_to_worker_result(self):
        msg = ResultMessage(subtype="success", is_error=False, num_turns=3, total_cost_usd=0.02,
                             permission_denials=[])
        event = event_from_message(msg)
        self.assertEqual(event["kind"], "worker_result")
        self.assertEqual(event["subtype"], "success")
        self.assertEqual(event["num_turns"], 3)

    def test_unknown_type_maps_to_none(self):
        self.assertIsNone(event_from_message(object()))


class PolicyTests(unittest.IsolatedAsyncioTestCase):
    async def test_denies_ask_user_question(self):
        with patch.dict(sys.modules, {"claude_agent_sdk": _fake_sdk_module([])}):
            result = await policy("AskUserQuestion", {}, None)
        self.assertEqual(result.behavior, "deny")
        self.assertIn("question.json", result.message)

    async def test_bash_and_other_tool_cases(self):
        cases = [
            ("Bash", "rm -rf /tmp/x", "deny"),
            ("Bash", "git push origin main --force", "deny"),
            ("Bash", "ls -la", "allow"),
            ("Read", "n/a", "allow"),
        ]
        with patch.dict(sys.modules, {"claude_agent_sdk": _fake_sdk_module([])}):
            for tool_name, command, expected in cases:
                with self.subTest(tool_name=tool_name, command=command):
                    result = await policy(tool_name, {"command": command, "file_path": "a.py"}, None)
                    self.assertEqual(result.behavior, expected)


class RunStepSdkTests(unittest.TestCase):
    # simplicity: setUp/tearDown are unittest's fixed method names, not a naming
    # choice; house-style.sh's camelCase deviation here is the same pre-existing
    # false positive test_execute.py, test_result.py, and test_postconditions.py hit.
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.result_path = Path(self._tmp.name, "result.json")
        self.step = {"cwd": self._tmp.name, "prompt": "do the thing", "schema": {"type": "object"},
                     "resultPath": str(self.result_path)}

    def tearDown(self):
        self._tmp.cleanup()

    def test_success_writes_the_result_and_maps_events(self):
        messages = [
            AssistantMessage(content=[TextBlock(text="working on it"), ToolUseBlock(id="1", name="Read", input={})]),
            ResultMessage(subtype="success", structured_output={"exit": "ok"}, session_id="sess-42"),
        ]
        with patch.dict(sys.modules, {"claude_agent_sdk": _fake_sdk_module(messages)}):
            run = run_step_sdk(self.step, plugin_path=Path("/plugin"), model=None)

        self.assertTrue(run.ok)
        self.assertEqual(run.session_id, "sess-42")
        self.assertTrue(run.unverifiedLive)
        self.assertEqual(json.loads(self.result_path.read_text()), {"exit": "ok"})
        kinds = [e["kind"] for e in run.events]
        self.assertEqual(kinds, ["worker_text", "worker_tool_use", "worker_result"])

    def test_missing_structured_output_fails_closed(self):
        messages = [ResultMessage(subtype="success", structured_output=None)]
        with patch.dict(sys.modules, {"claude_agent_sdk": _fake_sdk_module(messages)}):
            run = run_step_sdk(self.step, plugin_path=Path("/plugin"), model=None)
        self.assertFalse(run.ok)
        self.assertFalse(self.result_path.exists())

    def test_error_subtype_fails_closed_with_the_reason(self):
        messages = [ResultMessage(subtype="error_max_structured_output_retries")]
        with patch.dict(sys.modules, {"claude_agent_sdk": _fake_sdk_module(messages)}):
            run = run_step_sdk(self.step, plugin_path=Path("/plugin"), model=None)
        self.assertFalse(run.ok)
        self.assertEqual(run.reason, "error_max_structured_output_retries")
        self.assertFalse(self.result_path.exists())

    def test_missing_sdk_raises_loop_spec_error(self):
        with patch.dict(sys.modules, {"claude_agent_sdk": None}):
            with self.assertRaises(LoopSpecError):
                run_step_sdk(self.step, plugin_path=Path("/plugin"), model=None)


if __name__ == "__main__":
    unittest.main()
