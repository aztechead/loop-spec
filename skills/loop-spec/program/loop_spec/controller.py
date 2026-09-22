"""Drive one run: entry -> phases -> the next file a caller must act on.

Use `run_entry` once per CLI invocation of a controller entry (cycle, micro, or a
single-phase resume) and `continue_run` after `submit`/`answer` record a step or
question result. This module is the ONLY place that transitions a phase, spends the
T1 rewind budget, writes the SPEC approval record, or writes a terminal result;
`postconditions.py` only answers whether a claimed exit's requirements hold.
"""
from dataclasses import dataclass, field
from pathlib import Path
from typing import Literal

from . import baseline as baseline_module
from . import budget as budget_module
from . import contract
from . import debug as debug_module
from . import execute as execute_module
from . import iterate as iterate_module
from . import ledger as ledger_module
from . import postconditions
from . import questions
from . import repo as repo_module
from . import result as result_module
from . import revise as revise_module
from . import steps
from . import verify as verify_module
from .errors import LoopSpecError
from .ids import digest, new_id, now_iso
from .jsonio import atomic_write_json, read_json
from .events import emit, marker_phase_end, marker_phase_start
from .paths import FeaturePaths, ensure_results_dir, feature_dir, repo_id, slug_from_request
from .paths import state_home as resolve_state_home
from .state import StateStore

_PHASE_ORDER = ["spec", "plan", "execute", "verify", "iterate", "deliver"]
_ALL_IMPLEMENTATION_PHASES = _PHASE_ORDER + ["debug", "revise"]
_RESUMABLE_PHASES = ("spec", "plan", "execute", "verify", "iterate", "deliver")


@dataclass
class Next:
    kind: Literal["step", "question", "result", "wait"]
    path: Path
    slug: str
    # A wave issuing several steps at once (Part A of the post-hardening item 3)
    # needs several LOOP_SPEC_NEXT lines from one continue_run call; every
    # existing caller reads only kind/path/slug on the primary Next unchanged,
    # so this stays additive rather than turning continue_run's return type
    # into a list everywhere it is read.
    also: list["Next"] = field(default_factory=list)


# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------


def run_entry(entry: str, *, project_root: Path, request_text: str | None, slug: str | None,
              state_home: str | None, answer_policy: str | None, pr: str | None) -> Next:
    project_root = Path(project_root)
    home = resolve_state_home(state_home)
    rid = repo_id(project_root)

    if entry in ("cycle", "micro"):
        return _run_request_entry(
            entry, project_root=project_root, request_text=request_text, slug=slug, home=home, rid=rid,
            answer_policy=answer_policy, cycle_type="full" if entry == "cycle" else "micro", initial_phase="spec",
        )

    if entry == "debug":
        return _run_request_entry(
            entry, project_root=project_root, request_text=request_text, slug=slug, home=home, rid=rid,
            answer_policy=answer_policy, cycle_type="debug", initial_phase="debug",
        )

    if entry == "revise":
        return _run_revise_entry(project_root=project_root, pr=pr, slug=slug, home=home, rid=rid, answer_policy=answer_policy)

    if entry in _RESUMABLE_PHASES:
        if not slug:
            raise LoopSpecError(f"{entry} requires --slug", repair="pass --slug <slug>, see `loop-spec status`")
        paths = FeaturePaths(root=feature_dir(home, rid, slug), project_root=project_root)
        store = StateStore.open(paths)
        _check_phase_preconditions(store, entry)
        if store.state["phase"]["current"] != entry:
            store.state["phase"]["current"] = entry
            store.state["phase"]["entry"] = "fresh"
            store.state["phase"]["attemptId"] = None
            store.save()
        return continue_run(store, paths, project_root=project_root)

    raise LoopSpecError(f"unknown entry {entry}", repair="use cycle, micro, debug, revise, spec, plan, execute, verify, iterate, or deliver")


def _run_request_entry(entry: str, *, project_root: Path, request_text: str | None, slug: str | None,
                        home: Path, rid: str, answer_policy: str | None, cycle_type: str, initial_phase: str) -> Next:
    # cycle, micro, and debug all start from free-text request and differ only in
    # their run's cycleType and first phase; revise starts from a PR instead, so it
    # builds its own run in _run_revise_entry rather than sharing this helper.
    if not request_text:
        # --slug with no request resumes that run instead of starting a new one;
        # the digest check below only applies when a request text is given.
        if not slug:
            raise LoopSpecError(f"{entry} requires --request, --request-file, or --slug to resume",
                                 repair="pass --request/--request-file for a new run, or --slug to resume one")
        paths = FeaturePaths(root=feature_dir(home, rid, slug), project_root=project_root)
        if not paths.state_json.exists():
            raise LoopSpecError(f"no run for slug {slug!r}", repair="check `loop-spec status` for known slugs, or pass --request to start one")
        return continue_run(StateStore.open(paths), paths, project_root=project_root)

    slug = slug or slug_from_request(request_text)
    paths = FeaturePaths(root=feature_dir(home, rid, slug), project_root=project_root)
    _clear_stale_last_result(paths, slug)

    if paths.state_json.exists():
        store = StateStore.open(paths)
        if store.state["request"]["digest"] != digest(request_text):
            raise LoopSpecError(f"slug {slug} is in use by another request", repair="pass --slug to choose a different slug")
    else:
        run_fields = {
            "id": new_id("run"), "entry": entry, "createdAt": now_iso(),
            "slug": slug, "repoId": rid, "cycleType": cycle_type,
        }
        store = StateStore.create(paths, run_fields, request_text)
        store.state["phase"]["current"] = initial_phase
        _resolve_repos(store, project_root, slug, request_text)
        _resolve_implementations(store, project_root)
        if answer_policy == "default":
            store.state["questions"]["policy"] = "default"
        store.save()
    return continue_run(store, paths, project_root=project_root)


