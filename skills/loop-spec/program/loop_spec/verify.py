"""VERIFY's default implementation (M4): a verifier step, then a reviewer step, over
one review range, one call at a time.

Use `step`/`on_submit` the same way `execute.py` does; wiring them into the
controller's dispatch is another agent's change. Module state lives under
`store.state["verify"]`. The controller records the finished product into
`store.state["ledger"]` via `ledger.py` once it accepts the product -- this module
never writes the ledger itself.
"""
from pathlib import Path

from . import baseline as baseline_module
from . import probes as probes_module
from . import repo as repo_module
from .contract import resolve_role, validate_request
from .errors import LoopSpecError
from .execute import IssueStep, Product
from .ids import new_id
from .postconditions import verified_head
from .roles import compose_prompt, load_role

_DIFF_CAP = 200_000  # ponytail: same flat cap as execute.py's review diff

# The verifier's OWN step result: per-criterion verdicts plus a remediation hint and
# the two gap flags the module needs to pick an exit. Bespoke, not verify.json's full
# product shape (verify.json also needs findings/remediationTasks/reviewedRange,
# which the reviewer and this module supply, not the verifier).
_VERIFIER_RESULT_SCHEMA = {
    "type": "object", "required": ["verdicts", "planGap", "intentGap"], "additionalProperties": False,
    "properties": {
        "planGap": {"type": "boolean"},
        "intentGap": {"type": "boolean"},
        "verdicts": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["criterion", "verdict", "evidence", "cause", "remediation"],
                "additionalProperties": False,
                "properties": {
                    "criterion": {"type": "string"},
                    "verdict": {"type": "string", "enum": ["pass", "fail", "blocked"]},
                    "evidence": {
                        "anyOf": [
                            {"type": "null"},
                            {
                                "type": "object",
                                "required": ["command", "sha", "exitStatus", "failureIdentities", "outputDigest"],
                                "additionalProperties": False,
                                "properties": {
                                    "command": {"type": "string"}, "sha": {"type": "string"},
                                    "exitStatus": {"type": "integer"},
                                    "failureIdentities": {"type": "array", "items": {"type": "string"}},
                                    "outputDigest": {"type": "string"},
                                },
                            },
                        ],
                    },
                    "cause": {"type": ["string", "null"]},
                    "remediation": {
                        "anyOf": [
                            {"type": "null"},
                            {
                                "type": "object", "required": ["files"], "additionalProperties": False,
                                "properties": {"files": {"type": "array", "items": {"type": "string"}}},
                            },
                        ],
                    },
                },
            },
        },
    },
}


def _verify_checkout(repo_path: Path, head: str, prepare: str | None, checkouts_dir: Path) -> Path:
    dest = Path(checkouts_dir) / f"verify-{head[:12]}"
    if dest.is_dir():
        return dest
    repo_module.clean_checkout(repo_path, head, dest)
    if prepare:
        prepare_run = baseline_module.run_command(prepare, dest, head)
        if prepare_run.exit_status != 0:
            raise LoopSpecError(
                f"prepare command failed at {head}: {prepare}",
                repair=f"run `{prepare}` by hand in {dest} against {head} and fix it",
            )
    return dest


def _base_layers(repo_path: Path, base_sha: str, files: list[str], checkouts_dir: Path) -> int:
    # A temporary checkout, removed once measured -- same shape as baseline.py's
    # own capture_baseline, not a worktree this module keeps around.
    dest = Path(checkouts_dir) / f"verify-base-{base_sha[:12]}"
    repo_module.clean_checkout(repo_path, base_sha, dest)
    try:
        return probes_module.indirection_scan(dest, files)["layers"]
    finally:
        repo_module.remove_worktree(repo_path, dest, force=True)


