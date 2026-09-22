"""Drive one run: entry -> phases -> the next file a caller must act on.

Use `run_entry` once per CLI invocation of a controller entry (cycle, micro, or a
single-phase resume) and `continue_run` after `submit`/`answer` record a step or
question result. This module is the ONLY place that transitions a phase, spends the
T1 rewind budget, writes the SPEC approval record, or writes a terminal result;
`postconditions.py` only answers whether a claimed exit's requirements hold.
"""
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from . import baseline as baseline_module
from . import budget as budget_module
from . import contract
from . import postconditions
from . import questions
from . import repo as repo_module
from . import result as result_module
from . import steps
from .errors import LoopSpecError
from .ids import digest, new_id, now_iso
from .jsonio import atomic_write_json, read_json
from .events import emit, marker_phase_end, marker_phase_start
from .paths import FeaturePaths, feature_dir, repo_id, slug_from_request
from .paths import state_home as resolve_state_home
from .state import StateStore

_PHASE_ORDER = ["spec", "plan", "execute", "verify", "iterate", "deliver"]
_ALL_IMPLEMENTATION_PHASES = _PHASE_ORDER + ["debug", "revise"]
_RESUMABLE_PHASES = ("spec", "plan", "execute", "verify", "iterate", "deliver")


@dataclass
class Next:
    kind: Literal["step", "question", "result"]
    path: Path
    slug: str


# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------


def run_entry(entry: str, *, project_root: Path, request_text: str | None, slug: str | None,
              state_home: str | None, answer_policy: str | None, pr: str | None) -> Next:
    project_root = Path(project_root)
    home = resolve_state_home(state_home)
    rid = repo_id(project_root)

    if entry == "debug":
        raise LoopSpecError("debug lands at M4", repair="use cycle or micro, or wait for M4")
    if entry == "revise":
        raise LoopSpecError("revise lands at M5", repair="use cycle or micro, or wait for M5")

    if entry in ("cycle", "micro"):
        if not request_text:
            # --slug with no request resumes that run instead of starting a new one;
            # the digest check below only applies when a request text is given.
            if not slug:
                raise LoopSpecError(f"{entry} requires --request, --request-file, or --slug to resume",
                                     repair="pass --request/--request-file for a new run, or --slug to resume one")
            paths = FeaturePaths(root=feature_dir(home, rid, slug))
            if not paths.state_json.exists():
                raise LoopSpecError(f"no run for slug {slug!r}", repair="check `loop-spec status` for known slugs, or pass --request to start one")
            return continue_run(StateStore.open(paths), paths, project_root=project_root)

        slug = slug or slug_from_request(request_text)
        paths = FeaturePaths(root=feature_dir(home, rid, slug))
        _clear_stale_last_result(paths, slug)

        if paths.state_json.exists():
            store = StateStore.open(paths)
            if store.state["request"]["digest"] != digest(request_text):
                raise LoopSpecError(f"slug {slug} is in use by another request", repair="pass --slug to choose a different slug")
        else:
            run_fields = {
                "id": new_id("run"), "entry": entry, "createdAt": now_iso(),
                "slug": slug, "repoId": rid, "cycleType": "full" if entry == "cycle" else "micro",
            }
            store = StateStore.create(paths, run_fields, request_text)
            store.state["phase"]["current"] = "spec"
            _resolve_repos(store, project_root, slug, request_text)
            _resolve_implementations(store, project_root)
            if answer_policy == "default":
                store.state["questions"]["policy"] = "default"
            store.save()
        return continue_run(store, paths, project_root=project_root)

    if entry in _RESUMABLE_PHASES:
        if not slug:
            raise LoopSpecError(f"{entry} requires --slug", repair="pass --slug <slug>, see `loop-spec status`")
        paths = FeaturePaths(root=feature_dir(home, rid, slug))
        store = StateStore.open(paths)
        _check_phase_preconditions(store, entry)
        if store.state["phase"]["current"] != entry:
            store.state["phase"]["current"] = entry
            store.state["phase"]["entry"] = "fresh"
            store.state["phase"]["attemptId"] = None
            store.save()
        return continue_run(store, paths, project_root=project_root)

    raise LoopSpecError(f"unknown entry {entry}", repair="use cycle, micro, debug, revise, spec, plan, execute, verify, iterate, or deliver")


def _clear_stale_last_result(paths: FeaturePaths, slug: str) -> None:
    if paths.last_result_json.is_file():
        try:
            existing = read_json(paths.last_result_json)
        except ValueError:
            existing = {}
        if existing.get("slug") == slug:
            paths.last_result_json.unlink()


