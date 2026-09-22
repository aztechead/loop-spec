"""EXECUTE's default implementation (M3): drive the plan's tasks to integrated
commits through an implement/review/verify loop, one step at a time.

Use `step` as the per-call decision (issue a role step, pause for an operator
question, or hand back the phase product once every task is terminal) and
`on_submit` to fold a step's result back into `store.state["execute"]` between
calls; wiring `step`/`on_submit` into `contract.invoke`'s "default" dispatch for
phase="execute" is another agent's change, not this module's. `dag_waves` is the
pure Kahn-layering the plan's `dependsOn` graph needs before any task can start;
nothing else here is reusable outside this one phase's loop.
"""
import os
import re
from pathlib import Path

from . import baseline as baseline_module
from . import probes as probes_module
from . import repo as repo_module
from . import steps as steps_module
from .budget import has_room
from .contract import resolve_role, validate_request
from .errors import LoopSpecError
from .events import emit
from .ids import now_iso
from .paths import ensure_results_dir
from .postconditions import adopted_commits, retry_limit
from .roles import compose_prompt, load_role, resolve_model

_TERMINAL = {"done", "already-satisfied", "removed", "blocked", "planGap", "adopted"}
_DIFF_CAP = 200_000  # ponytail: a flat cap, raise it if a real diff gets truncated in practice
# LF-16: a rejected EXECUTE product's failures route to the task-state change that
# gives the NEXT attempt a chance to actually differ, instead of resubmitting the
# same already-"done" tasks and getting rejected again. E5/E6/E11 are all evidence-
# about-the-review defects a fresh review step can re-settle without redoing the
# implementation; E7 is the verify re-run itself, which only a new implement step
# can change.
_REVIEW_RETRY_FAILURE_IDS = {"E5", "E6", "E11"}
_IMPLEMENT_RETRY_FAILURE_ID = "E7"
_BLOCKED_OPTIONS = [
    {"value": "fix-and-re-enter", "label": "Fix and re-enter"},
    {"value": "stop", "label": "Stop"},
]
_TASK_ID_RE = re.compile(r"T-\d+")
# LF-11: a verify re-run that could never have passed no matter what the implementer
# does is a defect in PLAN's own verify/featureAdded/mustFlip fields, not something a
# retry fixes. "reproduction still fails at the candidate commit" (the OTHER
# mustFlip-failed detail) stays on the retry path below -- that one means the
# implementer's fix did not land yet, which a retry can still address.
_MUST_FLIP_BASELINE_DETAIL = "reproduction did not fail at base"


class IssueStep:
    __slots__ = ("request",)

    def __init__(self, request: dict) -> None:
        self.request = request


class IssueSteps:
    """Two or more requests from the SAME wave, for the lead to dispatch in
    parallel (step() falls back to the single-request IssueStep when a wave
    only ever has one request to issue, so every other module's step() and
    every existing test of it are unaffected)."""
    __slots__ = ("requests",)

    def __init__(self, requests: list[dict]) -> None:
        self.requests = requests


class Wait:
    """Nothing new to issue this call, but the wave is not done: one or more of
    its tasks already have a step open (implementing/reviewing) from an earlier
    call in this same wave. `open` names those steps' ids so the caller knows
    what it is waiting on rather than being told to start something new."""
    __slots__ = ("open",)

    def __init__(self, open: list[str]) -> None:
        self.open = open


class Product:
    __slots__ = ("product",)

    def __init__(self, product: dict) -> None:
        self.product = product


class Pause:
    __slots__ = ("question_request",)

    def __init__(self, question_request: dict) -> None:
        self.question_request = question_request


def dag_waves(tasks: list[dict], width: int = 3) -> list[list[str]]:
    """Kahn-layer `tasks` by `dependsOn`: a wave holds at most `width` ready tasks,
    and a task is ready once every dependency sits in an earlier wave."""
    deps = {t["id"]: list(t.get("dependsOn") or []) for t in tasks}
    remaining = set(deps)
    placed: set[str] = set()
    waves: list[list[str]] = []
    while remaining:
        ready = sorted(tid for tid in remaining if all(d in placed for d in deps[tid]))
        if not ready:
            raise LoopSpecError(
                "the task graph has a cycle dag_waves cannot layer",
                repair="fix each task's dependsOn so the graph has no cycle (PLAN's P5 should have caught this)",
            )
        wave = ready[:width]
        waves.append(wave)
        placed.update(wave)
        remaining.difference_update(wave)
    return waves


# --- shared state access --------------------------------------------------

def _plan_tasks(store) -> dict:
    return {t["id"]: t for t in store.state["products"]["plan"]["product"]["tasks"]}


def _retry_or_block(execute_state: dict, task_id: str, task_state: dict, reason_text: str, *, retry_status: str = "pending") -> None:
    task_state["retries"] += 1
    if task_state["retries"] > retry_limit():
        task_state["status"] = "blocked"
        task_state["reason"] = None
        execute_state["issues"].append({"task": task_id, "text": reason_text})
    else:
        task_state["status"] = retry_status
        task_state["reason"] = reason_text


def _route_verify_comparison(execute_state: dict, task_id: str, task_state: dict, comparison) -> None:
    """`baseline-error` and a `mustFlip-failed` baseline that never failed are PLAN's
    own mistake (see `_MUST_FLIP_BASELINE_DETAIL` above): route straight to plan gap,
    spending none of the task's retry budget on an outcome no retry can change. Every
    other failing verdict (`regression`, `featureAdded-failed`, a `mustFlip-failed`
    whose reproduction still fails at the candidate) is still the implementer's to fix
    and keeps the retry-then-block path."""
    reason_text = f"the verify re-run is {comparison.verdict}: {comparison.detail}"
    is_plan_defect = comparison.verdict == "baseline-error" or (
        comparison.verdict == "mustFlip-failed" and comparison.detail == _MUST_FLIP_BASELINE_DETAIL
    )
    if is_plan_defect:
        task_state["status"] = "planGap"
        task_state["reason"] = None
        execute_state["issues"].append({"task": task_id, "text": reason_text})
        return
    _retry_or_block(execute_state, task_id, task_state, reason_text)


# --- initialization (first step() call only) ------------------------------

