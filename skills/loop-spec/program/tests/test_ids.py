"""Unit tests for loop_spec.ids: digest canonicalization, id shape, timestamps."""
import re
import unittest

from loop_spec.ids import digest, new_id, now_iso


class DigestTests(unittest.TestCase):
    def test_key_order_does_not_matter(self):
        self.assertEqual(digest({"a": 1, "b": 2}), digest({"b": 2, "a": 1}))

    def test_prefix_is_sha256(self):
        d = digest({"x": 1})
        self.assertTrue(d.startswith("sha256:"))
        self.assertRegex(d, r"^sha256:[0-9a-f]{64}$")

    def test_different_content_differs(self):
        self.assertNotEqual(digest({"a": 1}), digest({"a": 2}))


class NewIdTests(unittest.TestCase):
    def test_shape(self):
        value = new_id("run")
        self.assertRegex(value, r"^run-[0-9a-f]{12}$")

    def test_unknown_kind_raises(self):
        with self.assertRaises(ValueError):
            new_id("bogus")

    def test_now_iso_is_iso8601(self):
        self.assertRegex(now_iso(), r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+00:00$")


if __name__ == "__main__":
    unittest.main()