def _resolve_repos(store: StateStore, project_root: Path, slug: str, request_text: str) -> None:
    workspace = repo_module.detect_workspace(project_root)
    if workspace.mode == "none":
        workspace.repos = [repo_module.init_in_place(project_root)]

    pr_ref = repo_module.find_pr_reference(request_text)
    repos: dict = {}
    adoption = None
    for entry in workspace.repos:
        base_sha = repo_module.head_sha(entry.path)
        feature_branch = f"feat/{slug}"
        default_branch = repo_module.default_branch(entry.path)
        if pr_ref is not None and adoption is None:
            candidate = repo_module.adopt_pr(entry.path, pr_ref)
            if candidate.adopt:
                adoption = candidate
                feature_branch = candidate.branch
                base_sha = repo_module.run_git(entry.path, "merge-base", default_branch, candidate.head_sha).strip()
        repos[entry.name] = {
            "path": str(entry.path), "baseSha": base_sha, "featureBranch": feature_branch,
            "defaultBranch": default_branch, "lastKnownHead": base_sha,
        }
    store.state["repos"] = repos
    if adoption is not None:
        store.state["adoption"] = {
            "number": adoption.number, "url": adoption.url, "branch": adoption.branch,
            "baseBranch": adoption.base_branch, "headSha": adoption.head_sha, "reason": adoption.reason,
        }


def _resolve_implementations(store: StateStore, project_root: Path) -> None:
    # Every phase, including debug/revise (each entry's own first phase), gets an
    # implementation resolved once up front so _drive_phase's lookup never misses.
    phases = {p: contract.resolve_implementation(project_root, p) for p in _ALL_IMPLEMENTATION_PHASES}
    store.state["implementations"] = {"phases": phases, "roles": {}}


_PHASE_PRECONDITIONS = {
    "plan": ("spec", ["approved"]),
    "execute": ("plan", ["ready"]),
    "verify": ("execute", ["integrated", "no change"]),
    "iterate": ("verify", ["passed"]),
    "deliver": ("iterate", ["converged", "converged with caveats"]),
}


def _check_phase_preconditions(store: StateStore, phase: str) -> None:
    requirement = _PHASE_PRECONDITIONS.get(phase)
    if requirement is None:
        return
    upstream, allowed_exits = requirement
    entry = store.state["products"].get(upstream)
    if entry is None or entry["exit"] not in allowed_exits:
        raise LoopSpecError(
            f"{phase} needs {upstream} to have exited {' or '.join(allowed_exits)} first",
            repair=f"run `loop-spec {upstream} --slug <slug>` first",
        )
    if postconditions.bound_ok(entry["product"], store, upstream) is not None:
        raise LoopSpecError(
            f"{phase} needs {upstream}'s product bound to the current revisions",
            repair=f"re-run {upstream}",
        )


# ---------------------------------------------------------------------------
# The continue loop
# ---------------------------------------------------------------------------


def continue_run(store: StateStore, paths: FeaturePaths, *, project_root: Path) -> Next:
    project_root = Path(project_root)
    slug = store.state["run"]["slug"]
    while True:
        if store.state.get("result") is not None:
            return Next(kind="result", path=paths.result_json, slug=slug)
        open_question = store.state["questions"]["open"]
        if open_question is not None:
            return Next(kind="question", path=Path(open_question["path"]), slug=slug)
        open_steps = store.state["steps"]["open"]
        if open_steps:
            first = open_steps[0]
            return Next(kind="step", path=paths.steps_dir / first["stepAttemptId"] / "step.json", slug=slug)

        blocked_question_id = store.state["phase"].get("blockedQuestionId")
        if blocked_question_id is not None:
            answered = store.state["questions"]["answered"].get(blocked_question_id)
            if answered is not None:
                store.state["phase"]["blockedQuestionId"] = None
                if answered["value"] in ("stop", "reject with reason"):
                    store.save()
                    result_module.write(
                        store, paths, "escalated",
                        reason=f"{store.state['phase']['current']} paused; operator chose {answered['value']!r}",
                    )
                    continue
                store.save()  # fix-and-re-enter / spec gap: phase.entry is already "remediation"
                continue

        critic_question_id = store.state["phase"].get("criticQuestionId")
        if critic_question_id is not None:
            answered = store.state["questions"]["answered"].get(critic_question_id)
            if answered is not None:
                store.state["phase"]["criticQuestionId"] = None
                product = store.state["phase"]["provisional"]
                store.state["phase"]["provisional"] = None
                attempt_id = store.state["phase"]["attemptId"]
                if answered["value"] == "spec gap":
                    _finalize(store, paths, project_root, "plan", attempt_id, dict(product, exit="spec gap"), "spec gap")
                else:
                    # Any other non-empty answer is the operator's reason for rejecting
                    # the still-open Critical finding(s); P7 accepts "rejected" with a
                    # stated reason with no further re-run. An empty reason leaves P7
                    # unsatisfied and _finalize rejects the product through the normal
                    # retry path, asking again rather than closing silently.
                    _close_critic_rejections(store, answered["value"].strip())
                    _finalize(store, paths, project_root, "plan", attempt_id, product, product["exit"])
                continue

        pending = store.state["phase"].get("pending")
        if pending in ("approval", "critic"):
            phase = store.state["phase"]["current"]
            attempt_id = store.state["phase"]["attemptId"]
            product = store.state["phase"]["provisional"]
            _accept_product(store, paths, project_root, phase, attempt_id, product)
            continue
        if pending == "deliver-credentials":
            _check_deliver_credentials(store, paths, project_root)
            continue

        _drive_phase(store, paths, project_root)


