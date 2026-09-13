import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from slugify import slugify  # noqa: E402


class SlugifyTests(unittest.TestCase):
    def test_simple(self):
        self.assertEqual(slugify("Hello World"), "hello-world")

    def test_collapses_repeated_separators(self):
        self.assertEqual(slugify("Hello,  World!!"), "hello-world")

    def test_strips_edge_separators(self):
        self.assertEqual(slugify("  --Hello--  "), "hello")

    def test_keeps_digits(self):
        self.assertEqual(slugify("Release 2.0 notes"), "release-2-0-notes")


if __name__ == "__main__":
    unittest.main()
