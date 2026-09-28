# Audit of the 7.4.2 plan (rev 1), Fable

For the author of `docs/loop-spec/v742-plan.md`. Each finding names the code it rests
on at `1f23578`; paths are under `skills/loop-spec/program/` unless absolute.

## Findings

1. **must-fix** — Fix 2 marks tasks only in EXECUTE `_init`, which never runs on the
   path the evidence shows. `execute.step` calls `_init` only when
   `store.state["execute"]` is None (`loop_spec/execute.py:1186-1190`); a re-plan
   after a plan gap goes through `_reconcile_plan`, which returns before touching
   any task when every snapshot still matches (`execute.py:990-991`) and otherwise
   rebuilds a task through `_fresh_task_state` (`execute.py:1024-1026`, `1067`). The
   live run's round 2 took exactly this path (`events.jsonl`:
   `execute_plan_reconciled ... reset 1` at 20:28). A planner that re-plans an
   unchanged task and only adds `alreadySatisfied` leaves the task `pending` and
   dispatched; the fix does nothing in the case it was written for. Put the marking
   in `_fresh_task_state` (covers init, reset and added) and add `alreadySatisfied`
   to `_PLAN_IDENTITY_FIELDS` (`execute.py:59`) so newly marking a task counts as a
   plan change. That also settles the adopted/already-satisfied precedence the
   plan leaves open: the prior plan's tasks carry no `alreadySatisfied`, so a marked
   task never matches (`execute.py:233`) and is never `adopted`. Do not re-apply the
   mark on later `step()` calls: a VERIFY `implementation gap` re-opens a task by
   criteria regardless of its status (`execute.py:905-907`, `_reopen` at `823-848`
   re-forks a task with no worktree), and a mark re-applied after that would undo
   the remediation.

2. **must-fix** — Fix 1 leaves the lead's `cwd` on the operator's checkout and adds a
   `codePath` hint. The planner lead's cwd is `first_repo["path"]`
   (`loop_spec/defaults.py:48, 65, 68`), the critic's is `repo_path`
   (`loop_spec/controller.py:1042, 1047`), the reviser's is `repo_path`
   (`loop_spec/revise.py:88, 93`), and `compose_prompt` makes that cwd the first
   line the model reads plus a `cd {cwd} &&` prefix on every command
   (`loop_spec/roles.py:222-231`, LF-08/15/20). The cause the plan names is that the
   lead ignored a prose instruction (`roles/planner/SKILL.md:21-22`); `codePath` is
   another prose instruction contradicted by the cwd line. Set cwd to
   `startCheckout` when it exists at those three sites (three one-line edits) and
   keep `codePath` in `repo_map` for workspace repos. A worktree shares the object
   store, so `git cat-file -e <baseSha>:<path>` and `git show` still work there.