def build_envelope(store: StateStore, paths: FeaturePaths, phase: str, attempt_id: str, project_root: Path) -> dict:
    state = store.state
    products = {
        name: {"exit": entry["exit"], "boundTo": entry["boundTo"], "product": entry["product"]}
        for name, entry in state["products"].items() if entry is not None
    }
    inputs_source = {
        "request": state["request"], "products": products, "revisions": state["revisions"],
        "approval": state["approval"], "baseline": state["baseline"], "ledger": state["ledger"],
        "budget": state["budget"], "entry": state["phase"]["entry"], "repos": state["repos"],
        "projectRoot": str(project_root),
    }
    return {
        "run": {"id": state["run"]["id"]},
        "attempt": {"id": attempt_id},
        "inputs": {"digest": digest(inputs_source)},
        "request": state["request"],
        "products": products,
        "state": {
            "requirementsRevision": state["revisions"]["requirements"], "approval": state["approval"],
            "planRevision": state["revisions"]["plan"], "baseline": state["baseline"],
            "ledger": state["ledger"], "budget": state["budget"],
        },
        "entry": {"mode": state["phase"]["entry"], "payload": state["phase"].get("entryPayload")},
        "repos": state["repos"],
        "paths": {
            "stateDir": str(paths.root),
            "writable": [str(paths.attempts_dir / attempt_id), str(paths.worktrees_dir)],
            "projectRoot": str(project_root),
        },
        "answers": questions.answers_for_context(store, attempt_id),
        "probes": {},  # M1: probes.py lands at M2 (wave F); every phase sees an empty envelope.
    }


def _drive_phase(store: StateStore, paths: FeaturePaths, project_root: Path) -> None:
    # An attempt spans every step round-trip for one phase invocation: the first
    # call here (attemptId is None) mints the attempt and writes its context once;
    # a later call for the SAME attempt (after a step the phase's own implementation
    # issued is submitted) re-invokes contract.invoke so it can see the file that
    # step wrote (e.g. an external phase's product.json) instead of starting over.
    phase = store.state["phase"]["current"]
    attempt_id = store.state["phase"].get("attemptId")
    if attempt_id is None:
        attempt_id = new_id("attempt")
        store.state["attempts"].append({"id": attempt_id, "phase": phase, "entry": store.state["phase"]["entry"], "startedAt": now_iso()})
        store.state["phase"]["attemptId"] = attempt_id
        store.save()
        marker_phase_start(paths, phase, attempt_id)
        emit(paths, "phase_start", {"summary": f"{phase} attempt {attempt_id}"}, phase=phase, attempt_id=attempt_id)
        envelope = build_envelope(store, paths, phase, attempt_id, project_root)
        contract.write_context(paths, attempt_id, envelope)

    implementation = store.state["implementations"]["phases"][phase]
    outcome = contract.invoke(paths, phase=phase, attempt_id=attempt_id, implementation=implementation, program_launcher=Path("loop-spec"), store=store)

    if outcome.kind == "step":
        request = read_json(outcome.path)
        # LF-03: a step re-issued after a rejection carries WHY (the failures, as
        # "id: message" lines) and WHAT it replaces (the rejected attempt's own
        # product step), overriding whatever the implementation's own request set;
        # any other remediation reason (a critic finding, a disapproval, ...) keeps
        # the implementation's own retryOf/reason untouched.
        rejected = (store.state["phase"].get("entryPayload") or {}).get("rejected")
        if rejected is not None:
            reason = "\n".join(f"{f['id']}: {f['message']}" for f in rejected["failures"])
            retry_of = store.state["phase"].get("lastStepId")
        else:
            reason = request.get("reason")
            retry_of = request.get("retryOf")
        record = steps.issue(
            store, paths, phase=phase, attempt_id=attempt_id, kind=request["kind"], role=request.get("role"),
            cwd=Path(request["cwd"]), prompt=request["prompt"], schema=request["schema"],
            postconditions=request["postconditions"], inputs_digest=request["inputsDigest"],
            retry_of=retry_of, reason=reason,
            result_path=Path(request["resultPath"]),
        )
        store.state["phase"]["lastStepId"] = record["stepAttemptId"]
        store.save()
        return
    if outcome.kind == "question":
        request = read_json(outcome.path)
        record = questions.ask(
            store, paths, phase=phase, attempt_id=attempt_id, text=request["text"], kind=request["kind"],
            options=request["options"], default_value=request.get("defaultValue"), payload=request.get("payload"),
        )
        questions.resolve_policy_answer(store, paths, record)
        return
    if outcome.kind == "error":
        result_module.write(store, paths, "failed", reason=outcome.stderr)
        return
    _accept_product(store, paths, project_root, phase, attempt_id, read_json(outcome.path))


