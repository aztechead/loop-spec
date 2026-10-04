"""The Stop hook that keeps an autonomous run going until it ends, the way `/goal` does.

`/goal` is a Stop hook with a condition: after every turn an evaluator says whether the
condition is met, and if not, the session takes another turn with the evaluator's reason
as its guidance. Here the condition is fixed, "the loop-spec run has a result", and the
evaluator is the run's own record rather than a model reading the transcript:

- **met**: the run has a result (`deliver`, `feedback`, or `finish` wrote it). The stop
  goes through.
- **not yet met**: the run is open. The stop is blocked, and the reason names the run's
  next step. When the run's record (phase, head, tasks, verify, feedback) has not changed
  for a few turns, the reason says so, so the lead can judge whether the run is blocked.
- **impossible**: the lead decides that, as `/goal`'s evaluator would, and records it by
  ending the run with `finish --status escalated`, which makes the condition met.

There is no cap on turns, as with `/goal`; Claude Code's own block cap stops a lead that
keeps answering without using a tool. As `/goal` skips evaluation while background work
runs, the hook lets the stop through when the lead says `LOOP_SPEC_WAITING`: the
workers' results resume the session. It never fails a session: any error lets the stop
through silently.
"""
import json
from pathlib import Path

from loop_spec import git
from loop_spec.runs import all_runs

STALL_TURNS = 3  # one turn can be a dispatch and a wait; three with no change suggests the run is stuck
WAITING = "LOOP_SPEC_WAITING"


def fingerprint(run, head: str | None, phase: str) -> str:
    s = run.state
    return json.dumps([phase, head, run.statuses(), s.get("verify"), s.get("iterate"), s.get("delivered"),
                       s.get("feedback")],
                      sort_keys=True)


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
    loop = run.state.setdefault("loop", {"fingerprint": None, "unchanged": 0})
    current = fingerprint(run, head, phase)
    loop["unchanged"] = loop["unchanged"] + 1 if current == loop["fingerprint"] else 0
    loop["fingerprint"] = current
    run.save()
    program = Path(__file__).resolve().parents[1] / "loop-spec"
    reason = (f"The autonomous loop-spec run {run.slug} is not finished (phase {phase}; next: "
              f"{next_step(run, phase)}; program: \"{program}\"). Continue it. It ends when `deliver`, "
              "`feedback`, or `finish` records a result.")
    if loop["unchanged"] >= STALL_TURNS:
        reason += (f" Its record has not changed in {loop['unchanged']} turns: if something you cannot fix blocks "
                   "it, end it with `finish --status escalated` naming the blocker; otherwise take the next step.")
    else:
        reason += f" If workers you dispatched are still running, say {WAITING} and end the turn."
    return {"decision": "block", "reason": reason}
