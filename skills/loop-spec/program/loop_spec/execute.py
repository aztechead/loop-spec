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
import copy
import dataclasses
import os
import re
from pathlib import Path

from loop_spec import baseline as baseline_module
from loop_spec import probes as probes_module
from loop_spec import repo as repo_module
from loop_spec import steps as steps_module
from loop_spec.budget import has_room
from loop_spec.contract import resolve_role, validate_request
from loop_spec.errors import LoopSpecError
from loop_spec.events import emit
from loop_spec.ids import new_id, now_iso
from loop_spec.jsonio import read_json
from loop_spec.paths import ensure_results_dir
from loop_spec.postconditions import adopted_commits, close_out_view, close_outs, retry_limit
from loop_spec.roles import compose_prompt, load_role, resolve_model

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
# LF-66: "stop" is first and the default, so a headless answerer (the default policy,
# or one that takes the first option) ends the run instead of improvising a fix.
_BLOCKED_OPTIONS = [
    {"value": "stop", "label": "Stop"},
    {"value": "fix-and-re-enter", "label": "Fix and re-enter"},
]
_TASK_ID_RE = re.compile(r"[TRC]-\d+")  # plan T-n/R-n, close-out C-n (LF-55)
# LF-11: a verify re-run that could never have passed no matter what the implementer
# does is a defect in PLAN's own verify/featureAdded/mustFlip fields, not something a
# retry fixes. "reproduction still fails at the candidate commit" (the OTHER
# mustFlip-failed detail) stays on the retry path below -- that one means the
# implementer's fix did not land yet, which a retry can still address.
_MUST_FLIP_BASELINE_DETAIL = "reproduction did not fail at base"
# LF-52/4.8: a plan task's identity for reconciliation -- the same eight fields
# _mark_adopted_tasks already compares to decide whether a reviser's carried-
# forward task is still the same task.
_PLAN_IDENTITY_FIELDS = ("title", "files", "repo", "verify", "criteria", "dependsOn", "featureAdded", "mustFlip")


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


def _task_spec(store, task_id: str) -> dict:
    """A plan task, or for an LF-55 close-out a stand-in with the plan task's fields:
    its text as the title, the files its commits changed, and no verify command."""
    plan_task = _plan_tasks(store).get(task_id)
    if plan_task is not None:
        return plan_task
    entry = close_outs(store)[task_id]
    task_state = (store.state.get("execute") or {}).get("tasks", {}).get(task_id) or {}
    return {"id": task_id, "repo": entry["repo"], "title": entry["text"], "files": task_state.get("files") or [],
            "criteria": [], "dependsOn": [], "verify": None, "featureAdded": None, "mustFlip": False}


def _schedule_close_outs(store, execute_state: dict) -> bool:
    """LF-55: each registered close-out gets a task state and its own trailing wave,
    once, in registry order. Execute state is never reset, so a closed close-out
    keeps the state it closed with. Returns whether anything was added."""
    added = False
    for cid in close_outs(store):
        if cid in execute_state["tasks"]:
            continue
        task_state = _fresh_task_state(_task_spec(store, cid))
        task_state.update({"closeOut": cid, "plan": None, "files": []})
        execute_state["tasks"][cid] = task_state
        execute_state["waves"].append([cid])
        added = True
    return added


def _refresh_stale_close_outs(store, paths, execute_state: dict) -> bool:
    """LF-55: a no-change close-out's proof holds only at the head it reviewed. When a
    later commit moved that head, re-review the empty range at the new head (a fresh
    fork and step; the registry keeps the old closure until a product is accepted)."""
    refreshed = False
    for tid, task_state in execute_state["tasks"].items():
        if not task_state.get("closeOut") or task_state["status"] != "already-satisfied":
            continue
        head = execute_state["repos"][task_state["repo"]]["head"]
        if ((task_state.get("review") or {}).get("reviewedRange") or {}).get("to") == head:
            continue
        evidence = task_state["evidence"]
        _refork(store, paths, tid, task_state, _task_spec(store, tid), head,
                f"the head moved to {head[:12]} after {tid}'s no-change review; review it again there")
        task_state.update({"evidence": evidence, "noChange": True, "status": "probing"})
        refreshed = True
    return refreshed


def _retry_or_block(execute_state: dict, task_id: str, task_state: dict, reason_text: str, *, retry_status: str = "pending") -> None:
    task_state["retries"] += 1
    if task_state["retries"] > retry_limit():
        task_state["status"] = "blocked"
        task_state["reason"] = None
        execute_state["issues"].append({"task": task_id, "text": reason_text})
    else:
        task_state["status"] = retry_status
        task_state["reason"] = reason_text


def repo_checks(store, repo_name: str) -> list[str]:
    plan = store.state["products"]["plan"]["product"]
    return [c["command"] for c in plan.get("checks") or [] if c["repo"] == repo_name]


