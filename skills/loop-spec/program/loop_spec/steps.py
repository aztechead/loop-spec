"""Issue, submit, and retire steps: the process-contract handoff to a worker.

Use `issue` when a phase implementation's exit 2 needs a step registered with an id,
`submit` to consume the worker's result and decide its evidence level, and
`retire`/`confirm_terminated` when a step is abandoned rather than completed. This
module records facts (a result arrived, it matched its schema, its evidence level)
and never decides what the program does with them next.
"""
import json
from dataclasses import dataclass
from pathlib import Path

from loop_spec.contract import unattested_policy
from loop_spec.errors import LoopSpecError
from loop_spec.events import emit
from loop_spec.ids import digest_bytes, new_id, now_iso
from loop_spec.jsonio import atomic_write_json, read_json
from loop_spec.paths import ensure_results_dir
from loop_spec.postconditions import retry_limit
from loop_spec.repo import remove_worktree
from loop_spec.schema import validate, validate_or_raise

# The step contract between a phase adapter and the core: what an adapter's
# step()/run() returns. contract.invoke turns each into its on-disk file.

class IssueStep:
    __slots__ = ("request",)

    def __init__(self, request: dict) -> None:
        self.request = request


class IssueSteps:
    """Two or more requests from the SAME wave, for the lead to dispatch in
    parallel (step() falls back to the single-request IssueStep when a wave
    only ever has one request to issue, so every other module's step() and
    every existing test of it are unaffected)."""
    __slots__ = ("requests",)

    def __init__(self, requests: list[dict]) -> None:
        self.requests = requests


class Wait:
    """Nothing new to issue this call, but the wave is not done: one or more of
    its tasks already have a step open (implementing/reviewing) from an earlier
    call in this same wave. `open` names those steps' ids so the caller knows
    what it is waiting on rather than being told to start something new."""
    __slots__ = ("open",)

    def __init__(self, open: list[str]) -> None:
        self.open = open


class Product:
    __slots__ = ("product",)

    def __init__(self, product: dict) -> None:
        self.product = product


class Pause:
    __slots__ = ("question_request",)

    def __init__(self, question_request: dict) -> None:
        self.question_request = question_request


# The verifier and debugger are re-run by the program itself (V4, B1), and the
# implementer's evidence is its own review; these three roles are pure judgment
# with nothing behind them but the transcript, so an unattested submission for
# one of them is refused rather than silently accepted.
ATTESTATION_REQUIRED_ROLES = frozenset({"plan-critic", "code-reviewer", "iterate-judge"})
ACCEPTED_LEVELS = frozenset({"host-attested", "controller-observed", "human-attested"})

# LF-61: the most rendered bytes (`n<TAB>line<LF>`, UTF-8) one scheduled Read covers.
# Provisional and empirical, not a proven token bound: on Claude Code 2.1.280, 16,000
# bytes of hex diff measured about 8,900 of the Read tool's 25,000-token cap (probe-lf61),
# and the recovery rules below cover a host that counts differently.
READ_BUDGET_BYTES = 16_000

# LF-59/61: the whole Agent prompt for a role step. attest.check_file_receipt requires the
# worker's opening to equal it and the worker's first actions to be Reads covering
# every line of the instruction file; the schedule only makes that easy to do.
_DISPATCH_PROMPT = (
    "Execute loop-spec step {step_id}.\n"
    "The instruction file {path} has {lines} lines. Before any other action, make these calls to the Read tool, in order, "
    "each with exactly this file_path and the offset and limit shown:\n"
    "{calls}\n"
    "If a read returns fewer lines than its limit, read again from the line after the last line it returned "
    "up to the end of that same listed range, then go on. If a read is refused as too large, read only the first "
    "half of the lines left in that range (at least one line), then continue the same way up to the end of that range. "
    "If a one-line read is refused, returns no line, or returns its line cut short, stop: report that the "
    "instruction file could not be read, and write no result.\n"
    "Do not use any other tool, and do not skip, sample or summarize any range, until you have read every line "
    "from 1 to {lines}.\n"
    "Then follow that file; it names where to write your result."
)