def _init(store, paths, ctx) -> dict:
    plan_product = store.state["products"]["plan"]["product"]
    head = verified_head(store)
    repo_name, repo_info = next(iter(store.state["repos"].items()))
    repo_path = Path(repo_info["path"])

    reviewed_ranges = store.state["ledger"]["reviewedRanges"]
    entry_payload = (ctx.get("entry") or {}).get("payload") or {}
    full = not reviewed_ranges or bool(entry_payload.get("finalPass"))
    range_from = repo_info["baseSha"] if full else reviewed_ranges[-1]["to"]

    all_files = sorted({f for task in plan_product["tasks"] for f in task["files"]})
    base_layers = _base_layers(repo_path, repo_info["baseSha"], all_files, paths.checkouts_dir)
    range_probes = probes_module.range_probes(repo_path, repo_info["baseSha"], head, base_layers)

    verify_state = {
        "planRevision": store.state["revisions"]["plan"], "head": head,
        "range": {"from": range_from, "to": head, "full": full},
        "rangeProbes": range_probes, "phase": "verifying",
        "verifierStep": None, "reviewerStep": None, "verifier": None, "reviewer": None,
        "pass": len(reviewed_ranges) + 1,
    }
    store.state["verify"] = verify_state
    store.save()
    return verify_state


def _verifier_request(store, paths, ctx, verify_state: dict) -> dict:
    project_root = Path(ctx["paths"]["projectRoot"])
    role = load_role("verifier", project_root, resolve_role(project_root, "verifier"))
    plan_product = store.state["products"]["plan"]["product"]
    spec_product = store.state["products"]["spec"]["product"]
    _, repo_info = next(iter(store.state["repos"].items()))
    cwd = _verify_checkout(Path(repo_info["path"]), verify_state["head"], plan_product.get("prepare"), paths.checkouts_dir)
    result_path = cwd / "loop-spec-verifier-result.json"

    inputs = {
        "criteria": spec_product["criteria"], "tasks": plan_product["tasks"],
        "baseline": store.state.get("baseline"), "environmentHealth": store.state.get("environmentHealth"),
        "head": verify_state["head"],
    }
    prompt = compose_prompt(role, inputs=inputs, result_path=result_path, cwd=cwd, phase="verify")
    request = {
        "kind": "role", "role": "verifier", "phase": "verify", "cwd": str(cwd),
        "prompt": prompt, "resultPath": str(result_path), "schema": _VERIFIER_RESULT_SCHEMA, "postconditions": [],
        "attempt": ctx["attempt"]["id"], "inputsDigest": ctx["inputs"]["digest"], "retryOf": None, "reason": None,
    }
    errors = validate_request("step", request)
    if errors:
        raise LoopSpecError("verify built an invalid verifier step request: " + "; ".join(errors),
                             repair="fix _verifier_request in verify.py")
    return request


def _reviewer_request(store, paths, ctx, verify_state: dict) -> dict:
    project_root = Path(ctx["paths"]["projectRoot"])
    role = load_role("code-reviewer", project_root, resolve_role(project_root, "code-reviewer"))
    plan_product = store.state["products"]["plan"]["product"]
    _, repo_info = next(iter(store.state["repos"].items()))
    repo_path = Path(repo_info["path"])
    cwd = _verify_checkout(repo_path, verify_state["head"], plan_product.get("prepare"), paths.checkouts_dir)
    result_path = cwd / "loop-spec-verify-review-result.json"

    range_ = verify_state["range"]
    diff = repo_module.run_git(repo_path, "diff", f"{range_['from']}..{range_['to']}")
    if len(diff) > _DIFF_CAP:
        diff = diff[:_DIFF_CAP] + "\n...(truncated)"

    ledger = store.state.get("ledger", {})
    signals = (ctx.get("probes") or {}).get("securitySignals") or []
    inputs = {
        "range": range_, "diff": diff,
        "ledger": {"reviewedRanges": ledger.get("reviewedRanges", []),
                   "openFindings": [f for f in ledger.get("findings", []) if f["disposition"] == "open"]},
        "rangeProbes": verify_state["rangeProbes"], "securitySignals": signals, "full": range_["full"],
    }
    prompt = compose_prompt(role, inputs=inputs, result_path=result_path, cwd=cwd, phase="verify")
    # simplicity: this build-validate-raise shape repeats iterate.py's own request
    # builder and execute.py's (Wave G, out of this wave's file list); a shared
    # helper would need a module none of those three currently import from.
    request = {
        "kind": "role", "role": "code-reviewer", "phase": "verify", "cwd": str(cwd),
        "prompt": prompt, "resultPath": str(result_path), "schema": role.schema, "postconditions": [],
        "attempt": ctx["attempt"]["id"], "inputsDigest": ctx["inputs"]["digest"], "retryOf": None, "reason": None,
    }
    errors = validate_request("step", request)
    if errors:
        raise LoopSpecError("verify built an invalid reviewer step request: " + "; ".join(errors),
                             repair="fix _reviewer_request in verify.py")
    return request


