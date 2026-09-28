"""Unit tests for loop_spec.log: output goes through logging, never print."""
import ast
import contextlib
import io
import unittest
from pathlib import Path

from loop_spec import log

REPO = Path(__file__).resolve().parents[4]


class LogTests(unittest.TestCase):
    def test_each_logger_writes_the_bare_message_to_the_current_stream(self):
        with contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()) as err:
            log.stdout.info('LOOP_SPEC_NEXT {"kind":"step"} 100%')
            log.stderr.error("loop-spec: failed")
        self.assertEqual(out.getvalue(), 'LOOP_SPEC_NEXT {"kind":"step"} 100%\n')
        self.assertEqual(err.getvalue(), "loop-spec: failed\n")

    def test_no_shipped_or_example_module_calls_print(self):
        sources = [*(REPO / "skills/loop-spec/program/loop_spec").glob("*.py"),
                   *(p for p in (REPO / "examples").rglob("*.py") if not p.name.startswith("test_"))]
        self.assertTrue(sources)
        calls = [f"{path.relative_to(REPO)}:{node.lineno}" for path in sources
                 for node in ast.walk(ast.parse(path.read_text(encoding="utf-8")))
                 if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "print"]
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