def _check_regressed(store, execute_state: dict, task_id: str, task_state: dict, cwd: Path, head: str) -> bool:
    commands = repo_checks(store, task_state["repo"])
    if not commands:
        return False
    repo_baseline = baseline_module.repo_baseline_dict(store.state.get("baseline"), task_state["repo"], store.state["repos"]) or {}
    runs = store.state.setdefault("executeCheckRuns", {}).setdefault(task_id, {})
    for command in commands:
        entry = (repo_baseline.get("entries") or {}).get(command)
        if entry is None:
            continue  # P3 guarantees one; a baseline recaptured without it is VERIFY's to catch
        run = baseline_module.run_command(command, cwd, head)
        comparison = baseline_module.compare_to_baseline(baseline_module.BaselineEntry.from_dict(entry), run)
        runs[command] = {"head": head, "run": run.to_dict(), "comparison": comparison.to_dict()}
        if comparison.verdict != "no-regression":
            _route_verify_comparison(execute_state, task_id, task_state, comparison, run, label="repo check")
            return True
    return False


_JS_TEST_FILE = re.compile(r"\.(?:test|spec)\.[cm]?[jt]sx?$")


def _failing_test_provenance(store, verify_attempt: str, criteria: list[str], repo_name: str, head: str) -> dict | None:
    """7.1.0: the program's own observation of a failing criterion (never the
    verifier's claim), matched to this rewind and head, against where it last passed."""
    for criterion in criteria:
        observation = (store.state.get("failureObservations") or {}).get(criterion)
        passed = (store.state.get("criterionPasses") or {}).get(criterion)
        if not observation or not passed or observation["attemptId"] != verify_attempt or \
                observation["sha"] != head or observation["repo"] != repo_name:
            continue
        if observation["runner"] == "pytest":
            failing = {i.split("::", 1)[0] for i in observation["failureIdentities"]}
        elif observation["runner"] in ("vitest", "jest"):
            failing = {i.split(" > ", 1)[0] for i in observation["failureIdentities"]
                       if _JS_TEST_FILE.search(i.split(" > ", 1)[0])}
        else:
            continue  # go and cargo identities name packages and symbols, not files
        added = set(repo_module.files_added_by(Path(store.state["repos"][repo_name]["path"]), passed["sha"], head))
        files = sorted(failing & added)
        if files:
            return {"criterion": criterion, "files": files, "passSha": passed["sha"], "head": head}
    return None


def _route_verify_comparison(execute_state: dict, task_id: str, task_state: dict, comparison, run,
                              label: str = "verify") -> None:
    """`baseline-error` and a `mustFlip-failed` baseline that never failed are PLAN's
    own mistake (see `_MUST_FLIP_BASELINE_DETAIL` above): route straight to plan gap,
    spending none of the task's retry budget on an outcome no retry can change. Every
    other failing verdict (`regression`, `featureAdded-failed`, a `mustFlip-failed`
    whose reproduction still fails at the candidate) is still the implementer's to fix
    and keeps the retry-then-block path."""
    reason_text = "\n".join([f"the {label} re-run of `{run.command}` is {comparison.verdict}: {comparison.detail}",
                              *baseline_module.describe_failure(comparison, run)])
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
    for plan_task in plan_tasks:
        prior_task = prior_tasks.get(plan_task["id"])
        if prior_task is None or any(plan_task.get(f) != prior_task.get(f) for f in _PLAN_IDENTITY_FIELDS):
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


def _execute_width() -> int:
    return int(os.environ.get("LOOP_SPEC_EXECUTE_WIDTH", "3"))


def _plan_snapshot(plan_task: dict) -> dict:
    """The identity tuple a task's state is reconciled against on every PLAN
    re-entry (4.8) -- deep-copied so a later in-place edit to the live plan
    product (there is none today, but nothing here should rely on that) can
    never retroactively change a snapshot already taken."""
    return copy.deepcopy({f: plan_task.get(f) for f in _PLAN_IDENTITY_FIELDS})


def _fresh_task_state(plan_task: dict) -> dict:
    return {
        "status": "pending", "repo": plan_task["repo"], "worktree": None, "branch": None,
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
        # LF-52/4.8: this task's identity as PLAN currently states it, compared
        # on every re-entry to decide whether its recorded work still applies.
        "plan": _plan_snapshot(plan_task),
    }