def _mark_adopted_tasks(store, paths, ctx, tasks: dict, plan_tasks: list[dict]) -> None:
    # LF-38: the reviser's own contract carries an unchanged prior task forward
    # verbatim; EXECUTE must not re-implement work the adopted PR already
    # delivered, or the worker finds nothing to do and the run blocks after
    # retries exhaust. A task counts as adopted only when its full dict (every
    # field a reviser could have touched) still matches the delivering run's plan.
    adoption = store.state.get("adoption")
    prior = (store.state.get("revise") or {}).get("prior")
    if adoption is None or not prior or not prior.get("plan"):
        return
    prior_tasks = {t["id"]: t for t in prior["plan"]["tasks"]}
    fields = ("title", "files", "repo", "verify", "criteria", "dependsOn", "featureAdded", "mustFlip")
    for plan_task in plan_tasks:
        prior_task = prior_tasks.get(plan_task["id"])
        if prior_task is None or any(plan_task.get(f) != prior_task.get(f) for f in fields):
            continue
        repo_name = plan_task["repo"]
        # The adopted range only covers the PR's own repo; a workspace's other
        # repos have no adopted commits to attribute a task's work to.
        if repo_name != adoption.get("repo"):
            continue
        repo_info = store.state["repos"][repo_name]
        commits = repo_module.commits_between(Path(repo_info["path"]), repo_info["baseSha"], adoption["headSha"])
        task_state = tasks[plan_task["id"]]
        task_state.update({
            "status": "adopted", "commits": commits,
            "integratedFrom": repo_info["baseSha"], "integratedTo": adoption["headSha"],
            "evidence": None, "review": None,
            # LF-51: an adopted task's review anchor is the repo's own base, not a
            # fork this task never made -- a later remediation's review still
            # covers the adopted commits plus whatever the repair adds.
            "reviewFrom": repo_info["baseSha"],
        })
        emit(paths, "task_adopted", {"task": plan_task["id"]}, phase="execute", attempt_id=ctx["attempt"]["id"])


def _init(store, paths, ctx) -> dict:
    plan_tasks = store.state["products"]["plan"]["product"]["tasks"]
    width = int(os.environ.get("LOOP_SPEC_EXECUTE_WIDTH", "3"))
    waves = dag_waves(plan_tasks, width=width)

    # The feature branch is checked out in its own worktree here, once, so a task's
    # commits ever land in the operator's own checkout only via the fast-forward
    # merge in on_submit -- never by working directly in repo_info["path"]. LF-13:
    # nothing else creates this branch, so a repo entering EXECUTE for the first
    # time needs it minted here, at baseSha. An already-existing branch is recorded
    # at its EXPECTED head (lastKnownHead), not whatever it actually points at now:
    # a foreign or stale branch then reads as an out-of-band move to the very next
    # check below (the same one a mid-run move already pauses for), instead of this
    # module silently adopting a head it never verified.
    repos = {}
    for name, info in (store.state.get("repos") or {}).items():
        repo_path = Path(info["path"])
        if repo_module.branch_sha(repo_path, info["featureBranch"]) is None:
            repo_module.create_feature_branch(repo_path, info["featureBranch"], info["baseSha"])
        worktree = paths.worktrees_dir / "feature" / name
        repo_module.add_worktree(repo_path, worktree, branch=info["featureBranch"])
        # LF-15: defaultHead is the checkout's OWN branch (main, say) at entry --
        # a worker that commits there by mistake, instead of into its task
        # worktree, moves it out from under the run the same way a moved feature
        # branch already did above.
        repos[name] = {
            "worktree": str(worktree), "head": info["lastKnownHead"],
            "defaultHead": repo_module.branch_sha(repo_path, info["defaultBranch"]),
        }

    tasks = {
        t["id"]: {
            "status": "pending", "repo": t["repo"], "worktree": None, "branch": None,
            "baseLayers": None, "implementSteps": [], "reviewSteps": [], "commits": [],
            "review": None, "probes": None, "evidence": None, "retries": 0, "reason": None,
            # LF-17: the range a task's commits were actually computed from, set once
            # at its first real merge -- a later re-review of the same integration
            # (feature_head == task_head, nothing new to merge) has no range of its
            # own to overwrite these with.
            "integratedFrom": None, "integratedTo": None,
            # The feature head this task's own worktree/branch forked from (set once,
            # in _ensure_worktree): a same-wave sibling issued at the same time can
            # merge first and move the feature head before this task's own review or
            # integration happen, so both must diff/compare against the head this
            # task actually started from, never whatever the feature head is now.
            "forkedFrom": None,
            # LF-51: the task's REVIEW anchor -- set once, at the first fork (or a
            # repo's baseSha for an adopted task), and kept through any later
            # remediation re-fork so one review still covers every commit the task
            # owns. forkedFrom moves on every re-fork; reviewFrom does not.
            "reviewFrom": None,
            # Bumped on every re-fork (remediation, plan reconciliation, a merge
            # conflict); names that generation's branch/worktree so a retained
            # earlier one is never collided with or silently reused.
            "generation": 0,
            "remediations": [],
        }
        for t in plan_tasks
    }
    _mark_adopted_tasks(store, paths, ctx, tasks, plan_tasks)

    execute_state = {"waves": waves, "tasks": tasks, "repos": repos, "issues": [], "handledRejections": [], "handledRewinds": []}
    store.state["execute"] = execute_state
    store.save()
    return execute_state


def _ensure_worktree(store, paths, ctx, task_id: str, task_state: dict, plan_task: dict) -> Pause | None:
    if task_state["worktree"] is not None:
        return None
    # Forked from the feature branch's CURRENT head, not a head captured at
    # init time: a later wave's task must build on top of earlier waves' already
    # -integrated commits, not the run's original base.
    execute_state = store.state["execute"]
    repo_state = execute_state["repos"][task_state["repo"]]
    repo_info = store.state["repos"][task_state["repo"]]
    repo_path = Path(repo_info["path"])
    # LF-14: task/<task-id> alone collided with the same task id from an earlier
    # run of this repo. Slug-scoping still is not enough on its own -- a LEFTOVER
    # branch from a PRIOR run of this exact slug is the same out-of-band condition
    # the feature branch check already pauses for; only an empty one (no commits
    # past the feature head this task is about to fork from) is safe to reuse.
    branch = f"task/{store.state['run']['slug']}/{task_id}"
    existing = repo_module.branch_sha(repo_path, branch)
    if existing is not None and existing != repo_state["head"]:
        text = (f"task branch {branch!r} already exists with commits not in the feature "
                f"head (expected {repo_state['head']}, found {existing}); how should the run proceed?")
        return Pause(_pause_request(ctx, task_state["repo"], repo_state["head"], existing, text=text))
    if existing is None:
        repo_module.create_feature_branch(repo_path, branch, repo_state["head"])

    worktree = paths.worktrees_dir / task_id
    repo_module.add_worktree(repo_path, worktree, branch=branch)
    task_state["worktree"] = str(worktree)
    task_state["branch"] = branch
    task_state["baseLayers"] = probes_module.indirection_scan(worktree, plan_task["files"])["layers"]
    task_state["forkedFrom"] = repo_state["head"]
    if task_state.get("reviewFrom") is None:
        task_state["reviewFrom"] = repo_state["head"]
    store.save()
    return None


