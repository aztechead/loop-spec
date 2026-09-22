"""The external placeholder implementation: a human or an out-of-process actor does
the phase's real work; the program's job is to state the contract and recognize done.

Use `run` as the implementation `contract.invoke`/`contract.run_phase` call when a
phase is bound to "external", the only implementation with real behavior in M1.
`PHASE_EXITS`, `PHASE_POSTCONDITIONS`, and `POSTCONDITION_TEXT` are the matrix data
every wave importing this module (wave D's postconditions/controller) reuses rather
than re-transcribing docs/loop-spec/phase-interface-7.0.md a second time.
"""
from pathlib import Path

from .jsonio import atomic_write_json, read_json
from .schema import load_schema, validate

PHASE_EXITS: dict[str, list[str]] = {
    "spec": ["approved", "needs answer"],
    "plan": ["ready", "spec gap"],
    "execute": ["integrated", "no change", "blocked", "plan gap"],
    "verify": ["passed", "implementation gap", "plan gap", "intent gap", "evidence incomplete", "blocked"],
    "iterate": ["converged", "converged with caveats", "rewind", "escalated"],
    "deliver": ["delivered", "partially delivered", "delivery blocked"],
    "debug": ["reproduced", "blocked reproduction"],
}

PHASE_POSTCONDITIONS: dict[str, list[str]] = {
    "spec": ["S1", "S2", "S3"],
    "plan": ["P1", "P2", "P3", "P4", "P5", "P6", "P7"],
    "execute": ["E1", "E2", "E3", "E4", "E5", "E6", "E7", "E8", "E9", "E10", "E11"],
    "verify": ["V1", "V2", "V3", "V4", "V5", "V6", "V7", "V8", "V9"],
    "iterate": ["I1", "I2", "I3", "I4", "I5", "I6"],
    "deliver": ["D1", "D2", "D3", "D4", "D5", "D6", "D7", "D8"],
    "debug": ["B1", "B2", "B3"],
}

