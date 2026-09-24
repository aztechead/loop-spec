"""DEBUG's phase module (M4): one lead step (role `debugger`) produces the whole
debug product; the entry-side work (creating the run, approval, routing the compact
SPEC/PLAN onward) is the core's, which calls `compact` below through the registry.

Use `step`/`on_submit` the same way `execute.py` does. Module state lives under
`store.state["debug"]`. The program's own re-run of the reproduction, which B1/B2
read, is core evidence (`state.debugRuns`, written by the controller).
"""
from pathlib import Path

from loop_spec import external
from loop_spec.contract import resolve_role, validate_request
from loop_spec.errors import LoopSpecError
from loop_spec.steps import IssueStep, Product
from loop_spec.paths import ensure_results_dir
from loop_spec.roles import compose_prompt, load_role, repo_map, resolve_model
from loop_spec.schema import load_schema


def _debugger_request(store, paths, ctx) -> dict:
    project_root = Path(ctx["paths"]["projectRoot"])
    role = load_role("debugger", project_root, resolve_role(project_root, "debugger"))
    _, repo_info = next(iter(store.state["repos"].items()))
    cwd = Path(repo_info["path"])
    # LF-27: under the project root (paths.results_dir), not the state home -- a
    # live lead step, under Claude Code's default permission mode, cannot write
    # under ~/.claude/... even with the Write tool allow-listed.
    ensure_results_dir(paths)
    result_path = paths.results_dir / f"debug-{ctx['attempt']['id']}.json"

    inputs = {
        "request": ctx["request"]["text"], "state": ctx.get("state", {}), "entry": ctx.get("entry", {}),
        "answers": ctx.get("answers", {}), "probes": ctx.get("probes", {}),
        "repos": repo_map(store.state["repos"]),
    }
    prompt = compose_prompt(role, inputs=inputs, result_path=result_path, cwd=cwd, phase="debug")
    request = {
        "kind": "lead", "role": "debugger", "phase": "debug", "cwd": str(cwd), "prompt": prompt,
        "resultPath": str(result_path), "schema": load_schema("debug"),
        "postconditions": external.PHASE_POSTCONDITIONS["debug"],
        "attempt": ctx["attempt"]["id"], "inputsDigest": ctx["inputs"]["digest"], "retryOf": None, "reason": None,
        "model": resolve_model(project_root, "debugger"),
    }
    errors = validate_request("step", request)
    if errors:
        raise LoopSpecError("debug built an invalid lead step request: " + "; ".join(errors),
                             repair="fix _debugger_request in debug.py")
    return request


def step(store, paths, ctx):
    debug_state = store.state.get("debug") or {}
    if debug_state.get("product") is not None:
        return Product(debug_state["product"])
    return IssueStep(_debugger_request(store, paths, ctx))


def on_submit(store, paths, step, result: dict) -> None:
    store.state.setdefault("debug", {})["product"] = result
    store.save()


def compact(product: dict) -> tuple[dict, dict]:
    """The registry hook the core calls after accepting a debug product: its SPEC and
    PLAN halves, each repair task pinned to the reproduction (debug's meaning)."""
    plan_product = product["plan"]
    tasks = [{**task, "mustFlip": True, "verify": product["reproduction"]["command"]} for task in plan_product["tasks"]]
    return product["spec"], {**plan_product, "tasks": tasks}