def _find_run_by_adoption_number(home: Path, rid: str, number: int, project_root: Path) -> str | None:
    repo_home = home / rid
    if not repo_home.exists():
        return None
    for slug_dir in sorted(repo_home.iterdir()):
        candidate = FeaturePaths(root=slug_dir, project_root=project_root)
        if not candidate.state_json.exists():
            continue
        adoption = StateStore.open(candidate).state.get("adoption")
        if adoption is not None and adoption.get("number") == number:
            return slug_dir.name
    return None


def _delivering_run_entry(slug_dir_name: str, state: dict) -> dict | None:
    spec = (state.get("products", {}).get("spec") or {}).get("product")
    plan = (state.get("products", {}).get("plan") or {}).get("product")
    if spec is None or plan is None:
        return None
    return {"slug": slug_dir_name, "spec": spec, "plan": plan}


def _find_delivering_run_products(home: Path, rid: str, pr_url: str, project_root: Path) -> dict | None:
    # LF-37: the reviser role reads "the SPEC and PLAN products it was delivered
    # against" (its own SKILL.md), but had no way to find that prior run itself --
    # a live lead scavenged the state home with find|xargs grep to do it by hand.
    # This is that lookup: the run whose result.json names this PR (the original
    # delivery) wins over a prior revise of the same PR (adoption.url match only).
    repo_home = home / rid
    if not repo_home.exists():
        return None
    result_hit, adoption_hit = None, None
    for slug_dir in sorted(repo_home.iterdir()):
        candidate = FeaturePaths(root=slug_dir, project_root=project_root)
        if not candidate.state_json.exists():
            continue
        state = StateStore.open(candidate).state

        prs = (state.get("result") or {}).get("prs") or []
        if candidate.result_json.is_file():
            try:
                prs = read_json(candidate.result_json).get("prs") or prs
            except (OSError, ValueError):
                pass
        if result_hit is None and any(p.get("url") == pr_url for p in prs):
            result_hit = _delivering_run_entry(slug_dir.name, state)

        adoption = state.get("adoption")
        if adoption_hit is None and adoption is not None and adoption.get("url") == pr_url:
            adoption_hit = _delivering_run_entry(slug_dir.name, state)

    return result_hit or adoption_hit


