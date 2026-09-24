"""Integration tests for loop_spec.controller: a whole cycle driven by hand, plus the
three named edge cases (stale revision, T1 exhaustion, duplicate accept)."""
import contextlib
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from loop_spec import budget as budget_module
from loop_spec import controller
from loop_spec import postconditions
from loop_spec import questions
from loop_spec import repo as repo_module
from loop_spec import probes as probes_module
from loop_spec import revise as revise_module
from loop_spec import steps
from loop_spec.errors import LoopSpecError
from loop_spec.ids import digest_bytes
from loop_spec.jsonio import atomic_write_json, read_json
from loop_spec.paths import FeaturePaths, feature_dir, repo_id
from loop_spec.state import StateStore

from tests._product_checks import assert_product_holds

_EXTERNAL_ENV = {f"LOOP_SPEC_PHASE_{p.upper()}": "external" for p in
                 ("spec", "plan", "execute", "verify", "iterate", "deliver")}

# EXECUTE left out (falls back to config default = "default"): only execute.py's
# own step()/on_submit() loop (contract._run_default_stepped) ever marks a task
# "adopted" and emits task_adopted -- an external EXECUTE bypasses that whole
# module for one hand-submitted product instead (contract.run_phase), so a test
# asserting on adoption needs EXECUTE undispatched by _EXTERNAL_ENV.
_EXTERNAL_ENV_EXCEPT_EXECUTE = {k: v for k, v in _EXTERNAL_ENV.items() if k != "LOOP_SPEC_PHASE_EXECUTE"}


def _git(cwd, *args):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True)


def _init_repo(tmp: Path) -> Path:
    repo_dir = tmp / "repo"
    repo_dir.mkdir()
    _git(repo_dir, "init", "-q", "-b", "main")
    _git(repo_dir, "config", "user.email", "test@example.com")
    _git(repo_dir, "config", "user.name", "Test")
    (repo_dir / "README.md").write_text("hello\n", encoding="utf-8")
    _git(repo_dir, "add", "README.md")
    _git(repo_dir, "commit", "-q", "-m", "init")
    return repo_dir


def _add_origin(tmp: Path, repo_dir: Path, *branches: str) -> Path:
    """A bare `origin` holding `branches`, so a PR adoption can fetch its head."""
    origin = tmp / "origin.git"
    _git(tmp, "init", "-q", "--bare", str(origin))
    _git(repo_dir, "remote", "add", "origin", str(origin))
    _git(repo_dir, "push", "-q", "origin", *branches)
    return origin


def _open(paths: FeaturePaths) -> StateStore:
    return StateStore.open(paths)


def _answer_approve_and_continue(paths, repo_dir, markers, next_):
    """Answer an open approval question with "approve" and continue. Shared by
    _drive_through_spec_approval (a real SPEC) and
    _approve_compacted_spec_and_submit_critic (DEBUG/REVISE's compacted SPEC)."""
    question = read_json(next_.path)
    store = _open(paths)
    from loop_spec import questions as questions_module
    questions_module.answer(store, paths, question_id=question["questionId"], value="approve")
    with contextlib.redirect_stdout(markers):
        return controller.continue_run(store, paths, project_root=repo_dir)


def _drive_through_spec_approval(store, paths, repo_dir, markers):
    """Write, submit, and approve a fixed SPEC product; return (next_ for PLAN's own
    step, the spec product) so a test can compute the requirements revision it binds
    to. Shared by any test that needs a run past SPEC before its own scenario starts."""
    step = read_json(paths.steps_dir / store.state["steps"]["open"][0]["stepAttemptId"] / "step.json")
    spec_product = {
        "exit": "approved", "inputsDigest": "sha256:" + "0" * 64,
        "boundTo": {"requirements": None, "plan": None},
        "goal": "Add a greeting message", "boundaries": [],
        "criteria": [{"id": "AC-1", "text": "prints a greeting"}],
        "decisions": [], "openQuestions": [],
    }
    atomic_write_json(Path(step["resultPath"]), spec_product)
    store = _open(paths)
    steps.submit(store, paths, step_id=step["stepAttemptId"], dispatch_name=None, host=None)
    with contextlib.redirect_stdout(markers):
        next_ = controller.continue_run(store, paths, project_root=repo_dir)
    next_ = _answer_approve_and_continue(paths, repo_dir, markers, next_)
    return next_, spec_product


def _start_greeting_run(repo_dir: Path, home: Path, markers: io.StringIO):
    """Start a full "cycle" run for the fixed "Add a greeting message" request and
    drive it through SPEC approval; return (next_ for PLAN's own step, spec_product,
    paths, repo_name). Shared by every test that needs this same run past SPEC
    before its own scenario (a converging cycle, a critic re-pass, ...) starts."""
    with contextlib.redirect_stdout(markers):
        controller.run_entry(
            "cycle", project_root=repo_dir, request_text="Add a greeting message",
            slug="greeting", state_home=str(home), answer_policy=None, pr=None,
        )
    paths = FeaturePaths(root=feature_dir(home, repo_id(repo_dir), "greeting"))
    store = _open(paths)
    repo_name = next(iter(store.state["repos"]))
    next_, spec_product = _drive_through_spec_approval(store, paths, repo_dir, markers)
    return next_, spec_product, paths, repo_name


def _greeting_plan_product(repo_name: str, spec_revision: str) -> dict:
    return {
        "exit": "ready", "inputsDigest": "sha256:" + "0" * 64,
        "boundTo": {"requirements": spec_revision, "plan": None},
        "tasks": [{
            "id": "T-1", "title": "add greeting", "dependsOn": [], "files": ["greet.py"],
            "repo": repo_name, "verify": 'python3 -c "import sys; sys.exit(0)"',
            "criteria": ["AC-1"], "featureAdded": None, "mustFlip": False,
        }],
        "prepare": None, "evidenceExceptions": [],
    }


def _submit_greeting_plan(paths, repo_dir, markers, step, repo_name: str, spec_product: dict):
    """Build the fixed greeting PLAN product, submit it against `step`, and continue;
    return (next_, plan_product) so a caller can bind later products to its revision."""
    spec_revision = postconditions.requirements_revision(spec_product)
    plan_product = _greeting_plan_product(repo_name, spec_revision)
    atomic_write_json(Path(step["resultPath"]), plan_product)
    store = _open(paths)
    steps.submit(store, paths, step_id=step["stepAttemptId"], dispatch_name=None, host=None)
    with contextlib.redirect_stdout(markers):
        next_ = controller.continue_run(store, paths, project_root=repo_dir)
    return next_, plan_product


def _approve_compacted_spec_and_submit_critic(paths, repo_dir, markers, next_):
    """Answer the compacted SPEC's own approval question with "approve", then submit
    an empty-findings PLAN critic step (PLAN forced external) and continue. Shared by
    DEBUG's and REVISE's entry tests, whose compacted SPEC/PLAN pass through the same
    approval+baseline+critic machinery a real SPEC/PLAN product would."""
    next_ = _answer_approve_and_continue(paths, repo_dir, markers, next_)
    critic_step = read_json(next_.path)
    atomic_write_json(Path(critic_step["resultPath"]), {"findings": []})
    return _submit_and_continue(paths, repo_dir, markers, critic_step["stepAttemptId"])


def _write_sdk_receipt(store, paths, step: dict) -> None:
    """A real SDK-runner dispatch leaves this under the step's own directory
    (steps.py: `paths.steps_dir / step_id / "receipt.json"`, only ever consulted
    when the run's own state says an SDK actually launched it) so steps.submit
    can mark the submission "controller-observed" (ACCEPTED_REVIEW_LEVELS)
    without a live host to attest it; dispatch_name=None/host=None (this file's
    usual submit call) would otherwise leave it "unattested" and E6 would reject
    a DEFAULT-mode EXECUTE task's review. Only EXECUTE's own review-role steps
    (never SPEC/PLAN/DEBUG/REVISE's compacted-approval or external-phase steps)
    need this -- E6 is the only postcondition that reads a step's own
    evidenceLevel."""
    store.state["run"]["runner"] = "sdk"
    store.save()
    result_path = Path(step["resultPath"])
    receipt_path = paths.steps_dir / step["stepAttemptId"] / "receipt.json"
    atomic_write_json(receipt_path, {
        "stepAttemptId": step["stepAttemptId"], "resultDigest": digest_bytes(result_path.read_bytes()),
        "sessionId": "test-session",
    })


def _submit_and_continue(paths, repo_dir, markers, step_id: str):
    """submit + route_submission (cli.py's own submit-command sequence) + continue,
    for a step whose role may need an on_submit dispatch (debug/revise/verify/
    iterate's own roles, unlike the plain-external steps _submit_greeting_plan's
    helpers above never route)."""
    store = _open(paths)
    submission = steps.submit(store, paths, step_id=step_id, dispatch_name=None, host=None)
    controller.route_submission(store, paths, submission.step, submission.result)
    with contextlib.redirect_stdout(markers):
        return controller.continue_run(store, paths, project_root=repo_dir)


class _QuietStdout(unittest.TestCase):
    """Every phase transition and marker prints via events.py's console/marker
    writers (progress lines to stderr by default, LOOP_SPEC_* markers to stdout), and
    a test that drives the controller by hand makes many calls no single
    `with contextlib.redirect_stdout(...)` wraps. Redirecting both streams for the
    whole test method here, rather than around each call, keeps that noise out of the
    real test-runner output without touching what each test asserts; unittest reports
    a failure's traceback after tearDown/addCleanup restores them."""

    def setUp(self):
        super().setUp()
        redirect_out = contextlib.redirect_stdout(io.StringIO())
        redirect_err = contextlib.redirect_stderr(io.StringIO())
        redirect_out.__enter__()
        redirect_err.__enter__()
        self.addCleanup(redirect_err.__exit__, None, None, None)
        self.addCleanup(redirect_out.__exit__, None, None, None)


