# 7.4.2 plan audit (Opus)

For the author of `docs/loop-spec/v742-plan.md` (Rev 1). Each finding below was checked
against the code at `1f23578`. Scope stays at the three fixes the user asked for.

## Findings

1. **must-fix: a mark added on a re-plan never takes effect, and a task in `planGap` loops.**
   The plan marks tasks only in `_init` (plan: "execute init (`execute.py:~329`)"). `_init`
   runs once, when `state.execute` is None (`execute.py:1188-1189`). On every later entry
   `_reconcile_plan` runs instead (`execute.py:1190`), and it compares only
   `_PLAN_IDENTITY_FIELDS` (`execute.py:59`, `:1030-1031`). The second plan in
   `v741-g5` is the pass where a planner would add the mark (after the plan gap). If that
   pass adds only `alreadySatisfied`, the task counts as unchanged ("kept") and keeps
   status `planGap`. `step()` then returns a `plan gap` product at once
   (`execute.py:1207-1208`), which sends the run back to PLAN again with no step in
   between. The reverse case is also broken: a re-plan that removes a wrong mark keeps
   the task `already-satisfied`, so it is never dispatched.
   Fix: add `alreadySatisfied` to the identity fields, and apply the mark wherever
   fresh state is built (`_fresh_task_state`, `execute.py:267`). Also make the
   `_refork` in the reset branch (`execute.py:1076`), which sets `pending`
   (`execute.py:813`), skip a marked task. Decide what happens to a marked task that
   already owns integrated commits: refuse it, or ignore the mark. Add a
   `test_execute` case for the kept-planGap re-plan.

2. **must-fix: Fix 3 drops the adopted review that an external EXECUTE needs.** The plan
   says a task is adopted "only when the delivering run's prior plan has a matching
   task (`execute.py:219-252`)". That holds only for the default EXECUTE. An external
   EXECUTE product sets its own dispositions, `adopted` included
   (`phase-interface-7.0.md:154`, `:376`). E5 fails any `adopted` task when
   `state.adoptedReview` is missing (`postconditions.py:663-664`). With the new trigger,
   an external EXECUTE on a PR with no prior never gets the review, so each product it
   submits is rejected. The plan's test claim is also false.
   `test_revise_entry_adopts_pr_and_reaches_execute` has no prior run on disk, because
   `prior` comes from `_find_delivering_run_products` (`controller.py:284`). It runs
   EXECUTE external (`_EXTERNAL_ENV` sets `LOOP_SPEC_PHASE_EXECUTE=external`, `tests/test_controller.py:28`, `:1200`), and it asserts
   that the review is issued (`tests/test_controller.py:1225-1245`). Under the planned
   predicate the set is empty and that assertion fails.
   Fix: issue the review when `implementations.phases.execute == "external"` or the
   adoptable set is non-empty. Keep that test as the external case. The prior-run
   test (`tests/test_controller.py:1248`) is the default case.

3. **must-fix: Fix 1 misses the debug entry, and in an adopted debug run the critic
   would read worse code than it does today.** The checkout is created only when
   building the envelope "for `plan` or `revise`". A debug run can adopt a PR, because
   `_run_request_entry` passes `find_pr_reference` for every request entry but auto and
   direct (`controller.py:149`). Its PLAN arrives by compaction
   (`controller.py:796-798`, `:849-864`), and the plan critic is issued from
   `_handle_plan_baseline_and_critic` (`controller.py:1109`) without a `plan` envelope
   ever being built. So `startCheckout` is never set, `codePath` falls back to the
   operator's checkout, and the edited critic `SKILL.md` no longer says to use
   `git show <startSha>`. Today's critic reads at the start commit
   (`roles/plan-critic/SKILL.md:18-21`). The debugger also reads `repo_map`
   (`debug.py:34`).
   Fix: create the checkout where the start commit is fixed, not per phase envelope.
   Either do it right after `_resolve_repos`/`_adopt` (`controller.py:339-381`,
   `_hand_off` included), or use an `ensure_start_checkout(store, paths)` that every
   `repo_map` caller runs first. `_phase_probes` already covers `debug`
   (`controller.py:510`); the plan names only `plan` and `revise`.

