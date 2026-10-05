"""The phase stream monitors read, in 7.x's exact format.

A run's phase is derived from its files (`runs.Run.phase`); this module records which
phase the stream last announced and, whenever the derived phase differs, announces the
change the way 7.x did:

    LOOP_SPEC_PHASE_END {"attemptId":...,"elapsedSeconds":...,"event":"phase_end","headSha":...,
                         "next":"plan","phase":"spec","timestamp":...,"verdict":"advanced"}
    LOOP_SPEC_PHASE_START {"attemptId":...,"event":"phase_start","phase":"plan","timestamp":...}
    [PLAN] plan attempt attempt-...              (and "[SPEC] spec approved -> plan")

Markers go to stdout; the `[PHASE]` lines to stderr, or stdout under Cloud Run or
LOOP_SPEC_CONSOLE_STREAM=stdout, and not at all under LOOP_SPEC_CONSOLE_EVENTS=0. Every
record is also appended to `events.jsonl`, in the run's directory and in 7.x's state home
(see legacy.py). Moving forward past several phases
at once announces each one in order, so every run shows SPEC, PLAN, EXECUTE, VERIFY,
ITERATE, and DELIVER.
"""
import json
import os
import secrets
from datetime import datetime, timezone
from pathlib import Path

from loop_spec import legacy, log

ORDER = ("spec", "plan", "execute", "verify", "iterate", "deliver")
FORWARD = {"spec": "approved", "plan": "ready", "execute": "integrated", "verify": "passed",
           "iterate": "converged", "deliver": "delivered"}
BACKWARD = {"plan": "spec gap", "execute": "plan gap", "verify": "implementation gap", "iterate": "rewind",
            "deliver": "base moved"}
TERMINAL = {"converged": "delivered", "converged-with-caveats": "delivered", "no-change": "no change",
            "escalated": "escalated", "failed": "failed"}


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _compact(payload: dict) -> str:
    return json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def _record(run, event: str, phase: str | None, attempt: str | None, data: dict) -> None:
    line = json.dumps({"event": event, "timestamp": _now(), "phase": phase, "attemptId": attempt,
                       "source": "program", "data": data}, sort_keys=True, ensure_ascii=False) + "\n"
    for directory in (run.dir, legacy.run_dir(run)):
        directory.mkdir(parents=True, exist_ok=True)
        with open(directory / "events.jsonl", "a") as f:
            f.write(line)


def result(run, record: dict, path) -> None:
    """Announce the run's result as 7.x did: the record, then where it is written."""
    log.stdout.info(f"LOOP_SPEC_RESULT {_compact(record)}")
    _record(run, "result", record.get("phaseReached"), None, record)
    program = Path(__file__).resolve().parents[1] / "loop-spec"
    log.stdout.info("LOOP_SPEC_NEXT " + _compact({
        "kind": "result", "path": str(path), "slug": run.slug, "program": str(program),
        "stateHome": str(legacy.state_home()), "projectRoot": str(run.project)}))


def _console(phase: str, summary: str) -> None:
    if os.environ.get("LOOP_SPEC_CONSOLE_EVENTS", "") == "0":
        return
    stream = os.environ.get("LOOP_SPEC_CONSOLE_STREAM", "")
    if stream not in ("stdout", "stderr"):
        stream = "stdout" if (os.environ.get("CLOUD_RUN_JOB") or os.environ.get("K_SERVICE")) else "stderr"
    (log.stdout if stream == "stdout" else log.stderr).info(f"[{phase.upper()}] {summary}")


def _start(run, phase: str) -> None:
    attempt = f"attempt-{secrets.token_hex(6)}"
    payload = {"event": "phase_start", "attemptId": attempt, "phase": phase, "timestamp": _now()}
    log.stdout.info(f"LOOP_SPEC_PHASE_START {_compact(payload)}")
    _record(run, "phase_start", phase, attempt, payload)
    _console(phase, f"{phase} attempt {attempt}")
    run.state["phaseStream"] = {"phase": phase, "attemptId": attempt, "startedAt": datetime.now(timezone.utc).timestamp()}


def _end(run, exit_: str, verdict: str, next_phase: str | None, head: str | None) -> None:
    current = run.state["phaseStream"]
    phase, attempt = current["phase"], current["attemptId"]
    elapsed = round(datetime.now(timezone.utc).timestamp() - current.get("startedAt", 0), 1)
    if isinstance(head, dict):  # a workspace's heads, as one string for hosts that read 7.x's headSha
        head = ",".join(f"{n}@{h}" for n, h in sorted(head.items()))
    payload = {"event": "phase_end", "attemptId": attempt, "phase": phase, "timestamp": _now(), "verdict": verdict,
               "next": next_phase, "elapsedSeconds": elapsed, "headSha": head}
    log.stdout.info(f"LOOP_SPEC_PHASE_END {_compact(payload)}")
    _record(run, "phase_end", phase, attempt, payload)
    summary = f"{phase} {exit_} -> {next_phase or 'terminal'}"
    _console(phase, summary)
    _record(run, "transition", phase, attempt, {"summary": summary})
    run.state["phaseStream"] = {"phase": None}


def sync(run, head: str | None) -> None:
    """Announce every phase change since the stream last spoke, then save the run."""
    target = run.phase(head)
    stream = run.state.get("phaseStream") or {"phase": None}
    if stream.get("phase") is None and target != "done" and not stream.get("ended"):
        _start(run, "spec")
    current = run.state["phaseStream"].get("phase")
    if target == "done":
        if current is not None:
            result = (run.result or {}).get("result", "converged")
            _end(run, TERMINAL.get(result, result), "completed", None, head)
            run.state["phaseStream"]["ended"] = True
    elif current != target:
        if ORDER.index(target) > ORDER.index(current):
            while current != target:
                following = ORDER[ORDER.index(current) + 1]
                _end(run, FORWARD[current], "advanced", following, head)
                _start(run, following)
                current = following
        else:
            _end(run, BACKWARD[current], "rewind", target, head)
            run.state["rewinds"] = run.state.get("rewinds", 0) + 1
            _start(run, target)
    run.save()