def _init(store, paths, ctx) -> dict:
    plan_tasks = store.state["products"]["plan"]["product"]["tasks"]
    waves = dag_waves(plan_tasks, width=_execute_width())

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

    tasks = {t["id"]: _fresh_task_state(t) for t in plan_tasks}
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
    # LF-52/4.8: a task reset under a new generation (a reconciled plan change
    # with no integrated commits) carries that generation forward, and a task
    # whose plain worktree path is still sitting there (quarantined, or just not
    # yet cleaned up) must never be raced -- either one forks a fresh generation
    # exactly as a remediation re-fork would, instead of pausing on a plain-named
    # branch/worktree this run itself already used once.
    if task_state.get("generation", 0) > 0 or (paths.worktrees_dir / task_id).exists():
        _refork(store, paths, task_id, task_state, plan_task, repo_state["head"], task_state.get("reason") or "fresh attempt")
        return None
    # LF-14: task/<task-id> alone collided with the same task id from an earlier
    # run of this repo. Slug-scoping still is not enough on its own -- a LEFTOVER
    # branch from a PRIOR run of this exact slug is the same out-of-band condition
    # the feature branch check already pauses for; only an empty one (no commits
    # past the feature head this task is about to fork from) is safe to reuse.
    branch = f"task/{store.state['run']['slug']}/{task_id}"
    existing = repo_module.branch_sha(repo_path, branch)
    if existing is not None and existing != repo_state["head"]:
        text = (f"task branch {branch!r} already exists with commits not in the feature "
                f"head (expected {repo_state['head']}, found {existing}); delete it, then fix-and-re-enter, or stop")
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
        "checks": repo_checks(store, task_state["repo"]),
    }
    if task_state.get("closeOut"):
        inputs["closeOut"] = close_out_view(close_outs(store)[task_id])
    existing = [e for e in store.state["products"]["plan"]["product"].get("existingCode") or [] if task_id in e["tasks"]]
    if existing:
        inputs["existingCode"] = existing  # 7.2.0: the code PLAN decided this task reuses or extends
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
    # LF-60: after a refused review the old worktree is quarantined (its worker may
    # still run); the re-issued review reads a fresh checkout of the same candidate.
    review_cwd = Path(task_state.get("reviewCheckout") or worktree)
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

    diff = repo_module.review_diff(worktree, f"{review_from}..{task_head}")
    if len(diff) > _DIFF_CAP:
        diff = diff[:_DIFF_CAP] + "\n...(truncated)"

    inputs = {
        "task": plan_task,
        "range": {"from": review_from, "to": task_head},
        "diff": diff,
        "probes": task_state["probes"],
        "ledger": store.state.get("ledger", {}),
    }
    if task_state.get("closeOut"):
        # E6 finds this exact input in the attested prompt: the review is for this obligation.
        inputs["closeOut"] = close_out_view(close_outs(store)[plan_task["id"]])
        inputs["obligation"] = (
            "This task closes out an ITERATE gap (closeOut.text). Pass only if that gap is closed at "
            "range.to. An empty range means the implementer found it already true there; check that claim."
        )
    prompt = compose_prompt(role, inputs=inputs, result_path=result_path, cwd=review_cwd, phase="execute")

    request = {
        "kind": "role", "role": "code-reviewer", "phase": "execute", "cwd": str(review_cwd),
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
    # LF-60: the review is bound to this candidate at issue; the submit applies it
    # to this SHA only, never to whatever the mutable task branch points at later.
    task_state["reviewCandidate"] = task_head
    task_state["status"] = "reviewing"
    store.save()
    return request


def _wave_schema(schema: dict, count: int) -> dict:
    """One code-reviewer result per task, each naming its task; the role's $defs move
    to the root, where schema.validate resolves every $ref."""
    item = {k: copy.deepcopy(v) for k, v in schema.items() if k != "$defs"}
    item["properties"] = {"task": {"type": "string"}, **item["properties"]}
    item["required"] = ["task", *item["required"]]
    return {"type": "object", "required": ["tasks"], "additionalProperties": False,
            "$defs": copy.deepcopy(schema.get("$defs") or {}),
            "properties": {"tasks": {"type": "array", "minItems": count, "maxItems": count, "items": item}}}


def _wave_review_request(store, paths, ctx, task_ids: list[str]) -> dict:
    """One review step for several tasks of one wave, once none of them is still
    implementing (6.10's per-wave review): one reviewer context instead of one per
    task. Each task is judged on its own and gets its own result entry, which
    on_submit applies exactly as a single-task review; rework stays per task."""
    project_root = Path(ctx["paths"]["projectRoot"])
    role = load_role("code-reviewer", project_root, resolve_role(project_root, "code-reviewer"))
    execute_state = store.state["execute"]
    ensure_results_dir(paths)
    result_path = paths.results_dir / f"wave-{'_'.join(task_ids)}-review-{new_id('step').split('-', 1)[1]}.json"
    entries, first_cwd = [], None
    for task_id in task_ids:
        task_state = execute_state["tasks"][task_id]
        plan_task = _task_spec(store, task_id)
        worktree = Path(task_state["worktree"])
        review_cwd = Path(task_state.get("reviewCheckout") or worktree)
        first_cwd = first_cwd or review_cwd
        _fork_point(paths, execute_state, task_state, task_id, ctx["attempt"]["id"])
        review_from = _review_from(task_state)
        task_head = repo_module.branch_sha(worktree, task_state["branch"])
        diff = repo_module.review_diff(worktree, f"{review_from}..{task_head}")
        if len(diff) > _DIFF_CAP:
            diff = diff[:_DIFF_CAP] + "\n...(truncated)"
        entry = {"task": plan_task, "cwd": str(review_cwd), "range": {"from": review_from, "to": task_head},
                 "diff": diff, "probes": task_state["probes"]}
        if task_state.get("reason"):
            entry["reason"] = task_state["reason"]
        entries.append(entry)
        task_state.update({"reviewCandidate": task_head, "status": "reviewing", "waveReview": str(result_path)})
    inputs = {
        "tasks": entries,
        "ledger": store.state.get("ledger", {}),
        "wave": (f"This step reviews {len(task_ids)} tasks of one wave together. Review each task on its own: "
                 "its range, diff and files, read in its own `cwd`, judged on its own criteria; one task's "
                 "verdict never decides another's. Write one result per task in `tasks`, each naming its "
                 "`task` id, in the shape the Method describes for a single review."),
    }
    wave_role = dataclasses.replace(role, schema=_wave_schema(role.schema, len(task_ids)))
    prompt = compose_prompt(wave_role, inputs=inputs, result_path=result_path, cwd=first_cwd, phase="execute")
    request = {
        "kind": "role", "role": "code-reviewer", "phase": "execute", "cwd": str(first_cwd),
        "prompt": prompt, "resultPath": str(result_path), "schema": wave_role.schema, "postconditions": [],
        "attempt": ctx["attempt"]["id"], "inputsDigest": ctx["inputs"]["digest"],
        "retryOf": None, "reason": None, "model": resolve_model(project_root, "code-reviewer"),
    }
    errors = validate_request("step", request)
    if errors:
        raise LoopSpecError("execute built an invalid wave review step request: " + "; ".join(errors),
                             repair="fix _wave_review_request in execute.py")
    store.save()
    return request


def _pause_request(ctx, repo_name: str, expected: str, actual: str, *, text: str | None = None) -> dict:
    request = {
        "attempt": ctx["attempt"]["id"], "phase": "execute",
        "text": text or (f"repo {repo_name}'s feature branch moved out of band "
                          f"(expected {expected}, found {actual}); reset it to {expected} (or move the "
                          f"commits into a task worktree), then fix-and-re-enter, or stop"),
        "options": _BLOCKED_OPTIONS,
        "defaultValue": "stop", "kind": "blocked",
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
        "options": _BLOCKED_OPTIONS, "defaultValue": "stop", "kind": "blocked", "payload": payload,
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
    cwds = {task_state["worktree"], task_state.get("reviewCheckout")}
    wave = task_state.get("waveReview")  # a shared wave review runs in its first task's cwd
    return next((s["stepAttemptId"] for s in store.state["steps"]["open"]
                 if (wave and s.get("resultPath") == wave) or (not wave and s["cwd"] in cwds)), None)


def _rejection_task_ids(message: str, execute_state: dict) -> list[str]:
    """The task ids a rejection's message names ("T-n" tokens); with none, every
    currently-done task. E6's own message already lists every id it means (it
    aggregates), so this only widens scope for a message that names none."""
    def _reviewed(t: dict) -> bool:  # a no-change close-out's review is its proof too (LF-55)
        return t.get("status") == "done" or (bool(t.get("closeOut")) and t.get("status") == "already-satisfied")
    parsed = [tid for tid in _TASK_ID_RE.findall(message) if _reviewed(execute_state["tasks"].get(tid, {}))]
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


def _reopen(store, paths, tid: str, task_state: dict, plan_task: dict, reason: str) -> bool:
    """Reuse task_id's existing branch/worktree if it is still safe to build on
    top of (clean, its writers known terminated, and an ancestor of the current
    feature head -- 4.5), otherwise re-fork a fresh generation from the current
    feature head (4.5/4.6). Shared by a VERIFY remediation (_handle_rewind) and a
    PLAN reconciliation (_reconcile_plan) re-opening a task that owns integrated
    commits. Returns whether the existing branch/worktree was reused."""
    execute_state = store.state["execute"]
    feature_head = execute_state["repos"][task_state["repo"]]["head"]
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
        _refork(store, paths, tid, task_state, plan_task, feature_head, reason)
    return reused


def _rerun_lines(store, criteria: list[str], feature_head: str) -> str:
    """7.2.0: what the program's own VERIFY re-run of a failing criterion printed (its
    failure ids, else its last lines), at this head; the verifier's cause is a claim."""
    for criterion in criteria:
        entry = (store.state.get("verifyRuns") or {}).get(criterion)
        if not entry or entry["rerun"].get("sha") != feature_head:
            continue
        run = baseline_module.CommandRun.from_dict(entry["rerun"])
        if run.exit_status == 0:
            continue
        lines = baseline_module.describe_failure(baseline_module.Comparison("regression", run.failure_identities, ""), run)
        return "\nThe program's re-run of " + criterion + " printed:\n" + "\n".join(lines)
    return ""


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
    # Only a failing verdict makes a criterion "failing"; a remediation whose criteria all
    # passed (an open Critical finding, LF-64, or a regressed repo check, 7.1.0) says so.
    cause_by_criterion = {v["criterion"]: v.get("cause") for v in rewind.get("verdicts", []) if v.get("verdict") == "fail"}
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

            cause = next((cause_by_criterion[c] for c in rem["criteria"] if cause_by_criterion.get(c)), None)
            files_text = ", ".join(rem.get("files") or []) or "(none named)"
            feature_head = execute_state["repos"][task_state["repo"]]["head"]
            if cause is None and not any(c in cause_by_criterion for c in rem["criteria"]):
                # No criterion failed: an open Critical finding (LF-64) or a regressed repo check.
                reason = f"VERIFY remediation {rem.get('id')}: {rem.get('title')} at {feature_head[:12]}; files: {files_text}"
            else:
                reason = (f"VERIFY found {', '.join(rem['criteria'])} failing at {feature_head[:12]}: {cause or 'no cause recorded'}. "
                          f"Remediation {rem.get('id')}: {rem.get('title')}; files: {files_text}; "
                          f"VERIFY ran: {rem.get('verify') or '(no command)'}")
                reason += _rerun_lines(store, rem["criteria"], feature_head)
                provenance = _failing_test_provenance(store, rewind["attemptId"], rem["criteria"], task_state["repo"], feature_head)
                if provenance is not None:
                    task_state["provenance"] = provenance
                    reason += (f"\nFact: {', '.join(provenance['files'])} were added after {provenance['criterion']} last "
                               f"passed at {provenance['passSha'][:12]} and now fail. Decide whether that test or the "
                               "implementation contradicts the approved criteria; change the test only where it "
                               "contradicts an approved criterion, never weaken an assertion a criterion requires, "
                               "and say in your result which you changed.")
                    emit(paths, "failing_test_added_after_pass", {"task": tid, **provenance,
                         "summary": f"{tid}: {', '.join(provenance['files'])} added after {provenance['criterion']} passed"},
                         phase="execute", attempt_id=attempt_id)
            if tid in reopened:
                task_state["reason"] = f"{task_state['reason']}\n{reason}"
                continue
            reopened.add(tid)

            reused = _reopen(store, paths, tid, task_state, plan_tasks[tid], reason)

            emit(paths, "task_reopened", {
                "task": tid, "reused": reused,
                "summary": f"{tid} reopened by VERIFY remediation {rem.get('id')} ({'reused' if reused else 're-forked'})",
            }, phase="execute", attempt_id=attempt_id)

    store.save()


# --- plan reconciliation (LF-52/4.8: a changed plan re-entry) --------------

def _reconcile_plan(store, paths, ctx, execute_state: dict) -> None:
    """A PLAN re-entry after EXECUTE already has state must not silently keep
    running the old task states against a changed plan. Reconciles by task
    identity (_PLAN_IDENTITY_FIELDS, the same one _mark_adopted_tasks uses):
    an unchanged task keeps its state; a changed task that owns integrated
    commits is re-opened against the current feature head, exactly like a
    VERIFY remediation (_reopen); a changed task without integrated commits
    starts over as fresh pending state under a new generation; a new plan task
    id gets fresh state; a dropped task with no integrated commits is retired;
    a dropped task that owns integrated commits, or one that changed repo while
    owning integrated commits, fails closed -- those commits would be
    unownable."""
    plan_tasks = _plan_tasks(store)
    # LF-55: close-outs are not plan tasks; reconciliation keeps them and their history.
    close_out_ids = [tid for tid, t in execute_state["tasks"].items() if t.get("closeOut")]
    tasks = {tid: t for tid, t in execute_state["tasks"].items() if not t.get("closeOut")}

    if any("plan" not in task_state for task_state in tasks.values()):
        raise LoopSpecError(
            "execute state predates plan snapshots; the program cannot tell which plan its recorded work ran against",
            repair="start a fresh run for this request",
        )

    if set(tasks) == set(plan_tasks) and all(tasks[tid]["plan"] == _plan_snapshot(plan_tasks[tid]) for tid in tasks):
        return

    attempt_id = ctx["attempt"]["id"]

    def _retire(tid: str, task_state: dict, repo_name: str) -> None:
        repo_path = Path(store.state["repos"][repo_name]["path"])
        last_step = (task_state["reviewSteps"] or task_state["implementSteps"] or [None])[-1]
        _retire_worktree(store, paths, repo_path, task_state["worktree"], last_step=last_step)
        store.state.get("executeRuns", {}).pop(tid, None)
        for issue in [i for i in execute_state["issues"] if i["task"] == tid]:
            execute_state["issues"].remove(issue)
            execute_state.setdefault("issueHistory", []).append(issue)

    kept, reopened, reset, added, dropped = [], [], [], [], []

    for tid in list(tasks):
        if tid in plan_tasks:
            continue
        task_state = tasks[tid]
        if task_state["commits"]:
            raise LoopSpecError(
                f"plan task {tid} was removed but owns integrated commits {', '.join(c[:12] for c in task_state['commits'])}",
                repair=f"restore {tid} in PLAN; a task that owns integrated commits cannot be dropped in 7.0",
            )
        _retire(tid, task_state, task_state["plan"]["repo"])
        del tasks[tid]
        del execute_state["tasks"][tid]
        dropped.append(tid)

    for tid, plan_task in plan_tasks.items():
        if tid not in tasks:
            tasks[tid] = execute_state["tasks"][tid] = _fresh_task_state(plan_task)
            added.append(tid)
            continue

        old = tasks[tid]
        new_snap = _plan_snapshot(plan_task)
        if old["plan"] == new_snap:
            kept.append(tid)
            continue

        changed_fields = sorted(f for f in _PLAN_IDENTITY_FIELDS if old["plan"].get(f) != new_snap.get(f))
        if old["commits"] and old["plan"]["repo"] != new_snap["repo"]:
            raise LoopSpecError(
                f"plan task {tid} changed repo from {old['plan']['repo']!r} to {new_snap['repo']!r} "
                f"but owns integrated commits in {old['plan']['repo']!r}",
                repair=(f"keep {tid} as the owner of its {old['plan']['repo']!r} commits and add a new "
                        f"task for the {new_snap['repo']!r} work"),
            )

        if old["commits"]:
            old.setdefault("remediations", []).append({
                "planChange": {"from": old["plan"], "to": new_snap},
                "priorStatus": old["status"], "priorRetries": old["retries"],
                "priorBranch": old["branch"], "priorWorktree": old["worktree"],
                "priorReview": old["review"], "at": now_iso(),
            })
            old["retries"] = 0
            store.state.get("executeRuns", {}).pop(tid, None)
            for issue in [i for i in execute_state["issues"] if i["task"] == tid]:
                execute_state["issues"].remove(issue)
                execute_state.setdefault("issueHistory", []).append(issue)
            reason = f"PLAN changed {tid} ({', '.join(changed_fields)}) after it integrated; re-implement against the current head"
            _reopen(store, paths, tid, old, plan_task, reason)
            old["plan"] = new_snap
            reopened.append(tid)
        else:
            # A fresh pending state, not a remediation-style reopen: nothing was
            # ever integrated for this task, so its whole history (retries,
            # steps, any remediations) is discarded, not carried forward.
            generation = old.get("generation", 0)
            had_fork = old["worktree"] is not None or old["branch"] is not None
            _retire(tid, old, old["plan"]["repo"])
            fresh = _fresh_task_state(plan_task)
            fresh["generation"] = generation
            tasks[tid] = execute_state["tasks"][tid] = fresh
            if had_fork:
                # The plain task/<slug>/<id> name is already spent on the
                # discarded attempt's (possibly still-retained) branch -- fork
                # a new generation right away instead of leaving _ensure_worktree
                # to collide with it lazily later.
                feature_head = execute_state["repos"][fresh["repo"]]["head"]
                reason = f"PLAN changed {tid} ({', '.join(changed_fields)}); re-implementing against the current head"
                _refork(store, paths, tid, fresh, plan_task, feature_head, reason)
            reset.append(tid)

    execute_state["waves"] = dag_waves(list(plan_tasks.values()), width=_execute_width()) + [[cid] for cid in close_out_ids]

    emit(paths, "execute_plan_reconciled", {
        "kept": kept, "reopened": reopened, "reset": reset, "added": added, "dropped": dropped,
        "summary": f"plan changed: kept {len(kept)}, reopened {len(reopened)}, reset {len(reset)}, added {len(added)}, dropped {len(dropped)}",
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
                "evidence": task_state["evidence"], "commits": [],
                # LF-55: a close-out's no-change claim is closed by its review, which E6 reads.
                "review": task_state["review"] if task_state.get("closeOut") else None,
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
    _reconcile_plan(store, paths, ctx, execute_state)

    if _self_heal_commits(store, execute_state):
        store.save()

    drift = _drifted_repo(store, paths, execute_state, ctx["attempt"]["id"])
    if drift is not None:
        return _drift_pause(ctx, drift)

    rejection_pause = _handle_rejection(store, paths, ctx, execute_state)
    if rejection_pause is not None:
        return rejection_pause

    _handle_rewind(store, paths, ctx, execute_state)
    if _schedule_close_outs(store, execute_state):
        store.save()

    if any(t["status"] in ("blocked", "planGap") for t in execute_state["tasks"].values()):
        return Product(_final_product(store, ctx, execute_state))

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
                pause = _ensure_worktree(store, paths, ctx, task_id, task_state, _task_spec(store, task_id))
                if pause is not None:
                    return pause

        requests: list[dict] = []
        open_steps: list[str] = []
        ready_for_review: list[str] = []
        for task_id in wave:
            task_state = execute_state["tasks"][task_id]
            if task_state["status"] == "pending":
                outcome = _implement_request(store, paths, ctx, _task_spec(store, task_id), task_state, task_id)
                if isinstance(outcome, Pause):
                    # Defensive: the pre-scan above already settled every worktree,
                    # so this should not fire, but a Pause still wins immediately.
                    return outcome
                requests.append(outcome)
            elif task_state["status"] == "probing":
                if _moved_after_refusal(task_state):
                    task_state["status"] = "blocked"
                    execute_state["issues"].append({"task": task_id, "text": (
                        f"the task branch moved after its review was refused (reviewed candidate "
                        f"{task_state['reviewCandidate'][:12]}); a worker whose termination is unknown may have written to it")})
                    store.save()
                    return step(store, paths, ctx)
                ready_for_review.append(task_id)
            elif task_state["status"] in ("implementing", "reviewing"):
                open_id = _open_step_id(store, task_state)
                if open_id is not None and open_id not in open_steps:
                    open_steps.append(open_id)
            elif task_state["status"] not in _TERMINAL:
                raise LoopSpecError(
                    f"execute task {task_id} is in status {task_state['status']!r}, which step() does not understand",
                    repair="check execute.py's task status machine for a missing case",
                )
        # 6.10's per-wave review: a task ready for review waits while a sibling in its
        # wave is still implementing, then the ready ones share one review step. A lone
        # task, and a close-out (E6 checks its own prompt), keep the single-task review.
        sibling_implementing = any(execute_state["tasks"][t]["status"] in ("pending", "implementing")
                                   for t in wave if t not in ready_for_review)
        if ready_for_review and not (sibling_implementing and (requests or open_steps)):
            batch = [t for t in ready_for_review if not execute_state["tasks"][t].get("closeOut")]
            singles = [t for t in ready_for_review if t not in batch or len(batch) < 2]
            if len(batch) >= 2:
                requests.append(_wave_review_request(store, paths, ctx, batch))
            for task_id in singles:
                requests.append(_review_request(store, paths, ctx, _task_spec(store, task_id), execute_state["tasks"][task_id]))
        if requests:
            return IssueStep(requests[0]) if len(requests) == 1 else IssueSteps(requests)
        if open_steps:
            return Wait(open_steps)
        raise LoopSpecError(
            "execute.step() was called with an outstanding submission still open",
            repair="submit the open step (on_submit) before calling step() again",
        )
    if _refresh_stale_close_outs(store, paths, execute_state):
        store.save()
        return step(store, paths, ctx)
    return Product(_final_product(store, ctx, execute_state))


def _on_implement_submit(store, paths, task_id: str, task_state: dict, step_record: dict, result: dict) -> None:
    task_state["implementSteps"].append(step_record["stepAttemptId"])
    execute_state = store.state["execute"]
    worktree = Path(task_state["worktree"])
    task_state.pop("noChange", None)

    # LF-49: "already satisfied" means nothing to integrate; Git, not the summary, decides that.
    if not result["commits"] and result["summary"].startswith("already satisfied:"):
        forked_from = task_state.get("forkedFrom")
        task_head = repo_module.branch_sha(worktree, task_state["branch"])
        if forked_from is not None and task_head == forked_from and repo_module.is_clean(worktree):
            task_state["evidence"] = result["summary"]
            task_state["reason"] = None
            if task_state.get("closeOut"):
                # LF-55: a close-out's no-change claim goes to review; the claim alone never closes it.
                task_state["noChange"] = True
                task_state["probes"] = None
                task_state["status"] = "probing"
                return
            task_state["status"] = "already-satisfied"
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
    if task_state.get("closeOut"):
        # A close-out has no PLAN file list; the files it changed feed review, E11 and VERIFY.
        changed = repo_module.run_git(worktree, "diff", "--name-only", f"{feature_head}..{task_head}")
        task_state["files"] = sorted(line for line in changed.splitlines() if line.strip())
    task_state["reason"] = None
    task_state["status"] = "probing"


def _on_review_submit(store, paths, task_id: str, task_state: dict, step_record: dict, result: dict) -> None:
    task_state["reviewSteps"].append(step_record["stepAttemptId"])
    execute_state = store.state["execute"]
    worktree = Path(task_state["worktree"])
    run_cwd = Path(task_state.pop("reviewCheckout", None) or worktree)
    candidate = task_state.pop("reviewCandidate", None)
    # The reviewed range is base..task from the head this task's own worktree
    # FORKED from, matching what _review_request actually showed the reviewer
    # -- never the feature branch's current head, which a same-wave sibling can
    # have already moved by merging first.
    fork = _fork_point(paths, execute_state, task_state, task_id, step_record.get("attempt"))
    current = repo_module.branch_sha(worktree, task_state["branch"])
    if candidate is not None and current != candidate:
        # LF-60: the review covers the issued candidate only; a branch that moved while
        # it ran (a retired worker's late write) is never relabelled as reviewed.
        task_state["status"] = "blocked"
        task_state["reason"] = None
        execute_state["issues"].append({"task": task_id, "text": (
            f"the task branch moved from {candidate[:12]} to {(current or 'missing')[:12]} while its review ran; "
            "the review covers only the issued candidate")})
        return
    task_head = candidate or current  # a review issued before LF-60's binding has none
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

    if task_state.get("closeOut"):
        # LF-55: a close-out has no verify command; the passing review is its proof.
        # No-change is decided from the reviewed candidate (LF-49's confirmed empty
        # fork, still unmoved), never from an empty integrated-commits list.
        if task_state.get("noChange") and task_head == task_state["forkedFrom"]:
            task_state["status"] = "already-satisfied"
            task_state["reason"] = None
            return
    else:
        plan_task = _plan_tasks(store)[task_id]
        # R3: this task's own repo has its own baseline; a workspace's other repos
        # never stand in for it.
        repo_baseline_dict = baseline_module.repo_baseline_dict(store.state.get("baseline"), plan_task["repo"], store.state["repos"])
        baseline_entry = baseline_module.BaselineEntry.from_dict(repo_baseline_dict["entries"][plan_task["verify"]])
        candidate = baseline_module.run_command(plan_task["verify"], run_cwd, task_head)
        comparison = baseline_module.compare_to_baseline(
            baseline_entry, candidate,
            feature_added=bool(plan_task["featureAdded"]), must_flip=bool(plan_task["mustFlip"]),
        )
        store.state.setdefault("executeRuns", {})[task_id] = {"run": candidate.to_dict(), "comparison": comparison.to_dict()}

        if comparison.verdict not in ("no-regression", "featureAdded-ok", "mustFlip-ok"):
            _route_verify_comparison(execute_state, task_id, task_state, comparison, candidate)
            return

    # 7.1.0: the plan's repo checks (lint, typecheck) at this task's head, close-outs
    # included, so a new diagnostic goes back to the implementer minutes after the
    # task. Early feedback only: VERIFY's check runs at the final head are the gate.
    if _check_regressed(store, execute_state, task_id, task_state, run_cwd, task_head):
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
            plan_task = _task_spec(store, task_id)
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
    wave = [tid for tid, t in execute_state["tasks"].items() if t.get("waveReview") == step.get("resultPath")]
    if step["role"] == "code-reviewer" and wave:
        by_task = {entry["task"]: entry for entry in result["tasks"]}
        if set(by_task) != set(wave):
            raise LoopSpecError(f"wave review {step['stepAttemptId']} returned results for {sorted(by_task)}, not {sorted(wave)}",
                                repair="the wave review must write exactly one result per task it was issued for")
        for task_id in wave:
            execute_state["tasks"][task_id].pop("waveReview")
            entry = {k: v for k, v in by_task[task_id].items() if k != "task"}
            _on_review_submit(store, paths, task_id, execute_state["tasks"][task_id], step, entry)
        store.save()
        return
    found = next(((tid, t) for tid, t in execute_state["tasks"].items()
                  if step["cwd"] in (t["worktree"], t.get("reviewCheckout"))), None)
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


def _moved_after_refusal(task_state: dict) -> bool:
    """LF-60: the task branch is no longer the candidate whose review was refused."""
    candidate = task_state.get("reviewCandidate")
    return candidate is not None and repo_module.branch_sha(Path(task_state["worktree"]), task_state["branch"]) != candidate


def on_step_refused(store, paths, step_id: str, refused: dict) -> None:
    """LF-60: a task review refused for want of evidence. The task keeps no reference
    to the dead step: it returns to review (one retry spent, as E6's rejection does)
    in a fresh checkout of the candidate that was under review; the quarantined
    worktree is never reused while its worker's termination is unknown. Mutates
    state only; the controller saves it with the ownerReset flag."""
    execute_state = store.state.get("execute") or {}
    if refused["role"] != "code-reviewer":
        return
    tasks = execute_state.get("tasks", {})
    step_path = paths.steps_dir / step_id / "step.json"
    result_path = read_json(step_path).get("resultPath") if step_path.is_file() else None
    affected = [(tid, t) for tid, t in tasks.items() if result_path and t.get("waveReview") == result_path]
    if not affected:
        found = next(((tid, t) for tid, t in tasks.items()
                      if refused["cwd"] in (t["worktree"], t.get("reviewCheckout"))), None)
        affected = [found] if found is not None else []
    for task_id, task_state in affected:
        if task_state["status"] != "reviewing":
            continue
        task_state.pop("waveReview", None)
        # Bound when the refused review was issued; a pre-binding step falls back to the branch.
        candidate = task_state.get("reviewCandidate") or repo_module.branch_sha(Path(task_state["worktree"]), task_state["branch"])
        checkout = paths.checkouts_dir / f"review-{task_id}-{step_id}"
        if not checkout.exists():
            repo_module.clean_checkout(Path(store.state["repos"][task_state["repo"]]["path"]), candidate, checkout)
        task_state.update({"review": None, "reviewCheckout": str(checkout), "reviewCandidate": candidate})
        _retry_or_block(execute_state, task_id, task_state, f"review step {step_id} refused: {refused['reason']}",
                        retry_status="probing")