# ---------------------------------------------------------------------------
# Product acceptance
# ---------------------------------------------------------------------------

_FINDING_SCHEMA = {
    "type": "object",
    "required": ["id", "location", "cause", "severity", "disposition", "reason", "supersedes"],
    "additionalProperties": False,
    "properties": {
        "id": {"type": "string"}, "location": {"type": "string"}, "cause": {"type": "string"},
        "severity": {"type": "string", "enum": ["Critical", "Important", "Minor"]},
        "disposition": {"type": "string", "enum": ["fixed", "rejected", "deferred", "open"]},
        "reason": {"type": ["string", "null"]},
        "supersedes": {"anyOf": [
            {"type": "null"},
            {"type": "object", "required": ["kind", "id"], "additionalProperties": False,
             "properties": {"kind": {"type": "string", "enum": ["finding", "range"]}, "id": {"type": "string"}}},
        ]},
    },
}
_CRITIC_SCHEMA = {
    "type": "object", "required": ["findings"], "additionalProperties": False,
    "properties": {"findings": {"type": "array", "items": _FINDING_SCHEMA}},
}


def _answered_question_for_attempt(store: StateStore, attempt_id: str):
    for question_id, record in store.state["questions"]["answered"].items():
        if record.get("attempt") == attempt_id:
            return question_id, record
    return None


def _accept_product(store: StateStore, paths: FeaturePaths, project_root: Path, phase: str, attempt_id: str, product: dict) -> None:
    existing = store.state["products"].get(phase)
    if existing is not None and existing.get("attemptId") == attempt_id:
        return  # already recorded for this attempt: never transition twice (IT-03).

    exit_ = product["exit"]

    if phase == "spec" and exit_ == "approved":
        if _handle_spec_approval(store, paths, attempt_id, product) != "approved":
            return

    if phase == "plan" and exit_ == "ready":
        if _handle_plan_baseline_and_critic(store, paths, project_root, attempt_id, product) != "ready":
            return

    if phase == "execute" and exit_ in ("integrated", "no change"):
        _run_execute_verifications(store, paths, product)

    if phase == "verify" and exit_ == "passed":
        _run_verify_reruns(store, paths, product)

    if phase == "deliver" and store.state["phase"].get("credentialsCheckedForAttempt") != attempt_id:
        store.state["phase"]["provisional"] = product
        store.state["phase"]["pending"] = "deliver-credentials"
        store.save()
        return

    _finalize(store, paths, project_root, phase, attempt_id, product, exit_)


def _handle_spec_approval(store: StateStore, paths: FeaturePaths, attempt_id: str, product: dict) -> str:
    revision = postconditions.requirements_revision(product)
    approval = store.state.get("approval")
    if approval is not None and approval.get("revision") == revision:
        return "approved"

    answered = _answered_question_for_attempt(store, attempt_id)
    if answered is None:
        store.state["phase"]["provisional"] = product
        store.state["phase"]["pending"] = "approval"
        store.save()
        record = questions.ask(
            store, paths, phase="spec", attempt_id=attempt_id,
            text=f"Approve these requirements (revision {revision})?", kind="approval",
            options=[{"value": "approve", "label": "Approve"}, {"value": "reject", "label": "Reject"}, {"value": "revise", "label": "Revise"}],
            default_value="approve", payload={"revision": revision},
        )
        questions.resolve_policy_answer(store, paths, record)
        return "pending"

    question_id, answer_record = answered
    store.state["phase"]["pending"] = None
    store.state["phase"]["provisional"] = None
    if answer_record["value"] == "approve":
        store.state["approval"] = {
            "revision": revision, "questionId": question_id, "by": answer_record["by"],
            "at": now_iso(), "writer": "program",
        }
        store.save()
        return "approved"
    store.state["phase"]["entry"] = "remediation"
    store.state["phase"]["entryPayload"] = {"answer": answer_record["value"]}
    store.save()
    return "remediation"