def _run_revise_entry(*, project_root: Path, pr: str | None, slug: str | None, home: Path, rid: str,
                       answer_policy: str | None) -> Next:
    if not pr:
        if not slug:
            raise LoopSpecError("revise requires --pr, or --slug to resume", repair="pass --pr <number-or-url>, or --slug to resume one")
        paths = FeaturePaths(root=feature_dir(home, rid, slug), project_root=project_root)
        if not paths.state_json.exists():
            raise LoopSpecError(f"no run for slug {slug!r}", repair="check `loop-spec status` for known slugs, or pass --pr to start one")
        return continue_run(StateStore.open(paths), paths, project_root=project_root)

    workspace = repo_module.detect_workspace(project_root)
    if workspace.mode == "none":
        workspace.repos = [repo_module.init_in_place(project_root)]
    adoption, repo_name, repo_path = None, None, None
    for entry in workspace.repos:
        candidate = repo_module.adopt_pr(entry.path, pr)
        if candidate.adopt:
            adoption, repo_name, repo_path = candidate, entry.name, entry.path
            break
    if adoption is None:
        raise LoopSpecError(f"revise cannot adopt PR {pr!r}: {candidate.reason}", repair="check gh auth and that the PR is open and same-repo")

    existing_slug = _find_run_by_adoption_number(home, rid, adoption.number, project_root)
    slug = slug or existing_slug or f"revise-{adoption.number}"
    paths = FeaturePaths(root=feature_dir(home, rid, slug), project_root=project_root)
    _clear_stale_last_result(paths, slug)

    if paths.state_json.exists():
        return continue_run(StateStore.open(paths), paths, project_root=project_root)

    base_sha = repo_module.run_git(repo_path, "merge-base", adoption.base_branch, adoption.head_sha).strip()
    request_text = f"revise PR #{adoption.number}: {adoption.url}"
    run_fields = {"id": new_id("run"), "entry": "revise", "createdAt": now_iso(), "slug": slug, "repoId": rid, "cycleType": "revise"}
    store = StateStore.create(paths, run_fields, request_text)
    store.state["repos"] = {repo_name: {
        "path": str(repo_path), "baseSha": base_sha, "featureBranch": adoption.branch,
        "defaultBranch": adoption.base_branch, "lastKnownHead": adoption.head_sha,
    }}
    store.state["adoption"] = {
        "repo": repo_name, "number": adoption.number, "url": adoption.url, "headRef": adoption.branch,
        "baseBranch": adoption.base_branch, "baseSha": base_sha, "headSha": adoption.head_sha,
    }
    store.state["revise"] = {
        "gaps": revise_module.gaps_from_pr(repo_path, adoption.number), "product": None,
        "prior": _find_delivering_run_products(home, rid, adoption.url, project_root),
    }
    store.state["phase"]["current"] = "revise"
    _resolve_implementations(store, project_root)
    if answer_policy == "default":
        store.state["questions"]["policy"] = "default"
    store.save()
    return continue_run(store, paths, project_root=project_root)


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
            nexts = [Next(kind="step", path=paths.steps_dir / s["stepAttemptId"] / "step.json", slug=slug)
                     for s in open_steps]
            nexts[0].also = nexts[1:]
            return nexts[0]

        blocked_question_id = store.state["phase"].get("blockedQuestionId")
        if blocked_question_id is not None:
            answered = store.state["questions"]["answered"].get(blocked_question_id)
            if answered is not None:
                store.state["phase"]["blockedQuestionId"] = None
                if answered["value"] in ("stop", "reject with reason"):
                    store.save()
                    _finish_run(
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

        compaction = store.state["phase"].get("compaction")
        if compaction is not None and store.state["phase"]["current"] == "plan" and store.state["phase"].get("pending") is None:
            # SPEC's own _finalize just advanced phase.current to "plan" (a debug/
            # revise compaction's SPEC half was approved); feed the held PLAN half
            # in directly instead of letting _drive_phase ask a PLAN implementation.
            _resume_compaction(store, paths, project_root)
            continue

        pending = store.state["phase"].get("pending")
        if pending in ("approval", "critic"):
            phase = store.state["phase"]["current"]
            attempt_id = store.state["phase"]["attemptId"]
            product = store.state["phase"]["provisional"]
            _accept_product(store, paths, project_root, phase, attempt_id, product)
            continue

        waiting = _drive_phase(store, paths, project_root)
        if waiting is not None:
            return waiting


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
    entry_payload = state["phase"].get("entryPayload")
    if state["run"].get("cycleType") == "micro":
        # Every phase of a micro run carries entry.payload.preset = "micro" so a role
        # reads it without threading a separate "is this micro" field through state;
        # no phase's own remediation/rejection payload is dropped to make room for it.
        entry_payload = {**(entry_payload or {}), "preset": "micro"}
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
        "entry": {"mode": state["phase"]["entry"], "payload": entry_payload},
        "repos": state["repos"],
        "paths": {
            "stateDir": str(paths.root),
            "writable": [str(paths.attempts_dir / attempt_id), str(paths.worktrees_dir)],
            "projectRoot": str(project_root),
        },
        "answers": questions.answers_for_context(store, attempt_id),
        "probes": {},  # M1: probes.py lands at M2 (wave F); every phase sees an empty envelope.
    }


def _drive_phase(store: StateStore, paths: FeaturePaths, project_root: Path) -> Next | None:
    # None means "state changed, let continue_run's loop re-evaluate from the
    # top" (every existing branch); a Next means "nothing new to report, hand
    # this back to the caller directly" -- only the "wait" outcome does that,
    # since looping back to the top would just call this again with nothing
    # about the state having changed (contract.invoke() would report the same
    # wait every time).
    # An attempt spans every step round-trip for one phase invocation: the first
    # call here (attemptId is None) mints the attempt and writes its context once;
    # a later call for the SAME attempt (after a step the phase's own implementation
    # issued is submitted) re-invokes contract.invoke so it can see the file that
    # step wrote (e.g. an external phase's product.json) instead of starting over.
    phase = store.state["phase"]["current"]
    if phase == "execute":
        _migrate_legacy_baseline(store, paths)
    if (phase == "execute" and store.state.get("adoption") is not None and store.state.get("adoptedReview") is None
            and store.state["phase"].get("adoptedReviewStepId") is None):
        _issue_adopted_review(store, paths, project_root)
        return

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

    if phase == "deliver" and store.state["phase"].get("credentialsCheckedForAttempt") != attempt_id:
        # LF-21: this has to run before DELIVER's implementation is ever invoked for
        # this attempt -- deliver.py reads store.state["credentialChecks"] on its
        # first pass, and an empty dict there reads as every repo's credentials
        # unchecked, not as "not checked yet, check later".
        _record_deliver_credentials(store, attempt_id)

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
            retry_of=retry_of, reason=reason, model=request.get("model"),
            result_path=Path(request["resultPath"]),
        )
        store.state["phase"]["lastStepId"] = record["stepAttemptId"]
        store.save()
        return None
    if outcome.kind == "steps":
        # A wave's several requests at once (execute.py's IssueSteps): the LF-03
        # rejection override above is a single "the rejected attempt's own
        # product step" retryOf, which does not generalize to several
        # simultaneous re-issues, so each request here keeps its own
        # reason/retryOf as its implementation (execute.py's own per-task
        # rejection handling) already set them.
        for request in read_json(outcome.path):
            record = steps.issue(
                store, paths, phase=phase, attempt_id=attempt_id, kind=request["kind"], role=request.get("role"),
                cwd=Path(request["cwd"]), prompt=request["prompt"], schema=request["schema"],
                postconditions=request["postconditions"], inputs_digest=request["inputsDigest"],
                retry_of=request.get("retryOf"), reason=request.get("reason"), model=request.get("model"),
                result_path=Path(request["resultPath"]),
            )
            store.state["phase"]["lastStepId"] = record["stepAttemptId"]
        store.save()
        return None
    if outcome.kind == "wait":
        return Next(kind="wait", path=outcome.path, slug=store.state["run"]["slug"])
    if outcome.kind == "question":
        request = read_json(outcome.path)
        record = questions.ask(
            store, paths, phase=phase, attempt_id=attempt_id, text=request["text"], kind=request["kind"],
            options=request["options"], default_value=request.get("defaultValue"), payload=request.get("payload"),
        )
        questions.resolve_policy_answer(store, paths, record)
        return
    if outcome.kind == "error":
        _finish_run(store, paths, "failed", reason=outcome.stderr)
        return
    _accept_product(store, paths, project_root, phase, attempt_id, read_json(outcome.path))


