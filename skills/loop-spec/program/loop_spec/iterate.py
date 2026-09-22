"""ITERATE's default implementation (M4): one judge step per pass, then the module
picks the exit from the judge's verdict, gaps, and the ledger.

Use `step`/`on_submit` the same way `execute.py` does. Module state lives under
`store.state["iterate"]`, keyed to the current VERIFY head so a later ITERATE entry
(after a rewind) issues a fresh judge call while `priorGaps` keeps accumulating.
"""
from pathlib import Path

from . import repo as repo_module
from .budget import has_room
from .contract import resolve_role, validate_request
from .errors import LoopSpecError
from .execute import IssueStep, Product
from .postconditions import verified_head
from .roles import compose_prompt, load_role

_DIFF_CAP = 200_000  # ponytail: same flat cap as execute.py's review diff

# The judge's OWN step result: the module computes exit/boundSha/boundTo/inputsDigest
# itself from this plus the ledger, so those are not part of what the judge submits.
_JUDGE_RESULT_SCHEMA = {
    "type": "object", "required": ["verdict", "gaps", "caveats"], "additionalProperties": False,
    "properties": {
        "verdict": {"type": "string", "enum": ["met", "unmet"]},
        "gaps": {
            "type": "array",
            "items": {
                "type": "object", "required": ["target", "text"], "additionalProperties": False,
                "properties": {
                    "target": {"type": "string", "enum": ["spec", "plan", "execute", "verify"]},
                    "text": {"type": "string"},
                },
            },
        },
        "caveats": {"type": "array", "items": {"type": "string"}},
    },
}


def _judge_request(store, paths, ctx, head: str) -> dict:
    project_root = Path(ctx["paths"]["projectRoot"])
    role = load_role("iterate-judge", project_root, resolve_role(project_root, "iterate-judge"))
    _, repo_info = next(iter(store.state["repos"].items()))
    cwd = Path(paths.checkouts_dir) / f"verify-{head[:12]}"
    if not cwd.is_dir():
        raise LoopSpecError(
            f"no verify checkout at {cwd}",
            repair="ITERATE runs after VERIFY passed, so verify.py's checkout should still exist",
        )
    result_path = cwd / "loop-spec-iterate-result.json"

    diff = repo_module.run_git(Path(repo_info["path"]), "diff", f"{repo_info['baseSha']}..{head}")
    if len(diff) > _DIFF_CAP:
        diff = diff[:_DIFF_CAP] + "\n...(truncated)"

    budget_state = store.state["budget"]
    inputs = {
        "request": store.state["request"]["text"], "spec": store.state["products"]["spec"]["product"],
        "diff": diff, "verify": store.state["products"]["verify"]["product"],
        "priorGaps": store.state["iterate"]["priorGaps"],
        "budget": {"spent": budget_state["spent"], "limit": budget_state["limit"], "hasRoom": has_room(store)},
    }
    prompt = compose_prompt(role, inputs=inputs, result_path=result_path, cwd=cwd, phase="iterate")
    # simplicity: this build-validate-raise shape repeats verify.py's own request
    # builders and execute.py's (Wave G, out of this wave's file list); a shared
    # helper would need a module none of those three currently import from.
    request = {
        "kind": "role", "role": "iterate-judge", "phase": "iterate", "cwd": str(cwd),
        "prompt": prompt, "resultPath": str(result_path), "schema": _JUDGE_RESULT_SCHEMA, "postconditions": [],
        "attempt": ctx["attempt"]["id"], "inputsDigest": ctx["inputs"]["digest"], "retryOf": None, "reason": None,
    }
    errors = validate_request("step", request)
    if errors:
        raise LoopSpecError("iterate built an invalid judge step request: " + "; ".join(errors),
                             repair="fix _judge_request in iterate.py")
    return request


def _final_product(store, ctx, iterate_state: dict) -> dict:
    judge = iterate_state["judge"]
    ledger_findings = store.state["ledger"]["findings"]
    open_findings = [f for f in ledger_findings if f["disposition"] == "open"]
    accepted_non_critical = [f["id"] for f in ledger_findings
                              if f["disposition"] in ("rejected", "deferred", "fixed") and f["severity"] != "Critical"]

    # Order matters: "at least one accepted finding" must be checked before the
    # plain "no open finding" rule, or a met verdict with only closed findings would
    # never reach "converged with caveats".
    if judge["verdict"] == "met" and not open_findings and accepted_non_critical:
        exit_, caveats = "converged with caveats", accepted_non_critical
    elif judge["verdict"] == "met" and not open_findings:
        exit_, caveats = "converged", []
    elif judge["verdict"] == "unmet" and judge["gaps"] and has_room(store):
        exit_, caveats = "rewind", []
    else:
        # Escalate on anything the design's four rules don't name outright (a "met"
        # verdict with findings still open and undispositioned, or "unmet" with no
        # gaps at all): never converge on an unresolved finding by default.
        exit_, caveats = "escalated", []

    return {
        "exit": exit_, "inputsDigest": ctx["inputs"]["digest"],
        "boundTo": {"requirements": store.state["revisions"]["requirements"], "plan": store.state["revisions"]["plan"]},
        "verdict": judge["verdict"], "gaps": judge["gaps"], "caveats": caveats, "boundSha": iterate_state["boundSha"],
    }


def step(store, paths, ctx):
    head = verified_head(store)
    iterate_state = store.state.get("iterate")
    if iterate_state is None:
        iterate_state = {"priorGaps": [], "judgeStep": None, "judge": None, "boundSha": None}
        store.state["iterate"] = iterate_state
        store.save()
    if iterate_state["boundSha"] != head:
        iterate_state["judge"] = None
        iterate_state["boundSha"] = head
        store.save()

    if iterate_state["judge"] is None:
        return IssueStep(_judge_request(store, paths, ctx, head))
    return Product(_final_product(store, ctx, iterate_state))


def on_submit(store, paths, step, result: dict) -> None:
    iterate_state = store.state["iterate"]
    iterate_state["judge"] = result
    iterate_state["judgeStep"] = step["stepAttemptId"]
    iterate_state["priorGaps"] = iterate_state["priorGaps"] + result["gaps"]
    store.save()
