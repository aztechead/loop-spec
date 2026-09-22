"""Invoke a phase implementation under the process contract, exit codes 0-3.

Use `resolve_implementation`/`resolve_role` to look up which implementation or role a
phase or role is bound to, `write_context` to hand an implementation its input
envelope, and `invoke` (or the out-of-process `run_phase` the CLI's `phase` command
calls) to run one and turn its exit code and output files into a `PhaseOutcome`. This
module never decides a route; that is postconditions.py/controller.py (wave D).
"""
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from . import external
from .errors import LoopSpecError
from .jsonio import atomic_write_json, read_json
from .schema import load_schema, validate, validate_or_raise

# The two fields each request kind's schema declares that only the program may mint;
# an implementation's step/question request omits them (it cannot allocate ids), so
# validate_request checks the same schema with just these two dropped from `required`.
_REQUEST_ID_FIELDS = {
    "step": ("stepAttemptId", "issuedAt"),
    "question": ("questionId", "askedAt"),
}


@dataclass
class PhaseOutcome:
    code: int
    kind: Literal["product", "error", "step", "question"]
    path: Path | None
    stderr: str


def load_config(project_root: Path) -> dict:
    path = Path(project_root) / ".loop-spec" / "config.json"
    if not path.is_file():
        return {}
    return read_json(path)


def resolve_implementation(project_root: Path, phase: str) -> str:
    env = os.environ.get(f"LOOP_SPEC_PHASE_{phase.upper()}")
    if env:
        return env
    return load_config(project_root).get("phases", {}).get(phase, "default")


def resolve_role(project_root: Path, role: str) -> str:
    env = os.environ.get(f"LOOP_SPEC_ROLE_{role.upper()}")
    if env:
        return env
    return load_config(project_root).get("roles", {}).get(role, "default")


def write_context(paths, attempt_id: str, envelope: dict) -> Path:
    validate_or_raise(envelope, "context")
    path = paths.attempts_dir / attempt_id / "context.json"
    atomic_write_json(path, envelope)
    return path


def validate_request(kind: str, obj: dict) -> list[str]:
    schema = load_schema(kind)
    drop = _REQUEST_ID_FIELDS[kind]
    schema = {**schema, "required": [f for f in schema["required"] if f not in drop]}
    return validate(obj, schema)


def run_phase(phase: str, context_path: Path, product_path: Path) -> int:
    # M1 has exactly one working implementation (external); `phase` is threaded
    # through for the day a bound-skill or default implementation also runs this
    # out-of-process contract entry point.
    return external.run(context_path, product_path, phase)


def _accept_product(phase: str, product_path: Path) -> PhaseOutcome:
    if not product_path.is_file():
        return PhaseOutcome(code=0, kind="error", path=None, stderr=f"exit 0 but no product at {product_path}")
    errors = validate(read_json(product_path), load_schema(phase))
    if errors:
        return PhaseOutcome(code=0, kind="error", path=None, stderr="; ".join(errors))
    return PhaseOutcome(code=0, kind="product", path=product_path, stderr="")


def _accept_request(path: Path, kind: str, code: int) -> PhaseOutcome:
    if not path.is_file():
        return PhaseOutcome(code=code, kind="error", path=None, stderr=f"exit {code} but no {kind} request at {path}")
    errors = validate_request(kind, read_json(path))
    if errors:
        return PhaseOutcome(code=code, kind="error", path=None, stderr="; ".join(errors))
    return PhaseOutcome(code=code, kind=kind, path=path, stderr="")


# The only two phases wave E gave a default (lead-run) implementation to; the rest
# still have none until M3/M4/M5 bind an implementation of their own.
_DEFAULT_ROLE_BY_PHASE = {"spec": "spec-writer", "plan": "planner"}


def _run_default_execute(store, paths, attempt_dir: Path, product_path: Path) -> int:
    # execute.py's step()/on_submit() need the live StateStore (they carry per-task
    # progress across calls in store.state["execute"]), unlike run_lead_phase's
    # context.json/product.json-only contract, so this dispatcher stays here rather
    # than in execute.py (its own docstring says wiring it in is not its job).
    from . import execute as execute_module
    ctx = read_json(attempt_dir / "context.json")
    outcome = execute_module.step(store, paths, ctx)
    if isinstance(outcome, execute_module.Product):
        atomic_write_json(product_path, outcome.product)
        return 0
    if isinstance(outcome, execute_module.IssueStep):
        atomic_write_json(attempt_dir / "step.json", outcome.request)
        return 2
    atomic_write_json(attempt_dir / "question.json", outcome.question_request)
    return 3


def invoke(paths, *, phase: str, attempt_id: str, implementation: str, program_launcher: Path, store=None) -> PhaseOutcome:
    attempt_dir = paths.attempts_dir / attempt_id
    product_path = attempt_dir / "product.json"

    if implementation == "default":
        if phase == "execute":
            if store is None:
                raise LoopSpecError("execute's default implementation needs the live state store",
                                     repair="call contract.invoke(..., store=store) from the controller")
            code = _run_default_execute(store, paths, attempt_dir, product_path)
        elif phase in _DEFAULT_ROLE_BY_PHASE:
            from . import defaults  # local: defaults.py calls back into resolve_role
            code = defaults.run_lead_phase(phase, _DEFAULT_ROLE_BY_PHASE[phase], attempt_dir / "context.json", product_path)
        else:
            raise LoopSpecError(f"default implementation for {phase} lands at M4/M5", repair='bind "external" in .loop-spec/config.json until then')
    elif implementation == "external":
        code = run_phase(phase, attempt_dir / "context.json", product_path)
    else:
        raise LoopSpecError("bound implementations land at M5", repair='bind "external" in .loop-spec/config.json until M5')

    if code == 0:
        return _accept_product(phase, product_path)
    if code == 2:
        return _accept_request(attempt_dir / "step.json", "step", code)
    if code == 3:
        return _accept_request(attempt_dir / "question.json", "question", code)
    if code == 1:
        return PhaseOutcome(code=1, kind="error", path=None, stderr="implementation exited 1")
    return PhaseOutcome(code=code, kind="error", path=None, stderr=f"implementation exited {code}; only 0-3 advance")
