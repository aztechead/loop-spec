"""Ask/answer questions and the run's default-answer policy.

Use `ask` to open a question against a run (only one may be open at a time),
`answer` to record a human's response, and `resolve_policy_answer` for the
controller to try the run's default policy right after `ask` before surfacing it
to a person. This module records facts and enforces the one-open-question and
retired-id identity rules; it never decides what to ask or what a route does next.
"""
from .errors import LoopSpecError
from .events import emit, marker_question
from .ids import new_id, now_iso
from .jsonio import atomic_write_json
from .schema import validate_or_raise


def ask(store, paths, *, phase: str, attempt_id: str, text: str, kind: str,
        options: list[dict], default_value: str | None, payload: dict | None, save: bool = True) -> dict:
    # save=False: the caller links the question id into its own state and saves both
    # at once (LF-60), so a crash never leaves an open question nothing points at.
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
    if save:
        store.save()
    return record


def answer(store, paths, *, question_id: str, value: str, scope: str = "question", by: str = "human") -> dict:
    if question_id in store.state["questions"]["retired"]:
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
    store.save()
    return state_record


def resolve_policy_answer(store, paths, question: dict) -> dict | None:
    if store.state["questions"]["policy"] != "default":
        return None
    default_value = question.get("defaultValue")
    if default_value is None:
        # A policy cannot invent an answer the question never offered.
        return None
    record = answer(store, paths, question_id=question["questionId"], value=default_value, scope="run", by="policy")
    store.state["questions"]["policyAnswered"].append(question["questionId"])
    store.save()
    return record


def answers_for_context(store, attempt_id: str) -> dict:
    by_question = {
        question_id: {"value": rec["value"], "scope": rec["scope"], "by": rec["by"]}
        for question_id, rec in store.state["questions"]["answered"].items()
        if rec.get("attempt") == attempt_id
    }
    return {"byQuestion": by_question, "policy": store.state["questions"]["policy"]}


def retire_attempt_questions(store, attempt_id: str) -> None:
    open_question = store.state["questions"]["open"]
    if open_question is not None and open_question.get("attempt") == attempt_id:
        store.state["questions"]["retired"].append(open_question["questionId"])
        store.state["questions"]["open"] = None
        store.save()
