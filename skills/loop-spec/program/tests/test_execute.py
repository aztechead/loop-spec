"""Unit tests for loop_spec.execute: dag_waves and the EXECUTE state machine."""
import subprocess
import tempfile
import unittest
from pathlib import Path

from loop_spec import repo as repo_module
from loop_spec.baseline import BaselineEntry, run_command
from loop_spec.errors import LoopSpecError
from loop_spec.execute import IssueStep, Pause, Product, dag_waves, on_submit, step
from loop_spec.paths import FeaturePaths
from loop_spec.postconditions import retry_limit
from loop_spec.state import StateStore


# simplicity: _git/_init_repo repeat test_repo.py's and test_baseline.py's own
# copies verbatim; there is no shared test-fixture module in this tree yet, and
# adding one is a cross-file change outside this file's own scope.
def _git(cwd, *args):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True)


def _init_repo(cwd):
    _git(cwd, "init", "-q", "-b", "main")
    _git(cwd, "config", "user.name", "Test")
    _git(cwd, "config", "user.email", "test@example.com")
    Path(cwd, "verify.sh").write_text("#!/bin/sh\nexit 0\n")
    _git(cwd, "add", "verify.sh")
    _git(cwd, "commit", "-q", "-m", "init")


def _commit(cwd, filename, message):
    Path(cwd, filename).write_text(f"{filename}\n")
    _git(cwd, "add", filename)
    _git(cwd, "commit", "-q", "-m", message)


def _head(cwd):
    return subprocess.run(["git", "rev-parse", "HEAD"], cwd=cwd, capture_output=True, text=True, check=True).stdout.strip()


class DagWavesTests(unittest.TestCase):
    def test_diamond(self):
        tasks = [
            {"id": "T-1", "dependsOn": []},
            {"id": "T-2", "dependsOn": ["T-1"]},
            {"id": "T-3", "dependsOn": ["T-1"]},
            {"id": "T-4", "dependsOn": ["T-2", "T-3"]},
        ]
        self.assertEqual(dag_waves(tasks), [["T-1"], ["T-2", "T-3"], ["T-4"]])

    def test_width_overflow(self):
        tasks = [{"id": f"T-{n}", "dependsOn": []} for n in range(1, 5)]
        self.assertEqual(dag_waves(tasks, width=3), [["T-1", "T-2", "T-3"], ["T-4"]])

    def test_cycle_raises(self):
        tasks = [{"id": "T-1", "dependsOn": ["T-2"]}, {"id": "T-2", "dependsOn": ["T-1"]}]
        with self.assertRaises(LoopSpecError):
            dag_waves(tasks)


# simplicity: indirection-scan sees one call site (setUp's list comprehension
# line) though it constructs both T-1 and T-2; keeping it avoids repeating the
# plan-task schema's nine fields twice in setUp.
def _plan_task(task_id, verify="sh verify.sh", depends_on=None):
    return {
        "id": task_id, "title": task_id, "dependsOn": depends_on or [], "files": [f"{task_id}.txt"],
        "repo": "repo", "verify": verify, "criteria": ["AC-1"], "featureAdded": None, "mustFlip": False,
    }


