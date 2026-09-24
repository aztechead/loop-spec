"""Unit tests for loop_spec.events: console stream precedence and stdout markers."""
import contextlib
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from loop_spec.errors import LoopSpecError
from loop_spec.events import emit, marker_next, marker_phase_start, marker_question, marker_wait
from loop_spec.paths import FeaturePaths


def _paths(tmp) -> FeaturePaths:
    return FeaturePaths(root=Path(tmp) / "feature")


def _emit_under(env: dict, paths: FeaturePaths, event: str = "progress") -> tuple[str, str]:
    """Run emit() with only `env` set, returning (stdout, stderr) as strings."""
    out, err = io.StringIO(), io.StringIO()
    with patch.dict("os.environ", env, clear=True), \
         contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        emit(paths, event)
    return out.getvalue(), err.getvalue()


_INVOCATION = {"program": "/p/loop-spec", "stateHome": "/h", "projectRoot": "/r"}

class ConsoleStreamPrecedenceTests(unittest.TestCase):
    def test_console_stream_env_wins_over_cloud_run_job(self):
        with tempfile.TemporaryDirectory() as tmp:
            out, err = _emit_under({"LOOP_SPEC_CONSOLE_STREAM": "stderr", "CLOUD_RUN_JOB": "x"}, _paths(tmp))
            self.assertEqual(out, "")
            self.assertIn("progress", err)

    def test_k_service_routes_to_stdout(self):
        with tempfile.TemporaryDirectory() as tmp:
            out, err = _emit_under({"K_SERVICE": "x"}, _paths(tmp))
            self.assertIn("progress", out)
            self.assertEqual(err, "")

    def test_default_is_stderr(self):
        with tempfile.TemporaryDirectory() as tmp:
            out, err = _emit_under({}, _paths(tmp))
            self.assertEqual(out, "")
            self.assertIn("progress", err)

    def test_console_events_0_suppresses_console_but_ledger_still_appended(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = _paths(tmp)
            out, err = _emit_under({"LOOP_SPEC_CONSOLE_EVENTS": "0"}, paths)
            self.assertEqual(out, "")
            self.assertEqual(err, "")
            lines = paths.events_jsonl.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(lines), 1)


class ReservedNameTests(unittest.TestCase):
    def test_implementation_source_refuses_reserved_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(LoopSpecError):
                emit(_paths(tmp), "phase_start", source="implementation")

    def test_program_source_may_use_reserved_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            emit(_paths(tmp), "phase_start", source="program")  # must not raise


class MarkerTests(unittest.TestCase):
    def test_marker_prints_prefix_and_compact_json_on_stdout(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                marker_phase_start(_paths(tmp), "spec", "attempt-1")
            line = out.getvalue().strip()
            self.assertTrue(line.startswith("LOOP_SPEC_PHASE_START {"))
            self.assertNotIn(" ", line.split(" ", 1)[1])  # compact separators: no spaces in the JSON

    def test_marker_question_prints_only_question_id(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            marker_question(_paths(tempfile.mkdtemp()), "question-1")
        self.assertEqual(out.getvalue().strip(), 'LOOP_SPEC_QUESTION {"questionId":"question-1"}')

    def test_marker_next_prints_kind_path_and_slug(self):
        # LF-06: submit/answer require --slug and nothing else in LOOP_SPEC_NEXT
        # names the run, so the marker carries it.
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            marker_next("result", "/tmp/result.json", "greeting", _INVOCATION)
        self.assertEqual(
            out.getvalue().strip(),
            'LOOP_SPEC_NEXT {"kind":"result","path":"/tmp/result.json","program":"/p/loop-spec",'
            '"projectRoot":"/r","slug":"greeting","stateHome":"/h"}',
        )

    def test_the_wait_marker_carries_the_invocation_too(self):
        # D5: a resumed run's first line can be a wait, so it names the launcher too.
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            marker_wait(_paths(tempfile.mkdtemp()), ["step-1"], _INVOCATION)
        self.assertEqual(out.getvalue().strip(),
                         'LOOP_SPEC_WAIT {"open":["step-1"],"program":"/p/loop-spec","projectRoot":"/r","stateHome":"/h"}')

    def test_the_cli_invocation_names_a_launcher_that_exists(self):
        import argparse
        from loop_spec import cli
        home = tempfile.mkdtemp()
        invocation = cli._invocation(argparse.Namespace(state_home=home, project_root="/r"))
        self.assertTrue(Path(invocation["program"]).is_file())
        self.assertEqual((Path(invocation["stateHome"]).resolve(), invocation["projectRoot"]), (Path(home).resolve(), "/r"))

    def test_marker_next_for_a_role_step_carries_what_a_lead_dispatches(self):
        # The lead dispatches from the marker and dispatch.txt, never the ~170 KB step.json.
        import json
        step_dir = Path(tempfile.mkdtemp()) / "step-1"
        step_dir.mkdir()
        (step_dir / "step.json").write_text(json.dumps({"kind": "role", "stepAttemptId": "step-1", "role": "code-reviewer",
                                                        "model": "haiku", "transport": "file", "prompt": "x" * 1000}))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            marker_next("step", str(step_dir / "step.json"), "greeting", _INVOCATION)
        marker = json.loads(out.getvalue().strip().removeprefix("LOOP_SPEC_NEXT "))
        self.assertEqual((marker["stepKind"], marker["stepAttemptId"], marker["role"], marker["model"], marker["dispatchPath"]),
                         ("role", "step-1", "code-reviewer", "haiku", str(step_dir / "dispatch.txt")))
        self.assertNotIn("prompt", marker)
        self.assertEqual(marker["subagentType"], "general-purpose")  # no effort

    def test_an_effort_names_the_worker_agent_and_a_lead_step_names_none(self):
        # F5: the Agent tool has no per-call effort; a role step with one runs as the
        # plugin's worker agent for that level.
        import json
        for kind, effort, expected in (("role", "high", "loop-spec:worker-high"), ("lead", "high", None)):
            step_dir = Path(tempfile.mkdtemp()) / "step-1"
            step_dir.mkdir()
            (step_dir / "step.json").write_text(json.dumps({"kind": kind, "stepAttemptId": "step-1", "role": "code-reviewer",
                                                            "model": None, "effort": effort}))
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                marker_next("step", str(step_dir / "step.json"), "greeting", _INVOCATION)
            marker = json.loads(out.getvalue().strip().removeprefix("LOOP_SPEC_NEXT "))
            self.assertEqual((marker["effort"], marker.get("subagentType")), (effort, expected))


if __name__ == "__main__":
    unittest.main()
