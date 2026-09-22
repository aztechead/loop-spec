"""DEBUG's phase module (M4): one lead step (role `debugger`) produces the whole
debug product; the entry-side work (creating the run, approval, routing the compact
SPEC/PLAN onward) is the controller's, using the two pure helpers below.

Use `step`/`on_submit` the same way `execute.py` does. Module state lives under
`store.state["debug"]`, which also holds `baseRun`/`originalRun` once the controller
calls `record_base_runs` (B1/B2 read them).
"""
from pathlib import Path

from . import baseline as baseline_module
from . import external
from . import repo as repo_module
from .contract import resolve_role, validate_request
from .errors import LoopSpecError
from .execute import IssueStep, Product
from .roles import compose_prompt, load_role
from .schema import load_schema


def _debugger_request(store, paths, ctx) -> dict:
    project_root = Path(ctx["paths"]["projectRoot"])
    role = load_role("debugger", project_root, resolve_role(project_root, "debugger"))
    _, repo_info = next(iter(store.state["repos"].items()))
    cwd = Path(repo_info["path"])
    result_path = Path(paths.attempts_dir) / ctx["attempt"]["id"] / "debug-result.json"

    inputs = {
        "request": ctx["request"]["text"], "state": ctx.get("state", {}), "entry": ctx.get("entry", {}),
        "answers": ctx.get("answers", {}), "probes": ctx.get("probes", {}),
    }
    prompt = compose_prompt(role, inputs=inputs, result_path=result_path, cwd=cwd, phase="debug")
    request = {
        "kind": "lead", "role": "debugger", "phase": "debug", "cwd": str(cwd), "prompt": prompt,
        "resultPath": str(result_path), "schema": load_schema("debug"),
        "postconditions": external.PHASE_POSTCONDITIONS["debug"],
        "attempt": ctx["attempt"]["id"], "inputsDigest": ctx["inputs"]["digest"], "retryOf": None, "reason": None,
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


def record_base_runs(store, paths, product: dict, repo_path: Path, base_sha: str) -> None:
    checkout = Path(paths.checkouts_dir) / f"debug-base-{base_sha[:12]}"
    repo_module.clean_checkout(repo_path, base_sha, checkout)
    try:
        base_run = baseline_module.run_command(product["reproduction"]["command"], checkout, base_sha)
        debug_state = store.state.setdefault("debug", {})
        debug_state["baseRun"] = base_run.to_dict()
        if product.get("original") is not None:
            original_run = baseline_module.run_command(product["original"]["command"], checkout, base_sha)
            debug_state["originalRun"] = original_run.to_dict()
    finally:
        repo_module.remove_worktree(repo_path, checkout, force=True)
    store.save()


def compact_products(product: dict) -> tuple[dict, dict]:
    plan_product = product["plan"]
    tasks = [{**task, "mustFlip": True, "verify": product["reproduction"]["command"]} for task in plan_product["tasks"]]
    return product["spec"], {**plan_product, "tasks": tasks}
