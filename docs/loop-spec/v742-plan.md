# 7.4.2 plan: a run on an open PR finds finished work quickly

For the Fable and Opus auditors of this change. Rev 2: folds in both rev 1 audits
(`v742-plan-audit-fable.md`, `v742-plan-audit-opus.md`); every item they raised is
answered below or under "Declined".

## Evidence

Live run `v741-g5` (7.4.1 at `1229a5e`, `docs/loop-spec/live-runs/7.0/v741-no-change-pr/`):
micro asked for `triple(x)` on live-7#29, whose head already has it. It ended
`no-change` after 20.5 minutes, about 15 of them waste: PLAN round 1 (7.5 min, the
critic raised "it already exists" twice), EXECUTE round 1 (3.3 min: an unused
adopted-range review, then an implementer that added a test and claimed the PR's
commit; plan gap), PLAN round 2 (4 min, the same Critical a third time), EXECUTE
round 2 (1.6 min, already satisfied).

Causes: (1) the planner lead read the operator's checkout, on `main`; its
`existingCode` cites are the base's line numbers although the prompt says to
`git show` at `startSha`; (2) PLAN cannot say a task is already done; (3) the
adopted-range review runs on every adopted run but is read only for `adopted` tasks.

## Fix 1: plan-writing roles read and run in a clean checkout of the code

**Where the checkout is made.** `controller._ensure_code_checkouts(store, paths)`
runs before every consumer of `repo_map` that plans: `build_envelope` for phases
`plan`, `debug` and `revise`, and `_issue_critic_step` (which a debug run reaches
without a `plan` envelope, Opus 3). For every repo (Opus 4), the code commit is the
accepted EXECUTE product's head for that repo when there is one (a re-plan after
EXECUTE integrated work, the same rule P8 uses, Fable 3), else
`postconditions.start_sha(state, name)`. The recorded checkout
`state.repos[name].codeCheckout = {"path", "sha"}` is reused only when the directory
exists, `repo_module.is_clean` holds, and its HEAD is that commit (Opus 5). Otherwise
the program removes the old worktree (force, then `git worktree prune`) and makes a
new one with `repo_module.clean_checkout` at
`paths.checkouts_dir / f"code-{name}-{sha[:12]}-{uuid8}"`. Everything under
`paths.root` is removed by `_finish_run`'s `remove_worktrees` at the end.

