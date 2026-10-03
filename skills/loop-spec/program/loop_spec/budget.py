"""The backward-transition ledger and its progress rule (T1, T2).

Use `repeat_of` before a phase claims a backward exit to learn whether it repeats an
earlier one, and `spend` to record the exit once accepted. There is no count: a backward
transition is refused only when an earlier one left the identical state (same exit, same
fingerprint), and a problem that comes back after a change is reported as "recurred" for
the controller to ask about. A DELIVER `base moved` has its own limit (T2) that asks
instead of stopping.
"""
from loop_spec.ids import now_iso


def repeat_of(store, from_phase: str, exit: str, cause: str, fingerprint: str) -> str | None:
    """None when this transition is new; "identical" when an earlier transition left the
    same (from, exit) on the same fingerprint, whatever its cause (re-running one state
    through one phase to the same exit cannot differ); "recurred" when one had the same
    cause on a different fingerprint. Transitions recorded without a fingerprint never match."""
    recurred = False
    for record in store.state["budget"]["transitions"]:
        if record["from"] != from_phase or record["exit"] != exit or record.get("fingerprint") is None:
            continue
        if record["fingerprint"] == fingerprint:
            return "identical"
        if record.get("cause") == cause:
            recurred = True
    return "recurred" if recurred else None


# ponytail: fixed count, no env var; add one when a host needs more. A base move is caused
# outside the run (someone else merged), so reaching the limit asks the operator.
BASE_MOVE_LIMIT = 3


def base_moves(store) -> int:
    """Base moves since the operator last chose to continue past the limit."""
    budget = store.state["budget"]
    return sum(1 for r in budget["transitions"][budget.get("baseMovesContinuedAt", 0):] if r["exit"] == "base moved")


def base_move_room(store) -> bool:
    return base_moves(store) < BASE_MOVE_LIMIT


def spend(store, *, from_phase: str, exit: str, to_phase: str, attempt_id: str, reason: str,
          cause: str | None = None, fingerprint: str | None = None) -> dict:
    # Idempotent replay first: a retried call for a transition already recorded is not a
    # new spend (IT-03).
    for record in store.state["budget"]["transitions"]:
        if record["attemptId"] == attempt_id and record["exit"] == exit:
            return record

    record = {
        "from": from_phase, "exit": exit, "to": to_phase,
        "attemptId": attempt_id, "reason": reason, "at": now_iso(),
        "cause": cause, "fingerprint": fingerprint,
    }
    store.state["budget"]["transitions"].append(record)
    # No save here: the caller persists the spend together with the transition it
    # pays for, so a crash can never leave a spent transition with no route (LF-55).
    return record
