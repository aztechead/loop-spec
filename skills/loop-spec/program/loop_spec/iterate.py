"""ITERATE's default implementation (M4): one judge step per pass, then the module
picks the exit from the judge's verdict, gaps, and the ledger.

Use `step`/`on_submit` the same way `execute.py` does. Module state lives under
`store.state["iterate"]`, keyed to the current VERIFY heads (per repo, LF-28) so a
later ITERATE entry (after a rewind) issues a fresh judge call while `priorGaps`
keeps accumulating.
"""
import copy
from pathlib import Path

from loop_spec import ledger as ledger_module
from loop_spec import postconditions
from loop_spec import repo as repo_module
from loop_spec import steps as steps_module
from loop_spec.budget import has_room
from loop_spec.errors import LoopSpecError
from loop_spec.events import emit
from loop_spec.steps import IssueStep, Product
from loop_spec.paths import ensure_results_dir
from loop_spec.roles import compose_prompt, load_role, step_request



def _judge_request(store, paths, ctx, heads: dict[str, str]) -> dict:
    project_root = Path(ctx["paths"]["projectRoot"])
    role = load_role("iterate-judge", project_root)
    touched = postconditions.touched_repos(store, heads)

    # LF-63: each touched repo's diff is its own top-level string input, so it renders
    # as real lines; nested in a dict, JSON put a whole diff on one escaped line. A
    # workspace keeps the repo in the key even when only one of its repos changed.
    diff_inputs = {}
    for name in sorted(touched):
        repo_info = store.state["repos"][name]
        diff = repo_module.review_diff(Path(repo_info["path"]), f"{repo_info['baseSha']}..{heads[name]}")
        diff_inputs["diff" if len(store.state["repos"]) == 1 else f"diff:{name}"] = diff

    if touched:
        first_repo = touched[0]
        # D4: VERIFY's product names its checkouts; only a default VERIFY's are used as
        # the judge's working tree, so an external one cannot pick the tree it is judged in.
        verify_product = (store.state["products"].get("verify") or {}).get("product") or {}
        checkouts = (verify_product.get("checkouts") or {}) if postconditions.ran_default(store, "verify") else {}
        checkout = checkouts.get(first_repo)
        cwd = Path(checkout) if checkout else Path(paths.checkouts_dir) / "verify-missing"
        if not cwd.is_dir():
            raise LoopSpecError(
                f"no verify checkout at {cwd}",
                repair="ITERATE runs after VERIFY passed, so verify.py's checkout should still exist",
            )
    else:
        cwd = Path(next(iter(store.state["repos"].values()))["path"])
    # LF-27: under the project root (paths.results_dir), not inside the checkout
    # (a temp dir under the state home a live model cannot always write to).
    ensure_results_dir(paths)
    result_path = paths.results_dir / f"iterate-{ctx['attempt']['id']}.json"

    budget_state = store.state["budget"]
    inputs = {
        "request": store.state["request"]["text"], "spec": store.state["products"]["spec"]["product"],
        **diff_inputs, "verify": store.state["products"]["verify"]["product"],
        "priorGaps": store.state["iterate"]["priorGaps"],
        "budget": {"spent": budget_state["spent"], "limit": budget_state["limit"], "hasRoom": has_room(store)},
    }
    if store.state.get("closeOuts"):
        # LF-55: what earlier rewinds asked EXECUTE to close out, and how each closed.
        inputs["closeOuts"] = store.state["closeOuts"]
    prompt = compose_prompt(role, inputs=inputs, result_path=result_path, cwd=cwd, phase="iterate")
    # simplicity: this build-validate-raise shape repeats verify.py's own request
    # builders and execute.py's (Wave G, out of this wave's file list); a shared
    # helper would need a module none of those three currently import from.
    return step_request("role", "iterate-judge", "iterate", project_root=project_root, ctx=ctx, cwd=cwd, prompt=prompt,
                        result_path=result_path, schema=role.schema)


