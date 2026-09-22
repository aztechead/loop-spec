"""Unit tests for loop_spec.repo: workspace detection, git mechanics, PR adoption."""
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from loop_spec.errors import LoopSpecError
from loop_spec.repo import (
    add_worktree,
    adopt_pr,
    clean_checkout,
    commits_between,
    create_feature_branch,
    detect_workspace,
    exclude_path,
    files_added_by,
    find_pr_reference,
    head_sha,
    init_in_place,
    is_ancestor,
    is_clean,
    remove_worktree,
)


def _git(cwd, *args):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True)


def _init_repo(cwd):
    _git(cwd, "init", "-q", "-b", "main")
    _git(cwd, "config", "user.name", "Test")
    _git(cwd, "config", "user.email", "test@example.com")


def _commit(cwd, filename, message):
    Path(cwd, filename).write_text(f"{filename}\n")
    _git(cwd, "add", filename)
    _git(cwd, "commit", "-q", "-m", message)


class DetectWorkspaceTests(unittest.TestCase):
    def test_single(self):
        with tempfile.TemporaryDirectory() as tmp:
            _init_repo(tmp)
            ws = detect_workspace(Path(tmp))
            self.assertEqual(ws.mode, "single")
            self.assertEqual(ws.source, "git")
            self.assertEqual(len(ws.repos), 1)
            self.assertEqual(ws.repos[0].name, Path(tmp).resolve().name)

    def test_none(self):
        with tempfile.TemporaryDirectory() as tmp:
            ws = detect_workspace(Path(tmp))
            self.assertEqual(ws.mode, "none")
            self.assertEqual(ws.repos, [])

    def test_discovered(self):
        with tempfile.TemporaryDirectory() as tmp:
            for name in ("b-repo", "a-repo"):
                child = Path(tmp, name)
                child.mkdir()
                _init_repo(child)
            ws = detect_workspace(Path(tmp))
            self.assertEqual(ws.mode, "workspace")
            self.assertEqual(ws.source, "discovered")
            self.assertEqual([r.name for r in ws.repos], ["a-repo", "b-repo"])

    def test_config_workspace(self):
        with tempfile.TemporaryDirectory() as tmp:
            child = Path(tmp, "svc")
            child.mkdir()
            _init_repo(child)
            loop_spec_dir = Path(tmp, ".loop-spec")
            loop_spec_dir.mkdir()
            (loop_spec_dir / "workspace.json").write_text(json.dumps({"repos": [{"name": "svc", "path": "svc"}]}))
            ws = detect_workspace(Path(tmp))
            self.assertEqual(ws.mode, "workspace")
            self.assertEqual(ws.source, "config")
            self.assertEqual(ws.repos[0].name, "svc")

    def test_config_workspace_invalid_entry_raises(self):
        with tempfile.TemporaryDirectory() as tmp:
            loop_spec_dir = Path(tmp, ".loop-spec")
            loop_spec_dir.mkdir()
            (loop_spec_dir / "workspace.json").write_text(json.dumps({"repos": [{"name": "missing", "path": "nope"}]}))
            with self.assertRaises(LoopSpecError) as ctx:
                detect_workspace(Path(tmp))
            self.assertIn("does not exist", ctx.exception.message)


class InitInPlaceTests(unittest.TestCase):
    def test_creates_root_commit_on_empty_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = init_in_place(Path(tmp))
            self.assertEqual(repo.path, Path(tmp).resolve())
            sha = head_sha(Path(tmp))
            self.assertRegex(sha, r"^[0-9a-f]{40}$")

    def test_refuses_on_existing_repo(self):
        with tempfile.TemporaryDirectory() as tmp:
            _init_repo(tmp)
            with self.assertRaises(LoopSpecError) as ctx:
                init_in_place(Path(tmp))
            self.assertIn("already a git repository", ctx.exception.message)


