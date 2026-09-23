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
    remove_worktrees,
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


class ReviewDiffTests(unittest.TestCase):
    def test_lockfile_content_is_named_not_carried(self):
        from loop_spec.repo import review_diff
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            _init_repo(repo)
            _commit(repo, "README", "init")
            base = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True).stdout.strip()
            (repo / "app.py").write_text("x = 1\n")
            (repo / "uv.lock").write_text("LOCKCONTENT\n" * 50)
            (repo / "web").mkdir()
            (repo / "web" / "package-lock.json").write_text("NESTEDLOCK\n")
            _git(repo, "add", "-A")
            _git(repo, "commit", "-q", "-m", "change")
            diff = review_diff(repo, f"{base}..HEAD")
        self.assertIn("+x = 1", diff)
        self.assertNotIn("LOCKCONTENT", diff)
        self.assertNotIn("NESTEDLOCK", diff)
        self.assertIn("uv.lock", diff)
        self.assertIn("web/package-lock.json", diff)


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

    def test_remove_worktrees_only_touches_those_under_paths_root(self):
        # LF-39: a terminal run's own feature dir is paths_root; a worktree some
        # OTHER run (or a checkout the test itself made) owns must survive.
        with tempfile.TemporaryDirectory() as tmp, tempfile.TemporaryDirectory() as run_dir, \
                tempfile.TemporaryDirectory() as other_dir:
            _init_repo(tmp)
            _commit(tmp, "a.txt", "first")
            sha = head_sha(Path(tmp))
            create_feature_branch(Path(tmp), "feat/x", sha)
            create_feature_branch(Path(tmp), "feat/y", sha)

            in_run = Path(run_dir, "worktrees", "feature")
            add_worktree(Path(tmp), in_run, branch="feat/x")
            outside = Path(other_dir, "wt")
            add_worktree(Path(tmp), outside, branch="feat/y")

            removed, skipped = remove_worktrees(Path(tmp), Path(run_dir))
            self.assertEqual(removed, [str(in_run.resolve())])
            self.assertEqual(skipped, [])
            self.assertFalse(in_run.exists())
            self.assertTrue(outside.is_dir())

            listing = subprocess.run(["git", "worktree", "list"], cwd=tmp, capture_output=True, text=True, check=True).stdout
            self.assertNotIn(str(in_run.resolve()), listing)
            self.assertIn(str(outside.resolve()), listing)

    def test_remove_worktrees_on_a_non_repo_returns_empty_instead_of_raising(self):
        with tempfile.TemporaryDirectory() as not_a_repo, tempfile.TemporaryDirectory() as run_dir:
            self.assertEqual(remove_worktrees(Path(not_a_repo), Path(run_dir)), ([], []))

    def test_a_protected_worktree_is_skipped_and_reported_not_removed(self):
        # R5: an open step's (or a quarantined one's) own worktree must never be
        # force-removed just because the run reached a terminal result
        # elsewhere -- the caller passes it in `protected`, derived from state.
        with tempfile.TemporaryDirectory() as tmp, tempfile.TemporaryDirectory() as run_dir:
            _init_repo(tmp)
            _commit(tmp, "a.txt", "first")
            sha = head_sha(Path(tmp))
            create_feature_branch(Path(tmp), "feat/x", sha)
            create_feature_branch(Path(tmp), "feat/y", sha)

            protected_wt = Path(run_dir, "worktrees", "task-1")
            add_worktree(Path(tmp), protected_wt, branch="feat/x")
            Path(protected_wt, "scratch.txt").write_text("uncommitted\n")

            finished_wt = Path(run_dir, "worktrees", "task-2")
            add_worktree(Path(tmp), finished_wt, branch="feat/y")

            removed, skipped = remove_worktrees(Path(tmp), Path(run_dir), protected={protected_wt.resolve()})
            self.assertEqual(removed, [str(finished_wt.resolve())])
            self.assertFalse(finished_wt.exists())
            self.assertTrue(protected_wt.is_dir())
            self.assertEqual(skipped, [{"path": str(protected_wt.resolve()), "reason": "open step or quarantined"}])

    def test_an_uncommitted_worktree_is_skipped_even_without_a_protection_record(self):
        # R5: uncommitted changes alone are enough to skip a worktree, even
        # with no open-step/quarantine record naming it -- discovered by
        # actually looking, since the caller cannot know this from state alone.
        with tempfile.TemporaryDirectory() as tmp, tempfile.TemporaryDirectory() as run_dir:
            _init_repo(tmp)
            _commit(tmp, "a.txt", "first")
            sha = head_sha(Path(tmp))
            create_feature_branch(Path(tmp), "feat/x", sha)

            dirty_wt = Path(run_dir, "worktrees", "task-1")
            add_worktree(Path(tmp), dirty_wt, branch="feat/x")
            Path(dirty_wt, "scratch.txt").write_text("uncommitted\n")

            removed, skipped = remove_worktrees(Path(tmp), Path(run_dir))
            self.assertEqual(removed, [])
            self.assertTrue(dirty_wt.is_dir())
            self.assertEqual(skipped, [{"path": str(dirty_wt.resolve()), "reason": "uncommitted changes"}])


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