def _issue_critic_step(store: StateStore, paths: FeaturePaths, attempt_id: str, plan_product: dict, is_external: bool, revision: str) -> None:
    repo_path = next(iter(store.state["repos"].values()))["path"]
    spec_product = store.state["products"]["spec"]["product"]
    inputs_digest = digest({"plan": plan_product, "spec": spec_product})
    prompt = (
        "Review this PLAN product for Critical-only issues: a criterion no task covers, "
        "a verify command that cannot test what it claims, or a destructive change with "
        'no boundary. Output {"findings": []} when nothing is Critical.\n\n'
        f"SPEC criteria: {spec_product['criteria']}\n\nPLAN tasks: {plan_product['tasks']}"
    )
    record = steps.issue(
        store, paths, phase="plan", attempt_id=attempt_id,
        kind="external" if is_external else "role", role=None if is_external else "plan-critic",
        cwd=Path(repo_path), prompt=prompt, schema=_CRITIC_SCHEMA, postconditions=["P7"],
        inputs_digest=inputs_digest,
    )
    store.state["phase"]["criticStepId"] = record["stepAttemptId"]
    # Recorded so a later call for a DIFFERENT (corrected) revision recognizes this
    # step's submission as answering the OLD revision, not the new one, and issues
    # a fresh critic step instead of replaying the stale result (the "re-issue the
    # critic step once on the corrected product" part of P7).
    store.state["phase"]["criticStepRevision"] = revision
    store.save()


def _critic_submission(store: StateStore, paths: FeaturePaths, revision: str) -> dict | None:
    step_id = store.state["phase"].get("criticStepId")
    if step_id is None or store.state["phase"].get("criticStepRevision") != revision:
        return None
    if store.state["steps"]["submissions"].get(step_id) is None:
        return None
    step = read_json(paths.steps_dir / step_id / "step.json")
    return read_json(Path(step["resultPath"]))


def _handle_plan_baseline_and_critic(store: StateStore, paths: FeaturePaths, project_root: Path, attempt_id: str, product: dict) -> str:
    boundary = postconditions.Boundary(store, paths, phase="plan", product=product, exit=product["exit"], project_root=project_root)
    # Only the structural ids need to hold before a baseline capture makes sense;
    # the rest (P3, P4, P7) depend on the baseline/critic this function produces.
    if any(f.id in ("P1", "P2", "P5", "P6") for f in boundary.check()):
        return "ready"  # let the normal full-check rejection path in _finalize report these

    revision = postconditions.plan_revision(product)
    baseline = store.state.get("baseline")
    if baseline is None or baseline.get("planRevision") != revision:
        _capture_plan_baseline(store, paths, product, revision)

    critic = store.state.get("critic")
    if critic is not None and critic.get("planRevision") == revision:
        return "ready"

    submission = _critic_submission(store, paths, revision)
    if submission is None:
        store.state["phase"]["provisional"] = product
        store.state["phase"]["pending"] = "critic"
        store.save()
        is_external = store.state["implementations"]["phases"].get("plan") == "external"
        _issue_critic_step(store, paths, attempt_id, product, is_external, revision)
        return "pending"

    passes = (critic or {}).get("passes", 0) + 1
    store.state["critic"] = {"passes": passes, "findings": submission["findings"], "planRevision": revision}
    store.state["phase"]["pending"] = None
    store.state["phase"]["provisional"] = None
    store.save()

    open_critical = [f for f in submission["findings"] if f.get("severity") == "Critical" and f.get("disposition") == "open"]
    if not open_critical:
        return "ready"
    if passes >= 2:
        # P7's second branch: a Critical still open after the one re-run asks a
        # question rather than looping forever. "spec gap" routes PLAN backward
        # through the normal spec-gap route; any other answer is the reason for
        # rejecting the finding(s) and closing without a further re-run (handled
        # in continue_run's criticQuestionId branch, once answered).
        store.state["phase"]["provisional"] = product
        record = questions.ask(
            store, paths, phase="plan", attempt_id=attempt_id,
            text=(f"PLAN critic still finds Critical issues after {passes} passes: "
                  f"{', '.join(f['id'] for f in open_critical)}. Answer with your reason to reject "
                  "and close, or 'spec gap' to send this back to SPEC."),
            kind="text", options=[{"value": "spec gap", "label": "Spec gap"}],
            default_value=None, payload={"findings": open_critical},
        )
        store.state["phase"]["criticQuestionId"] = record["questionId"]
        store.save()
        return "pending"
    # First pass with an open Critical: send PLAN back for one corrected re-pass.
    # attemptId resets so a genuinely fresh attempt runs (a stale product.json on
    # disk would otherwise look "already valid" to an external/lead implementation
    # and get replayed forever) with a new context exposing entryPayload; the
    # corrected product's own criticResponses changes its plan revision, which is
    # what forces _handle_plan_baseline_and_critic to re-issue the critic step.
    store.state["phase"]["entry"] = "remediation"
    store.state["phase"]["entryPayload"] = {"criticFindings": open_critical}
    store.state["phase"]["attemptId"] = None
    store.save()
    return "remediation"


