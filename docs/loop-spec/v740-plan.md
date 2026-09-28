# Plan: PR #109 follow-ups and per-role effort (7.4.0), rev 4

For the two critics of this change (Fable: architecture, Opus: correctness) and the
implementer after a `go`. Paths are under `skills/loop-spec/program/loop_spec/` unless
given in full. Line numbers are at `5cf7e4f` (7.3.0).

Scope, as the operator chose it on 2026-09-24: the four follow-ups in the 7.3.0 handoff
(F1 PLAN facts at the PR head, F2 revise resuming a finished run, F3 = D4 the core
reading plug-in state, F4 = D5 stubs copying the protocol), plus F5, per-role effort
for dispatched workers as Claude Code's subagent docs define it
(<https://code.claude.com/docs/en/sub-agents.md>, `effort` frontmatter).

Process: this plan, then a Fable and an Opus critique into
`v740-plan-audit-{fable,opus}.md` (untracked), revise until both say `go`, then the
main model implements, one commit per wave, then live runs, then 7.4.0 in all four
version files with a CHANGELOG entry.

Rev 2 folds in both rev-1 audits (Fable 1-16, Opus 1-21, both `revise`). Section
"Audit findings, where each landed" at the end maps every one. The two must-fix sets
conflicted on one point: Opus 3 asked for fallback reads so 7.3.0 runs resume on
7.4.0; Fable 2 showed any such fallback breaks the guard test. Rev 2 does neither: a
run started before 7.4.0 is refused on resume (F3, "Resume across the change").

## F1. PLAN facts at the PR head

### Finding (live run `ea-d`, PR live-7#26)

State: `~/.claude/plugins/data/loop-spec-inline/e82b41dd6e96ad10/add-a-one-line-docstring-to-square-on-ht/`.

- `state.adoption`: `baseSha 66d0f98` (merge-base with main), `headSha 4cef5b7` (PR head,
  which already defines `square`).
- The named-file probes were right: `attempts/attempt-8432805f4c14/context.json`
  `probes.named.d.files = [calc/__init__.py, tests/test_calc.py]`, computed at the PR
  head (`controller._phase_probes:478` picks `adoption.headSha` for the adopted repo).
- The planner's own reading was wrong. Its accepted `existingCode` entry: "Searched
  calc/__init__.py at the base commit (66d0f983): it defines only add and negate; no
  square function exists there". The task title became "Add square(x) ...".

Root cause, two parts:

1. `roles.repo_map` (`roles.py:196-199`) gives a PLAN-writing role only
   `{path, baseSha}` per repo. The PR head is not in the planner's inputs.
2. `roles/planner/SKILL.md` steps 3, 6, 7 say "base commit". For an adopted run the
   base is the merge-base, which predates the PR's own commits.

Not the cause: `named_files` matched; P8 (`postconditions.py:490`) already resolves
cites at the PR head for the adopted repo.

### Two commits, two jobs

- **Base (`baseSha`)**: where the baseline runs. A task's `verify` from a bare
  checkout, whether a `featureAdded` path exists yet (`postconditions.py:375`), the
  `checks` at base. These stay at the merge-base, so a PR's own breakage counts against
  the run, which must deliver a verified PR (both critics: keep).
- **Start (`startSha`)**: the code when this run begins: an adopted PR's head, else the
  base. Probes, `existingCode` searches and cites read here.

`lastKnownHead` already records the start commit. It is written only at
`controller.py:321` (fresh repo, `= baseSha`) and `:338` (adoption, the PR head); no
update, migration, re-adoption or hand-off writes it (Opus 15). Its readers are
`execute.py:324` and E8 (`postconditions.py:723-725`), which already rely on "head at
run start". It is right per repo in a workspace, and for debug and direct (never
adopted).

### Change

- `roles.repo_map`: add `"startSha": info.get("lastKnownHead") or info.get("baseSha")`;
  the docstring says `startSha` depends on `lastKnownHead` never being advanced. Callers
  unchanged (`defaults.py:59`, `debug.py:36`, `revise.py:81`); the lead context's
  `repos` carries `lastKnownHead` (seen in the `ea-d` context).
- Plan critic (Opus 13): `_issue_critic_step` (`controller.py:966-968`) adds
  `"repos": repo_map(store.state["repos"])` to its inputs, so the critic can check an
  `existingCode` `new` claim at the PR head. `roles/plan-critic/SKILL.md`: one sentence,
  read code at `inputs.repos.<repo>.startSha`.