4. **should-fix: `codePath` = the operator's checkout for a repo whose start is its base
   makes the new skip rest on a working tree that may be dirty.** The base is the
   operator's HEAD when the run starts (`controller.py:353-357`). Uncommitted edits, or
   a branch switched during a 20-minute run, are not at the base. Today the critic
   avoids both with `git show`. With Fix 1 the planner and the critic read the working
   tree, and P8 only checks line counts at the start commit (`postconditions.py:504-511`).
   A task marked from uncommitted work passes PLAN and EXECUTE, and VERIFY catches it,
   at the cost of one VERIFY round and a remediation. The cost argument ("not worth its
   cost now") does not hold: every PLAN attempt with named files already makes and
   removes a clean checkout at `start_sha` (`controller.py:521-533`). Simpler: always
   make the start checkout for every repo, and run `plan_probes` in it instead of the
   per-attempt `plan-probes-…-uuid` checkout. That removes the base-versus-adopted
   branch and one checkout per PLAN attempt.

5. **should-fix: reusing the checkout needs a cleanliness and registration check.**
   "created … only if absent" reuses the directory whenever it exists. The planner has
   Bash (`roles/planner/SKILL.md:4`), so a dirty checkout would be read as the start
   commit. A directory that was deleted while still registered makes
   `git worktree add` fail (`repo.py:312`, "missing but already registered"). On reuse,
   check `repo_module.is_clean` and HEAD == sha. Otherwise prune and recreate, or use a
   fresh name as `_issue_adopted_review` does (`controller.py:1729-1731`). A detached
   worktree at a SHA that is also checked out elsewhere is fine (`repo.py:312` uses
   `--detach`, and the feature worktree holds the branch). This applies to the
   `adopted-…` checkout at the same SHA too.

6. **should-fix: the schema change has to reach the two pinned copies, and the plan does
   not say what the field means there.** `test_verify_plan_task_def_matches_plan_schema`
   and `test_debug_spec_and_plan_defs_match_products_minus_envelope` require
   `verify.json#/$defs/planTask` and `debug.json#/$defs/plan` to equal `plan.json`
   (`tests/test_schema.py:165-189`). The field would then be allowed on VERIFY
   `remediationTasks` (`schemas/verify.json:274-277`), where it means nothing, and on a
   debug repair task, which `compact` pins as `mustFlip`
   (`debug.py:67`). There a mark contradicts B1's failing reproduction. Name both
   files in the plan, and either refuse `alreadySatisfied` with `mustFlip` (in P8 or
   the debug form check) or break parity for the verify copy with a comment.
   `schemas/revise.json` and `roles/reviser/schema.json` keep their own task shape
   with `additionalProperties: false`, so "Reviser: unchanged" means the reviser
   cannot mark tasks. State that so no one expects it to.

7. **should-fix: the planner and critic contracts live in `roles.CONTRACTS`, and the plan
   edits only `SKILL.md`.** `CONTRACTS["plan-critic"]` is appended to every critic prompt,
   bound skills included (`roles.py:151-160`, `:237-239`). It still makes "an
   `existingCode` entry marked `new` for behavior … code already implements" Critical,
   and it says nothing about `alreadySatisfied`. `CONTRACTS["planner"]`
   (`roles.py:140-150`) does not name the field, so a project that binds its own planner
   skill never learns it. Add one sentence to each.

8. **should-fix: the critic rule contradicts itself.** The plan says "never raise 'this
   already exists' against a task that is not marked, but say so as the fix". The
   critic's only output is Critical findings (`roles/plan-critic/SKILL.md:34-40`,
   `roles.py:159-160`), so a note that is not Critical cannot reach the planner.
   Choose one. (a) An unmarked task whose cited code already does the whole task is
   Critical, with the cause "mark T-n alreadySatisfied citing …". This costs one re-pass
   and saves an implementer. (b) Leave it out, and the implementer's "already
   satisfied:" path (`execute.py:1291-1305`) handles it. Also reconcile the choice with
   rule 6's "a later check already covers the flaw → not Critical"
   (`roles/plan-critic/SKILL.md:36-40`).