def _close_critic_rejections(store: StateStore, reason: str) -> None:
    for finding in store.state["critic"]["findings"]:
        if finding.get("severity") == "Critical" and finding.get("disposition") == "open":
            finding["disposition"] = "rejected"
            finding["reason"] = reason


def _capture_plan_baseline(store: StateStore, paths: FeaturePaths, plan_product: dict, revision: str) -> None:
    repo_name, repo_info = next(iter(store.state["repos"].items()))
    commands = [(t["verify"], t["id"], t.get("featureAdded")) for t in plan_product["tasks"]]
    baseline_obj = baseline_module.capture_baseline(
        Path(repo_info["path"]), repo_info["baseSha"], commands, plan_product.get("prepare"), paths.checkouts_dir, repo_name,
    )
    baseline_dict = baseline_obj.to_dict()
    baseline_dict["planRevision"] = revision
    store.state["baseline"] = baseline_dict
    health = store.state.setdefault("environmentHealth", {})
    for entry in baseline_obj.entries.values():
        if entry.run and entry.run.error_class is not None:
            health[entry.command] = {"errorClass": entry.run.error_class, "recordedAt": now_iso()}
    store.save()


def _run_execute_verifications(store: StateStore, paths: FeaturePaths, execute_product: dict) -> None:
    baseline_dict = store.state.get("baseline")
    if baseline_dict is None:
        return
    repo_name, repo_info = next(iter(store.state["repos"].items()))
    repo_path = Path(repo_info["path"])
    head = execute_product["heads"].get(repo_name)
    if head is None:
        return
    baseline_obj = baseline_module.Baseline.from_dict(baseline_dict)
    plan_tasks = {t["id"]: t for t in store.state["products"]["plan"]["product"]["tasks"]}
    prepare = store.state["products"]["plan"]["product"].get("prepare")
    execute_runs = store.state.setdefault("executeRuns", {})
    for task in execute_product["tasks"]:
        if task["disposition"] not in ("done", "adopted") or task["id"] in execute_runs:
            continue
        plan_task = plan_tasks.get(task["id"])
        if plan_task is None:
            continue
        checkout = paths.checkouts_dir / f"execute-{task['id']}-{head[:12]}"
        repo_module.clean_checkout(repo_path, head, checkout)
        try:
            if prepare:
                baseline_module.run_command(prepare, checkout, head)
            run = baseline_module.run_command(plan_task["verify"], checkout, head)
        finally:
            repo_module.remove_worktree(repo_path, checkout, force=True)
        entry = baseline_obj.entries.get(plan_task["verify"])
        comparison = baseline_module.compare_to_baseline(
            entry, run, feature_added=bool(plan_task.get("featureAdded")), must_flip=bool(plan_task.get("mustFlip")),
        )
        execute_runs[task["id"]] = {"run": run.to_dict(), "comparison": comparison.to_dict()}
    store.save()