- `roles/planner/SKILL.md`:
  - step 1: "The probes read each repo at `inputs.repos.<repo>.startSha`: an adopted
    PR's head, otherwise the base. Read code there too (`git show <startSha>:<path>`);
    the working tree may be on another commit."
  - step 3: `verify` and `featureAdded` stay "at the base commit (`baseSha`)"; test a
    `featureAdded` path with `git cat-file -e <baseSha>:<path>` (Opus 12).
  - step 6: repo checks were read "at `startSha`" (they are: `_phase_probes:477-481`).
  - step 7: cites are "at `startSha`, or at the head for code an earlier task of this
    run added"; a `new` entry's reason names the commit it searched.
- `roles/reviser/SKILL.md`: one sentence, the PR's current code is at
  `inputs.repos.<repo>.startSha`.
- P8's failure message (`postconditions.py:490`, "does not exist at the plan's
  commit") becomes "at the repo's start commit". The P8 row text already says "base, or
  the adopted PR head" (`external.py:52`, `phase-interface-7.0.md:142`): unchanged.
- `phase-interface-7.0.md:29`: the PLAN probes are read "at each repo's start commit
  (an adopted PR's head, else the base)".
- Not changed: `_phase_probes` and P8 keep reading `adoption.headSha`. That is two
  sources for one fact; `architecture.md`'s follow-up list names it (Fable 9).

### Tests

- `test_roles`: `repo_map` gives `startSha == lastKnownHead` for an adopted entry and
  `== baseSha` for a fresh one.
- The critic's inputs carry `repos` (extend the existing critic-issue test).
- The planner text is prose; live run 1 is its proof.

## F2. Revise resumes a finished run

### Finding

`controller._run_revise_entry:236-243`: `_find_run_by_adoption_number` returns any
`revise` run adopting that PR number, finished or not; `paths.state_json.exists()` is
true, and `continue_run` returns the old terminal result. New review comments are never
read. Callers: `_run_revise_entry` only, also reached from `_start_handoff`
(`controller.py:829`); `status` lists directories and `_routed_run` follows
`routedTo.slug`, so neither is affected (Opus 19).

### Decision: a new run per round

A run has one terminal `result.json`, written once (`result.py:138,173`) and read as
final by `_find_delivering_run_products`, `status` and the ledger. Reopening would clear
`state.result`, rewrite `result.json` and `last-result.json`, and re-create worktrees
`_finish_run` removed (`controller.py:1584-1592`). Both critics agree.

- "Finished" means `state.result is not None`, nothing else: a `paused` result writes
  `result.json` but leaves `state.result` unset and stays resumable (`result.py:168`;
  Opus 9).
- `_find_run_by_adoption_number` returns only an unfinished revise run of that PR. An
  in-flight one is still resumed, as today.
- `_next_revise_slug(home, rid, number)`: `revise-<n>`, then `revise-<n>-2`, `-3`, ...,
  the first with no `state.json`.
- `--slug` keeps its meaning: resume exactly that run, finished or not.

### Which prior products the reviser gets

`_find_delivering_run_products` takes the first `result.json` hit in slug order, so with
a finished `revise-26` and an original run both naming the PR, the winner depends on
slug spelling. A second round needs the latest finished run's products.

- Among runs whose `result.json` names the PR and that have SPEC and PLAN products,
  take the latest by `finishedAt`, reading `state.result.writtenAt` when
  `result.json` has none, and `""` when neither exists (the existing tests write a
  `result.json` with only `prs`; Opus 11).
- The adoption-only fallback (`controller.py:216-218`) uses the same latest-first rule,
  so `revise-7-2` beats `revise-7`.
- `test_prefers_the_delivering_result_over_a_prior_revise_run` still holds. New: two
  finished runs name the PR; the later wins regardless of slug order.

### Old comments in round two

`revise.gaps_from_pr` returns every comment on the PR, including those round one
handled. Filtering in code would hide a comment round one missed, so the reviser gets
the facts and decides:

- Each gap carries `createdAt`: `comments[].createdAt`, `reviews[].submittedAt`, inline
  `created_at` (gh field names checked on live PRs, Opus 18).
- The prior record carries `commentsCutoff`: the prior run's `state.run.createdAt`
  (core-owned, `controller.py:137,250`) when that run was a revise run, else `null` (an
  original cycle or micro never read comments), rewritten in gh's `...Z` form (Opus 10:
  `now_iso` writes `+00:00`). A revise run fetches its comments on its first step, just
  after it is created, so the cutoff errs early: a comment posted in between reads as
  new, which is the safe direction. (Rev 2 used a `gapsFetchedAt` in revise's bucket;
  the core building `prior` would then read a plug-in bucket, Fable 17.)