# ---------------------------------------------------------------------------
# Product acceptance
# ---------------------------------------------------------------------------

def _answered_question_for_attempt(store: StateStore, attempt_id: str):
    for question_id, record in store.state["questions"]["answered"].items():
        if record.get("attempt") == attempt_id:
            return question_id, record
    return None


def _normalize_single_repo_task_repos(store: StateStore, paths: FeaturePaths, attempt_id: str, product: dict) -> None:
    repos = store.state.get("repos") or {}
    if len(repos) != 1:
        return  # a workspace's unknown repo is a real P6 failure, not ours to guess
    only_repo = next(iter(repos))
    for task in product.get("tasks", []):
        if task.get("repo") not in repos:
            task["repo"] = only_repo
            emit(paths, "plan_repo_normalized", {"taskId": task["id"], "repo": only_repo},
                 phase="plan", attempt_id=attempt_id)


def _accept_product(store: StateStore, paths: FeaturePaths, project_root: Path, phase: str, attempt_id: str, product: dict) -> None:
    existing = store.state["products"].get(phase)
    if existing is not None and existing.get("attemptId") == attempt_id:
        return  # already recorded for this attempt: never transition twice (IT-03).

    if phase == "revise":
        # revise.py's product is {spec, plan} only -- unlike every other phase, it
        # carries no "exit" at all (it is not one of the seven ROUTES phases).
        _accept_revise_product(store, paths, project_root, attempt_id, product)
        return

    if phase == "plan":
        # LF-31: a lead, compact (debug/revise), or external PLAN product can name
        # a task's repo loosely ("." for "the one repo", or leave it out) when
        # there is only one repo to mean; normalize before P6 or anything past it
        # sees the product, so a single-repo run never rejects what a human would
        # read as obviously right. A workspace has real ambiguity to report, so
        # this never touches a product when more than one repo is registered.
        _normalize_single_repo_task_repos(store, paths, attempt_id, product)

    exit_ = product["exit"]

    if phase == "debug":
        _accept_debug_product(store, paths, project_root, attempt_id, product, exit_)
        return

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

    _finalize(store, paths, project_root, phase, attempt_id, product, exit_)


def _accept_debug_product(store: StateStore, paths: FeaturePaths, project_root: Path, attempt_id: str, product: dict, exit_: str) -> None:
    boundary = postconditions.Boundary(store, paths, phase="debug", product=product, exit=exit_, project_root=project_root)
    if exit_ == "blocked reproduction":
        message = boundary._b3()
        if message is not None:
            _reject_product(store, paths, "debug", attempt_id, exit_, [postconditions.Failure("B3", message)])
            return
        _record_accepted_product(store, "debug", attempt_id, product, exit_, boundary)
        _ask_pause_question(store, paths, "debug", exit_, product)
        return

    # "reproduced": B1/B2 need the base run debug.record_base_runs is about to
    # capture, so they run against THIS boundary object after it, not through the
    # normal ROUTES-driven check() (which would also try S1-S3/P1-P7 against the
    # whole debug product instead of the SPEC/PLAN halves those ids actually name --
    # those run separately, below, once the compacted SPEC and PLAN are recorded).
    _, repo_info = next(iter(store.state["repos"].items()))
    debug_module.record_base_runs(store, paths, product, Path(repo_info["path"]), repo_info["baseSha"])
    failures = [postconditions.Failure(req_id, message) for req_id in ("B1", "B2")
                for message in [getattr(boundary, f"_{req_id.lower()}")()] if message is not None]
    if failures:
        _reject_product(store, paths, "debug", attempt_id, exit_, failures)
        return
    _record_accepted_product(store, "debug", attempt_id, product, exit_, boundary)

    spec_product, plan_product = debug_module.compact_products(product)
    spec_product = {**spec_product, "exit": "approved", "inputsDigest": product["inputsDigest"],
                     "boundTo": {"requirements": None, "plan": None}}
    plan_product = {**plan_product, "exit": "ready", "inputsDigest": product["inputsDigest"]}
    _begin_compaction(store, paths, project_root, spec_product, plan_product)


