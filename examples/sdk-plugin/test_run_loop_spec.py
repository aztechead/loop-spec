"""RunWatch and the question seam through their interfaces, with real Agent SDK
message types. RunWatch cases are message orders a live session produced, or
review findings on 635bc7c. Run with
`python3 -m unittest examples/sdk-plugin/test_run_loop_spec.py` where
claude-agent-sdk is installed; loop-spec's own suite does not run it.
"""
import asyncio
import io
import json
import sys
import unittest
from pathlib import Path
from unittest import mock

from claude_agent_sdk import (
    ResultMessage,
    SystemMessage,
    TaskNotificationMessage,
    TaskStartedMessage,
    ToolResultBlock,
    UserMessage,
)

sys.path.insert(0, str(Path(__file__).parent))
from run_loop_spec import RunWatch, answer_first_option, answer_from_stdin, choose_answerer  # noqa: E402

QUESTION = {"question": "Approve?", "options": [{"label": "Approve"}, {"label": "Reject"}]}


def init():
    return SystemMessage(subtype="init", data={})


def turn_end(turns=3, error=False):
    return ResultMessage(subtype="error_during_execution" if error else "success", duration_ms=1,
                         duration_api_ms=1, is_error=error, num_turns=turns, session_id="s",
                         errors=["boom"] if error else None)


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

    def test_a_zero_turn_error_ends_the_watch_with_its_reason(self):
        watch = RunWatch()
        self.assertTrue(watch.observe(turn_end(turns=0, error=True)))
        self.assertEqual(watch.error, "error_during_execution; boom")

    def test_a_failed_turn_ends_the_watch_while_tasks_run(self):
        watch = RunWatch()
        feed(watch, [init(), started("T-1")])
        self.assertTrue(watch.observe(turn_end(error=True)))


def answer_with_stdin(text, question=QUESTION):
    with mock.patch.object(sys, "stdin", io.StringIO(text)), mock.patch.object(sys, "stderr", io.StringIO()):
        return asyncio.run(answer_from_stdin(question))


class AnswererTests(unittest.TestCase):
    def test_only_explicit_auto_selects_the_policy_adapter(self):
        self.assertIs(choose_answerer(True), answer_first_option)
        with mock.patch.object(sys.stdin, "isatty", return_value=False):
            self.assertIs(choose_answerer(False), answer_from_stdin)

    def test_out_of_range_numbers_are_asked_again(self):
        self.assertEqual(answer_with_stdin("0\n3\n2\n"), "Reject")

    def test_text_is_a_free_answer_and_blank_lines_are_skipped(self):
        self.assertEqual(answer_with_stdin("\nship it after lunch\n"), "ship it after lunch")

    def test_end_of_input_returns_none(self):
        self.assertIsNone(answer_with_stdin(""))
        self.assertIsNone(answer_with_stdin("5\n"))

    def test_auto_has_no_answer_without_options(self):
        self.assertIsNone(asyncio.run(answer_first_option({"question": "Why?", "options": []})))


if __name__ == "__main__":
    unittest.main()
