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
from unittest import mock

from loop_spec import cli


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
        self.assertIn("review of", self.repo.ls("iterate")[1])
        self.assertEqual(marker(self.repo.ls("status")[1], "LOOP_SPEC_RUN")["phase"], "deliver")

    def test_verify_at_base_shows_a_failure_without_recording_it(self):
        run = self.start("--kind", "debug")
        self.write(run, {"goal": "g", "criteria": [{"id": "AC-1", "text": "mul", "check": "python3 -c 'import calc; calc.mul'"}]},
                   {"tasks": [{"id": "T-1", "title": "fix"}]})
        code, out, _ = self.repo.ls("verify", "--base")
        self.assertEqual(code, 1)
        self.assertIn("not recorded", out)
        self.assertNotIn("verify", json.loads(Path(run["runDir"], "state.json").read_text()))

    def test_a_conflicting_task_is_refused_and_left_for_the_lead(self):
        run = self.start()
        self.write(run, {"goal": "g", "criteria": []}, {"tasks": [{"id": "T-1", "title": "a"}, {"id": "T-2", "title": "b"}]})
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
        self.write(run, {"goal": "g", "criteria": []}, {"tasks": [{"id": "T-1", "title": "a"}]})
        commit(Path(run["work"]), "mul.py", "x = 1\n")
        code, out, _ = self.repo.ls("task", "done", "T-1")
        self.assertEqual(code, 0)
        self.assertIn("T-1 done in work", out)
        self.assertIn("next: loop-spec verify", out)

    def test_a_cyclic_plan_is_reported_with_its_cycle(self):
        run = self.start()
        self.write(run, {"goal": "g", "criteria": []},
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

    def test_the_host_environment_can_make_a_run_autonomous(self):
        self.start()
        with mock.patch.dict(os.environ, {"LOOP_SPEC_MODE": "autonomous"}):
            self.assertEqual(marker(self.repo.ls("status")[1], "LOOP_SPEC_RUN")["mode"], "autonomous")
        self.assertEqual(marker(self.repo.ls("status")[1], "LOOP_SPEC_RUN")["mode"], "interactive")

    def test_finish_writes_the_result_and_removes_clean_worktrees(self):
        run = self.start()
        code, out, _ = self.repo.ls("finish", "--status", "no-change", "--summary", "already done")
        self.assertEqual(code, 0)
        result = marker(out, "LOOP_SPEC_RESULT")
        self.assertEqual((result["status"], result["summary"]), ("no-change", "already done"))
        self.assertEqual(json.loads(Path(result["path"]).read_text())["status"], "no-change")
        self.assertFalse(Path(run["work"]).exists())


if __name__ == "__main__":
    unittest.main()
