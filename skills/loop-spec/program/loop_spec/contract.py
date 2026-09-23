"""Invoke a phase implementation under the process contract, exit codes 0-4.

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

from loop_spec import external
from loop_spec.errors import LoopSpecError
from loop_spec.jsonio import atomic_write_json, read_json
from loop_spec.schema import load_schema, validate, validate_or_raise

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
    kind: Literal["product", "error", "step", "steps", "wait", "question"]
    path: Path | None
    stderr: str


# LF-60: which config key lets an unattested submission of each judgment role count.
# One key per role family, so opting reviews in never weakens the critic or judge.
_UNATTESTED_POLICY = {"code-reviewer": "review", "plan-critic": "judgment", "iterate-judge": "judgment"}


def load_config(project_root: Path) -> dict:
    path = Path(project_root) / ".loop-spec" / "config.json"
    if not path.is_file():
        return {}
    config = read_json(path)
    for family in ("review", "judgment"):
        value = (config.get("evidence") or {}).get(family, {}).get("accept")
        if value is not None and value != "unattested":
            raise LoopSpecError(f"{path}: evidence.{family}.accept is {value!r}; the only value is \"unattested\"",
                                repair=f"set evidence.{family}.accept to \"unattested\" or remove it")
    accept = (config.get("deliver") or {}).get("acceptRemotePaths")
    if accept is not None and not (isinstance(accept, list) and all(isinstance(g, str) and g for g in accept)):
        raise LoopSpecError(f"{path}: deliver.acceptRemotePaths is {accept!r}; it is a list of path globs",
                            repair='set it to a list such as ["CHANGELOG.md"], or remove it')
    return config


def unattested_policy(project_root: Path | None, role: str) -> str | None:
    """The config key that lets `role`'s unattested evidence count, when it is set."""
    family = _UNATTESTED_POLICY.get(role)
    if project_root is None or family is None:
        return None
    accept = (load_config(project_root).get("evidence") or {}).get(family, {}).get("accept")
    return f"evidence.{family}.accept" if accept == "unattested" else None


def resolve_implementation(project_root: Path, phase: str) -> str:
    env = os.environ.get(f"LOOP_SPEC_PHASE_{phase.upper()}")
    if env:
        return env
    return load_config(project_root).get("phases", {}).get(phase, "default")


def resolve_role(project_root: Path, role: str) -> str:
    env = os.environ.get(f"LOOP_SPEC_ROLE_{role.upper()}")
    if env:
        return env
    configured = load_config(project_root).get("roles", {}).get(role, "default")
    # roles.<role> is normally the binding string itself; roles.resolve_model
    # (which this module cannot import without a cycle) reads the same config
    # to also allow an object form ({"binding": ..., "model": ...}) so a project
    # can set a role's model without forcing a bound skill.
    return configured.get("binding", "default") if isinstance(configured, dict) else configured


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


def _accept_product(phase: str, implementation: str, product_path: Path) -> PhaseOutcome:
    if not product_path.is_file():
        return PhaseOutcome(code=0, kind="error", path=None, stderr=f"exit 0 but no product at {product_path}")
    errors = validate(read_json(product_path), load_schema(phase))
    if errors:
        # LF-25: name which implementation and phase produced the invalid product,
        # not just the schema errors -- otherwise a reader debugging a "failed" run
        # blames the validator or the phase itself instead of the implementation that
        # actually wrote the bad file (most often the program's own default one).
        stderr = f"{implementation} {phase.upper()} implementation produced an invalid product: " + "; ".join(errors)
        return PhaseOutcome(code=0, kind="error", path=None, stderr=stderr)
    return PhaseOutcome(code=0, kind="product", path=product_path, stderr="")


def _accept_request(path: Path, kind: str, code: int) -> PhaseOutcome:
    if not path.is_file():
        return PhaseOutcome(code=code, kind="error", path=None, stderr=f"exit {code} but no {kind} request at {path}")
    errors = validate_request(kind, read_json(path))
    if errors:
        return PhaseOutcome(code=code, kind="error", path=None, stderr="; ".join(errors))
    return PhaseOutcome(code=code, kind=kind, path=path, stderr="")


def _accept_requests(path: Path, code: int) -> PhaseOutcome:
    # A wave's several step requests at once (execute.py's IssueSteps): same
    # per-request "step" schema as _accept_request, just one list instead of
    # one file, so a bad request among several is named by its position.
    if not path.is_file():
        return PhaseOutcome(code=code, kind="error", path=None, stderr=f"exit {code} but no step requests at {path}")
    requests = read_json(path)
    if not isinstance(requests, list) or not requests:
        return PhaseOutcome(code=code, kind="error", path=None, stderr=f"{path} must be a non-empty JSON list of step requests")
    for i, request in enumerate(requests):
        errors = validate_request("step", request)
        if errors:
            return PhaseOutcome(code=code, kind="error", path=None, stderr=f"step request {i}: " + "; ".join(errors))
    return PhaseOutcome(code=code, kind="steps", path=path, stderr="")


def _accept_wait(path: Path, code: int) -> PhaseOutcome:
    if not path.is_file():
        return PhaseOutcome(code=code, kind="error", path=None, stderr=f"exit {code} but no wait request at {path}")
    data = read_json(path)
    if not isinstance(data, dict) or not isinstance(data.get("open"), list) or not all(isinstance(s, str) for s in data["open"]):
        return PhaseOutcome(code=code, kind="error", path=None, stderr=f"{path} must be a JSON object with an 'open' list of step ids")
    return PhaseOutcome(code=code, kind="wait", path=path, stderr="")


