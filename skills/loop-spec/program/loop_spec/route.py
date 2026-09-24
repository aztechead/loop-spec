"""ROUTE's phase module (7.3.0): one role step (`router`) picks the entry an `auto` run
continues as.

Use `step`/`on_submit` the way `debug.py` does. The facts the router reads are the
controller's (`store.state["route"]["facts"]`, written when the auto run starts); this
module owns only `store.state["route"]["result"]`, bound to the attempt it answered, so
a rejected choice is asked again with the rule it broke instead of replayed.
"""
from pathlib import Path

from loop_spec import external
from loop_spec.contract import resolve_role, validate_request
from loop_spec.entries import ENTRIES, ROUTABLE
from loop_spec.errors import LoopSpecError
from loop_spec.paths import ensure_results_dir
from loop_spec.roles import compose_prompt, load_role, resolve_model
from loop_spec.steps import IssueStep, Product


def _rejection(ctx) -> str | None:
    rejected = ((ctx.get("entry") or {}).get("payload") or {}).get("rejected")
    return "; ".join(f["message"] for f in rejected["failures"]) if rejected else None


def _router_request(store, paths, ctx) -> dict:
    project_root = Path(ctx["paths"]["projectRoot"])
    role = load_role("router", project_root, resolve_role(project_root, "router"))
    ensure_results_dir(paths)
    result_path = paths.results_dir / f"route-{ctx['attempt']['id']}.json"
    rejected = _rejection(ctx)
    inputs = {
        "request": ctx["request"]["text"],
        "prRefs": store.state["route"]["facts"]["prRefs"],
        "entries": [{"name": n, "use": ENTRIES[n].use, "takes": ENTRIES[n].takes} for n in ROUTABLE],
        "rejected": rejected,
    }
    prompt = compose_prompt(role, inputs=inputs, result_path=result_path, cwd=project_root, phase="route")
    request = {
        "kind": "role", "role": "router", "phase": "route", "cwd": str(project_root), "prompt": prompt,
        "resultPath": str(result_path), "schema": role.schema, "postconditions": external.PHASE_POSTCONDITIONS["route"],
        "attempt": ctx["attempt"]["id"], "inputsDigest": ctx["inputs"]["digest"], "retryOf": None, "reason": rejected,
        "model": resolve_model(project_root, "router"),
    }
    errors = validate_request("step", request)
    if errors:
        raise LoopSpecError("route built an invalid router step request: " + "; ".join(errors),
                             repair="fix _router_request in route.py")
    return request


def step(store, paths, ctx):
    stored = store.state.setdefault("route", {}).get("result")
    if stored is not None and stored["attempt"] == ctx["attempt"]["id"]:
        return Product({"exit": "routed", "inputsDigest": ctx["inputs"]["digest"],
                        "boundTo": {"requirements": None, "plan": None}, **stored["result"]})
    return IssueStep(_router_request(store, paths, ctx))


def on_submit(store, paths, step, result: dict) -> None:
    store.state.setdefault("route", {})["result"] = {"attempt": step["attempt"], "step": step["stepAttemptId"], "result": result}
    store.save()
