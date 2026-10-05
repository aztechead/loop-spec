"""A run across two repositories: the workspace root, one worktree per repository, tasks and checks
that name a repository, one verify, one PR per changed repository linked to each other, feedback
over every PR, the Stop hook, revise, and finish. Real git, and a fake `gh` keyed on the repository
it runs in."""
import contextlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from loop_spec import cli, hook, runs
from loop_spec.errors import LoopSpecError
from test_flow import commit, marker, sh

os.environ["LOOP_SPEC_HOME"] = tempfile.mkdtemp(prefix="loop-spec-home-")

FAKE_GH = """#!/usr/bin/env bash
# A stand-in for gh that answers per repository: the clone or worktree directory is named for it.
echo "$PWD: $*" >> "$FAKE_GH_DIR/calls"
name=$(basename "$PWD")
prev=""
for a in "$@"; do [ "$prev" = "--body-file" ] && cp "$a" "$FAKE_GH_DIR/body-$name.txt"; prev="$a"; done
case "$*" in
  "pr view "*"--json body"*) cat "$FAKE_GH_DIR/body-$name.txt" 2>/dev/null; exit 0 ;;
  "pr view "*"--json number,url"*)
    case "$3" in https://*) url="$3" ;; *) url="https://github.com/acme/$name/pull/$3" ;; esac
    echo "{\\"number\\": 7, \\"url\\": \\"$url\\", \\"headRefName\\": \\"feat/x\\", \\"baseRefName\\": \\"main\\", \\"state\\": \\"OPEN\\", \\"isCrossRepository\\": false}"
    exit 0 ;;
esac
case "$1 $2" in
  "pr list") echo "[]" ;;
  "pr create") echo "https://github.com/acme/$name/pull/7" ;;
  "repo view") echo "https://github.com/acme/$name" ;;
  "pr checks") cat "$FAKE_GH_DIR/checks-$name.json" 2>/dev/null || echo '[{"name": "job0", "bucket": "pass", "link": ""}]' ;;
  "pr view") echo '{"reviews": [], "comments": []}' ;;
  *) ;;
esac
"""

CRITERION = {"id": "AC-1", "text": "both repositories changed", "check": "test -f api/a.py && test -f web/w.py"}


class WorkspaceTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.base = Path(self._tmp.name)
        self.root = self.base / "ws"
        self.clones = {}
        for name in ("api", "web"):
            origin, path = self.base / f"origin-{name}.git", self.root / name
            sh(self.base, "git", "init", "-q", "--bare", "-b", "main", str(origin))
            sh(self.base, "git", "clone", "-q", str(origin), str(path))
            for key, value in (("user.email", "t@example.com"), ("user.name", "t"), ("commit.gpgsign", "false")):
                sh(path, "git", "config", key, value)
            commit(path, "seed.txt", f"{name} seed\n")  # distinct, so the root commits (and repo ids) differ
            sh(path, "git", "push", "-q", "origin", "main")
            self.clones[name] = path
        self.write_workspace([{"name": "api", "path": "api"}, {"name": "web", "path": "web"}])
        self.gh_dir = self.base / "gh"
        self.gh_dir.mkdir()
        (self.gh_dir / "gh").write_text(FAKE_GH)
        (self.gh_dir / "gh").chmod(0o755)
        self._env = mock.patch.dict(os.environ, {"PATH": f"{self.gh_dir}:{os.environ['PATH']}", "FAKE_GH_DIR": str(self.gh_dir)})
        self._env.start()

    def tearDown(self):
        self._env.stop()
        self._tmp.cleanup()

    def write_workspace(self, repos) -> None:
        (self.root / ".loop-spec").mkdir(exist_ok=True)
        (self.root / ".loop-spec" / "workspace.json").write_text(json.dumps({"repos": repos}))

    def ls(self, *args: str, cwd: Path | None = None) -> tuple[int, str, str]:
        n = 2 if args[0] == "task" else 1
        where = [] if cwd else ["--project-root", str(self.root)]
        before = os.getcwd()
        try:
            if cwd:
                os.chdir(cwd)
            with contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()) as err:
                code = cli.main([*args[:n], *where, *args[n:]])
        finally:
            os.chdir(before)
        return code, out.getvalue(), err.getvalue()

    def start(self, *extra: str) -> dict:
        code, out, err = self.ls("start", "--request", "Add both", *extra)
        self.assertEqual(code, 0, err)
        return marker(out, "LOOP_SPEC_RUN")

    def plan(self, run: dict, tasks: list, checks=None, criteria=None, prepare=None) -> None:
        Path(run["runDir"], "spec.json").write_text(json.dumps({"goal": "g", "criteria": criteria or [CRITERION]}))
        plan = {"tasks": tasks, **({"prepare": prepare} if prepare else {})}
        if checks is not None:
            plan["checks"] = checks
        Path(run["runDir"], "plan.json").write_text(json.dumps(plan))

    def do_task(self, task_id: str, filename: str) -> dict:
        code, out, err = self.ls("task", "start", task_id)
        self.assertEqual(code, 0, err)
        brief = marker(out, "LOOP_SPEC_TASK")
        commit(Path(brief["worktree"]), filename, "x = 1\n")
        self.assertEqual(self.ls("task", "done", task_id)[0], 0)
        return brief

    def both_tasks(self, run: dict) -> None:
        self.plan(run, [{"id": "T-A", "title": "api", "repo": "api"},
                        {"id": "T-W", "title": "web", "repo": "web", "verify": "test -f w.py"}])
        self.do_task("T-A", "a.py")
        self.do_task("T-W", "w.py")

    def verified_run(self) -> dict:
        run = self.start("--autonomous")
        self.both_tasks(run)
        self.assertEqual(self.ls("verify")[0], 0)
        self.assertEqual(self.ls("iterate")[0], 0)
        return run

    def describe(self, run: dict, name: str) -> None:
        pr = Path(run["runDir"], "pr")
        pr.mkdir(exist_ok=True)
        (pr / f"{name}.md").write_text(f"## Why the change\n\nThe {name} half.\n")

    def test_1_run_root_finds_the_workspace_and_refuses_bad_entries(self):
        run = self.start()
        sub = self.root / "api" / "deep"
        sub.mkdir()
        for start in (self.root, sub, Path(run["work"]) / "api"):
            self.assertEqual(runs.run_root(start), self.root.resolve())
        (self.base / "plain").mkdir()
        for repos, named in (([{"name": "x", "path": "../plain"}], "x"),
                             ([{"name": "api", "path": "api"}, {"name": "api", "path": "web"}], "api"),
                             ([{"name": "self", "path": "."}], "self")):
            self.write_workspace(repos)
            with self.assertRaises(LoopSpecError) as caught:
                runs.workspace_repos(self.root)
            self.assertIn(named, caught.exception.message)

    def test_1_clones_without_workspace_json_are_named_with_the_file_to_write(self):
        (self.root / ".loop-spec" / "workspace.json").unlink()
        with self.assertRaises(LoopSpecError) as caught:
            runs.run_root(self.root)
        self.assertIn("api, web", caught.exception.message)
        self.assertIn('"path": "web"', caught.exception.repair)

    def test_2_start_makes_a_worktree_per_repository(self):
        run = self.start()
        self.assertEqual(set(run["repos"]), {"api", "web"})
        for name, clone in self.clones.items():
            work = Path(run["work"]) / name
            self.assertEqual(sh(work, "git", "branch", "--show-current"), "feat/add-both")
            self.assertEqual(sh(work, "git", "rev-parse", "HEAD"), sh(clone, "git", "rev-parse", "origin/main"))
            self.assertEqual(run["repos"][name]["work"], str(work))
        state = json.loads(Path(run["runDir"], "state.json").read_text())
        self.assertEqual(set(state["repos"]), {"api", "web"})
        self.assertEqual(state["repos"]["web"]["path"], "web")

    def test_3_a_plan_that_names_no_repository_is_reported_on_the_plan_line(self):
        run = self.start()
        self.plan(run, [{"id": "T-1", "title": "t"}])
        out = self.ls("status")[1]
        self.assertRegex(out, r"plan +plan\.json is not a usable task graph: T-1 has no known `repo` \(one of: api, web\)")
        self.plan(run, [{"id": "T-1", "title": "t", "repo": "api"}], checks=["true"])
        self.assertIn("`checks` entry #1 must be an object with a `repo` (one of: api, web)", self.ls("status")[1])

    def test_3b_the_same_command_in_two_repositories_runs_in_both(self):
        run = self.start()
        self.plan(run, [{"id": "T-1", "title": "t", "repo": "api", "verify": "echo hi"}],
                  checks=[{"repo": "web", "command": "echo hi"}], criteria=[{"id": "AC-1", "text": "t", "check": "true"}])
        code, out, err = self.ls("verify")
        self.assertEqual(code, 0, out + err)
        self.assertEqual(len([line for line in out.splitlines() if "echo hi" in line]), 2)

    def test_4_a_task_works_in_its_own_repository(self):
        run = self.start()
        self.plan(run, [{"id": "T-W", "title": "web", "repo": "web"}], checks=[
            {"repo": "api", "command": "echo api-check"}, {"repo": "web", "command": "echo web-check"}],
            prepare={"web": "grep -q web seed.txt"})
        code, out, _ = self.ls("task", "start", "T-W")
        brief = marker(out, "LOOP_SPEC_TASK")
        self.assertEqual((brief["repo"], brief["checks"], brief["prepared"]), ("web", ["echo web-check"], True))
        worktree = Path(brief["worktree"])
        self.assertEqual(Path(sh(worktree, "git", "rev-parse", "--path-format=absolute", "--git-common-dir")),
                         (self.clones["web"] / ".git").resolve())
        commit(worktree, "w.py", "x = 1\n")
        api_head = sh(Path(run["work"]) / "api", "git", "rev-parse", "HEAD")
        self.assertEqual(self.ls("task", "done", "T-W")[0], 0)
        self.assertTrue((Path(run["work"]) / "web" / "w.py").exists())
        self.assertEqual(sh(Path(run["work"]) / "api", "git", "rev-parse", "HEAD"), api_head)

    def test_5_verify_checks_every_repository_and_records_both_heads(self):
        run = self.start()
        self.both_tasks(run)
        code, out, err = self.ls("verify")
        self.assertEqual(code, 0, out + err)
        state = json.loads(Path(run["runDir"], "state.json").read_text())
        heads = {n: sh(Path(run["work"]) / n, "git", "rev-parse", "HEAD") for n in ("api", "web")}
        self.assertEqual(state["verify"]["sha"], heads)
        self.assertTrue(state["verify"]["passed"])
        self.assertEqual(marker(self.ls("status")[1], "LOOP_SPEC_RUN")["phase"], "iterate")

    def test_6_deliver_opens_a_linked_pr_per_changed_repository(self):
        run = self.verified_run()
        code, out, err = self.ls("deliver")
        self.assertEqual(code, 1, out)  # no pr/<name>.md yet
        self.assertIn("[api] there is no PR description", err)
        for name in ("api", "web"):
            self.describe(run, name)
        code, out, err = self.ls("deliver")
        self.assertEqual(code, 0, out + err)
        self.assertIn("[api] delivered", out)
        self.assertIn("[web] delivered", out)
        self.assertIn("web#7", (self.gh_dir / "body-api.txt").read_text())
        self.assertIn("api#7", (self.gh_dir / "body-web.txt").read_text())
        state = json.loads(Path(run["runDir"], "state.json").read_text())
        for name in ("api", "web"):
            self.assertEqual(state["repos"][name]["pr"]["url"], f"https://github.com/acme/{name}/pull/7")
            self.assertEqual(state["repos"][name]["delivered"]["sha"], state["verify"]["sha"][name])

    def test_6_set_repo_gives_one_repository_its_own_branch_and_title(self):
        run = self.verified_run()
        code, out, err = self.ls("set", "--repo", "web", "--branch", "web/count", "--title", "[WEB] Document count")
        self.assertEqual(code, 0, err)
        for name in ("api", "web"):
            self.describe(run, name)
        self.assertEqual(self.ls("deliver")[0], 0)
        calls = (self.gh_dir / "calls").read_text().splitlines()
        create = {name: next(c for c in calls if c.startswith(f"{run['work']}/{name}: pr create")) for name in ("api", "web")}
        self.assertIn("--head web/count --title [WEB] Document count", create["web"])
        self.assertIn(f"--head feat/{run['slug']} --title ", create["api"])
        self.assertNotIn("[WEB]", create["api"])

    def test_6_a_repository_without_commits_gets_no_pr(self):
        run = self.start("--autonomous")
        self.plan(run, [{"id": "T-A", "title": "api", "repo": "api"}],
                  criteria=[{"id": "AC-1", "text": "t", "check": "test -f api/a.py"}])
        self.do_task("T-A", "a.py")
        self.assertEqual(self.ls("verify")[0], 0)
        self.assertEqual(self.ls("iterate")[0], 0)
        self.describe(run, "api")
        code, out, err = self.ls("deliver")
        self.assertEqual(code, 0, out + err)
        self.assertNotIn("[web]", out)
        self.assertNotIn("Part of one change", (self.gh_dir / "body-api.txt").read_text())
        self.assertFalse((self.gh_dir / "body-web.txt").exists())

    def test_7_feedback_reads_every_pr_and_ends_the_run(self):
        run = self.verified_run()
        for name in ("api", "web"):
            self.describe(run, name)
        self.assertEqual(self.ls("deliver")[0], 0)
        (self.gh_dir / "checks-web.json").write_text(json.dumps([{"name": "job9", "bucket": "fail", "link": ""}]))
        code, out, _ = self.ls("feedback", "--timeout", "0")
        self.assertEqual(code, 1)
        self.assertIn("CI FAILED", out)
        self.assertRegex(out, r"\[web\]\s+fail\s+job9")
        (self.gh_dir / "checks-web.json").unlink()
        code, out, err = self.ls("feedback", "--timeout", "0")
        self.assertEqual(code, 0, out + err)
        result = json.loads(Path(run["runDir"], "result.json").read_text())
        self.assertEqual(sorted(p["repo"] for p in result["prs"]), ["api", "web"])
        self.assertEqual(sorted(t["repo"] for t in result["delivery"]["targets"]), ["api", "web"])
        self.assertIsNone(result["verifiedSha"])

    def test_8_the_stop_hook_finds_the_run_from_the_root_and_from_a_worktree(self):
        run = self.start("--autonomous")
        for cwd in (self.root, Path(run["work"]) / "api"):
            answer = hook.decide({"cwd": str(cwd), "last_assistant_message": "Done."}, cli._next_step)
            self.assertEqual(answer["decision"], "block")
            self.assertIn(run["slug"], answer["reason"])

    def test_9_revise_needs_the_url_when_the_number_is_ambiguous(self):
        web = self.clones["web"]
        sh(web, "git", "checkout", "-q", "-b", "feat/x")
        commit(web, "w.py", "x = 1\n")
        sh(web, "git", "push", "-q", "origin", "feat/x")
        sh(web, "git", "checkout", "-q", "main")
        code, _, err = self.ls("start", "--pr", "7")
        self.assertEqual(code, 1)
        self.assertIn("PR 7 matches api, web", err)
        code, out, err = self.ls("start", "--pr", "https://github.com/acme/web/pull/7")
        self.assertEqual(code, 0, err)
        run = marker(out, "LOOP_SPEC_RUN")
        self.assertEqual(set(run["repos"]), {"web"})
        state = json.loads(Path(run["runDir"], "state.json").read_text())
        self.assertEqual((state["kind"], set(state["repos"]), state["repos"]["web"]["pr"]["adopted"]), ("revise", {"web"}, True))

    def test_10_finish_removes_every_worktree(self):
        run = self.start()
        self.both_tasks(run)
        self.assertEqual(self.ls("verify")[0], 0)
        self.assertEqual(self.ls("finish", "--status", "no-change", "--summary", "s")[0], 0)
        for clone in self.clones.values():
            self.assertEqual(len(sh(clone, "git", "worktree", "list").splitlines()), 1)
        self.assertFalse(Path(run["work"]).exists())


if __name__ == "__main__":
    unittest.main()
