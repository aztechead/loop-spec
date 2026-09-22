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
from loop_spec import repo as repo_module
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


if __name__ == "__main__":
    unittest.main()
