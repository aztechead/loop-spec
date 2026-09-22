"""Unit tests for loop_spec.paths: state-home precedence, repo_id, slug derivation."""
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from loop_spec.paths import repo_id, slug_from_request, state_home


def _git(cwd, *args):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True)


class StateHomeTests(unittest.TestCase):
    def test_explicit_wins_over_everything(self):
        with tempfile.TemporaryDirectory() as explicit, tempfile.TemporaryDirectory() as env_home:
            with patch.dict("os.environ", {"LOOP_SPEC_HOME": env_home}):
                self.assertEqual(state_home(explicit), Path(explicit))

    def test_env_var_wins_over_default(self):
        with tempfile.TemporaryDirectory() as env_home:
            with patch.dict("os.environ", {"LOOP_SPEC_HOME": env_home}):
                self.assertEqual(state_home(None), Path(env_home))

    def test_default_is_dot_loop_spec_under_home(self):
        with tempfile.TemporaryDirectory() as fake_home:
            with patch.dict("os.environ", {}, clear=True), \
                 patch("pathlib.Path.home", return_value=Path(fake_home)):
                self.assertEqual(state_home(None), Path(fake_home) / ".loop-spec")


class RepoIdTests(unittest.TestCase):
    def test_stable_and_16_hex_chars(self):
        with tempfile.TemporaryDirectory() as tmp:
            _git(tmp, "init", "-q")
            value = repo_id(Path(tmp))
            self.assertRegex(value, r"^[0-9a-f]{16}$")
            self.assertEqual(value, repo_id(Path(tmp)))

    def test_adding_origin_keeps_the_id(self):
        with tempfile.TemporaryDirectory() as tmp:
            _git(tmp, "init", "-q")
            _git(tmp, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "root")
            before = repo_id(Path(tmp))
            _git(tmp, "remote", "add", "origin", "https://example.com/org/repo.git")
            self.assertEqual(before, repo_id(Path(tmp)))

    def test_two_histories_differ(self):
        with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b:
            for tmp, msg in ((a, "one"), (b, "two")):
                _git(tmp, "init", "-q")
                _git(tmp, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", msg)
            self.assertNotEqual(repo_id(Path(a)), repo_id(Path(b)))


class SlugFromRequestTests(unittest.TestCase):
    def test_lowercase_alnum_joined_by_dash(self):
        self.assertEqual(slug_from_request("Add OAuth Login!"), "add-oauth-login")

    def test_truncated_to_40_chars(self):
        slug = slug_from_request("word " * 20)
        self.assertLessEqual(len(slug), 40)

    def test_never_empty(self):
        self.assertEqual(slug_from_request("!!!"), "feature")


if __name__ == "__main__":
    unittest.main()
