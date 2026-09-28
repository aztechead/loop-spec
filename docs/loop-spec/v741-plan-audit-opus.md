# 7.4.1 plan audit (gap 5, rev 1), Opus

For the author of `docs/loop-spec/v741-plan.md`. This audit checks each claim in the plan against
the code on `v7` (`667c587`) and lists what the plan misses. The outcome the user chose
(success, a `no-change` result naming the existing PR, no remote write) is taken as fixed.

## Claims that hold

- `repos[<adopted>].baseSha` is the merge-base, and `adoption.headSha` and `lastKnownHead` are both
  the PR head (`controller.py:367-375`). EXECUTE's product `heads` start at `lastKnownHead`
  (`execute.py:324`, `execute.py:1156`). So an adopted repo left untouched by a no-change run
  has head = PR head, and a non-adopted repo has head = base.
- E9 compares `baseSha..head` (`postconditions.py:742-750`), which on an adopted repo holds the
  PR's own commits. `_final_product` chooses `no change` when no task is done or adopted
  (`execute.py:1138-1145`).
- The two inline start-commit copies exist at `controller.py:511` and `postconditions.py:499`.
- D6 is defined (`postconditions.py:1073`) and no route lists it (`postconditions.py:97-101`).
- VERIFY and ITERATE read EXECUTE's product heads (`verify.py:33-42`, `iterate.py:27-36`). Their
  own `_touched_repos` counts the adopted repo as touched (head differs from the merge-base), so
  VERIFY already reviews merge-base..PR-head in full and re-runs evidence at the PR head.
- `result.pr_url` takes only a `delivered` row today (`result.py:90-95`). The `deliver.json`
  schema already allows a `skipped` row to carry a `pr` object (`schemas/deliver.json`, `repos.items.pr`).
- D1, D2, D3 and D7 skip every non-`delivered` row (`postconditions.py:1000-1086`). D8's
  required set is repos with done or adopted tasks that have commits (`postconditions.py:1096-1099`),
  which is empty on a `no change` exit because E9 allows only `already-satisfied` and `removed`.

## Findings

1. **must-fix: a no-change run becomes the "delivering run" for the next revise round.**
   `_find_delivering_run_products` ranks a run whose result `prs` names the PR above a run that
   only adopted it, and picks the latest finished of those (`controller.py:201-238`, especially
   `:218-236`). Today a no-change run on a PR has no row with a PR, so it is only an
   adoption hit. Under plan item 4 its skipped row carries the PR, `prs` lists it
   (`result.py:90-93`), and as the most recent result hit it wins. The next `revise --pr` then
   gets the no-change run's SPEC and PLAN as `adoption.prior` (`controller.py:280-281`) instead
   of the run that delivered the PR's commits. That changes what the reviser is told was
   delivered and which tasks `_mark_adopted_tasks` treats as adopted (`execute.py:219-252`).
   Fix: have `_find_delivering_run_products` skip a result whose `result` is `no-change`, or
   whose delivery targets have no `delivered` row naming the PR. Add one test in
   `test_controller` for this.

2. **should-fix: the adopted row's `pr.headSha` is never checked against the remote.** Plan items 4
   and 5 set the row's `headSha` from `adoption.headSha`, and D6 compares it only to the local
   verified head. The adoption head is fixed when the run starts (`controller.py:367-375`). A
   `revise --pr` that resumes an unfinished run (`controller.py:263-266`), or any push to the PR
   during a long run, leaves it behind the PR's real head. Today the push in `deliver.run`
   fails non-fast-forward in that case (`deliver.py:240-250`). With no push, nothing notices,
   and the result reports success for a PR head that VERIFY never saw. A read-only
   `gh pr view <n> --json state,headRefOid` in DELIVER or D6 is not a remote write and is not
   the readiness check the user declined. On a mismatch, either fail D6 (pause, re-run) or add a
   caveat to the row. If the author keeps the current design, state in the doc that `headSha` is
   the adoption-time head.

3. **should-fix: the existing `test_d6` breaks as written.** The postconditions fixture's EXECUTE
   exit is `integrated` (`tests/test_postconditions.py:154`). Once D6 returns None unless EXECUTE
   exited `no change`, the `assertIsNotNone` at `tests/test_postconditions.py:759` fails. The
   plan's Tests section lists new D6 cases but does not say that `test_d6` is rewritten. Set the
   fixture's EXECUTE exit to `no change` for the negative cases.

