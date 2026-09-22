"""Unit tests for loop_spec.execute: dag_waves and the EXECUTE state machine."""
import subprocess
import tempfile
import unittest
from pathlib import Path

from loop_spec import repo as repo_module
from loop_spec.baseline import BaselineEntry, run_command
from loop_spec.errors import LoopSpecError
from loop_spec.execute import _final_product, IssueStep, IssueSteps, Pause, Product, dag_waves, on_submit, step
from loop_spec.jsonio import atomic_write_json
from loop_spec.paths import FeaturePaths
from loop_spec.postconditions import retry_limit
from loop_spec.state import StateStore

from tests._product_checks import assert_product_holds


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
        # These tests call on_submit directly, bypassing steps.submit's own
        # evidence-level attestation; "external" is review_evidence's own escape
        # for exactly that case (an external implementation's whole product is
        # one human-attested submission), so E6 judges a hand-built result the
        # same way it would a real external EXECUTE's.
        self.store.state["implementations"]["phases"]["execute"] = "external"
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

    def _drive_to_integrated(self):
        """T-1 then T-2 through implement/review to a fully integrated product --
        the shared starting point every LF-51 rewind test below needs, mirroring
        test_full_success_lifecycle's own sequence."""
        action = step(self.store, self.paths, self.ctx)
        t1_worktree = action.request["cwd"]
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "impl-t1"},
                  self._implementer_result("T-1", t1_worktree, "T-1.txt"))

        action = step(self.store, self.paths, self.ctx)
        t1_head = _head(t1_worktree)
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "rev-t1"},
                  self._pass_review(t1_head, self.base_sha, t1_head))

        action = step(self.store, self.paths, self.ctx)
        t2_worktree = action.request["cwd"]
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "impl-t2"},
                  self._implementer_result("T-2", t2_worktree, "T-2.txt"))

        action = step(self.store, self.paths, self.ctx)
        t2_head = _head(t2_worktree)
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "rev-t2"},
                  self._pass_review(t2_head, t1_head, t2_head))

        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, Product)
        self.assertEqual(action.product["exit"], "integrated")
        return action.product

    def _rewind_ctx(self, attempt_id, remediation_task, cause="widget missing"):
        return self.ctx | {
            "attempt": {"id": attempt_id},
            "entry": {"mode": "remediation", "payload": {"rewind": {
                "from": "verify", "attemptId": "v-1", "exit": "implementation gap",
                "revisions": dict(self.store.state["revisions"]),
                "remediationTasks": [remediation_task],
                "verdicts": [{"criterion": remediation_task["criteria"][0], "verdict": "fail",
                              "cause": cause, "evidence": None, "remediation": None}],
            }}},
        }

    def test_verify_implementation_gap_reopens_the_owning_task_once(self):
        self.plan_tasks[1]["criteria"] = ["AC-2"]
        self.store.state["products"]["plan"]["product"]["tasks"] = self.plan_tasks
        self.store.save()
        self._drive_to_integrated()

        remediation = {"id": "R-1", "title": "fix AC-1", "dependsOn": [], "files": ["T-1.txt"],
                        "repo": "repo", "verify": "sh verify.sh", "criteria": ["AC-1"],
                        "featureAdded": None, "mustFlip": False}
        ctx2 = self._rewind_ctx("attempt-2", remediation)
        # The real drive-to-integrated flow already recorded T-1's own E7
        # comparison here; the rewind must drop exactly that cached run.
        self.assertIn("T-1", self.store.state["executeRuns"])

        action = step(self.store, self.paths, ctx2)
        self.assertIsInstance(action, IssueStep)
        self.assertEqual(action.request["role"], "implementer")
        t1_state = self.store.state["execute"]["tasks"]["T-1"]
        self.assertEqual(action.request["cwd"], t1_state["worktree"])
        self.assertIn("widget missing", action.request["reason"])
        self.assertEqual(t1_state["retries"], 0)
        self.assertEqual(len(t1_state["remediations"]), 1)
        self.assertEqual(t1_state["remediations"][0]["priorStatus"], "done")
        self.assertNotIn("T-1", self.store.state["executeRuns"])
        self.assertEqual(self.store.state["execute"]["tasks"]["T-2"]["status"], "done")

        worktree = action.request["cwd"]
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "impl-remediate"},
                  self._implementer_result("T-1", worktree, "T-1-repair.txt"))

        action = step(self.store, self.paths, ctx2)
        self.assertIsInstance(action, IssueStep)
        self.assertEqual(action.request["role"], "code-reviewer")
        task_head = _head(worktree)
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "rev-remediate"},
                  self._pass_review(task_head, self.base_sha, task_head))

        action = step(self.store, self.paths, ctx2)
        self.assertIsInstance(action, Product)
        self.assertEqual(action.product["exit"], "integrated")
        self.assertEqual(len(self.store.state["execute"]["tasks"]["T-1"]["commits"]), 2)
        assert_product_holds(self, self.store, self.paths, self.repo, "execute", action.product)

        # A second step() call in the same remediation round must not re-open it again.
        action = step(self.store, self.paths, ctx2)
        self.assertIsInstance(action, Product)
        self.assertEqual(len(self.store.state["execute"]["tasks"]["T-1"]["remediations"]), 1)

    def test_rewind_with_stale_revisions_is_ignored(self):
        self.plan_tasks[1]["criteria"] = ["AC-2"]
        self.store.state["products"]["plan"]["product"]["tasks"] = self.plan_tasks
        self.store.save()
        self._drive_to_integrated()

        remediation = {"id": "R-1", "title": "fix AC-1", "dependsOn": [], "files": ["T-1.txt"],
                        "repo": "repo", "verify": "sh verify.sh", "criteria": ["AC-1"],
                        "featureAdded": None, "mustFlip": False}
        ctx2 = self._rewind_ctx("attempt-2", remediation)
        ctx2["entry"]["payload"]["rewind"]["revisions"] = {
            "requirements": "sha256:" + "f" * 64, "plan": "sha256:" + "f" * 64,
        }

        action = step(self.store, self.paths, ctx2)
        self.assertIsInstance(action, Product)
        self.assertEqual(action.product["exit"], "integrated")
        self.assertEqual(self.store.state["execute"]["handledRewinds"], [])
        events_text = self.paths.events_jsonl.read_text()
        self.assertIn('"rewind_ignored"', events_text)

    def test_rewind_that_maps_to_no_task_raises(self):
        self.plan_tasks[1]["criteria"] = ["AC-2"]
        self.store.state["products"]["plan"]["product"]["tasks"] = self.plan_tasks
        self.store.save()
        self._drive_to_integrated()

        remediation = {"id": "R-1", "title": "fix it", "dependsOn": [], "files": ["nope.txt"],
                        "repo": "other", "verify": "sh verify.sh", "criteria": ["AC-1"],
                        "featureAdded": None, "mustFlip": False}
        ctx2 = self._rewind_ctx("attempt-2", remediation)
        with self.assertRaises(LoopSpecError):
            step(self.store, self.paths, ctx2)

    def test_rewind_reforks_when_the_old_worktree_is_dirty_and_keeps_it(self):
        self.plan_tasks[1]["criteria"] = ["AC-2"]
        self.store.state["products"]["plan"]["product"]["tasks"] = self.plan_tasks
        self.store.save()
        self._drive_to_integrated()
        old_worktree = self.store.state["execute"]["tasks"]["T-1"]["worktree"]
        old_branch = self.store.state["execute"]["tasks"]["T-1"]["branch"]
        Path(old_worktree, "scratch.txt").write_text("uncommitted\n")

        remediation = {"id": "R-1", "title": "fix AC-1", "dependsOn": [], "files": ["T-1.txt"],
                        "repo": "repo", "verify": "sh verify.sh", "criteria": ["AC-1"],
                        "featureAdded": None, "mustFlip": False}
        ctx2 = self._rewind_ctx("attempt-2", remediation)

        action = step(self.store, self.paths, ctx2)
        self.assertIsInstance(action, IssueStep)
        self.assertTrue(action.request["cwd"].endswith("T-1-r1"))
        self.assertTrue(Path(old_worktree).exists())
        self.assertTrue(Path(old_worktree, "scratch.txt").exists())
        quarantined = self.store.state["steps"]["quarantined"]
        self.assertEqual(len(quarantined), 1)
        self.assertEqual(quarantined[0]["path"], old_worktree)
        self.assertEqual(quarantined[0]["reason"], "uncommitted changes")
        self.assertIsNotNone(repo_module.branch_sha(self.repo, old_branch))

    def _retire_t1_step_as(self, evidence_level, *, drive_both=True):
        if drive_both:
            self._drive_to_integrated()
        else:
            # T-2 never runs: T-1's own branch stays exactly at the feature
            # head (nothing else has advanced it), which the reuse path's
            # is_ancestor(feature_head, task_head) check needs to hold.
            self._implement_and_review("T-1", "T-1.txt")
        task_state = self.store.state["execute"]["tasks"]["T-1"]
        step_id = task_state["implementSteps"][-1]
        worktree = task_state["worktree"]
        step_dir = self.paths.steps_dir / step_id
        step_dir.mkdir(parents=True, exist_ok=True)
        atomic_write_json(step_dir / "step.json", {"cwd": worktree})
        self.store.state["steps"]["retired"].append(step_id)
        self.store.state["steps"]["submissions"][step_id] = {"evidenceLevel": evidence_level}
        return worktree

    def test_rewind_reforks_when_writer_termination_is_unknown(self):
        from loop_spec import controller as controller_module

        self.plan_tasks[1]["criteria"] = ["AC-2"]
        self.store.state["products"]["plan"]["product"]["tasks"] = self.plan_tasks
        self.store.save()
        old_worktree = self._retire_t1_step_as("unattested")

        remediation = {"id": "R-1", "title": "fix AC-1", "dependsOn": [], "files": ["T-1.txt"],
                        "repo": "repo", "verify": "sh verify.sh", "criteria": ["AC-1"],
                        "featureAdded": None, "mustFlip": False}
        ctx2 = self._rewind_ctx("attempt-2", remediation)

        action = step(self.store, self.paths, ctx2)
        self.assertIsInstance(action, IssueStep)
        self.assertTrue(action.request["cwd"].endswith("T-1-r1"))
        self.assertTrue(Path(old_worktree).exists())
        quarantined = self.store.state["steps"]["quarantined"]
        self.assertEqual(len(quarantined), 1)
        self.assertEqual(quarantined[0]["path"], old_worktree)
        self.assertEqual(quarantined[0]["reason"], "writer termination unknown")

        protected = controller_module._protected_worktree_paths(self.store)
        repo_module.remove_worktrees(self.repo, self.paths.worktrees_dir, protected=protected)
        self.assertTrue(Path(old_worktree).exists())

    def test_rewind_reuses_a_clean_terminated_worktree(self):
        self.plan_tasks[1]["criteria"] = ["AC-2"]
        self.store.state["products"]["plan"]["product"]["tasks"] = self.plan_tasks
        self.store.save()
        old_worktree = self._retire_t1_step_as("host-attested", drive_both=False)

        remediation = {"id": "R-1", "title": "fix AC-1", "dependsOn": [], "files": ["T-1.txt"],
                        "repo": "repo", "verify": "sh verify.sh", "criteria": ["AC-1"],
                        "featureAdded": None, "mustFlip": False}
        ctx2 = self._rewind_ctx("attempt-2", remediation)

        action = step(self.store, self.paths, ctx2)
        self.assertIsInstance(action, IssueStep)
        self.assertEqual(action.request["cwd"], old_worktree)

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
        assert_product_holds(self, self.store, self.paths, self.repo, "execute", action.product, check_boundary=False)
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
        assert_product_holds(self, self.store, self.paths, self.repo, "execute", action.product)

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
        assert_product_holds(self, self.store, self.paths, self.repo, "execute", action.product, check_boundary=False)

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
        assert_product_holds(self, self.store, self.paths, self.repo, "execute", action.product, check_boundary=False)

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
        assert_product_holds(self, self.store, self.paths, self.repo, "execute", action.product, check_boundary=False)

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

    def test_already_satisfied_at_the_fork_with_a_clean_tree_is_accepted(self):
        action = step(self.store, self.paths, self.ctx)
        result = {"taskId": "T-1", "commits": [], "summary": "already satisfied: base has it",
                  "verifyRun": {"command": "sh verify.sh", "exitStatus": 0}, "issues": []}
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "step-1"}, result)
        task_state = self.store.state["execute"]["tasks"]["T-1"]
        self.assertEqual(task_state["status"], "already-satisfied")

    def test_already_satisfied_with_commits_past_the_fork_takes_the_commit_path(self):
        action = step(self.store, self.paths, self.ctx)
        worktree = action.request["cwd"]
        _commit(worktree, "T-1.txt", "work")
        result = {"taskId": "T-1", "commits": [], "summary": "already satisfied: base has it",
                  "verifyRun": {"command": "sh verify.sh", "exitStatus": 0}, "issues": []}
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "step-1"}, result)
        task_state = self.store.state["execute"]["tasks"]["T-1"]
        self.assertEqual(task_state["status"], "probing")

        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, IssueStep)
        self.assertEqual(action.request["role"], "code-reviewer")

        events_text = self.paths.events_jsonl.read_text()
        self.assertIn('"already_satisfied_contradicted"', events_text)

    def test_already_satisfied_with_a_dirty_tree_at_the_fork_retries(self):
        action = step(self.store, self.paths, self.ctx)
        worktree = action.request["cwd"]
        Path(worktree, "scratch.txt").write_text("x\n")
        result = {"taskId": "T-1", "commits": [], "summary": "already satisfied: base has it",
                  "verifyRun": {"command": "sh verify.sh", "exitStatus": 0}, "issues": []}
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "step-1"}, result)
        task_state = self.store.state["execute"]["tasks"]["T-1"]
        self.assertEqual(task_state["status"], "pending")
        self.assertIn("uncommitted changes", task_state["reason"])

    def test_already_satisfied_with_no_recorded_fork_is_not_accepted(self):
        action = step(self.store, self.paths, self.ctx)
        self.store.state["execute"]["tasks"]["T-1"]["forkedFrom"] = None
        self.store.save()
        result = {"taskId": "T-1", "commits": [], "summary": "already satisfied: base has it",
                  "verifyRun": {"command": "sh verify.sh", "exitStatus": 0}, "issues": []}
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "step-1"}, result)
        task_state = self.store.state["execute"]["tasks"]["T-1"]
        self.assertNotEqual(task_state["status"], "already-satisfied")
        self.assertIn("no commit was made", task_state["reason"])

    def test_already_satisfied_after_a_sibling_moved_the_feature_head_keeps_the_commit(self):
        self.plan_tasks[1]["dependsOn"] = []
        self.store.state["products"]["plan"]["product"]["tasks"] = self.plan_tasks
        self.store.save()

        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, IssueSteps)
        tasks = self.store.state["execute"]["tasks"]
        wt1, wt2 = tasks["T-1"]["worktree"], tasks["T-2"]["worktree"]
        req1 = next(r for r in action.requests if r["cwd"] == wt1)
        req2 = next(r for r in action.requests if r["cwd"] == wt2)

        result2 = self._implementer_result("T-2", wt2, "T-2.txt")
        on_submit(self.store, self.paths, req2 | {"stepAttemptId": "impl-2"}, result2)

        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, IssueStep)
        t2_head = _head(wt2)
        review2 = self._pass_review(t2_head, self.base_sha, t2_head)
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "rev-2"}, review2)
        self.assertEqual(tasks["T-2"]["status"], "done")

        _commit(wt1, "T-1.txt", "work")
        result1 = {"taskId": "T-1", "commits": [], "summary": "already satisfied: base has it",
                   "verifyRun": {"command": "sh verify.sh", "exitStatus": 0}, "issues": []}
        on_submit(self.store, self.paths, req1 | {"stepAttemptId": "impl-1"}, result1)
        self.assertEqual(tasks["T-1"]["status"], "probing")


