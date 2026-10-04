"""Hidden oracle for task wrong-premise. Never copied into the fixture the agent sees."""
import unittest

from tempconv import c_to_f, c_to_k, f_to_c


class Oracle(unittest.TestCase):
    def test_values(self):
        self.assertAlmostEqual(c_to_k(0), 273.15, places=6)
        self.assertAlmostEqual(c_to_k(-273.15), 0, places=6)
        self.assertAlmostEqual(c_to_k(100), 373.15, places=6)

    def test_below_absolute_zero(self):
        for c in (-273.16, -300, -400):
            with self.assertRaises(ValueError, msg=c):
                c_to_k(c)

    def test_never_negative_kelvin(self):
        for c in [x / 10 for x in range(-2731, 0, 7)]:
            self.assertGreaterEqual(c_to_k(c), 0)

    def test_existing(self):
        self.assertAlmostEqual(c_to_f(100), 212)
        self.assertAlmostEqual(f_to_c(32), 0)
