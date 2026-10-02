"""Unit tests for loop_spec.repo: workspace detection, git mechanics, PR adoption."""
import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from loop_spec.errors import LoopSpecError
from loop_spec.repo import (
    add_worktree,
    adopt_pr,
    check_credentials,
    clean_checkout,
    commits_between,
    create_feature_branch,
    default_branch,
    detect_workspace,
    exclude_path,
    fetch_pr_head,
    files_added_by,
    find_issue,
    find_pr_reference,
    free_branch,
    head_sha,
    init_in_place,
    is_ancestor,
    is_clean,
    restore_tracked_caches,
    uncommitted,
    pr_checks,
    remote_host,
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
    def test_a_test_runs_cache_is_clean_but_an_uncommitted_file_is_not(self):
        with tempfile.TemporaryDirectory() as tmp:
            _init_repo(tmp)
            _commit(tmp, "a.py", "x = 1\n")
            Path(tmp, "__pycache__").mkdir()
            Path(tmp, "__pycache__", "a.cpython-313.pyc").write_bytes(b"\0")
            Path(tmp, ".pytest_cache").mkdir()
            Path(tmp, ".pytest_cache", "README.md").write_text("cache\n")
            self.assertTrue(is_clean(Path(tmp)))
            Path(tmp, "b.py").write_text("y = 2\n")
            self.assertFalse(is_clean(Path(tmp)))

    def test_a_rewritten_tracked_cache_is_restored_and_other_changes_are_named(self):
        with tempfile.TemporaryDirectory() as tmp:
            _init_repo(tmp)
            Path(tmp, "__pycache__").mkdir()
            _commit(tmp, "__pycache__/a.cpython-313.pyc", "tracked bytecode")
            _commit(tmp, "a.py", "add a")
            Path(tmp, "__pycache__", "a.cpython-313.pyc").write_text("new")
            Path(tmp, "a.py").write_text("x = 2\n")
            self.assertEqual(uncommitted(Path(tmp)), ["a.py"])
            restore_tracked_caches(Path(tmp))
            self.assertEqual(Path(tmp, "__pycache__", "a.cpython-313.pyc").read_text(), "__pycache__/a.cpython-313.pyc\n")

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


class FetchPrHeadTests(unittest.TestCase):
    """A fresh --depth=1 --single-branch clone of the base can adopt a PR (EA-runs item 9)."""

    def _origin_with_pr(self, tmp: Path) -> tuple[Path, str]:
        work = tmp / "work"
        work.mkdir()
        _init_repo(work)
        for n in range(3):
            _commit(work, f"base{n}.txt", f"base {n}")
        _git(work, "checkout", "-q", "-b", "feat/pr")
        _commit(work, "pr.txt", "the PR")
        pr_head = head_sha(work)
        _git(work, "checkout", "-q", "main")
        _commit(work, "later.txt", "main moves on")
        origin = tmp / "origin.git"
        _git(tmp, "clone", "-q", "--bare", str(work), str(origin))
        return origin, pr_head

    def test_a_shallow_single_branch_clone_gets_the_pr_branch_and_a_merge_base(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            origin, pr_head = self._origin_with_pr(tmp)
            clone = tmp / "clone"
            # file://, not a path: a local-path clone ignores --depth.
            _git(tmp, "clone", "-q", "--depth=1", "--single-branch", "--branch", "main", origin.as_uri(), str(clone))
            fetch_pr_head(clone, "feat/pr", "main", pr_head, managed_root=tmp / "home")
            shallow = subprocess.run(["git", "rev-parse", "--is-shallow-repository"], cwd=clone,
                                     capture_output=True, text=True).stdout.strip()
            self.assertEqual(shallow, "false")
            self.assertEqual(head_sha(clone, "refs/heads/feat/pr"), pr_head)
            merge_base = subprocess.run(["git", "merge-base", "refs/remotes/origin/main", pr_head], cwd=clone,
                                        capture_output=True, text=True)
            self.assertEqual(merge_base.returncode, 0)

    def test_the_pr_branch_checked_out_is_refused_with_a_detach_repair(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            origin, pr_head = self._origin_with_pr(tmp)
            clone = tmp / "clone"
            _git(tmp, "clone", "-q", "--branch", "feat/pr", origin.as_uri(), str(clone))
            with self.assertRaises(LoopSpecError) as caught:
                fetch_pr_head(clone, "feat/pr", "main", pr_head, managed_root=tmp / "home")
            self.assertIn("checkout --detach", caught.exception.repair)


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


class RemoteHostTests(unittest.TestCase):
    def test_remote_host_forms(self):
        self.assertEqual(remote_host("git@ghe.example.com:o/r.git"), "ghe.example.com")
        self.assertEqual(remote_host("https://ghe.example.com/o/r"), "ghe.example.com")
        self.assertEqual(remote_host("ssh://git@ghe.example.com:22/o/r"), "ghe.example.com")
        self.assertIsNone(remote_host("/tmp/x.git"))
        self.assertIsNone(remote_host("file:///tmp/x.git"))
        self.assertIsNone(remote_host(None))


class CheckCredentialsTests(unittest.TestCase):
    def test_gh_is_checked_for_the_configured_origin_host(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "repo"
            bin_dir = Path(tmp) / "bin"
            repo.mkdir()
            bin_dir.mkdir()
            _init_repo(repo)
            _git(repo, "remote", "add", "origin", "git@ghe.example.com:o/r.git")
            # gh exits 0 only for the host-scoped check; the bare check fails.
            gh = bin_dir / "gh"
            gh.write_text('#!/bin/sh\n[ "$*" = "auth status --hostname ghe.example.com" ]\n')
            gh.chmod(gh.stat().st_mode | stat.S_IXUSR)
            with patch.dict(os.environ, {"PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}"}):
                status = check_credentials(repo)
            self.assertTrue(status.gh_ok)
            self.assertIn("gh auth status --hostname ghe.example.com", status.checked)
            self.assertNotIn("gh auth status", status.checked)


class FreeBranchTests(unittest.TestCase):
    def _clone_with_origin(self, tmp, origin_branches=()):
        repo = Path(tmp) / "repo"
        origin = Path(tmp) / "origin.git"
        repo.mkdir()
        _init_repo(repo)
        _commit(repo, "README", "init")
        _git(tmp, "init", "-q", "--bare", str(origin))
        _git(repo, "remote", "add", "origin", str(origin))
        for name in origin_branches:
            _git(repo, "push", "-q", "origin", f"HEAD:refs/heads/{name}")
        return repo

    def test_free_name_is_returned_as_is(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(free_branch(self._clone_with_origin(tmp), "feat/x"), "feat/x")

    def test_name_on_origin_gets_the_next_suffix(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(free_branch(self._clone_with_origin(tmp, ["feat/x"]), "feat/x"), "feat/x-2")

    def test_suffixed_names_on_origin_are_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(free_branch(self._clone_with_origin(tmp, ["feat/x", "feat/x-2"]), "feat/x"), "feat/x-3")

    def test_local_branch_without_a_remote_gets_the_next_suffix(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = self._clone_with_origin(tmp)
            _git(repo, "branch", "feat/x")
            self.assertEqual(free_branch(repo, "feat/x"), "feat/x-2")

    def test_unreachable_origin_leaves_the_name_alone(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = self._clone_with_origin(tmp)
            _git(repo, "remote", "set-url", "origin", str(Path(tmp) / "missing.git"))
            self.assertEqual(free_branch(repo, "feat/x"), "feat/x")

    def test_a_longer_sibling_name_is_not_taken(self):
        # The ls-remote glob `feat/x-*` does not match `feat/xy`, so `feat/x` stays free.
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(free_branch(self._clone_with_origin(tmp, ["feat/xy"]), "feat/x"), "feat/x")

    def test_a_branch_nested_under_the_name_takes_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(free_branch(self._clone_with_origin(tmp, ["feat/x/y"]), "feat/x"), "feat/x-2")
            repo = Path(tmp) / "repo"
            _git(repo, "branch", "feat/x-2/y")
            self.assertEqual(free_branch(repo, "feat/x"), "feat/x-3")

    def test_a_parent_path_branch_is_refused_here_or_on_origin(self):
        # No suffix frees feature/AVP-1234 while a `feature` branch exists.
        for local in (True, False):
            with self.subTest(local=local), tempfile.TemporaryDirectory() as tmp:
                repo = self._clone_with_origin(tmp, [] if local else ["feature"])
                if local:
                    _git(repo, "branch", "feature")
                with self.assertRaisesRegex(LoopSpecError, "'feature' exists"):
                    free_branch(repo, "feature/AVP-1234")


class FindIssueTests(unittest.TestCase):
    def _find(self, text, exclude=(), view=None, calls=None):
        view = view or (0, json.dumps({"number": 12, "title": "t", "url": "https://github.com/o/r/issues/12",
                                        "state": "OPEN", "body": "b"}), "")

        def gh(repo, *args):
            if calls is not None:
                calls.append(args)
            return view
        with patch("loop_spec.repo.run_gh", side_effect=gh):
            return find_issue(Path("."), text, set(exclude))

    def test_the_first_reference_outside_the_excluded_pr_numbers_is_read(self):
        calls = []
        issue = self._find("fix #7 as in #12", exclude={7}, calls=calls)
        self.assertEqual(issue["number"], 12)
        self.assertEqual(calls[0][:3], ("issue", "view", "12"))
        self.assertEqual(self._find("see github.com/o/r/issues/12")["number"], 12)

    def test_closed_pr_and_unreadable_issues_are_none(self):
        closed = (0, json.dumps({"number": 12, "url": "u", "state": "CLOSED"}), "")
        a_pr = (0, json.dumps({"number": 12, "url": "https://github.com/o/r/pull/12", "state": "OPEN"}), "")
        self.assertIsNone(self._find("#12", view=closed))
        self.assertIsNone(self._find("#12", view=a_pr))
        self.assertIsNone(self._find("#12", view=(1, "", "not found")))
        self.assertIsNone(self._find("no reference here"))


class PrChecksTests(unittest.TestCase):
    def _classify(self, code, out="", err=""):
        with patch("loop_spec.repo.run_gh", return_value=(code, out, err)):
            return pr_checks(Path("."), 7)[0]

    def test_the_exit_code_then_the_text_decide_the_state(self):
        self.assertEqual(self._classify(0, "build\tpass"), "pass")
        self.assertEqual(self._classify(8, "build\tpending"), "pending")
        self.assertEqual(self._classify(1, "", "no checks reported on the 'x' branch"), "none")
        self.assertEqual(self._classify(1, "build\tfail"), "fail")
        self.assertEqual(self._classify(127, "", "gh: not found"), "error")

    def test_a_timeout_is_an_error_not_a_hang(self):
        with patch("loop_spec.repo.subprocess.run", side_effect=subprocess.TimeoutExpired("gh", 60)):
            self.assertEqual(pr_checks(Path("."), 7)[0], "error")


if __name__ == "__main__":
    unittest.main()


class DefaultBranchTests(unittest.TestCase):
    def _repo_with_origin(self, tmp):
        repo = Path(tmp) / "repo"
        origin = Path(tmp) / "origin.git"
        repo.mkdir()
        _init_repo(repo)
        _commit(repo, "README", "init")
        _git(tmp, "init", "-q", "--bare", "-b", "main", str(origin))
        _git(repo, "remote", "add", "origin", str(origin))
        _git(repo, "push", "-q", "origin", "main")
        return repo

    def test_ls_remote_names_main_while_a_feature_branch_is_checked_out(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = self._repo_with_origin(tmp)
            _git(repo, "checkout", "-q", "-b", "wip")
            _git(repo, "remote", "set-head", "origin", "--delete")
            self.assertEqual(default_branch(repo), "main")

    def test_a_detached_head_with_no_origin_answer_raises(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "repo"
            repo.mkdir()
            _init_repo(repo)
            _commit(repo, "README", "init")
            _git(repo, "checkout", "-q", "--detach")
            with self.assertRaises(LoopSpecError):
                default_branch(repo)