def _accept_revise_product(store: StateStore, paths: FeaturePaths, project_root: Path, attempt_id: str, product: dict) -> None:
    # revise.py's own docstring: "revise" is not one of the seven ROUTES phases, so
    # there is no ROUTES/Boundary postcondition check on the raw {spec, plan} product
    # here (contract.py already validated it against schemas/revise.json before this
    # was ever called), and it is not recorded under store.state["products"] (that
    # namespace's shape -- exit/boundTo/product -- is build_envelope's contract for
    # the seven ROUTES phases; revise.py already owns store.state["revise"]["product"]
    # as its own record). It re-enters through SPEC's own approval flow, same as
    # debug's compacted product below.
    store.state.setdefault("revise", {})["acceptedAttempt"] = attempt_id
    inputs_digest = digest(product)
    spec_product = {**product["spec"], "exit": "approved", "inputsDigest": inputs_digest, "boundTo": {"requirements": None, "plan": None}}
    plan_product = {**product["plan"], "exit": "ready", "inputsDigest": inputs_digest}
    _begin_compaction(store, paths, project_root, spec_product, plan_product)


def _begin_compaction(store: StateStore, paths: FeaturePaths, project_root: Path, spec_product: dict, plan_product: dict) -> None:
    # DEBUG and REVISE both land a compact {spec, plan} pair instead of driving
    # SPEC's or PLAN's own implementation. Recording them reuses the exact same
    # approval/baseline/critic machinery a real SPEC or PLAN product goes through
    # (S1-S3, P1-P7): _accept_product below is the same function every other phase
    # calls, just fed this pair instead of a spec-writer's or planner's own output.
    # The PLAN half waits in store.state["phase"]["compaction"] until SPEC's own
    # acceptance advances phase.current to "plan" -- continue_run's compaction check
    # feeds it in then, instead of letting _drive_phase ask a PLAN implementation.
    store.state["phase"]["compaction"] = {"plan": plan_product}
    spec_attempt_id = new_id("attempt")
    store.state["phase"]["current"] = "spec"
    store.state["phase"]["attemptId"] = spec_attempt_id
    store.state["phase"]["entry"] = "fresh"
    store.state["phase"]["entryPayload"] = None
    store.state["phase"]["pending"] = None
    store.state["phase"]["provisional"] = None
    store.save()
    _accept_product(store, paths, project_root, "spec", spec_attempt_id, spec_product)


def _resume_compaction(store: StateStore, paths: FeaturePaths, project_root: Path) -> None:
    plan_product = dict(store.state["phase"]["compaction"]["plan"])
    store.state["phase"]["compaction"] = None
    plan_product["boundTo"] = {"requirements": store.state["revisions"]["requirements"], "plan": None}
    plan_attempt_id = new_id("attempt")
    store.state["phase"]["attemptId"] = plan_attempt_id
    store.state["phase"]["entry"] = "fresh"
    store.state["phase"]["entryPayload"] = None
    store.state["phase"]["pending"] = None
    store.state["phase"]["provisional"] = None
    store.save()
    _accept_product(store, paths, project_root, "plan", plan_attempt_id, plan_product)


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