- Reviser text, step 1: "A comment with `createdAt` before `prior.commentsCutoff` was
  handed to the revise run that produced `prior`; fold it in again only when the code at
  `startSha` still does not address it. An edited comment keeps its original
  `createdAt`."

### Tests

- `_find_run_by_adoption_number` skips a run with `state.result` set and returns one
  with only a paused `result.json`.
- `_run_revise_entry` with a finished `revise-7` creates `revise-7-2` (the revise-entry
  fixture, gh stubbed as `test_revise_entry_adopts_pr_and_reaches_execute` does).
- Latest-`finishedAt` test above; missing `finishedAt` does not raise.
- `gaps_from_pr` carries `createdAt`.

## F3. D4: the core reads plug-in state

### Inventory (grep at `5cf7e4f`)

Only `controller.py` and `postconditions.py` reach in. (`render.py:74` reads
`state.critic`, which is core-owned.)

| Site | Reads, writes or calls | Owner today |
|---|---|---|
| `postconditions.review_evidence:162`; callers E6 `:663`, `_no_change_proof:690`, `controller._close_close_outs:1438`, `result.py:153` | `state.execute.tasks[id].{status, reviewSteps}` | execute.py |
| `Boundary._e3` / `_e3_dispatch_ordering:572-605` | `state.execute.tasks[id].{implementSteps, reviewSteps}` | execute.py |
| `Boundary._e10:746` | `state.execute.tasks[id].retries` | execute.py |
| `Boundary._e11:758` | `state.execute.tasks[id].probes.securitySignals` | execute.py |
| `Boundary._p8:480` | `state.execute.repos[repo].head` | execute.py |
| `Boundary._observed_head:1002` (D1/D2) | `state.execute.repos[repo].worktree` | execute.py |
| `Boundary._b1/_b2:1143,1152` | `state.debug.{baseRun, originalRun}` | `debug.record_base_runs`, called by the controller |
| `controller._accept_debug_product:751,759` | calls `debug_module.record_base_runs`, `compact_products` | debug.py |
| `controller._accept_revise_product:775` | writes `state.revise.acceptedAttempt`; read by nothing (dead) | core |
| `controller._run_revise_entry:254` | calls `revise_module.gaps_from_pr`; writes `state.revise.{gaps, product, prior}` | core writes a plug-in's bucket |
| `controller._record_accepted_product:1474` | `state.verify.{reused, reviewerSteps}` | verify.py |
| `controller.py:147` (write), `:814`, `postconditions.py:1162` | `state.route.facts` (core-owned facts inside the `route` bucket; `route.py:5-6` documents the split) | core, under a plug-in's key |

Plug-in to plug-in reads:

| Reader | Reads | Owner |
|---|---|---|
| `execute._mark_adopted_tasks:227` | `state.revise.prior` | revise (seeded by the core) |
| `iterate.py:56` | `state.verify.checkouts` | verify.py |
| `deliver.py:205` | `state.execute.repos[repo].worktree` | execute.py |

### The rule

The core owns its records (`run`, `phase`, `steps`, `products`, `repos`, `adoption`,
`questions`, `budget`, `ledger`, `critic`, `closeOuts`, `adoptedReview`,
`deliverAttempts`, `implementations`, `revisions`, and new `routeFacts`) and the shared
evidence records, commands the program ran (`executeRuns`, `verifyRuns`,
`criterionPasses`, `checkRuns`, and new `debugRuns`). A plug-in owns `state.<its
phase>`.

- The core never reads or writes `state.<plug-in phase>`. It reads a plug-in's product.
- The core never imports a plug-in module; it reaches one through
  `contract.default_adapter(phase)` (`contract.py:170`), by a hook name.
- A plug-in may read core state. It never touches another plug-in's bucket; it reads
  that phase's product.
- The shared evidence records are written by the core, or by a plug-in recording a run
  it made through `baseline.run_command` (`execute.py:1396`, `repo_checks.py:40`); the
  core reads them (Fable 5). `execute._rerun_lines:855` reading `verifyRuns` stays.
- A product field that names evidence is read only when that phase ran its default
  implementation (`state.implementations.phases[phase] == "default"`, the test
  `review_evidence` already applies at `postconditions.py:160`). An external product
  cannot vouch for its own evidence (Opus 2): for it these reads give `retries` 0,
  no review step and no reused range, as today.

### Resume across the change

A 7.3.0 run resumed on 7.4.0 would have accepted products without the new fields and
state in the old buckets: ITERATE would raise on a missing checkout, `result.json`
would report reviews as unattested, a revise run would lose `prior` (Opus 3). Fallback
reads would each break the guard test (Fable 2). Instead the run is refused on resume,
gated on a state-format integer, not the version string (Opus 22: `VERSION` stays 7.3.0
until wave 4, so a version gate would refuse every new run from wave 2 on):

