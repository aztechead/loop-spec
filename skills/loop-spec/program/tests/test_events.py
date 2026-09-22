"""Unit tests for loop_spec.events: console stream precedence and stdout markers."""
import contextlib
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from loop_spec.errors import LoopSpecError
from loop_spec.events import emit, marker_next, marker_phase_start, marker_question
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

    def test_marker_next_prints_kind_and_path(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            marker_next("result", "/tmp/result.json")
        self.assertEqual(out.getvalue().strip(), 'LOOP_SPEC_NEXT {"kind":"result","path":"/tmp/result.json"}')


if __name__ == "__main__":
    unittest.main()
