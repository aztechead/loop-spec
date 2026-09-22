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
    if phase == "revise":
        # "revise" is not one of the seven ROUTES phases and has no schemas/revise.json
        # of its own (revise.py's docstring): steps.submit already validated this
        # result against the reviser role's own schema when its lead step was
        # submitted, so there is nothing further to check against here.
        return PhaseOutcome(code=0, kind="product", path=product_path, stderr="")
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


# The two phases with a default lead-run implementation (spec-writer, planner) and
# the five with a default step()/on_submit() implementation (execute.py's own
# pattern, reused by verify/iterate/debug/revise).
_DEFAULT_ROLE_BY_PHASE = {"spec": "spec-writer", "plan": "planner"}
_DEFAULT_STEPPED_MODULE_BY_PHASE = {"execute", "verify", "iterate", "debug", "revise"}


def _run_default_stepped(module, store, paths, attempt_dir: Path, product_path: Path) -> int:
    # execute.py/verify.py/iterate.py/debug.py's step()/on_submit() need the live
    # StateStore (they carry per-task or per-pass progress across calls in
    # store.state[<phase>]), unlike run_lead_phase's context.json/product.json-only
    # contract, so this dispatcher stays here rather than in each module (their own
    # docstrings say wiring them in is not their job). All four import IssueStep/
    # Product/Pause from execute.py, so one isinstance check covers every module.
    from . import execute as execute_module
    ctx = read_json(attempt_dir / "context.json")
    outcome = module.step(store, paths, ctx)
    if isinstance(outcome, execute_module.Product):
        atomic_write_json(product_path, outcome.product)
        return 0
    if isinstance(outcome, execute_module.IssueStep):
        atomic_write_json(attempt_dir / "step.json", outcome.request)
        return 2
    atomic_write_json(attempt_dir / "question.json", outcome.question_request)
    return 3


def _run_default_deliver(store, paths, attempt_dir: Path, product_path: Path) -> int:
    # deliver.py's run() dispatches no worker step: one pass returns a Product or a
    # Pause, never an IssueStep (its own docstring: an out-of-band remote move maps
    # to a "delivery blocked" product exit, not a raw pause -- no scenario uses Pause
    # today, but the branch stays so a future one need not touch this dispatcher).
    from . import deliver as deliver_module
    from . import execute as execute_module
    ctx = read_json(attempt_dir / "context.json")
    outcome = deliver_module.run(store, paths, ctx)
    if isinstance(outcome, execute_module.Product):
        atomic_write_json(product_path, outcome.product)
        return 0
    atomic_write_json(attempt_dir / "question.json", outcome.question_request)
    return 3


def invoke(paths, *, phase: str, attempt_id: str, implementation: str, program_launcher: Path, store=None) -> PhaseOutcome:
    attempt_dir = paths.attempts_dir / attempt_id
    product_path = attempt_dir / "product.json"

    if implementation == "default":
        if phase in _DEFAULT_STEPPED_MODULE_BY_PHASE:
            if store is None:
                raise LoopSpecError(f"{phase}'s default implementation needs the live state store",
                                     repair="call contract.invoke(..., store=store) from the controller")
            from . import debug as debug_module
            from . import execute as execute_module
            from . import iterate as iterate_module
            from . import revise as revise_module
            from . import verify as verify_module
            module = {"execute": execute_module, "verify": verify_module, "iterate": iterate_module,
                      "debug": debug_module, "revise": revise_module}[phase]
            code = _run_default_stepped(module, store, paths, attempt_dir, product_path)
        elif phase == "deliver":
            if store is None:
                raise LoopSpecError("deliver's default implementation needs the live state store",
                                     repair="call contract.invoke(..., store=store) from the controller")
            code = _run_default_deliver(store, paths, attempt_dir, product_path)
        elif phase in _DEFAULT_ROLE_BY_PHASE:
            from . import defaults  # local: defaults.py calls back into resolve_role
            code = defaults.run_lead_phase(phase, _DEFAULT_ROLE_BY_PHASE[phase], attempt_dir / "context.json", product_path)
        else:
            raise LoopSpecError(f"no default implementation for {phase}", repair='bind "external" in .loop-spec/config.json')
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
