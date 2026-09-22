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

from .errors import LoopSpecError
from .events import emit
from .ids import digest_bytes, new_id, now_iso
from .jsonio import atomic_write_json, read_json
from .paths import ensure_results_dir
from .postconditions import retry_limit
from .repo import remove_worktree
from .schema import validate, validate_or_raise

# The verifier and debugger are re-run by the program itself (V4, B1), and the
# implementer's evidence is its own review; these three roles are pure judgment
# with nothing behind them but the transcript, so an unattested submission for
# one of them is refused rather than silently accepted.
ATTESTATION_REQUIRED_ROLES = frozenset({"plan-critic", "code-reviewer", "iterate-judge"})

_STEP_TRAILER = """
--- loop-spec step ---
step: {step_id}
inputs: {inputs_digest}
phase: {phase}
result: {result_path}
When done, write your JSON result to the result path above (write to a temporary file in the same directory and rename), then end your final message with the line `LOOP_SPEC_RESULT_DIGEST <sha256:hex of the result file bytes>`."""


def issue(store, paths, *, phase: str, attempt_id: str, kind: str, role: str | None, cwd: Path,
          prompt: str, schema: dict, postconditions: list[str], inputs_digest: str,
          retry_of: str | None = None, reason: str | None = None, result_path: Path | None = None) -> dict:
    step_id = new_id("step")
    step_dir = paths.steps_dir / step_id
    step_dir.mkdir(parents=True, exist_ok=True)
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
        "issuedAt": issued_at, "retryOf": retry_of, "reason": reason,
    }
    validate_or_raise(record, "step")
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


def _open_step_record(store, step_id: str) -> dict:
    return next((s for s in store.state["steps"]["open"] if s["stepAttemptId"] == step_id), None)


def submit(store, paths, *, step_id: str, dispatch_name: str | None, host,
           result_file: str | Path | None = None) -> Submission:
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
    # LF-27: results_dir (or --result-file) holds the model's own copy; the state
    # home keeps its own beside step.json as the durable record, from the exact
    # bytes just read and digested, not a second read of a path that could move.
    record_path = paths.steps_dir / step_id / "result.json"
    record_path.parent.mkdir(parents=True, exist_ok=True)
    record_path.write_bytes(result_bytes)
    receipt_path = result_path.with_name("sdk-receipt.json")

    attestation = None
    if step["kind"] == "external":
        evidence_level = "human-attested"
    elif receipt_path.is_file():
        # sdk_runner.run_step_sdk wrote this beside the result: this process
        # itself watched the SDK session end successfully, so "controller-observed"
        # needs no host at all, only a receipt that actually names this submission.
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

    if (step["kind"] == "role" and step["role"] in ATTESTATION_REQUIRED_ROLES
            and host is not None and evidence_level == "unattested" and not receipt_path.is_file()):
        reason_text = attestation["reason"] if attestation else "no dispatch name given"
        attempts = open_record.get("attestationAttempts", 0) + 1
        open_record["attestationAttempts"] = attempts
        open_record["reason"] = reason_text
        step["attestationAttempts"] = attempts
        step["reason"] = reason_text
        atomic_write_json(step_path, step)
        limit = retry_limit()
        if attempts <= limit:
            redispatch = f"{step_id}-{attempts + 1}"
            emit(paths, "step_redispatch", {
                "stepAttemptId": step_id, "attempt": attempts, "dispatch": redispatch, "reason": reason_text,
                "summary": f"{step_id} unattested ({attempts}/{limit}): re-dispatch as {redispatch}",
            }, phase=step["phase"], attempt_id=step["attempt"], source="program")
            store.save()
            return Submission(step=step, result=result, result_digest=result_digest,
                               evidence_level=evidence_level, redispatch=redispatch)
        store.state.setdefault("attestationWaivers", []).append(
            {"kind": "evidence.unattested-step", "step": step_id, "role": step["role"], "attempts": attempts}
        )

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


def retire(store, paths, *, step_id: str, reason: str) -> None:
    record = _open_step_record(store, step_id)
    if record is None:
        raise LoopSpecError(f"no open step {step_id}", repair="check `loop-spec status` for the open step id")

    store.state["steps"]["open"] = [s for s in store.state["steps"]["open"] if s["stepAttemptId"] != step_id]
    store.state["steps"]["retired"].append(step_id)

    cwd = Path(record["cwd"])
    if cwd.is_relative_to(paths.worktrees_dir):
        # Roadmap 5: expiry never deletes on its own; the worktree waits here until
        # the host confirms the dispatch actually ended (confirm_terminated).
        store.state["steps"]["quarantined"].append({
            "stepAttemptId": step_id, "path": str(cwd), "reason": reason, "at": now_iso(),
        })
    store.save()


def confirm_terminated(store, paths, *, step_id: str, repo: Path) -> None:
    quarantined = store.state["steps"]["quarantined"]
    entry = next((q for q in quarantined if q["stepAttemptId"] == step_id), None)
    if entry is None:
        raise LoopSpecError(f"no quarantined step {step_id}", repair="check `loop-spec status`")

    store.state["steps"]["quarantined"] = [q for q in quarantined if q["stepAttemptId"] != step_id]
    remove_worktree(repo, Path(entry["path"]), force=True)
    store.save()
