# 7.4.1 plan, gap 5: a run on an open PR that finds the work already done

For the Fable and Opus auditors of this change. Gaps 1 to 4 of the 7.4.0 handoff are
already committed on `v7` (`5d58bd5`, `30a2df1`, and two doc commits) and are not
under review here. Rev 2: folds in both rev 1 audits (`v741-plan-audit-fable.md`,
`v741-plan-audit-opus.md`); the changes are marked (r2).

## Problem

A run that adopts an open PR (`--pr`, micro or cycle on a PR, or revise) records
`repos[<repo>].baseSha` = the merge-base of the PR head and its base branch, and
`adoption.headSha` = the PR head. When the planner, which reads code at the PR head
since 7.4.0 (F1), plans only `already-satisfied` tasks, EXECUTE's `_final_product`
(`execute.py:1138`) chooses exit `no change`. E9 (`postconditions.py:742`) then fails
because `baseSha..head` contains the PR's own commits. The retries run out and the
run ends blocked. The default EXECUTE cannot exit `integrated` either: its
`any_done` rule (`execute.py:1141`) needs a done or adopted task.

A revise run whose prior plan maps tasks to `adopted` exits `integrated` (the
`adopted` disposition counts as done at `execute.py:1121`), so it does not hit this.

## User decision (2026-09-24)

When an open PR already does what was asked, the run is a success. The result stays
`no-change` (`status: completed`, `outcome: no-change-needed`, `noChangeReason:
already-satisfied`, `converged: true`, `workDelivered: false`). `prUrl` and the
DELIVER row name the existing PR. DELIVER makes no remote write.

## Design

"No change" on an adopted repo is judged from the PR head, not the merge-base.

1. **One start-commit helper.** `postconditions.start_sha(state, repo_name)` returns
   `adoption.headSha` when `adoption.repo == repo_name`, else
   `repos[repo_name].baseSha`. It replaces the two inline copies of that expression,
   `controller._phase_probes` (`controller.py:511`) and P8 (`postconditions.py:499`).
   `roles.repo_map` keeps `lastKnownHead`, since it takes only the repos dict; its
   docstring already says why the two agree. (r2) `verify._touched_repos`,
   `iterate._touched_repos` and `deliver._touched_repos` stay on `baseSha`: VERIFY and
   ITERATE must review and judge the PR's own work over `base..head`, and a revise run
   that exits `integrated` with only `adopted` tasks at the PR head must still count
   its repo as touched, or D8 refuses its DELIVER product.
2. **E9.** `commits_between(path, start_sha(state, name), head)` must be empty. On a
   run with no adoption this is unchanged. The task-disposition half is unchanged.
   (r2) E9 also gates `integrated` through `!E9`. The default EXECUTE is unaffected,
   since it exits `integrated` only with a done or adopted task. An external EXECUTE
   that claims `integrated` on an adopted repo with every task `already-satisfied` and
   no commits after the PR head is now refused, which is correct.
3. **`verified_head`** (`postconditions.py:124`) drops its `no change` special case
   and always returns the product head. For a run with no adoption, E8 (base is an
   ancestor of head) plus E9 (no commits base..head) already make the head the base.
   For an adopted repo it is now the PR head, which is where VERIFY already ran
   (`verify._heads` reads the product heads). This fixes the result's `verifiedSha`.
   (r2) The comments at `verify.py:35` and `iterate.py:29` that describe the special
   case are corrected in the same diff.
4. **DELIVER** (`deliver.run`, r2): when EXECUTE exited `no change`, `touched = {}`
   in `run`, so every row takes the existing skipped branch (`deliver.py:190`) with
   `deliveredSha: null`. In that branch the adopted repo's row carries `pr` =
   `{number, url, headRef, headSha, base}` from `adoption` (`headSha` =
   `adoption.headSha`, `base` = `adoption.baseBranch`). Today `_touched_repos` counts
   the PR's commits as touched and would push. The gate is on the EXECUTE exit, not a
   start-commit `_touched_repos` (see item 1). The controller's read-only credential
   check (`_record_deliver_credentials`) still runs; `run`'s refusal loop iterates
   `touched`, so it refuses nothing, and D7 skips `skipped` rows.
