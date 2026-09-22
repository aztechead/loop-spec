"""RunWatch through its interface, with real Agent SDK message types.

Each case is a message order a live session produced. Run with
`python3 -m unittest examples/sdk-plugin/test_run_loop_spec.py` where
claude-agent-sdk is installed; loop-spec's own suite does not run it.
"""
import json
import sys
import unittest
from pathlib import Path

from claude_agent_sdk import (
    ResultMessage,
    SystemMessage,
    TaskNotificationMessage,
    TaskStartedMessage,
    ToolResultBlock,
    UserMessage,
)

sys.path.insert(0, str(Path(__file__).parent))
from run_loop_spec import RunWatch  # noqa: E402


def init():
    return SystemMessage(subtype="init", data={})


def turn_end(turns=3):
    return ResultMessage(subtype="success", duration_ms=1, duration_api_ms=1, is_error=False,
                         num_turns=turns, session_id="s")


def started(task_id):
    return TaskStartedMessage(subtype="task_started", data={}, task_id=task_id, description=task_id,
                              uuid="u", session_id="s")


def finished(task_id):
    return TaskNotificationMessage(subtype="task_notification", data={}, task_id=task_id, status="completed",
                                   output_file="", summary=task_id, uuid="u", session_id="s")


def next_line(kind, path="/state/result.json"):
    marker = "LOOP_SPEC_NEXT " + json.dumps({"kind": kind, "path": path, "slug": "x"})
    return UserMessage(content=[ToolResultBlock(tool_use_id="t", content=f"[DELIVER] done\n{marker}")])


def feed(watch, messages):
    return [watch.observe(m) for m in messages]


class RunWatchTests(unittest.TestCase):
    def test_done_when_a_turn_ends_after_the_result_printed(self):
        watch = RunWatch()
        self.assertEqual(feed(watch, [init(), next_line("result"), turn_end()]), [False, False, True])
        self.assertEqual(watch.result_path, "/state/result.json")

    def test_a_turn_ending_while_workers_run_is_not_done(self):
        # sdkp1: the lead dispatched two background workers and its turn ended.
        watch = RunWatch()
        feed(watch, [init(), started("T-1"), started("T-2"), turn_end()])
        self.assertFalse(watch.idle)
        feed(watch, [finished("T-1"), init(), turn_end(), finished("T-2")])
        self.assertFalse(watch.observe(init()))
        self.assertEqual(feed(watch, [next_line("result"), turn_end()]), [False, True])

    def test_a_resume_replay_is_not_a_turn_end(self):
        # sdkp2: a resumed session reports stopped tasks and a zero-turn result first.
        watch = RunWatch()
        feed(watch, [finished("T-1"), turn_end(turns=0)])
        self.assertFalse(watch.idle)

    def test_idle_without_a_result_so_the_caller_times_out(self):
        # sdkp4: a finished task's notification was handled inside the turn; no
        # follow-up turn came. idle tells the caller to stop waiting after a while.
        watch = RunWatch()
        self.assertEqual(feed(watch, [init(), next_line("step", "/state/step.json"), turn_end()]), [False, False, False])
        self.assertTrue(watch.idle)
        self.assertIsNone(watch.result_path)


if __name__ == "__main__":
    unittest.main()
