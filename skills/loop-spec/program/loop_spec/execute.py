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
from pathlib import Path

from . import baseline as baseline_module
from . import probes as probes_module
from . import repo as repo_module
from .budget import has_room
from .contract import resolve_role, validate_request
from .errors import LoopSpecError
from .postconditions import retry_limit
from .roles import compose_prompt, load_role

_TERMINAL = {"done", "already-satisfied", "removed", "blocked"}
_DIFF_CAP = 200_000  # ponytail: a flat cap, raise it if a real diff gets truncated in practice


class IssueStep:
    __slots__ = ("request",)

    def __init__(self, request: dict) -> None:
        self.request = request


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


def _retry_or_block(execute_state: dict, task_id: str, task_state: dict, reason_text: str) -> None:
    task_state["retries"] += 1
    if task_state["retries"] > retry_limit():
        task_state["status"] = "blocked"
        task_state["reason"] = None
        execute_state["issues"].append({"task": task_id, "text": reason_text})
    else:
        task_state["status"] = "pending"
        task_state["reason"] = reason_text


# --- initialization (first step() call only) ------------------------------

def _init(store, paths, ctx) -> dict:
    plan_tasks = store.state["products"]["plan"]["product"]["tasks"]
    width = int(os.environ.get("LOOP_SPEC_EXECUTE_WIDTH", "3"))
    waves = dag_waves(plan_tasks, width=width)

    # The feature branch is checked out in its own worktree here, once, so a task's
    # commits ever land in the operator's own checkout only via the fast-forward
    # merge in on_submit -- never by working directly in repo_info["path"].
    repos = {}
    for name, info in (store.state.get("repos") or {}).items():
        worktree = paths.worktrees_dir / "feature" / name
        repo_module.add_worktree(Path(info["path"]), worktree, branch=info["featureBranch"])
        repos[name] = {"worktree": str(worktree), "head": repo_module.head_sha(worktree)}

    tasks = {
        t["id"]: {
            "status": "pending", "repo": t["repo"], "worktree": None, "branch": None,
            "baseLayers": None, "implementSteps": [], "reviewSteps": [], "commits": [],
            "review": None, "probes": None, "evidence": None, "retries": 0, "reason": None,
        }
        for t in plan_tasks
    }

    execute_state = {"waves": waves, "tasks": tasks, "repos": repos, "issues": []}
    store.state["execute"] = execute_state
    store.save()
    return execute_state


def _ensure_worktree(store, paths, task_id: str, task_state: dict, plan_task: dict) -> None:
    if task_state["worktree"] is not None:
        return
    # Forked from the feature branch's CURRENT head, not a head captured at
    # init time: a later wave's task must build on top of earlier waves' already
    # -integrated commits, not the run's original base.
    execute_state = store.state["execute"]
    repo_state = execute_state["repos"][task_state["repo"]]
    repo_info = store.state["repos"][task_state["repo"]]
    branch = f"task/{task_id}"
    repo_module.create_feature_branch(Path(repo_info["path"]), branch, repo_state["head"])
    worktree = paths.worktrees_dir / task_id
    repo_module.add_worktree(Path(repo_info["path"]), worktree, branch=branch)
    task_state["worktree"] = str(worktree)
    task_state["branch"] = branch
    task_state["baseLayers"] = probes_module.indirection_scan(worktree, plan_task["files"])["layers"]
    store.save()


# --- step requests ---------------------------------------------------------

def _result_path(paths, task_id: str, kind: str, n: int) -> Path:
    results = paths.root / "results"
    results.mkdir(parents=True, exist_ok=True)
    return results / f"{task_id}-{kind}-{n}.json"


def _implement_request(store, paths, ctx, plan_task: dict, task_state: dict, task_id: str) -> dict:
    _ensure_worktree(store, paths, task_id, task_state, plan_task)
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
        "reason": task_state["reason"],
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
    feature_head = execute_state["repos"][task_state["repo"]]["head"]
    task_head = repo_module.branch_sha(worktree, task_state["branch"])
    result_path = _result_path(paths, plan_task["id"], "review", len(task_state["reviewSteps"]) + 1)

    diff = repo_module.run_git(worktree, "diff", f"{feature_head}..{task_head}")
    if len(diff) > _DIFF_CAP:
        diff = diff[:_DIFF_CAP] + "\n...(truncated)"

    signals = (ctx.get("probes") or {}).get("securitySignals") or []
    inputs = {
        "task": plan_task,
        "range": {"from": feature_head, "to": task_head},
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
        "retryOf": None, "reason": None,
    }
    errors = validate_request("step", request)
    if errors:
        raise LoopSpecError("execute built an invalid review step request: " + "; ".join(errors),
                             repair="fix _review_request in execute.py")
    task_state["status"] = "reviewing"
    store.save()
    return request


