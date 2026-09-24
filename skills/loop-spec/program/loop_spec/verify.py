"""VERIFY's default implementation (M4): one verifier step covering every repo, then
one reviewer step PER touched repo (LF-28: a workspace run reviewed only one repo
and checked evidence against the wrong repo's head), one call at a time.

Use `step`/`on_submit` the same way `execute.py` does; wiring them into the
controller's dispatch is another agent's change. Module state lives under
`store.state["verify"]`. The controller records the finished product into
`store.state["ledger"]` via `ledger.py` once it accepts the product -- this module
never writes the ledger itself.
"""
import copy
import hashlib
import re
from pathlib import Path

from loop_spec import baseline as baseline_module
from loop_spec import ledger as ledger_module
from loop_spec import probes as probes_module
from loop_spec import repo as repo_module
from loop_spec import repo_checks
from loop_spec import steps as steps_module
from loop_spec.contract import resolve_role, validate_request
from loop_spec.errors import LoopSpecError
from loop_spec.events import emit
from loop_spec.steps import IssueStep, Product
from loop_spec.ids import new_id
from loop_spec.paths import ensure_results_dir
from loop_spec.roles import compose_prompt, load_role, dispatch_settings

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


# LF-30: a rejected VERIFY product re-enters remediation with the SAME already
# -submitted results -- left alone, the next attempt reproduces the identical
# product and gets rejected again. V2-V6 are all the verifier's own claims (a
# criterion set, its evidence SHA, a stale re-run, an exception, a blocked
# cause); V7/V8 are the reviewer's (range continuity, a finding's supersedes).
_VERIFIER_RETRY_FAILURE_IDS = {"V2", "V3", "V4", "V5", "V6"}
_REVIEWER_RETRY_FAILURE_IDS = {"V7", "V8"}
_REPO_FAILURE_RE = re.compile(r"^repo (\S+):")


def _failure_repo(message: str) -> str | None:
    match = _REPO_FAILURE_RE.match(message)
    return match.group(1) if match else None


def _handle_rejection(store, paths, ctx, verify_state: dict) -> None:
    entry = ctx["entry"]
    if entry.get("mode") != "remediation":
        return
    rejected = (entry.get("payload") or {}).get("rejected")
    if not rejected or not rejected.get("failures"):
        return
    attempt_id = ctx["attempt"]["id"]
    if "handledRejections" not in verify_state:
        verify_state["handledRejections"] = []
        emit(paths, "module_state_reset",
             {"summary": "verify state had no handledRejections; starting one", "missingKey": "handledRejections"},
             phase="verify", attempt_id=attempt_id)
    if attempt_id in verify_state["handledRejections"]:
        return
    verify_state["handledRejections"].append(attempt_id)

    failures = rejected["failures"]
    reviewer_failures = [f for f in failures if f["id"] in _REVIEWER_RETRY_FAILURE_IDS]
    if reviewer_failures:
        # A repo the message cannot name (V8's finding id, say) resets every
        # reviewer rather than guess which one -- never silently leaves a
        # rejected result unreviewed again.
        repos = {_failure_repo(f["message"]) for f in reviewer_failures}
        targets = repos & set(verify_state["reviewers"]) if None not in repos else set(verify_state["reviewers"])
        reason = "\n".join(f["message"] for f in reviewer_failures)
        for name in targets:
            del verify_state["reviewers"][name]
            verify_state.setdefault("reviewerReasons", {})[name] = reason
            if name not in verify_state["pendingReviews"]:
                verify_state["pendingReviews"].append(name)
        if targets:
            verify_state["phase"] = "reviewing"

    verifier_messages = [f["message"] for f in failures if f["id"] in _VERIFIER_RETRY_FAILURE_IDS]
    if verifier_messages:
        # Checked last so it wins the phase: a fresh verifier step must be
        # issued (and land) before on_submit's own pendingReviews check can
        # correctly route back to any reviewer this same rejection just reset.
        verify_state["reason"] = "\n".join(verifier_messages)
        verify_state["verifier"] = None
        verify_state["phase"] = "verifying"

    store.save()


