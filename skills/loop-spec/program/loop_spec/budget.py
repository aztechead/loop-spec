"""The shared rewind budget (T1): bounds every backward or re-entrant transition,
except a DELIVER `base moved`, which has its own fixed limit (T2).

Use `has_room` before a phase claims a backward exit and `spend` to record it once
that exit is accepted. The budget only grows; there is no reset, by design, so a
fresh attempt never buys a run more rewinds than the operator configured.
"""
import os

from loop_spec.errors import LoopSpecError
from loop_spec.ids import now_iso


class BudgetExhausted(LoopSpecError):
    """Raised by spend() when the budget has no room left for a new transition."""


def limit(store) -> int:
    env = os.environ.get("LOOP_SPEC_REWIND_BUDGET")
    if env:
        try:
            return int(env)
        except ValueError as exc:
            raise LoopSpecError(
                f"LOOP_SPEC_REWIND_BUDGET is not an integer: {env!r}",
                repair="unset LOOP_SPEC_REWIND_BUDGET or set it to a whole number",
            ) from exc
    return store.state["budget"]["limit"]


def has_room(store) -> bool:
    return store.state["budget"]["spent"] < limit(store)


# ponytail: fixed cap, no env var; add one when a host needs more. A base move is caused
# outside the run (someone else merged), so it never spends the run's own rework budget.
BASE_MOVE_LIMIT = 3


def base_move_room(store) -> bool:
    moves = sum(1 for record in store.state["budget"]["transitions"] if record["exit"] == "base moved")
    return moves < BASE_MOVE_LIMIT


def spend(store, *, from_phase: str, exit: str, to_phase: str, attempt_id: str, reason: str) -> dict:
    # Idempotent replay first, regardless of remaining room: a retried call for a
    # transition already recorded is not a new spend (IT-03), so it must not be
    # blocked by an otherwise-exhausted budget either.
    for record in store.state["budget"]["transitions"]:
        if record["attemptId"] == attempt_id and record["exit"] == exit:
            return record

    base_move = exit == "base moved"
    if base_move and not base_move_room(store):
        raise BudgetExhausted(
            f"the base moved {BASE_MOVE_LIMIT} times; the base-move limit is {BASE_MOVE_LIMIT}",
            repair="resolve with the base owner, then start a revise run",
        )
    if not base_move and not has_room(store):
        raise BudgetExhausted(
            f"the rewind budget is exhausted ({store.state['budget']['spent']}/{limit(store)})",
            repair="raise LOOP_SPEC_REWIND_BUDGET, or resolve the run without another rewind",
        )

    record = {
        "from": from_phase, "exit": exit, "to": to_phase,
        "attemptId": attempt_id, "reason": reason, "at": now_iso(),
    }
    store.state["budget"]["transitions"].append(record)
    if not base_move:
        store.state["budget"]["spent"] += 1
    # No save here: the caller persists the spend together with the transition it
    # pays for, so a crash can never leave a spent budget with no route (LF-55).
    return record