class FullExternalCycleTests(_QuietStdout):
    def test_full_external_cycle_converges_and_delivers(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            repo_dir = _init_repo(tmp)
            origin = tmp / "origin.git"
            _git(tmp, "init", "-q", "--bare", str(origin))
            _git(repo_dir, "remote", "add", "origin", str(origin))
            # Push main so the bare remote's symbolic HEAD resolves; check_credentials'
            # git_ok probe is `git ls-remote --exit-code origin HEAD`, which fails on a
            # bare repo whose default branch was never pushed.
            _git(repo_dir, "push", "-q", "origin", "main")
            home = tmp / "home"

            with patch.dict("os.environ", _EXTERNAL_ENV, clear=False):
                markers = io.StringIO()
                next_, spec_product, paths, repo_name = _start_greeting_run(repo_dir, home, markers)
                store = _open(paths)
                base_sha = store.state["repos"][repo_name]["baseSha"]
                feature_branch = store.state["repos"][repo_name]["featureBranch"]
                self.assertEqual(next_.kind, "step")

                # --- PLAN ---
                step = read_json(next_.path)
                spec_revision = postconditions.requirements_revision(spec_product)
                next_, plan_product = _submit_greeting_plan(paths, repo_dir, markers, step, repo_name, spec_product)
                self.assertEqual(next_.kind, "step")  # the PLAN critic step

                # --- critic: no Critical findings ---
                critic_step = read_json(next_.path)
                atomic_write_json(Path(critic_step["resultPath"]), {"findings": []})
                store = _open(paths)
                steps.submit(store, paths, step_id=critic_step["stepAttemptId"], dispatch_name=None, host=None)
                with contextlib.redirect_stdout(markers):
                    next_ = controller.continue_run(store, paths, project_root=repo_dir)
                self.assertEqual(next_.kind, "step")  # EXECUTE's own step

                # --- EXECUTE: real commit on the feature branch, in a scratch worktree ---
                step = read_json(next_.path)
                repo_module.create_feature_branch(repo_dir, feature_branch, base_sha)
                feature_wt = tmp / "feature-wt"
                repo_module.add_worktree(repo_dir, feature_wt, branch=feature_branch)
                (feature_wt / "greet.py").write_text("print('hello')\n", encoding="utf-8")
                _git(feature_wt, "add", "greet.py")
                _git(feature_wt, "commit", "-q", "-m", "T-1: add greeting")
                commit_sha = repo_module.head_sha(feature_wt)
                repo_module.remove_worktree(repo_dir, feature_wt, force=True)

                plan_revision = postconditions.plan_revision(plan_product)
                execute_product = {
                    "exit": "integrated", "inputsDigest": "sha256:" + "0" * 64,
                    "boundTo": {"requirements": spec_revision, "plan": plan_revision},
                    "tasks": [{
                        "id": "T-1", "disposition": "done", "evidence": None, "commits": [commit_sha],
                        "review": {
                            "reviewedRange": {"from": base_sha, "to": commit_sha},
                            "verdict": "pass", "findings": [], "securityDispositions": [],
                        },
                    }],
                    "issues": [], "heads": {repo_name: commit_sha},
                }
                atomic_write_json(Path(step["resultPath"]), execute_product)
                store = _open(paths)
                steps.submit(store, paths, step_id=step["stepAttemptId"], dispatch_name=None, host=None)
                with contextlib.redirect_stdout(markers):
                    next_ = controller.continue_run(store, paths, project_root=repo_dir)
                self.assertEqual(next_.kind, "step")  # VERIFY's own step

                # --- VERIFY ---
                step = read_json(next_.path)
                verify_product = {
                    "exit": "passed", "inputsDigest": "sha256:" + "0" * 64,
                    "boundTo": {"requirements": spec_revision, "plan": plan_revision},
                    "verdicts": [{
                        "criterion": "AC-1", "verdict": "pass",
                        "evidence": {
                            "command": 'python3 -c "import sys; sys.exit(0)"', "repo": repo_name, "sha": commit_sha,
                            "exitStatus": 0, "failureIdentities": [], "outputDigest": "sha256:" + "0" * 64,
                        },
                        "cause": None,
                    }],
                    "findings": [], "remediationTasks": [],
                    "reviewedRanges": [{"repo": repo_name, "from": base_sha, "to": commit_sha, "full": True}],
                }
                atomic_write_json(Path(step["resultPath"]), verify_product)
                store = _open(paths)
                steps.submit(store, paths, step_id=step["stepAttemptId"], dispatch_name=None, host=None)
                with contextlib.redirect_stdout(markers):
                    next_ = controller.continue_run(store, paths, project_root=repo_dir)
                self.assertEqual(next_.kind, "step")  # ITERATE's own step

                # --- ITERATE ---
                step = read_json(next_.path)
                iterate_product = {
                    "exit": "converged", "inputsDigest": "sha256:" + "0" * 64,
                    "boundTo": {"requirements": spec_revision, "plan": plan_revision},
                    "verdict": "met", "gaps": [], "caveats": [], "boundShas": {repo_name: commit_sha},
                }
                atomic_write_json(Path(step["resultPath"]), iterate_product)
                store = _open(paths)
                steps.submit(store, paths, step_id=step["stepAttemptId"], dispatch_name=None, host=None)

                # LF-21: the credential check now runs before DELIVER's own step is
                # even issued, so `gh` needs its fake from here on, not only after
                # DELIVER's product is submitted below.
                def fake_run_gh(repo, *args):
                    if args[:2] == ("auth", "status"):
                        return 0, "", ""
                    if args[:2] == ("pr", "view"):
                        return 0, json.dumps({
                            "state": "OPEN", "headRefName": feature_branch, "headRefOid": commit_sha,
                            "baseRefName": "main", "number": 1, "url": "https://example.invalid/pull/1",
                        }), ""
                    return 1, "", "unexpected gh call in test"

                with patch.object(repo_module, "run_gh", fake_run_gh):
                    with contextlib.redirect_stdout(markers):
                        next_ = controller.continue_run(store, paths, project_root=repo_dir)
                self.assertEqual(next_.kind, "step")  # DELIVER's own step

                # LF-21: DELIVER's own (external) step is not issued until the
                # credential check has already run and recorded every field, not
                # just git_ok/gh_ok -- deliver.py reads failedCommand/repair too.
                store = _open(paths)
                check = store.state["credentialChecks"][repo_name]
                self.assertTrue(check["git_ok"])
                self.assertTrue(check["gh_ok"])
                self.assertIn("git ls-remote", check["checked"][0])
                self.assertIsNone(check["failedCommand"])

                # --- DELIVER: push the branch for real ---
                step = read_json(next_.path)
                _git(repo_dir, "push", "-q", "origin", feature_branch)

                deliver_product = {
                    "exit": "delivered", "inputsDigest": "sha256:" + "0" * 64,
                    "boundTo": {"requirements": spec_revision, "plan": plan_revision},
                    "repos": [{
                        "repo": repo_name,
                        "pr": {"number": 1, "url": "https://example.invalid/pull/1", "headRef": feature_branch, "headSha": commit_sha, "base": "main"},
                        "deliveredSha": commit_sha, "caveats": [], "state": "delivered",
                    }],
                }
                atomic_write_json(Path(step["resultPath"]), deliver_product)
                store = _open(paths)
                steps.submit(store, paths, step_id=step["stepAttemptId"], dispatch_name=None, host=None)
                with patch.object(repo_module, "run_gh", fake_run_gh):
                    with contextlib.redirect_stdout(markers):
                        next_ = controller.continue_run(store, paths, project_root=repo_dir)

            self.assertEqual(next_.kind, "result")
            result = read_json(next_.path)
            self.assertEqual(result["result"], "converged")
            self.assertEqual(result["status"], "completed")
            self.assertTrue(result["converged"])
            self.assertTrue(result["workDelivered"])

            printed = markers.getvalue()
            for marker in ("LOOP_SPEC_PHASE_START", "LOOP_SPEC_PHASE_END", "LOOP_SPEC_QUESTION", "LOOP_SPEC_RESULT"):
                self.assertIn(marker, printed)


class EdgeCaseTests(_QuietStdout):
    def _minimal_store(self, tmp: Path) -> tuple[StateStore, FeaturePaths]:
        paths = FeaturePaths(root=tmp / "feature")
        store = StateStore.create(paths, {"id": "run-1", "entry": "cycle", "cycleType": "full", "slug": "x", "createdAt": "2026-01-01T00:00:00+00:00"}, "do it")
        store.state["repos"] = {"repo": {"path": str(tmp), "baseSha": "a" * 40, "featureBranch": "feat/x", "defaultBranch": "main", "lastKnownHead": "a" * 40}}
        store.state["implementations"] = {"phases": {p: "external" for p in ("spec", "plan", "execute", "verify", "iterate", "deliver")}, "roles": {}}
        return store, paths

    def test_stale_revision_product_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            store, paths = self._minimal_store(tmp)
            spec_product = {"goal": "g", "boundaries": [], "criteria": [{"id": "AC-1", "text": "t"}], "decisions": [], "openQuestions": []}
            store.state["products"]["spec"] = {
                "attemptId": "attempt-0", "inputsDigest": "sha256:" + "0" * 64,
                "boundTo": {"requirements": None, "plan": None}, "exit": "approved", "product": spec_product,
                "receivedAt": "2026-01-01T00:00:00+00:00", "evidenceLevel": "human-attested",
            }
            store.state["revisions"]["requirements"] = postconditions.requirements_revision(spec_product)  # the CURRENT approved revision
            store.state["phase"]["current"] = "plan"
            store.state["phase"]["attemptId"] = "attempt-1"
            store.save()

            stale_plan_product = {
                "exit": "ready", "inputsDigest": "sha256:" + "0" * 64,
                "boundTo": {"requirements": "sha256:" + "2" * 64, "plan": None},  # stale: does not match
                "tasks": [], "prepare": None, "evidenceExceptions": [],
            }
            controller._accept_product(store, paths, tmp, "plan", "attempt-1", stale_plan_product)

            self.assertIsNone(store.state["products"]["plan"])
            self.assertEqual(store.state["phase"]["entry"], "remediation")
            self.assertIn("rejected", store.state["phase"]["entryPayload"])

    def test_t1_exhaustion_writes_escalated_without_entering_a_phase(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            store, paths = self._minimal_store(tmp)
            store.state["products"]["spec"] = {
                "attemptId": "attempt-0", "inputsDigest": "sha256:" + "0" * 64,
                "boundTo": {"requirements": None, "plan": None}, "exit": "approved",
                "product": {"goal": "g", "boundaries": [], "criteria": [], "decisions": []},
                "receivedAt": "2026-01-01T00:00:00+00:00", "evidenceLevel": "human-attested",
            }
            store.state["revisions"]["requirements"] = postconditions.requirements_revision(store.state["products"]["spec"]["product"])
            store.state["phase"]["current"] = "plan"
            store.state["phase"]["attemptId"] = "attempt-3"
            store.save()

            budget_module.spend(store, from_phase="plan", exit="spec gap", to_phase="spec", attempt_id="attempt-1", reason="gap")
            budget_module.spend(store, from_phase="plan", exit="spec gap", to_phase="spec", attempt_id="attempt-2", reason="gap")
            self.assertFalse(budget_module.has_room(store))

            plan_gap_product = {
                "exit": "spec gap", "inputsDigest": "sha256:" + "0" * 64,
                "boundTo": {"requirements": store.state["revisions"]["requirements"], "plan": None},
                "tasks": [], "prepare": None, "evidenceExceptions": [],
            }
            controller._accept_product(store, paths, tmp, "plan", "attempt-3", plan_gap_product)

            self.assertIsNotNone(store.state["result"])
            self.assertEqual(store.state["result"]["classification"], "escalated")
            self.assertEqual(store.state["phase"]["current"], "plan")  # never entered spec

    def test_duplicate_accept_does_not_double_transition(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            store, paths = self._minimal_store(tmp)
            store.state["phase"]["current"] = "spec"
            store.state["phase"]["attemptId"] = "attempt-1"
            store.save()

            spec_product = {
                "exit": "approved", "inputsDigest": "sha256:" + "0" * 64,
                "boundTo": {"requirements": None, "plan": None},
                "goal": "g", "boundaries": [], "criteria": [{"id": "AC-1", "text": "t"}],
                "decisions": [], "openQuestions": [],
            }
            revision = postconditions.requirements_revision(spec_product)
            from loop_spec import questions as questions_module
            record = questions_module.ask(
                store, paths, phase="spec", attempt_id="attempt-1", text="approve?", kind="approval",
                options=[{"value": "approve", "label": "Approve"}], default_value="approve", payload={"revision": revision},
            )
            questions_module.answer(store, paths, question_id=record["questionId"], value="approve")

            controller._accept_product(store, paths, tmp, "spec", "attempt-1", spec_product)
            self.assertEqual(store.state["phase"]["current"], "plan")
            first_products_spec = store.state["products"]["spec"]

            # A duplicate call for the SAME attempt must be a no-op (the attemptId guard).
            controller._accept_product(store, paths, tmp, "spec", "attempt-1", spec_product)
            self.assertEqual(store.state["phase"]["current"], "plan")
            self.assertEqual(store.state["products"]["spec"], first_products_spec)

    def test_forward_transition_clears_a_stale_entry_payload(self):
        # LF-51: a forward entry must never inherit a rejected/rewind payload left
        # behind by the phase before it -- start with one already sitting there
        # (as a real rejected-then-accepted attempt would leave, pre-fix) and
        # confirm the accepted forward transition clears it.
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            store, paths = self._minimal_store(tmp)
            store.state["phase"]["current"] = "spec"
            store.state["phase"]["attemptId"] = "attempt-1"
            store.state["phase"]["entryPayload"] = {"rejected": {"exit": "approved", "failures": [{"id": "S1", "message": "stale"}]}}
            store.save()

            spec_product = {
                "exit": "approved", "inputsDigest": "sha256:" + "0" * 64,
                "boundTo": {"requirements": None, "plan": None},
                "goal": "g", "boundaries": [], "criteria": [{"id": "AC-1", "text": "t"}],
                "decisions": [], "openQuestions": [],
            }
            revision = postconditions.requirements_revision(spec_product)
            from loop_spec import questions as questions_module
            record = questions_module.ask(
                store, paths, phase="spec", attempt_id="attempt-1", text="approve?", kind="approval",
                options=[{"value": "approve", "label": "Approve"}], default_value="approve", payload={"revision": revision},
            )
            questions_module.answer(store, paths, question_id=record["questionId"], value="approve")

            controller._accept_product(store, paths, tmp, "spec", "attempt-1", spec_product)
            self.assertEqual(store.state["phase"]["current"], "plan")
            self.assertIsNone(store.state["phase"]["entryPayload"])

    def test_verify_implementation_gap_carries_the_rewind_payload_forward(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            store, paths = self._minimal_store(tmp)
            spec_product = {"goal": "g", "boundaries": [], "criteria": [{"id": "AC-1", "text": "t"}],
                             "decisions": [], "openQuestions": []}
            store.state["products"]["spec"] = {
                "attemptId": "attempt-0", "inputsDigest": "sha256:" + "0" * 64,
                "boundTo": {"requirements": None, "plan": None}, "exit": "approved", "product": spec_product,
                "receivedAt": "2026-01-01T00:00:00+00:00", "evidenceLevel": "human-attested",
            }
            store.state["revisions"]["requirements"] = postconditions.requirements_revision(spec_product)
            plan_product = {"tasks": [], "prepare": None, "evidenceExceptions": []}
            store.state["products"]["plan"] = {
                "attemptId": "attempt-0", "inputsDigest": "sha256:" + "0" * 64,
                "boundTo": {"requirements": store.state["revisions"]["requirements"], "plan": None},
                "exit": "ready", "product": plan_product,
                "receivedAt": "2026-01-01T00:00:00+00:00", "evidenceLevel": "human-attested",
            }
            store.state["revisions"]["plan"] = postconditions.plan_revision(plan_product)
            store.state["phase"]["current"] = "verify"
            store.state["phase"]["attemptId"] = "attempt-1"
            store.save()

            remediation_task = {"id": "T-1", "title": "fix it", "dependsOn": [], "files": ["a.py"],
                                 "repo": "repo", "verify": "sh verify.sh", "criteria": ["AC-1"],
                                 "featureAdded": None, "mustFlip": False}
            verify_product = {
                "exit": "implementation gap", "inputsDigest": "sha256:" + "0" * 64,
                "boundTo": {"requirements": store.state["revisions"]["requirements"], "plan": store.state["revisions"]["plan"]},
                "verdicts": [{"criterion": "AC-1", "verdict": "fail", "evidence": None, "cause": "widget missing"}],
                "findings": [], "remediationTasks": [remediation_task],
                "reviewedRanges": [{"repo": "repo", "from": "a" * 40, "to": "b" * 40, "full": True}],
            }
            controller._accept_product(store, paths, tmp, "verify", "attempt-1", verify_product)

            self.assertEqual(store.state["phase"]["current"], "execute")
            rewind = store.state["phase"]["entryPayload"]["rewind"]
            self.assertEqual(rewind["attemptId"], "attempt-1")
            self.assertEqual(rewind["from"], "verify")
            self.assertEqual(rewind["exit"], "implementation gap")
            self.assertEqual(rewind["remediationTasks"], [remediation_task])
            self.assertEqual(rewind["verdicts"], verify_product["verdicts"])


class PlanCriticTests(_QuietStdout):
    def test_critic_fixed_then_rechecked_reaches_execute(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            repo_dir = _init_repo(tmp)
            home = tmp / "home"
            markers = io.StringIO()

            with patch.dict("os.environ", _EXTERNAL_ENV, clear=False):
                next_, spec_product, paths, repo_name = _start_greeting_run(repo_dir, home, markers)
                self.assertEqual(next_.kind, "step")

                # --- PLAN pass 1 ---
                step = read_json(next_.path)
                next_, plan_product = _submit_greeting_plan(paths, repo_dir, markers, step, repo_name, spec_product)
                self.assertEqual(next_.kind, "step")  # critic pass 1

                critic_step = read_json(next_.path)
                # LF-32: the role schema (additionalProperties false) has no
                # disposition/reason/supersedes -- the critic reports id/location/
                # cause/severity only; the program defaults disposition to "open".
                open_finding = {
                    "id": "F-1", "location": "greet.py:1", "cause": "no boundary on the destructive rm",
                    "severity": "Critical",
                }
                atomic_write_json(Path(critic_step["resultPath"]), {"findings": [open_finding]})
                store = _open(paths)
                steps.submit(store, paths, step_id=critic_step["stepAttemptId"], dispatch_name=None, host=None)
                with contextlib.redirect_stdout(markers):
                    next_ = controller.continue_run(store, paths, project_root=repo_dir)

                # An open Critical on pass 1 sends PLAN back for one corrected re-pass,
                # in a genuinely fresh attempt (not a replay of the rejected one).
                self.assertEqual(next_.kind, "step")
                store = _open(paths)
                self.assertEqual(store.state["phase"]["entry"], "remediation")
                self.assertIsNotNone(store.state["phase"]["attemptId"])
                self.assertEqual(store.state["critic"]["passes"], 1)
                self.assertEqual(store.state["critic"]["findings"][0]["disposition"], "open")

                # --- PLAN pass 2: the corrected product marks F-1 fixed ---
                step = read_json(next_.path)
                corrected_plan_product = dict(plan_product, criticResponses=[
                    {"findingId": "F-1", "disposition": "fixed", "reason": None},
                ])
                atomic_write_json(Path(step["resultPath"]), corrected_plan_product)
                store = _open(paths)
                steps.submit(store, paths, step_id=step["stepAttemptId"], dispatch_name=None, host=None)
                with contextlib.redirect_stdout(markers):
                    next_ = controller.continue_run(store, paths, project_root=repo_dir)
                self.assertEqual(next_.kind, "step")  # the critic is re-issued once, on the corrected product

                critic_step_2 = read_json(next_.path)
                atomic_write_json(Path(critic_step_2["resultPath"]), {"findings": []})
                store = _open(paths)
                steps.submit(store, paths, step_id=critic_step_2["stepAttemptId"], dispatch_name=None, host=None)
                with contextlib.redirect_stdout(markers):
                    next_ = controller.continue_run(store, paths, project_root=repo_dir)

                self.assertEqual(next_.kind, "step")  # PLAN went ready; EXECUTE's own step
                store = _open(paths)
                self.assertEqual(store.state["phase"]["current"], "execute")
                self.assertEqual(store.state["critic"]["passes"], 2)

    def _second_pass_critic(self, tmp: Path, recommendation, policy: str | None = "default", crash_after_ask=False):
        """LF-62: the real path. PLAN (external) gets a Critical on both critic passes;
        the second pass asks the blocked question, and continue_run consumes it."""
        repo_dir = _init_repo(tmp)
        markers = io.StringIO()
        with patch.dict("os.environ", _EXTERNAL_ENV, clear=False):
            next_, spec_product, paths, repo_name = _start_greeting_run(repo_dir, tmp / "home", markers)
            next_, plan_product = _submit_greeting_plan(paths, repo_dir, markers, read_json(next_.path), repo_name, spec_product)
            finding = {"id": "F-1", "location": "greet.py:1", "cause": "the verify command cannot fail", "severity": "Critical"}
            critic = read_json(next_.path)
            atomic_write_json(Path(critic["resultPath"]), {"findings": [finding]})
            next_ = _submit_and_continue(paths, repo_dir, markers, critic["stepAttemptId"])
            step = read_json(next_.path)
            atomic_write_json(Path(step["resultPath"]), dict(plan_product, criticResponses=[
                {"findingId": "F-1", "disposition": "fixed", "reason": None}]))
            next_ = _submit_and_continue(paths, repo_dir, markers, step["stepAttemptId"])
            store = _open(paths)
            store.state["questions"]["policy"] = policy
            store.save()
            critic_2 = read_json(next_.path)
            atomic_write_json(Path(critic_2["resultPath"]), {"findings": [dict(finding, recommendation=recommendation) if recommendation else finding]})
            store = _open(paths)
            steps.submit(store, paths, step_id=critic_2["stepAttemptId"], dispatch_name=None, host=None)
            if crash_after_ask:
                real_ask = questions.ask
                def ask_then_crash(*a, **kw):
                    real_ask(*a, **kw)
                    raise RuntimeError("crash before the critic links its question")
                with patch.object(controller.questions, "ask", side_effect=ask_then_crash), self.assertRaises(RuntimeError):
                    controller.continue_run(store, paths, project_root=repo_dir)
                store = _open(paths)  # what a resume finds on disk
            with contextlib.redirect_stdout(markers):
                next_ = controller.continue_run(store, paths, project_root=repo_dir)
            return _open(paths), next_

    def test_the_default_policy_takes_a_spec_gap_recommendation_through_continue_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, _ = self._second_pass_critic(Path(tmp), {"action": "spec gap", "reason": "AC-2 is untestable"})
            critic_questions = [q for q, r in store.state["questions"]["answered"].items() if r["phase"] == "plan"]
            self.assertEqual(len(critic_questions), 1)
            self.assertEqual(store.state["questions"]["answered"][critic_questions[0]]["by"], "policy")
            self.assertEqual(store.state["questions"]["policyAnswered"].count(critic_questions[0]), 1)
            self.assertEqual(store.state["phase"]["current"], "spec")  # the backward route
            self.assertEqual(store.state["budget"]["spent"], 1)
            self.assertIsNone(store.state["phase"]["criticQuestionId"])

    def test_the_default_policy_closes_findings_with_the_recommended_reason(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, _ = self._second_pass_critic(Path(tmp), {"action": "reject", "reason": "base facts cover it"})
            self.assertEqual(store.state["phase"]["current"], "execute")
            closed = store.state["critic"]["findings"][0]
            self.assertEqual((closed["id"], closed["disposition"], closed["reason"]), ("F-1", "rejected", "F-1: base facts cover it"))

    def test_the_critic_question_stays_open_without_a_default_or_the_policy(self):
        for recommendation, policy in ((None, "default"), ({"action": "spec gap", "reason": "AC-2 is untestable"}, None)):
            with self.subTest(policy=policy), tempfile.TemporaryDirectory() as tmp:
                store, next_ = self._second_pass_critic(Path(tmp), recommendation, policy=policy)
                self.assertEqual(next_.kind, "question")
                self.assertEqual(store.state["questions"]["open"]["questionId"], store.state["phase"]["criticQuestionId"])

    def test_a_crash_before_linking_the_critic_question_recovers_to_one_answered_question(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, _ = self._second_pass_critic(Path(tmp), {"action": "spec gap", "reason": "AC-2 is untestable"}, crash_after_ask=True)
            critic_questions = [q for q, r in store.state["questions"]["answered"].items() if r["phase"] == "plan"]
            self.assertEqual(len(critic_questions), 1)
            self.assertEqual(store.state["questions"]["policyAnswered"].count(critic_questions[0]), 1)
            self.assertEqual(store.state["phase"]["current"], "spec")

    def test_critic_step_prompt_carries_role_body_and_schema(self):
        # LF-32: the critic step goes through roles.compose_prompt/load_role like
        # every other role step, instead of a hand-written prompt and inline schema.
        roles_dir = Path(controller.__file__).resolve().parent.parent.parent / "roles"
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            repo_dir = _init_repo(tmp)
            home = tmp / "home"
            markers = io.StringIO()

            with patch.dict("os.environ", _EXTERNAL_ENV, clear=False):
                next_, spec_product, paths, repo_name = _start_greeting_run(repo_dir, home, markers)
                step = read_json(next_.path)
                next_, plan_product = _submit_greeting_plan(paths, repo_dir, markers, step, repo_name, spec_product)
                self.assertEqual(next_.kind, "step")  # the critic step

                critic_step = read_json(next_.path)
                store = _open(paths)
                self.assertEqual(critic_step["schema"], json.loads((roles_dir / "plan-critic" / "schema.json").read_text()))
                self.assertIn("## Output", critic_step["prompt"])
                self.assertIn('"severity"', critic_step["prompt"])
                self.assertIn("Critical-only", critic_step["prompt"])
                # F1: the critic reads code at each repo's start commit, like the planner.
                self.assertIn('"startSha"', critic_step["prompt"])
                self.assertTrue(critic_step["resultPath"].startswith(str(paths.results_dir)))
                attempt = store.state["phase"]["attemptId"]
                self.assertEqual(Path(critic_step["resultPath"]).name, f"plan-critic-{attempt}.json")

    def test_critic_result_in_review_tool_shape_is_rejected(self):
        # LF-32: the plan-critic worker wrote a review-tool-shaped result (the bug
        # this finding is about); submit must reject it naming what the schema wants.
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            repo_dir = _init_repo(tmp)
            home = tmp / "home"
            markers = io.StringIO()

            with patch.dict("os.environ", _EXTERNAL_ENV, clear=False):
                next_, spec_product, paths, repo_name = _start_greeting_run(repo_dir, home, markers)
                step = read_json(next_.path)
                next_, plan_product = _submit_greeting_plan(paths, repo_dir, markers, step, repo_name, spec_product)
                critic_step = read_json(next_.path)

                wrong_shape = {"findings": [{
                    "file": "x", "line": None, "category": "verify-gap",
                    "summary": "s", "failure_scenario": "f",
                }]}
                atomic_write_json(Path(critic_step["resultPath"]), wrong_shape)
                store = _open(paths)
                with self.assertRaises(LoopSpecError) as ctx:
                    steps.submit(store, paths, step_id=critic_step["stepAttemptId"], dispatch_name=None, host=None)
                self.assertIn("id", ctx.exception.message)
                self.assertIn("severity", ctx.exception.message)


class EscalatedPartialDraftTests(_QuietStdout):
    def _minimal_store(self, tmp: Path, config: dict | None = None) -> tuple[StateStore, FeaturePaths]:
        paths = FeaturePaths(root=tmp / "feature")
        store = StateStore.create(paths, {"id": "run-1", "entry": "cycle", "cycleType": "full", "slug": "x", "createdAt": "2026-01-01T00:00:00+00:00"}, "do it")
        store.state["repos"] = {"repo": {"path": str(tmp), "baseSha": "a" * 40, "featureBranch": "feat/x", "defaultBranch": "main", "lastKnownHead": "a" * 40}}
        store.state["implementations"] = {"phases": {p: "external" for p in ("spec", "plan", "execute", "verify", "iterate", "deliver")}, "roles": {}}
        store.state["products"]["execute"] = {
            "attemptId": "attempt-e", "inputsDigest": "sha256:" + "0" * 64,
            "boundTo": {"requirements": None, "plan": None}, "exit": "integrated",
            "product": {"heads": {"repo": "c" * 40}, "tasks": []},
            "receivedAt": "2026-01-01T00:00:00+00:00", "evidenceLevel": "human-attested",
        }
        store.state["phase"]["current"] = "iterate"
        store.state["phase"]["attemptId"] = "attempt-1"
        if config is not None:
            (tmp / ".loop-spec").mkdir()
            atomic_write_json(tmp / ".loop-spec" / "config.json", config)
        store.save()
        return store, paths

    def _exhaust_budget(self, store: StateStore) -> None:
        budget_module.spend(store, from_phase="plan", exit="spec gap", to_phase="spec", attempt_id="a-1", reason="gap")
        budget_module.spend(store, from_phase="plan", exit="spec gap", to_phase="spec", attempt_id="a-2", reason="gap")

    def _escalated_iterate_product(self) -> dict:
        return {
            "exit": "escalated", "inputsDigest": "sha256:" + "0" * 64,
            "boundTo": {"requirements": None, "plan": None},
            "verdict": "unmet", "gaps": [], "caveats": [], "boundShas": {"repo": "c" * 40},
        }

    def test_default_config_keeps_terminal_escalation(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            store, paths = self._minimal_store(tmp)
            self._exhaust_budget(store)

            controller._finalize(store, paths, tmp, "iterate", "attempt-1", self._escalated_iterate_product(), "escalated")

            self.assertEqual(store.state["result"]["classification"], "escalated")
            self.assertEqual(store.state["phase"]["current"], "iterate")  # never routed to deliver

    def test_escalated_partial_draft_routes_to_deliver_and_stays_escalated(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            store, paths = self._minimal_store(tmp, config={"deliver": {"escalatedPartialDraft": True}})
            self._exhaust_budget(store)

            controller._finalize(store, paths, tmp, "iterate", "attempt-1", self._escalated_iterate_product(), "escalated")

            self.assertIsNone(store.state.get("result"))  # not terminal yet: routed forward
            self.assertEqual(store.state["phase"]["current"], "deliver")
            self.assertEqual(store.state["phase"]["entry"], "fresh")
            self.assertEqual(store.state["phase"]["entryPayload"], {"draft": True})
            self.assertTrue(store.state["escalatedDraft"])

            # DELIVER finishes normally; the terminal write still classifies escalated,
            # with `delivery` filled from whatever DELIVER managed to publish.
            store.state["products"]["deliver"] = {
                "attemptId": "attempt-d", "inputsDigest": "sha256:" + "0" * 64,
                "boundTo": {"requirements": None, "plan": None}, "exit": "delivered",
                "product": {"repos": [{
                    "repo": "repo", "pr": {"number": 1, "url": "https://example.invalid/pull/1", "headRef": "feat/x", "headSha": "c" * 40, "base": "main"},
                    "deliveredSha": "c" * 40, "caveats": [], "state": "delivered",
                }]},
                "receivedAt": "2026-01-01T00:00:00+00:00", "evidenceLevel": "human-attested",
            }
            controller._write_terminal_result(store, paths, "deliver", "delivered")

            self.assertEqual(store.state["result"]["classification"], "escalated")
            result = read_json(paths.result_json)
            self.assertEqual(result["result"], "escalated")
            self.assertIsNotNone(result["delivery"])


class CloseOutTransitionTests(_QuietStdout):
    """LF-55: an accepted ITERATE rewind registers its execute gaps as close-outs in
    the same save as its budget spend and route; EXECUTE acceptance closes them."""

    def _store(self, tmp: Path) -> tuple[StateStore, FeaturePaths]:
        return EscalatedPartialDraftTests._minimal_store(self, tmp)

    def _rewind(self) -> dict:
        return {
            "exit": "rewind", "inputsDigest": "sha256:" + "0" * 64,
            "boundTo": {"requirements": None, "plan": None}, "verdict": "unmet",
            "gaps": [{"target": "plan", "text": "split T-2"}, {"target": "execute", "text": "rename the helper"}],
            "caveats": [], "boundShas": {"repo": "c" * 40},
        }

    def test_mixed_rewind_registers_the_execute_gap_once_and_routes_to_plan(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            store, paths = self._store(tmp)
            with patch.object(store, "save", wraps=store.save) as save:
                controller._accept_product(store, paths, tmp, "iterate", "attempt-1", self._rewind())
            self.assertEqual(save.call_count, 1)  # product, spend, close-outs and route in one write
            on_disk = StateStore.open(paths).state
            self.assertEqual(on_disk["phase"]["current"], "plan")
            self.assertEqual(on_disk["budget"]["spent"], 1)
            self.assertEqual([(e["id"], e["repo"], e["source"]["gapIndex"], e["status"]) for e in on_disk["closeOuts"]],
                             [("C-1", "repo", 1, "active")])

            controller._accept_product(store, paths, tmp, "iterate", "attempt-1", self._rewind())  # replay
            self.assertEqual(store.state["budget"]["spent"], 1)
            self.assertEqual(len(store.state["closeOuts"]), 1)

    def test_crash_before_the_transition_save_persists_nothing_and_the_last_rewind_replays(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            store, paths = self._store(tmp)
            budget_module.spend(store, from_phase="plan", exit="spec gap", to_phase="spec", attempt_id="a-1", reason="gap")
            store.save()  # one rewind left: this one is the last allowed
            with patch.object(store, "save", side_effect=RuntimeError("killed")):
                with self.assertRaises(RuntimeError):
                    controller._accept_product(store, paths, tmp, "iterate", "attempt-1", self._rewind())
            store = StateStore.open(paths)
            self.assertEqual(store.state["budget"]["spent"], 1)
            self.assertIsNone(store.state["products"]["iterate"])
            self.assertFalse(store.state.get("closeOuts"))

            controller._accept_product(store, paths, tmp, "iterate", "attempt-1", self._rewind())
            store = StateStore.open(paths)
            self.assertEqual(store.state["budget"]["spent"], 2)
            self.assertEqual(store.state["phase"]["current"], "plan")
            self.assertEqual([e["id"] for e in store.state["closeOuts"]], ["C-1"])

    def test_refused_rewind_registers_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            store, paths = self._store(tmp)
            EscalatedPartialDraftTests._exhaust_budget(self, store)
            controller._accept_product(store, paths, tmp, "iterate", "attempt-1", self._rewind())
            self.assertFalse(store.state.get("closeOuts"))
            self.assertEqual(store.state["budget"]["spent"], 2)

    def test_execute_acceptance_closes_and_a_refreshed_closure_keeps_its_history(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            store, paths = self._store(tmp)
            controller._register_close_outs(store, "it-1", {"gaps": [{"target": "execute", "text": "x"}]})

            def product(head):
                review = {"reviewedRange": {"from": head, "to": head}, "verdict": "pass", "findings": [], "securityDispositions": []}
                return {"tasks": [{"id": "C-1", "disposition": "already-satisfied", "evidence": "e", "commits": [], "review": review}]}

            controller._close_close_outs(store, "attempt-e1", product("a" * 40))
            controller._close_close_outs(store, "attempt-e2", product("a" * 40))  # same closure: no churn
            entry = store.state["closeOuts"][0]
            self.assertEqual((entry["status"], entry["closure"]["attemptId"], entry["history"]), ("closed", "attempt-e1", []))
            controller._close_close_outs(store, "attempt-e3", product("b" * 40))
            self.assertEqual(entry["closure"]["reviewedRange"]["to"], "b" * 40)
            self.assertEqual([h["attemptId"] for h in entry["history"]], ["attempt-e1"])


class PauseCauseTests(unittest.TestCase):
    """LF-21: a blocked-style product names its own cause (EXECUTE's issues, VERIFY's
    blocked verdicts, DELIVER's per-repo caveats); falling through to the exit name
    read as a tautology, e.g. "DELIVER exited delivery blocked: delivery blocked"."""

    def test_execute_uses_issue_text(self):
        product = {"issues": [{"task": "T-1", "text": "reproduction still fails at head"}]}
        self.assertEqual(controller._pause_cause("execute", product, "blocked"), "T-1: reproduction still fails at head")

    def test_verify_uses_blocked_verdict_cause(self):
        product = {"verdicts": [{"criterion": "AC-1", "verdict": "blocked", "cause": "the runner errored"}]}
        self.assertEqual(controller._pause_cause("verify", product, "blocked"), "the runner errored")

    def test_deliver_uses_repo_caveats(self):
        product = {"repos": [{"repo": "repo", "caveats": ["the gh credential check failed: gh auth status"]}]}
        self.assertEqual(controller._pause_cause("deliver", product, "delivery blocked"),
                          "the gh credential check failed: gh auth status")

    def test_falls_back_to_exit_when_the_product_names_nothing(self):
        self.assertEqual(controller._pause_cause("deliver", {"repos": []}, "delivery blocked"), "delivery blocked")


class ResumeBySlugTests(_QuietStdout):
    def test_cycle_with_slug_and_no_request_resumes_the_existing_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            repo_dir = _init_repo(tmp)
            home = tmp / "home"
            with patch.dict("os.environ", _EXTERNAL_ENV, clear=False):
                started = controller.run_entry(
                    "cycle", project_root=repo_dir, request_text="Add a greeting message",
                    slug="greeting", state_home=str(home), answer_policy=None, pr=None,
                )
                resumed = controller.run_entry(
                    "cycle", project_root=repo_dir, request_text=None,
                    slug="greeting", state_home=str(home), answer_policy=None, pr=None,
                )
                self.assertEqual(resumed.kind, started.kind)
                self.assertEqual(resumed.path, started.path)

    def test_cycle_with_unknown_slug_and_no_request_raises(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            repo_dir = _init_repo(tmp)
            home = tmp / "home"
            with self.assertRaises(LoopSpecError):
                controller.run_entry(
                    "cycle", project_root=repo_dir, request_text=None,
                    slug="never-started", state_home=str(home), answer_policy=None, pr=None,
                )


class RejectedStepReissueTests(_QuietStdout):
    def test_reissued_step_carries_failure_reason_and_retry_of(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            repo_dir = _init_repo(tmp)
            home = tmp / "home"
            markers = io.StringIO()

            with patch.dict("os.environ", _EXTERNAL_ENV, clear=False):
                next_, spec_product, paths, repo_name = _start_greeting_run(repo_dir, home, markers)
                self.assertEqual(next_.kind, "step")
                first_plan_step = read_json(next_.path)

                spec_revision = postconditions.requirements_revision(spec_product)
                bad_plan_product = _greeting_plan_product(repo_name, spec_revision)
                bad_plan_product["tasks"][0]["repo"] = "bogus"  # fails P6
                atomic_write_json(Path(first_plan_step["resultPath"]), bad_plan_product)
                store = _open(paths)
                # LF-31: a single-repo run normalizes an unrecognized repo name to
                # the one repo instead of rejecting it; a second repo keeps "bogus"
                # a genuine P6 failure, which is what this test is about.
                store.state["repos"]["other"] = dict(store.state["repos"][repo_name], path=str(repo_dir))
                store.save()
                steps.submit(store, paths, step_id=first_plan_step["stepAttemptId"], dispatch_name=None, host=None)
                with contextlib.redirect_stdout(markers):
                    next_ = controller.continue_run(store, paths, project_root=repo_dir)

                self.assertEqual(next_.kind, "step")  # re-issued after the rejection
                reissued = read_json(next_.path)
                self.assertIn("P6:", reissued["reason"])
                self.assertIn("bogus", reissued["reason"])
                self.assertEqual(reissued["retryOf"], first_plan_step["stepAttemptId"])


def _minimal_spec_and_plan(repo_name: str, goal: str, criterion_text: str, task_title: str) -> tuple[dict, dict]:
    """A minimal one-criterion SPEC and one-task PLAN, shared by DEBUG's and REVISE's
    entry tests below: both need a compact {spec, plan} pair and neither cares about
    its content beyond satisfying S1-S3/P1-P7 (debug's own compact_products overrides
    "verify"/"mustFlip" on every task regardless of what is set here)."""
    spec = {
        "goal": goal, "boundaries": [], "criteria": [{"id": "AC-1", "text": criterion_text}],
        "decisions": [], "openQuestions": [],
    }
    plan = {
        "tasks": [{
            "id": "T-1", "title": task_title, "dependsOn": [], "files": ["greet.py"],
            "repo": repo_name, "verify": "true", "criteria": ["AC-1"], "featureAdded": None, "mustFlip": False,
        }],
        "prepare": None, "evidenceExceptions": [],
    }
    return spec, plan


def _start_debug_run(repo_dir, home, markers, request_text: str, slug: str):
    """Start a "debug" entry run; return (next_ for the debug lead step, paths,
    store, repo_name). Shared by DEBUG's happy-path and blocked-reproduction tests."""
    with contextlib.redirect_stdout(markers):
        next_ = controller.run_entry(
            "debug", project_root=repo_dir, request_text=request_text,
            slug=slug, state_home=str(home), answer_policy=None, pr=None,
        )
    paths = FeaturePaths(root=feature_dir(home, repo_id(repo_dir), slug))
    store = _open(paths)
    repo_name = next(iter(store.state["repos"]))
    return next_, paths, store, repo_name


class DebugAndReviseEntryTests(_QuietStdout):
    """DEBUG and REVISE both land a compact {spec, plan} pair that re-enters through
    SPEC's own approval flow and PLAN's own baseline+critic pass, then routes to
    EXECUTE (M4/M5 wiring). Every downstream ROUTES phase is forced external here so
    each test exercises the controller's own routing/compaction, not any phase
    module's internal behavior."""

    def test_debug_entry_records_base_run_and_reaches_execute(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            repo_dir = _init_repo(tmp)
            home = tmp / "home"
            markers = io.StringIO()
            repro_command = "python3 -c \"import sys; print('boom'); sys.exit(1)\""

            with patch.dict("os.environ", _EXTERNAL_ENV, clear=False):
                next_, paths, store, repo_name = _start_debug_run(
                    repo_dir, home, markers, "the greeting script crashes", "debugtest",
                )
                self.assertEqual(store.state["run"]["cycleType"], "debug")
                self.assertEqual(next_.kind, "step")

                # --- DEBUG: a real command that actually fails at base ---
                debug_step = read_json(next_.path)
                self.assertEqual(debug_step["role"], "debugger")
                spec, plan = _minimal_spec_and_plan(repo_name, "Fix the crash", "the crash no longer reproduces", "fix the crash")
                debug_product = {
                    "exit": "reproduced", "inputsDigest": "sha256:" + "0" * 64,
                    "boundTo": {"requirements": None, "plan": None},
                    "reproduction": {"command": repro_command, "failureDigest": digest_bytes(b"boom\n"), "reason": None},
                    "original": None,
                    "diagnosis": "the greeting script exits nonzero",
                    "spec": spec, "plan": plan,
                }
                atomic_write_json(Path(debug_step["resultPath"]), debug_product)
                next_ = _submit_and_continue(paths, repo_dir, markers, debug_step["stepAttemptId"])

                store = _open(paths)
                self.assertEqual(store.state["products"]["debug"]["exit"], "reproduced")
                self.assertEqual(store.state["debug"]["baseRun"]["exitStatus"], 1)
                self.assertEqual(next_.kind, "question")  # the compacted SPEC's own approval question
                next_ = _approve_compacted_spec_and_submit_critic(paths, repo_dir, markers, next_)

                store = _open(paths)
                self.assertEqual(store.state["phase"]["current"], "execute")
                self.assertEqual(next_.kind, "step")  # EXECUTE's own external step
                self.assertIsNotNone(store.state["revisions"]["requirements"])
                self.assertIsNotNone(store.state["revisions"]["plan"])

    def test_debug_entry_normalizes_dot_repo_and_reaches_execute(self):
        # LF-31: the debugger's compact plan named its one task's repo "." (meaning
        # "the one repo") instead of the repo's real name; a single-repo run
        # normalizes that before P6 sees it, instead of rejecting an obviously
        # right product and falling back to a planner lead step.
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            repo_dir = _init_repo(tmp)
            home = tmp / "home"
            markers = io.StringIO()
            repro_command = "python3 -c \"import sys; print('boom'); sys.exit(1)\""

            with patch.dict("os.environ", _EXTERNAL_ENV, clear=False):
                next_, paths, store, repo_name = _start_debug_run(
                    repo_dir, home, markers, "the greeting script crashes", "debugdotrepo",
                )
                debug_step = read_json(next_.path)
                spec, plan = _minimal_spec_and_plan(".", "Fix the crash", "the crash no longer reproduces", "fix the crash")
                debug_product = {
                    "exit": "reproduced", "inputsDigest": "sha256:" + "0" * 64,
                    "boundTo": {"requirements": None, "plan": None},
                    "reproduction": {"command": repro_command, "failureDigest": digest_bytes(b"boom\n"), "reason": None},
                    "original": None,
                    "diagnosis": "the greeting script exits nonzero",
                    "spec": spec, "plan": plan,
                }
                atomic_write_json(Path(debug_step["resultPath"]), debug_product)
                next_ = _submit_and_continue(paths, repo_dir, markers, debug_step["stepAttemptId"])
                self.assertEqual(next_.kind, "question")  # the compacted SPEC's own approval question
                next_ = _approve_compacted_spec_and_submit_critic(paths, repo_dir, markers, next_)

                store = _open(paths)
                self.assertEqual(store.state["phase"]["current"], "execute")
                self.assertEqual(next_.kind, "step")  # EXECUTE's own external step, not a re-planned PLAN
                self.assertEqual(store.state["products"]["plan"]["product"]["tasks"][0]["repo"], repo_name)

    def test_debug_entry_rejected_compact_plan_names_failures_in_the_replan_step(self):
        # LF-31: a rejection unrelated to repo (an uncovered criterion, P2) still
        # falls back to the default PLAN implementation's lead step, and that
        # step's reason names the failure (LF-03) rather than leaving it silent.
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            repo_dir = _init_repo(tmp)
            home = tmp / "home"
            markers = io.StringIO()
            repro_command = "python3 -c \"import sys; print('boom'); sys.exit(1)\""

            with patch.dict("os.environ", _EXTERNAL_ENV, clear=False):
                next_, paths, store, repo_name = _start_debug_run(
                    repo_dir, home, markers, "the greeting script crashes", "debugreject",
                )
                debug_step = read_json(next_.path)
                spec, plan = _minimal_spec_and_plan(repo_name, "Fix the crash", "the crash no longer reproduces", "fix the crash")
                plan["tasks"][0]["criteria"] = ["AC-9"]  # leaves AC-1 uncovered: a genuine P2 failure
                debug_product = {
                    "exit": "reproduced", "inputsDigest": "sha256:" + "0" * 64,
                    "boundTo": {"requirements": None, "plan": None},
                    "reproduction": {"command": repro_command, "failureDigest": digest_bytes(b"boom\n"), "reason": None},
                    "original": None,
                    "diagnosis": "the greeting script exits nonzero",
                    "spec": spec, "plan": plan,
                }
                atomic_write_json(Path(debug_step["resultPath"]), debug_product)
                next_ = _submit_and_continue(paths, repo_dir, markers, debug_step["stepAttemptId"])
                self.assertEqual(next_.kind, "question")  # the compacted SPEC's own approval question
                next_ = _answer_approve_and_continue(paths, repo_dir, markers, next_)

                store = _open(paths)
                self.assertEqual(store.state["phase"]["current"], "plan")
                self.assertEqual(store.state["phase"]["entry"], "remediation")
                self.assertEqual(next_.kind, "step")  # the default PLAN implementation's own lead step
                replan_step = read_json(next_.path)
                self.assertIn("P2", replan_step["reason"])

    def test_debug_blocked_reproduction_pauses(self):
        # B3 (a blocked-reproduction product carries no reproduction) needs
        # debug.json's own "reproduction" nullable; this pins the pause path it gates.
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            repo_dir = _init_repo(tmp)
            home = tmp / "home"
            markers = io.StringIO()

            with patch.dict("os.environ", _EXTERNAL_ENV, clear=False):
                next_, paths, store, repo_name = _start_debug_run(
                    repo_dir, home, markers, "cannot reproduce the crash", "debugblocked",
                )
                debug_step = read_json(next_.path)
                spec, plan = _minimal_spec_and_plan(repo_name, "Investigate the crash", "the crash is understood", "investigate")
                debug_product = {
                    "exit": "blocked reproduction", "inputsDigest": "sha256:" + "0" * 64,
                    "boundTo": {"requirements": None, "plan": None},
                    "reproduction": None, "original": None,
                    "diagnosis": "cannot reproduce with the given steps",
                    "spec": spec, "plan": plan,
                }
                atomic_write_json(Path(debug_step["resultPath"]), debug_product)
                next_ = _submit_and_continue(paths, repo_dir, markers, debug_step["stepAttemptId"])

                store = _open(paths)
                self.assertEqual(store.state["products"]["debug"]["exit"], "blocked reproduction")
                self.assertEqual(next_.kind, "question")
                question = read_json(next_.path)
                self.assertEqual(question["kind"], "blocked")
                self.assertEqual(store.state["phase"]["current"], "debug")
                self.assertEqual(store.state["phase"]["entry"], "remediation")

    def test_revise_entry_adopts_pr_and_reaches_execute(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            repo_dir = _init_repo(tmp)
            home = tmp / "home"
            markers = io.StringIO()

            base_sha = repo_module.head_sha(repo_dir)
            _git(repo_dir, "checkout", "-q", "-b", "pr-branch")
            (repo_dir / "greet.py").write_text("print('hi')\n", encoding="utf-8")
            _git(repo_dir, "add", "greet.py")
            _git(repo_dir, "commit", "-q", "-m", "add greeting")
            head_sha = repo_module.head_sha(repo_dir)
            _git(repo_dir, "checkout", "-q", "main")

            _add_origin(tmp, repo_dir, "main", "pr-branch")
            adoption = repo_module.PrAdoption(
                adopt=True, number=42, url="https://github.com/example/repo/pull/42", branch="pr-branch",
                base_branch="main", head_sha=head_sha, reason="named open PR #42",
            )
            gaps = [{"id": "G-1", "author": "reviewer", "body": "tighten the message", "path": None, "line": None, "url": None}]

            with patch.object(repo_module, "adopt_pr", return_value=adoption), \
                 patch.object(revise_module, "gaps_from_pr", return_value=gaps), \
                 patch.dict("os.environ", _EXTERNAL_ENV, clear=False):
                with contextlib.redirect_stdout(markers):
                    next_ = controller.run_entry(
                        "revise", project_root=repo_dir, request_text=None, slug=None,
                        state_home=str(home), answer_policy=None, pr="42",
                    )
                paths = FeaturePaths(root=feature_dir(home, repo_id(repo_dir), "revise-42"))
                store = _open(paths)
                self.assertEqual(store.state["run"]["cycleType"], "revise")  # LF-41
                repo_name = next(iter(store.state["repos"]))
                self.assertEqual(store.state["phase"]["current"], "revise")
                self.assertEqual(store.state["adoption"]["number"], 42)
                self.assertEqual(store.state["adoption"]["baseSha"], base_sha)
                self.assertEqual(store.state["revise"]["gaps"], gaps)
                self.assertEqual(next_.kind, "step")

                # --- REVISE's lead step: the reviser's compact {spec, plan} ---
                reviser_step = read_json(next_.path)
                self.assertEqual(reviser_step["role"], "reviser")
                spec, plan = _minimal_spec_and_plan(repo_name, "Tighten the greeting", "the message is tighter", "tighten it")
                reviser_product = {"spec": spec, "plan": plan}
                atomic_write_json(Path(reviser_step["resultPath"]), reviser_product)
                next_ = _submit_and_continue(paths, repo_dir, markers, reviser_step["stepAttemptId"])
                self.assertEqual(next_.kind, "question")  # the compacted SPEC's own approval question
                next_ = _approve_compacted_spec_and_submit_critic(paths, repo_dir, markers, next_)

                # --- EXECUTE entry: the one full adopted-range review, before EXECUTE's own step ---
                store = _open(paths)
                self.assertEqual(store.state["phase"]["current"], "execute")
                self.assertEqual(next_.kind, "step")
                review_step = read_json(next_.path)
                self.assertEqual(review_step["role"], "code-reviewer")
                # LF-27: the adopted review's result is model-written, so it belongs
                # under the project's results dir, never the state home.
                self.assertIn(str(Path(".loop-spec") / "results"), review_step["resultPath"])
                review_result = {
                    "sha": head_sha, "reviewedRange": {"from": base_sha, "to": head_sha},
                    "verdict": "pass", "findings": [], "securityDispositions": [],
                }
                atomic_write_json(Path(review_step["resultPath"]), review_result)
                _write_sdk_receipt(_open(paths), paths, review_step)
                next_ = _submit_and_continue(paths, repo_dir, markers, review_step["stepAttemptId"])

                store = _open(paths)
                self.assertIsNotNone(store.state.get("adoptedReview"))
                self.assertEqual(next_.kind, "step")  # EXECUTE's own external step, now that the adopted review is on record

    def test_revise_entry_delivers_after_adopting_the_prior_task(self):
        # Item B (post-PR hardening): the sibling above stops once EXECUTE's own
        # step is issued; this one drives a revise run all the way to DELIVER,
        # with a REAL prior run on disk so adoption goes through
        # controller._find_delivering_run_products for real, T-1 carried forward
        # unchanged in the reviser's plan actually gets marked "adopted" (not
        # re-implemented), and a genuinely new T-2 gets implemented, reviewed,
        # verified, and delivered on top of it.
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            repo_dir = _init_repo(tmp)
            origin = tmp / "origin.git"
            _git(tmp, "init", "-q", "--bare", str(origin))
            _git(repo_dir, "remote", "add", "origin", str(origin))
            _git(repo_dir, "push", "-q", "origin", "main")
            home = tmp / "home"
            repo_name = repo_dir.name
            rid = repo_id(repo_dir)

            base_sha = repo_module.head_sha(repo_dir)
            _git(repo_dir, "checkout", "-q", "-b", "pr-branch")
            (repo_dir / "greet.py").write_text("print('hi')\n", encoding="utf-8")
            _git(repo_dir, "add", "greet.py")
            _git(repo_dir, "commit", "-q", "-m", "add greeting")
            head_sha = repo_module.head_sha(repo_dir)
            _git(repo_dir, "checkout", "-q", "main")

            # --- the prior run that delivered PR #42 (its plan's T-1) ---
            prior_spec = {
                "goal": "Add a greeting", "boundaries": [],
                "criteria": [{"id": "AC-1", "text": "prints a greeting"}],
                "decisions": [], "openQuestions": [],
            }
            t1 = {
                "id": "T-1", "title": "add greeting", "dependsOn": [], "files": ["greet.py"],
                "repo": repo_name, "verify": "true", "criteria": ["AC-1"], "featureAdded": None, "mustFlip": False,
            }
            prior_plan = {"tasks": [t1], "prepare": None, "evidenceExceptions": []}
            prior_paths = FeaturePaths(root=feature_dir(home, rid, "delivered-42"), project_root=repo_dir)
            prior_store = StateStore.create(
                prior_paths, {"id": "run-prior", "entry": "cycle", "slug": "delivered-42", "createdAt": "2026-01-01T00:00:00+00:00"},
                "add a greeting",
            )
            prior_store.state["products"]["spec"] = {"product": prior_spec}
            prior_store.state["products"]["plan"] = {"product": prior_plan}
            prior_store.save()
            pr_url = "https://github.com/example/repo/pull/42"
            atomic_write_json(prior_paths.result_json, {"prs": [{"number": 42, "repo": repo_name, "url": pr_url}]})

            _git(repo_dir, "push", "-q", "origin", "pr-branch")
            adoption = repo_module.PrAdoption(
                adopt=True, number=42, url=pr_url, branch="pr-branch",
                base_branch="main", head_sha=head_sha, reason="named open PR #42",
            )
            gaps = [{"id": "G-1", "author": "reviewer", "body": "tighten the message", "path": None, "line": None, "url": None}]

            with patch.object(repo_module, "adopt_pr", return_value=adoption), \
                 patch.object(revise_module, "gaps_from_pr", return_value=gaps), \
                 patch.dict("os.environ", _EXTERNAL_ENV_EXCEPT_EXECUTE, clear=False):
                markers = io.StringIO()
                with contextlib.redirect_stdout(markers):
                    next_ = controller.run_entry(
                        "revise", project_root=repo_dir, request_text=None, slug=None,
                        state_home=str(home), answer_policy=None, pr="42",
                    )
                paths = FeaturePaths(root=feature_dir(home, rid, "revise-42"))
                store = _open(paths)
                self.assertEqual(store.state["run"]["cycleType"], "revise")
                self.assertEqual(store.state["revise"]["prior"], {"slug": "delivered-42", "spec": prior_spec, "plan": prior_plan})
                self.assertEqual(next_.kind, "step")

                # --- REVISE's lead step: T-1 carried forward verbatim, plus a new T-2 ---
                reviser_step = read_json(next_.path)
                t2 = {
                    "id": "T-2", "title": "add farewell", "dependsOn": [], "files": ["farewell.py"],
                    "repo": repo_name, "verify": "true", "criteria": ["AC-2"], "featureAdded": None, "mustFlip": False,
                }
                reviser_spec = {
                    "goal": "Tighten the greeting", "boundaries": [],
                    "criteria": [{"id": "AC-1", "text": "prints a greeting"}, {"id": "AC-2", "text": "prints a farewell"}],
                    "decisions": [], "openQuestions": [],
                }
                reviser_plan = {"tasks": [t1, t2], "prepare": None, "evidenceExceptions": []}
                reviser_product = {"spec": reviser_spec, "plan": reviser_plan}
                atomic_write_json(Path(reviser_step["resultPath"]), reviser_product)
                next_ = _submit_and_continue(paths, repo_dir, markers, reviser_step["stepAttemptId"])
                self.assertEqual(next_.kind, "question")  # the compacted SPEC's own approval question
                next_ = _approve_compacted_spec_and_submit_critic(paths, repo_dir, markers, next_)

                # --- the one full adopted-range review, before EXECUTE's own step ---
                store = _open(paths)
                self.assertEqual(store.state["phase"]["current"], "execute")
                self.assertEqual(next_.kind, "step")
                review_step = read_json(next_.path)
                self.assertEqual(review_step["role"], "code-reviewer")
                review_result = {
                    "sha": head_sha, "reviewedRange": {"from": base_sha, "to": head_sha},
                    "verdict": "pass", "findings": [], "securityDispositions": [],
                }
                atomic_write_json(Path(review_step["resultPath"]), review_result)
                _write_sdk_receipt(store, paths, review_step)  # E6 needs T-1's adopted-review evidence "controller-observed"
                next_ = _submit_and_continue(paths, repo_dir, markers, review_step["stepAttemptId"])
                store = _open(paths)
                adopted_review = store.state.get("adoptedReview")
                self.assertIsNotNone(adopted_review)
                self.assertEqual(next_.kind, "step")  # EXECUTE's own step: T-1 auto-adopts, T-2 dispatches

                # T-1 is marked "adopted" (and task_adopted fires) the moment EXECUTE's
                # own step() first runs, before any step is even issued for T-2.
                events_text = paths.events_jsonl.read_text()
                self.assertIn('"task_adopted"', events_text)
                store = _open(paths)
                self.assertEqual(store.state["execute"]["tasks"]["T-1"]["status"], "adopted")

                # --- EXECUTE: T-2's own implementer step, a real commit in its issued worktree ---
                implementer_step = read_json(next_.path)
                self.assertEqual(implementer_step["role"], "implementer")
                t2_worktree = Path(store.state["execute"]["tasks"]["T-2"]["worktree"])
                (t2_worktree / "farewell.py").write_text("print('bye')\n", encoding="utf-8")
                _git(t2_worktree, "add", "farewell.py")
                _git(t2_worktree, "commit", "-q", "-m", "T-2: add farewell")
                commit_sha2 = repo_module.head_sha(t2_worktree)
                implementer_result = {
                    "taskId": "T-2", "commits": [commit_sha2], "summary": "added a farewell",
                    "verifyRun": {"command": "true", "exitStatus": 0}, "issues": [],
                }
                atomic_write_json(Path(implementer_step["resultPath"]), implementer_result)
                next_ = _submit_and_continue(paths, repo_dir, markers, implementer_step["stepAttemptId"])
                self.assertEqual(next_.kind, "step")  # T-2's own code-reviewer step

                review_t2_step = read_json(next_.path)
                self.assertEqual(review_t2_step["role"], "code-reviewer")
                review_t2_result = {
                    "sha": commit_sha2, "reviewedRange": {"from": head_sha, "to": commit_sha2},
                    "verdict": "pass", "findings": [], "securityDispositions": [],
                }
                atomic_write_json(Path(review_t2_step["resultPath"]), review_t2_result)
                store = _open(paths)
                _write_sdk_receipt(store, paths, review_t2_step)  # E6 needs T-2's own review evidence "controller-observed"
                next_ = _submit_and_continue(paths, repo_dir, markers, review_t2_step["stepAttemptId"])
                self.assertEqual(next_.kind, "step")  # VERIFY's own step (EXECUTE's product just accepted)

                # Revisions are read off the STORED products (their own digest
                # includes "exit", which reviser_spec/reviser_plan -- submitted
                # without it -- never carried) rather than recomputed from the
                # dicts this test wrote, to bind to what the run actually accepted.
                store = _open(paths)
                spec_revision = store.state["revisions"]["requirements"]
                plan_revision = store.state["revisions"]["plan"]
                self.assertEqual(store.state["products"]["execute"]["exit"], "integrated")
                execute_product = store.state["products"]["execute"]["product"]
                by_id = {t["id"]: t for t in execute_product["tasks"]}
                self.assertEqual(by_id["T-1"]["disposition"], "adopted")
                self.assertEqual(by_id["T-1"]["review"], {
                    "reviewedRange": {"from": base_sha, "to": head_sha},
                    "verdict": "pass", "findings": [], "securityDispositions": [],
                })
                self.assertEqual(by_id["T-2"]["disposition"], "done")
                # Accepting EXECUTE mutates no ledger state (unlike VERIFY's own
                # acceptance -- see the VERIFY check below), so re-checking its
                # already-accepted product here is safe.
                assert_product_holds(self, store, paths, repo_dir, "execute", execute_product)

                # --- VERIFY ---
                step = read_json(next_.path)
                verify_product = {
                    "exit": "passed", "inputsDigest": "sha256:" + "0" * 64,
                    "boundTo": {"requirements": spec_revision, "plan": plan_revision},
                    "verdicts": [
                        {"criterion": "AC-1", "verdict": "pass", "cause": None, "evidence": {
                            "command": "true", "repo": repo_name, "sha": commit_sha2,
                            "exitStatus": 0, "failureIdentities": [], "outputDigest": "sha256:" + "0" * 64,
                        }},
                        {"criterion": "AC-2", "verdict": "pass", "cause": None, "evidence": {
                            "command": "true", "repo": repo_name, "sha": commit_sha2,
                            "exitStatus": 0, "failureIdentities": [], "outputDigest": "sha256:" + "0" * 64,
                        }},
                    ],
                    "findings": [], "remediationTasks": [],
                    "reviewedRanges": [{"repo": repo_name, "from": base_sha, "to": commit_sha2, "full": True}],
                }
                store = _open(paths)
                # V4 (the program's own re-run matched) is ordinarily settled by
                # controller._run_verify_reruns AFTER this product is accepted; see
                # VerifyTests._run_pass in test_verify.py for the same stand-in,
                # needed here because this checks the product BEFORE submission.
                for verdict in verify_product["verdicts"]:
                    store.state.setdefault("verifyRuns", {})[verdict["criterion"]] = {"matched": True}
                assert_product_holds(self, store, paths, repo_dir, "verify", verify_product)
                atomic_write_json(Path(step["resultPath"]), verify_product)
                next_ = _submit_and_continue(paths, repo_dir, markers, step["stepAttemptId"])
                self.assertEqual(next_.kind, "step")  # ITERATE's own step

                store = _open(paths)
                self.assertEqual(store.state["products"]["verify"]["exit"], "passed")

                # --- ITERATE ---
                step = read_json(next_.path)
                iterate_product = {
                    "exit": "converged", "inputsDigest": "sha256:" + "0" * 64,
                    "boundTo": {"requirements": spec_revision, "plan": plan_revision},
                    "verdict": "met", "gaps": [], "caveats": [], "boundShas": {repo_name: commit_sha2},
                }
                atomic_write_json(Path(step["resultPath"]), iterate_product)
                store = _open(paths)
                steps.submit(store, paths, step_id=step["stepAttemptId"], dispatch_name=None, host=None)

                def fake_run_gh(repo, *args):
                    if args[:2] == ("auth", "status"):
                        return 0, "", ""
                    if args[:2] == ("pr", "view"):
                        return 0, json.dumps({
                            "state": "OPEN", "headRefName": "pr-branch", "headRefOid": commit_sha2,
                            "baseRefName": "main", "number": 42, "url": pr_url,
                        }), ""
                    return 1, "", "unexpected gh call in test"

                with patch.object(repo_module, "run_gh", fake_run_gh):
                    with contextlib.redirect_stdout(markers):
                        next_ = controller.continue_run(store, paths, project_root=repo_dir)
                self.assertEqual(next_.kind, "step")  # DELIVER's own step

                # --- DELIVER: push the branch for real, reusing the adopted PR ---
                step = read_json(next_.path)
                _git(repo_dir, "push", "-q", "origin", "pr-branch")
                deliver_product = {
                    "exit": "delivered", "inputsDigest": "sha256:" + "0" * 64,
                    "boundTo": {"requirements": spec_revision, "plan": plan_revision},
                    "repos": [{
                        "repo": repo_name,
                        "pr": {"number": 42, "url": pr_url, "headRef": "pr-branch", "headSha": commit_sha2, "base": "main"},
                        "deliveredSha": commit_sha2, "caveats": [], "state": "delivered",
                    }],
                }
                atomic_write_json(Path(step["resultPath"]), deliver_product)
                store = _open(paths)
                steps.submit(store, paths, step_id=step["stepAttemptId"], dispatch_name=None, host=None)
                with patch.object(repo_module, "run_gh", fake_run_gh):
                    with contextlib.redirect_stdout(markers):
                        next_ = controller.continue_run(store, paths, project_root=repo_dir)

            self.assertEqual(next_.kind, "result")
            result = read_json(next_.path)
            self.assertEqual(result["result"], "converged")
            self.assertEqual(result["status"], "completed")
            self.assertEqual(result["cycleType"], "revise")

            events_text = paths.events_jsonl.read_text()
            self.assertIn('"worktrees_removed"', events_text)


def _run_one_full_external_cycle(repo_dir, home, markers, slug: str, request_text: str, filename: str) -> FeaturePaths:
    """Drive one whole "cycle" run, every phase external, from its own request text
    to a delivered terminal result -- the same shape as FullExternalCycleTests's own
    test, parameterized so WorktreeReuseTests can run it more than once against the
    same repo_dir/home with a different slug each time. Returns its FeaturePaths."""
    with contextlib.redirect_stdout(markers):
        controller.run_entry(
            "cycle", project_root=repo_dir, request_text=request_text,
            slug=slug, state_home=str(home), answer_policy=None, pr=None,
        )
    paths = FeaturePaths(root=feature_dir(home, repo_id(repo_dir), slug))
    store = _open(paths)
    repo_name = next(iter(store.state["repos"]))
    next_, spec_product = _drive_through_spec_approval(store, paths, repo_dir, markers)
    base_sha = store.state["repos"][repo_name]["baseSha"]
    feature_branch = store.state["repos"][repo_name]["featureBranch"]

    step = read_json(next_.path)
    next_, plan_product = _submit_greeting_plan(paths, repo_dir, markers, step, repo_name, spec_product)

    critic_step = read_json(next_.path)
    atomic_write_json(Path(critic_step["resultPath"]), {"findings": []})
    store = _open(paths)
    steps.submit(store, paths, step_id=critic_step["stepAttemptId"], dispatch_name=None, host=None)
    with contextlib.redirect_stdout(markers):
        next_ = controller.continue_run(store, paths, project_root=repo_dir)

    step = read_json(next_.path)
    repo_module.create_feature_branch(repo_dir, feature_branch, base_sha)
    feature_wt = home.parent / f"{slug}-wt"
    repo_module.add_worktree(repo_dir, feature_wt, branch=feature_branch)
    (feature_wt / filename).write_text("print('hi')\n", encoding="utf-8")
    _git(feature_wt, "add", filename)
    _git(feature_wt, "commit", "-q", "-m", f"T-1: add {filename}")
    commit_sha = repo_module.head_sha(feature_wt)
    repo_module.remove_worktree(repo_dir, feature_wt, force=True)

    spec_revision = postconditions.requirements_revision(spec_product)
    plan_revision = postconditions.plan_revision(plan_product)
    execute_product = {
        "exit": "integrated", "inputsDigest": "sha256:" + "0" * 64,
        "boundTo": {"requirements": spec_revision, "plan": plan_revision},
        "tasks": [{
            "id": "T-1", "disposition": "done", "evidence": None, "commits": [commit_sha],
            "review": {
                "reviewedRange": {"from": base_sha, "to": commit_sha},
                "verdict": "pass", "findings": [], "securityDispositions": [],
            },
        }],
        "issues": [], "heads": {repo_name: commit_sha},
    }
    atomic_write_json(Path(step["resultPath"]), execute_product)
    store = _open(paths)
    steps.submit(store, paths, step_id=step["stepAttemptId"], dispatch_name=None, host=None)
    with contextlib.redirect_stdout(markers):
        next_ = controller.continue_run(store, paths, project_root=repo_dir)

    step = read_json(next_.path)
    verify_product = {
        "exit": "passed", "inputsDigest": "sha256:" + "0" * 64,
        "boundTo": {"requirements": spec_revision, "plan": plan_revision},
        "verdicts": [{
            "criterion": "AC-1", "verdict": "pass",
            "evidence": {
                "command": 'python3 -c "import sys; sys.exit(0)"', "repo": repo_name, "sha": commit_sha,
                "exitStatus": 0, "failureIdentities": [], "outputDigest": "sha256:" + "0" * 64,
            },
            "cause": None,
        }],
        "findings": [], "remediationTasks": [],
        "reviewedRanges": [{"repo": repo_name, "from": base_sha, "to": commit_sha, "full": True}],
    }
    atomic_write_json(Path(step["resultPath"]), verify_product)
    store = _open(paths)
    steps.submit(store, paths, step_id=step["stepAttemptId"], dispatch_name=None, host=None)
    with contextlib.redirect_stdout(markers):
        next_ = controller.continue_run(store, paths, project_root=repo_dir)

    step = read_json(next_.path)
    iterate_product = {
        "exit": "converged", "inputsDigest": "sha256:" + "0" * 64,
        "boundTo": {"requirements": spec_revision, "plan": plan_revision},
        "verdict": "met", "gaps": [], "caveats": [], "boundShas": {repo_name: commit_sha},
    }
    atomic_write_json(Path(step["resultPath"]), iterate_product)
    store = _open(paths)
    steps.submit(store, paths, step_id=step["stepAttemptId"], dispatch_name=None, host=None)

    def fake_run_gh(repo, *args):
        if args[:2] == ("auth", "status"):
            return 0, "", ""
        if args[:2] == ("pr", "view"):
            return 0, json.dumps({
                "state": "OPEN", "headRefName": feature_branch, "headRefOid": commit_sha,
                "baseRefName": "main", "number": 1, "url": f"https://example.invalid/pull/{slug}",
            }), ""
        return 1, "", "unexpected gh call in test"

    with patch.object(repo_module, "run_gh", fake_run_gh):
        with contextlib.redirect_stdout(markers):
            next_ = controller.continue_run(store, paths, project_root=repo_dir)

    step = read_json(next_.path)
    _git(repo_dir, "push", "-q", "origin", feature_branch)
    deliver_product = {
        "exit": "delivered", "inputsDigest": "sha256:" + "0" * 64,
        "boundTo": {"requirements": spec_revision, "plan": plan_revision},
        "repos": [{
            "repo": repo_name,
            "pr": {"number": 1, "url": f"https://example.invalid/pull/{slug}", "headRef": feature_branch, "headSha": commit_sha, "base": "main"},
            "deliveredSha": commit_sha, "caveats": [], "state": "delivered",
        }],
    }
    atomic_write_json(Path(step["resultPath"]), deliver_product)
    store = _open(paths)
    steps.submit(store, paths, step_id=step["stepAttemptId"], dispatch_name=None, host=None)
    with patch.object(repo_module, "run_gh", fake_run_gh):
        with contextlib.redirect_stdout(markers):
            next_ = controller.continue_run(store, paths, project_root=repo_dir)

    assert next_.kind == "result", f"expected a terminal result, got {next_.kind}"
    return paths


class RequestAdoptionTests(unittest.TestCase):
    """EA-runs item 1b: a cycle or micro request naming an open PR continues that PR's
    branch through the same adoption revise uses (the record EXECUTE's adopted review
    reads names its repo, and the run starts at the PR head, not the merge-base)."""

    def test_a_cycle_naming_an_open_pr_adopts_it_like_revise(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            repo_dir = _init_repo(tmp)
            base_sha = repo_module.head_sha(repo_dir)
            _git(repo_dir, "checkout", "-q", "-b", "pr-branch")
            (repo_dir / "greet.py").write_text("print('hi')\n", encoding="utf-8")
            _git(repo_dir, "add", "greet.py")
            _git(repo_dir, "commit", "-q", "-m", "add greeting")
            head_sha = repo_module.head_sha(repo_dir)
            _git(repo_dir, "checkout", "-q", "main")
            _add_origin(tmp, repo_dir, "main", "pr-branch")
            _git(repo_dir, "branch", "-q", "-D", "pr-branch")
            adoption = repo_module.PrAdoption(
                adopt=True, number=42, url="https://github.com/example/repo/pull/42", branch="pr-branch",
                base_branch="main", head_sha=head_sha, reason="named open PR #42",
            )
            home = tmp / "home"
            paths = FeaturePaths(root=feature_dir(home, repo_id(repo_dir), "x"), project_root=repo_dir)
            store = StateStore.create(paths, {"id": "run-1", "entry": "cycle", "cycleType": "full", "slug": "x",
                                              "createdAt": "2026-01-01T00:00:00+00:00"}, "fix it on #42")
            with patch.object(repo_module, "adopt_pr", return_value=adoption):
                controller._resolve_repos(store, repo_dir, "x", 42, home)
            name = store.state["adoption"]["repo"]
            self.assertEqual(store.state["repos"][name]["featureBranch"], "pr-branch")
            self.assertEqual(store.state["repos"][name]["lastKnownHead"], head_sha)
            self.assertEqual(store.state["repos"][name]["baseSha"], base_sha)
            self.assertEqual(repo_module.head_sha(repo_dir, "refs/heads/pr-branch"), head_sha)


class AutoRouteTests(_QuietStdout):
    """7.3.0: an auto run's router picks an entry; the program holds the choice to
    A1/A2 and hands the run on (same run for cycle/micro/debug/direct, a revise run
    of its own for revise)."""

    def _start(self, tmp: Path, refs=None, policy=None):
        repo_dir = _init_repo(tmp)
        self.markers = io.StringIO()
        with patch.object(probes_module, "pr_refs", return_value=refs or []), contextlib.redirect_stdout(self.markers):
            next_ = controller.run_entry("auto", project_root=repo_dir, request_text="do the thing", slug="auto-1",
                                         state_home=str(tmp / "home"), answer_policy=policy, pr=None)
        paths = FeaturePaths(root=feature_dir(tmp / "home", repo_id(repo_dir), "auto-1"), project_root=repo_dir)
        return repo_dir, paths, next_

    def _route(self, repo_dir, paths, next_, entry, pr=None):
        step = read_json(next_.path)
        self.assertEqual(step["role"], "router")
        atomic_write_json(Path(step["resultPath"]), {"entry": entry, "pr": pr, "reason": f"chose {entry}"})
        _write_sdk_receipt(_open(paths), paths, step)  # the router is attested; controller-observed here
        return _submit_and_continue(paths, repo_dir, self.markers, step["stepAttemptId"])

    def test_cycle_continues_in_the_same_run(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict("os.environ", _EXTERNAL_ENV, clear=False):
            repo_dir, paths, next_ = self._start(Path(tmp))
            next_ = self._route(repo_dir, paths, next_, "cycle")
            store = _open(paths)
            self.assertEqual((store.state["run"]["cycleType"], store.state["phase"]["current"]), ("full", "spec"))
            self.assertEqual(store.state["run"]["routedTo"]["entry"], "cycle")
            self.assertEqual((next_.kind, next_.slug), ("step", "auto-1"))

    def test_micro_on_a_named_pr_adopts_it(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict("os.environ", _EXTERNAL_ENV, clear=False):
            tmp = Path(tmp)
            repo_dir = tmp / "repo"
            repo_dir, paths, next_ = self._start(tmp, refs=[{"ref": "#42", "number": 42, "url": "https://example.invalid/o/r/pull/42",
                                                             "repo": "repo", "adoptable": True, "reason": "open"}])
            _git(repo_dir, "checkout", "-q", "-b", "pr-branch")
            (repo_dir / "greet.py").write_text("print('hi')\n", encoding="utf-8")
            _git(repo_dir, "add", "greet.py")
            _git(repo_dir, "commit", "-q", "-m", "add greeting")
            head_sha = repo_module.head_sha(repo_dir)
            _git(repo_dir, "checkout", "-q", "main")
            _add_origin(tmp, repo_dir, "main", "pr-branch")
            adoption = repo_module.PrAdoption(adopt=True, number=42, url="https://example.invalid/o/r/pull/42",
                                              branch="pr-branch", base_branch="main", head_sha=head_sha, reason="open")
            store = _open(paths)
            store.state["route"]["facts"]["prRefs"][0]["repo"] = next(iter(store.state["repos"]))
            store.save()
            with patch.object(repo_module, "adopt_pr", return_value=adoption):
                self._route(repo_dir, paths, next_, "micro", 42)
            store = _open(paths)
            self.assertEqual(store.state["run"]["cycleType"], "micro")
            self.assertEqual(store.state["adoption"]["repo"], next(iter(store.state["repos"])))
            self.assertEqual(next(iter(store.state["repos"].values()))["lastKnownHead"], head_sha)

    def test_revise_is_its_own_run_and_the_auto_run_records_where_it_went(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict("os.environ", _EXTERNAL_ENV, clear=False):
            tmp = Path(tmp)
            url = "https://example.invalid/o/r/pull/42"
            repo_dir, paths, next_ = self._start(tmp, refs=[{"ref": url, "number": 42, "url": url, "repo": "repo",
                                                             "adoptable": True, "reason": "open"}], policy="default")
            _git(repo_dir, "checkout", "-q", "-b", "pr-branch")
            (repo_dir / "greet.py").write_text("print('hi')\n", encoding="utf-8")
            _git(repo_dir, "add", "greet.py")
            _git(repo_dir, "commit", "-q", "-m", "add greeting")
            head_sha = repo_module.head_sha(repo_dir)
            _git(repo_dir, "checkout", "-q", "main")
            _add_origin(tmp, repo_dir, "main", "pr-branch")
            adoption = repo_module.PrAdoption(adopt=True, number=42, url=url, branch="pr-branch", base_branch="main",
                                              head_sha=head_sha, reason="open")
            store = _open(paths)
            store.state["route"]["facts"]["prRefs"][0]["repo"] = next(iter(store.state["repos"]))
            store.save()
            with patch.object(repo_module, "adopt_pr", return_value=adoption), \
                 patch.object(revise_module, "gaps_from_pr", return_value=[]):
                next_ = self._route(repo_dir, paths, next_, "revise", 42)
            self.assertEqual(next_.slug, "revise-42")
            result = read_json(paths.result_json)
            self.assertEqual((result["result"], result["routedTo"]["slug"]), ("routed", "revise-42"))
            self.assertFalse(paths.last_result_json.exists())
            revise_paths = FeaturePaths(root=paths.root.parent / "revise-42", project_root=repo_dir)
            self.assertEqual(_open(revise_paths).state["questions"]["policy"], "default")
            with contextlib.redirect_stdout(self.markers):
                again = controller.continue_run(_open(paths), paths, project_root=repo_dir)
            self.assertEqual(again.slug, "revise-42")

    def test_direct_ends_with_a_direct_result_and_no_gate(self):
        for exit_, blocker, expected in (("done", None, "direct"), ("incomplete", "the conflict needs a design call", "escalated")):
            with self.subTest(exit=exit_), tempfile.TemporaryDirectory() as tmp:
                repo_dir, paths, next_ = self._start(Path(tmp))
                _add_origin(Path(tmp), repo_dir, "main")
                next_ = self._route(repo_dir, paths, next_, "direct")
                step = read_json(next_.path)
                self.assertEqual((step["kind"], step["role"]), ("lead", "direct"))
                # LF-72 (live ea-a): a checked push makes workDelivered true with no DELIVER product.
                push = {"kind": "push", "repo": next(iter(_open(paths).state["repos"])), "ref": "main",
                        "sha": repo_module.head_sha(repo_dir), "url": None, "detail": "push main"}
                atomic_write_json(Path(step["resultPath"]), {
                    "exit": exit_, "inputsDigest": step["inputsDigest"], "boundTo": {"requirements": None, "plan": None},
                    "summary": "merged main", "actions": [push], "blocker": blocker})
                next_ = _submit_and_continue(paths, repo_dir, self.markers, step["stepAttemptId"])
                result = read_json(paths.result_json)
                self.assertEqual((next_.kind, result["result"], result["cycleType"]), ("result", expected, "direct"))
                if exit_ == "done":
                    self.assertTrue(result["workDelivered"])
                    self.assertTrue(any("no gate ran" in w for w in result["warnings"]))
                else:
                    self.assertEqual(result["reason"], blocker)

    def test_a_refused_choice_is_asked_again_with_the_rule_then_stops(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo_dir, paths, next_ = self._start(Path(tmp), policy="default")
            next_ = self._route(repo_dir, paths, next_, "revise", None)
            self.assertIn("route-refused:pr-not-adoptable", read_json(next_.path)["reason"])
            for _ in range(5):
                if next_.kind == "result":
                    break
                next_ = self._route(repo_dir, paths, next_, "revise", None)
            self.assertEqual(read_json(paths.result_json)["result"], "escalated")


class WorktreeReuseTests(_QuietStdout):
    """LF-39: a terminal run removes its own worktrees so a LATER run against the
    same repo is never refused by one it left behind."""

    def test_two_sequential_runs_share_one_repo(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            repo_dir = _init_repo(tmp)
            origin = tmp / "origin.git"
            _git(tmp, "init", "-q", "--bare", str(origin))
            _git(repo_dir, "remote", "add", "origin", str(origin))
            _git(repo_dir, "push", "-q", "origin", "main")
            home = tmp / "home"
            markers = io.StringIO()

            with patch.dict("os.environ", _EXTERNAL_ENV, clear=False):
                first_paths = _run_one_full_external_cycle(
                    repo_dir, home, markers, "greeting-one", "Add a greeting message", "greet.py",
                )
            first_result = read_json(first_paths.result_json)
            self.assertEqual(first_result["status"], "completed")

            worktree_listing = repo_module.run_git(repo_dir, "worktree", "list", "--porcelain")
            self.assertNotIn(str(first_paths.root), worktree_listing)

            # --- second run: a different slug/request, EXECUTE left at "default" so
            # it issues its own implementer step (an external EXECUTE, as the first
            # run used, never touches add_worktree itself -- LF-39's own bug site). ---
            with patch.dict("os.environ", _EXTERNAL_ENV_EXCEPT_EXECUTE, clear=False):
                with contextlib.redirect_stdout(markers):
                    controller.run_entry(
                        "cycle", project_root=repo_dir, request_text="Add a farewell message",
                        slug="greeting-two", state_home=str(home), answer_policy=None, pr=None,
                    )
                second_paths = FeaturePaths(root=feature_dir(home, repo_id(repo_dir), "greeting-two"))
                store = _open(second_paths)
                repo_name = next(iter(store.state["repos"]))
                next_, spec_product = _drive_through_spec_approval(store, second_paths, repo_dir, markers)

                step = read_json(next_.path)
                plan_product = {
                    "exit": "ready", "inputsDigest": "sha256:" + "0" * 64,
                    "boundTo": {"requirements": postconditions.requirements_revision(spec_product), "plan": None},
                    "tasks": [{
                        "id": "T-1", "title": "add farewell", "dependsOn": [], "files": ["farewell.py"],
                        "repo": repo_name, "verify": "true", "criteria": ["AC-1"], "featureAdded": None, "mustFlip": False,
                    }],
                    "prepare": None, "evidenceExceptions": [],
                }
                atomic_write_json(Path(step["resultPath"]), plan_product)
                store = _open(second_paths)
                steps.submit(store, second_paths, step_id=step["stepAttemptId"], dispatch_name=None, host=None)
                with contextlib.redirect_stdout(markers):
                    next_ = controller.continue_run(store, second_paths, project_root=repo_dir)

                critic_step = read_json(next_.path)
                atomic_write_json(Path(critic_step["resultPath"]), {"findings": []})
                store = _open(second_paths)
                steps.submit(store, second_paths, step_id=critic_step["stepAttemptId"], dispatch_name=None, host=None)
                with contextlib.redirect_stdout(markers):
                    next_ = controller.continue_run(store, second_paths, project_root=repo_dir)

            # EXECUTE's own default step() ran _init() (its own add_worktree call for
            # the feature branch, plus one per dispatched task) with no "already used
            # by worktree" LoopSpecError -- the very failure LF-39 fixed.
            self.assertEqual(next_.kind, "step")
            implementer_step = read_json(next_.path)
            self.assertEqual(implementer_step["role"], "implementer")

            second_listing = repo_module.run_git(repo_dir, "worktree", "list", "--porcelain")
            self.assertNotIn(str(first_paths.root), second_listing)


class BaselineCaptureTests(unittest.TestCase):
    """R3: a workspace baseline is captured (and re-checked at EXECUTE) per repo,
    never always the first one."""

    def test_capture_and_rerun_use_each_tasks_own_repo(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            repo_a = _init_repo(tmp)
            (repo_a / "check.py").write_text("import sys; sys.exit(0)\n", encoding="utf-8")
            _git(repo_a, "add", "check.py")
            _git(repo_a, "commit", "-q", "-m", "add check")
            head_a = repo_module.head_sha(repo_a)

            repo_b = tmp / "repo-b"
            repo_b.mkdir()
            _git(repo_b, "init", "-q", "-b", "main")
            _git(repo_b, "config", "user.email", "test@example.com")
            _git(repo_b, "config", "user.name", "Test")
            (repo_b / "README.md").write_text("hello from b\n", encoding="utf-8")
            _git(repo_b, "add", "README.md")
            _git(repo_b, "commit", "-q", "-m", "init")
            # Same command string as A's, a DIFFERENT check.py: if capture or the
            # EXECUTE re-run ever ran against A's checkout for B's task (the
            # pre-fix bug), this would come back 0, not 1.
            (repo_b / "check.py").write_text("import sys; sys.exit(1)\n", encoding="utf-8")
            _git(repo_b, "add", "check.py")
            _git(repo_b, "commit", "-q", "-m", "add check")
            head_b = repo_module.head_sha(repo_b)

            paths = FeaturePaths(root=tmp / "feature")
            store = StateStore.create(
                paths, {"id": "run-1", "entry": "cycle", "cycleType": "full", "slug": "x", "createdAt": "2026-01-01T00:00:00+00:00"}, "do it",
            )
            store.state["repos"] = {
                "a": {"path": str(repo_a), "baseSha": head_a, "featureBranch": "feat/x", "defaultBranch": "main", "lastKnownHead": head_a},
                "b": {"path": str(repo_b), "baseSha": head_b, "featureBranch": "feat/x", "defaultBranch": "main", "lastKnownHead": head_b},
            }
            store.save()

            plan_product = {
                "tasks": [
                    {"id": "T-a", "title": "a", "dependsOn": [], "files": [], "repo": "a", "verify": "python3 check.py",
                     "criteria": ["AC-a"], "featureAdded": None, "mustFlip": False},
                    {"id": "T-b", "title": "b", "dependsOn": [], "files": [], "repo": "b", "verify": "python3 check.py",
                     "criteria": ["AC-b"], "featureAdded": None, "mustFlip": False},
                ],
                "prepare": None,
            }
            controller._capture_plan_baseline(store, paths, plan_product, "rev-1")

            baseline = store.state["baseline"]
            self.assertEqual(set(baseline["repos"]), {"a", "b"})
            entry_a = baseline["repos"]["a"]["entries"]["python3 check.py"]
            entry_b = baseline["repos"]["b"]["entries"]["python3 check.py"]
            self.assertEqual(entry_a["run"]["exitStatus"], 0)
            self.assertEqual(entry_b["run"]["exitStatus"], 1)

            # --- EXECUTE's own re-run: T-b's record names repo B's own SHA ---
            store.state["products"]["plan"] = {"product": plan_product}
            execute_product = {"heads": {"a": head_a, "b": head_b}, "tasks": [
                {"id": "T-a", "disposition": "done", "evidence": None, "commits": [], "review": None},
                {"id": "T-b", "disposition": "done", "evidence": None, "commits": [], "review": None},
            ]}
            controller._run_execute_verifications(store, paths, execute_product)
            runs = store.state["executeRuns"]
            self.assertEqual(runs["T-a"]["run"]["sha"], head_a)
            self.assertEqual(runs["T-b"]["run"]["sha"], head_b)
            self.assertEqual(runs["T-b"]["run"]["exitStatus"], 1)
            self.assertEqual(runs["T-b"]["comparison"]["verdict"], "no-regression")  # matches B's own baseline

    def test_migrate_legacy_baseline_wraps_the_sole_repos_flat_shape(self):
        # R3: a run whose baseline was captured before the per-repo shape existed
        # (flat, no "repos" key) is migrated in place the first time EXECUTE's
        # phase is driven afterward, since with exactly one repo there is only
        # one thing that flat baseline could ever have meant.
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            repo = _init_repo(tmp)
            head = repo_module.head_sha(repo)
            paths = FeaturePaths(root=tmp / "feature")
            store = StateStore.create(
                paths, {"id": "run-1", "entry": "cycle", "cycleType": "full", "slug": "x", "createdAt": "2026-01-01T00:00:00+00:00"}, "do it",
            )
            store.state["repos"] = {
                "repo": {"path": str(repo), "baseSha": head, "featureBranch": "feat/x", "defaultBranch": "main", "lastKnownHead": head},
            }
            store.state["baseline"] = {
                "baseSha": head, "repo": "repo", "prepare": None, "prepareRun": None,
                "entries": {"true": {"command": "true", "task": "T-1", "status": "ran", "run": None}},
                "capturedAt": "2026-01-01T00:00:00+00:00", "normalizationVersion": 1, "planRevision": "rev-1",
            }
            store.save()

            controller._migrate_legacy_baseline(store, paths)

            self.assertEqual(store.state["baseline"]["planRevision"], "rev-1")
            migrated = store.state["baseline"]["repos"]["repo"]
            self.assertEqual(migrated["baseSha"], head)
            self.assertEqual(migrated["entries"]["true"]["task"], "T-1")
            self.assertNotIn("planRevision", migrated)
            events_text = paths.events_jsonl.read_text()
            self.assertIn('"module_state_reset"', events_text)

            # Idempotent: a second call on the already-migrated state is a no-op.
            controller._migrate_legacy_baseline(store, paths)
            self.assertEqual(store.state["baseline"]["repos"]["repo"], migrated)


class VerifyRerunsTests(unittest.TestCase):
    """LF-28: V4's clean re-run has to happen in the repo a verdict's evidence
    names, not always the workspace's first repo."""

    def test_run_verify_reruns_checks_out_each_verdicts_own_repo(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            repo_a = _init_repo(tmp)
            head_a = repo_module.head_sha(repo_a)

            repo_b = tmp / "repo-b"
            repo_b.mkdir()
            _git(repo_b, "init", "-q", "-b", "main")
            _git(repo_b, "config", "user.email", "test@example.com")
            _git(repo_b, "config", "user.name", "Test")
            (repo_b / "README.md").write_text("hello from b\n", encoding="utf-8")
            _git(repo_b, "add", "README.md")
            _git(repo_b, "commit", "-q", "-m", "init")
            head_b = repo_module.head_sha(repo_b)

            paths = FeaturePaths(root=tmp / "feature")
            store = StateStore.create(
                paths, {"id": "run-1", "entry": "cycle", "cycleType": "full", "slug": "x", "createdAt": "2026-01-01T00:00:00+00:00"}, "do it",
            )
            store.state["repos"] = {
                "a": {"path": str(repo_a), "baseSha": head_a, "featureBranch": "feat/x", "defaultBranch": "main", "lastKnownHead": head_a},
                "b": {"path": str(repo_b), "baseSha": head_b, "featureBranch": "feat/x", "defaultBranch": "main", "lastKnownHead": head_b},
            }
            store.state["products"]["execute"] = {
                "attemptId": "attempt-e", "inputsDigest": "sha256:" + "0" * 64,
                "boundTo": {"requirements": None, "plan": None}, "exit": "no change",
                "product": {"heads": {"a": head_a, "b": head_b}, "tasks": []},
                "receivedAt": "2026-01-01T00:00:00+00:00", "evidenceLevel": "human-attested",
            }
            store.state["products"]["plan"] = {
                "attemptId": "attempt-p", "inputsDigest": "sha256:" + "0" * 64,
                "boundTo": {"requirements": None, "plan": None}, "exit": "ready",
                "product": {"prepare": None}, "receivedAt": "2026-01-01T00:00:00+00:00", "evidenceLevel": "human-attested",
            }
            store.save()

            # Each command only succeeds against its OWN repo's checkout, so a
            # re-run against the wrong repo (the pre-fix bug: always the first
            # repo in the workspace) would fail to match.
            verify_product = {
                "verdicts": [
                    {"criterion": "AC-a", "verdict": "pass", "cause": None, "evidence": {
                        "command": "cat README.md", "repo": "a", "sha": head_a,
                        "exitStatus": 0, "failureIdentities": [], "outputDigest": "sha256:" + "0" * 64,
                    }},
                    {"criterion": "AC-b", "verdict": "pass", "cause": None, "evidence": {
                        "command": 'grep -q "from b" README.md', "repo": "b", "sha": head_b,
                        "exitStatus": 0, "failureIdentities": [], "outputDigest": "sha256:" + "0" * 64,
                    }},
                ],
            }
            controller._run_verify_reruns(store, paths, verify_product)
            runs = store.state["verifyRuns"]
            self.assertEqual(runs["AC-a"]["repo"], "a")
            self.assertEqual(runs["AC-b"]["repo"], "b")
            self.assertTrue(runs["AC-a"]["matched"])
            self.assertTrue(runs["AC-b"]["matched"])

    def _single_repo_store(self, tmp: Path, repo_dir: Path, head: str) -> tuple[FeaturePaths, StateStore]:
        paths = FeaturePaths(root=tmp / "feature")
        store = StateStore.create(
            paths, {"id": "run-1", "entry": "cycle", "cycleType": "full", "slug": "x", "createdAt": "2026-01-01T00:00:00+00:00"}, "do it",
        )
        store.state["repos"] = {
            "repo": {"path": str(repo_dir), "baseSha": head, "featureBranch": "feat/x", "defaultBranch": "main", "lastKnownHead": head},
        }
        store.state["products"]["execute"] = {
            "attemptId": "attempt-e", "inputsDigest": "sha256:" + "0" * 64,
            "boundTo": {"requirements": None, "plan": None}, "exit": "no change",
            "product": {"heads": {"repo": head}, "tasks": []},
            "receivedAt": "2026-01-01T00:00:00+00:00", "evidenceLevel": "human-attested",
        }
        store.state["products"]["plan"] = {
            "attemptId": "attempt-p", "inputsDigest": "sha256:" + "0" * 64,
            "boundTo": {"requirements": None, "plan": None}, "exit": "ready",
            "product": {"prepare": None}, "receivedAt": "2026-01-01T00:00:00+00:00", "evidenceLevel": "human-attested",
        }
        return paths, store

    def test_run_verify_reruns_runs_again_when_prepare_changed(self):
        """7.2.0: a cached execution is reused only under the same prepare command."""
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            repo = _init_repo(tmp)
            head = repo_module.head_sha(repo)
            paths, store = self._single_repo_store(tmp, repo, head)
            store.save()
            evidence = {"command": 'python3 -c "import sys; sys.exit(0)"', "repo": "repo", "sha": head,
                        "exitStatus": 0, "failureIdentities": [], "outputDigest": "sha256:" + "0" * 64}
            product = {"verdicts": [{"criterion": "AC-1", "verdict": "pass", "cause": None, "evidence": evidence}]}
            controller._run_verify_reruns(store, paths, product)
            real = controller.baseline_module.run_command
            with patch("loop_spec.controller.baseline_module.run_command", side_effect=real) as run:
                controller._run_verify_reruns(store, paths, product)
                self.assertEqual(run.call_count, 0)
                store.state["products"]["plan"]["product"]["prepare"] = "true"
                controller._run_verify_reruns(store, paths, product)
                self.assertEqual(run.call_count, 2)  # prepare, then the evidence command
            self.assertEqual(store.state["verifyRuns"]["AC-1"]["prepare"], "true")

    def test_run_verify_reruns_rechecks_a_changed_claim_against_a_cached_execution(self):
        # R9: a cached execution (same repo/sha/command) may be reused, but
        # "matched" must be re-evaluated against the CURRENT claim every time,
        # not trusted as a fact recorded by an earlier, possibly different, claim.
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            repo = _init_repo(tmp)
            head = repo_module.head_sha(repo)
            paths, store = self._single_repo_store(tmp, repo, head)
            store.save()

            evidence = {
                "command": 'python3 -c "import sys; sys.exit(0)"', "repo": "repo", "sha": head,
                "exitStatus": 0, "failureIdentities": [], "outputDigest": "sha256:" + "0" * 64,
            }
            verify_product = {"verdicts": [{"criterion": "AC-1", "verdict": "pass", "cause": None, "evidence": evidence}]}
            controller._run_verify_reruns(store, paths, verify_product)
            self.assertTrue(store.state["verifyRuns"]["AC-1"]["matched"])

            # Same sha/command, a different claimed exit status.
            changed_evidence = dict(evidence, exitStatus=7)
            changed_product = {"verdicts": [{"criterion": "AC-1", "verdict": "pass", "cause": None, "evidence": changed_evidence}]}
            controller._run_verify_reruns(store, paths, changed_product)
            self.assertFalse(store.state["verifyRuns"]["AC-1"]["matched"])

            boundary = postconditions.Boundary(
                store, paths, phase="verify", product=changed_product, exit="passed", project_root=repo,
            )
            self.assertIsNotNone(boundary._v4())

    def test_run_verify_reruns_never_executes_an_exempt_criterions_command(self):
        # R10: an approved non-repeatable command must never run a second time --
        # not even once more here, to find out it was exempt. A criterion in
        # verifyExceptionsThisAttempt is skipped before any re-run is scheduled.
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            repo = _init_repo(tmp)
            head = repo_module.head_sha(repo)
            marker = tmp / "marker"
            paths, store = self._single_repo_store(tmp, repo, head)
            store.state["verifyExceptionsThisAttempt"] = [{"criterion": "AC-1", "reason": "not repeatable"}]
            store.save()

            verify_product = {
                "verdicts": [{
                    "criterion": "AC-1", "verdict": "pass", "cause": None,
                    "evidence": {
                        "command": f"python3 -c \"open({str(marker)!r}, 'w').close()\"", "repo": "repo", "sha": head,
                        "exitStatus": 0, "failureIdentities": [], "outputDigest": "sha256:" + "0" * 64,
                    },
                }],
            }
            controller._run_verify_reruns(store, paths, verify_product)
            self.assertFalse(marker.exists())
            self.assertNotIn("AC-1", store.state["verifyRuns"])

    def test_run_verify_reruns_never_runs_a_shell_evidence_command_and_drops_its_record(self):
        # LF-53: a malformed claimed command is never run, exempt or not, and a
        # matched record an earlier submission left must not stand in for it.
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            repo = _init_repo(tmp)
            head = repo_module.head_sha(repo)
            paths, store = self._single_repo_store(tmp, repo, head)
            for exempt in (False, True):
                with self.subTest(exempt=exempt):
                    store.state["verifyExceptionsThisAttempt"] = (
                        [{"criterion": "AC-1", "reason": "not repeatable"}] if exempt else []
                    )
                    store.state["verifyRuns"] = {"AC-1": {"rerun": {"command": "pytest -q"}, "matched": True, "reason": "", "repo": "repo"}}
                    store.save()
                    verify_product = {"verdicts": [{
                        "criterion": "AC-1", "verdict": "pass", "cause": None,
                        "evidence": {"command": "pytest -q && true", "repo": "repo", "sha": head, "exitStatus": 0,
                                     "failureIdentities": [], "outputDigest": "sha256:" + "0" * 64},
                    }]}
                    with patch.object(controller.baseline_module, "run_command", side_effect=AssertionError("ran")):
                        controller._run_verify_reruns(store, paths, verify_product)
                    self.assertNotIn("AC-1", store.state["verifyRuns"])

    def test_plan_with_a_shell_command_skips_baseline_capture(self):
        # LF-53: no checkout, prepare, or verify command runs for a malformed plan.
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            repo = _init_repo(tmp)
            head = repo_module.head_sha(repo)
            paths, store = self._single_repo_store(tmp, repo, head)
            product = {"exit": "ready", "prepare": None, "tasks": [
                {"id": "T-1", "verify": "pytest -q && true", "repo": "repo", "featureAdded": None},
            ]}
            with patch.object(postconditions.Boundary, "check", return_value=[]), \
                    patch.object(controller, "_capture_plan_baseline", side_effect=AssertionError("captured")):
                self.assertEqual(controller._handle_plan_baseline_and_critic(store, paths, repo, "a-1", product), "ready")

    def test_debug_with_a_shell_reproduction_is_rejected_before_its_base_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            repo = _init_repo(tmp)
            head = repo_module.head_sha(repo)
            paths, store = self._single_repo_store(tmp, repo, head)
            store.save()
            product = {"reproduction": {"command": "cd pkg && pytest", "failureDigest": "sha256:" + "d" * 64, "reason": None},
                       "original": None}
            with patch.object(controller.debug_module, "record_base_runs", side_effect=AssertionError("ran")):
                controller._accept_debug_product(store, paths, repo, "a-1", product, "reproduced")
            failures = store.state["phase"]["entryPayload"]["rejected"]["failures"]
            self.assertEqual([f["id"] for f in failures], ["B1"])
            self.assertIn("'&&'", failures[0]["message"])


class CriticFactsAndDefaultTests(unittest.TestCase):
    """LF-54: the PLAN critic judges each verify command on the facts the comparator
    uses, a changed input re-issues it, and its own recommendation becomes the
    blocked question's default."""

    def _store(self, tmp: Path):
        paths = FeaturePaths(root=tmp / "feature")
        store = StateStore.create(
            paths, {"id": "run-1", "entry": "cycle", "cycleType": "full", "slug": "x", "createdAt": "2026-01-01T00:00:00+00:00"}, "do it",
        )
        store.state["repos"] = {"repo": {"path": str(tmp), "baseSha": "b" * 40, "featureBranch": "feat/x",
                                         "defaultBranch": "main", "lastKnownHead": "b" * 40}}
        return paths, store

    @staticmethod
    def _run(command, **overrides):
        run = {"command": command, "cwd": "/x", "sha": "b" * 40, "exitStatus": 1, "runner": "pytest",
               "failureIdentities": [], "fingerprints": [], "outputDigest": "sha256:" + "0" * 64,
               "normalizedDigest": "sha256:" + "0" * 64, "normalizationVersion": 1,
               "startedAt": "2026-01-01T00:00:00+00:00", "elapsedSeconds": 0.1, "errorClass": None,
               "testsRan": 2, "logPath": None}
        return {**run, **overrides}

    def _plan_and_baseline(self, store):
        tasks = [
            {"id": "T-1", "repo": "repo", "verify": "pytest -q tests/test_calc.py", "featureAdded": None, "mustFlip": False},
            {"id": "T-2", "repo": "repo", "verify": "make check", "featureAdded": None, "mustFlip": False},
            {"id": "T-3", "repo": "repo", "verify": "pytest -q tests/test_new.py", "featureAdded": "tests/test_new.py", "mustFlip": False},
            {"id": "T-4", "repo": "repo", "verify": "pytest -q tests/test_broken.py", "featureAdded": None, "mustFlip": False},
            {"id": "T-5", "repo": "repo", "verify": "pytest -q tests/test_repro.py", "featureAdded": None, "mustFlip": True},
            {"id": "T-6", "repo": "repo", "verify": "pytest -q tests/test_absent.py", "featureAdded": None, "mustFlip": False},
        ]
        entries = {
            "pytest -q tests/test_calc.py": {"command": "pytest -q tests/test_calc.py", "task": "T-1", "status": "ran",
                                             "run": self._run("pytest -q tests/test_calc.py", failureIdentities=["tests/test_calc.py::test_preexisting_failure"])},
            "make check": {"command": "make check", "task": "T-2", "status": "ran",
                           "run": self._run("make check", runner=None, fingerprints=["fp-1"], testsRan=0)},
            "pytest -q tests/test_new.py": {"command": "pytest -q tests/test_new.py", "task": "T-3", "status": "no-baseline", "run": None},
            "pytest -q tests/test_broken.py": {"command": "pytest -q tests/test_broken.py", "task": "T-4", "status": "ran",
                                               "run": self._run("pytest -q tests/test_broken.py", exitStatus=2, testsRan=0)},
            "pytest -q tests/test_repro.py": {"command": "pytest -q tests/test_repro.py", "task": "T-5", "status": "ran",
                                              "run": self._run("pytest -q tests/test_repro.py", failureIdentities=["tests/test_repro.py::test_bug"])},
        }
        store.state["baseline"] = {"planRevision": "rev-1", "repos": {"repo": {"baseSha": "b" * 40, "entries": entries}}}
        return {"tasks": tasks}

    def test_baseline_facts_carry_what_the_comparator_uses(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths, store = self._store(Path(tmp))
            facts = {f["task"]: f for f in controller._critic_baseline_facts(store, self._plan_and_baseline(store))}
            self.assertEqual((facts["T-1"]["status"], facts["T-1"]["mode"]), ("ran", "regression"))
            self.assertEqual(facts["T-1"]["failureIdentities"], ["tests/test_calc.py::test_preexisting_failure"])
            self.assertEqual(facts["T-2"]["fingerprints"], ["fp-1"])  # no parser: fingerprints decide
            self.assertEqual((facts["T-3"]["status"], facts["T-3"]["mode"]), ("no-baseline", "featureAdded"))
            self.assertEqual(facts["T-4"]["status"], "incomplete")  # nonzero, nothing parsed
            self.assertEqual(facts["T-5"]["mode"], "mustFlip")
            self.assertEqual(facts["T-6"]["status"], "missing")
            self.assertEqual(facts["T-1"]["baseSha"], "b" * 40)

    def test_a_changed_baseline_or_requirements_revision_is_a_new_critic_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths, store = self._store(Path(tmp))
            plan = self._plan_and_baseline(store)
            store.state["revisions"]["requirements"] = "req-1"
            before = controller._critic_identity(store, "rev-1", controller._critic_baseline_facts(store, plan))
            self.assertEqual(before, controller._critic_identity(store, "rev-1", controller._critic_baseline_facts(store, plan)))
            store.state["baseline"]["repos"]["repo"]["entries"]["make check"]["run"]["fingerprints"] = ["fp-2"]
            changed_baseline = controller._critic_identity(store, "rev-1", controller._critic_baseline_facts(store, plan))
            self.assertNotEqual(before, changed_baseline)
            store.state["revisions"]["requirements"] = "req-2"
            self.assertNotEqual(changed_baseline, controller._critic_identity(store, "rev-1", controller._critic_baseline_facts(store, plan)))

    def test_a_submitted_step_for_other_inputs_is_not_reused(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths, store = self._store(Path(tmp))
            result_path = Path(tmp) / "critic.json"
            atomic_write_json(result_path, {"findings": []})
            step_dir = paths.steps_dir / "step-1"
            step_dir.mkdir(parents=True)
            atomic_write_json(step_dir / "step.json", {"resultPath": str(result_path)})
            store.state["steps"]["submissions"]["step-1"] = {"at": "now", "evidenceLevel": "host-attested"}
            store.state["phase"].update(criticStepId="step-1", criticStepRevision="rev-1", criticStepIdentity="id-old")
            self.assertIsNone(controller._critic_submission(store, paths, Path(tmp), "rev-1", "id-new"))
            del store.state["phase"]["criticStepIdentity"]  # an older run's step: no identity recorded
            self.assertIsNone(controller._critic_submission(store, paths, Path(tmp), "rev-1", "id-new"))
            store.state["phase"]["criticStepIdentity"] = "id-new"
            self.assertEqual(controller._critic_submission(store, paths, Path(tmp), "rev-1", "id-new"), {"findings": []})
            store.state["steps"]["submissions"]["step-1"]["evidenceLevel"] = "unattested"  # LF-60: an old auto-waiver
            self.assertIsNone(controller._critic_submission(store, paths, Path(tmp), "rev-1", "id-new"))

    def test_default_from_recommendations(self):
        reject = lambda fid, reason: {"id": fid, "recommendation": {"action": "reject", "reason": reason}}
        spec_gap = {"id": "F-2", "recommendation": {"action": "spec gap", "reason": "the criterion is untestable"}}
        self.assertEqual(controller._critic_default([reject("F-1", "fine"), spec_gap]), "spec gap")
        self.assertEqual(controller._critic_default([reject("F-1", "a"), reject("F-3", "b ")]), "F-1: a; F-3: b")
        # An older or bound critic that writes no recommendation: a person decides.
        self.assertIsNone(controller._critic_default([reject("F-1", "a"), {"id": "F-4"}]))
        self.assertIsNone(controller._critic_default([reject("F-1", "  ")]))

    def test_policy_answer_closes_the_finding_with_the_recommended_reason(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths, store = self._store(Path(tmp))
            finding = {"id": "F-1", "location": "T-2.verify", "cause": "exits non-zero at base", "severity": "Critical",
                       "disposition": "open", "reason": None, "supersedes": None,
                       "recommendation": {"action": "reject", "reason": "failure identities are compared with base"}}
            store.state["critic"] = {"passes": 2, "findings": [finding], "planRevision": "rev-1"}
            store.state["questions"]["policy"] = "default"
            record = questions.ask(store, paths, phase="plan", attempt_id="a-1", text="blocked", kind="text",
                                   options=[{"value": "spec gap", "label": "Spec gap"}],
                                   default_value=controller._critic_default([finding]), payload=None)
            answered = store.state["questions"]["answered"][record["questionId"]]  # LF-62: ask applied the policy
            self.assertEqual((answered["by"], answered["value"]), ("policy", "F-1: failure identities are compared with base"))
            self.assertIn(record["questionId"], store.state["questions"]["policyAnswered"])
            controller._close_critic_rejections(store, answered["value"])
            closed = store.state["critic"]["findings"][0]
            self.assertEqual((closed["disposition"], closed["reason"]), ("rejected", answered["value"]))
            boundary = postconditions.Boundary(store, paths, phase="plan", product={}, exit="ready", project_root=Path(tmp))
            self.assertIsNone(boundary._p7())


class FindDeliveringRunProductsTests(unittest.TestCase):
    """LF-37: the reviser needs the SPEC/PLAN products of whatever prior run
    delivered this PR; this is the lookup that used to be a live lead's own
    find|xargs grep over the state home."""

    def _run_dir(self, home: Path, rid: str, slug: str, project_root: Path,
                 spec: dict, plan: dict) -> tuple[FeaturePaths, StateStore]:
        paths = FeaturePaths(root=home / rid / slug, project_root=project_root)
        store = StateStore.create(paths, {"id": f"run-{slug}", "entry": "cycle", "slug": slug}, "add a greeting")
        store.state["products"]["spec"] = {"product": spec}
        store.state["products"]["plan"] = {"product": plan}
        store.save()
        return paths, store

    def test_finds_the_run_whose_result_names_the_pr(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            home, rid, project_root = tmp / "home", "repo-1", tmp / "project"
            project_root.mkdir()
            spec = {"criteria": [{"id": "AC-1", "text": "x"}]}
            plan = {"tasks": []}
            paths, _ = self._run_dir(home, rid, "delivered", project_root, spec, plan)
            atomic_write_json(paths.result_json, {"prs": [{"number": 2, "repo": "consumer", "url": "https://example/pr/2"}]})

            found = controller._find_delivering_run_products(home, rid, "https://example/pr/2", project_root)
            self.assertEqual(found, {"slug": "delivered", "spec": spec, "plan": plan})

            self.assertIsNone(controller._find_delivering_run_products(home, rid, "https://example/pr/999", project_root))

    def test_prefers_the_delivering_result_over_a_prior_revise_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            home, rid, project_root = tmp / "home", "repo-1", tmp / "project"
            project_root.mkdir()
            pr_url = "https://example/pr/2"

            # "aaa-revise" sorts before "zzz-delivered", so this proves the result.json
            # hit is PREFERRED, not just visited first.
            _, revise_store = self._run_dir(
                home, rid, "aaa-revise", project_root,
                {"criteria": [{"id": "AC-2", "text": "from the prior revise"}]}, {"tasks": []},
            )
            revise_store.state["adoption"] = {"repo": "consumer", "number": 2, "url": pr_url, "headRef": "pr-branch",
                                               "baseBranch": "main", "baseSha": "a" * 40, "headSha": "b" * 40}
            revise_store.save()

            delivered_spec = {"criteria": [{"id": "AC-1", "text": "the original delivery"}]}
            delivered_plan = {"tasks": []}
            delivered_paths, _ = self._run_dir(home, rid, "zzz-delivered", project_root, delivered_spec, delivered_plan)
            atomic_write_json(delivered_paths.result_json, {"prs": [{"number": 2, "repo": "consumer", "url": pr_url}]})

            found = controller._find_delivering_run_products(home, rid, pr_url, project_root)
            self.assertEqual(found, {"slug": "zzz-delivered", "spec": delivered_spec, "plan": delivered_plan})

    def test_adoption_only_hit_used_when_no_result_names_the_pr(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            home, rid, project_root = tmp / "home", "repo-1", tmp / "project"
            project_root.mkdir()
            pr_url = "https://example/pr/3"
            spec = {"criteria": [{"id": "AC-2", "text": "from the prior revise"}]}
            plan = {"tasks": []}
            _, revise_store = self._run_dir(home, rid, "revise-3", project_root, spec, plan)
            revise_store.state["adoption"] = {"repo": "consumer", "number": 3, "url": pr_url, "headRef": "pr-branch",
                                               "baseBranch": "main", "baseSha": "a" * 40, "headSha": "b" * 40}
            revise_store.save()

            found = controller._find_delivering_run_products(home, rid, pr_url, project_root)
            self.assertEqual(found, {"slug": "revise-3", "spec": spec, "plan": plan})


class ModulePauseAnswerTests(unittest.TestCase):
    """LF-65: a phase module's blocked pause is answered through phase.blockedQuestionId,
    so `stop` ends the run and `fix-and-re-enter` re-invokes the module once, never
    re-asking a pause nothing read."""

    def _paused(self, tmp: Path, policy=None):
        paths = FeaturePaths(root=tmp / "feature")
        store = StateStore.create(
            paths, {"id": "run-1", "entry": "cycle", "cycleType": "full", "slug": "x", "createdAt": "2026-01-01T00:00:00+00:00"}, "do it",
        )
        store.state["phase"].update(current="execute", attemptId="attempt-1")
        store.state["implementations"]["phases"]["execute"] = "default"
        store.state["questions"]["policy"] = policy
        store.save()
        request = {"attempt": "attempt-1", "phase": "execute", "text": "feature branch moved out of band",
                   "options": [{"value": "stop", "label": "Stop"}, {"value": "fix-and-re-enter", "label": "Fix and re-enter"}],
                   "defaultValue": "stop", "kind": "blocked", "payload": {"repo": "repo"}}
        (tmp / "q.json").write_text(json.dumps(request))
        with patch.object(controller.contract, "invoke", return_value=controller.contract.PhaseOutcome(3, "question", tmp / "q.json", "")):
            controller._drive_phase(store, paths, tmp)
        question_id = store.state["phase"]["blockedQuestionId"]
        self.assertIsNotNone(question_id)
        self.assertEqual(StateStore.open(paths).state["phase"]["blockedQuestionId"], question_id)
        return paths, store, question_id

    def _continue_capturing_finish(self, store, paths, tmp):
        finished = []
        def finish(store, paths, classification, *, reason=None, **_):
            finished.append((classification, reason))
            store.state["result"] = {"status": classification}
        with patch.object(controller, "_finish_run", side_effect=finish):
            controller.continue_run(store, paths, project_root=Path(tmp))
        return finished

    def test_the_default_policy_answers_stop_and_escalates_without_re_asking(self):
        # LF-66: a headless run ends with a result instead of the lead improvising a fix.
        with tempfile.TemporaryDirectory() as tmp:
            paths, store, question_id = self._paused(Path(tmp), policy="default")
            self.assertIsNone(store.state["questions"]["open"])
            self.assertEqual(store.state["questions"]["answered"][question_id]["value"], "stop")
            self.assertEqual(self._continue_capturing_finish(store, paths, tmp)[0][0], "escalated")

    def test_stop_escalates(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths, store, question_id = self._paused(Path(tmp))
            questions.answer(store, paths, question_id=question_id, value="stop")
            self.assertEqual(self._continue_capturing_finish(store, paths, tmp)[0][0], "escalated")

    def test_fix_and_re_enter_re_invokes_the_module_without_re_asking(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths, store, question_id = self._paused(Path(tmp))
            questions.answer(store, paths, question_id=question_id, value="fix-and-re-enter")
            (Path(tmp) / "wait.json").write_text(json.dumps({"open": []}))
            with patch.object(controller.contract, "invoke",
                              return_value=controller.contract.PhaseOutcome(4, "wait", Path(tmp) / "wait.json", "")) as invoke:
                controller.continue_run(store, paths, project_root=Path(tmp))
            self.assertEqual(invoke.call_count, 1)
            self.assertIsNone(store.state["questions"]["open"])
            self.assertIsNone(store.state["phase"]["blockedQuestionId"])


class RefusedEvidenceTests(unittest.TestCase):
    """LF-60: a judgment step refused for want of evidence accepts nothing, raises one
    blocked question, and leaves no owner holding the dead step, across crashes."""

    def _store(self, tmp: Path):
        paths = FeaturePaths(root=tmp / "feature")
        store = StateStore.create(
            paths, {"id": "run-1", "entry": "cycle", "cycleType": "full", "slug": "x", "createdAt": "2026-01-01T00:00:00+00:00"}, "do it",
        )
        store.state["phase"]["current"] = "plan"
        return paths, store

    def _refuse_critic(self, tmp: Path):
        paths, store = self._store(tmp)
        record = steps.issue(store, paths, phase="plan", attempt_id="attempt-1", kind="role", role="plan-critic",
                             cwd=tmp, prompt="judge", schema={"type": "object"}, postconditions=["P7"],
                             inputs_digest="sha256:" + "a" * 64, result_path=tmp / "critic.json")
        store.state["phase"].update(criticStepId=record["stepAttemptId"], criticStepRevision="rev-1",
                                    criticStepIdentity="id-1", pending="critic")
        store.save()
        atomic_write_json(tmp / "critic.json", {"findings": [{"id": "F-1", "severity": "Critical"}]})
        submission = steps.submit(store, paths, step_id=record["stepAttemptId"], dispatch_name=None, host=None, project_root=tmp)
        self.assertEqual(submission.refused, "no host attestor")
        return paths, record["stepAttemptId"]

    def test_a_refusal_resets_its_owner_and_asks_one_question_across_resumes(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths, step_id = self._refuse_critic(Path(tmp))
            for _ in range(2):  # a crash after submit's one write, then a repeated resume
                store = StateStore.open(paths)
                controller._finish_refusals(store, paths)
            store = StateStore.open(paths)
            refused = store.state["steps"]["refused"][step_id]
            self.assertTrue(refused["ownerReset"])
            self.assertEqual(store.state["questions"]["open"]["questionId"], refused["questionId"])
            self.assertEqual(store.state["phase"]["blockedQuestionId"], refused["questionId"])
            self.assertEqual(store.state["questions"]["retired"], [])
            self.assertIsNone(store.state["phase"]["criticStepId"])
            self.assertIsNone(store.state.get("critic"))  # no handler consumed the refused findings
            question = read_json(Path(store.state["questions"]["open"]["path"]))
            self.assertEqual((question["defaultValue"], question["payload"]["refusedStep"]), ("stop", step_id))

    def test_a_crash_between_the_owner_reset_and_the_question_asks_exactly_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths, step_id = self._refuse_critic(Path(tmp))
            store = StateStore.open(paths)
            with patch.object(controller.questions, "ask", side_effect=RuntimeError("crash")):
                with self.assertRaises(RuntimeError):
                    controller._finish_refusals(store, paths)
            store = StateStore.open(paths)
            self.assertEqual((store.state["steps"]["refused"][step_id]["ownerReset"], store.state["questions"]["open"]),
                             (True, None))
            controller._finish_refusals(store, paths)
            self.assertIsNotNone(StateStore.open(paths).state["questions"]["open"])

    def test_an_unrelated_open_question_defers_the_refusal_question(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths, step_id = self._refuse_critic(Path(tmp))
            store = StateStore.open(paths)
            other = questions.ask(store, paths, phase="plan", attempt_id="attempt-1", text="other?", kind="choice",
                                  options=[{"value": "a", "label": "A"}], default_value=None, payload=None)
            controller._finish_refusals(store, paths)
            self.assertEqual(store.state["questions"]["open"]["questionId"], other["questionId"])
            self.assertIsNone(store.state["steps"]["refused"][step_id]["questionId"])

    def test_stop_escalates_naming_the_refused_step(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths, step_id = self._refuse_critic(Path(tmp))
            store = StateStore.open(paths)
            controller._finish_refusals(store, paths)
            questions.answer(store, paths, question_id=store.state["questions"]["open"]["questionId"], value="stop")
            finished = []
            def finish(store_, paths_, classification, **kw):
                finished.append((classification, kw["reason"]))
                store_.state["result"] = {"status": "escalated"}
            with patch.object(controller, "_finish_run", side_effect=finish):
                controller.continue_run(store, paths, project_root=Path(tmp))
            self.assertEqual(finished[0][0], "escalated")
            self.assertIn(f"step {step_id} (plan-critic) has no accepted evidence", finished[0][1])

    def test_each_owner_drops_the_refused_step(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths, store = self._store(Path(tmp))
            store.state["phase"]["adoptedReviewStepId"] = "s-adopt"
            controller._reset_refused_owner(store, paths, "s-adopt", {"role": "code-reviewer", "phase": "execute", "cwd": "/c"})
            self.assertIsNone(store.state["phase"]["adoptedReviewStepId"])
            store.state["iterate"] = {"judge": {"verdict": "met"}, "judgeStep": "s-old"}
            controller._reset_refused_owner(store, paths, "s-judge", {"role": "iterate-judge", "phase": "iterate", "cwd": "/c"})
            self.assertEqual((store.state["iterate"]["judge"], store.state["iterate"]["judgeStep"]), (None, None))

    def test_an_accepted_critic_counts_only_with_accepted_step_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths, store = self._store(Path(tmp))
            store.state["critic"] = {"passes": 1, "findings": [], "planRevision": "rev-1", "inputsIdentity": "id-1"}
            self.assertFalse(controller._accepted_critic_current(store, Path(tmp), "rev-1", "id-1"))  # no stepId
            store.state["critic"]["stepId"] = "s-1"
            store.state["steps"]["submissions"]["s-1"] = {"evidenceLevel": "unattested"}
            self.assertFalse(controller._accepted_critic_current(store, Path(tmp), "rev-1", "id-1"))
            atomic_write_json(Path(tmp) / ".loop-spec" / "config.json", {"evidence": {"judgment": {"accept": "unattested"}}})
            self.assertTrue(controller._accepted_critic_current(store, Path(tmp), "rev-1", "id-1"))


if __name__ == "__main__":
    unittest.main()


class CompatibilityTests(unittest.TestCase):
    """7.1.0: a run whose baseline was captured under other comparison rules is refused
    before any command writes to it; a run with no baseline is never refused."""

    def _run_with_baseline(self, tmp: Path, version):
        repo_dir = _init_repo(tmp)
        home = tmp / "home"
        paths = FeaturePaths(root=feature_dir(home, repo_id(repo_dir), "old"))
        store = StateStore.create(paths, {"id": "run-1", "entry": "cycle", "createdAt": "2026-01-01T00:00:00+00:00",
                                          "slug": "old", "repoId": repo_id(repo_dir), "cycleType": "cycle"}, "old request")
        if version is not None:
            store.state["baseline"] = {"planRevision": "sha256:x", "repos": {"repo": {"normalizationVersion": version}}}
        store.save()
        return repo_dir, home, paths

    def test_submit_and_answer_refused_before_any_write(self):
        from loop_spec import cli
        with tempfile.TemporaryDirectory() as t:
            repo_dir, home, paths = self._run_with_baseline(Path(t), 1)
            before = paths.state_json.read_bytes()
            common = ["--project-root", str(repo_dir), "--state-home", str(home), "--slug", "old"]
            with contextlib.redirect_stderr(io.StringIO()) as err:
                self.assertEqual(cli.main(["submit", *common, "--step", "step-x"]), 1)
                self.assertEqual(cli.main(["answer", *common, "--question", "q-1", "--answer", "stop"]), 1)
            self.assertIn("comparison rules v1", err.getvalue())
            self.assertEqual(paths.state_json.read_bytes(), before)

    def test_baseline_free_run_is_compatible(self):
        with tempfile.TemporaryDirectory() as t:
            _, _, paths = self._run_with_baseline(Path(t), None)
            controller.check_compatible(StateStore.open(paths))  # no raise


class RepairHintTests(unittest.TestCase):
    """7.2.0: a repair hint names this launcher with this call's project root and state home."""

    def test_a_bare_loop_spec_command_in_a_repair_runs_as_printed(self):
        from loop_spec import cli
        with tempfile.TemporaryDirectory() as t:
            with contextlib.redirect_stderr(io.StringIO()) as err:
                self.assertEqual(cli.main(["submit", "--project-root", t, "--state-home", f"{t}/home", "--step", "step-x"]), 1)
        launcher = Path(cli.__file__).resolve().parents[1] / "loop-spec"
        self.assertIn(f"see `{launcher} status --project-root {t} --state-home {t}/home`", err.getvalue())


class PhaseProbesTests(unittest.TestCase):
    """7.1.0: PLAN, DEBUG and REVISE get repo-check facts per repo; other phases none."""

    def test_plan_gets_facts_per_repo_and_revise_reads_the_adopted_head(self):
        state = {"repos": {"repo": {"path": "/r", "baseSha": "b" * 40}}, "request": {"text": "x"}}
        with patch("loop_spec.controller.probes_module.repo_checks_probe", side_effect=lambda p, sha: [sha]) as probe, \
                patch("loop_spec.controller.probes_module.named_files", return_value=[]):
            self.assertEqual(controller._phase_probes(state, "spec", Path("/c")), {})
            self.assertEqual(controller._phase_probes(state, "plan", Path("/c")), {"repoChecks": {"repo": ["b" * 40]}})
            state["adoption"] = {"repo": "repo", "headSha": "h" * 40}
            self.assertEqual(controller._phase_probes(state, "revise", Path("/c")), {"repoChecks": {"repo": ["h" * 40]}})
        self.assertEqual(probe.call_count, 2)

    def test_plan_probes_the_named_files_at_the_base_commit(self):
        """7.1.1: repo-relative facts from a checkout at the base, removed afterwards."""
        with tempfile.TemporaryDirectory() as t:
            repo, checkouts = Path(t) / "repo", Path(t) / "checkouts"
            repo.mkdir()
            run = lambda *a: subprocess.run(["git", "-C", str(repo), *a], check=True, capture_output=True, text=True).stdout.strip()
            run("init", "-q", "-b", "main")
            (repo / "auth.py").write_text("def login(): pass  # auth\n")
            run("add", ".")
            run("-c", "user.name=T", "-c", "user.email=t@e", "commit", "-q", "-m", "base")
            (repo / "auth.py").write_text("changed after base\n")
            state = {"repos": {"repo": {"path": str(repo), "baseSha": run("rev-parse", "HEAD")}},
                     "request": {"text": "harden auth.py"}}
            probes = controller._phase_probes(state, "plan", checkouts)
            self.assertEqual(probes["named"]["repo"]["files"], ["auth.py"])
            self.assertEqual([s["file"] for s in probes["named"]["repo"]["securitySignals"]], ["auth.py"])
            self.assertEqual(list(checkouts.iterdir()), [])
            state["request"]["text"] = "nothing named"
            self.assertNotIn("named", controller._phase_probes(state, "plan", checkouts))


class FailureObservationTests(unittest.TestCase):
    """7.1.0: a failing criterion with a recorded pass is re-run by the program at the
    head; an unmet condition skips it (with an event) and never blocks VERIFY."""

    def setUp(self):
        from tests.test_postconditions import PostconditionsTests
        PostconditionsTests.setUp(self)
        self.store.state["revisions"]["requirements"] = "sha256:req"
        self.store.state["products"]["plan"] = {"exit": "ready", "product": self.plan_product}
        self.store.state["products"]["execute"] = {"exit": "integrated", "product": self.execute_product}
        self.store.state["criterionPasses"] = {"AC-1": {"repo": "repo", "sha": self.base_sha, "command": "x",
                                                        "requirementsRevision": "sha256:req", "attemptId": "v-1"}}
        self.product = {"verdicts": [{"criterion": "AC-1", "verdict": "fail", "cause": "boom",
                                      "evidence": {"command": "git log --oneline -1", "repo": "repo", "sha": "claimed"}}]}

    def test_runs_at_the_program_head_and_skips_on_changed_requirements(self):
        controller._observe_failures(self.store, self.paths, self.product, "v-2")
        observation = self.store.state["failureObservations"]["AC-1"]
        self.assertEqual((observation["sha"], observation["attemptId"]), (self.sha_b, "v-2"))
        self.store.state["revisions"]["requirements"] = "sha256:changed"
        self.store.state["failureObservations"] = {}
        controller._observe_failures(self.store, self.paths, self.product, "v-3")
        self.assertEqual(self.store.state["failureObservations"], {})
        self.assertIn("failure_observation_skipped", self.paths.events_jsonl.read_text())