9. **should-fix: the plan misses a doc row.** The revise entry row states that "At EXECUTE
   entry the program runs a full review step over the adopted range"
   (`phase-interface-7.0.md:376`). After Fix 3 (with finding 2) it runs only when a task
   is adoptable or EXECUTE is external. Add that row to "Docs in the same diff".
   `architecture.md:51-53` already names the `startSha` split (`lastKnownHead` in
   `repo_map` against `adoption.headSha` in `start_sha`). `codePath` is checked out at
   `start_sha` while `repo_map` shows `startSha = lastKnownHead` (`roles.py:212-219`).
   Build both from `postconditions.start_sha`, or keep that note accurate.

10. **note: the prompt header still points the lead at the operator's checkout.**
    `compose_prompt` puts `WORKING DIRECTORY: {cwd}` and "every command starts with
    `cd {cwd} &&`" first (`roles.py:228-231`). For the planner, `cwd` is the first
    repo's path (`defaults.py:48`), and the reviser (`revise.py:88`) and critic
    (`controller.py:1042`) get the same. The cause of `v741-g5` was a lead ignoring
    an explicit read-at-`startSha` instruction, and Fix 1 replaces that with another
    instruction. For a single-repo adopted run, consider making the lead's `cwd` the
    start checkout, so the header itself names the right tree. The result path is
    absolute under `.loop-spec/results`, so writes are unaffected. In a workspace, the
    first repo need not be the adopted one.

11. **note: the adoption predicate in `postconditions` fits
    `tests/test_architecture.py`, but only loosely fits `CLAUDE.md`.** Core modules may
    not import plugins, and plugins may import core
    (`tests/test_architecture.py:56-63`). `adoptable_task_ids` reads `adoption.prior`, not
    a plugin bucket, so the guard passes. `postconditions` is the least bad core home,
    and `start_sha` and `adopted_commits` (`postconditions.py:140-155`) are already there
    as helpers. `CLAUDE.md` says the module "only answers whether a claimed exit holds",
    so update the module docstring (`postconditions.py:1-10`) to cover these shared
    adoption facts. The loop must keep the `repo == adoption.repo` filter
    (`execute.py:238-241`). The controller cannot read `state.execute`, so the predicate
    has to run on the current plan. After a re-plan it can issue a review that no task
    uses, because `_init` does not re-run. That costs one review and is harmless.
    Exclude marked tasks from the set so a marked-and-matching task does not trigger
    it. For a micro or cycle run on a PR, `adoption.prior` is never set (only
    `controller.py:284` sets it), so the set is always empty there. That is the waste
    `v741-g5` paid.

12. **note: "the same standing as an implementer's claim" is only true at the program
    level.** Neither claim gets a program re-run or a review (E5, E6 and E7 skip
    `already-satisfied`, `postconditions.py:652`, `:673`, `:718`). E3 accepts it as a
    dependency (`postconditions.py:616`), so a dependent task runs on top of it. The
    implementer, though, forks a worktree at the current head and is told to run the
    verify command (`roles.py:166`). The PLAN mark rests on reading code only. The chain
    still holds, because V2 needs a verdict on every criterion at the head
    (`postconditions.py:788-794`), VERIFY re-runs the cited commands, a VERIFY
    `implementation gap` re-opens the owning task, marked or not
    (`execute.py:908-955` → `_reopen`), and ITERATE judges against the original
    request. A wrong mark costs one VERIFY round and weakens no exit. Reword the plan's
    claim to say so.

13. **note: the line citations check out.** `controller.py:580` (`_phase_probes`),
    `:599` (adopted review), `execute.py:329`, `:1127`, `:1291`, `postconditions.py:175`,
    `:663`, and `roles/planner/SKILL.md:21` all say what the plan says. VERIFY reviews
    `base..head` in full on its first pass (`verify.py:179-201`), and `adoptedReview`
    never enters the ledger, so for a run with no adopted task Fix 3 loses no review of
    the PR's commits. Remediation `reviewFrom` for an adopted task is the repo base
    (`execute.py:250`), which does not depend on `adoptedReview`.

verdict: no-go

## Rev 2

Checked `v742-plan.md` rev 2 against the same tree (`1f23578`).

### Rev 1 findings

- **1 (re-plan marking): resolved.** `_fresh_task_state` applies the mark, and
  `alreadySatisfied` joins `_PLAN_IDENTITY_FIELDS`. A task kept in `planGap` whose
  re-plan marks it now differs from its snapshot. It has no commits, so it takes the
  reset branch (`execute.py:1062-1077`) and gets fresh `already-satisfied` state; the
  `_refork` there is skipped. A removed mark resets to `pending`. Leaving a null key
  out of `_plan_snapshot` keeps 7.4.1 snapshots equal, and
  `_mark_adopted_tasks`/`changed_fields` compare with `.get`
  (`execute.py:233`, `:1034`), so a missing key and null match. `_reopen` → `_refork`
  on a never-forked marked task is safe: `_retire_worktree` returns early on
  `None` (`execute.py:766`).