4. **should-fix: the planned deliver test's "no push" assertion would pass without checking anything.**
   The push goes through `repo_module._git(worktree, "push", ...)` (`deliver.py:240`), not
   `run_git`. A test that patches only `run_git` would pass even if a push happened. Patch
   `repo_module._git` (or assert that no call has `"push"` in its args) along with `run_gh`.

5. **should-fix: the doc edits in item 7 leave some doc text false.**
   `phase-interface-7.0.md:295` routes `delivered` to terminal `converged` or
   `converged-with-caveats` only. Add `no-change` to that route cell, not just D6 to Requires.
   The D6 row's Gates cell (`:289`) should read `delivered`. The DELIVER Product row (`:278`)
   should say that a `skipped` row may carry the adopted PR. The Runs-as row (`:280`) should say
   that a `no change` run touches no repo, so there is nothing to push or credential-gate.
   CLAUDE.md requires fixing a doc in the same diff when the change makes it false.

6. **note: E9 also gates `integrated`, and the plan does not mention it.** `integrated` requires
   `!E9` (`postconditions.py:78`, doc `:168`, `:174`). The default EXECUTE is unaffected: it
   exits `integrated` only when some task is done or adopted, so E9's disposition half fails and
   `!E9` still holds. An external EXECUTE that claims `integrated` with every task
   `already-satisfied` on an adopted repo passed before (the PR commits made E9 false) and is
   refused after the change. That is the correct behavior, but the doc's E9 row should state it.

7. **note: the Problem section's "E2/E9 forbid it [`integrated`]" is wrong for the code as it stands.** On an
   adopted repo E9's commit half is false, so `!E9` holds, and E2 accepts `already-satisfied`
   (`postconditions.py:547-575`). What keeps the default EXECUTE off `integrated` is the
   `any_done` rule (`execute.py:1141-1145`). The design does not depend on this claim.

8. **note: "the credential check is skipped too" needs no code change.** The controller still runs
   `_record_deliver_credentials` for every repo at DELIVER entry (`controller.py:614-619`,
   `:1370-1379`), and those calls only read (`repo.py:497-516`). The refusal loop in `deliver.run`
   iterates `touched` only (`deliver.py:183`), so an empty touched set refuses nothing. D7 skips
   `skipped` rows (`postconditions.py:1082-1083`), so D7 holds. Do not remove the controller
   call: `credentialsCheckedForAttempt` is written there.

9. **note: gate on the EXECUTE exit in DELIVER; do not change `deliver._touched_repos` to use the
   start commit.** Plan item 4 does this correctly, and it matters. Under a start-commit
   `_touched_repos`, a revise that exits `integrated` with only `adopted` tasks at the PR head would
   report its repo as skipped, and D8 would then refuse the product ("touched by EXECUTE but
   reported skipped", `postconditions.py:1107-1108`). Say this in the plan so the implementer
   does not "simplify" it.

10. **note: the `verified_head` change keeps existing no-change runs the same.** A default EXECUTE's
    `no change` head for a non-adopted repo is `lastKnownHead` = `baseSha` (`controller.py:354`,
    `execute.py:324`). `commits_between` uses `--no-merges` (`repo.py:217`), so E8 plus E9 do
    not strictly force head == base: an external product could name an empty merge commit.
    Returning the product head is the more accurate value in that case too.

11. **note: workspace with an adopted repo and other repos.** `start_sha` gives the other repos
    `baseSha`, and their heads equal base, so E9 holds for them. D6's rule (a PR only on the
    adopted repo) matches. `verifiedSha` is null for any multi-repo run (`result.py:111-112`).
    No gap.

12. **note: the adopted-range review at EXECUTE entry does not affect the result.** It runs for
    every adopted run, micro and cycle included (`controller.py:598-600`). Its result is read only
    for `adopted` tasks (`execute.py:1127`, `postconditions.py:661-662`), so on a no-change run it
    is a spent step whose findings nothing reads. VERIFY's own full review of merge-base..PR-head
    (`verify.py:198-202`) and V7 still gate the success. This is how the code already behaves and
    is not in scope for this plan.

13. **note: a simpler source for the start commit already exists.** `repos[name]["lastKnownHead"]`
    already holds the start commit for every repo (base, or the PR head), and `roles.repo_map`
    uses it (`roles.py:212-219`). E9 could read it with no new helper. The helper is still
    reasonable because the name `lastKnownHead` suggests a value that moves. Either choice is fine.