def _issue_critic_step(store: StateStore, paths: FeaturePaths, project_root: Path, attempt_id: str, plan_product: dict, is_external: bool, revision: str) -> None:
    # LF-32: this used to hand-write a prompt and an inline schema that contradicted
    # the role's own schema.json; every other role step goes through
    # roles.compose_prompt/load_role (see _issue_adopted_review), and the critic
    # step now does too.
    from .roles import compose_prompt, load_role, resolve_model
    repo_path = next(iter(store.state["repos"].values()))["path"]
    spec_product = store.state["products"]["spec"]["product"]
    inputs = {"specCriteria": spec_product["criteria"], "planTasks": plan_product["tasks"]}
    inputs_digest = digest({"plan": plan_product, "spec": spec_product})

    role = load_role("plan-critic", project_root, contract.resolve_role(project_root, "plan-critic"))
    ensure_results_dir(paths)
    result_path = paths.results_dir / f"plan-critic-{attempt_id}.json"
    prompt = compose_prompt(role, inputs=inputs, result_path=result_path, cwd=Path(repo_path), phase="plan")

    record = steps.issue(
        store, paths, phase="plan", attempt_id=attempt_id,
        kind="external" if is_external else "role", role=None if is_external else "plan-critic",
        cwd=Path(repo_path), prompt=prompt, schema=role.schema, postconditions=["P7"],
        inputs_digest=inputs_digest, result_path=result_path,
        model=None if is_external else resolve_model(project_root, "plan-critic"),
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
        _issue_critic_step(store, paths, project_root, attempt_id, product, is_external, revision)
        return "pending"

    # LF-32: the role schema has no disposition/reason/supersedes -- the critic
    # reports facts (id/location/cause/severity), the program owns disposition.
    findings = [{**f, "disposition": f.get("disposition", "open"), "reason": f.get("reason"),
                 "supersedes": f.get("supersedes")} for f in submission["findings"]]

    passes = (critic or {}).get("passes", 0) + 1
    store.state["critic"] = {"passes": passes, "findings": findings, "planRevision": revision}
    store.state["phase"]["pending"] = None
    store.state["phase"]["provisional"] = None
    store.save()

    open_critical = [f for f in findings if f.get("severity") == "Critical" and f.get("disposition") == "open"]
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


def _migrate_legacy_baseline(store: StateStore, paths: FeaturePaths) -> None:
    # R3: store.state["baseline"] used to be one flat Baseline dict for the
    # workspace's first repo; every reader now expects it keyed by repo under
    # "repos". A run whose baseline was captured under the old shape (still
    # mid-EXECUTE when this fix landed) is migrated in place, once, the first
    # time EXECUTE's own phase is driven afterward -- a sole repo's baseline
    # carries over as that repo's own entry (the only repo it could have meant);
    # an ambiguous multi-repo one is dropped, since which repo it belonged to
    # can no longer be told apart, rather than guessed at.
    baseline = store.state.get("baseline")
    if baseline is None or "repos" in baseline:
        return
    repos = store.state.get("repos") or {}
    migrated = {"planRevision": baseline.get("planRevision"), "repos": {}}
    if len(repos) == 1:
        repo_name = next(iter(repos))
        migrated["repos"][repo_name] = {k: v for k, v in baseline.items() if k != "planRevision"}
    store.state["baseline"] = migrated
    emit(paths, "module_state_reset",
         {"summary": "baseline state predates the per-repo shape; re-initializing", "missingKey": "repos"},
         phase="execute")
    store.save()


def _capture_plan_baseline(store: StateStore, paths: FeaturePaths, plan_product: dict, revision: str) -> None:
    # R3: each task's verify command is captured in THAT task's own repo, at that
    # repo's own base SHA -- a workspace's other repos never stand in for it.
    tasks_by_repo: dict[str, list[tuple]] = {}
    for t in plan_product["tasks"]:
        tasks_by_repo.setdefault(t["repo"], []).append((t["verify"], t["id"], t.get("featureAdded")))

    baselines: dict[str, dict] = {}
    # environmentHealth stays keyed per repo too, the same reason entries do: a
    # failing command string is only meaningful against the repo it failed in.
    health = store.state.setdefault("environmentHealth", {})
    for repo_name, commands in tasks_by_repo.items():
        repo_info = store.state["repos"][repo_name]
        baseline_obj = baseline_module.capture_baseline(
            Path(repo_info["path"]), repo_info["baseSha"], commands, plan_product.get("prepare"), paths.checkouts_dir, repo_name,
        )
        baselines[repo_name] = baseline_obj.to_dict()
        repo_health = health.setdefault(repo_name, {})
        for entry in baseline_obj.entries.values():
            if entry.run and entry.run.error_class is not None:
                repo_health[entry.command] = {"errorClass": entry.run.error_class, "recordedAt": now_iso()}

    store.state["baseline"] = {"planRevision": revision, "repos": baselines}
    store.save()


def _run_execute_verifications(store: StateStore, paths: FeaturePaths, execute_product: dict) -> None:
    baseline_state = store.state.get("baseline")
    if baseline_state is None:
        return
    plan_tasks = {t["id"]: t for t in store.state["products"]["plan"]["product"]["tasks"]}
    prepare = store.state["products"]["plan"]["product"].get("prepare")
    execute_runs = store.state.setdefault("executeRuns", {})
    for task in execute_product["tasks"]:
        if task["disposition"] not in ("done", "adopted") or task["id"] in execute_runs:
            continue
        plan_task = plan_tasks.get(task["id"])
        if plan_task is None:
            continue
        # R3: the re-run happens in THIS task's own repo, at that repo's own
        # EXECUTE head -- never always the workspace's first repo.
        repo_name = plan_task["repo"]
        repo_baseline_dict = baseline_module.repo_baseline_dict(baseline_state, repo_name, store.state["repos"])
        if repo_baseline_dict is None:
            continue
        repo_info = store.state["repos"][repo_name]
        repo_path = Path(repo_info["path"])
        head = execute_product["heads"].get(repo_name)
        if head is None:
            continue
        baseline_obj = baseline_module.Baseline.from_dict(repo_baseline_dict)
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
    # LF-28: each verdict's evidence names the repo it ran in; the clean re-run has
    # to happen at THAT repo's head, not the first repo in the workspace.
    heads = postconditions.verified_heads(store)
    prepare = store.state["products"]["plan"]["product"].get("prepare")
    # R10: resolved and consulted before any re-run is scheduled -- an approved
    # non-repeatable command must never be executed a second time just to record
    # that it was exempt (V4/V5 already skip an exempt criterion on their own).
    exceptions = postconditions.resolved_exceptions(store)
    verify_runs = store.state.setdefault("verifyRuns", {})
    for verdict in verify_product["verdicts"]:
        if verdict["verdict"] not in ("pass", "fail") or verdict["criterion"] in exceptions:
            continue
        evidence = verdict.get("evidence") or {}
        # R9: the EXECUTION may be reused when it was against the same repo, SHA,
        # and command (nothing about running the command again would differ), but
        # "matched" is a property of THIS claim against that execution, never a
        # fact stored once and trusted for a later, possibly different, claim.
        prior = verify_runs.get(verdict["criterion"])
        if prior and prior.get("repo") == evidence.get("repo") \
                and prior["rerun"].get("sha") == evidence.get("sha") \
                and prior["rerun"].get("command") == evidence.get("command"):
            rerun = baseline_module.CommandRun.from_dict(prior["rerun"])
            matched, reason = baseline_module.evidence_matches(evidence, rerun)
            verify_runs[verdict["criterion"]] = {
                "rerun": prior["rerun"], "matched": matched, "reason": reason, "repo": prior["repo"],
            }
            continue
        repo_name = evidence["repo"]
        repo_path = Path(store.state["repos"][repo_name]["path"])
        head = heads[repo_name]
        checkout = paths.checkouts_dir / f"verify-{verdict['criterion']}-{head[:12]}"
        repo_module.clean_checkout(repo_path, head, checkout)
        try:
            if prepare:
                baseline_module.run_command(prepare, checkout, head)
            rerun = baseline_module.run_command(evidence.get("command", ""), checkout, head)
        finally:
            repo_module.remove_worktree(repo_path, checkout, force=True)
        matched, reason = baseline_module.evidence_matches(evidence, rerun)
        verify_runs[verdict["criterion"]] = {"rerun": rerun.to_dict(), "matched": matched, "reason": reason, "repo": repo_name}
    store.save()


def _record_deliver_credentials(store: StateStore, attempt_id: str) -> None:
    checks = store.state.setdefault("credentialChecks", {})
    for name, info in store.state["repos"].items():
        status = repo_module.check_credentials(Path(info["path"]))
        checks[name] = {
            "git_ok": status.git_ok, "gh_ok": status.gh_ok, "checked": status.checked,
            "failedCommand": status.failed_command, "repair": status.repair,
        }
    store.state["phase"]["credentialsCheckedForAttempt"] = attempt_id
    store.save()


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
        _finish_run(store, paths, "escalated", reason=f"the rewind budget has no room for {phase} {exit_}")
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
            _finish_run(store, paths, "escalated", reason=str(exc))
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
        # already-cleared code names what it supersedes. LF-28: a workspace's
        # product carries one reviewed range per touched repo, so each is its own
        # ledger entry; findings are attributed to their own repo's entry rather
        # than stamped with whichever range happened to be recorded last.
        by_step = (store.state.get("verify") or {}).get("reviewerStep")
        findings = product.get("findings", [])
        reviewed_ranges = product["reviewedRanges"]
        multi_repo = len(reviewed_ranges) > 1
        for reviewed_range in reviewed_ranges:
            repo = reviewed_range["repo"]
            range_id = ledger_module.record_range(
                store, repo=repo, from_sha=reviewed_range["from"], to_sha=reviewed_range["to"],
                full=reviewed_range["full"], sha=reviewed_range["to"], by_step=by_step,
            )
            repo_findings = [f for f in findings if f.get("repo") == repo] if multi_repo else findings
            ledger_module.record_findings(store, repo_findings, sha=reviewed_range["to"], range_id=range_id)
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


def _pause_cause(phase: str, product: dict, exit_: str) -> str:
    # Each phase's blocked-style product names the cause in its own field: EXECUTE's
    # issues, VERIFY's blocked verdicts, DELIVER's per-repo caveats. Falling through
    # to the exit name (the pre-fix behavior) reads as a tautology, e.g. "DELIVER
    # exited delivery blocked: delivery blocked".
    if phase == "deliver":
        caveats = [c for entry in product.get("repos", []) for c in entry.get("caveats", [])]
        return "; ".join(caveats) if caveats else exit_
    issues = product.get("issues") or []
    if issues:
        return "; ".join(f"{i.get('task', '?')}: {i.get('text', '')}" for i in issues)
    blocked = [v["cause"] for v in product.get("verdicts", []) if v.get("verdict") == "blocked" and v.get("cause")]
    if blocked:
        return "; ".join(blocked)
    return exit_


def _ask_pause_question(store: StateStore, paths: FeaturePaths, phase: str, exit_: str, product: dict) -> None:
    cause = _pause_cause(phase, product, exit_)
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


def _protected_worktree_paths(store: StateStore) -> set[Path]:
    # R5: an open step's own worktree, or one already quarantined pending host
    # confirmation (steps.confirm_terminated), is never safe to force-remove
    # just because the RUN reached a terminal result elsewhere -- a worker
    # process touching one of them may still be running.
    open_paths = {Path(s["cwd"]).resolve() for s in store.state["steps"]["open"]}
    quarantined_paths = {Path(q["path"]).resolve() for q in store.state["steps"]["quarantined"]}
    return open_paths | quarantined_paths


def _finish_run(store: StateStore, paths: FeaturePaths, classification: str, *, reason: str | None = None,
                 summary: str | None = None, partially_delivered: bool = False) -> Path:
    # LF-39: every result_module.write in this module writes a terminal result
    # (nothing here passes "paused", the one classification that leaves a run
    # resumable) -- removing each repo's worktrees under this run's own feature
    # dir here, once, is the one place that covers every route into a terminal
    # state instead of one more site to remember at each call. Cleanup runs
    # BEFORE result_module.write (R5) so a skipped worktree's cleanupBacklog
    # entry is already in state for this same terminal result to carry, not
    # left for a result nobody will write again.
    if classification != "paused":
        protected = _protected_worktree_paths(store)
        removed = []
        for info in store.state.get("repos", {}).values():
            repo_removed, repo_skipped = repo_module.remove_worktrees(Path(info["path"]), paths.root, protected=protected)
            removed.extend(repo_removed)
            if repo_skipped:
                store.state.setdefault("cleanupBacklog", []).extend(repo_skipped)
        if removed:
            emit(paths, "worktrees_removed", {"removed": removed}, phase=store.state["phase"]["current"])
    return result_module.write(store, paths, classification, reason=reason, summary=summary,
                                partially_delivered=partially_delivered)


def _write_terminal_result(store: StateStore, paths: FeaturePaths, phase: str, exit_: str) -> None:
    if phase == "iterate" and exit_ == "escalated":
        _finish_run(store, paths, "escalated")
        return
    if store.state.get("escalatedDraft"):
        # This run reached DELIVER only because escalatedPartialDraft routed an
        # escalated ITERATE forward; it still classifies as escalated, DELIVER just
        # fills in `delivery` with whatever it managed to publish (roadmap 15).
        _finish_run(store, paths, "escalated", partially_delivered=(exit_ == "partially delivered"))
        return
    if exit_ == "partially delivered":
        # R7: a converged ITERATE whose DELIVER only reached some repos is not
        # "converged" -- the schema-1 table has no row for a converged
        # classification that left a repo undelivered. The deliver outcome, not
        # just ITERATE's verdict, decides the terminal classification here.
        not_delivered = [entry["repo"] for entry in store.state["products"]["deliver"]["product"]["repos"]
                          if entry["state"] != "delivered"]
        _finish_run(store, paths, "escalated", partially_delivered=True,
                    reason=f"did not deliver: {', '.join(not_delivered)}")
        return
    execute_exit = store.state["products"]["execute"]["exit"]
    iterate_exit = store.state["products"]["iterate"]["exit"]
    if execute_exit == "no change":
        classification = "no-change"
    elif iterate_exit == "converged with caveats":
        classification = "converged-with-caveats"
    else:
        classification = "converged"
    _finish_run(store, paths, classification)


# ---------------------------------------------------------------------------
# Adopted-PR review (revise's one full pass before EXECUTE starts its own work)
# ---------------------------------------------------------------------------

_ADOPTED_REVIEW_DIFF_CAP = 200_000  # ponytail: same flat cap verify.py/revise.py use


def _issue_adopted_review(store: StateStore, paths: FeaturePaths, project_root: Path) -> None:
    # A revise run adopts an existing PR's commits rather than having EXECUTE write
    # them; E5/E6 refuse to call any of its tasks "adopted" until one full
    # code-reviewer pass over the whole adopted range is on record. Issued once,
    # before EXECUTE's own attempt starts, so that record exists before any task
    # can claim it.
    from .roles import compose_prompt, load_role, resolve_model
    adoption = store.state["adoption"]
    repo_info = store.state["repos"][adoption["repo"]]
    repo_path = Path(repo_info["path"])
    checkout = paths.checkouts_dir / f"adopted-{adoption['headSha'][:12]}"
    repo_module.clean_checkout(repo_path, adoption["headSha"], checkout)
    diff = repo_module.run_git(repo_path, "diff", f"{adoption['baseSha']}..{adoption['headSha']}")
    if len(diff) > _ADOPTED_REVIEW_DIFF_CAP:
        diff = diff[:_ADOPTED_REVIEW_DIFF_CAP] + "\n...(truncated)"

    role = load_role("code-reviewer", project_root, contract.resolve_role(project_root, "code-reviewer"))
    attempt_id = new_id("attempt")
    # LF-27: a model-written result goes under the project's results dir, never
    # the state home (checkout is under state home; a live model's default
    # permission mode refuses writes there).
    ensure_results_dir(paths)
    result_path = paths.results_dir / f"adopted-review-{attempt_id}.json"
    inputs = {
        "range": {"from": adoption["baseSha"], "to": adoption["headSha"], "full": True}, "diff": diff,
        "ledger": {"reviewedRanges": [], "openFindings": []}, "rangeProbes": {}, "securitySignals": [], "full": True,
    }
    prompt = compose_prompt(role, inputs=inputs, result_path=result_path, cwd=checkout, phase="execute")
    record = steps.issue(
        store, paths, phase="execute", attempt_id=attempt_id, kind="role", role="code-reviewer",
        cwd=checkout, prompt=prompt, schema=role.schema, postconditions=[], inputs_digest=digest(inputs),
        result_path=result_path, model=resolve_model(project_root, "code-reviewer"),
    )
    store.state["phase"]["adoptedReviewStepId"] = record["stepAttemptId"]
    store.save()


# ---------------------------------------------------------------------------
# Step submission routing
# ---------------------------------------------------------------------------

_SUBMIT_ROLE_MODULES = {
    ("execute", "implementer"): execute_module, ("execute", "code-reviewer"): execute_module,
    ("verify", "verifier"): verify_module, ("verify", "code-reviewer"): verify_module,
    ("iterate", "iterate-judge"): iterate_module,
    ("debug", "debugger"): debug_module,
    ("revise", "reviser"): revise_module,
}


def route_submission(store: StateStore, paths: FeaturePaths, step: dict, result: dict) -> None:
    """Hand a submitted step's result to the module that owns its phase's default
    implementation. The one exception is the adopted-PR review _issue_adopted_review
    issues before EXECUTE's own attempt starts: same phase and role as an ordinary
    EXECUTE review step, so its step id (not phase/role) is what tells them apart."""
    if step["stepAttemptId"] == store.state["phase"].get("adoptedReviewStepId"):
        store.state["adoptedReview"] = result
        store.save()
        return
    module = _SUBMIT_ROLE_MODULES.get((step["phase"], step["role"]))
    if module is not None:
        module.on_submit(store, paths, step, result)
