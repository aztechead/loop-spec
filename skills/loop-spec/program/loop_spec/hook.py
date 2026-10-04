"""The Stop hook that keeps an autonomous run going until it has a result.

Claude Code runs it whenever the lead ends a turn. When an autonomous run in this
repository is still open, it blocks the stop and hands the lead the run's next step,
the same prompt each time, the way a Ralph loop re-feeds its task. It lets the stop
through when:

- no autonomous run is open here, or the run has ended;
- the lead's last message says `LOOP_SPEC_WAITING` (workers are running in the
  background, and their completion will resume the session);
- the run has made no progress (phase, head, task states, verify, CI) over
  IDLE_LIMIT continuations: the first time, it asks the lead to end the run as
  escalated; after that it lets the stop through;
- MAX_CONTINUATIONS is reached.

It never fails a session: any error lets the stop through silently.
"""
import json
from pathlib import Path

from loop_spec import git
from loop_spec.runs import all_runs

IDLE_LIMIT = 3
MAX_CONTINUATIONS = 40
WAITING = "LOOP_SPEC_WAITING"


def fingerprint(run, head: str | None, phase: str) -> str:
    s = run.state
    return json.dumps([phase, head, run.statuses(), (s.get("verify") or {}).get("sha"),
                       (s.get("verify") or {}).get("passed"), s.get("delivered"), s.get("ci")], sort_keys=True)


def decide(hook_input: dict, next_step) -> dict | None:
    """The hook's JSON answer, or None to let the stop through. `next_step(run, phase)` names the next step."""
    if WAITING in (hook_input.get("last_assistant_message") or ""):
        return None
    project = git.project_root(Path(hook_input.get("cwd") or "."))
    runs = [r for r in all_runs(project) if r.mode == "autonomous" and not r.result_path.is_file()]
    if not runs:
        return None
    run = runs[0]
    head = git.head(run.work) if run.work.exists() else None
    phase = run.phase(head)
    loop = run.state.setdefault("loop", {"fingerprint": None, "idle": 0, "count": 0})
    current = fingerprint(run, head, phase)
    loop["idle"] = loop["idle"] + 1 if current == loop["fingerprint"] else 0
    loop["fingerprint"], loop["count"] = current, loop["count"] + 1
    run.save()
    if loop["count"] > MAX_CONTINUATIONS or loop["idle"] > IDLE_LIMIT:
        return None
    program = Path(__file__).resolve().parents[1] / "loop-spec"
    if loop["idle"] == IDLE_LIMIT:
        reason = (f"The loop-spec run {run.slug} has not moved in {IDLE_LIMIT} continuations (phase {phase}). "
                  f"End it now: `\"{program}\" finish --slug {run.slug} --status escalated --summary \"...\"`, "
                  "naming what blocks it and the verified head, if any.")
    else:
        reason = (f"The autonomous loop-spec run {run.slug} is not finished (phase {phase}; next: "
                  f"{next_step(run, phase)}; program: \"{program}\"). Continue it now. The run ends only when "
                  "`deliver` or `ci` reports a result, or with `finish`. If workers you dispatched are still running, say "
                  f"{WAITING} and end the turn; if something you cannot fix blocks the run, end it with "
                  "`finish --status escalated`.")
    return {"decision": "block", "reason": reason}