def _fork_point(paths, execute_state: dict, task_state: dict, task_id: str, attempt_id: str | None) -> str:
    # Legacy state (written before forkedFrom existed) has no recorded fork
    # point for a task whose worktree already existed; the current feature head
    # is the same safe adoption _drifted_repo already uses for its own missing
    # defaultHead (a run that started before this key existed has no better
    # answer than "assume nothing has moved yet").
    if task_state.get("forkedFrom") is None:
        task_state["forkedFrom"] = execute_state["repos"][task_state["repo"]]["head"]
        emit(paths, "module_state_reset",
             {"summary": f"execute task {task_id} had no forkedFrom; adopted the current feature head", "missingKey": "forkedFrom"},
             phase="execute", attempt_id=attempt_id)
    return task_state["forkedFrom"]


def _review_from(task_state: dict) -> str:
    # LF-51: a task's review always starts from its historical anchor, not
    # wherever its CURRENT branch happens to have forked from -- a remediation
    # re-fork moves forkedFrom but must not orphan the review of commits an
    # earlier, already-accepted pass already covered. Legacy state (written
    # before reviewFrom existed) falls back to forkedFrom, same as it always used.
    return task_state.get("reviewFrom") or task_state["forkedFrom"]


# --- step requests ---------------------------------------------------------

def _result_path(paths, task_id: str, kind: str, n: int) -> Path:
    # LF-27: under the project root (paths.results_dir), not the state home --
    # a live model, under Claude Code's default permission mode, cannot write
    # under ~/.claude/... even with the Write tool allow-listed.
    ensure_results_dir(paths)
    return paths.results_dir / f"{task_id}-{kind}-{n}.json"


def _implement_request(store, paths, ctx, plan_task: dict, task_state: dict, task_id: str) -> dict | Pause:
    pause = _ensure_worktree(store, paths, ctx, task_id, task_state, plan_task)
    if pause is not None:
        return pause
    worktree = Path(task_state["worktree"])
    project_root = Path(ctx["paths"]["projectRoot"])
    role = load_role("implementer", project_root, resolve_role(project_root, "implementer"))
    spec = store.state["products"]["spec"]["product"]
    # The result file lives outside the worktree: a result written into the checkout
    # shows up in `git status` and made every implement submission fail is_clean until
    # the lead hacked the repo's exclude file (live finding LF-07).
    result_path = _result_path(paths, task_id, "implement", len(task_state["implementSteps"]) + 1)

    inputs = {
        "task": plan_task,
        "criteria": [c for c in spec["criteria"] if c["id"] in plan_task["criteria"]],
        "probes": ctx.get("probes", {}),
        "minimalDiff": not has_room(store),
    }
    if task_state["reason"]:
        inputs["retryReason"] = task_state["reason"]
    prompt = compose_prompt(role, inputs=inputs, result_path=result_path, cwd=worktree, phase="execute")

    request = {
        "kind": "role", "role": "implementer", "phase": "execute", "cwd": str(worktree),
        "prompt": prompt, "resultPath": str(result_path), "schema": role.schema, "postconditions": [],
        "attempt": ctx["attempt"]["id"], "inputsDigest": ctx["inputs"]["digest"],
        "retryOf": task_state["implementSteps"][-1] if task_state["implementSteps"] else None,
        "reason": task_state["reason"], "model": resolve_model(project_root, "implementer"),
    }
    errors = validate_request("step", request)
    if errors:
        raise LoopSpecError("execute built an invalid implement step request: " + "; ".join(errors),
                             repair="fix _implement_request in execute.py")
    task_state["status"] = "implementing"
    store.save()
    return request


def _review_request(store, paths, ctx, plan_task: dict, task_state: dict) -> dict:
    worktree = Path(task_state["worktree"])
    project_root = Path(ctx["paths"]["projectRoot"])
    role = load_role("code-reviewer", project_root, resolve_role(project_root, "code-reviewer"))
    execute_state = store.state["execute"]
    # The range/diff a reviewer sees is always base..task from the head this
    # task's own worktree FORKED from, never the feature branch's current head:
    # a same-wave sibling can merge first and move that current head, and a
    # two-dot diff against a moved head would show the sibling's own work as
    # removed (a plain wrong diff), not just a stale one.
    # _fork_point still runs (and backfills a legacy forkedFrom) even though its
    # own return value is no longer what the reviewer sees below -- reviewFrom
    # falls back to forkedFrom (_review_from) and needs it populated either way.
    _fork_point(paths, execute_state, task_state, plan_task["id"], ctx["attempt"]["id"])
    review_from = _review_from(task_state)
    task_head = repo_module.branch_sha(worktree, task_state["branch"])
    result_path = _result_path(paths, plan_task["id"], "review", len(task_state["reviewSteps"]) + 1)

    diff = repo_module.run_git(worktree, "diff", f"{review_from}..{task_head}")
    if len(diff) > _DIFF_CAP:
        diff = diff[:_DIFF_CAP] + "\n...(truncated)"

    signals = (ctx.get("probes") or {}).get("securitySignals") or []
    inputs = {
        "task": plan_task,
        "range": {"from": review_from, "to": task_head},
        "diff": diff,
        "probes": task_state["probes"],
        "ledger": store.state.get("ledger", {}),
        "securitySignals": [s for s in signals if s.get("file") in plan_task["files"]],
    }
    prompt = compose_prompt(role, inputs=inputs, result_path=result_path, cwd=worktree, phase="execute")

    request = {
        "kind": "role", "role": "code-reviewer", "phase": "execute", "cwd": str(worktree),
        "prompt": prompt, "resultPath": str(result_path), "schema": role.schema, "postconditions": [],
        "attempt": ctx["attempt"]["id"], "inputsDigest": ctx["inputs"]["digest"],
        # LF-16: normally None/None -- a task only ever reaches "probing" fresh,
        # straight from a passing implement step. A rejection re-routed back to
        # review (see _handle_rejection) is the one case with a reason already
        # set and a prior review step to retry.
        "retryOf": task_state["reviewSteps"][-1] if task_state["reviewSteps"] else None,
        "reason": task_state["reason"], "model": resolve_model(project_root, "code-reviewer"),
    }
    errors = validate_request("step", request)
    if errors:
        raise LoopSpecError("execute built an invalid review step request: " + "; ".join(errors),
                             repair="fix _review_request in execute.py")
    task_state["status"] = "reviewing"
    store.save()
    return request


