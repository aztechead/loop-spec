"""The CLI against real git repositories: start, the task graph, merges, verify, finish,
and the deliver refusals. Each test builds a repository with a bare `origin` in a temp dir."""
import contextlib
import io
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from loop_spec import cli
from loop_spec.errors import LoopSpecError

# The state home 7.x hosts read (legacy.py) goes to a scratch directory, never ~/.loop-spec.
os.environ["LOOP_SPEC_HOME"] = tempfile.mkdtemp(prefix="loop-spec-home-")


def sh(cwd, *args):
    return subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class Repo:
    def __init__(self, root: Path) -> None:
        self.origin = root / "origin.git"
        self.path = root / "repo"
        sh(root, "git", "init", "-q", "--bare", "-b", "main", str(self.origin))
        sh(root, "git", "clone", "-q", str(self.origin), str(self.path))
        for key, value in (("user.email", "t@example.com"), ("user.name", "t"), ("commit.gpgsign", "false")):
            sh(self.path, "git", "config", key, value)
        (self.path / "calc.py").write_text("def add(a, b):\n    return a + b\n")
        sh(self.path, "git", "add", "calc.py")
        sh(self.path, "git", "commit", "-qm", "init")
        sh(self.path, "git", "push", "-q", "origin", "main")

    def ls(self, *args: str) -> tuple[int, str, str]:
        n = 2 if args[0] == "task" else 1  # options follow the (sub)command words
        with contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()) as err:
            code = cli.main([*args[:n], "--project-root", str(self.path), *args[n:]])
        return code, out.getvalue(), err.getvalue()


def marker(text: str, name: str) -> dict:
    line = next(line for line in text.splitlines() if line.startswith(name + " "))
    return json.loads(line[len(name) + 1:])


def verdict(run_dir, head, findings=(), name="verdict.json") -> str:
    """Save a reviewer's json verdict for `head` in the run directory and return its path."""
    path = Path(run_dir, name)
    path.write_text(json.dumps({"head": head, "findings": list(findings)}))
    return str(path)


def commit(worktree: Path, name: str, text: str) -> None:
    (worktree / name).write_text(text)
    sh(worktree, "git", "add", name)
    sh(worktree, "git", "commit", "-qm", f"add {name}")


class FlowTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = Repo(Path(self._tmp.name))

    def tearDown(self):
        self._tmp.cleanup()

    def start(self, *extra: str) -> dict:
        code, out, err = self.repo.ls("start", "--request", "Add mul and sub", *extra)
        self.assertEqual(code, 0, err)
        return marker(out, "LOOP_SPEC_RUN")

    def task_start(self, *ids: str) -> dict:
        code, out, err = self.repo.ls("task", "start", *ids)
        self.assertEqual(code, 0, err)
        briefs = [json.loads(line.split(" ", 1)[1]) for line in out.splitlines() if line.startswith("LOOP_SPEC_TASK ")]
        return {b["id"]: b for b in briefs}

    def write(self, run: dict, spec: dict, plan: dict) -> None:
        Path(run["runDir"], "spec.json").write_text(json.dumps(spec))
        Path(run["runDir"], "plan.json").write_text(json.dumps(plan))

    def test_start_branches_from_origin_and_keeps_runs_out_of_git_status(self):
        run = self.start("--autonomous")
        self.assertEqual((run["phase"], run["mode"], run["slug"]), ("spec", "autonomous", "add-mul-and-sub"))
        self.assertEqual(sh(run["work"], "git", "branch", "--show-current"), "feat/add-mul-and-sub")
        self.assertEqual(sh(self.repo.path, "git", "status", "--porcelain"), "")

    def test_starting_the_same_request_again_resumes_it(self):
        first = self.start()
        code, out, _ = self.repo.ls("start", "--request", "Add mul and sub")
        self.assertIn("resuming add-mul-and-sub", out)
        self.assertEqual(marker(out, "LOOP_SPEC_RUN")["runDir"], first["runDir"])

    def test_a_graph_runs_in_waves_and_verify_records_the_head(self):
        run = self.start()
        check = "python3 -c 'import calc; assert calc.mul(2, 3) == 6 and calc.sub(3, 2) == 1'"
        self.write(run, {"goal": "g", "criteria": [{"id": "AC-1", "text": "both work", "check": check}]},
                   {"tasks": [{"id": "T-1", "title": "mul"}, {"id": "T-2", "title": "sub"},
                              {"id": "T-3", "title": "export", "dependsOn": ["T-1", "T-2"], "criteria": ["AC-1"]}]})
        self.assertIn("next     loop-spec task start T-1 T-2", self.repo.ls("status")[1])

        briefs = self.task_start("T-1", "T-2")
        self.assertEqual(briefs["T-1"]["criteria"], [])
        commit(Path(briefs["T-1"]["worktree"]), "mul.py", "def mul(a, b):\n    return a * b\n")
        commit(Path(briefs["T-2"]["worktree"]), "sub.py", "def sub(a, b):\n    return a - b\n")
        self.assertIn("T-1 merged (1 commit)", self.repo.ls("task", "done", "T-1")[1])
        self.assertIn("next: loop-spec task start T-3", self.repo.ls("task", "done", "T-2")[1])

        brief = self.task_start("T-3")["T-3"]
        self.assertEqual(brief["criteria"][0]["check"], check)
        self.assertEqual(brief["goal"], "g")
        t3 = Path(brief["worktree"])
        self.assertTrue((t3 / "mul.py").exists() and (t3 / "sub.py").exists())
        with (t3 / "calc.py").open("a") as f:
            f.write("from mul import mul\nfrom sub import sub\n")
        sh(t3, "git", "commit", "-qam", "export")
        self.assertIn("next: loop-spec verify", self.repo.ls("task", "done", "T-3")[1])

        code, out, _ = self.repo.ls("verify")
        self.assertEqual(code, 0, out)
        state = json.loads(Path(run["runDir"], "state.json").read_text())
        self.assertEqual(state["verify"]["sha"], sh(run["work"], "git", "rev-parse", "HEAD"))
        self.assertTrue(state["verify"]["passed"])
        self.assertEqual(marker(self.repo.ls("status")[1], "LOOP_SPEC_RUN")["phase"], "iterate")
        self.assertIn("review of", self.repo.ls("iterate", "--verdict-file", verdict(run["runDir"], sh(run["work"], "git", "rev-parse", "HEAD")))[1])
        self.assertEqual(marker(self.repo.ls("status")[1], "LOOP_SPEC_RUN")["phase"], "deliver")

    def test_verify_at_base_records_the_base_and_deliver_needs_a_failure_there(self):
        run = self.start("--kind", "debug")
        self.write(run, {"goal": "g", "criteria": [{"id": "AC-1", "text": "fixed", "check": "test -f fixed"}]},
                   {"tasks": [{"id": "T-1", "title": "fix"}]})
        state_path = Path(run["runDir"], "state.json")
        code, out, _ = self.repo.ls("verify", "--base")
        self.assertEqual(code, 1)
        self.assertIn("recorded as the base record", out)
        state = json.loads(state_path.read_text())
        self.assertNotEqual(state["baseVerify"]["results"][0]["exit"], 0)
        self.assertNotIn("verify", state)
        commit(Path(run["work"]), "fixed", "")
        self.assertEqual(self.repo.ls("verify")[0], 0)
        self.assertEqual(self.repo.ls("iterate", "--verdict-file", verdict(run["runDir"], sh(run["work"], "git", "rev-parse", "HEAD")))[0], 0)
        state = json.loads(state_path.read_text())
        base = state.pop("baseVerify")
        state_path.write_text(json.dumps(state))
        code, _, err = self.repo.ls("deliver")
        self.assertEqual(code, 1)
        self.assertIn("verify --base", err)
        state["baseVerify"] = base
        state_path.write_text(json.dumps(state))
        code, _, err = self.repo.ls("deliver")
        self.assertEqual(code, 1)
        self.assertIn("there is no PR description", err)

    def test_refactor_deliver_needs_a_criterion_that_passed_at_the_base(self):
        run = self.start("--kind", "refactor")
        self.write(run, {"goal": "g", "criteria": [{"id": "AC-1", "text": "t", "check": "test -f moved"}]},
                   {"tasks": [{"id": "T-1", "title": "move"}]})
        self.assertEqual(self.repo.ls("verify", "--base")[0], 1)
        commit(Path(run["work"]), "moved", "")
        self.assertEqual(self.repo.ls("verify")[0], 0)
        self.assertEqual(self.repo.ls("iterate", "--verdict-file", verdict(run["runDir"], self.head(run)))[0], 0)
        code, _, err = self.repo.ls("deliver")
        self.assertEqual(code, 1)
        self.assertIn("no criterion passed at the base", err)
        self.write(run, {"goal": "g", "criteria": [{"id": "AC-1", "text": "t", "check": "test -f calc.py"}]},
                   {"tasks": [{"id": "T-1", "title": "move"}]})
        self.assertEqual(self.repo.ls("verify", "--base")[0], 0)
        self.assertEqual(self.repo.ls("verify")[0], 0)
        self.assertEqual(self.repo.ls("iterate", "--verdict-file", verdict(run["runDir"], self.head(run)))[0], 0)
        code, _, err = self.repo.ls("deliver")
        self.assertNotIn("no criterion passed at the base", err)

    def verified(self, *extra: str) -> dict:
        run = self.start(*extra)
        self.write(run, {"goal": "g", "criteria": [{"id": "AC-1", "text": "t", "check": "true"}]}, {"tasks": [{"id": "T-1", "title": "a"}]})
        commit(Path(self.task_start("T-1")["T-1"]["worktree"]), "a.txt", "a\n")
        self.assertEqual(self.repo.ls("task", "done", "T-1")[0], 0)
        self.assertEqual(self.repo.ls("verify")[0], 0)
        return run

    def head(self, run: dict) -> str:
        return sh(run["work"], "git", "rev-parse", "HEAD")

    def test_iterate_refuses_an_open_blocking_finding_and_status_names_it(self):
        run = self.verified()
        finding = {"id": "F-1", "file": "a.txt", "line": 1, "blocking": True, "summary": "wrong"}
        code, out, _ = self.repo.ls("iterate", "--verdict-file", verdict(run["runDir"], self.head(run), [finding]))
        self.assertEqual(code, 1)
        self.assertIn("1 blocking finding(s) open", out)
        state = json.loads(Path(run["runDir"], "state.json").read_text())
        self.assertNotIn("iterate", state)
        self.assertEqual(len(state["reviews"]), 1)
        self.assertIn("F-1", self.repo.ls("status")[1])

    def test_iterate_accepts_a_declined_blocking_finding(self):
        run = self.verified()
        finding = {"id": "F-1", "file": "a.txt", "blocking": True, "summary": "wrong"}
        path = verdict(run["runDir"], self.head(run), [finding])
        code, _, err = self.repo.ls("iterate", "--verdict-file", path, "--decline", "F-1")
        self.assertEqual(code, 1)
        self.assertIn("give a reason", err)
        self.assertEqual(self.repo.ls("iterate", "--verdict-file", path, "--decline", "F-1=out of scope")[0], 0)
        state = json.loads(Path(run["runDir"], "state.json").read_text())
        self.assertEqual(state["iterate"]["sha"], self.head(run))
        self.assertEqual(state["reviews"][-1]["declined"], {"F-1": "out of scope"})

    def test_iterate_refuses_a_verdict_for_another_head_and_a_missing_verdict(self):
        run = self.verified()
        code, _, err = self.repo.ls("iterate", "--verdict-file", verdict(run["runDir"], "0" * 40))
        self.assertEqual(code, 1)
        self.assertIn("review the current head", err)
        code, _, err = self.repo.ls("iterate")
        self.assertEqual(code, 1)
        self.assertIn("ITERATE records the reviewer's verdict", err)

    def test_a_micro_run_may_iterate_without_a_verdict(self):
        run = self.verified("--kind", "micro")
        self.assertEqual(self.repo.ls("iterate")[0], 0)
        self.assertTrue(json.loads(Path(run["runDir"], "state.json").read_text())["reviews"][-1]["self"])

    def test_repeat_blocking_file_is_the_file_two_reviews_of_different_heads_share(self):
        def review(sha, *files):
            return {"sha": sha, "findings": [{"id": f"F-{i}", "file": f, "blocking": True} for i, f in enumerate(files)], "declined": {}}
        run = SimpleNamespace(state={"reviews": [review("a", "x.py", "y.py"), {"sha": "b", "self": True}, review("c", "y.py")]})
        self.assertEqual(cli._repeat_blocking_file(run), ["y.py"])
        run.state["reviews"].append(review("c", "y.py", "z.py"))  # a re-review of the same head
        self.assertEqual(cli._repeat_blocking_file(run), ["y.py"])
        run.state["reviews"] = [review("a", "x.py"), review("c", "y.py")]
        self.assertEqual(cli._repeat_blocking_file(run), [])

    def test_finish_completed_needs_a_clear_feedback_round(self):
        run = self.verified()
        head = self.head(run)
        state_path = Path(run["runDir"], "state.json")
        state = json.loads(state_path.read_text())
        state.update(pr={"number": 7, "url": "u"}, delivered={"sha": head, "verified": True, "title": "t"},
                     feedback={"sha": head, "ci": "failed", "seen": []})
        state_path.write_text(json.dumps(state))
        code, _, err = self.repo.ls("finish", "--status", "completed", "--summary", "s")
        self.assertEqual(code, 1)
        self.assertIn("not clear", err)
        self.assertEqual(self.repo.ls("finish", "--status", "escalated", "--summary", "s")[0], 0)

    def test_a_conflicting_task_is_refused_and_left_for_the_lead(self):
        run = self.start()
        self.write(run, {"goal": "g", "criteria": [{"id": "AC-1", "text": "t"}]}, {"tasks": [{"id": "T-1", "title": "a"}, {"id": "T-2", "title": "b"}]})
        paths = {tid: b["worktree"] for tid, b in self.task_start("T-1", "T-2").items()}
        commit(Path(paths["T-1"]), "calc.py", "one\n")
        commit(Path(paths["T-2"]), "calc.py", "two\n")
        self.assertEqual(self.repo.ls("task", "done", "T-1")[0], 0)
        code, _, err = self.repo.ls("task", "done", "T-2")
        self.assertEqual(code, 1)
        self.assertIn("T-2 conflicts with the feature branch in: calc.py", err)
        self.assertEqual(sh(run["work"], "git", "status", "--porcelain"), "")

        subprocess.run(["git", "merge", "-q", "feat/add-mul-and-sub"], cwd=paths["T-2"], capture_output=True)  # conflicts
        Path(paths["T-2"], "calc.py").write_text("one and two\n")
        sh(paths["T-2"], "git", "commit", "-qam", "resolve")
        self.assertEqual(self.repo.ls("task", "done", "T-2")[0], 0)
        self.assertEqual(Path(run["work"], "calc.py").read_text(), "one and two\n")

    def test_a_task_the_lead_did_in_work_is_marked_done_without_a_worktree(self):
        run = self.start()
        self.write(run, {"goal": "g", "criteria": [{"id": "AC-1", "text": "t"}]}, {"tasks": [{"id": "T-1", "title": "a"}]})
        commit(Path(run["work"]), "mul.py", "x = 1\n")
        code, out, _ = self.repo.ls("task", "done", "T-1")
        self.assertEqual(code, 0)
        self.assertIn("T-1 done in work", out)
        self.assertIn("next: loop-spec verify", out)

    def test_a_cyclic_plan_is_reported_with_its_cycle(self):
        run = self.start()
        self.write(run, {"goal": "g", "criteria": [{"id": "AC-1", "text": "t"}]},
                   {"tasks": [{"id": "T-1", "title": "a", "dependsOn": ["T-2"]}, {"id": "T-2", "title": "b", "dependsOn": ["T-1"]}]})
        _, out, _ = self.repo.ls("status")
        self.assertIn("dependency cycle: T-1 -> T-2 -> T-1", out)
        code, _, err = self.repo.ls("task", "start", "T-1")
        self.assertEqual(code, 1)
        self.assertIn("not a usable task graph", err)

    def test_deliver_refuses_a_head_verify_did_not_pass(self):
        run = self.start()
        self.write(run, {"goal": "g", "criteria": [{"id": "AC-1", "text": "t", "check": "true"}]}, {"tasks": [{"id": "T-1", "title": "a"}]})
        commit(Path(run["work"]), "a.txt", "a\n")
        code, _, err = self.repo.ls("deliver")
        self.assertEqual(code, 1)
        self.assertIn("refusing to deliver an unverified head: no verify has run", err)
        self.assertEqual(self.repo.ls("verify")[0], 0)
        commit(Path(run["work"]), "b.txt", "b\n")
        code, _, err = self.repo.ls("deliver")
        self.assertIn("but the branch is now at", err)
        self.assertEqual(self.repo.ls("verify")[0], 0)  # the verify checkout is reused at the new head
        self.assertTrue(Path(run["runDir"], "verify", "b.txt").is_file())

    def test_task_start_prepares_each_new_worktree_and_briefs_it(self):
        run = self.start()
        self.write(run, {"goal": "g", "criteria": [{"id": "AC-1", "text": "t", "check": "true"}]},
                   {"prepare": "echo ready > prepared.txt", "tasks": [{"id": "T-1", "title": "a", "criteria": ["AC-1"]}]})
        brief = self.task_start("T-1")["T-1"]
        self.assertTrue(brief["prepared"])
        self.assertEqual(Path(brief["worktree"], "prepared.txt").read_text(), "ready\n")
        self.assertEqual(brief["criteria"], [{"id": "AC-1", "text": "t", "check": "true"}])

    def test_a_finished_tasks_checkout_is_reused_with_its_ignored_files(self):
        with open(self.repo.path / ".git" / "info" / "exclude", "a") as f:
            f.write("cache/\n")
        run = self.start()
        prepare = "mkdir -p cache && { test -f cache/x && echo reused || echo fresh; } > cache/state && touch cache/x"
        self.write(run, {"goal": "g", "criteria": [{"id": "AC-1", "text": "t"}]},
                   {"prepare": prepare, "tasks": [{"id": "T-1", "title": "a"}, {"id": "T-2", "title": "b", "dependsOn": ["T-1"]}]})
        first = self.task_start("T-1")["T-1"]
        self.assertEqual(Path(first["worktree"], "cache", "state").read_text(), "fresh\n")
        commit(Path(first["worktree"]), "a.py", "a = 1\n")
        self.assertEqual(self.repo.ls("task", "done", "T-1")[0], 0)
        second = self.task_start("T-2")["T-2"]
        self.assertEqual(second["worktree"], first["worktree"])
        self.assertEqual(Path(second["worktree"], "cache", "state").read_text(), "reused\n")
        self.assertTrue(Path(second["worktree"], "a.py").is_file())
        self.assertEqual(sh(Path(second["worktree"]), "git", "branch", "--show-current"), second["branch"])

    def test_a_task_with_no_room_for_a_checkout_stays_ready(self):
        run = self.start()
        self.write(run, {"goal": "g", "criteria": [{"id": "AC-1", "text": "t"}]}, {"tasks": [{"id": "T-1", "title": "a"}]})
        state = Path(run["runDir"], "state.json")
        data = json.loads(state.read_text())
        data["checkoutBytes"] = 10**18
        state.write_text(json.dumps(data))
        code, out, _ = self.repo.ls("task", "start", "T-1")
        self.assertEqual(code, 0)
        self.assertIn("T-1: not started, needs about", out)
        self.assertEqual(sh(self.repo.path, "git", "branch", "--list", "loop-spec-task/*"), "")
        self.assertIn("ready", self.repo.ls("status")[1])

    def test_a_failed_checkout_leaves_nothing_behind(self):
        run = self.start()
        self.write(run, {"goal": "g", "criteria": [{"id": "AC-1", "text": "t"}]}, {"tasks": [{"id": "T-1", "title": "a"}]})

        def broken(repo, dest, ref, *, new_branch=None, detach=False):
            sh(repo, "git", "branch", new_branch)
            Path(dest).mkdir(parents=True)
            raise LoopSpecError("unable to write file")

        with mock.patch("loop_spec.git.add_worktree", side_effect=broken):
            code, out, _ = self.repo.ls("task", "start", "T-1")
        self.assertEqual(code, 0)
        self.assertIn("T-1: not started: unable to write file", out)
        self.assertFalse(Path(run["runDir"], "tasks", "slot-1").exists())
        self.assertEqual(sh(self.repo.path, "git", "branch", "--list", "loop-spec-task/*"), "")

    def test_the_host_environment_can_make_a_run_autonomous(self):
        self.start()
        with mock.patch.dict(os.environ, {"LOOP_SPEC_MODE": "autonomous"}):
            self.assertEqual(marker(self.repo.ls("status")[1], "LOOP_SPEC_RUN")["mode"], "autonomous")
        self.assertEqual(marker(self.repo.ls("status")[1], "LOOP_SPEC_RUN")["mode"], "interactive")

    def test_an_unusable_spec_is_named_and_verify_refuses_it(self):
        run = self.start()
        self.write(run, {"goal": "", "criteria": [{"id": "AC-1"}, {"id": "AC-1", "text": "t", "check": 3}]},
                   {"tasks": [{"id": "T-1", "title": "a"}]})
        out = self.repo.ls("status")[1]
        self.assertIn("is not usable: `goal` must be a one-sentence string; AC-1 has no `text`; AC-1: `check` must be "
                      "a command string, or left out when no command can show it; criterion id AC-1 is used more than once", out)
        self.assertRegex(out, r"next +fix \S+spec\.json: `goal`")
        self.assertEqual(marker(out, "LOOP_SPEC_RUN")["phase"], "spec")
        code, _, err = self.repo.ls("verify")
        self.assertEqual(code, 1)
        self.assertIn("spec.json is not usable", err)

    def test_a_plan_naming_an_unknown_criterion_is_refused_and_shared_files_are_warned(self):
        run = self.start()
        self.write(run, {"goal": "g", "criteria": [{"id": "AC-1", "text": "t"}]},
                   {"tasks": [{"id": "T-1", "title": "a", "criteria": ["AC-2"]}]})
        out = self.repo.ls("status")[1]
        self.assertIn("T-1 covers AC-2, which is not in spec.json (criteria: AC-1)", out)
        self.write(run, {"goal": "g", "criteria": [{"id": "AC-1", "text": "t"}]},
                   {"tasks": [{"id": "T-1", "title": "a", "files": ["calc.py"], "criteria": ["AC-1"]},
                              {"id": "T-2", "title": "b", "files": ["calc.py"]}]})
        self.assertIn("warning  T-1 and T-2 can run at once but both list calc.py", self.repo.ls("status")[1])

    def test_the_next_step_names_the_kind_reference_at_the_spec(self):
        _, out, _ = self.repo.ls("start", "--request", "Add mul")
        self.assertNotIn("(read ", out)
        _, out, _ = self.repo.ls("start", "--kind", "micro", "--request", "Rename mul")
        self.assertRegex(out, r"next .*spec\.json.* \(read \S+/references/micro\.md\)")
        references = Path(marker(out, "LOOP_SPEC_RUN")["references"])
        self.assertTrue(references.is_absolute() and (references / "micro.md").is_file())

    def test_finish_writes_the_result_and_removes_clean_worktrees(self):
        run = self.start()
        code, out, _ = self.repo.ls("finish", "--status", "no-change", "--summary", "already done")
        self.assertEqual(code, 0)
        result = marker(out, "LOOP_SPEC_RESULT")
        self.assertEqual((result["status"], result["outcome"], result["result"], result["summary"]),
                         ("completed", "no-change-needed", "no-change", "already done"))
        self.assertEqual(json.loads(Path(marker(out, "LOOP_SPEC_NEXT")["path"]).read_text()), result)
        self.assertFalse(Path(run["work"]).exists())


if __name__ == "__main__":
    unittest.main()