def read_schedule(prompt: str, budget: int = READ_BUDGET_BYTES) -> list[dict]:
    """LF-61: contiguous Read ranges covering every line of `prompt` once, in order,
    each rendering to at most `budget` bytes. A line that alone exceeds the budget
    raises: it is over the supported read budget (not proof the host cannot read it)."""
    lines = prompt.split("\n")  # a prompt ending in LF ends with its empty last line
    ranges, start, size = [], 1, 0
    for number, line in enumerate(lines, 1):
        rendered = len(f"{number}\t{line}\n".encode("utf-8"))
        if rendered > budget:
            raise LoopSpecError(
                f"line {number} of the composed prompt renders to {rendered} bytes, over the supported "
                f"{budget}-byte read budget",
                repair="shorten the input that produced that line (for example a minified or generated file in "
                       "a diff); the program does not truncate, split or summarize a prompt line")
        if size + rendered > budget:
            ranges.append({"offset": start, "limit": number - start})
            start, size = number, 0
        size += rendered
    ranges.append({"offset": start, "limit": len(lines) - start + 1})
    return ranges


_STEP_TRAILER = """
--- loop-spec step ---
step: {step_id}
inputs: {inputs_digest}
phase: {phase}
result: {result_path}
When done, write your JSON result to the result path above (write to a temporary file in the same directory and rename). The result file carries your findings, so keep your final message to a sentence or two, then end it with the line `LOOP_SPEC_RESULT_DIGEST <sha256:hex of the result file bytes>`."""


def issue(store, paths, *, phase: str, attempt_id: str, kind: str, role: str | None, cwd: Path,
          prompt: str, schema: dict, postconditions: list[str], inputs_digest: str,
          retry_of: str | None = None, reason: str | None = None, result_path: Path | None = None,
          model: str | None = None) -> dict:
    step_id = new_id("step")
    step_dir = paths.steps_dir / step_id
    # A phase's own step (an external/lead/role implementation producing that
    # phase's product) must land its result exactly where contract.invoke checks
    # for it (attempts/<id>/product.json), not at the auto-generated path below;
    # the caller passes that path in. Every other step (the PLAN critic, a future
    # per-task EXECUTE/VERIFY step) is content with its own file under results_dir
    # (LF-27: under the project root, not the state home a live model cannot
    # always write to).
    if result_path is not None:
        result_path = Path(result_path)
    else:
        ensure_results_dir(paths)
        result_path = paths.results_dir / f"{step_id}.json"
    issued_at = now_iso()

    full_prompt = prompt + _STEP_TRAILER.format(
        step_id=step_id, inputs_digest=inputs_digest, phase=phase, result_path=str(result_path),
    )
    record = {
        "stepAttemptId": step_id, "kind": kind, "role": role, "phase": phase, "cwd": str(cwd),
        "prompt": full_prompt, "resultPath": str(result_path), "schema": schema,
        "postconditions": postconditions, "attempt": attempt_id, "inputsDigest": inputs_digest,
        "issuedAt": issued_at, "retryOf": retry_of, "reason": reason, "model": model,
    }
    if kind == "role":
        # LF-59: a lead re-typing a long prompt into the Agent call changed it in
        # transit (LF-56, LF-57). A role worker instead gets a short fixed bootstrap
        # and reads the prompt from a file the program wrote; step.prompt stays the
        # authority, ends in exactly one LF (in both copies), and never holds a CR.
        if "\r" in full_prompt:
            raise LoopSpecError(f"step {step_id}'s composed prompt contains a carriage return",
                                repair="compose role prompts with LF line endings only")
        record["prompt"] = full_prompt = full_prompt + "\n"
        instruction_path = step_dir / "instructions.md"
        # LF-61: scheduled on the final prompt, before anything is written, so a
        # refusal leaves no step anyone could dispatch.
        try:
            schedule = read_schedule(full_prompt)
        except LoopSpecError as exc:
            raise LoopSpecError(f"{phase} {role} step not issued: {exc.message}", repair=exc.repair) from exc
        calls = "\n".join(f"{i}. offset={r['offset']} limit={r['limit']}" for i, r in enumerate(schedule, 1))
        record.update({"transport": "file", "instructionPath": str(instruction_path), "readSchedule": schedule,
                       "dispatchPrompt": _DISPATCH_PROMPT.format(step_id=step_id, path=instruction_path,
                                                                 lines=len(full_prompt.split("\n")), calls=calls)})
    validate_or_raise(record, "step")
    step_dir.mkdir(parents=True, exist_ok=True)
    if kind == "role":
        with open(record["instructionPath"], "w", encoding="utf-8", newline="") as f:
            f.write(full_prompt)
        with open(step_dir / "dispatch.txt", "w", encoding="utf-8", newline="") as f:
            f.write(record["dispatchPrompt"])
    atomic_write_json(step_dir / "step.json", record)

    store.state["steps"]["open"].append({
        "stepAttemptId": step_id, "phase": phase, "attempt": attempt_id, "kind": kind, "role": role,
        "cwd": str(cwd), "resultPath": str(result_path), "issuedAt": issued_at,
        "retryOf": retry_of, "retries": 0,
    })
    emit(paths, "step_issued", {"stepAttemptId": step_id, "summary": f"issued {step_id}"}, phase=phase, attempt_id=attempt_id, source="program")
    store.save()
    return record


