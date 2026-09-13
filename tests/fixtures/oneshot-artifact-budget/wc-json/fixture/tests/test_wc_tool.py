import io
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import wc_tool  # noqa: E402


class CountTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False)
        self.tmp.write("one two\nthree\n")
        self.tmp.close()

    def tearDown(self):
        os.unlink(self.tmp.name)

    def test_count(self):
        c = wc_tool.count(self.tmp.name)
        self.assertEqual((c["lines"], c["words"], c["chars"]), (2, 3, 14))

    def test_text_output(self):
        buf = io.StringIO()
        with redirect_stdout(buf):
            wc_tool.main([self.tmp.name])
        self.assertIn(self.tmp.name, buf.getvalue())
        self.assertIn("2", buf.getvalue())


if __name__ == "__main__":
    unittest.main()
