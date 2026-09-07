import io
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from todo import cli  # noqa: E402


def run(argv):
    buf = io.StringIO()
    with redirect_stdout(buf):
        code = cli.main(argv)
    return code, buf.getvalue()


class CliTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.file = os.path.join(self.dir, "todo.json")

    def test_add_and_list(self):
        run(["--file", self.file, "add", "buy milk"])
        run(["--file", self.file, "add", "walk dog"])
        code, out = run(["--file", self.file, "list"])
        self.assertEqual(code, 0)
        self.assertEqual(out.splitlines(), ["[ ] 1: buy milk", "[ ] 2: walk dog"])

    def test_done(self):
        run(["--file", self.file, "add", "buy milk"])
        code, out = run(["--file", self.file, "done", "1"])
        self.assertEqual(code, 0)
        self.assertEqual(out.strip(), "[x] 1: buy milk")

    def test_done_missing(self):
        code, _ = run(["--file", self.file, "done", "9"])
        self.assertEqual(code, 1)


if __name__ == "__main__":
    unittest.main()