5. **D6** (`postconditions.py:1073`) is defined but no exit lists it, so it never
   runs. Wire it: `delivered` requires D6, and `_d6` returns None unless EXECUTE
   exited `no change`. Its rule becomes: every row is `skipped` with no
   `deliveredSha`; a row has a PR only for the adopted repo, and that PR is the
   adoption's number with `headSha` equal to `verified_heads(store)[adoption.repo]`
   (r2: per repo, not `verified_head`, so a workspace run is right). (r2) For that
   row D6 also reads the live PR with the same read-only call D2 makes,
   `gh pr view <n> --json state,headRefOid`: state `OPEN`,
   `headRefOid` equal to the row's `headSha`. A PR that moved during the run fails D6,
   so the run never reports success for a head VERIFY did not see. This is a read,
   not the readiness check the user declined.
6. **Result** (`result.py:90`): `pr_url` also takes a `skipped` row's PR when the
   classification is `no-change`. `prs` already lists every row with a PR.
   `workDelivered` stays false because no row is `delivered`.
6b. **(r2) Delivering-run lookup.** `controller._find_delivering_run_products`
   (`controller.py:201`) ranks a run whose result `prs` names the PR above a run that
   only adopted it. After item 6 a no-change run's result names the PR, so the next
   `revise --pr` would take the no-change run's SPEC and PLAN as `adoption.prior`. The
   lookup skips a result hit whose `outcome` is `no-change-needed`; such a run can
   still be an adoption hit, which counts only when no run delivered the PR.
7. **Docs in the same diff.** `phase-interface-7.0.md`: the E9 row ("`start..head`
   is empty, where start is the base, or the adopted PR's head"; it forbids
   `integrated`), the `no change` route (r2: "VERIFY at the head, over
   `base..head`"), the VERIFY precondition (line 201), the DELIVER Product row (a
   `skipped` row may carry the adopted PR) and Runs-as row (a `no change` run touches
   no repo, so nothing is pushed), the D6 row (its rule, and Gates = `delivered`),
   the `delivered` exit row (Requires adds D6; Route adds terminal `no-change`), and
   the terminal-results row for `no-change` (`prUrl` names an adopted PR).
   `external.POSTCONDITION_TEXT` E9 and D6, and `postconditions.ROUTES` `delivered`.

## Tests

- `test_postconditions`: E9 passes on an adopted repo whose head is the PR head and
  fails when a commit follows the PR head; (r2) `integrated` with only `adopted` tasks
  at the PR head still has E9 false. (r2) The existing `test_d6` is rewritten, since
  its fixture's EXECUTE exit is `integrated`: with exit `no change`, D6 passes for the
  adopted-PR row with a stubbed `gh pr view` at that head, and fails for a PR on a
  non-adopted repo, a `delivered` row, and a PR whose live head moved; D6 is inert
  when EXECUTE exited `integrated`.
- `test_deliver`: a `no change` EXECUTE on an adopted run produces all-`skipped`
  rows and the PR on the adopted row, (r2) with `repo_module._git` and `run_gh`
  patched and asserted never called with `push` or a PR write.
- (r2) `test_controller`: `_find_delivering_run_products` returns the delivering
  run, not a later no-change run whose result names the same PR.
- `test_result`: `no-change` with an adopted row has `prUrl` = the PR URL and
  `workDelivered` false.
- Existing `verified_head` callers' tests stay green.

## Live check

Micro on a fresh fixture PR in live-7 that already does what the request asks.
Expected: EXECUTE `no change`, VERIFY at the PR head, result `no-change` with
`prUrl` = the PR, no push. This run also confirms that a lead follows the rewritten
`references/runner.md` (gap 2). (r2) Recorded in `docs/loop-spec/live-runs-7.0.md`
with evidence. The 7.4.1 version bump and CHANGELOG are a separate commit after
this one.

## Out of scope

- `roles.repo_map`'s `lastKnownHead` vs `adoption.headSha` (item 1 explains).
- A PR comment or a readiness check on the adopted PR (the user chose neither).
