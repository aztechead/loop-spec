"""Hidden oracle for task feat-one. Never copied into the fixture the agent sees."""
import unittest

from calc import add, clamp, sub


class Oracle(unittest.TestCase):
    def test_clamp(self):
        self.assertEqual(clamp(5, 0, 3), 3)
        self.assertEqual(clamp(-1, 0, 3), 0)
        self.assertEqual(clamp(2, 0, 3), 2)
        self.assertEqual(clamp(0, 0, 0), 0)
        self.assertEqual(clamp(3, 0, 3), 3)
        self.assertAlmostEqual(clamp(2.5, 0.0, 1.5), 1.5)
        self.assertEqual(clamp(-7, -5, -2), -5)

    def test_bad_range(self):
        with self.assertRaises(ValueError):
            clamp(1, 3, 0)

    def test_existing(self):
        self.assertEqual(add(2, 3), 5)
        self.assertEqual(sub(2, 3), -1)