def _run_verify_reruns(store: StateStore, paths: FeaturePaths, verify_product: dict) -> None:
    repo_name, repo_info = next(iter(store.state["repos"].items()))
    repo_path = Path(repo_info["path"])
    head = postconditions.verified_head(store)
    prepare = store.state["products"]["plan"]["product"].get("prepare")
    verify_runs = store.state.setdefault("verifyRuns", {})
    for verdict in verify_product["verdicts"]:
        if verdict["verdict"] not in ("pass", "fail") or verdict["criterion"] in verify_runs:
            continue
        evidence = verdict.get("evidence") or {}
        checkout = paths.checkouts_dir / f"verify-{verdict['criterion']}-{head[:12]}"
        repo_module.clean_checkout(repo_path, head, checkout)
        try:
            if prepare:
                baseline_module.run_command(prepare, checkout, head)
            rerun = baseline_module.run_command(evidence.get("command", ""), checkout, head)
        finally:
            repo_module.remove_worktree(repo_path, checkout, force=True)
        matched, reason = baseline_module.evidence_matches(evidence, rerun)
        verify_runs[verdict["criterion"]] = {"rerun": rerun.to_dict(), "matched": matched, "reason": reason}
    store.save()


def _check_deliver_credentials(store: StateStore, paths: FeaturePaths, project_root: Path) -> None:
    attempt_id = store.state["phase"]["attemptId"]
    checks = store.state.setdefault("credentialChecks", {})
    for name, info in store.state["repos"].items():
        status = repo_module.check_credentials(Path(info["path"]))
        checks[name] = {"git_ok": status.git_ok, "gh_ok": status.gh_ok}
    store.state["phase"]["credentialsCheckedForAttempt"] = attempt_id
    store.state["phase"]["pending"] = None
    product = store.state["phase"]["provisional"]
    store.save()
    _accept_product(store, paths, project_root, "deliver", attempt_id, product)


# ---------------------------------------------------------------------------
# Boundary check, rejection, and routing
# ---------------------------------------------------------------------------


def _finalize(store: StateStore, paths: FeaturePaths, project_root: Path, phase: str, attempt_id: str, product: dict, exit_: str) -> None:
    route = postconditions.ROUTES[phase][exit_]
    if "T1" in route["requires"] and not budget_module.has_room(store):
        # T1 exhaustion is not an ordinary rejected postcondition: the controller
        # refuses the backward exit and escalates directly, without entering any
        # phase or looping the product back into remediation (phase-interface-7.0.md
        # "Backward-transition budget"). ITERATE's own refused rewind is the one
        # named exception (its "rewind" exit gates on I3/I4 instead of T1).
        result_module.write(store, paths, "escalated", reason=f"the rewind budget has no room for {phase} {exit_}")
        return

    boundary = postconditions.Boundary(store, paths, phase=phase, product=product, exit=exit_, project_root=project_root)
    failures = boundary.check()
    if failures:
        _reject_product(store, paths, phase, attempt_id, exit_, failures)
        return

    _record_accepted_product(store, phase, attempt_id, product, exit_, boundary)

    next_phase, mode = route["next"]
    if mode == "rewind":
        order = {"spec": 0, "plan": 1, "execute": 2, "verify": 3}
        targets = {g["target"] for g in product.get("gaps", [])} or {"spec"}
        next_phase = min(targets, key=lambda t: order.get(t, 99))
        mode = "remediation"
    if phase == "iterate" and exit_ == "escalated" and contract.load_config(project_root).get("deliver", {}).get("escalatedPartialDraft") is True:
        # Roadmap 15: the operator opted into a partial draft delivery for an
        # escalated run. Route forward to DELIVER instead of terminating; the
        # eventual terminal write still classifies "escalated" (_write_terminal_result),
        # with `delivery` filled in from whatever DELIVER manages to publish.
        next_phase, mode = "deliver", "fresh"
        store.state["escalatedDraft"] = True
        store.state["phase"]["entryPayload"] = {"draft": True}

    verdict = "blocked" if route.get("pause") else ("completed" if mode == "terminal" else ("rewind" if route["backward"] else "advanced"))
    marker_phase_end(paths, phase, attempt_id, verdict, next_phase, 0.0, None)
    emit(paths, "transition", {"summary": f"{phase} {exit_} -> {next_phase or 'terminal'}"}, phase=phase, attempt_id=attempt_id)

    if route.get("pause"):
        _ask_pause_question(store, paths, phase, exit_, product)
        return

    if route["backward"]:
        try:
            budget_module.spend(store, from_phase=phase, exit=exit_, to_phase=next_phase, attempt_id=attempt_id, reason=exit_)
        except budget_module.BudgetExhausted as exc:
            result_module.write(store, paths, "escalated", reason=str(exc))
            return

    if mode == "terminal":
        _write_terminal_result(store, paths, phase, exit_)
        return

    store.state["phase"]["current"] = next_phase
    store.state["phase"]["entry"] = mode
    store.state["phase"]["attemptId"] = None
    store.state["phase"]["pending"] = None
    store.state["phase"]["provisional"] = None
    store.save()