- `state.STATE_FORMAT = 2` in `state.py`; `StateStore.create` writes
  `"stateFormat": STATE_FORMAT`.
- `check_compatible` (`controller.py:266`) refuses when
  `state.get("stateFormat", 1) < STATE_FORMAT` and `state.result is None`, placed before
  the `baseline is None` early return (`:271-273`): a run paused in SPEC or ROUTE has no
  baseline but has old buckets. A finished run runs nothing more, so it is not refused:
  `continue_run` still returns its result or follows `routedTo` (`_routed_run`,
  `controller.py:845`), and re-running a finished request still prints its result
  (Opus 23).
- Repair text: "finish the run on the loop-spec version that started it, or start a new
  run with `--slug <new-slug>`" (the same request maps to the same slug).
- `_find_run_by_adoption_number` skips a revise run with an old `stateFormat`, so an
  unfinished 7.3.0 `revise-<n>` neither blocks `revise --pr <n>` nor makes every auto
  hand-off to that PR raise; `_next_revise_slug` moves past its directory.
- Unaffected, verified (Opus 23): `status` (`cli.py:146`), `_find_delivering_run_products`
  and `_find_run_by_adoption_number` open with `StateStore.open`, not `_open_existing`;
  `_clear_stale_last_result` reads JSON only. They read only core keys of old runs.

PR #109 is unreleased and no run is in flight; the CHANGELOG says so.

### Changes, by plug-in

**EXECUTE publishes what E3, E6, E10 and E11 read.** `schemas/execute.json` gains
optional fields; every task `_final_product` emits (`execute.py:1090-1134`, the `done`,
`adopted` and `already-satisfied` branches, close-outs included; Opus 5) carries:

- `steps: {"implement": [ids], "review": [ids]}`;
- `securitySignals: [...]`, the probe records execute stored at review time, built as
  `((task_state.get("probes") or {}).get("securitySignals")) or []`: `probes` is None
  at start and is reset to None at `execute.py:809,842,1289` (Opus 25).

and each issue (`issues.items`, `additionalProperties: false`, so the schema changes)
gains optional `retries: int`, set by `_retry_or_block` (`execute.py:136-141`) from
`task_state["retries"]`. A blocked task is never in `product.tasks` (the disposition
enum has no `blocked`), so a per-task `retries` would never be read and LF-40 would
return (Opus 1).

Readers:

- `review_evidence(store, task)` takes the product task (all four callers have it in
  scope: E6 `:663`, `:690` `task`, `controller.py:1438` `by_id[entry["id"]]`,
  `result.py:153`). `disposition == "adopted"` replaces `status == "adopted"`; the
  review step is `task["steps"]["review"][-1]`. The level still comes from
  `state.steps.submissions[step]` (core-owned), so a product cannot claim more than
  its step earned. An unknown step id reads as `unattested`.
- E3 ordering reads `steps` from the product task; an unknown step id fails E3 rather
  than passing (Fable 4).
- E10 reads `issue["retries"]` (default implementation only).
- E11 reads `securitySignals` from the product task (default implementation only).
  Not recomputed (Fable 4 asked for a recompute): E11 checks that the reviewer
  dispositioned the signals it was shown, and the shown set is the one execute stored
  at review time over the review's range, close-outs included. A recompute over
  `task.commits` at acceptance could differ from what the reviewer saw and fail a
  correct product.
- P8 reads `products.execute.product.heads[repo]` when an EXECUTE product exists. For
  an external EXECUTE this adds its head as a cite commit where today nothing was read;
  benign, noted (Opus 17).

**The feature worktree is a path, not a product field (Fable 3).** The repo-level
EXECUTE worktree is always `paths.worktrees_dir / "feature" / <repo>`
(`execute.py:317`, its only construction; task generations use
`worktrees_dir / f"{task_id}-r{generation}"`, `:797`, never this one; Opus 24).
`FeaturePaths.feature_worktree(repo) -> Path` in `paths.py` (core). `execute.py:322`,
`_observed_head` (`postconditions.py:1002`) and `deliver.py:205` call it, falling back
to the repo path when it is not a directory, as today. No schema field.

**VERIFY publishes the review step behind each range and its checkouts.**

- `reviewedRanges[]` gains optional `reviewStep` and `reusedRangeId`
  (`schemas/verify.json`, items `additionalProperties: false`). `verify.py` fills them
  from `reviewerSteps` and `reused`; the controller's ledger write reads them from the
  product, default implementation only (Opus 2: an external VERIFY naming any earlier
  step would otherwise get range reuse through `verify.py:180`).