class ExecuteLifecycleTests(unittest.TestCase):
    """One consumer repo, a two-task plan, and the implement/review/verify loop."""

    # simplicity: setUp/tearDown are unittest's fixed method names, not a naming
    # choice; house-style.sh's camelCase deviation on this file is the same
    # pre-existing false positive test_result.py and test_postconditions.py hit.
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        _init_repo(self.repo)
        self.base_sha = _head(self.repo)
        _git(self.repo, "branch", "feature", self.base_sha)

        self.paths = FeaturePaths(root=self.tmp / "run")
        self.store = StateStore.create(self.paths, {"id": "run-1", "slug": "add-a-widget"}, "add a widget")
        self.store.state["repos"] = {
            "repo": {"path": str(self.repo), "baseSha": self.base_sha, "featureBranch": "feature",
                     "defaultBranch": "main", "lastKnownHead": self.base_sha},
        }
        self.store.state["products"]["spec"] = {
            "exit": "approved", "product": {"criteria": [{"id": "AC-1", "text": "it works"}]},
        }
        self.plan_tasks = [_plan_task("T-1"), _plan_task("T-2", depends_on=["T-1"])]
        self.store.state["products"]["plan"] = {"exit": "ready", "product": {"tasks": self.plan_tasks}}
        # A real run_command call, not a hand-built CommandRun: fingerprints() hashes
        # even a clean run's "<no failure output>" marker, so a guessed empty list
        # would never match compare_to_baseline's real candidate fingerprints.
        baseline_run = run_command("sh verify.sh", self.repo, self.base_sha)
        entry = BaselineEntry(command="sh verify.sh", task=None, status="ran", run=baseline_run)
        self.store.state["baseline"] = {"entries": {"sh verify.sh": entry.to_dict()}}
        self.store.save()

        self.ctx = {"attempt": {"id": "attempt-1"}, "inputs": {"digest": "sha256:" + "a" * 64},
                    "paths": {"projectRoot": str(self.repo)}, "probes": {},
                    "entry": {"mode": "fresh", "payload": None}}

    def tearDown(self):
        self._tmp.cleanup()

    def _implementer_result(self, task_id, worktree, filename):
        _commit(worktree, filename, f"implement {task_id}")
        return {"taskId": task_id, "commits": [_head(worktree)], "summary": f"did {task_id}",
                "verifyRun": {"command": "sh verify.sh", "exitStatus": 0}, "issues": []}

    def _pass_review(self, sha, from_sha, to_sha):
        return {"sha": sha, "reviewedRange": {"from": from_sha, "to": to_sha}, "verdict": "pass",
                "findings": [], "securityDispositions": []}

    def _implement_and_review(self, task_id, filename):
        """One implement step, then one passing review step, for a task with no
        prior attempts -- the shared setup the two plan-gap tests below both need
        before the verify re-run they're actually exercising even happens."""
        action = step(self.store, self.paths, self.ctx)
        worktree = action.request["cwd"]
        result = self._implementer_result(task_id, worktree, filename)
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "impl-1"}, result)

        action = step(self.store, self.paths, self.ctx)
        task_head = _head(worktree)
        review = self._pass_review(task_head, self.base_sha, task_head)
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "rev-1"}, review)
        return worktree, task_head

    def _assert_routed_to_plan_gap(self, task_id):
        """Zero retries spent, then the very next step() call hands back the plan-gap
        product -- shared by both plan-gap tests, which differ only in what unfixable
        verify verdict got the task there and are free to assert its issue text."""
        task_state = self.store.state["execute"]["tasks"][task_id]
        self.assertEqual(task_state["status"], "planGap")
        self.assertEqual(task_state["retries"], 0)

        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, Product)
        self.assertEqual(action.product["exit"], "plan gap")
        return action

    def test_full_success_lifecycle(self):
        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, IssueStep)
        self.assertEqual(action.request["role"], "implementer")
        t1_worktree = self.store.state["execute"]["tasks"]["T-1"]["worktree"]
        self.assertTrue(Path(t1_worktree).is_dir())

        result = self._implementer_result("T-1", t1_worktree, "T-1.txt")
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "step-1"}, result)
        self.assertEqual(self.store.state["execute"]["tasks"]["T-1"]["status"], "probing")

        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, IssueStep)
        self.assertEqual(action.request["role"], "code-reviewer")
        self.assertIn(self.base_sha, action.request["prompt"])  # the range's "from" names the feature head

        task_head = _head(t1_worktree)
        review = self._pass_review(task_head, self.base_sha, task_head)
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "step-2"}, review)
        self.assertEqual(self.store.state["execute"]["tasks"]["T-1"]["status"], "done")
        self.assertEqual(self.store.state["execute"]["repos"]["repo"]["head"], task_head)

        # T-2 depends on T-1 and only becomes issuable now that T-1 is done.
        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, IssueStep)
        self.assertEqual(action.request["role"], "implementer")
        t2_worktree = self.store.state["execute"]["tasks"]["T-2"]["worktree"]

        result = self._implementer_result("T-2", t2_worktree, "T-2.txt")
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "step-3"}, result)

        action = step(self.store, self.paths, self.ctx)
        self.assertEqual(action.request["role"], "code-reviewer")
        t2_head = _head(t2_worktree)
        review = self._pass_review(t2_head, task_head, t2_head)
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "step-4"}, review)

        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, Product)
        self.assertEqual(action.product["exit"], "integrated")
        ids = {t["id"] for t in action.product["tasks"]}
        self.assertEqual(ids, {"T-1", "T-2"})
        self.assertEqual(action.product["heads"]["repo"], t2_head)
        done_task = next(t for t in action.product["tasks"] if t["id"] == "T-1")
        self.assertEqual(done_task["review"]["verdict"], "pass")

    def test_review_fail_reissues_implement_with_the_finding_in_reason(self):
        action = step(self.store, self.paths, self.ctx)
        worktree = action.request["cwd"]
        result = self._implementer_result("T-1", worktree, "T-1.txt")
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "step-1"}, result)

        action = step(self.store, self.paths, self.ctx)
        task_head = _head(worktree)
        finding = {"id": "F-1", "location": "T-1.txt:1", "cause": "missing a null check",
                   "severity": "Critical", "disposition": "open", "reason": None, "supersedes": None}
        review = {"sha": task_head, "reviewedRange": {"from": self.base_sha, "to": task_head}, "verdict": "fail",
                  "findings": [finding], "securityDispositions": []}
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "step-2"}, review)
        self.assertEqual(self.store.state["execute"]["tasks"]["T-1"]["status"], "pending")

        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, IssueStep)
        self.assertEqual(action.request["role"], "implementer")
        self.assertIn("missing a null check", action.request["reason"])

    def test_retries_past_the_limit_block_the_task(self):
        # Each retry costs two step() calls (implement, then review), so the loop
        # needs headroom for 2 * (retry_limit() + 1) calls, not retry_limit() + 1.
        for attempt in range(2 * (retry_limit() + 2)):
            action = step(self.store, self.paths, self.ctx)
            if isinstance(action, Product):
                break
            worktree = action.request["cwd"]
            if action.request["role"] == "implementer":
                filename = f"T-1-{attempt}.txt"
                result = self._implementer_result("T-1", worktree, filename)
                on_submit(self.store, self.paths, action.request | {"stepAttemptId": f"impl-{attempt}"}, result)
            else:
                task_head = _head(worktree)
                finding = {"id": f"F-{attempt}", "location": "T-1.txt:1", "cause": "still broken",
                           "severity": "Critical", "disposition": "open", "reason": None, "supersedes": None}
                review = {"sha": task_head, "reviewedRange": {"from": self.base_sha, "to": task_head},
                          "verdict": "fail", "findings": [finding], "securityDispositions": []}
                on_submit(self.store, self.paths, action.request | {"stepAttemptId": f"rev-{attempt}"}, review)

        self.assertIsInstance(action, Product)
        self.assertEqual(action.product["exit"], "blocked")
        self.assertEqual(self.store.state["execute"]["tasks"]["T-1"]["status"], "blocked")
        self.assertTrue(action.product["issues"])

    def test_mustflip_on_an_ordinary_task_routes_to_plan_gap(self):
        # LF-11: the planner mistakenly set featureAdded to the verify COMMAND
        # string and mustFlip: true on an ordinary (non-debug-repair) task. No
        # implementer retry can make an already-passing baseline "fail at base",
        # so this must exit plan gap on the first pass, not burn retries toward
        # a blocked no implementer could have prevented.
        self.plan_tasks[0]["mustFlip"] = True
        self.plan_tasks[0]["featureAdded"] = "sh verify.sh"

        self._implement_and_review("T-1", "T-1.txt")

        action = self._assert_routed_to_plan_gap("T-1")
        self.assertEqual(action.product["issues"], [
            {"task": "T-1", "text": "the verify re-run is mustFlip-failed: reproduction did not fail at base"},
        ])

    def test_missing_baseline_routes_to_plan_gap(self):
        self.plan_tasks[0]["verify"] = "sh other.sh"
        self.store.state["baseline"]["entries"]["sh other.sh"] = BaselineEntry(
            command="sh other.sh", task=None, status="no-baseline", run=None,
        ).to_dict()

        self._implement_and_review("T-1", "T-1.txt")

        self._assert_routed_to_plan_gap("T-1")

    def test_regression_still_retries_before_blocking(self):
        # A genuine regression (unlike mustFlip-failed/baseline-error above) is the
        # implementer's to fix, so it keeps the existing retry-then-block path.
        # verify.sh is broken once, on the task's own worktree/branch, which every
        # retry below reuses (_ensure_worktree creates it only on the first call).
        broken = False
        for attempt in range(2 * (retry_limit() + 2)):
            action = step(self.store, self.paths, self.ctx)
            if isinstance(action, Product):
                break
            worktree = action.request["cwd"]
            if action.request["role"] == "implementer":
                _commit(worktree, f"T-1-{attempt}.txt", f"implement T-1 {attempt}")
                if not broken:
                    # A silent `exit 1` fingerprints identically to the baseline's
                    # silent `exit 0` (fingerprints() hashes output text, never exit
                    # status), so the break needs distinct output to register as a
                    # new failure identity.
                    Path(worktree, "verify.sh").write_text("#!/bin/sh\necho 'regression detected'\nexit 1\n")
                    _git(worktree, "add", "verify.sh")
                    _git(worktree, "commit", "-q", "-m", "break verify")
                    broken = True
                result = {"taskId": "T-1", "commits": [_head(worktree)], "summary": f"did T-1 {attempt}",
                          "verifyRun": {"command": "sh verify.sh", "exitStatus": 1}, "issues": []}
                on_submit(self.store, self.paths, action.request | {"stepAttemptId": f"impl-{attempt}"}, result)
            else:
                task_head = _head(worktree)
                review = self._pass_review(task_head, self.base_sha, task_head)
                on_submit(self.store, self.paths, action.request | {"stepAttemptId": f"rev-{attempt}"}, review)

        self.assertIsInstance(action, Product)
        self.assertEqual(action.product["exit"], "blocked")
        self.assertEqual(self.store.state["execute"]["tasks"]["T-1"]["status"], "blocked")

    def test_out_of_band_commit_pauses(self):
        step(self.store, self.paths, self.ctx)  # initializes worktrees, including worktrees/feature
        feature_worktree = self.store.state["execute"]["repos"]["repo"]["worktree"]
        _commit(feature_worktree, "sneaky.txt", "out of band")

        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, Pause)
        self.assertEqual(action.question_request["payload"]["repo"], "repo")

    def test_first_step_creates_a_missing_feature_branch_at_base(self):
        # LF-13: setUp pre-creates "feature" for every other test; this one removes
        # it to exercise the run that arrives at EXECUTE with no branch minted yet.
        _git(self.repo, "branch", "-D", "feature")
        self.assertIsNone(repo_module.branch_sha(self.repo, "feature"))

        action = step(self.store, self.paths, self.ctx)

        self.assertEqual(repo_module.branch_sha(self.repo, "feature"), self.base_sha)
        self.assertIsInstance(action, IssueStep)

    def test_stale_task_branch_with_a_foreign_commit_pauses(self):
        # LF-14: a task branch left over from a previous run of this same slug, with
        # a commit the current feature head never integrated, is out of band -- the
        # same condition the feature-branch check above already pauses for.
        _git(self.repo, "branch", "task/add-a-widget/T-1", self.base_sha)
        _git(self.repo, "checkout", "task/add-a-widget/T-1")
        _commit(self.repo, "foreign.txt", "leftover from a previous run")
        _git(self.repo, "checkout", "main")

        action = step(self.store, self.paths, self.ctx)

        self.assertIsInstance(action, Pause)
        self.assertIn("task/add-a-widget/T-1", action.question_request["text"])

    def test_default_branch_drift_between_step_calls_pauses(self):
        # LF-15: the implementer's mistake was committing into the project root
        # (the "main" checkout) instead of its own task worktree -- self.repo IS
        # that checkout, still on "main" after setUp (branch creation never
        # switches it), so committing there directly reproduces it.
        step(self.store, self.paths, self.ctx)  # initializes; records repos.repo.defaultHead
        _commit(self.repo, "oops.txt", "committed straight into the checkout")

        action = step(self.store, self.paths, self.ctx)

        self.assertIsInstance(action, Pause)
        self.assertEqual(action.question_request["kind"], "blocked")
        self.assertEqual(action.question_request["payload"]["branch"], "main")
        self.assertIn("main", action.question_request["text"])

    def test_e6_rejection_reissues_review_and_does_not_reclear_within_the_same_attempt(self):
        # LF-16: EXECUTE's own product got rejected with E6 (an unaccepted review
        # evidence level) after T-1 was already "done" -- left alone, the next
        # attempt would resubmit the identical product and get rejected again.
        worktree, task_head = self._implement_and_review("T-1", "T-1.txt")
        self.assertEqual(self.store.state["execute"]["tasks"]["T-1"]["status"], "done")
        last_review_step = self.store.state["execute"]["tasks"]["T-1"]["reviewSteps"][-1]

        rejection_ctx = self.ctx | {
            "attempt": {"id": "attempt-2"},
            "entry": {"mode": "remediation", "payload": {"rejected": {
                "exit": "integrated",
                "failures": [{"id": "E6", "message": "tasks with an unaccepted review evidence level: T-1"}],
            }}},
        }

        action = step(self.store, self.paths, rejection_ctx)
        self.assertIsInstance(action, IssueStep)
        self.assertEqual(action.request["role"], "code-reviewer")
        self.assertEqual(action.request["retryOf"], last_review_step)
        self.assertIn("T-1", action.request["reason"])
        task_state = self.store.state["execute"]["tasks"]["T-1"]
        self.assertEqual(task_state["status"], "reviewing")
        self.assertIsNone(task_state["review"])

        # A later step() call in this same attempt must not re-clear: put T-1
        # back where a re-dispatch would find it, with a sentinel review, and
        # confirm handledRejections' guard leaves it alone.
        task_state["status"] = "probing"
        task_state["review"] = {"sentinel": True}
        action = step(self.store, self.paths, rejection_ctx)
        self.assertIsInstance(action, IssueStep)
        self.assertEqual(task_state["review"], {"sentinel": True})
        self.assertEqual(self.store.state["execute"]["handledRejections"], ["attempt-2"])

    def test_review_reissues_past_the_limit_block_the_task(self):
        # LF-35: a review that never attests must not be re-issued forever; each
        # E6 re-issue counts as a retry, and past the limit the task blocks.
        worktree, task_head = self._implement_and_review("T-1", "T-1.txt")
        task_state = self.store.state["execute"]["tasks"]["T-1"]
        for n in range(retry_limit() + 1):
            rejection_ctx = self.ctx | {
                "attempt": {"id": f"attempt-e6-{n}"},
                "entry": {"mode": "remediation", "payload": {"rejected": {
                    "exit": "integrated",
                    "failures": [{"id": "E6", "message": "tasks with an unaccepted review evidence level: T-1"}],
                }}},
            }
            action = step(self.store, self.paths, rejection_ctx)
            if isinstance(action, Product):
                break
            self.assertEqual(action.request["role"], "code-reviewer")
            review = self._pass_review(task_head, task_head, task_head)
            on_submit(self.store, self.paths, action.request | {"stepAttemptId": f"rev-e6-{n}"}, review)
        self.assertIsInstance(action, Product)
        self.assertEqual(action.product["exit"], "blocked")
        self.assertEqual(task_state["status"], "blocked")
        self.assertEqual(task_state["retries"], retry_limit() + 1)
        self.assertEqual(task_state["commits"], [task_head])

    def test_review_retry_after_rejection_does_not_wipe_commits(self):
        # LF-17: an E6 rejection resets a DONE task straight to "probing" (no new
        # implementation), so the fresh review's task_head equals the already
        # -integrated feature_head -- that re-review must not wipe the commits
        # the FIRST integration recorded.
        worktree, task_head = self._implement_and_review("T-1", "T-1.txt")
        task_state = self.store.state["execute"]["tasks"]["T-1"]
        self.assertEqual(task_state["commits"], [task_head])
        self.assertEqual(task_state["integratedFrom"], self.base_sha)
        self.assertEqual(task_state["integratedTo"], task_head)

        rejection_ctx = self.ctx | {
            "attempt": {"id": "attempt-e6-retry"},
            "entry": {"mode": "remediation", "payload": {"rejected": {
                "exit": "integrated",
                "failures": [{"id": "E6", "message": "tasks with an unaccepted review evidence level: T-1"}],
            }}},
        }
        action = step(self.store, self.paths, rejection_ctx)
        self.assertIsInstance(action, IssueStep)
        self.assertEqual(action.request["role"], "code-reviewer")

        review = self._pass_review(task_head, task_head, task_head)
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "rev-2"}, review)

        self.assertEqual(task_state["status"], "done")
        self.assertEqual(task_state["commits"], [task_head])

    def test_e4_rejection_pauses_on_every_fresh_attempt(self):
        # LF-18: a genuine, self-heal-resistant mismatch (commits is non-empty but
        # wrong, so _self_heal_commits -- which only fires on an EMPTY list --
        # leaves it alone) must pause every time a fresh attempt sees it, not just
        # once, and never silently fall through to a product.
        worktree, task_head = self._implement_and_review("T-1", "T-1.txt")
        self.store.state["execute"]["tasks"]["T-1"]["commits"] = [self.base_sha]

        rejection_ctx = self.ctx | {
            "attempt": {"id": "attempt-e4-1"},
            "entry": {"mode": "remediation", "payload": {"rejected": {
                "exit": "integrated",
                "failures": [{"id": "E4", "message": "repo repo: task commits do not exactly cover base..head"}],
            }}},
        }
        action = step(self.store, self.paths, rejection_ctx)
        self.assertIsInstance(action, Pause)
        self.assertIn(task_head, action.question_request["text"])

        action = step(self.store, self.paths, rejection_ctx | {"attempt": {"id": "attempt-e4-2"}})
        self.assertIsInstance(action, Pause)

    def test_legacy_execute_state_backfills_and_emits_module_state_reset(self):
        # A run whose state.execute predates handledRejections (LF-16) or a
        # repo's defaultHead (LF-15) must not KeyError on resume; a hand-built
        # legacy dict, missing both, stands in for one such old run.
        self._implement_and_review("T-1", "T-1.txt")
        execute_state = self.store.state["execute"]
        del execute_state["handledRejections"]
        del execute_state["repos"]["repo"]["defaultHead"]
        self.store.save()

        rejection_ctx = self.ctx | {
            "attempt": {"id": "attempt-legacy"},
            "entry": {"mode": "remediation", "payload": {"rejected": {
                "exit": "integrated",
                "failures": [{"id": "E6", "message": "tasks with an unaccepted review evidence level: T-1"}],
            }}},
        }
        action = step(self.store, self.paths, rejection_ctx)
        self.assertIsInstance(action, IssueStep)

        events_text = self.paths.events_jsonl.read_text()
        self.assertIn('"module_state_reset"', events_text)
        self.assertIn("defaultHead", events_text)
        self.assertIn("handledRejections", events_text)


if __name__ == "__main__":
    unittest.main()