- **2 (external EXECUTE review): resolved.** `external` and `default` are the only
  implementation values (`contract.py:275-284`), so "EXECUTE is external or a task is
  adoptable" covers every product that can claim `adopted`. The plan's test claim
  now matches the test: it runs EXECUTE external via `_EXTERNAL_ENV`,
  `tests/test_controller.py:28`, `:1200`.
- **3 (debug checkout): resolved.** `_ensure_code_checkouts` runs in
  `_issue_critic_step`, which a debug compaction reaches (`controller.py:796-798`,
  `:1109`), and in the `debug` envelope.
- **4 to 9: resolved** as the plan states. Finding 4 (all repos get a checkout) was
  taken, apart from the probes, which the plan declines with a stated reason.
  Finding 6's verify-copy exception is named. Finding 9 adds the `:376` row. Finding
  10's cwd change was also taken.

### New in rev 2

R2-1. **should-fix: replacing or reusing the code checkout ignores open and
   quarantined steps.** The planner, critic and reviser now have `cwd` = the code
   checkout, which is under `paths.checkouts_dir`. A retired step whose cwd is there is
   quarantined (`steps.py:389-395`), and at the end `_protected_worktree_paths`
   protects it (`controller.py:1633-1640`). Rev 2 reuses a checkout that "exists, is
   clean, HEAD matches", even when it is quarantined. Otherwise it "force"-removes
   it, which the codebase never does to a path with a possibly-live writer: see
   `_retire_worktree`, "clean AND writers known terminated … otherwise quarantine"
   (`execute.py:761-780`), and LF-60's "quarantined, never reused"
   (`controller.py:1729-1731`). Fix: when the recorded path is in an open or
   quarantined step, or `steps.writers_known_terminated` is False (`steps.py:423`,
   core), leave it and make a fresh `code-…-{uuid8}` checkout. Remove the old one only
   when it is clean and its writers are known terminated, never with force. The
   roles are read-only, so the practical risk is low, but this is the invariant the
   rest of the program keeps.
R2-2. **note: the SDK runner's state-home guard also covers the code checkout.**
   `_state_home_denial` denies any Bash command that names a path under `paths.root`
   (`sdk_runner.py:102-111`). `compose_prompt` tells a worker to prefix every command
   with `cd {cwd} &&` (`roles.py:228-231`). Under `--runner sdk`, a plan critic whose
   cwd is the checkout therefore has its Bash denied. VERIFY and the adopted review
   already work this way (their cwd is under `checkouts_dir`), so this problem
   predates rev 2, and rev 2 extends it to the critic. The `claude -p` runner used by
   the live check is unaffected. Record it as a follow-up.
R2-3. **note: the reason given for "a marked task is never adopted" is wrong, but the
   conclusion holds.** A 7.4.2 delivering run's prior plan can carry the key. It still
   never matters: `prior` is set only by the revise entry (`controller.py:284`); the
   reviser's schema cannot emit the mark; and adoption runs only in `_init`, against
   the reviser's plan. Reword the reason.
R2-4. **note: P8's integrated-commits refusal reads only the accepted EXECUTE
   product.** A task that owns commits but was last in `planGap` or `blocked` is not
   in `tasks_out` (`execute.py:1103-1136`), so P8 passes its mark. Reconcile then
   reopens it through the commits path (`execute.py:1044-1058`) and ignores the
   mark. The result is correct: the task is re-implemented, not skipped. It is worth
   one sentence in the plan.
R2-5. **note: a mid-attempt resume keeps the prompt it was issued with.** The
   envelope, and with it `_ensure_code_checkouts`, runs only when an attempt is
   minted (`controller.py:606-614`). A checkout deleted while a PLAN step is open is
   not recreated until the next attempt, so the open step's `WORKING DIRECTORY`
   names a missing directory. The same holds for today's `adopted-…` and VERIFY
   checkouts, so this is not a blocker.

verdict: go