3. **should-fix** — a re-plan after EXECUTE integrated commits reads stale code. P8
   resolves cites at the start commit *and* at the accepted EXECUTE product's heads
   (`loop_spec/postconditions.py:492-501`; `phase-interface-7.0.md:142`), and the
   planner is told cites may be "at the head for code an earlier task of this run
   added" (`roles/planner/SKILL.md:69-70`). Fix 1's checkout is always at
   `start_sha`, so on a plan-gap or VERIFY plan-gap re-plan the planner reads a tree
   without this run's own commits. Check out at the execute head when the EXECUTE
   product publishes one for the repo (the same rule P8 uses), or state in the plan
   that a re-plan deliberately reads the start. (`_phase_probes` has the same
   staleness today, `controller.py:513`; pre-existing, not this change's.)

4. **should-fix** — `revise.json` and `debug.json` embed their own task schema with
   `additionalProperties: false` (`loop_spec/schemas/revise.json:82-83`,
   `schemas/debug.json:136-146`). The plan edits only `plan.json`, so a reviser or
   debugger that sets `alreadySatisfied` fails its own product validation, while
   "Reviser: unchanged. Its plan tasks go through the same EXECUTE init" implies it
   may. Either add the field to all three schemas (and tell the reviser in its
   SKILL.md, since a revise run on a PR that already addresses a comment has the
   same waste), or say explicitly that only PLAN's product may carry it.

5. **should-fix** — the debug entry is missing from Fix 1. Every entry except
   `auto` and `direct` adopts a PR the request names (`controller.py:149`), so a
   debug run can have a start commit that is not its base; `_phase_probes` already
   treats `debug` like `plan` (`controller.py:511`). The plan ensures the checkout
   only for `plan` and `revise` envelopes, so the debugger's compact PLAN cites the
   operator's tree. Add `debug` to the set or state why it is excluded.

6. **note** — Fix 3's claims hold. `adoptedReview` is read at
   `postconditions.py:663` (E5, gated on disposition `adopted`) and
   `adoptedReviewStepId` at `postconditions.py:172-177` (`review_evidence`, same
   gate); the controller only stores and resets it (`controller.py:1777-1778`,
   `1796-1798`). Only VERIFY records reviewed ranges into the ledger
   (`controller.py:1547-1551`, `ledger.py:58`), so the adopted review never
   shortened VERIFY's range: a first VERIFY pass reviews `base..head` in full
   (`verify.py:200`). Dropping the review for a run with no adoptable task removes a
   duplicate, it does not move work to VERIFY. `_adopt` and `_resolve_repos` set
   `adoption` for cycle and micro too (`controller.py:365-383`, `339-362`), so the
   waste applies beyond revise.

7. **note** — Fix 3's module placement is allowed. `test_architecture.py:8-9,
   51-57` forbids core importing a plugin; `execute` importing from
   `postconditions` is the permitted direction, and `adoption` is not a plugin
   bucket. `start_sha` and `adopted_commits` (`postconditions.py:140-153`) are the
   precedent for a shared adoption fact living there. The controller's trigger
   needs the current plan tasks, which are in `state["products"]["plan"]` at EXECUTE
   entry (`controller.py:599`), so no ordering problem.

8. **note** — Fix 2 does not weaken an E-check. E2 requires evidence for
   `already-satisfied` (`postconditions.py:546`), and the plan's evidence string is
   non-empty. E3 accepts an `already-satisfied` dependency (`:616`). E4, E5 and E6
   skip it; the close-out branch of E6 applies only to `C-n` registry ids, which are
   never plan tasks (`execute.py:983-985`). E9 holds because `start..head` is empty
   by construction (`:747-751`). ITERATE and VERIFY preconditions already accept
   `no change` (`controller.py:392-396`). The one thing the plan should say: an
   `alreadySatisfied` task in a base-start run with `featureAdded` set is
   contradictory; the critic rule at `roles/plan-critic/SKILL.md:77` (a
   `featureAdded` path present at base) already catches it, so cite that rather than
   adding a P-check.

9. **note** — the skip-work risk is bounded but real on a base-start run. P8's cite
   check proves a range exists, not that the code does the task; the critic is the
   only content check. On a run whose head equals base, VERIFY issues no reviewer
   (`verify.py:42`, `touched` empty) and the verifier reads the operator's checkout
   for an untouched repo (`verify.py:232-235` comment; pre-existing). A wrong mark is
   recoverable through the VERIFY remediation path (finding 1), so this is a prompt
   matter: the planner text should require that each cited range satisfies the
   task's `criteria`, not merely "does what the task would do".

10. **note** — checkout lifecycle. `clean_checkout` raises when `dest` exists
    (`repo.py:308-312`), so "create only if absent" must test the directory, and a
    resume where the operator deleted the directory but git still lists the
    worktree needs `git worktree prune` before re-adding. A detached worktree at a
    SHA the feature worktree also has is allowed by git (only a branch is
    exclusive), and the adopted review's `adopted-<sha>` path is distinct
    (`controller.py:1728`), so no collision. `_finish_run` removes every worktree
    under `paths.root` on a terminal result (`controller.py:1655-1658`) and
    quarantines a dirty one, which covers the new checkout. Simpler shape: create
    the start checkout before `_phase_probes` and run the named-file probes in it
    instead of the throwaway `plan-probes-*` checkout (`controller.py:528-534`),
    so PLAN makes one worktree, not two.

11. **note** — `state.repos[name].startCheckout` reaches the lead unchanged:
    `build_envelope` passes `state["repos"]` as `repos` (`controller.py:573`),
    `run_lead_phase` reads it (`defaults.py:44-48`), and `context.json` does not
    constrain repo entries (`schemas/context.json:57`). `repo_map` derives
    `startSha` from `lastKnownHead` (`roles.py:212-219`), a duplication
    `architecture.md:51-53` already records; Fix 1 adds a third spelling of the same
    fact. Out of scope, but worth a line in that doc.

12. **note** — the plan's timing table matches `events.jsonl`: PLAN 1 20:13:39 to
    20:21:59 (includes the answer-policy question), EXECUTE 1 20:21:59 to
    20:24:24, PLAN 2 to 20:28:28, EXECUTE 2 to 20:30:07. The adopted review step
    (`step-3f6f1abdd317`) was issued before the first EXECUTE attempt and no
    `task_adopted` event followed, which is the unused-review case Fix 3 removes.

verdict: no-go

## Rev 2

Both rev 1 must-fixes are resolved as written, and rev 2's additions hold against the
code.

1. **resolved (rev 1 #1)** — marking in `_fresh_task_state` covers `_init`
   (`execute.py:328`), `added` (`:1024`) and `reset` (`:1067`); `alreadySatisfied` in
   `_PLAN_IDENTITY_FIELDS` turns a mark added or removed on a re-plan into a
   snapshot change, so the early return at `:990` no longer swallows it. Skipping
   `_refork` for a marked task in the `reset` branch is right (`:1069-1075` would set
   `pending`). `_plan_snapshot` omitting a null key keeps 7.4.1 snapshots equal
   (`changed_fields` uses `.get`, `:1032`). A remediation `_reopen` never rebuilds
   fresh state, so the mark does not re-apply (`:823-848`). P8 refusing a marked task
   that owns integrated commits runs before `_reconcile_plan` would `_reopen` it
   (`:1043-1057`), so the two rules never disagree.
2. **resolved (rev 1 #2)** — cwd at the checkout for the planner lead, the critic and
   the reviser; the debugger keeping its cwd is consistent with the program's own
   reproduction checkout (`controller.py:815-816`).
3. **note** — `codeCheckout` in `state.repos` enters the envelope's inputs digest
   (`controller.py:548`), so the digest changes whenever a checkout is replaced.
   That digest is only recorded on steps and products (`steps.py:158`,
   `controller.py:795-797, 1524`), never compared for staleness, so nothing
   re-issues on it. No action.
4. **note** — a lead that leaves scratch in its checkout makes `_finish_run` skip it
   as dirty and add a `cleanupBacklog` row (`repo.py:296-299`,
   `controller.py:1658-1661`). Same behavior task worktrees already have; the live
   check will show whether planners do this.
5. **note** — Fix 3's external-EXECUTE trigger reads
   `state["implementations"]["phases"]`, not a plugin bucket, so
   `test_architecture.py` is unaffected; `_mark_adopted_tasks`'s repo filter
   (`execute.py:236-238`) must move with the loop, as the plan says.
6. **note** — "the accepted EXECUTE product's head" for the code commit is the same
   source P8 reads (`postconditions.py:492`), so a plan-gap re-plan cites and reads
   at one commit.

verdict: go