def _pause_request(ctx, repo_name: str, expected: str, actual: str) -> dict:
    request = {
        "attempt": ctx["attempt"]["id"], "phase": "execute",
        "text": (f"repo {repo_name}'s feature branch moved out of band "
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

    if execute_state["issues"]:
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


# --- the two entry points ---------------------------------------------

def step(store, paths, ctx):
    execute_state = store.state.get("execute")
    if execute_state is None:
        execute_state = _init(store, paths, ctx)

    for name, repo_state in execute_state["repos"].items():
        repo_info = store.state["repos"][name]
        actual = repo_module.branch_sha(Path(repo_info["path"]), repo_info["featureBranch"])
        if actual is not None and actual != repo_state["head"]:
            return Pause(_pause_request(ctx, name, repo_state["head"], actual))

    if any(t["status"] == "blocked" for t in execute_state["tasks"].values()):
        return Product(_final_product(store, ctx, execute_state))

    plan_tasks = _plan_tasks(store)
    for wave in execute_state["waves"]:
        wave_states = [execute_state["tasks"][tid] for tid in wave]
        if all(t["status"] in _TERMINAL for t in wave_states):
            continue
        for task_id in wave:
            task_state = execute_state["tasks"][task_id]
            if task_state["status"] == "pending":
                return IssueStep(_implement_request(store, paths, ctx, plan_tasks[task_id], task_state, task_id))
            if task_state["status"] == "probing":
                return IssueStep(_review_request(store, paths, ctx, plan_tasks[task_id], task_state))
        raise LoopSpecError(
            "execute.step() was called with an outstanding submission still open",
            repair="submit the open step (on_submit) before calling step() again",
        )
    return Product(_final_product(store, ctx, execute_state))


def _on_implement_submit(store, task_id: str, task_state: dict, step_record: dict, result: dict) -> None:
    task_state["implementSteps"].append(step_record["stepAttemptId"])
    execute_state = store.state["execute"]
    worktree = Path(task_state["worktree"])

    if not result["commits"] and result["summary"].startswith("already satisfied:"):
        task_state["status"] = "already-satisfied"
        task_state["evidence"] = result["summary"]
        task_state["reason"] = None
        return

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


def _on_review_submit(store, task_id: str, task_state: dict, step_record: dict, result: dict) -> None:
    task_state["reviewSteps"].append(step_record["stepAttemptId"])
    execute_state = store.state["execute"]
    worktree = Path(task_state["worktree"])
    feature_head = execute_state["repos"][task_state["repo"]]["head"]
    task_head = repo_module.branch_sha(worktree, task_state["branch"])
    task_state["review"] = {
        "reviewedRange": {"from": feature_head, "to": task_head},
        "verdict": result["verdict"], "findings": result["findings"],
        "securityDispositions": result["securityDispositions"],
    }

    if result["verdict"] != "pass":
        open_findings = [f for f in result["findings"] if f["disposition"] not in ("rejected", "deferred")]
        causes = "; ".join(f'{f["location"]}: {f["cause"]}' for f in open_findings) or "review failed with no open finding"
        _retry_or_block(execute_state, task_id, task_state, f"the reviewer found: {causes}")
        return

    plan_task = _plan_tasks(store)[task_id]
    baseline_entry = baseline_module.BaselineEntry.from_dict(store.state["baseline"]["entries"][plan_task["verify"]])
    candidate = baseline_module.run_command(plan_task["verify"], worktree, task_head)
    comparison = baseline_module.compare_to_baseline(
        baseline_entry, candidate,
        feature_added=bool(plan_task["featureAdded"]), must_flip=bool(plan_task["mustFlip"]),
    )
    store.state.setdefault("executeRuns", {})[task_id] = {"run": candidate.to_dict(), "comparison": comparison.to_dict()}

    if comparison.verdict not in ("no-regression", "featureAdded-ok", "mustFlip-ok"):
        _retry_or_block(execute_state, task_id, task_state, f"the verify re-run is {comparison.verdict}: {comparison.detail}")
        return

    feature_worktree = Path(execute_state["repos"][task_state["repo"]]["worktree"])
    repo_module.run_git(feature_worktree, "merge", "--ff-only", task_head)
    task_state["commits"] = repo_module.commits_between(feature_worktree, feature_head, task_head)
    execute_state["repos"][task_state["repo"]]["head"] = task_head
    task_state["status"] = "done"
    task_state["reason"] = None


def on_submit(store, paths, step, result: dict) -> None:
    # `paths` is part of the required on_submit interface (symmetry with step());
    # this implementation has no need for it yet. `step` is the registered step
    # record (has cwd/role/stepAttemptId), not this module's own step() function.
    execute_state = store.state["execute"]
    found = next(((tid, t) for tid, t in execute_state["tasks"].items() if t["worktree"] == step["cwd"]), None)
    if found is None:
        raise LoopSpecError(f"execute has no task with worktree {step['cwd']}", repair="check the submitted step's cwd")
    task_id, task_state = found

    if step["role"] == "implementer":
        _on_implement_submit(store, task_id, task_state, step, result)
    elif step["role"] == "code-reviewer":
        _on_review_submit(store, task_id, task_state, step, result)
    else:
        raise LoopSpecError(f"execute got a submission for an unknown role {step['role']!r}",
                             repair="check the submitted step's role field")
    store.save()