- The product gains optional `checkouts: {repo: path}` (the path carries a suffix,
  `verify.py:120`, so it is not derivable). `iterate.py:56` reads
  `products.verify.product.checkouts`, default VERIFY only: it becomes the iterate
  judge's `cwd`, so an external VERIFY gets today's "no verify checkout" error, not a
  directory it chose (Opus 26).

**DEBUG: the program's re-run of the reproduction is core evidence (Fable 6).**

- `record_base_runs` and `_with_error_class` move from `debug.py` into `controller.py`
  as `_run_reproduction_runs`, beside `_run_execute_verifications:1157` and
  `_run_verify_reruns:1198`, writing `state.debugRuns = {baseRun, originalRun,
  claimedDigest}`.
- B1/B2 read `state.debugRuns`.
- `compact_products` stays in `debug.py`, renamed `compact`, and the core calls
  `contract.default_adapter("debug").compact(product)`. `default_adapter`, not
  `resolve_implementation`: compaction is the phase's meaning, the same when the phase
  is bound external (Fable 11).
- No migration: covered by the resume refusal. (Rev 1's reason, "inside one submit",
  was wrong: `record_base_runs` saves before B1 runs, `debug.py:91`; Opus 16.)

**REVISE owns its bucket; the core owns the adoption.**

- `_run_revise_entry` stops writing `state.revise`. It writes `adoption.prior` (F2's
  lookup, with `commentsCutoff`) on the adoption record it creates.
- `revise.step` fetches `gaps_from_pr` when `"gaps" not in` its bucket (not when the
  list is empty: a PR with no comments would refetch every step; Opus 8). A `gh` failure now raises after the run exists; the next
  `revise --pr` resumes it because it has no result. That is new behaviour, stated in
  the CHANGELOG.
- `revise.py` and `execute._mark_adopted_tasks` read `state.adoption.prior`. No
  fallback (Fable 2; the resume refusal covers 7.3.0 runs).
- `_accept_revise_product` drops the dead `acceptedAttempt` write and calls
  `contract.default_adapter("revise").compact(product)`, a hook returning
  `(spec, plan)`.

**ROUTE: the facts move to a core key (Fable 1, Opus 6).** `state.routeFacts =
{"prRefs": [...]}`, written where `controller.py:147` writes today, read by
`route.py:33`, `controller.py:814` and `_a2` (`postconditions.py:1162`). `route.py`
keeps `state.route.result`.