14. **note: small reference errors in the plan.** The DELIVER entry point is `deliver.run`
    (`deliver.py:165`), not `deliver.step`. The Live check should be recorded in
    `docs/loop-spec/live-runs-7.0.md` (CLAUDE.md). The version bump and CHANGELOG for 7.4.1 are
    not in this plan. That is fine if the gap 1 to 5 release commit handles them.

verdict: no-go

## Rev 2

Re-audit of `v741-plan.md` rev 2 against the same code (`v7` at `667c587`).

### Rev 1 findings

- R1 (was 1, must-fix): **resolved.** Item 6b makes the delivering-run lookup skip a result hit
  whose `outcome` is `no-change-needed`. `result.json` carries `outcome` from `_OUTCOME`
  (`result.py:23-24`), and the lookup already reads `result.json` (`controller.py:221-225`).
  A new `test_controller` case covers it. One gap remains, in R6 below.
- R2 (was 2, should-fix): **resolved.** Fable's `gh pr view` read now lives in D6 (item 5). This
  audit's view of that addition is in R7.
- R3 (was 3): **resolved.** `test_d6` is rewritten with a `no change` fixture.
- R4 (was 4): **resolved.** The test patches `repo_module._git` and `run_gh` and asserts that
  neither is called with `push` or a PR write.
- R5 (was 5): **resolved.** Item 7 now lists the DELIVER Product and Runs-as rows, D6's Gates,
  and the `delivered` Route (terminal `no-change`).
- Notes 6, 7, 9, 14: **folded in.** Items 1 and 2 cover the `!E9` and `_touched_repos` points,
  the Problem section's `integrated` claim is corrected, and the plan now uses `deliver.run` and
  records the live run in `live-runs-7.0.md`.

### New in rev 2

6. **should-fix: 6b's `outcome` key misses a no-change run that escalated with a partial draft.**
   With `deliver.escalatedPartialDraft: true`, an ITERATE `escalated` routes to DELIVER
   (`controller.py:1435-1441`). If EXECUTE exited `no change`, item 4 still puts the adopted PR on
   the skipped row. `prs` lists every row that has a PR, whatever the classification
   (`result.py:90-93`). The result's `outcome` is then `escalated`, not `no-change-needed`, so 6b
   does not skip it, and it would win the lookup as in rev 1's finding 1. There are two ways to
   close the gap:
   - Key the skip on the run's own `state.products.execute.exit == "no change"`, which the lookup
     already has open as `state`.
   - Count a result hit only when a delivery target with state `delivered` or `failed` names the
     PR.

   The route is rare (the operator has to opt in), so this is should-fix.

7. **Judgment on Fable's addition (D6 reads the live PR): keep it, and write its failure message
   as a repair.** The read is the same one D2 already makes for delivered rows
   (`postconditions.py:1030-1041`). It writes nothing and is not a readiness check. Adoption
   needed working `gh` (`repo.adopt_pr`), so it adds no new dependency. Two consequences for how
   it is written:
   - **should-fix: a moved PR cannot be fixed by re-entering DELIVER.** `adoption.headSha` is
     frozen when the run starts (`controller.py:367-375`). A failed D6 is rejected up to the retry
     limit and then pauses with stop or fix-and-re-enter (`controller.py:1583-1594`). Re-entering
     fails the same way every time. The D6 message should say this: "the PR moved from <adopted>
     to <live> (or is <state>) during the run; stop, then re-run the entry to adopt the new head".
     It should not read as a generic mismatch.
   - **note:** when `gh pr view` itself fails (network, auth), D6 fails and DELIVER retries, the
     same as D2 does today. Name the failed command in the message, as D2 does
     (`postconditions.py:1036-1037`).

8. **note: wrong line cite in item 4.** `deliver.py:190` is the skipped branch inside the
   credential-refusal block. With `touched = {}`, `refused` is empty, so rows take the main loop's
   skipped branch at `deliver.py:198-200`. That is where the adopted row's `pr` goes. The design
   is unaffected.

No rev 2 change breaks an existing path. The `integrated` path with only `adopted` tasks keeps
E9 false (`test_postconditions` covers it). Non-adopted no-change runs still produce all-skipped
rows with no PR, so D6 needs no `gh` call for them. The PR read happens only for the adopted row.

verdict: go
