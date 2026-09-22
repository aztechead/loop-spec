"""VERIFY's default implementation (M4): one verifier step covering every repo, then
one reviewer step PER touched repo (LF-28: a workspace run reviewed only one repo
and checked evidence against the wrong repo's head), one call at a time.

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
from .events import emit
from .execute import IssueStep, Product
from .ids import new_id
from .paths import ensure_results_dir
from .roles import compose_prompt, load_role

_DIFF_CAP = 200_000  # ponytail: same flat cap as execute.py's review diff


def _heads(store) -> dict[str, str]:
    # EXECUTE's own product always carries a head per repo it initialized
    # (touched or not), unlike postconditions.verified_head, which only reads
    # the first repo -- exactly the single-repo assumption LF-28 is about.
    return store.state["products"]["execute"]["product"]["heads"]


def _touched_repos(store, heads: dict[str, str]) -> list[str]:
    repos = store.state["repos"]
    return [name for name in heads if heads[name] != repos[name]["baseSha"]]


def _criterion_repo(plan_product: dict) -> dict[str, str]:
    # A criterion belongs to the repo of the (first) task that covers it.
    mapping: dict[str, str] = {}
    for task in plan_product["tasks"]:
        for cid in task["criteria"]:
            mapping.setdefault(cid, task["repo"])
    return mapping


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
    heads = _heads(store)
    repos = store.state["repos"]
    touched = _touched_repos(store, heads)

    files_by_repo: dict[str, set] = {}
    for task in plan_product["tasks"]:
        files_by_repo.setdefault(task["repo"], set()).update(task["files"])

    reviewed_ranges = store.state["ledger"]["reviewedRanges"]
    entry_payload = (ctx.get("entry") or {}).get("payload") or {}
    final_pass = bool(entry_payload.get("finalPass"))

    checkouts, ranges, range_probes = {}, {}, {}
    for name in touched:
        repo_info = repos[name]
        repo_path = Path(repo_info["path"])
        head = heads[name]
        # No per-repo prior entry (every existing ledger range predates LF-28, or
        # this repo was never reviewed before) reviews the whole range, same as a
        # genuinely first pass -- never silently skips content nothing has seen.
        prior = next((e for e in reversed(reviewed_ranges) if e.get("repo") == name), None)
        repo_full = final_pass or prior is None
        range_from = repo_info["baseSha"] if repo_full else prior["to"]
        ranges[name] = {"repo": name, "from": range_from, "to": head, "full": repo_full}
        checkouts[name] = str(_verify_checkout(repo_path, head, plan_product.get("prepare"), paths.checkouts_dir))
        files = sorted(files_by_repo.get(name, set()))
        base_layers = _base_layers(repo_path, repo_info["baseSha"], files, paths.checkouts_dir)
        range_probes[name] = probes_module.range_probes(repo_path, repo_info["baseSha"], head, base_layers)

    verify_state = {
        "planRevision": store.state["revisions"]["plan"], "heads": heads,
        "checkouts": checkouts, "ranges": ranges, "rangeProbes": range_probes,
        "phase": "verifying", "verifierStep": None, "reviewerSteps": {}, "verifier": None,
        "reviewers": {}, "pendingReviews": list(touched), "pass": len(reviewed_ranges) + 1,
    }
    store.state["verify"] = verify_state
    store.save()
    return verify_state


def _verifier_request(store, paths, ctx, verify_state: dict) -> dict:
    project_root = Path(ctx["paths"]["projectRoot"])
    role = load_role("verifier", project_root, resolve_role(project_root, "verifier"))
    plan_product = store.state["products"]["plan"]["product"]
    spec_product = store.state["products"]["spec"]["product"]
    criterion_repo = _criterion_repo(plan_product)
    # LF-28: one repo untouched (or reviewed against the wrong head) is what
    # rejected a passing task; every repo gets its own checkout path (a live,
    # untouched one just points at its own path, not a temp clean checkout),
    # head, base, and the tasks/criteria that belong to it.
    repos_input = []
    for name, repo_info in store.state["repos"].items():
        repos_input.append({
            "repo": name, "checkout": verify_state["checkouts"].get(name, repo_info["path"]),
            "head": verify_state["heads"][name], "base": repo_info["baseSha"],
            "tasks": [t for t in plan_product["tasks"] if t["repo"] == name],
            "criteria": [c for c in spec_product["criteria"] if criterion_repo.get(c["id"]) == name],
        })
    # LF-27: under the project root (paths.results_dir), not inside a checkout
    # (a temp dir under the state home a live model cannot always write to).
    ensure_results_dir(paths)
    result_path = paths.results_dir / f"verify-{ctx['attempt']['id']}-verifier.json"
    cwd = Path(repos_input[0]["checkout"]) if repos_input else project_root

    inputs = {
        "repos": repos_input, "criteria": spec_product["criteria"], "tasks": plan_product["tasks"],
        "baseline": store.state.get("baseline"), "environmentHealth": store.state.get("environmentHealth"),
    }
    prompt = compose_prompt(role, inputs=inputs, result_path=result_path, cwd=cwd, phase="verify")
    request = {
        "kind": "role", "role": "verifier", "phase": "verify", "cwd": str(cwd),
        "prompt": prompt, "resultPath": str(result_path), "schema": role.schema, "postconditions": [],
        "attempt": ctx["attempt"]["id"], "inputsDigest": ctx["inputs"]["digest"], "retryOf": None, "reason": None,
    }
    errors = validate_request("step", request)
    if errors:
        raise LoopSpecError("verify built an invalid verifier step request: " + "; ".join(errors),
                             repair="fix _verifier_request in verify.py")
    return request


def _reviewer_request(store, paths, ctx, verify_state: dict, repo_name: str) -> dict:
    project_root = Path(ctx["paths"]["projectRoot"])
    role = load_role("code-reviewer", project_root, resolve_role(project_root, "code-reviewer"))
    repo_path = Path(store.state["repos"][repo_name]["path"])
    cwd = Path(verify_state["checkouts"][repo_name])
    ensure_results_dir(paths)
    result_path = paths.results_dir / f"verify-{ctx['attempt']['id']}-reviewer-{repo_name}.json"

    range_ = verify_state["ranges"][repo_name]
    diff = repo_module.run_git(repo_path, "diff", f"{range_['from']}..{range_['to']}")
    if len(diff) > _DIFF_CAP:
        diff = diff[:_DIFF_CAP] + "\n...(truncated)"

    ledger = store.state.get("ledger", {})
    signals = (ctx.get("probes") or {}).get("securitySignals") or []
    inputs = {
        "repo": repo_name, "range": range_, "diff": diff,
        "ledger": {"reviewedRanges": [e for e in ledger.get("reviewedRanges", []) if e.get("repo") == repo_name],
                   "openFindings": [f for f in ledger.get("findings", [])
                                     if f["disposition"] == "open" and f.get("repo") == repo_name]},
        "rangeProbes": verify_state["rangeProbes"][repo_name], "securitySignals": signals, "full": range_["full"],
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
    plan_product = store.state["products"]["plan"]["product"]
    criterion_repo = _criterion_repo(plan_product)

    verdicts_out = [
        {"criterion": v["criterion"], "verdict": v["verdict"], "cause": v["cause"],
         "evidence": {**v["evidence"], "repo": criterion_repo.get(v["criterion"])} if v["evidence"] else v["evidence"]}
        for v in verifier_result["verdicts"]
    ]
    # LF-28: a finding's repo is which per-repo reviewer produced it -- never a
    # lookup, since two repos could otherwise report the same file location.
    findings_out = [
        {"id": new_id("finding"), "repo": repo_name, "location": f["location"], "cause": f["cause"],
         "severity": f["severity"], "disposition": f["disposition"], "reason": f["reason"], "supersedes": f["supersedes"]}
        for repo_name, reviewer_result in verify_state["reviewers"].items()
        for f in reviewer_result["findings"]
    ]

    remediation_tasks = []
    for n, v in enumerate(verifier_result["verdicts"], start=1):
        if v["verdict"] != "fail":
            continue
        remediation = v["remediation"] or {}
        remediation_tasks.append({
            "id": f"R-{n}", "title": f"fix {v['criterion']}", "dependsOn": [],
            "files": remediation.get("files") or [], "repo": criterion_repo.get(v["criterion"]),
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
        "reviewedRanges": [verify_state["ranges"][name] for name in verify_state["reviewers"]],
    }


def step(store, paths, ctx):
    verify_state = store.state.get("verify")
    if verify_state is not None and "reviewers" not in verify_state:
        # A run whose state.verify predates the per-repo shape (LF-28) has none
        # of its keys; re-initialize for this attempt rather than KeyError on
        # every field below.
        emit(paths, "module_state_reset",
             {"summary": "verify state predates the per-repo shape; re-initializing", "missingKey": "reviewers"},
             phase="verify", attempt_id=ctx["attempt"]["id"])
        verify_state = None
    if verify_state is None:
        verify_state = _init(store, paths, ctx)

    if verify_state["phase"] == "verifying":
        return IssueStep(_verifier_request(store, paths, ctx, verify_state))
    if verify_state["phase"] == "reviewing":
        return IssueStep(_reviewer_request(store, paths, ctx, verify_state, verify_state["pendingReviews"][0]))
    return Product(_final_product(store, ctx, verify_state))


def on_submit(store, paths, step, result: dict) -> None:
    verify_state = store.state["verify"]
    if step["role"] == "verifier":
        verify_state["verifier"] = result
        verify_state["verifierStep"] = step["stepAttemptId"]
        verify_state["phase"] = "reviewing" if verify_state["pendingReviews"] else "done"
    elif step["role"] == "code-reviewer":
        repo_name = next(name for name in verify_state["pendingReviews"]
                          if verify_state["checkouts"][name] == step["cwd"])
        verify_state["pendingReviews"].remove(repo_name)
        verify_state["reviewers"][repo_name] = result
        verify_state["reviewerSteps"][repo_name] = step["stepAttemptId"]
        verify_state["phase"] = "reviewing" if verify_state["pendingReviews"] else "done"
    else:
        raise LoopSpecError(f"verify got a submission for an unknown role {step['role']!r}",
                             repair="check the submitted step's role field")
    store.save()