def _final_product(store, paths, ctx, iterate_state: dict) -> dict:
    judge = iterate_state["judge"]
    ledger_findings = store.state["ledger"]["findings"]
    open_findings = [f for f in ledger_findings if f["disposition"] == "open"]
    # A caveat is an unresolved Important finding: `fixed` (a later review confirmed
    # it) and `rejected` (the reviewer withdrew it with a reason) are closed, and a
    # deferred Minor one is reported (ledger, warnings, PR body) but never a caveat,
    # so it cannot make the PR a draft.
    deferred_important = [f["id"] for f in ledger_findings
                          if f["disposition"] == "deferred" and f["severity"] == "Important"]

    # A "met" verdict over an open ledger finding is not met: reconciled here,
    # before the four rules below ever see it, rather than left as a fifth rule of
    # its own. I4 only accepts "escalated" for a refused rewind (unmet, no budget
    # room) or an unclosable gap (unmet, no gap at all) -- routing a met-but-open
    # verdict to "unmet" with a synthesized gap keeps it on one of those two paths
    # instead of needing a justification of its own.
    #
    # LF-46: nobody dispositions a non-Critical open finding, so it used to force
    # "unmet" forever -- EXECUTE has nothing to do with a Minor finding, VERIFY
    # just re-runs, and the run never converges. The program now dispositions each
    # one itself: Critical always forces a gap (unchanged); Important forces one
    # while the rewind budget has room; Minor, and Important once the budget is
    # out of room, are deferred by policy. Only a deferred Important one is a
    # caveat; a deferred Minor one is reported but converges cleanly. A forced gap is
    # an EXECUTE close-out (LF-55), never a re-plan: a review finding names code to
    # fix, and a PLAN round for it cost 8 to 12 minutes in the timing runs.
    if judge["verdict"] == "met" and open_findings:
        forced_gaps = []
        acted_on = []
        for f in open_findings:
            if f["severity"] == "Critical" or (f["severity"] == "Important" and has_room(store)):
                gap = {"target": "execute", "text": f"open finding {f['id']} ({f['severity']}) at {f['location']}: {f['cause']}",
                       "findingId": f["id"]}
                if f.get("repo"):
                    gap["repo"] = f["repo"]
                forced_gaps.append(gap)
                acted_on.append(f["id"])
            else:
                ledger_module.disposition(store, f["id"], "deferred", "left open at ITERATE; deferred by policy")
                emit(paths, "finding_deferred", {"id": f["id"], "severity": f["severity"]},
                     phase="iterate", attempt_id=ctx["attempt"]["id"])
                if f["severity"] == "Important":
                    deferred_important.append(f["id"])
        verdict = "unmet" if forced_gaps else "met"
        gaps = judge["gaps"] + forced_gaps
        if acted_on:
            emit(paths, "iterate_verdict_reconciled",
                 {"judgeVerdict": "met", "openFindings": acted_on},
                 phase="iterate", attempt_id=ctx["attempt"]["id"])
    else:
        verdict, gaps = judge["verdict"], judge["gaps"]

    # Order matters: "at least one accepted finding" must be checked before the
    # plain "met" rule, or a met verdict with only deferred findings would never
    # reach "converged with caveats". A "met" verdict past
    # the reconciliation above already means no Critical or budget-backed
    # Important finding is left unresolved, so this no longer re-checks
    # open_findings itself.
    if verdict == "met" and deferred_important:
        exit_, caveats = "converged with caveats", deferred_important
    elif verdict == "met":
        exit_, caveats = "converged", []
    elif verdict == "unmet" and gaps and has_room(store):
        exit_, caveats = "rewind", []
    else:
        # The reconciliation above means "met" only ever reaches here with no
        # unresolved finding left to explain, so this now only ever covers
        # "unmet": no gap at all, or a gap but no budget room left to rewind into.
        exit_, caveats = "escalated", []

    return {
        "exit": exit_, "inputsDigest": ctx["inputs"]["digest"],
        "boundTo": {"requirements": store.state["revisions"]["requirements"], "plan": store.state["revisions"]["plan"]},
        "verdict": verdict, "gaps": gaps, "caveats": caveats, "boundShas": iterate_state["boundShas"],
    }