def _pause_request(ctx, repo_name: str, expected: str, actual: str, *, text: str | None = None) -> dict:
    request = {
        "attempt": ctx["attempt"]["id"], "phase": "execute",
        "text": text or (f"repo {repo_name}'s feature branch moved out of band "
                          f"(expected {expected}, found {actual}); how should the run proceed?"),
        "options": [
            {"value": "resume", "label": "treat the new head as the base and continue"},
            {"value": "abort", "label": "stop the run here"},
        ],
        "defaultValue": None, "kind": "blocked",
        "payload": {"repo": repo_name, "expected": expected, "actual": actual},
    }
    errors = validate_request("question", request)
    if errors:
        raise LoopSpecError("execute built an invalid pause question: " + "; ".join(errors),
                             repair="fix _pause_request in execute.py")
    return request


def _blocked_pause_request(ctx, text: str, payload: dict) -> dict:
    """The shared shape for a pause that needs a human to reconcile something
    outside any retry's reach (LF-15's default-branch drift, LF-16's E4 unmapped
    commits) -- "fix-and-re-enter" or "stop", the same options the controller's
    own blocked questions already use, never an automatic resume."""
    request = {
        "attempt": ctx["attempt"]["id"], "phase": "execute", "text": text,
        "options": _BLOCKED_OPTIONS, "defaultValue": None, "kind": "blocked", "payload": payload,
    }
    errors = validate_request("question", request)
    if errors:
        raise LoopSpecError("execute built an invalid blocked pause question: " + "; ".join(errors),
                             repair="fix _blocked_pause_request in execute.py")
    return request


def _drifted_repo(store, paths, execute_state: dict, attempt_id: str | None = None) -> dict | None:
    """The first repo whose feature or default branch no longer points where
    execute.py last recorded it -- an out-of-band commit, most often a worker
    committing into the wrong checkout (LF-13's feature-branch case, LF-15's
    default-branch one). None means every repo still matches. Shared by step()
    (which turns this into the actual pause) and on_submit() (which uses it only
    to refuse folding a possibly-compromised submission into task state)."""
    for name, repo_state in execute_state["repos"].items():
        repo_info = store.state["repos"][name]
        repo_path = Path(repo_info["path"])
        actual = repo_module.branch_sha(repo_path, repo_info["featureBranch"])
        if actual is not None and actual != repo_state["head"]:
            return {"repo": name, "branch": repo_info["featureBranch"], "isDefault": False,
                     "expected": repo_state["head"], "actual": actual}
        default_actual = repo_module.branch_sha(repo_path, repo_info["defaultBranch"])
        # A run that started before this check existed has no recorded default head;
        # adopt the current one rather than fail every older run on resume.
        if "defaultHead" not in repo_state:
            repo_state["defaultHead"] = default_actual
            store.save()
            emit(paths, "module_state_reset",
                 {"summary": f"execute repo {name!r} had no defaultHead; adopted the current one", "missingKey": "defaultHead"},
                 phase="execute", attempt_id=attempt_id)
        if default_actual is not None and default_actual != repo_state["defaultHead"]:
            return {"repo": name, "branch": repo_info["defaultBranch"], "isDefault": True,
                     "expected": repo_state["defaultHead"], "actual": default_actual}
    return None


def _drift_pause(ctx, drift: dict) -> Pause:
    if not drift["isDefault"]:
        return Pause(_pause_request(ctx, drift["repo"], drift["expected"], drift["actual"]))
    text = (f"the checkout's {drift['branch']} moved from {drift['expected']} to {drift['actual']} during "
            f"EXECUTE (a worker may have committed outside its worktree); reconcile it yourself, then "
            f"fix-and-re-enter, or stop")
    payload = {"repo": drift["repo"], "branch": drift["branch"], "expected": drift["expected"], "actual": drift["actual"]}
    return Pause(_blocked_pause_request(ctx, text, payload))


def _unmapped_commits_pause(store, ctx, execute_state: dict) -> Pause | None:
    """LF-16's E4: recomputes the postcondition's own check (every done task's
    commits must exactly cover base..head) instead of parsing its repo-only
    message, so the pause can name the actual mismatched commits."""
    for name, repo_state in execute_state["repos"].items():
        repo_info = store.state["repos"][name]
        repo_path = Path(repo_info["path"])
        task_commits = {
            repo_module.head_sha(repo_path, c)
            for task_state in execute_state["tasks"].values()
            if task_state["repo"] == name and task_state["status"] == "done"
            for c in task_state["commits"]
        }
        actual = set(repo_module.commits_between(repo_path, repo_info["baseSha"], repo_state["head"]))
        adopted = adopted_commits(store, name, repo_path)  # LF-44, same rule as E4
        mismatched = sorted((task_commits - adopted) ^ (actual - adopted))
        if mismatched:
            text = (f"repo {name}: commits {', '.join(mismatched)} are not exactly covered by any task's "
                     f"recorded commits; reconcile them, then fix-and-re-enter, or stop")
            return Pause(_blocked_pause_request(ctx, text, {"repo": name, "commits": mismatched}))
    return None


def _open_step_id(store, task_state: dict) -> str | None:
    # task_state["implementSteps"]/["reviewSteps"] only gain an id once that step
    # is SUBMITTED (_on_implement_submit/_on_review_submit append it there); a
    # task mid-flight ("implementing"/"reviewing") with no submission yet -- the
    # common case Wait exists for -- has nothing in either list yet. The step
    # actually open for it lives in store.state["steps"]["open"], keyed by the
    # same worktree cwd on_submit itself uses to find a task.
    return next((s["stepAttemptId"] for s in store.state["steps"]["open"] if s["cwd"] == task_state["worktree"]), None)


