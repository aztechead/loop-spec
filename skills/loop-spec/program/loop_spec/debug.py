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
from .paths import ensure_results_dir
from .roles import compose_prompt, load_role
from .schema import load_schema


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


def _with_error_class(run: dict) -> dict:
    """LF-23: a pyenv shim (or similar wrapper) can exit 127 without ever raising
    FileNotFoundError, so run_command's own exception-based errorClass detection
    never fires for it. Backfilling errorClass from the exit status here lets B1's
    message name a missing binary either way run_command found it."""
    if run.get("exitStatus") == 127 or run.get("errorClass") is not None:
        return {**run, "errorClass": run.get("errorClass") or "command-not-found"}
    return run


def record_base_runs(store, paths, product: dict, repo_path: Path, base_sha: str) -> None:
    checkout = Path(paths.checkouts_dir) / f"debug-base-{base_sha[:12]}"
    repo_module.clean_checkout(repo_path, base_sha, checkout)
    try:
        base_run = baseline_module.run_command(product["reproduction"]["command"], checkout, base_sha)
        debug_state = store.state.setdefault("debug", {})
        debug_state["baseRun"] = _with_error_class(base_run.to_dict())
        # LF-23: the worker's own failureDigest came from its own checkout, a
        # different path than the program's clean checkout above -- the two digests
        # can never match, so this is recorded as the worker's claim, never compared.
        debug_state["claimedDigest"] = product["reproduction"]["failureDigest"]
        if product.get("original") is not None:
            original_run = baseline_module.run_command(product["original"]["command"], checkout, base_sha)
            debug_state["originalRun"] = _with_error_class(original_run.to_dict())
    finally:
        repo_module.remove_worktree(repo_path, checkout, force=True)
    store.save()


def compact_products(product: dict) -> tuple[dict, dict]:
    plan_product = product["plan"]
    tasks = [{**task, "mustFlip": True, "verify": product["reproduction"]["command"]} for task in plan_product["tasks"]]
    return product["spec"], {**plan_product, "tasks": tasks}