def _record_accepted_product(store: StateStore, phase: str, attempt_id: str, product: dict, exit_: str, boundary: "postconditions.Boundary") -> None:
    is_external = store.state["implementations"]["phases"].get(phase) == "external"
    store.state["products"][phase] = {
        "attemptId": attempt_id, "inputsDigest": product["inputsDigest"], "boundTo": product["boundTo"],
        "exit": exit_, "product": product, "receivedAt": now_iso(),
        "evidenceLevel": "human-attested" if is_external else "unattested",
    }
    if phase == "spec":
        store.state["revisions"]["requirements"] = postconditions.requirements_revision(product)
    if phase == "plan":
        store.state["revisions"]["plan"] = postconditions.plan_revision(product)
    if phase == "verify":
        # V7/V8 read this history on the NEXT VERIFY pass to decide whether that
        # pass may review only the delta since here, and whether a finding on
        # already-cleared code names what it supersedes.
        store.state["ledger"]["reviewedRanges"].append(dict(product["reviewedRange"], id=new_id("range")))
        store.state["ledger"]["findings"].extend(product.get("findings", []))
    store.state["phase"]["retries"] = 0
    if boundary.unreviewed:
        store.state["unreviewed"] = boundary.unreviewed
    if boundary.weakened_assurance:
        store.state.setdefault("weakenedAssurance", []).extend(boundary.weakened_assurance)
    store.save()


def _reject_product(store: StateStore, paths: FeaturePaths, phase: str, attempt_id: str, exit_: str, failures: list) -> None:
    emit(paths, "product_rejected", {"summary": f"{phase} {exit_} rejected: {failures[0].message}"}, phase=phase, attempt_id=attempt_id)
    store.state["phase"]["retries"] = store.state["phase"].get("retries", 0) + 1
    store.state["phase"]["entry"] = "remediation"
    store.state["phase"]["entryPayload"] = {"rejected": {"exit": exit_, "failures": [{"id": f.id, "message": f.message} for f in failures]}}
    store.state["phase"]["attemptId"] = None
    if store.state["phase"]["retries"] > postconditions.retry_limit():
        record = questions.ask(
            store, paths, phase=phase, attempt_id=attempt_id,
            text=f"{phase.upper()} product rejected {store.state['phase']['retries']} times: {'; '.join(f.message for f in failures)}",
            kind="blocked", options=[{"value": "fix-and-re-enter", "label": "Fix and re-enter"}, {"value": "stop", "label": "Stop"}],
            default_value=None, payload={"phase": phase},
        )
        store.state["phase"]["blockedQuestionId"] = record["questionId"]
        store.save()
    else:
        store.save()


def _ask_pause_question(store: StateStore, paths: FeaturePaths, phase: str, exit_: str, product: dict) -> None:
    cause = product.get("issues") or [v.get("cause") for v in product.get("verdicts", []) if v.get("verdict") == "blocked"] or exit_
    attempt_id = store.state["phase"]["attemptId"]
    record = questions.ask(
        store, paths, phase=phase, attempt_id=attempt_id,
        text=f"{phase.upper()} exited {exit_}: {cause}",
        kind="blocked", options=[{"value": "fix-and-re-enter", "label": "Fix and re-enter"}, {"value": "stop", "label": "Stop"}],
        default_value=None, payload={"phase": phase, "exit": exit_},
    )
    store.state["phase"]["blockedQuestionId"] = record["questionId"]
    store.state["phase"]["entry"] = "remediation"
    store.state["phase"]["attemptId"] = None
    store.save()


def _write_terminal_result(store: StateStore, paths: FeaturePaths, phase: str, exit_: str) -> None:
    if phase == "iterate" and exit_ == "escalated":
        result_module.write(store, paths, "escalated")
        return
    if store.state.get("escalatedDraft"):
        # This run reached DELIVER only because escalatedPartialDraft routed an
        # escalated ITERATE forward; it still classifies as escalated, DELIVER just
        # fills in `delivery` with whatever it managed to publish (roadmap 15).
        result_module.write(store, paths, "escalated", partially_delivered=(exit_ == "partially delivered"))
        return
    execute_exit = store.state["products"]["execute"]["exit"]
    iterate_exit = store.state["products"]["iterate"]["exit"]
    if execute_exit == "no change":
        classification = "no-change"
    elif iterate_exit == "converged with caveats":
        classification = "converged-with-caveats"
    else:
        classification = "converged"
    result_module.write(store, paths, classification, partially_delivered=(exit_ == "partially delivered"))