def _rejection_task_ids(message: str, execute_state: dict) -> list[str]:
    """The task ids a rejection's message names ("T-n" tokens); with none, every
    currently-done task. E6's own message already lists every id it means (it
    aggregates), so this only widens scope for a message that names none."""
    parsed = [tid for tid in _TASK_ID_RE.findall(message) if execute_state["tasks"].get(tid, {}).get("status") == "done"]
    if parsed:
        return parsed
    return [tid for tid, t in execute_state["tasks"].items() if t["status"] == "done"]


def _handle_rejection(store, paths, ctx, execute_state: dict) -> Pause | None:
    """LF-16: a rejected EXECUTE product re-enters remediation with the SAME
    already-"done" task state that got rejected -- left alone, the next attempt
    reproduces the identical product and gets rejected again. Undo just enough of
    the named tasks' progress that a fresh review or implement step can actually
    change something, and only once per attempt (handledRejections) so a later
    step() call in the same remediation round does not re-clear a review this
    same handling just re-issued."""
    entry = ctx["entry"]
    if entry.get("mode") != "remediation":
        return None
    rejected = (entry.get("payload") or {}).get("rejected")
    if not rejected or not rejected.get("failures"):
        return None
    attempt_id = ctx["attempt"]["id"]
    # A run that started before this field existed has no handledRejections list;
    # start one rather than fail every older run on resume.
    if "handledRejections" not in execute_state:
        execute_state["handledRejections"] = []
        emit(paths, "module_state_reset",
             {"summary": "execute state had no handledRejections; starting one", "missingKey": "handledRejections"},
             phase="execute", attempt_id=attempt_id)
    if attempt_id in execute_state["handledRejections"]:
        return None
    execute_state["handledRejections"].append(attempt_id)

    failures = rejected["failures"]
    if any(f["id"] == "E4" for f in failures):
        pause = _unmapped_commits_pause(store, ctx, execute_state)
        if pause is not None:
            store.save()
            return pause

    for failure in failures:
        if failure["id"] in _REVIEW_RETRY_FAILURE_IDS:
            for task_id in _rejection_task_ids(failure["message"], execute_state):
                task_state = execute_state["tasks"][task_id]
                task_state["review"] = None
                # A re-issued review counts against the same retry limit as a
                # re-implementation; without it a host that never attests a
                # review re-issued it forever (LF-35).
                _retry_or_block(execute_state, task_id, task_state, failure["message"], retry_status="probing")
        elif failure["id"] == _IMPLEMENT_RETRY_FAILURE_ID:
            for task_id in _rejection_task_ids(failure["message"], execute_state):
                task_state = execute_state["tasks"][task_id]
                task_state["status"] = "pending"
                task_state["reason"] = failure["message"]
    store.save()
    return None


# --- remediation (LF-51: a VERIFY "implementation gap" rewind) -------------

def _retire_worktree(store, paths, repo_path: Path, worktree, *, last_step: str | None) -> bool:
    """Remove an old task worktree only when it is clean AND its writers are
    known terminated; otherwise keep it and quarantine it so terminal cleanup
    (controller._protected_worktree_paths) protects it. Returns whether it was
    actually removed."""
    if worktree is None or not Path(worktree).exists():
        return False
    try:
        dirty = not repo_module.is_clean(worktree)
    except LoopSpecError:
        dirty = True
    known = steps_module.writers_known_terminated(store, paths, worktree)
    if not dirty and known:
        repo_module.remove_worktree(repo_path, Path(worktree), force=False)
        return True
    store.state["steps"]["quarantined"].append({
        "stepAttemptId": last_step, "path": str(worktree),
        "reason": "uncommitted changes" if dirty else "writer termination unknown",
        "at": now_iso(),
    })
    return False


def _refork(store, paths, task_id: str, task_state: dict, plan_task: dict, feature_head: str, reason: str) -> None:
    """Fork task_id's implementation fresh from feature_head: a new generation's
    branch and worktree, independent of whatever it had before. The old branch is
    never deleted; the old worktree is retired (removed if safe, else quarantined)
    through _retire_worktree."""
    last_step = (task_state["reviewSteps"] or task_state["implementSteps"] or [None])[-1]
    repo_path = Path(store.state["repos"][task_state["repo"]]["path"])
    _retire_worktree(store, paths, repo_path, task_state["worktree"], last_step=last_step)

    slug = store.state["run"]["slug"]
    generation = task_state.get("generation", 0) + 1
    while True:
        branch = f"task/{slug}/{task_id}-r{generation}"
        worktree = paths.worktrees_dir / f"{task_id}-r{generation}"
        if repo_module.branch_sha(repo_path, branch) is None and not worktree.exists():
            break
        generation += 1
    task_state["generation"] = generation

    repo_module.create_feature_branch(repo_path, branch, feature_head)
    repo_module.add_worktree(repo_path, worktree, branch=branch)
    task_state["worktree"] = str(worktree)
    task_state["branch"] = branch
    task_state["forkedFrom"] = feature_head
    task_state["baseLayers"] = probes_module.indirection_scan(worktree, plan_task["files"])["layers"]
    task_state["probes"] = None
    task_state["review"] = None
    task_state["evidence"] = None
    task_state["reason"] = reason
    task_state["status"] = "pending"
    # A task with no integrated history yet (never merged, or this is its first
    # fork) resets BOTH anchors to the new head; one that already owns integrated
    # commits keeps reviewFrom so its next review still covers them.
    if task_state.get("reviewFrom") is None or not task_state["commits"]:
        task_state["reviewFrom"] = feature_head
    store.state.get("executeRuns", {}).pop(task_id, None)
    store.save()


