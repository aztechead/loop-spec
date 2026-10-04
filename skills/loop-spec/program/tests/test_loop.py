"""The delivery loop against real git repositories and a fake `gh`: a moved origin, the
run's own title, repository checks compared at the base, CI rounds, and the Stop hook."""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from loop_spec import ci, cli, hook
from loop_spec.runs import Run
from test_flow import Repo, commit, marker, sh

FAKE_GH = """#!/usr/bin/env bash
# A stand-in for gh: answers the few calls loop-spec makes from files in $FAKE_GH_DIR.
echo "$*" >> "$FAKE_GH_DIR/calls"
case "$1 $2" in
  "pr list") echo "[]" ;;
  "pr create") echo "https://github.com/acme/kv/pull/7" ;;
  "pr checks") cat "$FAKE_GH_DIR/checks.json"; exit "$(cat "$FAKE_GH_DIR/checks.exit" 2>/dev/null || echo 0)" ;;
  "run view") printf 'step 1 ok\\nAssertionError: boom\\n' ;;
  *) ;;
esac
"""


class LoopTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        self.repo = Repo(root)
        self.gh_dir = root / "gh"
        self.gh_dir.mkdir()
        (self.gh_dir / "gh").write_text(FAKE_GH)
        (self.gh_dir / "gh").chmod(0o755)
        env = {"PATH": f"{self.gh_dir}:{os.environ['PATH']}", "FAKE_GH_DIR": str(self.gh_dir)}
        self._env = mock.patch.dict(os.environ, env)
        self._env.start()

    def tearDown(self):
        self._env.stop()
        self._tmp.cleanup()

    def checks(self, *buckets: str, exit_code: int = 0) -> None:
        rows = [{"name": f"job{i}", "bucket": b, "link": f"https://github.com/acme/kv/actions/runs/9/job/{i}"}
                for i, b in enumerate(buckets)]
        (self.gh_dir / "checks.json").write_text(json.dumps(rows))
        (self.gh_dir / "checks.exit").write_text(str(exit_code))

    def ready_run(self, *start_args: str, checks=None) -> dict:
        code, out, err = self.repo.ls("start", "--request", "Add mul", *start_args)
        self.assertEqual(code, 0, err)
        run = marker(out, "LOOP_SPEC_RUN")
        Path(run["runDir"], "spec.json").write_text(json.dumps(
            {"title": "feat: spec title", "goal": "g", "criteria": [{"id": "AC-1", "text": "t", "check": "true"}]}))
        plan = {"tasks": [{"id": "T-1", "title": "a"}]}
        if checks is not None:
            plan["checks"] = checks
        Path(run["runDir"], "plan.json").write_text(json.dumps(plan))
        self.repo.ls("task", "start", "T-1")
        commit(Path(run["runDir"], "tasks", "T-1"), "mul.py", "def mul(a, b):\n    return a * b\n")
        self.assertEqual(self.repo.ls("task", "done", "T-1")[0], 0)
        return run

    def push_to_origin_main(self, name: str, text: str) -> None:
        other = Path(self._tmp.name) / "teammate"
        if not other.exists():
            sh(self._tmp.name, "git", "clone", "-q", str(self.repo.origin), str(other))
            sh(other, "git", "config", "user.email", "m@example.com")
            sh(other, "git", "config", "user.name", "m")
        sh(other, "git", "pull", "-q")
        commit(other, name, text)
        sh(other, "git", "push", "-q", "origin", "main")

    # --- a moved origin -------------------------------------------------------------

    def test_deliver_refuses_a_moved_base_until_it_is_synced_and_verified(self):
        run = self.ready_run()
        self.assertEqual(self.repo.ls("verify")[0], 0)
        self.push_to_origin_main("teammate.py", "x = 1\n")
        code, _, err = self.repo.ls("deliver")
        self.assertEqual(code, 1)
        self.assertIn("origin/main has 1 commit the feature branch does not", err)

        code, out, _ = self.repo.ls("sync")
        self.assertIn("merged origin/main (1 commit)", out)
        self.assertTrue(Path(run["work"], "teammate.py").exists())
        self.assertEqual(marker(self.repo.ls("status")[1], "LOOP_SPEC_RUN")["phase"], "verify")
        self.assertEqual(self.repo.ls("verify")[0], 0)
        self.checks("pass")
        code, out, err = self.repo.ls("deliver")
        self.assertEqual(code, 0, err)
        self.assertIn("next: loop-spec ci", out)

    def test_a_conflicting_base_is_left_for_the_lead_and_synced_after(self):
        run = self.ready_run()
        commit(Path(run["work"]), "calc.py", "ours\n")
        self.push_to_origin_main("calc.py", "theirs\n")
        code, _, err = self.repo.ls("sync")
        self.assertEqual(code, 1)
        self.assertIn("merging origin/main conflicts in: calc.py", err)
        Path(run["work"], "calc.py").write_text("ours and theirs\n")
        sh(run["work"], "git", "commit", "-qam", "resolve")
        self.assertIn("nothing moved on origin", self.repo.ls("sync")[1])
        state = json.loads(Path(run["runDir"], "state.json").read_text())
        self.assertEqual(state["base"]["sha"], sh(self.repo.path, "git", "rev-parse", "origin/main"))

    # --- the run's own title ----------------------------------------------------------

    def test_the_runs_title_and_branch_win_over_the_spec(self):
        run = self.ready_run("--title", "feat(kv): add mul", "--branch", "feature/KV-12")
        self.assertEqual(self.repo.ls("verify")[0], 0)
        self.checks("pass")
        self.assertEqual(self.repo.ls("deliver")[0], 0)
        calls = (self.gh_dir / "calls").read_text()
        self.assertIn("--title feat(kv): add mul", calls)
        self.assertIn("--head feature/KV-12", calls)
        self.assertEqual(sh(self.repo.path, "git", "ls-remote", "--heads", "origin", "feature/KV-12").split()[1],
                         "refs/heads/feature/KV-12")

    # --- repository checks ------------------------------------------------------------

    def test_a_check_failing_the_same_way_at_base_is_pre_existing(self):
        run = self.ready_run(checks=[{"command": "echo legacy warning; exit 3", "source": "CLAUDE.md"}])
        code, out, _ = self.repo.ls("verify")
        self.assertEqual(code, 0, out)
        self.assertIn("pre-existing, not counted", out)

    def test_a_check_the_change_broke_fails_verify(self):
        self.ready_run(checks=["test ! -f mul.py"])
        code, out, _ = self.repo.ls("verify")
        self.assertEqual(code, 1)
        self.assertIn("passes at the base: this change made it fail", out)

    def test_a_check_failing_at_base_with_new_output_fails_verify(self):
        self.ready_run(checks=["echo 'calc.py: W1 legacy'; test ! -f mul.py || echo 'mul.py: E501 line too long'; exit 1"])
        code, out, _ = self.repo.ls("verify")
        self.assertEqual(code, 1)
        self.assertIn("these lines are new:\n        mul.py: E501 line too long", out)

    def test_status_names_the_rules_files_and_a_missing_checks_list(self):
        (self.repo.path / "CLAUDE.md").write_text("Run `make lint`.\n")
        sh(self.repo.path, "git", "add", "CLAUDE.md")
        sh(self.repo.path, "git", "commit", "-qm", "docs: rules")
        sh(self.repo.path, "git", "push", "-q", "origin", "main")
        self.ready_run()
        out = self.repo.ls("status")[1]
        self.assertIn("rules    CLAUDE.md", out)
        self.assertIn("plan.json has no `checks`", out)

    # --- CI ---------------------------------------------------------------------------

    def deliver(self, run: dict) -> None:
        self.assertEqual(self.repo.ls("verify")[0], 0)
        self.assertEqual(self.repo.ls("deliver")[0], 0)

    def test_passing_ci_ends_the_run_completed(self):
        run = self.ready_run()
        self.deliver(run)
        self.checks("pass", "skipping")
        code, out, _ = self.repo.ls("ci")
        result = marker(out, "LOOP_SPEC_RESULT")
        self.assertEqual((code, result["status"], result["ci"], result["prUrl"]),
                         (0, "completed", "passed", "https://github.com/acme/kv/pull/7"))

    def test_failing_ci_shows_the_log_then_drafts_the_pr_after_the_last_round(self):
        run = self.ready_run()
        (Path(run["work"]) / ".github" / "workflows").mkdir(parents=True)
        for round_ in range(1, 4):
            commit(Path(run["work"]), f"fix{round_}.txt", "x\n")
            self.deliver(run)
            self.checks("pass", "fail", exit_code=1)
            code, out, _ = self.repo.ls("ci")
            self.assertIn("AssertionError: boom", out)
            if round_ < 3:
                self.assertEqual(code, 1)
                self.assertIn(f"CI FAILED (round {round_} of 3)", out)
        result = marker(out, "LOOP_SPEC_RESULT")
        self.assertEqual(result["status"], "escalated")
        self.assertIn("pr ready 7 --undo", (self.gh_dir / "calls").read_text())

    def test_ci_waits_for_pending_checks_and_returns_at_its_timeout(self):
        sleeps = []
        clock = iter([0, 0, 20, 40, 60]).__next__
        self.checks("pending")
        outcome, _ = ci.wait(self.repo.path, 7, timeout=30, sleep=sleeps.append, clock=clock)
        self.assertEqual((outcome, len(sleeps)), ("pending", 2))

    # --- the Stop hook ----------------------------------------------------------------

    def hook(self, last_message: str = "Done for now.") -> dict | None:
        return hook.decide({"cwd": str(self.repo.path), "last_assistant_message": last_message}, cli._next_step)

    def test_an_open_autonomous_run_blocks_the_stop_with_its_next_step(self):
        self.ready_run("--autonomous")
        answer = self.hook()
        self.assertEqual(answer["decision"], "block")
        self.assertIn("phase verify", answer["reason"])
        self.assertIsNone(self.hook("Three implementers are running. LOOP_SPEC_WAITING"))

    def test_an_interactive_or_finished_run_lets_the_stop_through(self):
        self.ready_run()
        self.assertIsNone(self.hook())
        with mock.patch.dict(os.environ, {"LOOP_SPEC_MODE": "autonomous"}):
            self.assertIsNotNone(self.hook())
            self.repo.ls("finish", "--status", "no-change", "--summary", "s")
            self.assertIsNone(self.hook())

    def test_no_progress_asks_once_to_escalate_then_lets_go(self):
        self.ready_run("--autonomous")
        answers = [self.hook() for _ in range(5)]
        self.assertTrue(all(a and a["decision"] == "block" for a in answers[:4]))
        self.assertIn("has not moved in 3 continuations", answers[3]["reason"])
        self.assertIsNone(answers[4])

    def test_the_hook_command_is_silent_outside_a_repository(self):
        proc = subprocess.run([str(Path(cli.__file__).parents[1] / "loop-spec"), "hook-stop"], input='{"cwd": "/"}',
                              capture_output=True, text=True, cwd="/")
        self.assertEqual((proc.returncode, proc.stdout, proc.stderr), (0, "", ""))


if __name__ == "__main__":
    unittest.main()
