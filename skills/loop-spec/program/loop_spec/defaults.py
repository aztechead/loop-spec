"""The default SPEC/PLAN implementations under the process contract: dispatch a
`lead` step that runs the bound role's composed prompt in the current session.

Use `run_lead_phase` as `contract.invoke`'s `implementation == "default"` handler
for the `spec` and `plan` phases; EXECUTE/VERIFY/ITERATE/DELIVER have no default
yet, so `contract.py` still raises "lands at M3/M4/M5" for those.
"""
import os
from pathlib import Path

from . import external
from .jsonio import atomic_write_json, read_json
from .roles import compose_prompt, load_role
from .schema import load_schema, validate


def run_lead_phase(phase: str, role_name: str, context_path: Path, product_path: Path) -> int:
    context = read_json(context_path)
    product_path = Path(product_path)
    if product_path.is_file() and not validate(read_json(product_path), load_schema(phase)):
        return 0

    project_root = Path(context["paths"]["projectRoot"])

    from .contract import resolve_role  # local: contract.invoke calls into this module

    binding = resolve_role(project_root, role_name)
    role = load_role(role_name, project_root, binding)

    # context.repos is a dict keyed by repo name (controller.py builds
    # state.repos that way); a list is also accepted since context.json's own
    # schema allows either shape.
    repos = context.get("repos") or {}
    if isinstance(repos, list):
        first_repo = repos[0] if repos else None
    else:
        first_repo = next(iter(repos.values()), None)
    cwd = Path(first_repo["path"]) if first_repo else project_root

    state = context.get("state", {})
    inputs = {
        "request": context["request"]["text"],
        "products": context.get("products", {}),
        "state": state,
        "entry": context.get("entry", {}),
        "answers": context.get("answers", {}),
        "probes": context.get("probes", {}),
        "inputsDigest": context["inputs"]["digest"],
        "revisions": {
            "requirements": state.get("requirementsRevision"),
            "plan": state.get("planRevision"),
        },
    }
    prompt = compose_prompt(role, inputs=inputs, result_path=product_path, cwd=cwd, phase=phase)

    env_key = "LOOP_SPEC_MODEL_" + role_name.upper().replace("-", "_")
    step_request = {
        "kind": "lead", "role": role_name, "phase": phase, "cwd": str(cwd), "prompt": prompt,
        "resultPath": str(product_path), "schema": load_schema(phase),
        "postconditions": external.PHASE_POSTCONDITIONS[phase],
        "attempt": context["attempt"]["id"], "inputsDigest": context["inputs"]["digest"],
        "retryOf": None, "reason": None, "model": os.environ.get(env_key),
    }
    atomic_write_json(product_path.parent / "step.json", step_request)
    return 2