**What the roles get.** `roles.repo_map` adds `codePath` (the checkout's path, else
the repo's `path`) and `codeSha` (the checkout's commit, else `startSha`). The step
`cwd` becomes the checkout (Fable 2, Opus 10): the planner lead
(`defaults.run_lead_phase`, first repo's `codePath` when the phase is `plan`), the
plan critic (`_issue_critic_step`) and the reviser (`revise._reviser_request`, the
adopted repo's). So `compose_prompt`'s `WORKING DIRECTORY` line and `cd {cwd} &&`
prefix name the right tree. A worktree shares the object store, so `git show
<baseSha>:<path>` still works there. Result paths are absolute and unaffected. The
debugger keeps its cwd (it reproduces against the operator's repo; the program
re-runs the reproduction in its own base checkout); it gets `codePath` through
`repo_map`.

**Prompts.** `roles/planner`, `roles/plan-critic`, `roles/reviser` `SKILL.md` and
`roles.CONTRACTS["planner"]`, `["plan-critic"]` (Opus 7): read code under
`inputs.repos.<repo>.codePath`, a clean checkout at `codeSha`; cites are
repo-relative paths in it.

## Fix 2: PLAN can mark a task already satisfied

**Schema.** `schemas/plan.json` task: optional `alreadySatisfied`, null or
`{"evidence": str (minLength 1), "cites": [{"path", "lines"}] (minItems 1)}`. The
task keeps `verify`, `criteria` and the rest; coverage checks and the baseline are
unchanged. `debug.json#/$defs/plan` is pinned equal to `plan.json`
(`tests/test_schema.py`) and takes the field. `verify.json#/$defs/planTask` does
not: a remediation task is work VERIFY asks for, so the parity test compares it to
`plan.json`'s task minus `alreadySatisfied`, with a comment (Opus 6). The reviser's
own task shape (`revise.json`, `roles/reviser/schema.json`) is unchanged: the
reviser already drops a comment the code at the start commit satisfies, so it has
no marked tasks (Fable 4, Opus 6).

**P8.** The existing cite check becomes one helper used for `existingCode` cites and
for each task's `alreadySatisfied.cites` (resolved at the start commit or an
EXECUTE head, as today). P8 also refuses a marked task with `mustFlip` (a debug
repair task must fail at base, B1) and a marked task that owns integrated commits in
the accepted EXECUTE product.

**EXECUTE.**
- `_fresh_task_state(plan_task)` sets `status: already-satisfied`, `evidence:
  "already satisfied at PLAN: <evidence>"` for a marked task. That covers `_init`,
  `_reconcile_plan`'s `added` and `reset` paths (Fable 1, Opus 1).
- `alreadySatisfied` joins `_PLAN_IDENTITY_FIELDS`, so adding or removing a mark is a
  plan change: a task kept in `planGap` whose re-plan marks it is reset to
  `already-satisfied`; a mark removed resets it to `pending`. `_plan_snapshot`
  leaves the key out when it is null, so a 7.4.1 run's snapshots still compare equal
  after upgrade. In the `reset` branch, a marked task is not re-forked (`_refork`
  would set `pending`).
- The mark is read only when fresh state is built, so a VERIFY `implementation gap`
  that re-opens a marked task (`_reopen`) still re-implements it (Fable 1).
- A marked task never matches a prior plan task (the prior lacks the key), so it is
  never `adopted`.
- When every task is marked, EXECUTE issues no step and exits `no change`.

What proves a marked task: only the cited code (P8 checks the ranges exist, the
critic checks what they do). E5, E6 and E7 skip `already-satisfied`, as for an
implementer's "already satisfied:" claim. A wrong mark weakens no exit: V2 needs a
verdict for every criterion at the head, VERIFY re-runs the evidence, an
`implementation gap` re-opens the owning task, and ITERATE judges against the
request. It costs one VERIFY round (Opus 12, Fable 9).

**Prompts.** Planner `SKILL.md` and `CONTRACTS["planner"]`: when the code at
`codePath` already meets every criterion a task covers, keep the task and set
`alreadySatisfied` with cites there; never mark a `mustFlip` task. Plan-critic
`SKILL.md` and `CONTRACTS["plan-critic"]` (Opus 8, option a): a marked task whose
cited code does not meet its criteria is Critical; an unmarked task whose work the
code at `codePath` already does in full is Critical with the fix "mark T-n
alreadySatisfied citing ...". That costs one critic re-pass and saves an
implementer, a review and a plan gap; rule 6 ("a later check covers it") does not
apply, since no later check stops the wasted EXECUTE round.

## Fix 3: the adopted-range review runs only when something reads it

- `postconditions.adoptable_task_ids(state, plan_tasks) -> set[str]` holds the
  matching loop of `execute._mark_adopted_tasks` (repo filter kept) and
  `_PLAN_IDENTITY_FIELDS` moves there with it; `execute` imports both. The module
  docstring names the shared adoption facts it holds (Opus 11).
- `controller.py:599` issues `_issue_adopted_review` only when EXECUTE is external
  (an external product may claim `adopted` tasks, which E5 requires the review for,
  Opus 2) or `adoptable_task_ids` for the current plan is non-empty.
- `test_revise_entry_adopts_pr_and_reaches_execute` keeps asserting the review (it
  runs EXECUTE external). A new test: a default-EXECUTE adopted run with no prior
  issues no review.

## Docs in the same diff

`phase-interface-7.0.md`: P8's row (`alreadySatisfied` cites; not with `mustFlip`
or integrated commits), the PLAN product row (`alreadySatisfied`), EXECUTE's
runs-as row (a marked task is not dispatched), and the revise entry row
(`:376`, the adopted-range review runs only when EXECUTE is external or a task is
adoptable) (Opus 9). `external.POSTCONDITION_TEXT` P8. `architecture.md:51-53`: the
start commit now has `start_sha`, `repo_map.startSha` (`lastKnownHead`) and
`codeSha`; say so.

## Tests

- `test_controller`: an adopted run's PLAN step has `cwd` and `codePath` = a clean
  checkout at the PR head; a non-adopted run's is a checkout at base; a dirty or
  deleted checkout is replaced on the next envelope; an adopted default-EXECUTE run
  with no prior issues no adopted review.
- `test_postconditions`: P8 passes an `alreadySatisfied` cite inside the file at the
  start commit, fails one outside, fails a marked `mustFlip` task, and fails a marked
  task that owns integrated commits.
- `test_execute`: a marked task is `already-satisfied` with no step; all marked
  gives `no change` with no step; a re-plan that marks a task kept in `planGap`
  resets it to `already-satisfied`; a re-plan that removes a mark resets it to
  `pending`.
- `test_schema`: the parity test's `verify.json` exception.

## Live check

Micro on live-7#30 (`quadruple(x)`, already done), consumer clone `$S/v741/c2` on
`main`. Expected: the planner cites the PR head's line numbers and marks the task;
the critic passes first time; no adopted review and no implementer; EXECUTE `no
change`; well under `v741-g5`'s 20.5 minutes.

## Declined

- Running the named-file probes in the code checkout instead of their own
  (Fable 10, Opus 4): a saving of one checkout per PLAN attempt, and the probes read
  at the start commit while a re-plan's checkout may be at an EXECUTE head. Left as
  is.
