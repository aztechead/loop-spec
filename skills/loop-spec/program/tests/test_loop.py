"""The delivery loop against real git repositories and a fake `gh`: a moved origin, the
run's own branch and title, repository checks compared at the base, CI and review
feedback rounds, and the Stop hook."""
import json
import os
import shutil
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
prev=""
for a in "$@"; do [ "$prev" = "--body-file" ] && cp "$a" "$FAKE_GH_DIR/body.txt"; prev="$a"; done  # what create and edit last wrote
case "$*" in "pr view "*"--json body"*) cat "$FAKE_GH_DIR/body.txt" 2>/dev/null; exit 0 ;; esac
case "$1 $2" in
  "auth status") [ -z "$FAKE_GH_NO_AUTH" ] || { echo "You are not logged into any GitHub hosts." >&2; exit 1; } ;;
  "pr list") echo "[]" ;;
  "pr create") echo "https://github.com/acme/kv/pull/7" ;;
  "pr checks") cat "$FAKE_GH_DIR/checks.json"; exit "$(cat "$FAKE_GH_DIR/checks.exit" 2>/dev/null || echo 0)" ;;
  "api repos/{owner}/{repo}/actions/jobs/7") echo "failure" ;;
  "api repos/{owner}/{repo}/actions/jobs/"*) printf '2026-10-04T16:19:37.1Z step 1 ok\\n2026-10-04T16:19:37.2Z AssertionError: boom\\n2026-10-04T16:19:37.3Z ##[error]Process completed with exit code 1.\\n2026-10-04T16:19:38Z Cleaning up orphan processes\\n' ;;
  "api user") echo "loop-bot" ;;
  "pr view") cat "$FAKE_GH_DIR/view.json" 2>/dev/null || echo '{"reviews": [], "comments": []}' ;;
  "api repos/{owner}/{repo}/pulls/7/comments") cat "$FAKE_GH_DIR/inline.jsonl" 2>/dev/null ;;
  "api repos/{owner}/{repo}/issues/7/comments") cat "$FAKE_GH_DIR/comments.jsonl" 2>/dev/null ;;
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
        Path(run["runDir"], "pr.md").write_text("## Why the change\n\nCallers need mul.\n")
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
        self.assertEqual(self.repo.ls("iterate")[0], 0)
        self.push_to_origin_main("teammate.py", "x = 1\n")
        code, _, err = self.repo.ls("deliver")
        self.assertEqual(code, 1)
        self.assertIn("origin/main has 1 commit the feature branch does not", err)

        code, out, _ = self.repo.ls("sync")
        self.assertIn("merged origin/main (1 commit)", out)
        self.assertTrue(Path(run["work"], "teammate.py").exists())
        self.assertEqual(marker(self.repo.ls("status")[1], "LOOP_SPEC_RUN")["phase"], "verify")
        self.assertEqual(self.repo.ls("verify")[0], 0)
        self.assertEqual(self.repo.ls("iterate")[0], 0)
        self.checks("pass")
        code, out, err = self.repo.ls("deliver")
        self.assertEqual(code, 0, err)
        self.assertIn("next: loop-spec feedback", out)

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
        self.assertEqual(self.repo.ls("iterate")[0], 0)
        self.checks("pass")
        self.assertEqual(self.repo.ls("deliver")[0], 0)
        self.assertEqual(run["slug"], "feat-kv-add-mul")  # the slug follows --title when no --slug is given
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

    # --- a revise run ----------------------------------------------------------------

    def test_a_revise_run_delivers_without_pr_md_and_does_not_report_the_review_it_started_from(self):
        sh(self.repo.path, "git", "push", "-q", "origin", "main:feat/mul")
        (self.gh_dir / "view.json").write_text(json.dumps({
            "number": 7, "url": "https://github.com/acme/kv/pull/7", "headRefName": "feat/mul", "baseRefName": "main",
            "state": "OPEN", "isCrossRepository": False, "reviews": []}))
        self.comments({"id": "C1", "author": "ana", "body": "Please add mul."})
        code, out, err = self.repo.ls("start", "--pr", "7")
        self.assertEqual(code, 0, err)
        run = marker(out, "LOOP_SPEC_RUN")
        self.assertIn("review so far, 1 item(s)", out)
        self.assertIn("Please add mul.", out)  # listed once, at the start
        Path(run["runDir"], "spec.json").write_text(json.dumps(
            {"title": "t", "goal": "g", "criteria": [{"id": "AC-1", "text": "t", "check": "true"}]}))
        Path(run["runDir"], "plan.json").write_text(json.dumps({"tasks": [{"id": "T-1", "title": "a"}]}))
        self.repo.ls("task", "start", "T-1")
        commit(Path(run["runDir"], "tasks", "T-1"), "mul.py", "def mul(a, b):\n    return a * b\n")
        self.assertEqual(self.repo.ls("task", "done", "T-1")[0], 0)
        self.checks("pass")
        self.deliver(run)  # no pr.md: the PR keeps its own description, and only the verification section is folded in
        calls = (self.gh_dir / "calls").read_text()
        self.assertIn("pr edit 7 --body-file", calls)
        self.assertNotIn("--title", calls)
        code, out, _ = self.repo.ls("feedback")
        self.assertNotIn("Please add mul.", out)
        self.assertEqual(marker(out, "LOOP_SPEC_RESULT")["status"], "completed")

    # --- CI and review feedback ------------------------------------------------------

    def deliver(self, run: dict) -> None:
        self.assertEqual(self.repo.ls("verify")[0], 0)
        self.assertEqual(self.repo.ls("iterate")[0], 0)
        self.assertEqual(self.repo.ls("deliver")[0], 0)

    def comments(self, *items: dict) -> None:
        """Conversation comments as `gh api issues/7/comments` shows them after the program's jq filter."""
        (self.gh_dir / "comments.jsonl").write_text("".join(json.dumps({"at": "2026-10-04T10:00:00Z", **c}) + "\n" for c in items))

    def review(self, reviews=(), comments=(), inline=()) -> None:
        (self.gh_dir / "view.json").write_text(json.dumps({"reviews": list(reviews)}))
        self.comments(*comments)
        (self.gh_dir / "inline.jsonl").write_text("".join(json.dumps(c) + "\n" for c in inline))

    def test_passing_ci_and_a_quiet_review_end_the_run_completed(self):
        run = self.ready_run()
        self.deliver(run)
        self.checks("pass", "skipping")
        self.review(reviews=[{"id": "R1", "author": {"login": "ana"}, "state": "APPROVED", "body": ""}],
                    comments=[{"id": "C0", "author": "loop-bot", "body": "our own note\n\n<!-- loop-spec -->"}])
        code, out, _ = self.repo.ls("feedback")
        result = marker(out, "LOOP_SPEC_RESULT")
        target = result["delivery"]["targets"][0]
        self.assertEqual((code, result["status"], result["outcome"], target["ci"], target["reviews"]),
                         (0, "completed", "delivered", "passed", {"ana": "APPROVED"}))

    def test_failing_ci_has_no_round_limit(self):
        run = self.ready_run()
        (Path(run["work"]) / ".github" / "workflows").mkdir(parents=True)
        for round_ in range(1, 6):
            commit(Path(run["work"]), f"fix{round_}.txt", "x\n")
            self.deliver(run)
            self.checks("pass", "fail", exit_code=1)
            code, out, _ = self.repo.ls("feedback")
            self.assertEqual(code, 1)
            self.assertIn("AssertionError: boom", out)
            self.assertIn("CI FAILED", out)
            self.assertNotIn("LOOP_SPEC_RESULT", out)
        self.assertNotIn("pr ready", (self.gh_dir / "calls").read_text())

    def test_a_failed_check_is_reported_without_waiting_for_slower_ones(self):
        run = self.ready_run()
        (Path(run["work"]) / ".github" / "workflows").mkdir(parents=True)
        self.deliver(run)
        self.checks("fail", "pending", exit_code=1)
        code, out, _ = self.repo.ls("feedback", "--timeout", "600")
        self.assertEqual(code, 1)
        self.assertIn("CI FAILED", out)
        self.assertRegex(out, r"\n +AssertionError: boom\n +##\[error\]Process completed")  # cut at the error, stamps gone
        self.assertNotIn("orphan", out)

    def test_a_check_github_leaves_pending_after_its_job_failed_counts_as_failed(self):
        run = self.ready_run()
        self.deliver(run)
        rows = [{"name": "lint", "bucket": "pass", "link": "https://github.com/acme/kv/actions/runs/9/job/1"},
                {"name": "policy", "bucket": "pending", "startedAt": "2026-01-01T00:00:00Z",
                 "link": "https://github.com/acme/kv/actions/runs/9/job/7"}]
        (self.gh_dir / "checks.json").write_text(json.dumps(rows))
        code, out, _ = self.repo.ls("feedback", "--timeout", "0")
        self.assertEqual(code, 1)
        self.assertIn("CI FAILED", out)

    def test_review_comments_are_reported_once_then_the_run_can_end(self):
        run = self.ready_run()
        self.deliver(run)
        self.checks("pass")
        self.review(reviews=[{"id": "R1", "author": {"login": "ana"}, "state": "CHANGES_REQUESTED",
                              "body": "Please rename mul to multiply."}],
                    comments=[{"id": "C1", "author": "loop-bot", "body": "Why int, not float?"}],
                    inline=[{"id": 11, "author": "coderabbit[bot]", "body": "Missing test for 0.",
                             "path": "mul.py", "line": 2, "url": "https://github.com/acme/kv/pull/7#r11"}])
        code, out, _ = self.repo.ls("feedback")
        self.assertEqual(code, 1)
        self.assertIn("comment by loop-bot", out)  # the run's own gh account, not its own reply
        self.assertIn("review (changes_requested) by ana", out)
        self.assertIn("Please rename mul to multiply.", out)
        self.assertIn("inline comment by coderabbit[bot] on mul.py:2", out)
        self.assertIn("3 new review item(s)", out)
        commit(Path(run["work"]), "mul.py", "def multiply(a, b):\n    return a * b\n")
        self.deliver(run)
        calls = (self.gh_dir / "calls").read_text()
        self.assertIn("--add-reviewer ana", calls)  # asked to look again
        self.assertIn("--add-reviewer coderabbit[bot]", calls)
        code, out, _ = self.repo.ls("feedback")
        self.assertEqual(marker(out, "LOOP_SPEC_RESULT")["delivery"]["targets"][0]["reviews"], {"ana": "CHANGES_REQUESTED"})

    def test_a_requested_review_keeps_the_run_open_until_it_is_in_or_the_wait_runs_out(self):
        run = self.ready_run()
        self.deliver(run)
        self.checks("pass")
        (self.gh_dir / "view.json").write_text(json.dumps({"reviews": [], "comments": [],
                                                           "reviewRequests": [{"login": "ana"}]}))
        code, out, _ = self.repo.ls("feedback", "--timeout", "0")
        self.assertEqual(code, 0)
        self.assertIn("review requested from ana is not in yet", out)
        self.assertNotIn("LOOP_SPEC_RESULT", out)
        (self.repo.path / ".loop-spec" / "config.json").write_text(json.dumps({"feedback": {"reviewWaitMinutes": 0}}))
        code, out, _ = self.repo.ls("feedback", "--timeout", "0")
        self.assertIn("still not in after 0 min", out)
        self.assertEqual(marker(out, "LOOP_SPEC_RESULT")["status"], "completed")

    def test_feedback_skills_keep_the_run_open_for_the_lead(self):
        (self.repo.path / ".loop-spec").mkdir(exist_ok=True)
        (self.repo.path / ".loop-spec" / "config.json").write_text(json.dumps({"feedback": {"skills": ["acme:pr-review"]}}))
        run = self.ready_run()
        self.deliver(run)
        self.checks("pass")
        code, out, _ = self.repo.ls("feedback")
        self.assertEqual(code, 0)
        self.assertIn("acme:pr-review", out)
        self.assertNotIn("LOOP_SPEC_RESULT", out)

    def test_ci_waits_for_pending_checks_and_returns_at_its_timeout(self):
        sleeps = []
        clock = iter([0, 0, 20, 40, 60]).__next__
        self.checks("pending")
        outcome, _ = ci.wait(self.repo.path, 7, timeout=30, sleep=sleeps.append, clock=clock)
        self.assertEqual((outcome, len(sleeps)), ("pending", 2))

    # --- the PR description ---------------------------------------------------------------

    def test_deliver_needs_pr_md_and_names_the_template_to_follow(self):
        run = self.ready_run()
        Path(run["runDir"], "pr.md").unlink()
        self.assertIn("pr.md    not written yet; follows ", self.repo.ls("status")[1])
        self.assertEqual(self.repo.ls("verify")[0], 0)
        self.assertEqual(self.repo.ls("iterate")[0], 0)
        code, _, err = self.repo.ls("deliver")
        self.assertEqual(code, 1)
        self.assertIn("references/visual-pr/pr_description_template.md", err)

    def test_at_deliver_the_next_step_names_the_template_until_pr_md_is_written(self):
        run = self.ready_run()
        Path(run["runDir"], "pr.md").unlink()
        self.repo.ls("verify")
        out = self.repo.ls("iterate")[1]
        self.assertRegex(out, r"next: loop-spec deliver \(read \S+/visual-pr/pr_description_template\.md\)")
        Path(run["runDir"], "pr.md").write_text("## Why the change\n\nmul.\n")
        self.assertNotRegex(self.repo.ls("status")[1], r"next .*pr_description_template")

    def test_deliver_refuses_template_placeholders_left_in_pr_md(self):
        run = self.ready_run()
        Path(run["runDir"], "pr.md").write_text(
            "## Why the change\n\nmul.\n\n## Special things to note\n\n- {List 1-3 reviewer-relevant warnings, migrations, "
            "constraints, deliberate omissions, or surprising decisions. Use \"None.\" when there are no special considerations.}\n")
        self.repo.ls("verify")
        self.repo.ls("iterate")
        code, _, err = self.repo.ls("deliver")
        self.assertEqual(code, 1)
        self.assertIn("pr.md still has 1 line(s) of the template's placeholders, such as: - {List 1-3", err)

    def test_deliver_checks_gh_before_it_pushes(self):
        run = self.ready_run()
        self.repo.ls("verify")
        self.repo.ls("iterate")
        with mock.patch.dict(os.environ, {"FAKE_GH_NO_AUTH": "1"}):
            code, _, err = self.repo.ls("deliver")
        self.assertEqual(code, 1)
        self.assertIn("gh cannot open the PR: You are not logged into any GitHub hosts.", err)
        self.assertEqual(sh(self.repo.path, "git", "ls-remote", "--heads", "origin", "feat/add-mul"), "")

    def test_the_repositorys_own_pr_template_wins(self):
        run = self.ready_run()
        template = Path(run["work"], ".github", "pull_request_template.md")
        template.parent.mkdir(parents=True)
        template.write_text("## Ticket\n")
        self.assertIn("follows .loop-spec/runs/add-mul/work/.github/pull_request_template.md", self.repo.ls("status")[1])

    # --- branch and title from the repository's rules -------------------------------------

    def test_set_renames_the_branch_until_it_is_pushed(self):
        run = self.ready_run()
        self.assertIn("branch is now feature/KV-9", self.repo.ls("set", "--branch", "feature/KV-9", "--title", "feat(kv): mul")[1])
        self.assertEqual(sh(run["work"], "git", "branch", "--show-current"), "feature/KV-9")
        self.deliver(run)
        self.assertIn("--head feature/KV-9 --title feat(kv): mul", (self.gh_dir / "calls").read_text())
        code, _, err = self.repo.ls("set", "--branch", "feature/other")
        self.assertEqual(code, 1)
        self.assertIn("already pushed", err)

    # --- a branch someone else already has -------------------------------------------------

    def teammate_pushes_branch(self, branch: str) -> None:
        other = Path(self._tmp.name) / "other"
        sh(self._tmp.name, "git", "clone", "-q", str(self.repo.origin), str(other))
        for key, value in (("user.email", "o@example.com"), ("user.name", "o"), ("commit.gpgsign", "false")):
            sh(other, "git", "config", key, value)
        sh(other, "git", "checkout", "-q", "-b", branch)
        commit(other, "theirs.py", "x = 1\n")
        sh(other, "git", "push", "-q", "origin", branch)

    def test_a_branch_origin_already_has_is_taken_and_the_run_gets_the_next_name(self):
        self.teammate_pushes_branch("feat/add-mul")
        run = marker(self.repo.ls("start", "--request", "Add mul")[1], "LOOP_SPEC_RUN")
        self.assertEqual(sh(run["work"], "git", "branch", "--show-current"), "feat/add-mul-2")

    def test_deliver_refuses_a_branch_origin_has_other_commits_on_when_the_run_has_no_pr(self):
        self.ready_run()
        self.assertEqual(self.repo.ls("verify")[0], 0)
        self.assertEqual(self.repo.ls("iterate")[0], 0)
        self.teammate_pushes_branch("feat/add-mul")
        code, _, err = self.repo.ls("deliver")
        self.assertEqual(code, 1)
        self.assertIn("belongs to other work", err)

    # --- redelivery keeps what the PR's people wrote ---------------------------------------

    def test_a_redeliver_replaces_only_the_verification_section_and_never_the_title(self):
        run = self.ready_run()
        self.deliver(run)
        body = self.gh_dir / "body.txt"
        body.write_text("HOST NOTE\n\n" + body.read_text() + "\nFOOTER\n")  # edited on GitHub
        commit(Path(run["work"]), "more.py", "x = 1\n")
        self.deliver(run)
        text = body.read_text()
        self.assertIn("HOST NOTE", text)
        self.assertIn("FOOTER", text)
        self.assertIn("Callers need mul.", text)
        self.assertEqual(text.count("<!-- loop-spec:verification -->"), 1)
        self.assertIn(sh(run["work"], "git", "rev-parse", "HEAD")[:12], text)
        edits = [c for c in (self.gh_dir / "calls").read_text().splitlines() if c.startswith("pr edit 7 --body-file")]
        self.assertEqual(len(edits), 1)  # the first deliver created the PR
        self.assertNotIn("--title", " ".join(edits))

    # --- review items ----------------------------------------------------------------------

    def test_an_edited_conversation_comment_comes_back_as_a_new_item(self):
        run = self.ready_run()
        self.deliver(run)
        self.checks("pass")
        self.comments({"id": 5, "author": "coderabbit[bot]", "body": "Summary v1"})
        self.assertIn("1 new review item(s)", self.repo.ls("feedback")[1])
        self.comments({"id": 5, "author": "coderabbit[bot]", "body": "Summary v2", "at": "2026-10-04T11:00:00Z"})
        code, out, _ = self.repo.ls("feedback")
        self.assertEqual(code, 1)
        self.assertIn("Summary v2", out)

    def test_a_waited_for_login_keeps_the_run_open_until_it_posts_after_the_delivery(self):
        (self.repo.path / ".loop-spec").mkdir(exist_ok=True)
        (self.repo.path / ".loop-spec" / "config.json").write_text(json.dumps({"feedback": {"waitFor": ["coderabbit"]}}))
        run = self.ready_run()
        self.deliver(run)
        self.checks("pass")
        code, out, _ = self.repo.ls("feedback", "--timeout", "0")
        self.assertEqual(code, 0)
        self.assertIn("review requested from coderabbit is not in yet", out)
        self.assertNotIn("LOOP_SPEC_RESULT", out)
        self.comments({"id": 6, "author": "coderabbit[bot]", "body": "Looks fine.", "at": "2999-01-01T00:00:00Z"})
        out = self.repo.ls("feedback", "--timeout", "0")[1]
        self.assertIn("Looks fine.", out)
        self.assertNotIn("is not in yet", out)

    # --- the result ------------------------------------------------------------------------

    def test_the_result_carries_assumptions_decisions_criteria_and_caveats(self):
        run = self.ready_run()
        Path(run["runDir"], "spec.json").write_text(json.dumps(
            {"title": "t", "goal": "g", "assumptions": ["a1"], "decisions": ["d1"],
             "criteria": [{"id": "AC-1", "text": "t", "check": "true"}]}))
        self.assertEqual(self.repo.ls("verify")[0], 0)
        self.assertEqual(self.repo.ls("iterate", "--caveats", "slow on big inputs")[0], 0)
        result = marker(self.repo.ls("finish", "--status", "escalated", "--summary", "s")[1], "LOOP_SPEC_RESULT")
        self.assertEqual((result["assumptions"], result["decisions"], result["caveats"]),
                         (["a1"], ["d1"], ["slow on big inputs"]))
        self.assertEqual(result["criteria"], [{"id": "AC-1", "passed": True, "checked": True}])
        self.assertEqual(result["criteriaSha"], sh(self.repo.path, "git", "rev-parse", "feat/add-mul"))

    # --- pause, resume, checkpoint ---------------------------------------------------------

    def started_task(self) -> dict:
        run = marker(self.repo.ls("start", "--request", "Add mul")[1], "LOOP_SPEC_RUN")
        Path(run["runDir"], "spec.json").write_text(json.dumps(
            {"title": "t", "goal": "g", "criteria": [{"id": "AC-1", "text": "t", "check": "true"}]}))
        Path(run["runDir"], "plan.json").write_text(json.dumps({"tasks": [{"id": "T-1", "title": "a"}]}))
        self.assertEqual(self.repo.ls("task", "start", "T-1")[0], 0)
        return run

    def test_status_rebuilds_a_lost_work_worktree(self):
        run = self.started_task()
        shutil.rmtree(run["work"])
        out = self.repo.ls("status")[1]
        self.assertIn("restored work from feat/add-mul", out)
        self.assertEqual(sh(run["work"], "git", "branch", "--show-current"), "feat/add-mul")

    def test_status_resets_a_doing_task_whose_branch_is_gone(self):
        run = self.started_task()
        shutil.rmtree(Path(run["runDir"], "tasks", "T-1"))
        sh(self.repo.path, "git", "worktree", "prune")
        sh(self.repo.path, "git", "branch", "-D", "loop-spec-task/add-mul/T-1")
        out = self.repo.ls("status")[1]
        self.assertIn("T-1: worktree lost and its branch is gone; back to todo", out)
        self.assertIn("(worktree lost; start it again)", out)

    def test_checkpoint_commits_a_dirty_task_worktree_and_push_lands_its_branch(self):
        run = self.started_task()
        task_dir = Path(run["runDir"], "tasks", "T-1")
        (task_dir / "half.py").write_text("x = 1\n")
        code, out, _ = self.repo.ls("checkpoint", "--push")
        self.assertEqual(code, 0)
        self.assertRegex(out, r"tasks/T-1 loop-spec-task/add-mul/T-1 [0-9a-f]{12} committed")
        self.assertIn("feat/add-mul", out)
        self.assertEqual(sh(task_dir, "git", "log", "-1", "--format=%s"), "wip: loop-spec checkpoint, not verified")
        self.assertIn("refs/heads/loop-spec-task/add-mul/T-1", sh(self.repo.path, "git", "ls-remote", "--heads", "origin"))

    def test_task_done_removes_the_task_branch_a_checkpoint_pushed(self):
        run = self.started_task()
        (Path(run["runDir"], "tasks", "T-1") / "half.py").write_text("x = 1\n")
        self.repo.ls("checkpoint", "--push")
        self.assertEqual(self.repo.ls("task", "done", "T-1")[0], 0)
        self.assertNotIn("loop-spec-task", sh(self.repo.path, "git", "ls-remote", "--heads", "origin"))

    def test_a_host_stop_request_puts_the_wrap_up_in_the_hook_reason_and_the_next_line(self):
        run = self.ready_run("--autonomous")
        Path(run["runDir"], "stop-requested").write_text("")
        reason = self.hook()["reason"]
        self.assertIn("the host asked this run to wrap up", reason)
        self.assertIn("loop-spec checkpoint --push", reason)
        self.assertNotIn(hook.WAITING, reason)
        self.assertRegex(self.repo.ls("status")[1], r"next +the host asked this run to wrap up")
        self.assertIn("next: the host asked this run to wrap up", self.repo.ls("verify")[1])  # mid-turn too

    # --- the Stop hook ----------------------------------------------------------------

    def hook(self, last_message: str = "Done for now.") -> dict | None:
        return hook.decide({"cwd": str(self.repo.path), "last_assistant_message": last_message}, cli._next_step)

    def test_an_open_autonomous_run_blocks_the_stop_with_its_next_step(self):
        self.ready_run("--autonomous")
        answer = self.hook()
        self.assertEqual(answer["decision"], "block")
        self.assertIn("phase verify", answer["reason"])
        self.assertIsNone(self.hook("Three implementers are running. LOOP_SPEC_WAITING"))

    def test_a_supervised_run_may_stop_to_ask_and_is_blocked_otherwise(self):
        self.ready_run("--supervised")
        self.assertEqual(self.hook("Done for now.")["decision"], "block")
        self.assertIsNone(self.hook("Which one do you want? LOOP_SPEC_ASKING"))

    def test_an_interactive_or_finished_run_lets_the_stop_through(self):
        self.ready_run()
        self.assertIsNone(self.hook())
        with mock.patch.dict(os.environ, {"LOOP_SPEC_MODE": "autonomous"}):
            self.assertIsNotNone(self.hook())
            self.repo.ls("finish", "--status", "no-change", "--summary", "s")
            self.assertIsNone(self.hook())

    def test_a_stalled_run_keeps_going_with_no_cap_and_names_the_stall(self):
        self.ready_run("--autonomous")
        answers = [self.hook() for _ in range(60)]
        self.assertTrue(all(a and a["decision"] == "block" for a in answers))
        self.assertNotIn("has not changed", answers[2]["reason"])
        self.assertIn("has not changed in 3 turns", answers[3]["reason"])
        self.assertIn("has not changed in 59 turns", answers[59]["reason"])

    def test_the_hook_command_is_silent_outside_a_repository(self):
        proc = subprocess.run([str(Path(cli.__file__).parents[1] / "loop-spec"), "hook-stop"], input='{"cwd": "/"}',
                              capture_output=True, text=True, cwd="/")
        self.assertEqual((proc.returncode, proc.stdout, proc.stderr), (0, "", ""))


if __name__ == "__main__":
    unittest.main()