class WorktreeTests(unittest.TestCase):
    def test_add_clean_checkout_and_remove(self):
        with tempfile.TemporaryDirectory() as tmp, tempfile.TemporaryDirectory() as workdir:
            _init_repo(tmp)
            _commit(tmp, "a.txt", "first")
            sha = head_sha(Path(tmp))
            create_feature_branch(Path(tmp), "feat/x", sha)

            wt_dest = Path(workdir, "wt")
            add_worktree(Path(tmp), wt_dest, branch="feat/x")
            self.assertTrue(wt_dest.is_dir())
            self.assertTrue(is_clean(wt_dest))
            remove_worktree(Path(tmp), wt_dest)
            self.assertFalse(wt_dest.exists())

            checkout_dest = Path(workdir, "co")
            clean_checkout(Path(tmp), sha, checkout_dest)
            self.assertTrue(checkout_dest.is_dir())
            remove_worktree(Path(tmp), checkout_dest)
            self.assertFalse(checkout_dest.exists())


class ExcludePathTests(unittest.TestCase):
    # LF-27: keeps .loop-spec/ out of `git status` without ever committing it.
    def test_appends_once_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            _init_repo(tmp)

            exclude_path(Path(tmp), ".loop-spec/")
            exclude_path(Path(tmp), ".loop-spec/")

            exclude_file = Path(tmp, ".git", "info", "exclude")
            lines = exclude_file.read_text().splitlines()
            self.assertEqual(lines.count(".loop-spec/"), 1)

    def test_a_linked_worktree_resolves_to_the_shared_exclude_file(self):
        with tempfile.TemporaryDirectory() as tmp, tempfile.TemporaryDirectory() as workdir:
            _init_repo(tmp)
            _commit(tmp, "a.txt", "first")
            sha = head_sha(Path(tmp))
            create_feature_branch(Path(tmp), "feat/x", sha)
            wt_dest = Path(workdir, "wt")
            add_worktree(Path(tmp), wt_dest, branch="feat/x")

            exclude_path(wt_dest, ".loop-spec/")

            self.assertIn(".loop-spec/", Path(tmp, ".git", "info", "exclude").read_text().splitlines())

    def test_non_repo_does_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            exclude_path(Path(tmp), ".loop-spec/")
            self.assertFalse((Path(tmp) / ".git").exists())


class HistoryTests(unittest.TestCase):
    def test_commits_between_and_is_ancestor(self):
        with tempfile.TemporaryDirectory() as tmp:
            _init_repo(tmp)
            _commit(tmp, "a.txt", "c1")
            c1 = head_sha(Path(tmp))
            _commit(tmp, "b.txt", "c2")
            c2 = head_sha(Path(tmp))
            _commit(tmp, "c.txt", "c3")
            c3 = head_sha(Path(tmp))

            self.assertEqual(commits_between(Path(tmp), c1, c3), [c2, c3])
            self.assertTrue(is_ancestor(Path(tmp), c1, c3))
            self.assertFalse(is_ancestor(Path(tmp), c3, c1))

    def test_files_added_by(self):
        with tempfile.TemporaryDirectory() as tmp:
            _init_repo(tmp)
            _commit(tmp, "a.txt", "c1")
            base = head_sha(Path(tmp))
            _commit(tmp, "b.txt", "c2")
            head = head_sha(Path(tmp))
            self.assertEqual(sorted(files_added_by(Path(tmp), base, head)), ["b.txt"])


class FindPrReferenceTests(unittest.TestCase):
    def test_hash_number(self):
        self.assertEqual(find_pr_reference("fixes #123 please"), 123)

    def test_pr_number(self):
        self.assertEqual(find_pr_reference("resume PR 456"), 456)

    def test_pull_slash_number(self):
        self.assertEqual(find_pr_reference("see pull/789 for context"), 789)

    def test_full_url(self):
        url = "https://github.com/org/repo/pull/42"
        self.assertEqual(find_pr_reference(f"continue work on {url}"), url)

    def test_no_match(self):
        self.assertIsNone(find_pr_reference("just a plain request"))


class AdoptPrTests(unittest.TestCase):
    def test_gh_absent_returns_no_adopt(self):
        with tempfile.TemporaryDirectory() as tmp:
            with patch("loop_spec.repo.shutil.which", return_value=None):
                result = adopt_pr(Path(tmp), 123)
            self.assertFalse(result.adopt)
            self.assertEqual(result.reason, "gh is not installed")


if __name__ == "__main__":
    unittest.main()