def step(store, paths, ctx):
    heads = postconditions.verified_heads(store)
    iterate_state = store.state.get("iterate")
    if iterate_state is not None and "boundShas" not in iterate_state:
        # A run whose state.iterate predates the per-repo shape has "boundSha"
        # (singular) instead; re-initialize for this attempt, keeping priorGaps
        # (unaffected by the rename) rather than KeyError on the field below.
        emit(paths, "module_state_reset",
             {"summary": "iterate state predates the per-repo shape; re-initializing", "missingKey": "boundShas"},
             phase="iterate", attempt_id=ctx["attempt"]["id"])
        iterate_state = {"priorGaps": iterate_state.get("priorGaps", []), "judgeStep": None,
                          "judge": None, "boundShas": None, "inputs": None}
        store.state["iterate"] = iterate_state
        store.save()
    if iterate_state is None:
        iterate_state = {"priorGaps": [], "judgeStep": None, "judge": None, "boundShas": None, "inputs": None}
        store.state["iterate"] = iterate_state
        store.save()

    # LF-52: a cached judgment is never re-bound to revisions, heads, or an
    # accepted VERIFY attempt it was not made against -- boundShas alone missed
    # a requirements/plan revision change (or a new accepted VERIFY product) at
    # the very same heads.
    inputs = copy.deepcopy({
        "requirements": store.state["revisions"]["requirements"],
        "plan": store.state["revisions"]["plan"],
        "heads": heads,
        "verifyAttempt": (store.state["products"].get("verify") or {}).get("attemptId"),
    })
    if store.state.get("closeOuts"):
        # LF-55: a no-change close-out moves no head and VERIFY reuses its product, so
        # without this the cached judgment would rewind on the same gap again.
        inputs["closeOuts"] = copy.deepcopy(store.state["closeOuts"])
    if iterate_state.get("inputs") != inputs:
        old_inputs = iterate_state.get("inputs")
        iterate_state["judge"] = None
        iterate_state["judgeStep"] = None
        # A copy, not the same dict EXECUTE's own product still holds: aliasing it
        # would make this comparison always equal the moment that product's heads
        # change, since both sides would be the identical object.
        iterate_state["boundShas"] = dict(heads)
        iterate_state["inputs"] = inputs
        emit(paths, "iterate_state_reset",
             {"summary": "iterate inputs changed; a fresh judgment is required", "from": old_inputs, "to": inputs},
             phase="iterate", attempt_id=ctx["attempt"]["id"])
        store.save()

    if iterate_state["judge"] is not None and not steps_module.evidence_accepted(
            store, ctx["paths"]["projectRoot"], iterate_state["judgeStep"], "iterate-judge"):
        # LF-60: a cached judgment with no accepted evidence (an older auto-waiver)
        # is never consumed; a fresh judge is issued.
        emit(paths, "judgment_untrusted", {"judgeStep": iterate_state["judgeStep"],
                                           "summary": "cached ITERATE judgment has no accepted evidence; re-judging"},
             phase="iterate", attempt_id=ctx["attempt"]["id"])
        iterate_state["judge"] = None
        iterate_state["judgeStep"] = None
        store.save()
    if iterate_state["judge"] is None:
        return IssueStep(_judge_request(store, paths, ctx, heads))
    return Product(_final_product(store, paths, ctx, iterate_state))


def on_submit(store, paths, step, result: dict) -> None:
    iterate_state = store.state["iterate"]
    iterate_state["judge"] = result
    iterate_state["judgeStep"] = step["stepAttemptId"]
    iterate_state["priorGaps"] = iterate_state["priorGaps"] + result["gaps"]
    store.save()


def on_step_refused(store, paths, step_id: str, refused: dict) -> None:
    """LF-60: a refused judge step never reached on_submit; drop any judgment so the
    next step() issues a fresh judge. Mutates state only."""
    iterate_state = store.state.get("iterate")
    if iterate_state is not None and refused["role"] == "iterate-judge":
        iterate_state["judge"] = None
        iterate_state["judgeStep"] = None