def _verify_checkout(repo_path: Path, repo_name: str, head: str, prepare: str | None, checkouts_dir: Path,
                     suffix: str = "") -> Path:
    # 7.1.1: keyed by repo and prepare too, so workspace repos at one SHA, or a changed
    # prepare at an unchanged head, never share a tree; a failed prepare leaves none.
    prepare_key = hashlib.sha256((prepare or "").encode()).hexdigest()[:8]
    dest = Path(checkouts_dir) / f"verify-{repo_name}-{head[:12]}-{prepare_key}{suffix}"
    if dest.is_dir():
        return dest
    repo_module.clean_checkout(repo_path, head, dest)
    if prepare:
        prepare_run = baseline_module.run_command(prepare, dest, head)
        if prepare_run.exit_status != 0:
            repo_module.remove_worktree(repo_path, dest, force=True)
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


def _current_inputs(store) -> dict:
    return {
        "requirements": store.state["revisions"]["requirements"],
        "plan": store.state["revisions"]["plan"],
        "heads": _heads(store),
    }


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
    reused_reviewers: dict[str, dict] = {}
    reused_links: dict[str, dict] = {}
    pending_reviews: list[str] = []
    for name in touched:
        repo_info = repos[name]
        repo_path = Path(repo_info["path"])
        head = heads[name]
        # No per-repo prior entry (every existing ledger range predates LF-28, or
        # this repo was never reviewed before) reviews the whole range, same as a
        # genuinely first pass -- never silently skips content nothing has seen.
        prior = next((e for e in reversed(reviewed_ranges) if e.get("repo") == name), None)
        if prior is not None and not steps_module.evidence_accepted(
                store, ctx["paths"]["projectRoot"], prior.get("byStep"), "code-reviewer"):
            # LF-60: a range whose review has no accepted evidence (or no recorded
            # step at all) is untrusted: never reused and never a delta base; the
            # repo is reviewed over base..head in full.
            emit(paths, "review_untrusted", {"repo": name, "rangeId": prior["id"], "byStep": prior.get("byStep")},
                 phase="verify", attempt_id=ctx["attempt"]["id"])
            prior = None
        repo_full = final_pass or prior is None
        # LF-47: an empty delta (nothing changed since the last reviewed SHA)
        # needs no reviewer step at all; a final pass reuses the same prior
        # entry too, but only once some earlier pass already reviewed base..head
        # in full -- a final pass still has to have SEEN the whole diff once.
        reused = prior is not None and prior["to"] == head and (not final_pass or prior["full"])
        if reused:
            ranges[name] = {"repo": prior["repo"], "from": prior["from"], "to": prior["to"], "full": prior["full"]}
            reused_reviewers[name] = {"findings": []}
            reused_links[name] = {"rangeId": prior["id"], "byStep": prior.get("byStep")}
            emit(paths, "review_reused", {"repo": name, "rangeId": prior["id"]}, phase="verify", attempt_id=ctx["attempt"]["id"])
        else:
            range_from = repo_info["baseSha"] if repo_full else prior["to"]
            ranges[name] = {"repo": name, "from": range_from, "to": head, "full": repo_full}
            pending_reviews.append(name)
        checkouts[name] = str(_verify_checkout(repo_path, name, head, plan_product.get("prepare"), paths.checkouts_dir))
        files = sorted(files_by_repo.get(name, set()))
        base_layers = _base_layers(repo_path, repo_info["baseSha"], files, paths.checkouts_dir)
        # 7.3.0: the verify checkout at head, not the operator's checkout: the probes read files at `head`.
        range_probes[name] = probes_module.range_probes(Path(checkouts[name]), repo_info["baseSha"], head, base_layers)

    verify_state = {
        "planRevision": store.state["revisions"]["plan"], "heads": heads,
        "checkouts": checkouts, "ranges": ranges, "rangeProbes": range_probes,
        "phase": "verifying", "verifierStep": None, "reviewerSteps": {}, "verifier": None, "reason": None,
        "reviewers": reused_reviewers, "reviewerReasons": {}, "pendingReviews": pending_reviews, "reused": reused_links,
        "handledRejections": [], "pass": len(reviewed_ranges) + 1,
        "inputs": copy.deepcopy({
            "requirements": store.state["revisions"]["requirements"],
            "plan": store.state["revisions"]["plan"],
            "heads": heads,
        }),
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
        "evidenceExceptions": plan_product.get("evidenceExceptions", []),
        "baseline": store.state.get("baseline"), "environmentHealth": store.state.get("environmentHealth"),
    }
    check_rows = repo_checks.ensure_check_runs(store, paths)
    if check_rows:
        # 7.1.0: facts, not work for the verifier: the program ran each repo check at
        # the head; a regression becomes a remediation whatever the verdicts say.
        inputs["repoChecks"] = [{"repo": r["repo"], "command": r["command"], "head": r["head"],
                                 "verdict": r["comparison"]["verdict"], "detail": r["comparison"]["detail"],
                                 "newIdentities": r["comparison"]["newIdentities"][:20]} for r in check_rows]
    prompt = compose_prompt(role, inputs=inputs, result_path=result_path, cwd=cwd, phase="verify")
    request = {
        "kind": "role", "role": "verifier", "phase": "verify", "cwd": str(cwd),
        "prompt": prompt, "resultPath": str(result_path), "schema": role.schema, "postconditions": [],
        "attempt": ctx["attempt"]["id"], "inputsDigest": ctx["inputs"]["digest"],
        # LF-30: None/None on a fresh pass -- a rejection re-routed back to the
        # verifier (see _handle_rejection) is the one case with a reason already
        # set and a prior verifier step to retry.
        "retryOf": verify_state.get("verifierStep"), "reason": verify_state.get("reason"),
        **dispatch_settings(project_root, "verifier"),
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
    diff = repo_module.review_diff(repo_path, f"{range_['from']}..{range_['to']}")
    if len(diff) > _DIFF_CAP:
        diff = diff[:_DIFF_CAP] + "\n...(truncated)"

    ledger = store.state.get("ledger", {})
    inputs = {
        "repo": repo_name, "range": range_, "diff": diff,
        "ledger": {"reviewedRanges": [e for e in ledger.get("reviewedRanges", []) if e.get("repo") == repo_name],
                   "openFindings": [f for f in ledger.get("findings", [])
                                     if f["disposition"] == "open" and f.get("repo") == repo_name]},
        "rangeProbes": verify_state["rangeProbes"][repo_name], "full": range_["full"],
    }
    prompt = compose_prompt(role, inputs=inputs, result_path=result_path, cwd=cwd, phase="verify")
    # simplicity: this build-validate-raise shape repeats iterate.py's own request
    # builder and execute.py's (Wave G, out of this wave's file list); a shared
    # helper would need a module none of those three currently import from.
    request = {
        "kind": "role", "role": "code-reviewer", "phase": "verify", "cwd": str(cwd),
        "prompt": prompt, "resultPath": str(result_path), "schema": role.schema, "postconditions": [],
        "attempt": ctx["attempt"]["id"], "inputsDigest": ctx["inputs"]["digest"],
        # LF-30: None/None on a fresh pass -- a rejection re-routed back to this
        # repo's review (see _handle_rejection) is the one case with a reason
        # already set and a prior reviewer step to retry.
        "retryOf": verify_state["reviewerSteps"].get(repo_name), "reason": verify_state.get("reviewerReasons", {}).get(repo_name),
        **dispatch_settings(project_root, "code-reviewer"),
    }
    errors = validate_request("step", request)
    if errors:
        raise LoopSpecError("verify built an invalid reviewer step request: " + "; ".join(errors),
                             repair="fix _reviewer_request in verify.py")
    return request


def _final_product(store, paths, ctx, verify_state: dict) -> dict:
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
    # LF-50: a reviewer finding that names an open ledger finding (same id, repo,
    # location file) is carried forward under its own id; one that names a closed
    # ledger finding with the same disposition is an echo, dropped rather than
    # minted as new; anything else gets a fresh id.
    findings_out = []
    for repo_name, reviewer_result in verify_state["reviewers"].items():
        for f in reviewer_result["findings"]:
            entry = ledger_module.carried_forward(store, f, repo_name)
            if entry is not None and ledger_module.valid_update(entry, f):
                finding_id = f["id"]
            else:
                closed_echo = ledger_module.closed_echo(store, f, repo_name)
                if closed_echo is not None:
                    emit(paths, "finding_echo_ignored",
                         {"id": f["id"], "disposition": closed_echo["disposition"],
                          "summary": f"reviewer repeated closed finding {f['id']}; ignored"},
                         phase="verify", attempt_id=ctx["attempt"]["id"])
                    continue
                finding_id = new_id("finding")
            findings_out.append({
                "id": finding_id, "repo": repo_name, "location": f["location"], "cause": f["cause"],
                "severity": f["severity"], "disposition": f["disposition"], "reason": f["reason"], "supersedes": f["supersedes"],
            })

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

    # LF-45: the route is the verdicts', never a bare flag -- a planGap/intentGap
    # with every verdict passing is a note the verifier made (often a criterion an
    # evidenceExceptions entry already covers), not a gap the program should act
    # on. The verifier role never sees PLAN or SPEC directly, so it has nothing
    # deterministic behind a flag it raises with no failing criterion.
    any_not_pass = any(v["verdict"] != "pass" for v in verdicts_out)
    if verifier_result["intentGap"] and any_not_pass:
        exit_ = "intent gap"
    elif verifier_result["planGap"] and any_not_pass:
        exit_ = "plan gap"
    elif any(v["verdict"] == "blocked" for v in verdicts_out):
        exit_ = "blocked"
    elif any(v["verdict"] == "fail" for v in verdicts_out):
        exit_ = "implementation gap"
    else:
        exit_ = "passed"
    # LF-64: every verdict passing with a Critical review finding still open is an
    # implementation gap, not a pass V7 will reject: re-reviewing the same head only
    # re-finds it. One remediation per finding reopens the plan task owning its file
    # (else the repo's last task); a repo with no plan task has nothing to reopen.
    if exit_ == "passed":
        critical_ids = []
        for f in ledger_module.effective_findings(store, findings_out, store.state["repos"]):
            if f["severity"] != "Critical" or f["disposition"] != "open":
                continue
            repo = f.get("repo") or next(iter(store.state["repos"]))
            path = (f.get("location") or "").split(":", 1)[0]
            repo_tasks = [t for t in plan_product["tasks"] if t["repo"] == repo]
            if not repo_tasks:
                continue
            owners = [t for t in repo_tasks if path in t["files"]] or repo_tasks[-1:]
            criteria = sorted({c for t in owners for c in t["criteria"]})
            remediation_tasks.append({
                "id": f"R-{len(verifier_result['verdicts']) + len(critical_ids) + 1}",
                "title": f"fix Critical finding {f['id']} at {f['location']}: {f['cause']}",
                "dependsOn": [], "files": [path] if path else [], "repo": repo, "verify": "",
                "criteria": criteria, "featureAdded": None, "mustFlip": False,
            })
            critical_ids.append(f["id"])
        if critical_ids:
            exit_ = "implementation gap"
            emit(paths, "verify_critical_remediation",
                 {"findings": critical_ids, "summary": f"open Critical finding(s) {', '.join(critical_ids)} routed to EXECUTE"},
                 phase="verify", attempt_id=ctx["attempt"]["id"])
    if exit_ in ("passed", "implementation gap"):
        exit_ = _check_remediations(store, paths, ctx, plan_product, verifier_result, remediation_tasks, exit_)
    if (verifier_result["intentGap"] or verifier_result["planGap"]) and not any_not_pass:
        emit(paths, "verify_gap_flag_ignored",
             {"planGap": verifier_result["planGap"], "intentGap": verifier_result["intentGap"]},
             phase="verify", attempt_id=ctx["attempt"]["id"])

    return {
        "exit": exit_, "inputsDigest": ctx["inputs"]["digest"],
        "boundTo": {"requirements": store.state["revisions"]["requirements"], "plan": store.state["revisions"]["plan"]},
        "verdicts": verdicts_out, "findings": findings_out, "remediationTasks": remediation_tasks,
        "reviewedRanges": [_published_range(verify_state, name) for name in verify_state["reviewers"]],
        # D4: ITERATE's judge reads the verified tree here, not in this module's bucket.
        "checkouts": dict(verify_state["checkouts"]),
    }


def _published_range(verify_state: dict, name: str) -> dict:
    """A reviewed range with the step that reviewed it (a reused range keeps the step
    that originally did), which the core records in the ledger (LF-60)."""
    reused = (verify_state.get("reused") or {}).get(name)
    return {**verify_state["ranges"][name],
            "reviewStep": reused["byStep"] if reused else verify_state["reviewerSteps"].get(name),
            "reusedRangeId": reused["rangeId"] if reused else None}


def _check_remediations(store, paths, ctx, plan_product: dict, verifier_result: dict,
                        remediation_tasks: list, exit_: str) -> str:
    """7.1.0: a repo check the program ran at the verified head that shows a new
    diagnostic becomes one remediation, owned like LF-64's (the plan task whose files
    hold the diagnostic, else the repo's last task); a check that cannot be compared
    with its baseline is PLAN's to fix."""
    for row in repo_checks.ensure_check_runs(store, paths):
        comparison = baseline_module.Comparison.from_dict(row["comparison"])
        if comparison.verdict == "no-regression":
            continue
        if comparison.verdict == "baseline-error":
            emit(paths, "check_baseline_error", {"repo": row["repo"], "command": row["command"],
                 "summary": f"repo check {row['command']!r} cannot be compared with its baseline: {comparison.detail}"},
                 phase="verify", attempt_id=ctx["attempt"]["id"])
            exit_ = "plan gap"
            continue
        run = baseline_module.CommandRun.from_dict(row["run"])
        paths_hit = sorted({i.split(": ", 1)[0] for i in comparison.new_identities if i in run.failure_identities})
        repo_tasks = [t for t in plan_product["tasks"] if t["repo"] == row["repo"]]
        owners = [t for t in repo_tasks if set(t["files"]) & set(paths_hit)] or repo_tasks[-1:]
        shown = "; ".join(baseline_module.describe_failure(comparison, run, limit=3))
        remediation_tasks.append({
            "id": f"R-{len(verifier_result['verdicts']) + len(remediation_tasks) + 1}",
            "title": f"repo check `{row['command']}` regressed at {row['head'][:12]}: {shown}",
            "dependsOn": [], "files": paths_hit, "repo": row["repo"], "verify": "",
            "criteria": sorted({c for t in owners for c in t["criteria"]}), "featureAdded": None, "mustFlip": False,
        })
        if exit_ == "passed":
            exit_ = "implementation gap"
        emit(paths, "verify_check_remediation", {"repo": row["repo"], "command": row["command"],
             "summary": f"repo check {row['command']!r} regressed; routed to EXECUTE"},
             phase="verify", attempt_id=ctx["attempt"]["id"])
    return exit_


def _requeue_review(store, verify_state: dict, repo_name: str, reason: str) -> None:
    """Send one repo back to review over base..head in full (LF-60): its earlier
    review is not accepted evidence, so no delta from it can be trusted either."""
    verify_state["reviewers"].pop(repo_name, None)
    verify_state["reviewerSteps"].pop(repo_name, None)
    verify_state.setdefault("reused", {}).pop(repo_name, None)
    head = verify_state["heads"][repo_name]
    verify_state["ranges"][repo_name] = {"repo": repo_name, "from": store.state["repos"][repo_name]["baseSha"],
                                         "to": head, "full": True}
    verify_state.setdefault("reviewerReasons", {})[repo_name] = reason
    if repo_name not in verify_state["pendingReviews"]:
        verify_state["pendingReviews"].append(repo_name)
    if verify_state["phase"] != "verifying":  # a pending verifier routes to review on submit
        verify_state["phase"] = "reviewing"


def _drop_untrusted_reviews(store, paths, ctx, verify_state: dict) -> None:
    """LF-60: state rebuilt for the same inputs still holds each repo's review; one
    whose step has no accepted evidence (accepted by an older auto-waiver, say) is
    reviewed again rather than consumed. Ledger findings stay until a fully
    accepted replacement review dispositions them."""
    project_root = ctx["paths"]["projectRoot"]
    untrusted = [name for name, step_id in verify_state["reviewerSteps"].items()
                 if not steps_module.evidence_accepted(store, project_root, step_id, "code-reviewer")]
    for name in untrusted:
        emit(paths, "review_untrusted", {"repo": name, "byStep": verify_state["reviewerSteps"][name]},
             phase="verify", attempt_id=ctx["attempt"]["id"])
        _requeue_review(store, verify_state, name, "the earlier review of this repo has no accepted evidence")
    if untrusted:
        store.save()


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
    if verify_state is not None and ("inputs" not in verify_state or verify_state["inputs"] != _current_inputs(store)):
        emit(paths, "verify_state_reset",
             {"summary": "verify inputs changed; re-initializing",
              "from": verify_state.get("inputs"), "to": _current_inputs(store)},
             phase="verify", attempt_id=ctx["attempt"]["id"])
        verify_state = None
    if verify_state is None:
        verify_state = _init(store, paths, ctx)
    else:
        _handle_rejection(store, paths, ctx, verify_state)
        _drop_untrusted_reviews(store, paths, ctx, verify_state)

    if verify_state["phase"] == "verifying":
        return IssueStep(_verifier_request(store, paths, ctx, verify_state))
    if verify_state["phase"] == "reviewing":
        return IssueStep(_reviewer_request(store, paths, ctx, verify_state, verify_state["pendingReviews"][0]))
    return Product(_final_product(store, paths, ctx, verify_state))


def on_submit(store, paths, step, result: dict) -> None:
    verify_state = store.state["verify"]
    if step["role"] == "verifier":
        verify_state["verifier"] = result
        verify_state["verifierStep"] = step["stepAttemptId"]
        verify_state["phase"] = "reviewing" if verify_state["pendingReviews"] else "done"
    elif step["role"] == "code-reviewer":
        repo_name = next((name for name in verify_state["pendingReviews"]
                          if verify_state["checkouts"][name] == step["cwd"]), None)
        if repo_name is None:
            raise LoopSpecError(
                f"verify got a code-review submission from {step['cwd']}, which matches no pending review checkout "
                f"({', '.join(verify_state['checkouts'][n] for n in verify_state['pendingReviews']) or 'none pending'})",
                repair="the submitted review's cwd matches no pending VERIFY checkout; check `loop-spec status`",
            )
        verify_state["pendingReviews"].remove(repo_name)
        verify_state["reviewers"][repo_name] = result
        verify_state["reviewerSteps"][repo_name] = step["stepAttemptId"]
        verify_state["phase"] = "reviewing" if verify_state["pendingReviews"] else "done"
    else:
        raise LoopSpecError(f"verify got a submission for an unknown role {step['role']!r}",
                             repair="check the submitted step's role field")
    store.save()


def on_step_refused(store, paths, step_id: str, refused: dict) -> None:
    """LF-60: a VERIFY review refused for want of evidence. The repo is found by the
    refused step's checkout (reviewerSteps is written only on an accepted submit),
    goes back to review in full, and gets a fresh checkout; the quarantined one is
    kept. Mutates state only; the controller saves it with the ownerReset flag."""
    verify_state = store.state.get("verify")
    if verify_state is None or refused["role"] != "code-reviewer":
        return
    repo_name = next((name for name, path in verify_state["checkouts"].items() if path == refused["cwd"]), None)
    if repo_name is None:
        return
    head = verify_state["heads"][repo_name]
    plan_product = store.state["products"]["plan"]["product"]
    verify_state["checkouts"][repo_name] = str(_verify_checkout(
        Path(store.state["repos"][repo_name]["path"]), repo_name, head, plan_product.get("prepare"), paths.checkouts_dir,
        suffix=f"-{step_id}"))
    _requeue_review(store, verify_state, repo_name, f"review step {step_id} refused: {refused['reason']}")