The controller's `from loop_spec import debug as debug_module` and `revise as
revise_module` imports go away.

### Guard test

`tests/test_architecture.py`, small, `ast` over `loop_spec/` only (tests read buckets
freely):

- (a) A core module imports no plug-in module (`execute`, `verify`, `iterate`,
  `debug`, `revise`, `route`, `deliver`, `sdk_runner`; `repo_checks` is a shared
  service).
- (b) No subscript, `.get`, `.setdefault`, `.pop` or subscript assignment whose
  receiver is the name `state` or an attribute chain ending in `.state`, with a string
  constant naming a plug-in phase: in core modules any plug-in phase, in a plug-in
  module any phase but its own. `store.state["products"].get("execute")` and
  `store.state["implementations"]["phases"].get("execute")` are legal because their
  receiver is not `state` itself. Dict-literal keys are not checked (Fable 12, Opus 6).

The core/plug-in lists live in the test, taken from `architecture.md`.

### Test fallout, updated not deleted (Opus 7)

`test_controller.py:2146` (patches `controller.debug_module`), `:1038`
(`state.debug.baseRun`), `:1192,1294` (`state.revise.gaps`/`.prior` after entry);
`test_debug.py:7,81-97` (`record_base_runs` import); `test_events.py:88,103` (three-argument
`marker_next`); `test_postconditions` E3, E10, E11
fixtures that seed `state.execute` (for example `:420-432`, the LF-40 test sets the
count on the issue).

### Docs

- `phase-interface-7.0.md`: EXECUTE product (`tasks[].steps`, `tasks[].securitySignals`,
  `issues[].retries`), VERIFY product (`reviewedRanges[].reviewStep`, `reusedRangeId`,
  `checkouts`), each marked "read only when the phase ran its default implementation";
  E3/E6/E10/E11/P8/D1/D2/B1/B2 rows re-worded where they name state;
  `external.POSTCONDITION_TEXT` mirrors any changed row.
- `architecture.md`: the deviation list is replaced by the rule, citing the guard test;
  the `_phase_probes`/P8 two-sources note is the one follow-up.

## F4. D5: the stubs copy the runner protocol

### Finding

Eleven entry stubs (`skills/{auto,cycle,debug,deliver,execute,iterate,micro,plan,revise,spec,verify}/SKILL.md`)
share a byte-identical tail from "Then read the last stdout line" to the end. The hub
`skills/loop-spec/SKILL.md` carries a twelfth copy under "The `LOOP_SPEC_NEXT`
protocol". `status` differs and stays. No test reads stub text past `description:`
(`test_entries.py:18`; Opus 21).

### Decision: one protocol file, values in the marker (Fable 7)

- New `skills/loop-spec/references/runner.md`, the protocol once. First lines name the
  reader (a lead running an entry stub).
- The launcher path, state home and project root are facts the program has. The
  `LOOP_SPEC_NEXT` marker carries them: `program` (the launcher,
  `Path(__file__).resolve().parents[1] / "loop-spec"`), `stateHome`, `projectRoot`.
  `runner.md` writes every command as `"<program>" submit --project-root
  "<projectRoot>" --state-home "<stateHome>" --slug <slug> ...`, citing the marker's
  fields. No stub binds placeholders; no lead-side substitution.
- `marker_next` widens deliberately (its comment says the signature is fixed; that
  comment changes): `marker_next(kind, path, slug, *, program, state_home,
  project_root)`. `_print_next` (`cli.py:176-185`) has no `args` today; thread the
  parsed `--project-root`/`--state-home` into it. `program` is
  `Path(__file__).resolve().parents[1] / "loop-spec"` (exists, Opus 27).
- `marker_wait` (`LOOP_SPEC_WAIT`) carries the same three fields: a resumed run whose
  first printed line is a wait has shown no `LOOP_SPEC_NEXT` yet (Opus 27).
- Each stub keeps its frontmatter, its start command (which uses `${CLAUDE_SKILL_DIR}`
  and `${CLAUDE_PLUGIN_DATA}`, substituted inline, the one place substitution works),
  the `{project-root}`/`{request}` sentence, then: "Then read
  `${CLAUDE_SKILL_DIR}/../loop-spec/references/runner.md` in full and follow it for
  every line the program prints." and the "launcher is missing" pointer (Opus 21).
- The hub's protocol section becomes one paragraph citing `references/runner.md`.
- F4 and F5 land in one wave: both change `marker_next` (Fable 16).

### Tests

- `test_entries.py`: every stub with a start command cites `references/runner.md` and
  contains no `LOOP_SPEC_WAIT` (the copy's marker).
- `test_events.py`: the marker carries `program` (an existing file), `stateHome`, `projectRoot`.

## F5. Per-role effort for dispatched workers

### What the host offers (probed 2026-09-24, CC 2.1.281)

- Subagent frontmatter `effort`: `low`, `medium`, `high`, `xhigh`, `max`; overrides the
  session's; omitted inherits; available levels depend on the model (docs).
- The Agent tool has no per-call effort; only the agent definition sets it.
- A plugin's `agents/<name>.md` registers as `<plugin>:<name>`. Probe: plugin
  `effprobe` with `agents/worker-low.md` (`effort: low`) was listed as
  `effprobe:worker-low` and dispatched with `model: "sonnet"`; its `.meta.json` was
  `{"agentType":"effprobe:worker-low",...,"model":"sonnet"}`.
- The host does not record a subagent's applied effort in its transcript
  (`perTurnEffort: null`, no `effort` key; main-session records carry `"effort"`). The
  program can prove which agent type ran, not the effort level.
- A plugin agent's body replaces the default system prompt; `tools` omitted inherits.
- Agent SDK 0.2.157: `ClaudeAgentOptions.effort` (`types.py`, class at line 1962,
  field at 2319; passed as `--effort`, `subprocess_cli.py:770`). Probed in the
  scratch venv; the example README pins that version (Opus 14).

### Design

Same seam as the model override (`roles.resolve_model`).

- `roles.EFFORT_LEVELS = ("low", "medium", "high", "xhigh", "max")`.
- `contract.load_config` validates `roles.<role>.effort` against `EFFORT_LEVELS` beside
  the `evidence.*.accept` checks (`contract.py:45-50`), so a bad value fails at the
  first command (Opus 14). `roles.resolve_effort(project_root, role)`: env
  `LOOP_SPEC_EFFORT_<ROLE>` (validated the same way, raising `LoopSpecError` naming the
  variable), then config, else `None`.
- `roles.dispatch_settings(project_root, role) -> {"model", "effort"}` replaces the
  `"model": resolve_model(project_root, "<role>")` entries in module request dicts:
  `debug.py:44`, `defaults.py:72`, `execute.py:449,510,578`, `iterate.py:88`,
  `revise.py:92`, `route.py:42`, `verify.py:271,313`.
- `steps.issue(..., effort=None)` stores `"effort"`. Its four direct callers pass it
  (Opus 4): the two module pass-throughs `controller.py:609,627` add
  `effort=request.get("effort")` next to `model=`; the plan-critic step
  (`controller.py:981`) adds `effort=None if is_external else resolve_effort(...)`; the
  adopted-range review (`controller.py:1681`) adds `resolve_effort(project_root,
  "code-reviewer")`.
- `schemas/step.json` gains `"effort": {"enum": ["low","medium","high","xhigh","max", null]}`.
- The plugin ships `agents/worker-{low,medium,high,xhigh,max}.md` at the plugin root:
  `name`, a description saying only the loop-spec program dispatches it, `effort:
  <level>`, no `model` (the Agent call's `model` wins; without one it inherits, as
  `general-purpose` does), no `tools`. The five bodies are identical: "You are a
  loop-spec worker. The user message is your complete task: follow it exactly, read
  every file it names in full, and write your result where it says."
- The marker gains `effort` for every step and, for `stepKind == "role"` only,
  `subagentType`: `general-purpose` when effort is null, else
  `loop-spec:worker-<effort>` (plugin name from `.claude-plugin/plugin.json`). A lead
  step gets no `subagentType` (Opus 14).
- `runner.md`: `subagent_type` = the marker's `subagentType`; a re-dispatch after an
  unattested submit uses the same `subagent_type` as well as the same name and text.
  The unattested re-dispatch line the CLI prints (`cli.py:244`) names the
  `subagent_type` for an effort step (Opus 27).
- Attestation, in `ClaudeCodeAttestor.attest` (not `check_transcript`): when the step
  has an effort, load `agent-<id>.meta.json` next to the matched transcript; a missing
  file, a missing `agentType`, or one not equal to the expected type is `unattested`
  with its own reason ("dispatched as <agentType or 'unknown'>; this step runs as
  <type> for effort <level>"). With no effort, nothing new is checked. The transcript
  fallback glob (`attest.py:48-50`) can match with no meta file, hence fail closed.
- What refusal means (Opus Q3): an unattested result stops the run only for
  `ATTESTATION_REQUIRED_ROLES` (`steps.py:73`: plan-critic, code-reviewer,
  iterate-judge, router), through the existing re-dispatch path, bounded by
  `retry_limit`, ending in the refusal question. For implementer and verifier a
  mismatch is recorded and the run goes on. README says so.
- SDK runner: `run_step_sdk(step, *, ..., model, effort=None, ...)` passes `effort` to
  `ClaudeAgentOptions`; `examples/supervisor/supervisor.py:198` passes
  `step.get("effort")`, and `run_lead_step` sets `effort=step.get("effort")`.
- Lead steps in a host session run in the lead's own session; a configured effort does
  not apply there, the session's `--effort` does. `model` already behaves this way
  (`defaults.py:72`); README says so.
- `general-purpose` stays the default (both critics, Q4): a single worker type would
  change the system prompt of every role step at once with no live evidence. The
  confound is recorded: an effort-set step runs under the worker body, not
  general-purpose's prompt, so comparing effort levels also varies the system prompt.
  Revisit after live run 3.

### Docs

README config table: `roles.<role>` object form gains `effort`; new row
`LOOP_SPEC_EFFORT_<ROLE>`; the lead-step and implementer/verifier limits.
`references/contract.md` step fields and config table. `architecture.md` Role row: a
role's dispatch settings are model and effort. `examples/supervisor/README.md` pins
SDK 0.2.157 for `effort`.

### Tests

- `load_config` rejects a bad `roles.<role>.effort`; `resolve_effort`: env beats config,
  a bad env value raises, unset is `None`.
- `marker_next`: `subagentType` is `general-purpose` with no effort,
  `loop-spec:worker-high` with `high`, absent on a lead step.
- `attest`: an effort step with a mismatched `agentType`, and one with no meta file, is
  unattested; a matched one attests.
- The five agent files exist, one per `EFFORT_LEVELS`, with matching `effort:` and
  identical bodies.
- The plan-critic and adopted-review steps carry the configured effort.

## Docs, version, live runs

- `phase-interface-7.0.md`: `:29` probes wording (F1); every F3 product and row change.
- `architecture.md`: the D4 and D5 deviations replaced by the rule and the runner file;
  F5 in the Role row; one follow-up (`_phase_probes`/P8 read `adoption.headSha`).
- Follow-ups recorded, not fixed (Opus 18, 20): `revise.py:39` REST call is unpaginated
  (30 inline comments max); an adopted run whose planner finds all work done can only
  end blocked, because E9 fails `no change` when the PR's own commits sit between base
  and head.
- `CHANGELOG.md` 7.4.0, including: pre-7.4.0 runs are refused on resume; a revise `gh`
  failure now happens after the run exists. Version in `.claude-plugin/plugin.json`,
  `.claude-plugin/marketplace.json`, README `Current version:`, every
  `skills/*/manifest.toml`.
- Live runs (operator in the loop, Sonnet lead, `launch.sh`), fixture PR live-7#28
  (`double(x)` added on branch `v74-double`; base `main` has no `double`):
  1. **F1**: micro "add a one-line docstring to double on <PR #28 url>"; pass = the
     planner's `existingCode` cites `double` at the PR head (`extend`, not `new`), and
     the task title does not say "Add double".
  2. **F2**: revise on #28 (after run 1 delivered), then one new review comment, then
     revise again; pass = a second run `revise-28-2` handles the new comment, and
     `revise-28`'s `result.json` is unchanged.
  3. **F4 + F5**: a cycle with `LOOP_SPEC_EFFORT_CODE_REVIEWER=low`; pass = the lead
     read `runner.md` and followed it (the run converges), and every code-reviewer
     subagent's `.meta.json` says `agentType: loop-spec:worker-low`, attested.
  4. **F3** has no new behaviour; runs 1-3 exercise the changed read paths.

## Order (commit per wave)

1. F1 (`fix:`), F2 (`fix:`).
2. F3 (`fix:`; split per plug-in only if it splits cleanly) with the guard test and the
   resume refusal.
3. F4 + F5 together (`feat:`): `marker_next`, `runner.md`, stubs, agents, effort.
4. Docs, `chore: 7.4.0`, live runs, live-run docs, push, PR #109 body.

## Audit findings, where each landed

| Finding | Where |
|---|---|
| Fable 1, Opus 6 | F3 ROUTE: `routeFacts`; guard matches writes |
| Fable 2, Opus 3 | F3 "Resume across the change": refuse pre-7.4.0 resumes, no fallbacks |
| Fable 3 | F3 feature worktree path, no product field |
| Fable 4 | E3 unknown step fails: taken. E11 recompute: declined, reason in F3 EXECUTE |
| Fable 5 | F3 rule, shared evidence records; no `baseline.py` wrappers |
| Fable 6 | F3 DEBUG: `_run_reproduction_runs` in controller |
| Fable 7 | F4: values in the marker |
| Fable 8, Opus Q4 | F5: `general-purpose` stays |
| Fable 9, Opus Q1 | F1: baseline at merge-base; follow-up named |
| Fable 10, Opus Q2 | F2: new run per round |
| Fable 11 | F3 DEBUG: `default_adapter`, reason stated |
| Fable 12 | F3 guard receiver rule |
| Fable 13, Opus Q3 | F5 attestation refusal and its limits |
| Fable 14 | F5 lead steps |
| Fable 15 | F5 design (unchanged) |
| Fable 16 | Order: F4 + F5 one wave |
| Opus 1 | F3 EXECUTE: `issues[].retries` |
| Opus 2 | F3 rule: evidence fields read for default implementations only |
| Opus 4 | F5: four `steps.issue` callers |
| Opus 5 | F3 EXECUTE: four `review_evidence` callers; every emitted task has `steps` |
| Opus 7 | F3 test fallout list |
| Opus 8 | F3 REVISE: fetch when key absent; new failure timing |
| Opus 9 | F2: finished = `state.result` set |
| Opus 10, Fable 17 | F2: cutoff = prior revise run's `run.createdAt`, gh format |
| Opus 11 | F2: missing `finishedAt`; fallback ordering |
| Opus 12 | F1: planner steps 3, 6; `phase-interface:29`; P8 message only |
| Opus 13 | F1: critic gets `repos` |
| Opus 14 | F5: role-only `subagentType`, redispatch type, fail closed, `load_config`, SDK param |
| Opus 15-21 | notes folded into F1, F2, F3, F4 and the follow-ups |
| Opus 22, 23 | F3 "Resume across the change": `stateFormat` gate, finished runs pass, revise lookup skips old runs |
| Opus 24, 25 | F3 worktree cite `:317`; `securitySignals` None guard |
| Opus 26 | F3 VERIFY: `checkouts` default-only |
| Opus 27 | F4: `_print_next` threading, `marker_wait` fields, redispatch line; test fallout |
| Fable 17 | F2 cutoff from `run.createdAt` |
