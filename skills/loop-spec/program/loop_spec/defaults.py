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

    # The context envelope carries no project root (schemas/context.json has none):
    # the first repo's path is the same fallback external.py already uses for cwd,
    # and it doubles here as the root a bound-skill lookup searches from.
    repos = context.get("repos") or []
    root = Path(repos[0]["path"]) if repos else Path(context["paths"]["stateDir"])

    from .contract import resolve_role  # local: contract.invoke calls into this module

    binding = resolve_role(root, role_name)
    role = load_role(role_name, root, binding)

    state = context.get("state", {})
    inputs = {
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
    prompt = compose_prompt(role, inputs=inputs, result_path=product_path, cwd=root, phase=phase)

    env_key = "LOOP_SPEC_MODEL_" + role_name.upper().replace("-", "_")
    step_request = {
        "kind": "lead", "role": role_name, "phase": phase, "cwd": str(root), "prompt": prompt,
        "resultPath": str(product_path), "schema": load_schema(phase),
        "postconditions": external.PHASE_POSTCONDITIONS[phase],
        "attempt": context["attempt"]["id"], "inputsDigest": context["inputs"]["digest"],
        "retryOf": None, "reason": None, "model": os.environ.get(env_key),
    }
    atomic_write_json(product_path.parent / "step.json", step_request)
    return 2
