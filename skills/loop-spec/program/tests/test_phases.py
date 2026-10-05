"""The 7.x-compatible phase stream: the markers, console lines, and events.jsonl records that
monitors built for 7.x read, across a whole run against a real repository and a fake `gh`."""
import json
import os
import re
import unittest
from pathlib import Path
from unittest import mock

import test_loop
from test_flow import commit

START_KEYS = {"attemptId", "event", "phase", "timestamp"}
END_KEYS = {"attemptId", "elapsedSeconds", "event", "headSha", "next", "phase", "timestamp", "verdict"}


def markers(text: str) -> list[tuple[str, dict]]:
    found = []
    for line in text.splitlines():
        m = re.match(r"^(LOOP_SPEC_PHASE_(?:START|END)) (\{.*\})$", line)
        if m:
            found.append((m.group(1), json.loads(m.group(2))))
    return found


class PhaseStreamTests(unittest.TestCase):
    # The repository, fake gh, and run helpers of test_loop, without its tests.
    base = test_loop.LoopTests
    setUp, tearDown, checks, ready_run = base.setUp, base.tearDown, base.checks, base.ready_run

    def run_all(self, *steps) -> tuple[str, str]:
        out, err = "", ""
        for step in steps:
            _, o, e = self.repo.ls(*step)
            out, err = out + o, err + e
        return out, err

    def test_a_run_announces_every_7x_phase_in_order_in_7x_format(self):
        _, start_out, start_err = self.repo.ls("start", "--request", "Add mul")
        run = json.loads(start_out.splitlines()[-1].split(" ", 1)[1])
        Path(run["runDir"], "spec.json").write_text(json.dumps(
            {"goal": "g", "criteria": [{"id": "AC-1", "text": "t", "check": "true"}]}))
        Path(run["runDir"], "plan.json").write_text(json.dumps({"tasks": [{"id": "T-1", "title": "a"}]}))
        Path(run["runDir"], "pr.md").write_text("## Why the change\n\nmul.\n")
        out, start_task_err = self.run_all(("task", "start", "T-1"))
        commit(Path(run["runDir"], "tasks", "T-1"), "mul.py", "x = 1\n")
        self.checks("pass")
        more_out, err = self.run_all(("task", "done", "T-1"), ("verify",), ("iterate",), ("deliver",), ("feedback",))
        stream = markers(start_out + out + more_out)
        err = start_err + start_task_err + err

        phases = [(kind[-3:], m["phase"], m.get("verdict"), m.get("next")) for kind, m in stream]
        self.assertEqual(phases, [
            ("ART", "spec", None, None), ("END", "spec", "advanced", "plan"),
            ("ART", "plan", None, None), ("END", "plan", "advanced", "execute"),
            ("ART", "execute", None, None), ("END", "execute", "advanced", "verify"),
            ("ART", "verify", None, None), ("END", "verify", "advanced", "iterate"),
            ("ART", "iterate", None, None), ("END", "iterate", "advanced", "deliver"),
            ("ART", "deliver", None, None), ("END", "deliver", "completed", None),
        ])
        for kind, m in stream:
            self.assertEqual(set(m), START_KEYS if kind.endswith("START") else END_KEYS)
            self.assertTrue(m["attemptId"].startswith("attempt-"))
        starts = {m["phase"]: m["attemptId"] for kind, m in stream if kind.endswith("START")}
        self.assertTrue(all(m["attemptId"] == starts[m["phase"]] for kind, m in stream if kind.endswith("END")))

        self.assertIn("[ITERATE] iterate converged -> deliver", err)
        self.assertIn("[DELIVER] deliver delivered -> terminal", err)
        self.assertRegex(err, r"\[EXECUTE\] execute attempt attempt-[0-9a-f]{12}")
        events = [json.loads(line) for line in Path(run["runDir"], "events.jsonl").read_text().splitlines()]
        self.assertEqual({e["event"] for e in events}, {"phase_start", "phase_end", "transition", "result"})
        self.assertEqual(json.loads(Path(run["runDir"], "result.json").read_text())["phaseReached"], "deliver")

    def test_markers_the_leads_pipe_cut_are_reported_once_by_the_post_tool_use_hook(self):
        from loop_spec import hook, runs
        _, start_out, _ = self.repo.ls("start", "--request", "Add mul")
        run = runs.all_runs(self.repo.path)[0]
        hook.stream_gaps({"tool_name": "Bash", "cwd": str(self.repo.path), "tool_response": ""})  # empty what start left
        Path(run.dir, "spec.json").write_text(json.dumps(
            {"goal": "g", "criteria": [{"id": "AC-1", "text": "t", "check": "true"}]}))
        self.repo.ls("status")  # SPEC -> PLAN
        pending = run.pending_stream.read_text().splitlines()
        self.assertEqual([m["phase"] for _, m in markers("\n".join(pending))], ["spec", "plan"])
        hook_input = {"tool_name": "Bash", "cwd": str(self.repo.path), "tool_response": {"stdout": "ok", "stderr": ""}}
        self.assertEqual(hook.stream_gaps(hook_input), pending)
        self.assertFalse(run.pending_stream.exists())
        run.pending_stream.write_text("\n".join(pending) + "\n")
        shown = {**hook_input, "tool_response": {"stdout": "\n".join(pending), "stderr": ""}}
        self.assertEqual(hook.stream_gaps(shown), [])

    def test_the_markers_come_last_so_a_lead_keeping_the_tail_passes_them_on(self):
        _, start_out, _ = self.repo.ls("start", "--request", "Add mul")
        run = json.loads(start_out.splitlines()[-1].split(" ", 1)[1])
        Path(run["runDir"], "spec.json").write_text(json.dumps(
            {"goal": "g", "criteria": [{"id": "AC-1", "text": "t", "check": "true"}]}))
        Path(run["runDir"], "plan.json").write_text(json.dumps({"tasks": [{"id": "T-1", "title": "a"}]}))
        # the host's run: `status 2>&1 | grep -v "^LOOP_SPEC_RUN" | tail -12`, then `task done T-4 2>&1 | tail -2`
        lines = self.repo.ls("status")[1].splitlines()
        self.assertTrue(lines[-1].startswith("LOOP_SPEC_RUN "))
        self.assertEqual([m["phase"] for _, m in markers("\n".join(lines[-4:-1]))], ["plan", "plan", "execute"])
        self.repo.ls("task", "start", "T-1")
        commit(Path(run["runDir"], "tasks", "T-1"), "mul.py", "x = 1\n")
        tail = self.repo.ls("task", "done", "T-1")[1].splitlines()[-2:]
        self.assertEqual([(k, m["phase"]) for k, m in markers("\n".join(tail))],
                         [("LOOP_SPEC_PHASE_END", "execute"), ("LOOP_SPEC_PHASE_START", "verify")])

    def test_moving_back_announces_a_rewind_and_the_phase_again(self):
        run = self.ready_run()
        self.assertEqual(self.repo.ls("verify")[0], 0)
        commit(Path(run["work"]), "fix.py", "x = 2\n")  # a review fix: the verified head moved
        out = self.repo.ls("status")[1]
        stream = [(m["phase"], m.get("verdict"), m.get("next")) for _, m in markers(out)]
        self.assertEqual(stream, [("iterate", "rewind", "verify"), ("verify", None, None)])

    def test_a_fix_verified_at_once_still_enters_verify(self):
        run = self.ready_run()
        self.repo.ls("verify")
        self.repo.ls("iterate")
        commit(Path(run["work"]), "fix.py", "x = 2\n")  # a review fix, verified with no status in between
        out = self.repo.ls("verify")[1]
        stream = [(m["phase"], m.get("verdict"), m.get("next")) for _, m in markers(out)]
        self.assertEqual(stream, [("deliver", "rewind", "verify"), ("verify", None, None),
                                  ("verify", "advanced", "iterate"), ("iterate", None, None)])

    def test_console_lines_follow_the_7x_stream_settings(self):
        with mock.patch.dict(os.environ, {"LOOP_SPEC_CONSOLE_STREAM": "stdout"}):
            _, out, err = self.repo.ls("start", "--request", "Add mul")
        self.assertRegex(out, r"\[SPEC\] spec attempt attempt-")
        self.assertNotIn("[SPEC]", err)
        with mock.patch.dict(os.environ, {"LOOP_SPEC_CONSOLE_EVENTS": "0"}):
            _, out, err = self.repo.ls("start", "--request", "Add div")
        self.assertNotIn("[SPEC]", out + err)
        self.assertIn("LOOP_SPEC_PHASE_START", out)



if __name__ == "__main__":
    unittest.main()