@dataclass
class Submission:
    step: dict
    result: dict
    result_digest: str
    evidence_level: str
    redispatch: str | None = None
    refused: str | None = None  # LF-60: no accepted evidence and no opt-in; nothing was accepted


def _open_step_record(store, step_id: str) -> dict:
    return next((s for s in store.state["steps"]["open"] if s["stepAttemptId"] == step_id), None)


def record_waiver(store, step_id: str, role: str, policy: str, attempts: int | None = None) -> None:
    """LF-60: one weakened-assurance entry per step accepted unattested under `policy`."""
    waivers = store.state.setdefault("attestationWaivers", [])
    if not any(w.get("step") == step_id and w.get("policy") == policy for w in waivers):
        waivers.append({"kind": "evidence.unattested-step", "step": step_id, "role": role,
                        "attempts": attempts, "policy": policy, "source": "config"})


def evidence_accepted(store, project_root, step_id: str | None, role: str) -> bool:
    """LF-60: whether a judgment recorded from `step_id` may still be consumed: its
    submission's level is accepted, or config opts `role` in (recorded as a waiver).
    Missing provenance (no step id, no submission) is never accepted evidence."""
    submission = store.state["steps"]["submissions"].get(step_id) if step_id else None
    if submission is None:
        return False
    if submission["evidenceLevel"] in ACCEPTED_LEVELS:
        return True
    policy = unattested_policy(project_root, role)
    if policy is None:
        return False
    record_waiver(store, step_id, role, policy)
    return True


