"""Ask/answer questions and the run's default-answer policy.

Use `ask` to open a question against a run (only one may be open at a time),
`answer` to record a human's response; `ask` itself applies the run's default
policy (`resolve_policy_answer`) before a question is surfaced to a person. This
module records facts and enforces the one-open-question and retired-id identity
rules; it never decides what to ask or what a route does next.
"""
from loop_spec.errors import LoopSpecError
from loop_spec.events import emit, marker_question
from loop_spec.ids import new_id, now_iso
from loop_spec.jsonio import atomic_write_json
from loop_spec.schema import validate_or_raise

# A blocked question's answers. LF-66: "stop" is first and the default, so a headless
# answerer (the default policy, or one that takes the first option) ends the run
# instead of improvising a fix.
BLOCKED_OPTIONS = [
    {"value": "stop", "label": "Stop"},
    {"value": "fix-and-re-enter", "label": "Fix and re-enter"},
]

# A recurred-problem question's answers (the progress rule): `continue` routes the run
# back again, `stop` ends it. `stop` is first and the default, as for a blocked question.
# EXECUTE's blocked exit adds a third answer: a block no retry can clear (the plan's
# verify cannot pass, a build output the plan never ignored) goes back to PLAN.
EXECUTE_BLOCKED_OPTIONS = [*BLOCKED_OPTIONS, {"value": "plan gap", "label": "Plan gap (re-plan)"}]

RECURRED_OPTIONS = [
    {"value": "stop", "label": "Stop"},
    {"value": "continue", "label": "Continue"},
]


def ask(store, paths, *, phase: str, attempt_id: str, text: str, kind: str,
        options: list[dict], default_value: str | None, payload: dict | None, save: bool = True,
        by_policy: bool = False) -> dict:
    """Open a question and, under the run's default policy, answer it with its offered
    default at once (LF-62: one place, so no caller can forget). save=False defers
    every state write, the policy answer's included, to the caller, which links the
    question id into its own state and saves once (LF-60, LF-62): a crash never leaves
    a question, or its answer, that nothing points at. by_policy=True answers this one
    question by policy whatever the run's policy (contract.spec_approval)."""
    open_question = store.state["questions"]["open"]
    if open_question is not None:
        raise LoopSpecError(
            f"a question is already open: {open_question['questionId']}",
            repair="answer the open question first, see `loop-spec status`",
        )

    question_id = new_id("question")
    record = {
        "questionId": question_id, "attempt": attempt_id, "phase": phase, "text": text,
        "options": options, "defaultValue": default_value, "kind": kind,
        "payload": payload, "askedAt": now_iso(),
    }
    validate_or_raise(record, "question")

    path = paths.attempts_dir / attempt_id / "question.json"
    atomic_write_json(path, record)

    store.state["questions"]["open"] = {
        "questionId": question_id, "attempt": attempt_id, "phase": phase, "kind": kind,
        "askedAt": record["askedAt"], "path": str(path), "defaultValue": default_value,
    }
    emit(paths, "question", {"questionId": question_id, "summary": text}, phase=phase, attempt_id=attempt_id, source="program")
    marker_question(paths, question_id)
    resolve_policy_answer(store, paths, record, save=False, this_question_only=by_policy)
    if save:
        store.save()
    return record


def answer(store, paths, *, question_id: str, value: str, scope: str = "question", by: str = "human",
           save: bool = True) -> dict:
    if question_id in store.state["questions"]["retired"]:
        recorded = store.state["questions"]["answered"].get(question_id)
        if recorded is not None and recorded["value"] == value:
            return recorded  # a replayed answer (a lead retrying after the run moved on) is a no-op
        raise LoopSpecError(
            f"question {question_id} is retired",
            repair="answer the open question, see `loop-spec status`",
        )
    open_question = store.state["questions"]["open"]
    if open_question is None or open_question["questionId"] != question_id:
        raise LoopSpecError(
            f"no open question with id {question_id}",
            repair="check `loop-spec status` for the open question id",
        )

    answered_at = now_iso()
    file_record = {"questionId": question_id, "value": value, "scope": scope, "answeredAt": answered_at, "by": by}
    validate_or_raise(file_record, "answer")
    path = paths.attempts_dir / open_question["attempt"] / "answer.json"
    atomic_write_json(path, file_record)

    # The state record carries phase/attempt too: answers_for_context filters by
    # attempt, which the answer.json file (schema additionalProperties: false) has
    # no room for.
    state_record = {
        "value": value, "scope": scope, "answeredAt": answered_at, "by": by,
        "phase": open_question["phase"], "attempt": open_question["attempt"],
    }
    store.state["questions"]["answered"][question_id] = state_record
    store.state["questions"]["retired"].append(question_id)
    store.state["questions"]["open"] = None
    if scope == "run":
        store.state["questions"]["policy"] = "default"
    if save:
        store.save()
    return state_record


def resolve_policy_answer(store, paths, question: dict, save: bool = True,
                          this_question_only: bool = False) -> dict | None:
    # this_question_only: answer by policy even without the run's default policy, and
    # at question scope, so the answer never turns the run's policy on.
    if store.state["questions"]["policy"] != "default" and not this_question_only:
        return None
    default_value = question.get("defaultValue")
    if default_value is None:
        # A policy cannot invent an answer the question never offered.
        return None
    scope = "run" if store.state["questions"]["policy"] == "default" else "question"
    record = answer(store, paths, question_id=question["questionId"], value=default_value, scope=scope, by="policy", save=False)
    store.state["questions"]["policyAnswered"].append(question["questionId"])
    # Say which operator setting answered, so a lead that saw the question printed never
    # reads the answer as a gate it was never asked about being bypassed (p775-approval).
    setting = "the run's default answer policy" if scope == "run" else "spec.approval: policy"
    emit(paths, "policy_answer", {"questionId": question["questionId"], "value": default_value,
                                  "summary": f"answered by policy ({setting}): {default_value}"},
         phase=question.get("phase"), attempt_id=question.get("attempt"), source="program")
    if save:
        store.save()
    return record


def answers_for_context(store, attempt_id: str) -> dict:
    by_question = {
        question_id: {"value": rec["value"], "scope": rec["scope"], "by": rec["by"]}
        for question_id, rec in store.state["questions"]["answered"].items()
        if rec.get("attempt") == attempt_id
    }
    return {"byQuestion": by_question, "policy": store.state["questions"]["policy"]}
