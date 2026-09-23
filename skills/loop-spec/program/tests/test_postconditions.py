"""Unit tests for loop_spec.postconditions: one failing and one holding case per
postcondition id, against a fake-but-complete state built over a real temp git repo
(base commit plus two feature commits, T-1 and T-2).

D1-D3 call `gh`/a remote directly; per the wave's scope they are tested only for the
"record missing" failure path, not a full holding pass (that would need a real GitHub
remote). V5 has no failing branch at all: it only records exceptions as weakened
assurance, so its test covers both its no-exception and its exception shape instead.
"""
import copy
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from loop_spec import baseline as baseline_module
from loop_spec import budget as budget_module
from loop_spec import postconditions
from loop_spec import repo as repo_module
from loop_spec.jsonio import atomic_write_json
from loop_spec.paths import FeaturePaths
from loop_spec.state import StateStore

_VERIFY_CMD = 'python3 -c "import sys; sys.exit(0)"'


def _git(cwd, *args):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True)


def _rev_parse(cwd) -> str:
    return subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=cwd, check=True, capture_output=True, text=True,
    ).stdout.strip()


class PostconditionsTests(unittest.TestCase):
    """One shared fixture: a converged, delivered feature bound end to end."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        tmp = Path(self._tmp.name)
        self.repo_dir = repo_dir = tmp / "repo"
        repo_dir.mkdir()
        _git(repo_dir, "init", "-q", "-b", "main")
        _git(repo_dir, "config", "user.email", "test@example.com")
        _git(repo_dir, "config", "user.name", "Test")
        (repo_dir / "README.md").write_text("hello\n", encoding="utf-8")
        _git(repo_dir, "add", "README.md")
        _git(repo_dir, "commit", "-q", "-m", "init")
        self.base_sha = _rev_parse(repo_dir)

        _git(repo_dir, "checkout", "-q", "-b", "feat/x")
        (repo_dir / "a.txt").write_text("a\n", encoding="utf-8")
        _git(repo_dir, "add", "a.txt")
        _git(repo_dir, "commit", "-q", "-m", "T-1")
        self.sha_a = _rev_parse(repo_dir)
        (repo_dir / "b.txt").write_text("b\n", encoding="utf-8")
        _git(repo_dir, "add", "b.txt")
        _git(repo_dir, "commit", "-q", "-m", "T-2")
        self.sha_b = _rev_parse(repo_dir)

        self.paths = FeaturePaths(root=tmp / "feature")
        self.store = StateStore.create(
            self.paths, {"id": "run-1", "entry": "cycle", "cycleType": "full", "slug": "x", "createdAt": "2026-01-01T00:00:00+00:00"}, "do it",
        )
        self.store.state["repos"] = {
            "repo": {"path": str(repo_dir), "baseSha": self.base_sha, "featureBranch": "feat/x", "defaultBranch": "main", "lastKnownHead": self.base_sha},
        }
        self.store.state["implementations"]["phases"]["execute"] = "external"

        self.spec_product = {
            "exit": "approved", "inputsDigest": "sha256:" + "0" * 64,
            "boundTo": {"requirements": None, "plan": None},
            "goal": "Add a greeting", "boundaries": [],
            "criteria": [{"id": "AC-1", "text": "one"}, {"id": "AC-2", "text": "two"}],
            "decisions": [], "openQuestions": [],
        }
        self.spec_revision = postconditions.requirements_revision(self.spec_product)

        self.plan_product = {
            "exit": "ready", "inputsDigest": "sha256:" + "0" * 64,
            "boundTo": {"requirements": self.spec_revision, "plan": None},
            "tasks": [
                {"id": "T-1", "title": "t1", "dependsOn": [], "files": ["a.txt"], "repo": "repo",
                 "verify": _VERIFY_CMD, "criteria": ["AC-1"], "featureAdded": None, "mustFlip": False},
                {"id": "T-2", "title": "t2", "dependsOn": ["T-1"], "files": ["b.txt"], "repo": "repo",
                 "verify": _VERIFY_CMD, "criteria": ["AC-2"], "featureAdded": None, "mustFlip": False},
            ],
            "prepare": None, "evidenceExceptions": [],
        }
        self.plan_revision = postconditions.plan_revision(self.plan_product)

        baseline = baseline_module.capture_baseline(
            repo_dir, self.base_sha, [(_VERIFY_CMD, "T-1", None)], None, self.paths.checkouts_dir, "repo",
        )
        self.store.state["baseline"] = baseline.to_dict()
        self.store.state["critic"] = {"passes": 1, "findings": [], "planRevision": self.plan_revision}

        review_pass = {"reviewedRange": {"from": self.base_sha, "to": self.sha_b}, "verdict": "pass", "findings": [], "securityDispositions": []}
        self.execute_product = {
            "exit": "integrated", "inputsDigest": "sha256:" + "0" * 64,
            "boundTo": {"requirements": self.spec_revision, "plan": self.plan_revision},
            "tasks": [
                {"id": "T-1", "disposition": "done", "evidence": None, "commits": [self.sha_a], "review": copy.deepcopy(review_pass)},
                {"id": "T-2", "disposition": "done", "evidence": None, "commits": [self.sha_b], "review": copy.deepcopy(review_pass)},
            ],
            "issues": [], "heads": {"repo": self.sha_b},
        }
        self.store.state["executeRuns"] = {"T-1": {"comparison": {"verdict": "match"}}, "T-2": {"comparison": {"verdict": "match"}}}

        evidence = {"command": _VERIFY_CMD, "repo": "repo", "sha": self.sha_b, "exitStatus": 0, "failureIdentities": [], "outputDigest": "sha256:" + "0" * 64}
        self.verify_product = {
            "exit": "passed", "inputsDigest": "sha256:" + "0" * 64,
            "boundTo": {"requirements": self.spec_revision, "plan": self.plan_revision},
            "verdicts": [
                {"criterion": "AC-1", "verdict": "pass", "evidence": copy.deepcopy(evidence), "cause": None},
                {"criterion": "AC-2", "verdict": "pass", "evidence": copy.deepcopy(evidence), "cause": None},
            ],
            "findings": [], "remediationTasks": [],
            "reviewedRanges": [{"repo": "repo", "from": self.base_sha, "to": self.sha_b, "full": True}],
        }
        self.store.state["verifyRuns"] = {"AC-1": {"matched": True}, "AC-2": {"matched": True}}

        self.iterate_product = {
            "exit": "converged", "inputsDigest": "sha256:" + "0" * 64,
            "boundTo": {"requirements": self.spec_revision, "plan": self.plan_revision},
            "verdict": "met", "gaps": [], "caveats": [], "boundShas": {"repo": self.sha_b},
        }

        self.deliver_product = {
            "exit": "delivered", "inputsDigest": "sha256:" + "0" * 64,
            "boundTo": {"requirements": self.spec_revision, "plan": self.plan_revision},
            "repos": [{
                "repo": "repo", "pr": {"number": 1, "url": "https://example.invalid/pull/1", "headRef": "feat/x", "headSha": self.sha_b, "base": "main"},
                "deliveredSha": self.sha_b, "caveats": [], "state": "delivered",
            }],
        }
        self.store.state["credentialChecks"] = {"repo": {"git_ok": True, "gh_ok": True}}

        self.store.state["revisions"] = {"requirements": self.spec_revision, "plan": self.plan_revision}
        self.store.state["approval"] = {"revision": self.spec_revision, "questionId": "question-0", "by": "human", "at": "2026-01-01T00:00:00+00:00", "writer": "program"}
        self.store.state["questions"]["answered"]["question-0"] = {"value": "approve", "by": "human", "phase": "spec", "attempt": "attempt-spec", "answeredAt": "2026-01-01T00:00:00+00:00"}

        def _wrap(exit_, product):
            return {"attemptId": "attempt-0", "inputsDigest": "sha256:" + "0" * 64, "boundTo": product["boundTo"],
                    "exit": exit_, "product": product, "receivedAt": "2026-01-01T00:00:00+00:00", "evidenceLevel": "human-attested"}

        self.store.state["products"]["spec"] = _wrap("approved", self.spec_product)
        self.store.state["products"]["plan"] = _wrap("ready", self.plan_product)
        self.store.state["products"]["execute"] = _wrap("integrated", self.execute_product)
        self.store.state["products"]["verify"] = _wrap("passed", self.verify_product)
        self.store.save()

    def _boundary(self, phase, product, exit_) -> postconditions.Boundary:
        return postconditions.Boundary(self.store, self.paths, phase=phase, product=product, exit=exit_, project_root=self.repo_dir)

    def _second_repo(self) -> tuple[str, str]:
        # LF-28: same shape as test_e4_workspace_filters_tasks_by_repo's own second
        # repo, registered under "other" for the V3/I1 two-repo tests.
        other = Path(self._tmp.name) / "other"
        other.mkdir()
        _git(other, "init", "-q", "-b", "main")
        _git(other, "config", "user.email", "test@example.com")
        _git(other, "config", "user.name", "Test")
        (other / "a.txt").write_text("a\n", encoding="utf-8")
        _git(other, "add", "a.txt")
        _git(other, "commit", "-q", "-m", "base")
        other_base = _rev_parse(other)
        _git(other, "checkout", "-q", "-b", "feat/x")
        (other / "b.txt").write_text("b\n", encoding="utf-8")
        _git(other, "add", "b.txt")
        _git(other, "commit", "-q", "-m", "T-9")
        other_head = _rev_parse(other)
        self.store.state["repos"]["other"] = {
            "path": str(other), "baseSha": other_base, "featureBranch": "feat/x",
            "defaultBranch": "main", "lastKnownHead": other_base,
        }
        return other_base, other_head

    # -- S: SPEC ---------------------------------------------------------

    def test_s1(self):
        self.assertIsNone(self._boundary("spec", self.spec_product, "approved")._s1())
        bad = copy.deepcopy(self.spec_product)
        del bad["goal"]
        self.assertIsNotNone(self._boundary("spec", bad, "approved")._s1())

    def test_s2(self):
        self.assertIsNone(self._boundary("spec", self.spec_product, "approved")._s2())
        self.store.state["approval"] = None
        self.assertIsNotNone(self._boundary("spec", self.spec_product, "approved")._s2())

    def test_s3(self):
        self.assertIsNone(self._boundary("spec", self.spec_product, "approved")._s3())
        bad = copy.deepcopy(self.spec_product)
        bad["approved"] = True
        self.assertIsNotNone(self._boundary("spec", bad, "approved")._s3())

    # -- P: PLAN -----------------------------------------------------------

    def test_p1(self):
        self.assertIsNone(self._boundary("plan", self.plan_product, "ready")._p1())
        bad = copy.deepcopy(self.plan_product)
        bad["boundTo"]["requirements"] = "sha256:" + "9" * 64
        self.assertIsNotNone(self._boundary("plan", bad, "ready")._p1())

    def test_p2(self):
        self.assertIsNone(self._boundary("plan", self.plan_product, "ready")._p2())
        bad = copy.deepcopy(self.plan_product)
        bad["tasks"][1]["criteria"] = []
        self.assertIsNotNone(self._boundary("plan", bad, "ready")._p2())

    def test_p3(self):
        self.assertIsNone(self._boundary("plan", self.plan_product, "ready")._p3())
        self.store.state["baseline"] = None
        self.assertIsNotNone(self._boundary("plan", self.plan_product, "ready")._p3())

    def test_p3_rejects_a_shell_command_before_consulting_the_baseline(self):
        # LF-53: the live shape -- a featureAdded task, which the baseline never runs.
        bad = copy.deepcopy(self.plan_product)
        bad["tasks"][0]["featureAdded"] = "tests/test_clamp.py"
        bad["tasks"][0]["verify"] = "git diff --quiet abc -- tests/test_calc.py && python -m pytest -q tests/test_clamp.py"
        message = self._boundary("plan", bad, "ready")._p3()
        self.assertIn(f"task {bad['tasks'][0]['id']}: verify command uses the shell operator '&&'", message)

        bad = copy.deepcopy(self.plan_product)
        bad["tasks"][0]["verify"] = "pytest -q | tee out"
        self.assertIn("'|'", self._boundary("plan", bad, "ready")._p3())

        bad = copy.deepcopy(self.plan_product)
        bad["prepare"] = "cd x && make"
        self.assertIn("prepare command uses the shell operator '&&'", self._boundary("plan", bad, "ready")._p3())

    def test_p4(self):
        self.assertIsNone(self._boundary("plan", self.plan_product, "ready")._p4())
        self.store.state["baseline"]["baseSha"] = "z" * 40
        self.assertIsNotNone(self._boundary("plan", self.plan_product, "ready")._p4())

    def test_p5(self):
        self.assertIsNone(self._boundary("plan", self.plan_product, "ready")._p5())
        bad = copy.deepcopy(self.plan_product)
        bad["tasks"][0]["dependsOn"] = ["T-2"]  # T-1 <-> T-2 cycle
        self.assertIsNotNone(self._boundary("plan", bad, "ready")._p5())

    def test_p6(self):
        self.assertIsNone(self._boundary("plan", self.plan_product, "ready")._p6())
        bad = copy.deepcopy(self.plan_product)
        bad["tasks"][0]["repo"] = "bogus"
        self.assertIsNotNone(self._boundary("plan", bad, "ready")._p6())

    def test_p7(self):
        self.assertIsNone(self._boundary("plan", self.plan_product, "ready")._p7())
        self.store.state["critic"] = None
        self.assertIsNotNone(self._boundary("plan", self.plan_product, "ready")._p7())

    # -- E: EXECUTE ----------------------------------------------------------

    def test_e1(self):
        self.assertIsNone(self._boundary("execute", self.execute_product, "integrated")._e1())
        bad = copy.deepcopy(self.execute_product)
        bad["boundTo"]["plan"] = "sha256:" + "9" * 64
        self.assertIsNotNone(self._boundary("execute", bad, "integrated")._e1())

    def test_e2(self):
        self.assertIsNone(self._boundary("execute", self.execute_product, "integrated")._e2())
        bad = copy.deepcopy(self.execute_product)
        del bad["tasks"][1]
        self.assertIsNotNone(self._boundary("execute", bad, "integrated")._e2())

    def test_e3(self):
        self.assertIsNone(self._boundary("execute", self.execute_product, "integrated")._e3())
        bad = copy.deepcopy(self.execute_product)
        bad["tasks"][0]["disposition"] = "removed"  # T-2 depends on an un-accepted T-1
        self.assertIsNotNone(self._boundary("execute", bad, "integrated")._e3())

    def test_e4(self):
        self.assertIsNone(self._boundary("execute", self.execute_product, "integrated")._e4())
        bad = copy.deepcopy(self.execute_product)
        bad["tasks"][1]["commits"] = []  # sha_b no longer claimed by any task
        self.assertIsNotNone(self._boundary("execute", bad, "integrated")._e4())

    def test_e4_counts_an_adopted_prs_commits_as_mapped(self):
        # LF-44: a revise run whose reviser did not carry the delivering plan's tasks
        # forward still passes E4 for the adopted PR's own commits.
        product = copy.deepcopy(self.execute_product)
        product["tasks"] = [product["tasks"][1]]  # only the new work (sha_b) is claimed
        self.assertIsNotNone(self._boundary("execute", product, "integrated")._e4())
        self.store.state["adoption"] = {"repo": "repo", "baseSha": self.base_sha, "headSha": self.sha_a}
        self.assertIsNone(self._boundary("execute", product, "integrated")._e4())
        self.store.state["adoption"]["repo"] = "other"
        self.assertIsNotNone(self._boundary("execute", product, "integrated")._e4())

    def test_e4_workspace_filters_tasks_by_repo(self):
        # LF-24: a second repo whose task commit is unknown to the first must not be
        # unioned into the first repo's coverage check.
        other = Path(self._tmp.name) / "other"
        other.mkdir()
        _git(other, "init", "-q", "-b", "main")
        _git(other, "config", "user.email", "test@example.com")
        _git(other, "config", "user.name", "Test")
        (other / "a.txt").write_text("a\n", encoding="utf-8")
        _git(other, "add", "a.txt")
        _git(other, "commit", "-q", "-m", "base")
        other_base = _rev_parse(other)
        _git(other, "checkout", "-q", "-b", "feat/x")
        (other / "b.txt").write_text("b\n", encoding="utf-8")
        _git(other, "add", "b.txt")
        _git(other, "commit", "-q", "-m", "T-9")
        other_head = _rev_parse(other)
        self.store.state["repos"]["other"] = {"path": str(other), "baseSha": other_base, "featureBranch": "feat/x", "defaultBranch": "main", "lastKnownHead": other_base}
        plan = self.store.state["products"]["plan"]["product"]
        plan["tasks"].append({**plan["tasks"][0], "id": "T-9", "repo": "other"})
        product = copy.deepcopy(self.execute_product)
        product["tasks"].append({"id": "T-9", "disposition": "done", "evidence": None, "commits": [other_head], "review": copy.deepcopy(product["tasks"][0]["review"])})
        product["heads"]["other"] = other_head
        self.assertIsNone(self._boundary("execute", product, "integrated")._e4())

    def test_e5(self):
        self.assertIsNone(self._boundary("execute", self.execute_product, "integrated")._e5())
        bad = copy.deepcopy(self.execute_product)
        bad["tasks"][0]["review"] = None
        self.assertIsNotNone(self._boundary("execute", bad, "integrated")._e5())

    def test_e6(self):
        self.assertIsNone(self._boundary("execute", self.execute_product, "integrated")._e6())
        self.store.state["implementations"]["phases"]["execute"] = "default"
        self.assertIsNotNone(self._boundary("execute", self.execute_product, "integrated")._e6())

        # evidence.review.accept: "unattested" (roadmap 5) accepts what the default
        # branch above just refused, and records it as weakened assurance per task.
        config_dir = self.repo_dir / ".loop-spec"
        config_dir.mkdir()
        atomic_write_json(config_dir / "config.json", {"evidence": {"review": {"accept": "unattested"}}})
        boundary = self._boundary("execute", self.execute_product, "integrated")
        self.assertIsNone(boundary._e6())
        accepted_tasks = [t["id"] for t in self.execute_product["tasks"] if t["disposition"] in ("done", "adopted")]
        self.assertEqual(
            boundary.weakened_assurance,
            [{"kind": "evidence.review.accept", "value": "unattested", "task": t} for t in accepted_tasks],
        )

    def test_e5_and_e6_accept_an_adopted_task_through_the_adopted_range_review(self):
        # LF-42: an adopted task has no review step of its own; its review is the
        # adopted-range review and its evidence is that step's submission.
        adopted_review = {"reviewedRange": {"from": self.base_sha, "to": self.sha_b}, "verdict": "pass",
                          "findings": [], "securityDispositions": [], "sha": self.sha_b}
        product = copy.deepcopy(self.execute_product)
        product["tasks"][0].update({"disposition": "adopted", "review": copy.deepcopy(adopted_review)})
        self.store.state["implementations"]["phases"]["execute"] = "default"
        self.store.state["adoptedReview"] = adopted_review
        self.store.state["phase"]["adoptedReviewStepId"] = "step-adopted"
        self.store.state["steps"]["submissions"]["step-adopted"] = {"evidenceLevel": "host-attested"}
        self.store.state.setdefault("execute", {})["tasks"] = {
            "T-1": {"status": "adopted", "reviewSteps": []},
            "T-2": {"status": "done", "reviewSteps": ["step-t2"]},
        }
        self.store.state["steps"]["submissions"]["step-t2"] = {"evidenceLevel": "host-attested"}
        boundary = self._boundary("execute", product, "integrated")
        self.assertIsNone(boundary._e5())
        self.assertIsNone(boundary._e6())
        product["tasks"][0]["review"] = None
        self.assertEqual(self._boundary("execute", product, "integrated")._e5(), "task T-1 has no passing review")

    def test_e7(self):
        self.assertIsNone(self._boundary("execute", self.execute_product, "integrated")._e7())
        self.store.state["executeRuns"]["T-1"]["comparison"]["verdict"] = "regression"
        self.assertIsNotNone(self._boundary("execute", self.execute_product, "integrated")._e7())

    def test_e8(self):
        self.assertIsNone(self._boundary("execute", self.execute_product, "integrated")._e8())
        self.store.state["repos"]["repo"]["featureBranch"] = "main"  # main sits at base, not head
        self.assertIsNotNone(self._boundary("execute", self.execute_product, "integrated")._e8())

    def test_e9(self):
        no_change = {
            "exit": "no change", "inputsDigest": "sha256:" + "0" * 64,
            "boundTo": {"requirements": self.spec_revision, "plan": self.plan_revision},
            "tasks": [
                {"id": "T-1", "disposition": "already-satisfied", "evidence": "no diff needed", "commits": [], "review": None},
                {"id": "T-2", "disposition": "already-satisfied", "evidence": "no diff needed", "commits": [], "review": None},
            ],
            "issues": [], "heads": {"repo": self.base_sha},
        }
        self.assertIsNone(self._boundary("execute", no_change, "no change")._e9())
        bad = copy.deepcopy(no_change)
        bad["tasks"][0]["disposition"] = "done"
        self.assertIsNotNone(self._boundary("execute", bad, "no change")._e9())

    def test_e10(self):
        blocked = copy.deepcopy(self.execute_product)
        blocked["issues"] = [{"task": "T-1", "text": "still failing"}]
        self.assertIsNotNone(self._boundary("execute", blocked, "blocked")._e10())  # retries below the limit
        self.store.state["phase"]["retries"] = postconditions.retry_limit()
        self.assertIsNone(self._boundary("execute", blocked, "blocked")._e10())

    def test_e10_accepts_a_task_that_exhausted_its_own_retries(self):
        # LF-40: the task's per-step retries count, not only the phase's rejections.
        blocked = copy.deepcopy(self.execute_product)
        blocked["issues"] = [{"task": "T-1", "text": "no commit was made on the task branch"}]
        self.store.state["phase"]["retries"] = 0
        self.store.state["execute"] = {"tasks": {"T-1": {"retries": postconditions.retry_limit() + 1}}}
        self.assertIsNone(self._boundary("execute", blocked, "blocked")._e10())
        self.store.state["execute"]["tasks"]["T-1"]["retries"] = 1
        self.assertIsNotNone(self._boundary("execute", blocked, "blocked")._e10())

    def test_e11(self):
        # M1: probes.securitySignals is empty, so E11 always holds until a signal exists.
        self.assertIsNone(self._boundary("execute", self.execute_product, "integrated")._e11())
        self.store.state["probes"] = {"securitySignals": ["a.txt"]}
        self.assertIsNotNone(self._boundary("execute", self.execute_product, "integrated")._e11())  # T-1 touches a.txt with no disposition
        fixed = copy.deepcopy(self.execute_product)
        fixed["tasks"][0]["review"]["securityDispositions"] = [{"signal": "a.txt", "disposition": "accepted", "reason": "reviewed"}]
        self.assertIsNone(self._boundary("execute", fixed, "integrated")._e11())

    # -- V: VERIFY ---------------------------------------------------------

    def test_v1(self):
        self.assertIsNone(self._boundary("verify", self.verify_product, "passed")._v1())
        bad = copy.deepcopy(self.verify_product)
        bad["boundTo"]["requirements"] = "sha256:" + "9" * 64
        self.assertIsNotNone(self._boundary("verify", bad, "passed")._v1())

    def test_v2(self):
        self.assertIsNone(self._boundary("verify", self.verify_product, "passed")._v2())
        bad = copy.deepcopy(self.verify_product)
        del bad["verdicts"][1]
        self.assertIsNotNone(self._boundary("verify", bad, "passed")._v2())

    def test_v3(self):
        self.assertIsNone(self._boundary("verify", self.verify_product, "passed")._v3())
        bad = copy.deepcopy(self.verify_product)
        bad["verdicts"][0]["evidence"]["sha"] = self.sha_a
        self.assertIsNotNone(self._boundary("verify", bad, "passed")._v3())

    def test_v3_two_repos(self):
        # LF-28: each verdict's evidence is checked against ITS OWN repo's head --
        # a single global head would have missed a verdict naming the wrong one.
        other_base, other_head = self._second_repo()
        execute_product = copy.deepcopy(self.execute_product)
        execute_product["heads"]["other"] = other_head
        self.store.state["products"]["execute"]["product"] = execute_product

        product = copy.deepcopy(self.verify_product)
        product["verdicts"][1]["evidence"]["repo"] = "other"
        product["verdicts"][1]["evidence"]["sha"] = other_head
        self.assertIsNone(self._boundary("verify", product, "passed")._v3())

        bad = copy.deepcopy(product)
        bad["verdicts"][1]["evidence"]["sha"] = self.sha_b  # "repo"'s head, claimed for "other"
        self.assertIsNotNone(self._boundary("verify", bad, "passed")._v3())

    def test_v4(self):
        self.assertIsNone(self._boundary("verify", self.verify_product, "passed")._v4())
        del self.store.state["verifyRuns"]["AC-1"]
        message = self._boundary("verify", self.verify_product, "passed")._v4()
        self.assertEqual(message, "criterion AC-1: no matching re-run recorded")

    def test_v4_rejects_a_shell_evidence_command_even_when_exempt(self):
        # LF-53: command form is checked before the exception skip.
        product = copy.deepcopy(self.verify_product)
        product["verdicts"][0]["evidence"]["command"] = "pytest -q && echo ok"
        message = self._boundary("verify", product, "passed")._v4()
        self.assertEqual(
            message,
            f"criterion {product['verdicts'][0]['criterion']}: evidence command uses the shell operator '&&'; "
            "commands run as argv with no shell",
        )
        self.store.state["verifyExceptionsThisAttempt"] = [{"criterion": product["verdicts"][0]["criterion"], "reason": "operator approved"}]
        self.assertIsNotNone(self._boundary("verify", product, "passed")._v4())

    def test_v4_mismatch_message_names_the_cause(self):
        self.store.state["verifyRuns"]["AC-1"] = {
            "rerun": {"cwd": "/tmp/verify-AC-1-abc123", "exitStatus": 127},
            "matched": False, "reason": "exitStatus differs",
        }
        message = self._boundary("verify", self.verify_product, "passed")._v4()
        self.assertEqual(
            message,
            "criterion AC-1: the program's re-run differs from the claim: exitStatus differs "
            "(claimed exit 0, re-run exit 127 in verify-AC-1-abc123; an exit of 127 means the "
            "command was not found in the clean checkout)",
        )

    def test_v4_skips_an_operator_approved_exception_without_raising(self):
        # R10: verifyExceptionsThisAttempt is a list of {"criterion", "reason"}
        # objects (the same shape V5 already reads); building a set straight
        # from that list used to raise TypeError: unhashable type: 'dict'.
        # AC-1's own verifyRuns entry is removed too, since an exempt criterion
        # must never need one to pass.
        self.store.state["verifyExceptionsThisAttempt"] = [{"criterion": "AC-1", "reason": "operator approved"}]
        del self.store.state["verifyRuns"]["AC-1"]
        self.assertIsNone(self._boundary("verify", self.verify_product, "passed")._v4())

    def test_v5(self):
        # No failing branch exists: _v5 only records exceptions, it never rejects.
        boundary = self._boundary("verify", self.verify_product, "passed")
        self.assertIsNone(boundary._v5())
        self.assertEqual(boundary.weakened_assurance, [])

        # Each source gets its own entry, kept as an object like E6's own
        # weakenedAssurance entries (never a bare criterion id).
        plan_with_exception = copy.deepcopy(self.plan_product)
        plan_with_exception["evidenceExceptions"] = [{"criterion": "AC-1", "reason": "flaky in CI"}]
        self.store.state["products"]["plan"]["product"] = plan_with_exception
        self.store.state["verifyExceptionsThisAttempt"] = [{"criterion": "AC-2", "reason": "operator approved at VERIFY"}]
        boundary = self._boundary("verify", self.verify_product, "passed")
        self.assertIsNone(boundary._v5())
        self.assertEqual(boundary.weakened_assurance, [
            {"kind": "evidence.exception", "criterion": "AC-1", "source": "plan", "reason": "flaky in CI"},
            {"kind": "evidence.exception", "criterion": "AC-2", "source": "answer", "reason": "operator approved at VERIFY"},
        ])

    def test_v6(self):
        blocked = copy.deepcopy(self.verify_product)
        blocked["verdicts"][0]["verdict"] = "blocked"
        blocked["verdicts"][0]["cause"] = "the runner errored"
        self.assertIsNotNone(self._boundary("verify", blocked, "blocked")._v6())  # no run recorded an errorClass
        self.store.state["verifyRuns"]["AC-1"]["errorClass"] = "runner-error"
        self.assertIsNone(self._boundary("verify", blocked, "blocked")._v6())

    def test_v7(self):
        self.assertIsNone(self._boundary("verify", self.verify_product, "passed")._v7())
        bad = copy.deepcopy(self.verify_product)
        bad["findings"] = [{"id": "f-1", "location": "a.txt:1", "cause": "c", "severity": "Critical", "disposition": "open", "reason": None, "supersedes": None}]
        self.assertIsNotNone(self._boundary("verify", bad, "passed")._v7())

    def test_v7_accepts_a_final_passs_full_range_after_a_prior_delta(self):
        # LF-47: a final pass reviews base..head in full, same as a first pass --
        # its own "from" is the repo's base SHA, not a continuation of whatever
        # delta the last pass reviewed.
        self.store.state["ledger"]["reviewedRanges"] = [
            {"id": "range-1", "repo": "repo", "from": self.base_sha, "to": self.sha_a, "full": True},
        ]
        full_pass = copy.deepcopy(self.verify_product)
        full_pass["reviewedRanges"] = [{"repo": "repo", "from": self.base_sha, "to": self.sha_b, "full": True}]
        self.assertIsNone(self._boundary("verify", full_pass, "passed")._v7())

        # A range restarting from base without declaring itself full is still
        # rejected: "full" is what excuses a "from" other than the last "to".
        not_full = copy.deepcopy(full_pass)
        not_full["reviewedRanges"] = [{"repo": "repo", "from": self.base_sha, "to": self.sha_b, "full": False}]
        self.assertIsNotNone(self._boundary("verify", not_full, "passed")._v7())

    def test_v8(self):
        self.store.state["ledger"]["reviewedRanges"] = [{"id": "range-1", "repo": "repo", "from": self.base_sha, "to": self.sha_a, "full": False}]
        finding = {"id": "f-1", "location": "a.txt:1", "cause": "c", "severity": "Minor", "disposition": "open", "reason": None, "supersedes": None}
        product = dict(self.verify_product, findings=[finding])
        self.assertIsNotNone(self._boundary("verify", product, "passed")._v8())
        finding["supersedes"] = {"kind": "range", "id": "range-1"}
        self.assertIsNone(self._boundary("verify", product, "passed")._v8())

    def test_v8_carried_forward_open_finding_needs_no_supersedes(self):
        self.store.state["ledger"]["reviewedRanges"] = [{"id": "range-1", "repo": "repo", "from": self.base_sha, "to": self.sha_a, "full": False}]
        self.store.state["ledger"]["findings"] = [
            {"id": "f-1", "repo": "repo", "location": "a.txt:1", "cause": "c", "severity": "Minor", "disposition": "open", "reason": None, "supersedes": None},
        ]
        finding = {"id": "f-1", "repo": "repo", "location": "a.txt:1", "cause": "c", "severity": "Minor", "disposition": "open", "reason": None, "supersedes": None}
        product = dict(self.verify_product, findings=[finding])
        self.assertIsNone(self._boundary("verify", product, "passed")._v8())

    def test_v8_same_id_from_another_repo_is_not_carried_forward(self):
        other_base, other_head = self._second_repo()
        self.store.state["ledger"]["reviewedRanges"] = [{"id": "range-other", "repo": "other", "from": other_base, "to": other_head, "full": True}]
        self.store.state["ledger"]["findings"] = [
            {"id": "f-1", "repo": "repo", "location": "a.txt:1", "cause": "c", "severity": "Minor", "disposition": "open", "reason": None, "supersedes": None},
        ]
        finding = {"id": "f-1", "repo": "other", "location": "b.txt:1", "cause": "c", "severity": "Minor", "disposition": "open", "reason": None, "supersedes": None}
        product = dict(self.verify_product, findings=[finding])
        self.assertIsNotNone(self._boundary("verify", product, "passed")._v8())

    def test_v8_a_range_id_used_as_a_finding_id_is_not_carried_forward(self):
        self.store.state["ledger"]["reviewedRanges"] = [{"id": "range-1", "repo": "repo", "from": self.base_sha, "to": self.sha_a, "full": False}]
        finding = {"id": "range-1", "repo": "repo", "location": "a.txt:1", "cause": "c", "severity": "Minor", "disposition": "open", "reason": None, "supersedes": None}
        product = dict(self.verify_product, findings=[finding])
        self.assertIsNotNone(self._boundary("verify", product, "passed")._v8())

    def test_v8_a_fresh_finding_supersedes_a_closed_finding(self):
        self.store.state["ledger"]["reviewedRanges"] = [{"id": "range-1", "repo": "repo", "from": self.base_sha, "to": self.sha_a, "full": False}]
        self.store.state["ledger"]["findings"] = [
            {"id": "f-old", "repo": "repo", "location": "a.txt:1", "cause": "c", "severity": "Minor", "disposition": "fixed", "reason": "patched", "supersedes": None},
        ]
        finding = {"id": "f-new", "repo": "repo", "location": "a.txt:1", "cause": "c", "severity": "Minor",
                   "disposition": "open", "reason": None, "supersedes": {"kind": "finding", "id": "f-old"}}
        product = dict(self.verify_product, findings=[finding])
        self.assertIsNone(self._boundary("verify", product, "passed")._v8())

    def test_v7_a_valid_closure_of_an_open_critical_passes(self):
        self.store.state["ledger"]["findings"] = [
            {"id": "f-1", "repo": "repo", "location": "a.txt:1", "cause": "c", "severity": "Critical", "disposition": "open", "reason": None, "supersedes": None},
        ]
        closing = {"id": "f-1", "repo": "repo", "location": "a.txt:1", "cause": "c", "severity": "Critical", "disposition": "fixed", "reason": "patched", "supersedes": None}
        product = dict(self.verify_product, findings=[closing])
        self.assertIsNone(self._boundary("verify", product, "passed")._v7())
        self.assertEqual(self.store.state["ledger"]["findings"][0]["disposition"], "open")  # V7 wrote nothing

    def test_v7_a_closure_on_a_different_location_still_blocks(self):
        self.store.state["ledger"]["findings"] = [
            {"id": "f-1", "repo": "repo", "location": "a.txt:1", "cause": "c", "severity": "Critical", "disposition": "open", "reason": None, "supersedes": None},
        ]
        closing = {"id": "f-1", "repo": "repo", "location": "b.txt:1", "cause": "c", "severity": "Critical", "disposition": "fixed", "reason": "patched", "supersedes": None}
        product = dict(self.verify_product, findings=[closing])
        self.assertIsNotNone(self._boundary("verify", product, "passed")._v7())

    def test_v7_a_closure_with_no_reason_still_blocks(self):
        self.store.state["ledger"]["findings"] = [
            {"id": "f-1", "repo": "repo", "location": "a.txt:1", "cause": "c", "severity": "Critical", "disposition": "open", "reason": None, "supersedes": None},
        ]
        closing = {"id": "f-1", "repo": "repo", "location": "a.txt:1", "cause": "c", "severity": "Critical", "disposition": "fixed", "reason": "", "supersedes": None}
        product = dict(self.verify_product, findings=[closing])
        self.assertIsNotNone(self._boundary("verify", product, "passed")._v7())

    def test_v9(self):
        blocked = copy.deepcopy(self.verify_product)
        blocked["verdicts"][0]["verdict"] = "blocked"
        blocked["verdicts"][0]["cause"] = "the network is offline"
        self.assertIsNotNone(self._boundary("verify", blocked, "blocked")._v9())
        blocked["standInTried"] = ["AC-1"]
        self.assertIsNone(self._boundary("verify", blocked, "blocked")._v9())

    # -- I: ITERATE ----------------------------------------------------------

    def test_i1(self):
        self.assertIsNone(self._boundary("iterate", self.iterate_product, "converged")._i1())
        bad = copy.deepcopy(self.iterate_product)
        bad["boundShas"] = {"repo": self.sha_a}
        self.assertIsNotNone(self._boundary("iterate", bad, "converged")._i1())

    def test_i1_two_repos(self):
        # LF-28: I1 checks every repo's own boundShas entry, not just the first.
        other_base, other_head = self._second_repo()
        execute_product = copy.deepcopy(self.execute_product)
        execute_product["heads"]["other"] = other_head
        self.store.state["products"]["execute"]["product"] = execute_product

        product = copy.deepcopy(self.iterate_product)
        product["boundShas"]["other"] = other_head
        self.assertIsNone(self._boundary("iterate", product, "converged")._i1())

        bad = copy.deepcopy(product)
        bad["boundShas"]["other"] = other_base  # unbound to the EXECUTE head
        self.assertIsNotNone(self._boundary("iterate", bad, "converged")._i1())

    def test_i2(self):
        self.assertIsNone(self._boundary("iterate", self.iterate_product, "converged")._i2())
        bad = copy.deepcopy(self.iterate_product)
        bad["gaps"] = [{"target": "debug", "text": "nope"}]
        self.assertIsNotNone(self._boundary("iterate", bad, "converged")._i2())

    def test_i3(self):
        self.assertIsNone(self._boundary("iterate", self.iterate_product, "converged")._i3())
        budget_module.spend(self.store, from_phase="plan", exit="spec gap", to_phase="spec", attempt_id="a-1", reason="gap")
        budget_module.spend(self.store, from_phase="plan", exit="spec gap", to_phase="spec", attempt_id="a-2", reason="gap")
        self.assertIsNotNone(self._boundary("iterate", self.iterate_product, "converged")._i3())

    def test_i4(self):
        escalated = copy.deepcopy(self.iterate_product)
        escalated["exit"] = "escalated"
        escalated["verdict"] = "unmet"
        # No gap at all (the fixture's own "gaps": []): an unclosable gap, valid
        # grounds for "escalated" on its own, regardless of budget room.
        self.assertIsNone(self._boundary("iterate", escalated, "escalated")._i4())

        # A gap the router could still act on, with room left to rewind into:
        # neither branch justifies "escalated" yet.
        routable = copy.deepcopy(escalated)
        routable["gaps"] = [{"target": "plan", "text": "missing a case"}]
        self.assertIsNotNone(self._boundary("iterate", routable, "escalated")._i4())

        # Budget exhausted: the refused-rewind branch passes regardless of gaps.
        budget_module.spend(self.store, from_phase="plan", exit="spec gap", to_phase="spec", attempt_id="a-1", reason="gap")
        budget_module.spend(self.store, from_phase="plan", exit="spec gap", to_phase="spec", attempt_id="a-2", reason="gap")
        self.assertIsNone(self._boundary("iterate", routable, "escalated")._i4())

    def test_i5(self):
        self.assertIsNone(self._boundary("iterate", self.iterate_product, "converged")._i5())
        self.store.state["ledger"]["findings"] = [{"id": "f-1", "location": "a.txt:1", "cause": "c", "severity": "Minor", "disposition": "open", "reason": None, "supersedes": None}]
        self.assertIsNotNone(self._boundary("iterate", self.iterate_product, "converged")._i5())

    def test_i6(self):
        with_caveats = copy.deepcopy(self.iterate_product)
        with_caveats["exit"] = "converged with caveats"
        self.assertIsNotNone(self._boundary("iterate", with_caveats, "converged with caveats")._i6())  # no caveats named
        self.store.state["ledger"]["findings"] = [{"id": "f-1", "location": "a.txt:1", "cause": "c", "severity": "Minor", "disposition": "deferred", "reason": "acceptable", "supersedes": None}]
        with_caveats["caveats"] = ["f-1"]
        self.assertIsNone(self._boundary("iterate", with_caveats, "converged with caveats")._i6())

    # -- D: DELIVER ----------------------------------------------------------

    def test_d1_record_missing(self):
        bad = copy.deepcopy(self.deliver_product)
        bad["repos"][0]["repo"] = "bogus"
        self.assertIsNotNone(self._boundary("deliver", bad, "delivered")._d1())

    def test_d2_record_missing(self):
        with patch.object(repo_module, "run_gh", lambda *a: (1, "", "no such pr")):
            self.assertIsNotNone(self._boundary("deliver", self.deliver_product, "delivered")._d2())

    def test_d3_record_missing(self):
        config_dir = self.repo_dir / ".loop-spec"
        config_dir.mkdir()
        atomic_write_json(config_dir / "config.json", {"deliver": {"readiness": "checks"}})
        with patch.object(repo_module, "run_gh", lambda *a: (1, "", "checks pending")):
            self.assertIsNotNone(self._boundary("deliver", self.deliver_product, "delivered")._d3())

    def test_d4(self):
        self.assertIsNone(self._boundary("deliver", self.deliver_product, "delivered")._d4())
        self.store.state["deliverAttempts"] = {"repo": 2}
        self.assertIsNotNone(self._boundary("deliver", self.deliver_product, "delivered")._d4())

    def test_d5(self):
        mixed = {"repos": [{"state": "delivered"}, {"state": "failed"}]}
        self.assertIsNone(self._boundary("deliver", mixed, "partially delivered")._d5())
        all_delivered = {"repos": [{"state": "delivered"}, {"state": "delivered"}]}
        self.assertIsNotNone(self._boundary("deliver", all_delivered, "partially delivered")._d5())

    def test_d6(self):
        skipped = {"repos": [{"repo": "repo", "pr": None, "state": "skipped"}]}
        self.assertIsNone(self._boundary("deliver", skipped, "delivered")._d6())
        not_skipped = {"repos": [{"repo": "repo", "pr": {"number": 1}, "state": "skipped"}]}
        self.assertIsNotNone(self._boundary("deliver", not_skipped, "delivered")._d6())

    def test_d7(self):
        self.assertIsNone(self._boundary("deliver", self.deliver_product, "delivered")._d7())
        self.store.state["credentialChecks"] = {}
        self.assertIsNotNone(self._boundary("deliver", self.deliver_product, "delivered")._d7())

    # -- B: debug (not runnable until M4; the checks exist now) --------------

    def test_b1(self):
        # LF-23: B1 holds on the program's own clean-checkout run, never on comparing
        # the worker's failureDigest against it (the checkouts differ, so a digest
        # comparison could never match).
        self.assertIsNotNone(self._boundary("debug", {"reproduction": {"command": "pytest -q", "failureDigest": "sha256:" + "d" * 64}}, "reproduced")._b1())
        self.store.state["debug"] = {"baseRun": {"exitStatus": 1, "errorClass": None, "failureIdentities": ["boom"], "fingerprints": []}}
        self.assertIsNone(self._boundary("debug", {"reproduction": {"command": "pytest -q", "failureDigest": "sha256:" + "d" * 64}}, "reproduced")._b1())

        self.store.state["debug"] = {"baseRun": {"exitStatus": 127, "errorClass": "command-not-found"}}
        self.assertIn("could not run at base", self._boundary("debug", {}, "reproduced")._b1())

        self.store.state["debug"] = {"baseRun": {"exitStatus": 0, "errorClass": None}}
        self.assertIn("passed at base", self._boundary("debug", {}, "reproduced")._b1())

        self.store.state["debug"] = {"baseRun": {"exitStatus": 1, "errorClass": None, "failureIdentities": [], "fingerprints": []}}
        self.assertIsNotNone(self._boundary("debug", {}, "reproduced")._b1())

        # LF-53: a shell reproduction is rejected on its form, whatever the base run says.
        self.store.state["debug"] = {"baseRun": {"exitStatus": 1, "errorClass": None, "failureIdentities": ["boom"], "fingerprints": []}}
        product = {"reproduction": {"command": "cd pkg && pytest -q", "failureDigest": "sha256:" + "d" * 64}}
        self.assertIn("reproduction command uses the shell operator '&&'", self._boundary("debug", product, "reproduced")._b1())

    def test_b2(self):
        changed = {"original": {"command": "pytest -q"}, "reproduction": {"reason": None}}
        self.assertIsNotNone(self._boundary("debug", changed, "reproduced")._b2())
        changed["reproduction"]["reason"] = "the failure moved files"
        self.store.state["debug"] = {"originalRun": {"exitStatus": 1, "errorClass": None, "failureIdentities": ["x"], "fingerprints": []}}
        self.assertIsNone(self._boundary("debug", changed, "reproduced")._b2())
        # Same normalization as B1: an original run that passed at base does not hold.
        self.store.state["debug"] = {"originalRun": {"exitStatus": 0, "errorClass": None}}
        self.assertIsNotNone(self._boundary("debug", changed, "reproduced")._b2())
        # LF-53: the original command is checked on its form too.
        changed["original"]["command"] = "pytest -q; true"
        self.assertIn("original command uses the shell operator ';'", self._boundary("debug", changed, "reproduced")._b2())

    def test_b3(self):
        self.assertIsNotNone(self._boundary("debug", {"reproduction": {"anything": True}}, "blocked reproduction")._b3())
        self.assertIsNone(self._boundary("debug", {}, "blocked reproduction")._b3())

    # -- T1: shared budget -----------------------------------------------

    def test_t1(self):
        self.assertIsNone(self._boundary("iterate", self.iterate_product, "converged")._t1())
        budget_module.spend(self.store, from_phase="plan", exit="spec gap", to_phase="spec", attempt_id="a-1", reason="gap")
        budget_module.spend(self.store, from_phase="plan", exit="spec gap", to_phase="spec", attempt_id="a-2", reason="gap")
        self.assertIsNotNone(self._boundary("iterate", self.iterate_product, "converged")._t1())

    # --- LF-55: close-outs --------------------------------------------------

    def _close_out(self, cid="C-1", repo="repo", closure=None):
        entry = {"id": cid, "source": {"phase": "iterate", "attemptId": "it-1", "gapIndex": 0, "findingId": None},
                 "text": "rename the helper", "repo": repo, "registeredRevisions": {}, "status": "active",
                 "closure": closure, "history": []}
        self.store.state.setdefault("closeOuts", []).append(entry)
        return entry

    def _with_close_out_commit(self):
        (self.repo_dir / "c.txt").write_text("c\n", encoding="utf-8")
        _git(self.repo_dir, "add", "c.txt")
        _git(self.repo_dir, "commit", "-q", "-m", "C-1")
        sha_c = _rev_parse(self.repo_dir)
        product = copy.deepcopy(self.execute_product)
        product["heads"] = {"repo": sha_c}
        review = {"reviewedRange": {"from": self.sha_b, "to": sha_c}, "verdict": "pass", "findings": [], "securityDispositions": []}
        product["tasks"].append({"id": "C-1", "disposition": "done", "evidence": None, "commits": [sha_c], "review": review})
        return product, sha_c

    def test_e2_requires_every_registered_close_out_once(self):
        self._close_out()
        failure = self._boundary("execute", self.execute_product, "integrated")._e2()
        self.assertEqual(failure, "close-out C-1 (from ITERATE it-1 gap 0) has no disposition in the EXECUTE product")
        product, _ = self._with_close_out_commit()
        self.assertIsNone(self._boundary("execute", product, "integrated")._e2())
        product["tasks"].append(copy.deepcopy(product["tasks"][-1]))
        self.assertEqual(self._boundary("execute", product, "integrated")._e2(), "task C-1 appears more than once in the EXECUTE product")
        product["tasks"][-1]["id"] = "C-9"
        self.assertEqual(self._boundary("execute", product, "integrated")._e2(), "task C-9 is not a registered close-out")

    def test_e2_keeps_a_closed_close_out_in_later_products(self):
        product, sha_c = self._with_close_out_commit()
        c1 = product["tasks"][-1]
        self._close_out(closure={"disposition": "done", "repo": "repo", "commits": [sha_c],
                                  "reviewedRange": c1["review"]["reviewedRange"], "verdict": "pass",
                                  "reviewStep": None, "attemptId": "attempt-e1"})
        self.assertIsNone(self._boundary("execute", product, "integrated")._e2())
        dropped = copy.deepcopy(product)
        dropped["tasks"].pop()  # an external product that omits the closed close-out
        self.assertIn("C-1", self._boundary("execute", dropped, "integrated")._e2())
        self.assertIsNotNone(self._boundary("execute", dropped, "integrated")._e4())
        changed = copy.deepcopy(product)
        changed["tasks"][-1]["commits"] = [self.sha_b]
        self.assertIn("same disposition and commits", self._boundary("execute", changed, "integrated")._e2())

    def test_e4_maps_close_out_commits_by_the_registry_repo(self):
        self._close_out()
        product, _ = self._with_close_out_commit()
        self.assertIsNone(self._boundary("execute", product, "integrated")._e4())
        self.assertIsNone(self._boundary("execute", product, "integrated")._e5())

    def test_e7_needs_no_verify_run_for_a_registered_close_out(self):
        product, _ = self._with_close_out_commit()
        self.assertIsNotNone(self._boundary("execute", product, "integrated")._e7())  # unregistered: no re-run
        self._close_out()
        self.assertIsNone(self._boundary("execute", product, "integrated")._e7())

    def test_e6_binds_a_no_change_close_out_review_to_the_obligation_and_head(self):
        entry = self._close_out()
        self.store.state["implementations"]["phases"]["execute"] = "default"
        self.store.state["execute"] = {"tasks": {
            "T-1": {"status": "done", "reviewSteps": ["step-t1"]}, "T-2": {"status": "done", "reviewSteps": ["step-t2"]},
            "C-1": {"status": "already-satisfied", "reviewSteps": ["step-c1"], "closeOut": "C-1"}}}
        for sid in ("step-t1", "step-t2", "step-c1"):
            self.store.state["steps"]["submissions"][sid] = {"evidenceLevel": "host-attested"}
        step_dir = self.paths.steps_dir / "step-c1"
        step_dir.mkdir(parents=True)

        def write_prompt(view):
            atomic_write_json(step_dir / "step.json", {"prompt": "### closeOut\n```json\n" + json.dumps(view, indent=2, sort_keys=True) + "\n```"})

        write_prompt(postconditions.close_out_view(entry))
        product = copy.deepcopy(self.execute_product)
        at_head = {"reviewedRange": {"from": self.sha_b, "to": self.sha_b}, "verdict": "pass", "findings": [], "securityDispositions": []}
        product["tasks"].append({"id": "C-1", "disposition": "already-satisfied", "evidence": "already satisfied: yes", "commits": [], "review": at_head})
        self.assertIsNone(self._boundary("execute", product, "integrated")._e6())

        stale = copy.deepcopy(product)  # attested and passing, but reviewed at an older head
        stale["tasks"][-1]["review"]["reviewedRange"] = {"from": self.sha_a, "to": self.sha_a}
        self.assertIn("not the empty range at head", self._boundary("execute", stale, "integrated")._e6())

        write_prompt(postconditions.close_out_view(entry) | {"id": "C-2"})
        self.assertEqual(self._boundary("execute", product, "integrated")._e6(), "close-out C-1: its review step was not issued for this close-out")

        write_prompt(postconditions.close_out_view(entry))
        product["tasks"][-1]["review"] = None
        self.assertEqual(self._boundary("execute", product, "integrated")._e6(), "close-out C-1 is already-satisfied with no passing review")

    def test_e6_close_out_binding_matches_a_non_ascii_obligation_as_the_prompt_renders_it(self):
        # LF-57: E6 and compose_prompt share render_json, so an em dash matches both ways.
        from loop_spec.roles import Role, compose_prompt
        entry = self._close_out()
        entry["text"] = "rename the helper \u2014 it shadows a builtin"
        self.store.state["implementations"]["phases"]["execute"] = "default"
        self.store.state["execute"] = {"tasks": {"T-1": {"reviewSteps": ["s1"]}, "T-2": {"reviewSteps": ["s2"]}, "C-1": {"reviewSteps": ["s3"]}}}
        for sid in ("s1", "s2", "s3"):
            self.store.state["steps"]["submissions"][sid] = {"evidenceLevel": "host-attested"}
        role = Role(name="code-reviewer", body="Review.", schema={"type": "object"}, source="default", version="sha256:" + "0" * 64)
        prompt = compose_prompt(role, inputs={"closeOut": postconditions.close_out_view(entry)},
                                result_path=Path("/tmp/r.json"), cwd=Path("/tmp"), phase="execute")
        atomic_write_json(self.paths.steps_dir / "s3" / "step.json", {"prompt": prompt})
        product = copy.deepcopy(self.execute_product)
        review = {"reviewedRange": {"from": self.sha_b, "to": self.sha_b}, "verdict": "pass", "findings": [], "securityDispositions": []}
        product["tasks"].append({"id": "C-1", "disposition": "already-satisfied", "evidence": "e", "commits": [], "review": review})
        self.assertIsNone(self._boundary("execute", product, "integrated")._e6())

    def test_i2_resolves_an_execute_gap_to_a_known_repo(self):
        gaps = copy.deepcopy(self.iterate_product)
        gaps["gaps"] = [{"target": "execute", "text": "x"}]
        self.assertIsNone(self._boundary("iterate", gaps, "rewind")._i2())  # one repo: defaults
        gaps["gaps"][0]["repo"] = "nope"
        self.assertEqual(self._boundary("iterate", gaps, "rewind")._i2(), "gap 0 names an unknown repo 'nope'; name one of repo")
        self.store.state["repos"]["other"] = dict(self.store.state["repos"]["repo"])
        del gaps["gaps"][0]["repo"]
        self.assertEqual(self._boundary("iterate", gaps, "rewind")._i2(), "gap 0 targets EXECUTE with no repo; name one of other, repo")

    def test_d8_requires_a_repo_whose_only_commits_are_a_close_outs(self):
        self._close_out(repo="other")
        self.execute_product["tasks"].append({"id": "C-1", "disposition": "done", "evidence": None, "commits": ["abcdef1"], "review": None})
        self.assertEqual(self._boundary("deliver", self.deliver_product, "delivered")._d8(),
                         "repo other: touched by EXECUTE but missing from DELIVER's repos")


if __name__ == "__main__":
    unittest.main()


class RepoCheckPostconditionTests(unittest.TestCase):
    """7.1.0: P3/P6 for the plan's repo checks, and V10 over the program's own check runs."""

    setUp = PostconditionsTests.setUp
    _boundary = PostconditionsTests._boundary

    _CHECK = "git grep -n TODO"  # exits 1 with no output at base; a TODO line is a new failure

    def _plan_with_check(self, **check):
        plan = copy.deepcopy(self.plan_product)
        plan["checks"] = [{"repo": "repo", "command": self._CHECK, **check}]
        return plan

    def test_p6_rejects_bad_checks(self):
        self.assertIsNone(self._boundary("plan", self._plan_with_check(), "ready")._p6())
        self.assertIn("which no task changes", self._boundary("plan", self._plan_with_check(repo="other"), "ready")._p6())
        twice = self._plan_with_check()
        twice["checks"].append(dict(twice["checks"][0]))
        self.assertIn("listed twice", self._boundary("plan", twice, "ready")._p6())
        collide = self._plan_with_check(command=_VERIFY_CMD)
        collide["tasks"][0]["featureAdded"] = "new.txt"
        self.assertIn("featureAdded", self._boundary("plan", collide, "ready")._p6())

    def test_p3_needs_a_baseline_run_for_each_check(self):
        plan = self._plan_with_check()
        self.assertIn("no baseline run", self._boundary("plan", plan, "ready")._p3())
        baseline = baseline_module.capture_baseline(
            self.repo_dir, self.base_sha, [(_VERIFY_CMD, "T-1", None), (self._CHECK, None, None)], None,
            self.paths.checkouts_dir, "repo")
        self.store.state["baseline"] = baseline.to_dict()
        self.assertIsNone(self._boundary("plan", plan, "ready")._p3())
        self.assertIn("shell", self._boundary("plan", self._plan_with_check(command="ruff check | tee x"), "ready")._p3())

    def test_v10_holds_only_for_a_clean_program_run_at_the_verified_head(self):
        from loop_spec import repo_checks
        plan = self._plan_with_check()
        baseline = baseline_module.capture_baseline(
            self.repo_dir, self.base_sha, [(_VERIFY_CMD, "T-1", None), (self._CHECK, None, None)], None,
            self.paths.checkouts_dir, "repo")
        self.store.state["baseline"] = {"planRevision": "x", "repos": {"repo": baseline.to_dict()}}
        self.store.state["products"]["plan"] = {"exit": "ready", "product": plan}
        self.store.state["products"]["execute"] = {"exit": "integrated", "product": self.execute_product}
        v10 = lambda: self._boundary("verify", self.verify_product, "passed")._v10()  # noqa: E731
        self.assertIn("no program run", v10())
        repo_checks.ensure_check_runs(self.store, self.paths)
        self.assertIsNone(v10())

        # A new head with a TODO: the stale record no longer counts, and the fresh run regressed.
        (self.repo_dir / "c.txt").write_text("TODO: failing on purpose\n", encoding="utf-8")
        _git(self.repo_dir, "add", "c.txt")
        _git(self.repo_dir, "commit", "-q", "-m", "T-2 more")
        self.execute_product["heads"]["repo"] = _rev_parse(self.repo_dir)
        self.assertIn("no program run", v10())
        rows = repo_checks.ensure_check_runs(self.store, self.paths)
        self.assertEqual(rows[0]["comparison"]["verdict"], "regression")
        self.assertIn("is regression", v10())