# One line per id, copied from docs/loop-spec/phase-interface-7.0.md (the "Postcondition"
# column of each phase's table).
POSTCONDITION_TEXT: dict[str, str] = {
    "S1": "product validates against the SPEC schema",
    "S2": "an approval record exists, produced from a human or policy answer to a question that names the proposed requirements revision, and the record references that question id",
    "S3": "the product's own fields did not create the approval record; only the program writes it",
    "P1": "product validates; bound to the current requirements revision",
    "P2": "every criterion id in the requirements revision is covered by at least one task",
    "P3": "every verify command either ran at the base SHA from a bare worktree root during baseline capture, or is declared featureAdded with a target path that does not exist at base",
    "P4": "the baseline is captured (section 11) with the prepare command applied; environment health recorded once per failing command",
    "P5": "the task graph is acyclic and every dependsOn names a task in the plan",
    "P6": "workspace resolved once and the repo list stored in state; every task names a repo in it",
    "P7": "the critic pass ran and every Critical finding is closed as fixed with the critic re-run once on the corrected product, or rejected with a stated reason recorded in state; deferred is not a disposition for Critical; a Critical finding still open after the one re-run exits spec gap or asks a question",
    "E1": "product validates; bound to the plan and requirements revisions per repo",
    "E2": "every required task has an accepted disposition",
    "E3": "for every task, its dependencies completed before it was dispatched",
    "E4": "every commit in base..head maps to exactly one done or adopted task (an adopted PR's own commits count as mapped); a merge commit the program recorded while integrating two same-wave siblings is not a task commit and is excluded from base..head on both sides of the comparison",
    "E5": "every done or adopted task has a review record whose reviewed range covers all of that task's commits; for an adopted task the record comes from a full review step the program ran over the adopted range at entry, never from the PR's own history",
    "E6": "every such review record's evidence level meets the accepted class for review steps; otherwise the task is listed in unreviewed",
    "E7": "each task's verify command produced no new failure identity against its baseline; a featureAdded command had a meaningful first success (exit zero, at least one parsed identity where a parser exists) that became its task-local baseline; a mustFlip command failed at baseline with the recorded digest and passes at integration",
    "E8": "the feature head is reachable from base and was not moved out of band",
    "E9": "base..head is empty and every task is already-satisfied or removed",
    "E10": "a rejected step was re-issued with its reason up to the per-step retry limit before blocked is claimed",
    "E11": "for a task touching a file with a security signal, the review record carries a disposition per signal",
    "V1": "product validates; bound to both revisions",
    "V2": "every criterion id in the requirements revision has exactly one verdict",
    "V3": "every evidence SHA equals the verified head of its repo",
    "V4": "for every criterion without a V5 exception, its cited command was run by the program in a clean checkout of that SHA it created, with prepare fixtures applied (that execution may be reused across submissions naming the same repo, SHA, and command, but is re-matched against each submission's own claim, never a fact an earlier claim left recorded), and command identity, exit status, parsed failure identities, and normalized output digest matched",
    "V5": "a criterion skipped V4 only under an exception declared in the PLAN product and approved with it, or granted by an operator answer at VERIFY; its verdict is recorded at assurance claimed and listed under weakenedAssurance",
    "V6": "a blocked verdict cites a cause the program observed, in the baseline record or in its own re-run",
    "V7": "every verdict is pass and the review policy holds per repo: first and final passes saw that repo's full diff, other passes the delta since its last reviewed SHA, no Critical finding open",
    "V8": "a finding on cleared code carries a typed supersedes naming a finding id or a reviewed-range id",
    "V9": "blocked for an offline-unavailable dependency was claimed only after a stand-in was tried",
    "I1": "product validates; the verdict binds every repo's integrated SHA (boundShas), the requirements revision, and the plan revision",
    "I2": "every gap names a target of SPEC, PLAN, EXECUTE, or VERIFY",
    "I3": "T1 holds for this rewind",
    "I4": "a rewind is needed and T1 refuses it, or the verdict is unmet and the judge names no gap any route can close",
    "I5": "VERIFY passed at this SHA and no open gap against the original goal; the shared convergence predicate",
    "I6": "no Critical finding open; the caveats list contains only accepted non-Critical review findings, each with a recorded disposition, and nothing else",
    "D1": "per touched repo, the remote head ref's SHA equals the verified SHA",
    "D2": "per touched repo, the PR is open, its head ref and SHA match, and its base target matches configuration",
    "D3": "required checks satisfy the configured readiness policy (6.9's exact-SHA and required-check behavior)",
    "D4": "a retried creation was reconciled by identity against existing remote state; no duplicate PR",
    "D5": "partial publication is recorded per repo and never reported as all delivered",
    "D6": "a no change head that ITERATE converged opened no PR and the product says so",
    "D7": "before the first remote write the program checked git and gh credentials and attempted the host's own refresh; a failure exits delivery blocked naming the command",
    "D8": "the product's repos cover exactly the set of repos EXECUTE touched with an accepted task's commits, no duplicates; a skipped row is only valid for a repo EXECUTE did not touch; every row marked delivered has a non-null PR",
    "B1": "the program ran the recorded reproduction at base in a clean checkout and it failed with at least one parsed identity or fingerprint; the failure digest it recorded is the mustFlip baseline",
    "B2": "a changed reproduction states a reason and the original was run too, with both results recorded",
    "B3": "no reproduction exists",
    "T1": "the shared feature-level budget has room and this transition was counted once against it; default two, operator override, persisted across sessions, never reset by a fresh attempt",
}


def run(context_path: Path, product_path: Path, phase: str) -> int:
    context = read_json(context_path)
    product_path = Path(product_path)

    by_question = context.get("answers", {}).get("byQuestion", {})
    external_done = any(answer.get("value") == "external-done" for answer in by_question.values())
    already_valid = product_path.is_file() and not validate(read_json(product_path), load_schema(phase))
    if external_done or already_valid:
        return 0

    repos = context.get("repos") or {}
    # `repos` is the repo-name-keyed map the controller stores, not a list; take
    # whichever repo sorts first as "the" repo for a single-repo M1 run.
    first_repo = next(iter(repos.values()), None) if isinstance(repos, dict) else (repos[0] if repos else None)
    cwd = first_repo["path"] if first_repo else context["paths"]["stateDir"]
    exits = PHASE_EXITS[phase]
    postcondition_ids = PHASE_POSTCONDITIONS[phase]
    postcondition_lines = "; ".join(f"{pid}: {POSTCONDITION_TEXT[pid]}" for pid in postcondition_ids)
    prompt = (
        f"Phase {phase.upper()} is implemented externally. Produce `product.json` at "
        f"{product_path} matching the {phase} schema and declaring one exit from: "
        f"{', '.join(exits)}. The program will check these postconditions: {postcondition_lines}"
    )
    step_request = {
        "kind": "external", "role": None, "phase": phase, "cwd": str(cwd), "prompt": prompt,
        "resultPath": str(product_path), "schema": load_schema(phase), "postconditions": postcondition_ids,
        "attempt": context["attempt"]["id"], "inputsDigest": context["inputs"]["digest"],
        "retryOf": None, "reason": None,
    }
    atomic_write_json(product_path.parent / "step.json", step_request)
    return 2