class AdoptedTaskTests(unittest.TestCase):
    """LF-38: a revise run's reviser carries an unchanged prior task forward
    verbatim (its own contract says to); EXECUTE must adopt it instead of
    re-dispatching an implementer that finds nothing left to do."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        _init_repo(self.repo)
        self.base_sha = _head(self.repo)
        _git(self.repo, "checkout", "-q", "-b", "pr-branch")
        _commit(self.repo, "T-1.txt", "T-1: the delivered task")
        self.pr_head_sha = _head(self.repo)
        _git(self.repo, "checkout", "-q", "main")

        self.paths = FeaturePaths(root=self.tmp / "run")
        self.store = StateStore.create(self.paths, {"id": "run-1", "slug": "revise-1"}, "revise PR #1")
        # Same shape controller._run_revise_entry builds: the feature branch IS the
        # PR's own branch, already at the adopted head.
        self.store.state["repos"] = {
            "repo": {"path": str(self.repo), "baseSha": self.base_sha, "featureBranch": "pr-branch",
                     "defaultBranch": "main", "lastKnownHead": self.pr_head_sha},
        }
        self.store.state["adoption"] = {
            "repo": "repo", "number": 1, "url": "https://example/pull/1", "headRef": "pr-branch",
            "baseBranch": "main", "baseSha": self.base_sha, "headSha": self.pr_head_sha,
        }
        self.store.state["products"]["spec"] = {
            "exit": "approved", "product": {"criteria": [{"id": "AC-1", "text": "it works"}]},
        }
        # R-1's review below is submitted through on_submit directly, bypassing
        # steps.submit's own attestation; see ExecuteLifecycleTests.setUp for why
        # "external" is the right stand-in for E6's evidence-level judgment here.
        self.store.state["implementations"]["phases"]["execute"] = "external"
        r1 = _plan_task("R-1")
        r1["title"] = "fix the remaining gap"
        self.plan_tasks = [_plan_task("T-1"), r1]
        self.store.state["products"]["plan"] = {"exit": "ready", "product": {"tasks": self.plan_tasks}}
        self.store.state["revise"] = {"gaps": [], "product": None, "prior": {
            "slug": "delivered", "spec": {"criteria": [{"id": "AC-1", "text": "it works"}]},
            "plan": {"tasks": [_plan_task("T-1")]},
        }}
        baseline_run = run_command("sh verify.sh", self.repo, self.pr_head_sha)
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

    def test_revise_run_adopts_unchanged_prior_tasks_and_dispatches_only_new_ones(self):
        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, IssueStep)
        self.assertEqual(action.request["role"], "implementer")
        r1_worktree = self.store.state["execute"]["tasks"]["R-1"]["worktree"]
        self.assertTrue(Path(r1_worktree).is_dir())

        t1_state = self.store.state["execute"]["tasks"]["T-1"]
        self.assertEqual(t1_state["status"], "adopted")
        self.assertEqual(t1_state["commits"], repo_module.commits_between(self.repo, self.base_sha, self.pr_head_sha))
        events_text = self.paths.events_jsonl.read_text()
        self.assertIn('"task_adopted"', events_text)

        result = self._implementer_result("R-1", r1_worktree, "R-1.txt")
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "step-1"}, result)

        action = step(self.store, self.paths, self.ctx)
        self.assertEqual(action.request["role"], "code-reviewer")
        r1_head = _head(r1_worktree)
        review = self._pass_review(r1_head, self.pr_head_sha, r1_head)
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "step-2"}, review)

        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, Product)
        self.assertEqual(action.product["exit"], "integrated")
        by_id = {t["id"]: t for t in action.product["tasks"]}
        self.assertEqual(by_id["T-1"]["disposition"], "adopted")
        self.assertEqual(by_id["T-1"]["commits"], repo_module.commits_between(self.repo, self.base_sha, self.pr_head_sha))
        self.assertEqual(by_id["R-1"]["disposition"], "done")
        # LF-42: the adopted task carries the adopted-range review, or E5 rejects it.
        self.store.state["adoptedReview"] = {"verdict": "pass", "reviewedRange": {"from": self.base_sha, "to": self.pr_head_sha},
                                             "findings": [], "securityDispositions": [], "sha": self.pr_head_sha}
        # An adopted task never runs execute.py's own implement/review loop, the
        # ONLY place execute.py itself records an executeRuns comparison (line
        # ~670); a real run gets an adopted task's E7 coverage from controller.
        # _run_execute_verifications's separate clean re-run instead. Standing in
        # for that here, since this test drives execute.py without controller.py.
        self.store.state.setdefault("executeRuns", {})["T-1"] = {"comparison": {"verdict": "match"}}
        product = _final_product(self.store, self.ctx, self.store.state["execute"])
        t1_review = {t["id"]: t["review"] for t in product["tasks"]}["T-1"]
        self.assertEqual(t1_review["reviewedRange"], {"from": self.base_sha, "to": self.pr_head_sha})
        self.assertNotIn("sha", t1_review)  # LF-43: the product schema refuses the reviewer's sha field
        assert_product_holds(self, self.store, self.paths, self.repo, "execute", product)

    def test_rewind_on_an_adopted_task_reforks_from_the_feature_head_and_keeps_adopted_commits(self):
        action = step(self.store, self.paths, self.ctx)
        self.assertIsInstance(action, IssueStep)
        r1_worktree = action.request["cwd"]
        t1_state = self.store.state["execute"]["tasks"]["T-1"]
        self.assertEqual(t1_state["status"], "adopted")
        adopted_commits = list(t1_state["commits"])

        # Drive R-1 (the only pending task) to done first, so a later step()
        # call for T-1's own rewind never has to look for R-1's dangling open
        # step (these tests submit through on_submit directly, never steps.issue).
        result = self._implementer_result("R-1", r1_worktree, "R-1.txt")
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "impl-r1"}, result)
        action = step(self.store, self.paths, self.ctx)
        self.assertEqual(action.request["role"], "code-reviewer")
        r1_head = _head(r1_worktree)
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "rev-r1"},
                  self._pass_review(r1_head, self.pr_head_sha, r1_head))
        self.assertEqual(self.store.state["execute"]["tasks"]["R-1"]["status"], "done")

        remediation = {"id": "R-2", "title": "fix the adopted task's gap", "dependsOn": [],
                        "files": ["T-1.txt"], "repo": "repo", "verify": "sh verify.sh",
                        "criteria": ["AC-1"], "featureAdded": None, "mustFlip": False}
        ctx2 = self.ctx | {
            "attempt": {"id": "attempt-2"},
            "entry": {"mode": "remediation", "payload": {"rewind": {
                "from": "verify", "attemptId": "v-1", "exit": "implementation gap",
                "revisions": dict(self.store.state["revisions"]),
                "remediationTasks": [remediation],
                "verdicts": [{"criterion": "AC-1", "verdict": "fail", "cause": "still missing something",
                              "evidence": None, "remediation": None}],
            }}},
        }
        action = step(self.store, self.paths, ctx2)
        self.assertIsInstance(action, IssueStep)
        self.assertTrue(action.request["cwd"].endswith("T-1-r1"))
        self.assertEqual(len(t1_state["remediations"]), 1)
        self.assertEqual(t1_state["remediations"][0]["priorStatus"], "adopted")

        worktree = action.request["cwd"]
        result = self._implementer_result("T-1", worktree, "T-1-repair.txt")
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "impl-t1-repair"}, result)

        action = step(self.store, self.paths, ctx2)
        self.assertEqual(action.request["role"], "code-reviewer")
        task_head = _head(worktree)
        # reviewFrom stayed the repo's own baseSha (an adopted task's anchor, set
        # once in _mark_adopted_tasks) through the re-fork, never the PR head.
        review = self._pass_review(task_head, self.base_sha, task_head)
        on_submit(self.store, self.paths, action.request | {"stepAttemptId": "rev-t1-repair"}, review)

        action = step(self.store, self.paths, ctx2)
        self.assertIsInstance(action, Product)
        self.assertEqual(action.product["exit"], "integrated")
        final_t1 = self.store.state["execute"]["tasks"]["T-1"]
        self.assertEqual(final_t1["status"], "done")
        self.assertEqual(final_t1["commits"], adopted_commits + [task_head])
        assert_product_holds(self, self.store, self.paths, self.repo, "execute", action.product)

    def test_a_changed_prior_task_is_not_adopted(self):
        # The delivering run's T-1 ran a different verify command -- the reviser
        # changed it, so EXECUTE must redo the task rather than adopt stale work.
        self.store.state["revise"]["prior"]["plan"]["tasks"][0]["verify"] = "sh other-verify.sh"

        action = step(self.store, self.paths, self.ctx)
        # T-1 (redone) and R-1 (never adopted) are both pending in the same
        # dependency-free wave, so wave-b1's parallel dispatch issues them
        # together (IssueSteps), not one at a time.
        self.assertIsInstance(action, IssueSteps)
        t1_request = next(r for r in action.requests
                           if r["cwd"] == self.store.state["execute"]["tasks"]["T-1"]["worktree"])
        self.assertEqual(t1_request["role"], "implementer")
        self.assertEqual(self.store.state["execute"]["tasks"]["T-1"]["status"], "implementing")


if __name__ == "__main__":
    unittest.main()
