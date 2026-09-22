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

_EXTERNAL_ENV = {f"LOOP_SPEC_PHASE_{p.upper()}": "external" for p in
                 ("spec", "plan", "execute", "verify", "iterate", "deliver")}


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
                            "command": 'python3 -c "import sys; sys.exit(0)"', "sha": commit_sha,
                            "exitStatus": 0, "failureIdentities": [], "outputDigest": "sha256:" + "0" * 64,
                        },
                        "cause": None,
                    }],
                    "findings": [], "remediationTasks": [],
                    "reviewedRange": {"from": base_sha, "to": commit_sha, "full": True},
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
                    "verdict": "met", "gaps": [], "caveats": [], "boundSha": commit_sha,
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
                open_finding = {
                    "id": "F-1", "location": "greet.py:1", "cause": "no boundary on the destructive rm",
                    "severity": "Critical", "disposition": "open", "reason": None, "supersedes": None,
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
            "verdict": "unmet", "gaps": [], "caveats": [], "boundSha": "c" * 40,
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
                review_result = {
                    "sha": head_sha, "reviewedRange": {"from": base_sha, "to": head_sha},
                    "verdict": "pass", "findings": [], "securityDispositions": [],
                }
                atomic_write_json(Path(review_step["resultPath"]), review_result)
                next_ = _submit_and_continue(paths, repo_dir, markers, review_step["stepAttemptId"])

                store = _open(paths)
                self.assertIsNotNone(store.state.get("adoptedReview"))
                self.assertEqual(next_.kind, "step")  # EXECUTE's own external step, now that the adopted review is on record


if __name__ == "__main__":
    unittest.main()