def submit(store, paths, *, step_id: str, dispatch_name: str | None, host,
           result_file: str | Path | None = None, project_root: Path | None = None) -> Submission:
    step_path = paths.steps_dir / step_id / "step.json"
    if not step_path.is_file():
        raise LoopSpecError(f"no open step {step_id}", repair="check `loop-spec status` for the open step id")
    step = read_json(step_path)
    # A worker may write its result somewhere the program's own resultPath is not
    # writable (a host that denies writes under the state home); --result-file
    # points submit at those bytes instead. Validation, digest, and the submission
    # record below are unchanged either way.
    result_path = Path(result_file) if result_file is not None else Path(step["resultPath"])

    # A replay of an already-accepted submission (IT-03) must be checked before the
    # "retired" refusal below: a successful submit() moves the step to retired, so a
    # step id that IS in `retired` is exactly the id a replay call passes.
    existing = store.state["steps"]["submissions"].get(step_id)
    if existing is not None:
        if not result_path.is_file():
            raise LoopSpecError(f"no result at {result_path}", repair="the worker must write it before submit")
        result = read_json(result_path)
        result_digest = digest_bytes(result_path.read_bytes())
        if existing["digest"] == result_digest:
            return Submission(step=step, result=result, result_digest=result_digest, evidence_level=existing["evidenceLevel"])
        raise LoopSpecError(
            f"a different result was already submitted for {step_id}",
            repair="check `loop-spec status`; the step may need a new attempt",
        )

    if step_id in store.state["steps"]["retired"]:
        raise LoopSpecError(
            f"step {step_id} is retired; a new attempt was issued",
            repair="check `loop-spec status` for the current step",
        )
    open_record = _open_step_record(store, step_id)
    if open_record is None:
        raise LoopSpecError(f"no open step {step_id}", repair="check `loop-spec status` for the open step id")

    if not result_path.is_file():
        raise LoopSpecError(f"no result at {result_path}", repair="the worker must write it before submit")
    try:
        result = read_json(result_path)
    except json.JSONDecodeError as exc:
        raise LoopSpecError(
            "result is not valid JSON; the worker must write to a temp file and rename",
            repair=f"inspect {result_path}",
        ) from exc

    errors = validate(result, step["schema"])
    if errors:
        # The step is NOT retired here: the caller may re-issue with the reason,
        # which needs the step to still be open to retry against.
        raise LoopSpecError("; ".join(errors), repair=f"fix the listed fields in {result_path} and re-issue the step")

    result_bytes = result_path.read_bytes()
    result_digest = digest_bytes(result_bytes)
    # R2: under the state home (never beside result_path, which a worker/result
    # author can write to), and only trusted when this run's own state says an
    # SDK session actually launched it -- a receipt's mere presence, in the old
    # worker-writable location, was accepted as proof by itself.
    receipt_path = paths.steps_dir / step_id / "receipt.json"

    attestation = None
    if step["kind"] == "external":
        evidence_level = "human-attested"
    elif store.state["run"].get("runner") == "sdk" and receipt_path.is_file():
        # sdk_runner.run_step_sdk wrote this: this process itself watched the SDK
        # session end successfully, so "controller-observed" needs no host at
        # all, only a receipt that actually names this submission.
        try:
            receipt = read_json(receipt_path)
        except json.JSONDecodeError:
            receipt = {}
        if receipt.get("stepAttemptId") == step_id and receipt.get("resultDigest") == result_digest:
            evidence_level = "controller-observed"
            attestation = {"ok": True, "kind": "sdk-receipt", "sessionId": receipt.get("sessionId")}
        else:
            evidence_level = "unattested"
            attestation = {"ok": False, "reason": "sdk receipt digest mismatch"}
    elif host is None or dispatch_name is None:
        evidence_level = "unattested"
    else:
        ok, reason_text = host.attest(step, result_digest, dispatch_name)
        evidence_level = "host-attested" if ok else "unattested"
        attestation = {"ok": ok, "reason": reason_text}

    if step["kind"] == "role" and step["role"] in ATTESTATION_REQUIRED_ROLES and evidence_level == "unattested":
        reason_text = attestation["reason"] if attestation else ("no dispatch name given" if host is not None else "no host attestor")
        attempts = open_record.get("attestationAttempts", 0) + 1
        open_record["attestationAttempts"] = attempts
        open_record["reason"] = reason_text
        step["attestationAttempts"] = attempts
        step["reason"] = reason_text
        atomic_write_json(step_path, step)
        limit = retry_limit()
        # Only a host can attest a fresh dispatch; an SDK receipt mismatch or no host
        # at all goes straight to the policy below.
        if host is not None and not receipt_path.is_file() and attempts <= limit:
            redispatch = f"{step_id}-{attempts + 1}"
            emit(paths, "step_redispatch", {
                "stepAttemptId": step_id, "attempt": attempts, "dispatch": redispatch, "reason": reason_text,
                "summary": f"{step_id} unattested ({attempts}/{limit}): re-dispatch as {redispatch}",
            }, phase=step["phase"], attempt_id=step["attempt"], source="program")
            store.save()
            return Submission(step=step, result=result, result_digest=result_digest,
                               evidence_level=evidence_level, redispatch=redispatch)
        policy = unattested_policy(project_root, step["role"])
        if policy is None:
            # LF-60: missing evidence is never itself a reason to accept. The result is
            # kept only as a diagnostic; retiring the step and recording the refusal is
            # one state write, so a resume always finds both or neither.
            diagnostic = paths.steps_dir / step_id / "refused-result.json"
            diagnostic.write_bytes(result_bytes)
            retire(store, paths, step_id=step_id, reason=f"refused: {reason_text}", save=False)
            store.state["steps"].setdefault("refused", {})[step_id] = {
                "role": step["role"], "phase": step["phase"], "cwd": step["cwd"], "reason": reason_text,
                "attempts": attempts, "at": now_iso(), "questionId": None, "ownerReset": False,
            }
            emit(paths, "step_refused", {"stepAttemptId": step_id, "reason": reason_text,
                                         "summary": f"{step_id} ({step['role']}) refused: {reason_text}"},
                 phase=step["phase"], attempt_id=step["attempt"], source="program")
            store.save()
            return Submission(step=step, result=result, result_digest=result_digest,
                               evidence_level=evidence_level, refused=reason_text)
        record_waiver(store, step_id, step["role"], policy, attempts)

    # LF-27: results_dir (or --result-file) holds the model's own copy; the state
    # home keeps its own beside step.json as the durable record, from the exact
    # bytes just read and digested, not a second read of a path that could move.
    record_path = paths.steps_dir / step_id / "result.json"
    record_path.parent.mkdir(parents=True, exist_ok=True)
    record_path.write_bytes(result_bytes)
    store.state["steps"]["submissions"][step_id] = {
        "digest": result_digest, "evidenceLevel": evidence_level, "attestation": attestation,
        "submittedAt": now_iso(), "dispatch": dispatch_name,
    }
    store.state["steps"]["open"] = [s for s in store.state["steps"]["open"] if s["stepAttemptId"] != step_id]
    store.state["steps"]["retired"].append(step_id)
    emit(paths, "step_accepted", {"stepAttemptId": step_id, "summary": f"{step_id} {evidence_level}"},
         phase=step["phase"], attempt_id=step["attempt"], source="program")
    store.save()
    return Submission(step=step, result=result, result_digest=result_digest, evidence_level=evidence_level)


