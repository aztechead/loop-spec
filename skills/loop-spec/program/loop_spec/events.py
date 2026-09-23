"""Progress events: the run's append-only ledger, console progress lines, and stdout markers.

Use `emit` for anything that should land in events.jsonl and print a one-line progress
update. Use the `marker_*` functions at the four points the controller and CLI hand
structured state back to whatever launched them (phase boundaries, a pending question,
a terminal result, "read this file next"); each also lands in the ledger so the JSONL
file is a complete history even for a caller that only reads stdout.
"""
import json
import os
import sys
from pathlib import Path

from loop_spec.errors import LoopSpecError
from loop_spec.ids import now_iso
from loop_spec.jsonio import append_jsonl, read_json
from loop_spec.paths import FeaturePaths

# The program reserves these names for its own lifecycle events; an implementation
# emitting one of them would let a phase impersonate a controller transition.
_RESERVED = {
    "phase_start", "phase_end", "step_accepted", "step_rejected",
    "transition", "result", "question", "approval",
}


def emit(paths: FeaturePaths, event: str, data: dict | None = None, *,
         phase: str | None = None, attempt_id: str | None = None, source: str = "program") -> dict:
    if source == "implementation" and event in _RESERVED:
        raise LoopSpecError(
            f"'{event}' is a reserved event name",
            repair="use a name other than " + ", ".join(sorted(_RESERVED)),
        )
    data = data or {}
    record = {
        "event": event, "timestamp": now_iso(), "phase": phase,
        "attemptId": attempt_id, "source": source, "data": data,
    }
    append_jsonl(paths.events_jsonl, record)
    if os.environ.get("LOOP_SPEC_CONSOLE_EVENTS", "") != "0":
        tag = phase.upper() if phase else "LOOP-SPEC"
        summary = data.get("summary", event)
        stream = os.environ.get("LOOP_SPEC_CONSOLE_STREAM", "")
        if stream not in ("stdout", "stderr"):
            # Cloud Run stamps CLOUD_RUN_JOB/K_SERVICE on jobs and services it runs, and
            # assigns stderr output ERROR severity there, so routine progress on stderr
            # would surface in Cloud Logging as a stream of errors (port of the same
            # precedence in lib/events.sh).
            stream = "stdout" if (os.environ.get("CLOUD_RUN_JOB") or os.environ.get("K_SERVICE")) else "stderr"
        print(f"[{tag}] {summary}", file=sys.stdout if stream == "stdout" else sys.stderr)
    return record


def _compact(payload: dict) -> str:
    return json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def _marker(paths: FeaturePaths, prefix: str, payload: dict) -> None:
    print(f"{prefix} {_compact(payload)}")
    append_jsonl(paths.events_jsonl, {
        "event": prefix[len("LOOP_SPEC_"):].lower(), "timestamp": now_iso(),
        "phase": payload.get("phase"), "attemptId": payload.get("attemptId"),
        "source": "program", "data": payload,
    })


def marker_phase_start(paths: FeaturePaths, phase: str, attempt_id: str) -> None:
    _marker(paths, "LOOP_SPEC_PHASE_START", {
        "event": "phase_start", "attemptId": attempt_id, "phase": phase, "timestamp": now_iso(),
    })


def marker_phase_end(paths: FeaturePaths, phase: str, attempt_id: str, verdict: str, next: str | None,
                      elapsed_seconds: float, head_sha: str | None) -> None:
    _marker(paths, "LOOP_SPEC_PHASE_END", {
        "event": "phase_end", "attemptId": attempt_id, "phase": phase, "timestamp": now_iso(),
        "verdict": verdict, "next": next, "elapsedSeconds": elapsed_seconds, "headSha": head_sha,
    })


def marker_question(paths: FeaturePaths, question_id: str) -> None:
    _marker(paths, "LOOP_SPEC_QUESTION", {"questionId": question_id})


def marker_wait(paths: FeaturePaths, open_step_ids: list[str]) -> None:
    # A wave with steps already dispatched and nothing new to issue: the caller
    # submits what it already sent workers out for, and starts nothing new.
    _marker(paths, "LOOP_SPEC_WAIT", {"open": open_step_ids})


def marker_result(paths: FeaturePaths, result_dict: dict) -> None:
    _marker(paths, "LOOP_SPEC_RESULT", result_dict)


def marker_next(kind: str, path: str, slug: str) -> None:
    # No `paths` argument here (the design fixes this signature to take only
    # kind/path/slug), so unlike the other markers this one cannot also append
    # itself to the ledger. `slug` (LF-06) is what a stub passes back on the next
    # `submit`/`answer`, since those commands require --slug and nothing else in
    # LOOP_SPEC_NEXT names the run.
    marker = {'kind': kind, 'path': path, 'slug': slug}
    if kind == "step":
        # A step's own fields, so a lead dispatching a role step never opens
        # step.json, which carries the whole composed prompt (up to ~170 KB).
        step = read_json(Path(path))
        marker.update({"stepKind": step["kind"], "stepAttemptId": step["stepAttemptId"],
                       "role": step.get("role"), "model": step.get("model")})
        if step.get("transport") == "file":
            marker["dispatchPath"] = str(Path(path).parent / "dispatch.txt")
    print(f"LOOP_SPEC_NEXT {_compact(marker)}")