def _handle_rewind(store, paths, ctx, execute_state: dict) -> None:
    """LF-51: a VERIFY `implementation gap` re-opens the plan task(s) owning each
    failed criterion against the current feature head. No-op unless the entry
    payload actually carries such a rewind, and deduplicated by VERIFY attempt id
    (handledRewinds) so a later step() call in the same remediation round does not
    re-open an already-reopened task."""
    rewind = ((ctx.get("entry") or {}).get("payload") or {}).get("rewind")
    if not rewind or rewind.get("from") != "verify" or rewind.get("exit") != "implementation gap":
        return
    attempt_id = ctx["attempt"]["id"]
    # A run that started before this field existed has no handledRewinds list;
    # start one rather than fail every older run on resume (same pattern as
    # _handle_rejection's own handledRejections backfill above).
    if "handledRewinds" not in execute_state:
        execute_state["handledRewinds"] = []
        emit(paths, "module_state_reset",
             {"summary": "execute state had no handledRewinds; starting one", "missingKey": "handledRewinds"},
             phase="execute", attempt_id=attempt_id)
    if rewind["attemptId"] in execute_state["handledRewinds"]:
        return

    if rewind.get("revisions") != store.state["revisions"]:
        # Requirements or plan moved since this VERIFY attempt issued the rewind;
        # acting on it now would reopen tasks against a gap that may no longer
        # even apply. Never marked handled, so a later attempt with fresh (or the
        # same, still-stale) payload gets evaluated again rather than silently lost.
        emit(paths, "rewind_ignored", {
            "summary": f"VERIFY rewind {rewind['attemptId']} is stale; revisions moved since it was issued",
            "payloadRevisions": rewind.get("revisions"), "currentRevisions": store.state["revisions"],
        }, phase="execute", attempt_id=attempt_id)
        return
    execute_state["handledRewinds"].append(rewind["attemptId"])

    plan_tasks = _plan_tasks(store)
    cause_by_criterion = {v["criterion"]: v.get("cause") for v in rewind.get("verdicts", [])}
    reopened: set[str] = set()  # one re-open per task per rewind, however many criteria it owns

    for rem in rewind["remediationTasks"]:
        owners = [tid for tid, t in plan_tasks.items()
                  if t["repo"] == rem.get("repo") and set(t["criteria"]) & set(rem["criteria"])]
        prefer = [tid for tid in owners if set(plan_tasks[tid]["files"]) & set(rem.get("files") or [])]
        owners = prefer or owners
        if not owners:
            raise LoopSpecError(
                f"VERIFY remediation {rem.get('id')} for {', '.join(rem['criteria'])} in repo {rem.get('repo')!r} maps to no plan task",
                repair="a remediation names a repo from this run's repos and criteria a plan task in that repo covers; fix the VERIFY product or the plan",
            )

        for tid in owners:
            task_state = execute_state["tasks"][tid]
            task_state.setdefault("remediations", []).append({
                "verifyAttempt": rewind["attemptId"], "criteria": rem["criteria"],
                "priorStatus": task_state["status"], "priorRetries": task_state["retries"],
                "priorBranch": task_state["branch"], "priorWorktree": task_state["worktree"],
                "priorReview": task_state["review"], "at": now_iso(),
            })
            for issue in [i for i in execute_state["issues"] if i["task"] == tid]:
                execute_state["issues"].remove(issue)
                execute_state.setdefault("issueHistory", []).append(issue)
            store.state.get("executeRuns", {}).pop(tid, None)
            task_state["retries"] = 0

            cause = next((cause_by_criterion[c] for c in rem["criteria"] if cause_by_criterion.get(c)), "no cause recorded")
            files_text = ", ".join(rem.get("files") or []) or "(none named)"
            feature_head = execute_state["repos"][task_state["repo"]]["head"]
            reason = (f"VERIFY found {', '.join(rem['criteria'])} failing at {feature_head[:12]}: {cause}. "
                      f"Remediation {rem.get('id')}: {rem.get('title')}; files: {files_text}; "
                      f"VERIFY ran: {rem.get('verify') or '(no command)'}")
            if tid in reopened:
                task_state["reason"] = f"{task_state['reason']}\n{reason}"
                continue
            reopened.add(tid)

            repo_path = Path(store.state["repos"][task_state["repo"]]["path"])
            task_head = repo_module.branch_sha(repo_path, task_state["branch"]) if task_state["branch"] else None
            reused = bool(
                task_state["worktree"] and Path(task_state["worktree"]).exists() and task_head
                and repo_module.is_clean(task_state["worktree"])
                and steps_module.writers_known_terminated(store, paths, task_state["worktree"])
                and repo_module.is_ancestor(Path(task_state["worktree"]), feature_head, task_head)
            )
            if reused:
                task_state["review"] = None
                task_state["probes"] = None
                task_state["evidence"] = None
                task_state["status"] = "pending"
                task_state["reason"] = reason
            else:
                _refork(store, paths, tid, task_state, plan_tasks[tid], feature_head, reason)

            emit(paths, "task_reopened", {
                "task": tid, "reused": reused,
                "summary": f"{tid} reopened by VERIFY remediation {rem.get('id')} ({'reused' if reused else 're-forked'})",
            }, phase="execute", attempt_id=attempt_id)

    store.save()


# --- the phase product -------------------------------------------------

def _final_product(store, ctx, execute_state: dict) -> dict:
    tasks_out = []
    any_done = False
    for task_id, task_state in execute_state["tasks"].items():
        if task_state["status"] == "done":
            any_done = True
            tasks_out.append({
                "id": task_id, "disposition": "done", "evidence": task_state["evidence"],
                "commits": task_state["commits"], "review": task_state["review"],
            })
        elif task_state["status"] == "already-satisfied":
            tasks_out.append({
                "id": task_id, "disposition": "already-satisfied",
                "evidence": task_state["evidence"], "commits": [], "review": None,
            })
        elif task_state["status"] == "adopted":
            # LF-38: delivered by the adopted PR, not this run -- counts as done
            # for the exit decision so a run whose only new work is a remediation
            # task still exits `integrated`, not `no change`.
            any_done = True
            # LF-42: the adopted-range review is this task's review; E5 reads it
            # off the task like any other. Projected to the product's review shape
            # (the reviewer's result also carries `sha`, which the product schema
            # refuses -- LF-43).
            adopted = store.state.get("adoptedReview")
            tasks_out.append({
                "id": task_id, "disposition": "adopted", "evidence": None,
                "commits": task_state["commits"],
                "review": None if adopted is None else {
                    "reviewedRange": adopted["reviewedRange"], "verdict": adopted["verdict"],
                    "findings": adopted["findings"], "securityDispositions": adopted["securityDispositions"],
                },
            })

    if any(t["status"] == "planGap" for t in execute_state["tasks"].values()):
        exit_ = "plan gap"
    elif execute_state["issues"]:
        exit_ = "blocked"
    elif any_done:
        exit_ = "integrated"
    else:
        exit_ = "no change"

    return {
        "exit": exit_,
        "inputsDigest": ctx["inputs"]["digest"],
        "boundTo": {
            "requirements": store.state["revisions"]["requirements"],
            "plan": store.state["revisions"]["plan"],
        },
        "tasks": tasks_out,
        "issues": execute_state["issues"],
        "heads": {name: repo_state["head"] for name, repo_state in execute_state["repos"].items()},
    }


