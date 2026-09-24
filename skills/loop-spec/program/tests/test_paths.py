"""Unit tests for loop_spec.paths: state-home precedence, repo_id, slug derivation."""
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from loop_spec.paths import FeaturePaths, ensure_results_dir, repo_id, slug_from_request, state_home


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


    def test_a_shallow_clone_keeps_its_id_after_unshallowing(self):
        # LF-74 (live ea-b): adopting a PR unshallows a --depth=1 clone, which moved
        # the root commit and with it every later call's state key.
        with tempfile.TemporaryDirectory() as tmp:
            work, clone = Path(tmp) / "work", Path(tmp) / "clone"
            work.mkdir()
            _git(work, "init", "-q", "-b", "main")
            for msg in ("one", "two"):
                _git(work, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", msg)
            _git(tmp, "clone", "-q", "--depth=1", work.as_uri(), str(clone))
            before = repo_id(clone)
            _git(clone, "fetch", "-q", "--unshallow")
            self.assertEqual(before, repo_id(clone))

class FeaturePathsResultsDirTests(unittest.TestCase):
    # LF-27: a live model, under Claude Code's default permission mode, cannot
    # write anywhere under the state home (~/.claude/...) even with the Write
    # tool allow-listed; results_dir moves model-written results under the
    # project root instead, which is always writable.
    def test_results_dir_is_under_the_project_root_namespaced_by_slug(self):
        with tempfile.TemporaryDirectory() as home, tempfile.TemporaryDirectory() as project:
            root = Path(home) / "repo-id" / "add-a-widget"
            paths = FeaturePaths(root=root, project_root=Path(project))
            self.assertEqual(paths.results_dir, Path(project) / ".loop-spec" / "results" / "add-a-widget")

    def test_project_root_defaults_to_root_when_not_given(self):
        with tempfile.TemporaryDirectory() as home:
            root = Path(home) / "repo-id" / "add-a-widget"
            paths = FeaturePaths(root=root)
            self.assertEqual(paths.results_dir, root / ".loop-spec" / "results" / "add-a-widget")

    def test_ensure_results_dir_creates_it_and_excludes_it_once(self):
        with tempfile.TemporaryDirectory() as project:
            _git(project, "init", "-q")
            root = Path(project) / ".loop-spec-state" / "add-a-widget"
            paths = FeaturePaths(root=root, project_root=Path(project))

            ensure_results_dir(paths)
            ensure_results_dir(paths)

            self.assertTrue(paths.results_dir.is_dir())
            exclude_text = (Path(project) / ".git" / "info" / "exclude").read_text()
            self.assertEqual(exclude_text.count(".loop-spec/"), 1)

    def test_ensure_results_dir_on_a_non_repo_just_makes_the_dir(self):
        with tempfile.TemporaryDirectory() as project:
            root = Path(project) / ".loop-spec-state" / "add-a-widget"
            paths = FeaturePaths(root=root, project_root=Path(project))

            ensure_results_dir(paths)

            self.assertTrue(paths.results_dir.is_dir())
            self.assertFalse((Path(project) / ".git").exists())


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