# The two phases with a default lead-run implementation (spec-writer, planner) and
# the five with a default step()/on_submit() implementation (execute.py's own
# pattern, reused by verify/iterate/debug/revise).
_DEFAULT_ROLE_BY_PHASE = {"spec": "spec-writer", "plan": "planner"}
_DEFAULT_STEPPED_MODULE_BY_PHASE = {"execute", "verify", "iterate", "debug", "revise"}


# R1: a wave module's request shape can change call to call within the SAME attempt
# (a multi-task IssueSteps wave collapsing to one IssueStep, or back) -- the file a
# PRIOR call wrote for the shape it had then must not survive to be misread as this
# call's answer, and invoke() below must not infer the shape from which of these
# files happens to exist (that inference is exactly what let a stale steps.json
# shadow a fresh step.json).
_STEP_SHAPE_FILES = ("step.json", "steps.json", "wait.json")


def _run_default_stepped(module, store, paths, attempt_dir: Path, product_path: Path) -> tuple[int, str | None]:
    # execute.py/verify.py/iterate.py/debug.py's step()/on_submit() need the live
    # StateStore (they carry per-task or per-pass progress across calls in
    # store.state[<phase>]), unlike run_lead_phase's context.json/product.json-only
    # contract, so this dispatcher stays here rather than in each module (their own
    # docstrings say wiring them in is not their job). All four import IssueStep/
    # Product/Pause from execute.py, so one isinstance check covers every module.
    from loop_spec import execute as execute_module
    ctx = read_json(attempt_dir / "context.json")
    outcome = module.step(store, paths, ctx)
    for name in _STEP_SHAPE_FILES:
        (attempt_dir / name).unlink(missing_ok=True)
    if isinstance(outcome, execute_module.Product):
        atomic_write_json(product_path, outcome.product)
        return 0, "product"
    if isinstance(outcome, execute_module.IssueSteps):
        atomic_write_json(attempt_dir / "steps.json", outcome.requests)
        return 2, "steps"
    if isinstance(outcome, execute_module.IssueStep):
        atomic_write_json(attempt_dir / "step.json", outcome.request)
        return 2, "step"
    if isinstance(outcome, execute_module.Wait):
        atomic_write_json(attempt_dir / "wait.json", {"open": outcome.open})
        return 4, "wait"
    atomic_write_json(attempt_dir / "question.json", outcome.question_request)
    return 3, "question"


def _run_default_deliver(store, paths, attempt_dir: Path, product_path: Path) -> int:
    # deliver.py's run() dispatches no worker step: one pass returns a Product or a
    # Pause, never an IssueStep (its own docstring: an out-of-band remote move maps
    # to a "delivery blocked" product exit, not a raw pause -- no scenario uses Pause
    # today, but the branch stays so a future one need not touch this dispatcher).
    from loop_spec import deliver as deliver_module
    from loop_spec import execute as execute_module
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
    # Set only by _run_default_stepped, the one producer that can write either
    # "step.json" or "steps.json" from the same attempt across calls (R1); every
    # other path (external, defaults.py) only ever writes "step.json", so leaving
    # this None for them and falling through to that fixed path below is correct,
    # not an inference.
    stepped_kind: str | None = None

    if implementation == "default":
        if phase in _DEFAULT_STEPPED_MODULE_BY_PHASE:
            if store is None:
                raise LoopSpecError(f"{phase}'s default implementation needs the live state store",
                                     repair="call contract.invoke(..., store=store) from the controller")
            from loop_spec import debug as debug_module
            from loop_spec import execute as execute_module
            from loop_spec import iterate as iterate_module
            from loop_spec import revise as revise_module
            from loop_spec import verify as verify_module
            module = {"execute": execute_module, "verify": verify_module, "iterate": iterate_module,
                      "debug": debug_module, "revise": revise_module}[phase]
            code, stepped_kind = _run_default_stepped(module, store, paths, attempt_dir, product_path)
        elif phase == "deliver":
            if store is None:
                raise LoopSpecError("deliver's default implementation needs the live state store",
                                     repair="call contract.invoke(..., store=store) from the controller")
            code = _run_default_deliver(store, paths, attempt_dir, product_path)
        elif phase in _DEFAULT_ROLE_BY_PHASE:
            from loop_spec import defaults  # local: defaults.py calls back into resolve_role
            code = defaults.run_lead_phase(phase, _DEFAULT_ROLE_BY_PHASE[phase], attempt_dir / "context.json", product_path)
        else:
            raise LoopSpecError(f"no default implementation for {phase}", repair='bind "external" in .loop-spec/config.json')
    elif implementation == "external":
        code = run_phase(phase, attempt_dir / "context.json", product_path)
    else:
        # roadmap 5: a bound implementation is the default with its roles resolved to
        # other skills, not a third phase kind -- resolve_implementation only ever
        # reads "phases".<phase> from config, so any other value there is a mistake,
        # not a real binding, and the fix is in "roles", not "phases".
        raise LoopSpecError(
            f"phase {phase} implementation must be default or external; bind a method with roles.<role>",
            repair='set "phases".<phase> to "default" or "external" in .loop-spec/config.json, then bind a method under "roles"',
        )

    if code == 0:
        return _accept_product(phase, implementation, product_path)
    if code == 2:
        if stepped_kind == "steps":
            return _accept_requests(attempt_dir / "steps.json", code)
        return _accept_request(attempt_dir / "step.json", "step", code)
    if code == 3:
        return _accept_request(attempt_dir / "question.json", "question", code)
    if code == 4:
        return _accept_wait(attempt_dir / "wait.json", code)
    if code == 1:
        return PhaseOutcome(code=1, kind="error", path=None, stderr="implementation exited 1")
    return PhaseOutcome(code=code, kind="error", path=None, stderr=f"implementation exited {code}; only 0-4 advance")
