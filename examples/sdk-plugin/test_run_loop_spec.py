"""RunWatch and the question handling through their interfaces, with real Agent SDK
message types. Run with `python3 -m unittest examples/sdk-plugin/test_run_loop_spec.py`
where claude-agent-sdk is installed; loop-spec's own suite does not run it.
"""
import argparse
import asyncio
import io
import json
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from claude_agent_sdk import (
    PermissionResultAllow,
    PermissionResultDeny,
    ResultMessage,
    SystemMessage,
    TaskNotificationMessage,
    TaskStartedMessage,
    ToolResultBlock,
    UserMessage,
)

sys.path.insert(0, str(Path(__file__).parent))
from run_loop_spec import RunWatch, answer_from_stdin, current_phase, make_can_use_tool, model_for, prompt_for, result_file  # noqa: E402

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


def tool_output(text):
    return UserMessage(content=[ToolResultBlock(tool_use_id="t", content=text)])


def result_line(path="/home/u/.loop-spec/0123456789abcdef/x/result.json"):
    return tool_output("delivered feat/x\nLOOP_SPEC_RESULT " + json.dumps({"schema": 1, "status": "completed"}) +
                       "\nLOOP_SPEC_NEXT " + json.dumps({"kind": "result", "path": path, "slug": "x"}))


def feed(watch, messages):
    return [watch.observe(m) for m in messages]


class RunWatchTests(unittest.TestCase):
    def test_done_when_a_turn_ends_after_the_result_printed(self):
        watch = RunWatch()
        self.assertEqual(feed(watch, [init(), result_line(), turn_end()]), [False, False, True])
        self.assertEqual(watch.result_path, "/home/u/.loop-spec/0123456789abcdef/x/result.json")

    def test_a_phase_model_holds_until_a_later_phase_names_another(self):
        self.assertEqual(model_for("verify", {"execute": "sonnet"}), "sonnet")
        self.assertIsNone(model_for("plan", {"execute": "sonnet"}))
        self.assertEqual(model_for("deliver", {"execute": "sonnet", "deliver": "opus"}), "opus")
        self.assertIsNone(model_for("done", {"execute": "sonnet"}))

    def test_the_phase_comes_from_the_newest_runs_events(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.assertIsNone(current_phase(root))
            for slug, phases in (("old", ["spec"]), ("new", ["spec", "plan", "execute"])):
                events = root / ".loop-spec" / "runs" / slug / "events.jsonl"
                events.parent.mkdir(parents=True)
                events.write_text("".join(json.dumps({"event": "phase_start", "phase": p}) + "\n" for p in phases))
                time.sleep(0.01)
            self.assertEqual(current_phase(root), "execute")
            with events.open("a") as f:
                f.write(json.dumps({"event": "result", "phase": "deliver"}) + "\n")
            self.assertEqual(current_phase(root), "done")

    def test_a_next_line_the_lead_cut_short_is_skipped_and_the_run_directory_has_the_result(self):
        watch = RunWatch()
        cut = tool_output('LOOP_SPEC_NEXT {"kind": "result", "path": "/home/u/.loop-spec/01')
        self.assertEqual(feed(watch, [init(), cut, turn_end()]), [False, False, False])
        with tempfile.TemporaryDirectory() as d:
            run = Path(d, ".loop-spec", "runs", "x")
            run.mkdir(parents=True)
            (run / "result.json").write_text("{}")
            self.assertEqual(result_file(Path(d), 0), str(run / "result.json"))
            self.assertIsNone(result_file(Path(d), time.time() + 60))

    def test_a_turn_ending_while_workers_run_is_not_done(self):
        watch = RunWatch()
        feed(watch, [init(), started("T-1"), started("T-2"), turn_end()])
        self.assertFalse(watch.idle)
        feed(watch, [finished("T-1"), init(), turn_end(), finished("T-2")])
        self.assertFalse(watch.observe(init()))
        self.assertEqual(feed(watch, [result_line(), turn_end()]), [False, True])

    def test_a_resume_replay_is_not_a_turn_end(self):
        watch = RunWatch()
        feed(watch, [finished("T-1"), turn_end(turns=0)])
        self.assertFalse(watch.idle)

    def test_idle_without_a_result_so_the_caller_times_out(self):
        watch = RunWatch()
        self.assertEqual(feed(watch, [init(), tool_output("LOOP_SPEC_RUN {}"), turn_end()]), [False, False, False])
        self.assertTrue(watch.idle)
        self.assertIsNone(watch.result_path)

    def test_an_error_ends_the_watch_with_its_reason_even_while_tasks_run(self):
        watch = RunWatch()
        feed(watch, [init(), started("T-1")])
        self.assertTrue(watch.observe(turn_end(turns=0, error=True)))
        self.assertEqual(watch.error, "error_during_execution; boom")


def answer_with_stdin(text, question=QUESTION):
    with mock.patch.object(sys, "stdin", io.StringIO(text)), mock.patch.object(sys, "stderr", io.StringIO()):
        return asyncio.run(answer_from_stdin(question))


class QuestionTests(unittest.TestCase):
    def test_out_of_range_numbers_are_asked_again(self):
        self.assertEqual(answer_with_stdin("0\n3\n2\n"), "Reject")

    def test_text_is_a_free_answer_and_blank_lines_are_skipped(self):
        self.assertEqual(answer_with_stdin("\nship it after lunch\n"), "ship it after lunch")

    def test_end_of_input_returns_none(self):
        self.assertIsNone(answer_with_stdin(""))

    def test_an_autonomous_run_declines_questions_without_stopping(self):
        can_use_tool = make_can_use_tool(autonomous=True)
        with mock.patch.object(sys, "stderr", io.StringIO()):
            decision = asyncio.run(can_use_tool("AskUserQuestion", {"questions": [QUESTION]}, None))
        self.assertIsInstance(decision, PermissionResultDeny)
        self.assertIn("choose the reasonable default", decision.message.lower())
        self.assertFalse(decision.interrupt)

    def test_an_interactive_answer_rides_on_updated_input(self):
        can_use_tool = make_can_use_tool(autonomous=False)
        with mock.patch.object(sys, "stdin", io.StringIO("1\n")), mock.patch.object(sys, "stderr", io.StringIO()):
            decision = asyncio.run(can_use_tool("AskUserQuestion", {"questions": [QUESTION]}, None))
        self.assertIsInstance(decision, PermissionResultAllow)
        self.assertEqual(decision.updated_input["answers"], {"Approve?": "Approve"})


class PromptTests(unittest.TestCase):
    def test_the_entry_is_sent_as_a_slash_command(self):
        args = argparse.Namespace(entry="debug", autonomous=True, supervised=False, request="test_x fails")
        self.assertEqual(prompt_for(args), "/loop-spec:debug test_x fails")


if __name__ == "__main__":
    unittest.main()