def _self_heal_commits(store, execute_state: dict) -> bool:
    """LF-17/18: a done task can carry an empty commits list -- state written
    before this fix recorded no integratedFrom/integratedTo at all, and existing
    state from the bug this fix closes has the same shape. Recompute instead of
    letting E4's own check (or a delivered product) keep reporting a mismatch
    nothing else will ever resolve. Returns whether anything changed."""
    healed = False
    for task_id, task_state in execute_state["tasks"].items():
        if task_state["status"] != "done" or task_state["commits"]:
            continue
        repo_info = store.state["repos"][task_state["repo"]]
        repo_path = Path(repo_info["path"])
        if task_state.get("integratedFrom") and task_state.get("integratedTo"):
            from_sha, to_sha = task_state["integratedFrom"], task_state["integratedTo"]
        else:
            from_sha = repo_info["baseSha"]
            to_sha = repo_module.branch_sha(repo_path, task_state["branch"])
        if to_sha is None:
            continue
        task_state["commits"] = repo_module.commits_between(repo_path, from_sha, to_sha)
        healed = True
    return healed


# --- the two entry points ---------------------------------------------

def step(store, paths, ctx):
    execute_state = store.state.get("execute")
    if execute_state is None:
        execute_state = _init(store, paths, ctx)

    if _self_heal_commits(store, execute_state):
        store.save()

    drift = _drifted_repo(store, paths, execute_state, ctx["attempt"]["id"])
    if drift is not None:
        return _drift_pause(ctx, drift)

    rejection_pause = _handle_rejection(store, paths, ctx, execute_state)
    if rejection_pause is not None:
        return rejection_pause

    _handle_rewind(store, paths, ctx, execute_state)

    if any(t["status"] in ("blocked", "planGap") for t in execute_state["tasks"].values()):
        return Product(_final_product(store, ctx, execute_state))

    plan_tasks = _plan_tasks(store)
    for wave in execute_state["waves"]:
        wave_states = [execute_state["tasks"][tid] for tid in wave]
        if all(t["status"] in _TERMINAL for t in wave_states):
            continue

        # Every pending task's worktree must exist before any request is built:
        # _implement_request flips a task to "implementing" as its last step, and
        # once two or more requests are collected below, discovering a LATER
        # task's worktree pause would strand an earlier one already flipped with
        # no step actually issued for it. Settling every worktree first (cheap
        # and idempotent -- _ensure_worktree no-ops once a task has one) means
        # the collection loop below can no longer pause partway through.
        for task_id in wave:
            task_state = execute_state["tasks"][task_id]
            if task_state["status"] == "pending":
                pause = _ensure_worktree(store, paths, ctx, task_id, task_state, plan_tasks[task_id])
                if pause is not None:
                    return pause

        requests: list[dict] = []
        open_steps: list[str] = []
        for task_id in wave:
            task_state = execute_state["tasks"][task_id]
            if task_state["status"] == "pending":
                outcome = _implement_request(store, paths, ctx, plan_tasks[task_id], task_state, task_id)
                if isinstance(outcome, Pause):
                    # Defensive: the pre-scan above already settled every worktree,
                    # so this should not fire, but a Pause still wins immediately.
                    return outcome
                requests.append(outcome)
            elif task_state["status"] == "probing":
                requests.append(_review_request(store, paths, ctx, plan_tasks[task_id], task_state))
            elif task_state["status"] in ("implementing", "reviewing"):
                open_id = _open_step_id(store, task_state)
                if open_id is not None:
                    open_steps.append(open_id)
            elif task_state["status"] not in _TERMINAL:
                raise LoopSpecError(
                    f"execute task {task_id} is in status {task_state['status']!r}, which step() does not understand",
                    repair="check execute.py's task status machine for a missing case",
                )
        if requests:
            return IssueStep(requests[0]) if len(requests) == 1 else IssueSteps(requests)
        if open_steps:
            return Wait(open_steps)
        raise LoopSpecError(
            "execute.step() was called with an outstanding submission still open",
            repair="submit the open step (on_submit) before calling step() again",
        )
    return Product(_final_product(store, ctx, execute_state))


def _on_implement_submit(store, paths, task_id: str, task_state: dict, step_record: dict, result: dict) -> None:
    task_state["implementSteps"].append(step_record["stepAttemptId"])
    execute_state = store.state["execute"]
    worktree = Path(task_state["worktree"])

    # LF-49: "already satisfied" means nothing to integrate; Git, not the summary, decides that.
    if not result["commits"] and result["summary"].startswith("already satisfied:"):
        forked_from = task_state.get("forkedFrom")
        task_head = repo_module.branch_sha(worktree, task_state["branch"])
        if forked_from is not None and task_head == forked_from and repo_module.is_clean(worktree):
            task_state["status"] = "already-satisfied"
            task_state["evidence"] = result["summary"]
            task_state["reason"] = None
            return
        if task_head is not None and task_head != forked_from:
            emit(paths, "already_satisfied_contradicted",
                 {"task": task_id, "forkedFrom": forked_from, "taskHead": task_head,
                  "summary": f"{task_id} claimed already satisfied but "
                             + ("its fork is unrecorded" if forked_from is None else "its branch moved past its fork")
                             + "; taking the commit path"},
                 phase="execute", attempt_id=step_record.get("attempt"))

    if not repo_module.is_clean(worktree):
        _retry_or_block(execute_state, task_id, task_state, "the worktree has uncommitted changes after the implement step")
        return

    feature_head = execute_state["repos"][task_state["repo"]]["head"]
    task_head = repo_module.branch_sha(worktree, task_state["branch"])
    if task_head is None or task_head == feature_head:
        _retry_or_block(execute_state, task_id, task_state, "no commit was made on the task branch")
        return

    task_state["probes"] = probes_module.diff_probes(worktree, feature_head, task_head, task_state["baseLayers"])
    task_state["reason"] = None
    task_state["status"] = "probing"