def retire(store, paths, *, step_id: str, reason: str, save: bool = True) -> None:
    record = _open_step_record(store, step_id)
    if record is None:
        raise LoopSpecError(f"no open step {step_id}", repair="check `loop-spec status` for the open step id")

    store.state["steps"]["open"] = [s for s in store.state["steps"]["open"] if s["stepAttemptId"] != step_id]
    store.state["steps"]["retired"].append(step_id)

    cwd = Path(record["cwd"])
    if cwd.is_relative_to(paths.worktrees_dir) or cwd.is_relative_to(paths.checkouts_dir):
        # Roadmap 5: expiry never deletes on its own; the worktree (or a review
        # checkout, LF-60) waits here until the host confirms the dispatch actually
        # ended (confirm_terminated). A re-issued step gets a fresh path instead.
        store.state["steps"]["quarantined"].append({
            "stepAttemptId": step_id, "path": str(cwd), "reason": reason, "at": now_iso(),
        })
    if save:
        store.save()


def confirm_terminated(store, paths, *, step_id: str, repo: Path) -> None:
    quarantined = store.state["steps"]["quarantined"]
    entry = next((q for q in quarantined if q["stepAttemptId"] == step_id), None)
    if entry is None:
        raise LoopSpecError(f"no quarantined step {step_id}", repair="check `loop-spec status`")

    store.state["steps"]["quarantined"] = [q for q in quarantined if q["stepAttemptId"] != step_id]
    # LF-51/8A: the operator's confirmation is the evidence writers_known_terminated
    # looks for on a step whose submission was never attested; record it regardless
    # of what happens to the worktree below.
    store.state["steps"].setdefault("terminated", []).append(step_id)
    # Termination being known is not the same as "safe to force-delete" -- an
    # uncommitted edit sitting in the worktree is still real work. Remove without
    # --force; a dirty tree makes git refuse, and the path goes to cleanupBacklog
    # (files intact) instead.
    try:
        remove_worktree(repo, Path(entry["path"]))
    except LoopSpecError:
        store.state.setdefault("cleanupBacklog", []).append({"path": entry["path"], "reason": "uncommitted changes"})
    store.save()


def writers_known_terminated(store, paths, path) -> bool:
    """True only when every step that ever ran in `path` ended with evidence: a
    host- or human-attested submission, or an operator confirm_terminated. An open
    step, an unattested submission, or a quarantine entry there means unknown."""
    resolved = str(Path(path).resolve())
    if any(Path(s["cwd"]).resolve() == Path(resolved) for s in store.state["steps"]["open"]):
        return False
    if any(Path(q["path"]).resolve() == Path(resolved) for q in store.state["steps"]["quarantined"]):
        return False
    terminated = store.state["steps"].setdefault("terminated", [])
    submissions = store.state["steps"]["submissions"]
    for step_id in store.state["steps"]["retired"]:
        step_path = paths.steps_dir / step_id / "step.json"
        if not step_path.is_file():
            continue
        record = read_json(step_path)
        if Path(record["cwd"]).resolve() != Path(resolved):
            continue
        submission = submissions.get(step_id, {})
        if submission.get("evidenceLevel") in ("host-attested", "human-attested"):
            continue
        if step_id in terminated:
            continue
        return False
    return True