def _final_product(store, ctx, verify_state: dict) -> dict:
    verifier_result = verify_state["verifier"]
    reviewer_result = verify_state["reviewer"]
    repo_name, _ = next(iter(store.state["repos"].items()))

    verdicts_out = [
        {"criterion": v["criterion"], "verdict": v["verdict"], "evidence": v["evidence"], "cause": v["cause"]}
        for v in verifier_result["verdicts"]
    ]
    findings_out = [
        {"id": new_id("finding"), "location": f["location"], "cause": f["cause"], "severity": f["severity"],
         "disposition": f["disposition"], "reason": f["reason"], "supersedes": f["supersedes"]}
        for f in reviewer_result["findings"]
    ]

    remediation_tasks = []
    for n, v in enumerate(verifier_result["verdicts"], start=1):
        if v["verdict"] != "fail":
            continue
        remediation = v["remediation"] or {}
        remediation_tasks.append({
            "id": f"R-{n}", "title": f"fix {v['criterion']}", "dependsOn": [],
            "files": remediation.get("files") or [], "repo": repo_name,
            "verify": (v["evidence"] or {}).get("command") or "", "criteria": [v["criterion"]],
            "featureAdded": None, "mustFlip": False,
        })

    if verifier_result["intentGap"]:
        exit_ = "intent gap"
    elif verifier_result["planGap"]:
        exit_ = "plan gap"
    elif any(v["verdict"] == "blocked" for v in verdicts_out):
        exit_ = "blocked"
    elif any(v["verdict"] == "fail" for v in verdicts_out):
        exit_ = "implementation gap"
    else:
        exit_ = "passed"

    return {
        "exit": exit_, "inputsDigest": ctx["inputs"]["digest"],
        "boundTo": {"requirements": store.state["revisions"]["requirements"], "plan": store.state["revisions"]["plan"]},
        "verdicts": verdicts_out, "findings": findings_out, "remediationTasks": remediation_tasks,
        "reviewedRange": verify_state["range"],
    }


def step(store, paths, ctx):
    verify_state = store.state.get("verify")
    if verify_state is None:
        verify_state = _init(store, paths, ctx)

    if verify_state["phase"] == "verifying":
        return IssueStep(_verifier_request(store, paths, ctx, verify_state))
    if verify_state["phase"] == "reviewing":
        return IssueStep(_reviewer_request(store, paths, ctx, verify_state))
    return Product(_final_product(store, ctx, verify_state))


def on_submit(store, paths, step, result: dict) -> None:
    verify_state = store.state["verify"]
    if step["role"] == "verifier":
        verify_state["verifier"] = result
        verify_state["verifierStep"] = step["stepAttemptId"]
        verify_state["phase"] = "reviewing"
    elif step["role"] == "code-reviewer":
        verify_state["reviewer"] = result
        verify_state["reviewerStep"] = step["stepAttemptId"]
        verify_state["phase"] = "done"
    else:
        raise LoopSpecError(f"verify got a submission for an unknown role {step['role']!r}",
                             repair="check the submitted step's role field")
    store.save()