def _on_review_submit(store, paths, task_id: str, task_state: dict, step_record: dict, result: dict) -> None:
    task_state["reviewSteps"].append(step_record["stepAttemptId"])
    execute_state = store.state["execute"]
    worktree = Path(task_state["worktree"])
    # The reviewed range is base..task from the head this task's own worktree
    # FORKED from, matching what _review_request actually showed the reviewer
    # -- never the feature branch's current head, which a same-wave sibling can
    # have already moved by merging first.
    fork = _fork_point(paths, execute_state, task_state, task_id, step_record.get("attempt"))
    task_head = repo_module.branch_sha(worktree, task_state["branch"])
    task_state["review"] = {
        "reviewedRange": {"from": _review_from(task_state), "to": task_head},
        "verdict": result["verdict"], "findings": result["findings"],
        "securityDispositions": result["securityDispositions"],
    }

    if result["verdict"] != "pass":
        open_findings = [f for f in result["findings"] if f["disposition"] not in ("rejected", "deferred")]
        causes = "; ".join(f'{f["location"]}: {f["cause"]}' for f in open_findings) or "review failed with no open finding"
        _retry_or_block(execute_state, task_id, task_state, f"the reviewer found: {causes}")
        return

    plan_task = _plan_tasks(store)[task_id]
    # R3: this task's own repo has its own baseline; a workspace's other repos
    # never stand in for it.
    repo_baseline_dict = baseline_module.repo_baseline_dict(store.state.get("baseline"), plan_task["repo"], store.state["repos"])
    baseline_entry = baseline_module.BaselineEntry.from_dict(repo_baseline_dict["entries"][plan_task["verify"]])
    candidate = baseline_module.run_command(plan_task["verify"], worktree, task_head)
    comparison = baseline_module.compare_to_baseline(
        baseline_entry, candidate,
        feature_added=bool(plan_task["featureAdded"]), must_flip=bool(plan_task["mustFlip"]),
    )
    store.state.setdefault("executeRuns", {})[task_id] = {"run": candidate.to_dict(), "comparison": comparison.to_dict()}

    if comparison.verdict not in ("no-regression", "featureAdded-ok", "mustFlip-ok"):
        _route_verify_comparison(execute_state, task_id, task_state, comparison)
        return

    feature_worktree = Path(execute_state["repos"][task_state["repo"]]["worktree"])
    feature_head = execute_state["repos"][task_state["repo"]]["head"]
    if repo_module.is_ancestor(feature_worktree, feature_head, task_head):
        # The common case: nothing else has merged into this repo's feature
        # branch since this task forked (or a re-review of an already-
        # integrated task, feature_head == task_head -- LF-17), so the linear
        # history every other check assumes stays exactly that.
        repo_module.run_git(feature_worktree, "merge", "--ff-only", task_head)
    else:
        # A same-wave sibling merged first and moved the feature head past
        # where this task forked; a real merge commit is the only way to bring
        # a divergent branch in without rewriting either side's already-
        # reviewed commits.
        try:
            repo_module.run_git(feature_worktree, "merge", "--no-ff", "--no-edit",
                                 "-m", f"loop-spec: integrate {task_id}", task_head)
        except LoopSpecError:
            repo_module.run_git(feature_worktree, "merge", "--abort")
            # The task's own commits conflict with a sibling's on the new head:
            # nothing here can resolve that but a fresh implementation against
            # it. Re-fork (4.5/4.6): the old worktree/branch are retired through
            # the same helper a VERIFY remediation uses, never force-deleted
            # outright, and a retry is spent the same way any other
            # implement-again route does. `commits` is untouched -- it only
            # ever holds INTEGRATED commits, so this failed attempt's
            # attribution was never recorded onto it in the first place.
            new_head = execute_state["repos"][task_state["repo"]]["head"]
            plan_task = _plan_tasks(store)[task_id]
            reason = f"{task_id} conflicts with the feature head after a sibling merged; re-implement on {new_head[:12]}"
            _refork(store, paths, task_id, task_state, plan_task, new_head, reason)
            _retry_or_block(execute_state, task_id, task_state, reason)
            return
    new_commits = repo_module.commits_between(feature_worktree, fork, task_head)
    if new_commits:
        # LF-17: a re-review of an already-integrated task (an E5/E6/E11 remediation
        # retry -- feature_head == task_head, nothing new to merge) must not wipe the
        # commits its FIRST integration recorded; only a genuine new merge updates them.
        # LF-51: a remediated task can already own commits from BEFORE its re-fork
        # (4.6) -- union them (de-duplicated, order-preserving) instead of
        # replacing, so an earlier accepted integration is never disowned.
        task_state["commits"] = list(dict.fromkeys(task_state["commits"] + new_commits))
        task_state["integratedFrom"], task_state["integratedTo"] = fork, task_head
    # HEAD, not task_head: a --no-ff merge just above leaves the feature branch
    # at a NEW merge commit task_head never names.
    execute_state["repos"][task_state["repo"]]["head"] = repo_module.branch_sha(feature_worktree, "HEAD")
    task_state["status"] = "done"
    task_state["reason"] = None


def on_submit(store, paths, step, result: dict) -> None:
    # `paths` is part of the required on_submit interface (symmetry with step());
    # this implementation has no need for it yet. `step` is the registered step
    # record (has cwd/role/stepAttemptId), not this module's own step() function.
    execute_state = store.state["execute"]
    if _drifted_repo(store, paths, execute_state, step.get("attempt")) is not None:
        # LF-15: a repo drifted underneath this submission. Folding it into task
        # state would trust a possibly-compromised worktree; leave the task
        # exactly where it was and let the next step() call raise the pause
        # instead (never reset the drift out from under the operator here).
        return
    found = next(((tid, t) for tid, t in execute_state["tasks"].items() if t["worktree"] == step["cwd"]), None)
    if found is None:
        raise LoopSpecError(f"execute has no task with worktree {step['cwd']}", repair="check the submitted step's cwd")
    task_id, task_state = found

    if step["role"] == "implementer":
        _on_implement_submit(store, paths, task_id, task_state, step, result)
    elif step["role"] == "code-reviewer":
        _on_review_submit(store, paths, task_id, task_state, step, result)
    else:
        raise LoopSpecError(f"execute got a submission for an unknown role {step['role']!r}",
                             repair="check the submitted step's role field")
    store.save()
