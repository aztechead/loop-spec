# v740 plan audit: correctness (Opus)

For the author of `v740-plan.md` rev 1 and the implementer after a `go`. This checks
each proposed change against the code at `5cf7e4f` and traces its callers and readers.
Line numbers are at that commit and are under `skills/loop-spec/program/loop_spec/`
unless the path is given in full.

## Must-fix

1. **must-fix. F3 E10 moves to a field that blocked tasks never publish.** The plan
   says "E10 reads `retries` from the product task named by each issue". But
   `execute._final_product` (execute.py:1090-1134) only emits tasks whose status is
   `done`, `already-satisfied` or `adopted`, and the schema's disposition enum has no
   `blocked`. An issue names a task that `_retry_or_block` (execute.py:136-141) set to
   `blocked`, and that task is not in `product.tasks`. The lookup therefore always
   finds nothing, `step_retries_exhausted` is always false, and LF-40 comes back: a
   correctly blocked product is rejected until the phase's own retries run out
   (postconditions.py:746-752; `test_e10_accepts_a_task_that_exhausted_its_own_retries`,
   tests/test_postconditions.py:420). Correction: publish the count on the issue.
   `_retry_or_block` appends `{"task", "text", "retries": task_state["retries"]}`,
   `schemas/execute.json` `issues.items` gains an optional integer `retries` (the
   items are `additionalProperties: false`), and E10 reads `issue.get("retries", 0)`.
   Update the LF-40 test to set the count on the issue.

2. **must-fix. F3 lets an external product vouch for its own evidence.** The plan
   says external products "keep today's vacuous outcome" because the fields are
   optional. That is true only while an external product leaves the fields out, and
   nothing stops it from filling them in:
   - An external EXECUTE issue or task that claims a large `retries` count skips
     E10's retry-limit rule. Today E10 has no `state.execute` to read for an external
     EXECUTE, so it cannot be skipped.
   - An external VERIFY `reviewedRanges[].reviewStep` becomes the ledger's `byStep`
     (controller.py:1481-1484). `verify.py:180` then trusts that range for reuse and
     as a delta base whenever `evidence_accepted` passes for that step id. Any earlier
     accepted code-reviewer step passes that check, even though it reviewed a
     different range.

   Correction: read the moved fields only when
   `state.implementations.phases.<phase> == "default"`. That is the same test
   `review_evidence` already applies at postconditions.py:160. An external product
   gets `retries` 0, `byStep` None and `reusedFrom` None, exactly as today. Say this
   in `phase-interface-7.0.md` next to the new product fields.

3. **must-fix. F3 breaks runs started on 7.3.0 and resumed on 7.4.0, not only
   `revise.prior`.** `check_compatible` (controller.py:266) gates only the
   normalization version, so a 7.3.0 run resumes on 7.4.0. When its EXECUTE or VERIFY
   product was accepted on 7.3.0, that product lacks the new fields, and:
   - ITERATE raises. `iterate.py:56-63` would read
     `products.verify.product.checkouts`, find nothing, fall back to
     `checkouts_dir/verify-missing` and raise `LoopSpecError("no verify checkout ...")`.
     This hits every 7.3.0 run paused anywhere between VERIFY acceptance and ITERATE.
   - `result.json` reports wrong review levels. `result.py:151-153` calls
     `review_evidence` on the accepted EXECUTE product. With no `steps`, every done
     task reads as `unattested`, although its step was host-attested.
   - DELIVER and D1/D2 fall back to the repo path (deliver.py:205,
     postconditions.py:1002). This probably works because worktrees share refs, but
     it is a different path from the one that was verified.

   Correction: give every moved read the same `ponytail:` fallback the plan already
   gives `revise.prior`. Read the product field, and when it is absent read the old
   bucket (`state.verify.checkouts`, `state.execute.tasks[id].{implementSteps,
   reviewSteps}`, `state.execute.repos[r].worktree`). The removal condition is "no
   7.3.0 run left". The guard test must allow exactly these fallback reads, by an
   allow-list of `(module, key)` pairs in the test. Otherwise it fails on them.

4. **must-fix. F5's list of `model` sites is wrong, so two role steps ignore
   effort.** The plan lists `controller.py:609,627` as `dispatch_settings` sites and
   leaves out two direct `steps.issue` calls:
   - `controller.py:981`, the plan-critic step (`model=None if is_external else resolve_model(...)`);
   - `controller.py:1681`, the adopted-range code-reviewer step.

   With `LOOP_SPEC_EFFORT_CODE_REVIEWER=low`, the adopted review is issued with no
   effort, is dispatched as `general-purpose`, and passes, because the agentType
   check only runs when a step has an effort. Live run 3's pass condition would then
   be false on any adopted run. Lines 609 and 627 are pass-throughs of a module's
   request. They need `effort=request.get("effort")` added next to `model=`, not a
   `dispatch_settings` call. Correction: extend `steps.issue(..., effort=None)` and
   call it with effort from all four sites (609, 627, 981, 1681). The 981 site keeps
   the `None if is_external` shape.

## Should-fix

5. **should-fix. F3: `review_evidence` has four callers, and the plan names two.**
   The plan names E6 (postconditions.py:663) and `result.py:153`. The other two are
   `_no_change_proof` (postconditions.py:690, with a close-out id) and
   `_close_close_outs` (controller.py:1438, with a close-out id during
   `_record_accepted_product`). Both need the product task: `task` is in scope at 690,
   and `by_id[entry["id"]]` is in scope at 1438. `_final_product` must therefore put
   `steps` on the `already-satisfied` branch (execute.py:1100-1106) as well, or a
   close-out's `reviewStep` closure becomes None and the LF-55 prompt-binding check at
   690-694 fails. State "every emitted task carries `steps`, `securitySignals`" in the
   plan.

6. **should-fix. F3: the inventory misses `state.route`, and the guard test will
   fail on the planned code.** The core writes `store.state["route"] = {"facts": ...}`
   (controller.py:147) and reads it at controller.py:814 and postconditions.py:1162.
   `route.py` owns `state.route.result` (route.py:5-6). The plan lists `route.facts`
   as core-owned but keeps it inside a bucket named after a plug-in phase, so guard
   (b) flags all three sites. Correction: move the facts to a core key
   (`state.routeFacts`), have `route.py:33` read it, and add a fallback to
   `state.route.facts` for an auto run paused at its router step on 7.3.0. Also make
   guard (b) match `setdefault`, `pop`, and subscript assignment, not only a read
   subscript or `.get`. controller.py:254 and :775 are assignments and a
   `setdefault`.

7. **should-fix. F3 test fallout is not listed.** These break by construction:
   `tests/test_controller.py:2146` patches `controller.debug_module`, which will no
   longer exist; `:1038` asserts `state.debug.baseRun`; `tests/test_debug.py:7,81-97`
   imports `record_base_runs` from `debug`; `test_postconditions` E3, E10 and E11
   fixtures seed `state.execute` (for example :425 and :432); and
   `test_controller.py:1192,1294` assert `state.revise.gaps` and `.prior` straight
   after entry. List them in the wave so the implementer updates them and does not
   delete them.

8. **should-fix. F3 revise: fetch gaps only when the key is absent.**
   `revise.step` today does `setdefault("revise", {"gaps": [], ...})` (revise.py:102).
   If the new code fetches when `not gaps`, a PR with no comments is fetched on every
   step. If it keeps the `setdefault`, a 7.4.0 run never fetches at all. Fetch when
   `"gaps" not in bucket`. A 7.3.0 run already has the key and is not refetched. Also
   say that a `gh` failure now happens after the run exists, so the next
   `revise --pr` resumes it (it has no result). That is fine, but it is new
   behaviour: today the failure raises before any state is written
   (controller.py:236-256).

9. **should-fix. F2: "finished" must mean `state.result is not None`, and nothing
   else.** `result.write` with `paused` writes `result.json` but leaves `state.result`
   unset (result.py:1-6 and :168), so the run can still be resumed. The plan's test,
   "`state.result is None` and no `result.json`", would call a paused revise run
   finished and start a second run beside it. No caller passes `paused` today (grep),
   so the defect is latent, but the plan should use the correct test.

10. **should-fix. F2: the round-two cutoff uses the wrong time.** "A comment dated
    before `prior.finishedAt` was handed to the run that produced `prior`" is false in
    two cases:
    - Round one read comments once, at its creation (controller.py:254-255). A comment
      posted while round one was running predates its `finishedAt`, but that run never
      saw it.
    - When `prior` is the original cycle or micro run, it never read comments at all.

    Correction: record `gapsFetchedAt` on the revise run when it fetches, and carry it
    into `prior` as the cutoff only when the prior run is a revise run. Otherwise the
    cutoff is null. gh returns `createdAt` as `...Z` and `now_iso` writes `+00:00`
    (for example state.json `writtenAt`), so write the cutoff in gh's format, or tell
    the reviser the two formats are the same instant.

11. **should-fix. F2: ordering by latest `finishedAt` needs a rule for a missing
    value, and the fallback needs the same ordering.** The existing tests write a
    `result.json` with only `prs` (tests/test_controller.py:1273, 2295, 2322). Sorting
    `None` against a string raises `TypeError`. Treat a missing value as `""`, or read
    `state.result.writtenAt`, which is the same instant (result.py:171). The
    adoption-only fallback (controller.py:216-218) still takes the first match in slug
    order. With `revise-7` and `revise-7-2` that is the older run. Apply the same
    latest-first rule there.

12. **should-fix. F1 leaves three texts that still say "base".**
    - Planner step 6 (roles/planner/SKILL.md:54) says the program read the repo-check
      tools "from the repo's manifests at the base commit". `_phase_probes`
      (controller.py:477-481) reads them at `adoption.headSha`. Say `startSha`.
    - `phase-interface-7.0.md:29` says the PLAN probes are "read at the base commit".
      Same fix.
    - The P8 text the plan wants to change already reads "at the repo's plan commit
      (base, or the adopted PR head)" (external.py:52, phase-interface-7.0.md:142).
      There is no `contract.CONTRACTS`; the dict is `roles.CONTRACTS`, and it does
      not mention P8. The only "plan's commit" wording is P8's failure message at
      postconditions.py:490. Retarget the edit to that message.

    Also, step 3 should tell the planner how to test `featureAdded` at base
    (`git cat-file -e <baseSha>:<path>`), since its working tree may be at the PR
    head.

13. **should-fix. F1: the plan-critic cannot check what F1 fixes.** The critic's
    Critical list includes "an `existingCode` entry marked `new` for behavior cited or
    named code already implements" (roles.py:141-142). But `_issue_critic_step`
    (controller.py:966-968) passes no repo map, so the critic reads whatever the
    operator's checkout has at `cwd`. Add `"repos": repo_map(store.state["repos"])`
    to the critic's inputs and one sentence to `roles/plan-critic/SKILL.md` telling it
    to read code at `startSha`. This input also feeds `inputs_digest`, which is fine
    because it is computed per issue.

14. **should-fix. F5: marker, redispatch, meta and validation.**
    - Emit `subagentType` only for `stepKind == "role"`. A lead step (SPEC, PLAN,
      DIRECT, debugger, reviser) is never dispatched, and a
      `loop-spec:worker-high` on it misreads as an instruction.
    - After an unattested submit, `runner.md` must say to redispatch with the same
      `subagent_type`. Today the text says to redispatch "under that exact name with
      the same dispatch text" only.
    - `find_transcripts` can match through the fallback glob with no meta file
      (attest.py:48-50). The agentType check must load
      `agent-<id>.meta.json` next to the matched transcript and fail closed with its
      own reason when the file or its `agentType` is missing. Put the check in
      `ClaudeCodeAttestor.attest`, not in `check_transcript`.
    - Validate `roles.<role>.effort` in `contract.load_config`, next to the
      `evidence.*.accept` checks (contract.py:45-50), so a bad value fails at the
      first command and not when a step is half built.
    - `run_step_sdk` takes `model` as a parameter from its caller
      (sdk_runner.py:192, supervisor.py:198). Add `effort` the same way, with the
      supervisor passing `step.get("effort")`. The claim that
      `ClaudeAgentOptions.effort` exists is not checkable here (`claude_agent_sdk` is
      not installed in this environment). Pin the SDK version it was probed on in the
      example's README.

## Notes

15. **note. F1: `lastKnownHead` is written in exactly two places.** Those are
    controller.py:321 (fresh repo, equal to `baseSha`) and :338 (adoption, the PR
    head). No `update`, migration, re-adoption or hand-off writes it:
    `_hand_off` goes back through `_resolve_repos`, and `_run_revise_entry` goes
    through `_adopt`. It is right for workspaces (per repo), debug (fresh, so the
    base), and direct (never adopts; `_hand_off` skips `_resolve_repos` for direct).
    It has two readers, not one: execute.py:324 and E8 at postconditions.py:723-725.
    E8 already relies on the same "head at run start" meaning. Say in `repo_map`'s
    docstring that `startSha` depends on `lastKnownHead` never being advanced.

16. **note. F3 debug window.** `record_base_runs` calls `store.save()` itself
    (debug.py:91) before B1 and B2 run, so the window is persisted and is not "inside
    one submit call". The conclusion still holds: a resumed acceptance re-runs the
    reproduction before B1 reads it, so no migration is needed. Fix the plan's
    reasoning.

17. **note. F3 P8 changes for an external EXECUTE.** Reading
    `products.execute.product.heads` adds the external product's head as a cite
    commit. Today an external EXECUTE has no `state.execute` to read. The change is
    benign, but it is not identical to today's behaviour; say so.

18. **note. gh fields, checked live.** `gh pr view --json comments,reviews` returns
    `comments[].createdAt` and `reviews[].submittedAt`, and reviews carry no `url`
    (checked on aztechead/loop-spec). The REST `pulls/{n}/comments` items carry
    `created_at`. An edited comment keeps its `createdAt`, so an old comment that was
    edited after round one will look already handled. The REST call at revise.py:39
    is unpaginated, which caps inline comments at 30. That was already true before
    this plan; add `--paginate` as a follow-up.

19. **note. F2 slug readers are covered.** `_find_run_by_adoption_number` is reached only via
    `_run_revise_entry` (also from `_start_handoff`, controller.py:829); `status` just lists
    directories (cli.py:135-158); `_routed_run` follows `routedTo.slug`. Test :1690 still holds.

20. **note. Adopted "no change" runs, related to Q1.** On an adopted run, E9 fails a
    `no change` exit (postconditions.py:727-731), because the adopted PR's own commits
    lie between `baseSha` and the head. After F1, a planner that sees the work already
    done at the PR head is more likely to plan only `already-satisfied` tasks, and
    that run can then only end blocked. This problem already existed; record it as a
    follow-up.

21. **note. F4 is sound.** The eleven tails are byte-identical; no test reads stub text past
    `description:` (test_entries.py:18); test_events.py:105 checks named keys only. Keep the
    "launcher is missing" pointer in each stub. `status` rightly stays as is.

## Answers to the open questions

- **Q1: keep the baseline at the merge-base.** The baseline capture, P3's
  `featureAdded` (a path absent at base), the VERIFY full range from `baseSha`, the
  adopted-range review, and `_mark_adopted_tasks` (execute.py:241-245) all assume
  `baseSha` is the merge-base. Moving the baseline changes all of them for a minor
  release. The cost is note 20 and the PR-breakage case, which the plan already
  accepts.
- **Q2: a new run per round.** Reopening a run would clear `state.result`, rewrite
  `result.json` and `last-result.json`, and re-create worktrees that `_finish_run`
  already removed (controller.py:1584-1592). Every reader treats those as final.
- **Q3: refuse on a mismatch, but know what refusal means.** An unattested result
  only stops a run for `ATTESTATION_REQUIRED_ROLES` (steps.py:73: plan-critic,
  code-reviewer, iterate-judge, router): the step is redispatched, then refused or
  waived by `evidence.*.accept`. That is bounded by `retry_limit` and ends in the
  refusal question, so it does not deadlock. For implementer and verifier a mismatch
  is recorded and does not stop the run. With warning-only, effort would be
  unverifiable for every role, so keep refusal and state the implementer and verifier
  limit in the README.
- **Q4: keep `general-purpose` as the default for 7.4.0.** A `loop-spec:worker`
  default changes the system prompt of every role step in every run at once, with no
  live evidence yet. Record the confound instead: an effort-set step runs under the
  worker body and not under general-purpose's prompt, so a comparison between effort
  levels also varies the system prompt. Revisit after run 3.

## Round 2

This round checks rev 2's new claims against the code at `5cf7e4f`. Findings 1-21 above
are resolved as rev 2's map says, except where noted below.

22. **must-fix. The resume refusal refuses every run until the version bump.** Rev 2
    compares `state.loopSpecVersion` against 7.4.0. That field is `VERSION`
    (state.py:36), which comes from `skills/loop-spec/manifest.toml`, and the manifest
    stays at 7.3.0 until wave 4 (`chore: 7.4.0`). `check_compatible` runs at the top
    of every `continue_run` (controller.py:388), including the call right after
    `StateStore.create` (controller.py:156), and in `submit`/`answer` (cli.py:172).
    From the wave-2 commit to the wave-4 commit, every new run is therefore refused on
    its first call, and almost every controller test fails.

    Correction: take the gate off the version string. Add
    `state.STATE_FORMAT = 2` in state.py, write `"stateFormat": STATE_FORMAT` in
    `StateStore.create`, and refuse when `state.get("stateFormat", 1) <
    STATE_FORMAT`. This also avoids parsing a version like `7.4.0-dev` as integers.
    Put the check before the `baseline is None: return` early exit (controller.py:271-273),
    because a run paused in SPEC or ROUTE has no baseline but does have old buckets
    (`state.route.facts`, `state.revise`).

23. **should-fix. "Breaks nothing that reads old runs" is true for scans, not for
    re-entry.**
    - `status` (cli.py:146 uses `StateStore.open`), `_find_delivering_run_products`
      and `_find_run_by_adoption_number` (both use `StateStore.open`, not
      `_open_existing`) and `_clear_stale_last_result` (reads JSON only) are
      unaffected. Verified.
    - Everything that goes through `_open_existing` or `continue_run` is refused, and
      that includes finished runs:
      - `_routed_run` (controller.py:845) and the auto run's own `continue_run` refuse
        before they reach the `state.result` branch (controller.py:392-396);
      - re-running a finished request, which today prints its result marker, now errors;
      - its repair text, "start a new run", cannot be followed without `--slug`,
        because the same request text maps to the same slug.

    Correction: skip the check when `state.result is not None`. A finished run runs
    nothing more, so it has no hazard, and `continue_run` then returns its result or
    follows `routedTo` exactly as today. Name `--slug <new-slug>` in the repair.
    Also, have `_find_run_by_adoption_number` skip a revise run with an old
    `stateFormat`. Otherwise one unfinished 7.3.0 `revise-<n>` blocks both
    `revise --pr <n>` and every auto hand-off to that PR. The hand-off raises inside
    `_start_handoff` with `phase.handoff` still set, so each resume of the auto run
    raises again. With the skip, `_next_revise_slug` moves past the old directory.

24. **note. Verified: the feature worktree path.** execute.py:317 (not :322) builds
    `paths.worktrees_dir / "feature" / name`, and this is the only construction of that
    path. Task generations use `worktrees_dir / f"{task_id}-r{generation}"`
    (execute.py:797), which never collides with it. The existing fallback in
    `_observed_head` and deliver.py:205 fires when there is no `state.execute`, which
    is an external EXECUTE, and no feature worktree exists then either. So "not a
    directory, then the repo path" behaves the same.

25. **note. Verified: every emitted task and close-out can carry `steps` and
    `securitySignals`.** `_final_product` emits only the `done`, `already-satisfied`
    and `adopted` branches (execute.py:1093-1123). Close-outs are built by
    `_fresh_task_state` (execute.py:109), which always has
    `implementSteps`/`reviewSteps` lists (execute.py:270). One trap: `probes` starts
    as None and is reset to None at execute.py:809, 842 and 1289. Build the field as
    `((task_state.get("probes") or {}).get("securitySignals")) or []`, not
    `task_state["probes"]["securitySignals"]`.

26. **should-fix. `checkouts` is an evidence-like field too.** ITERATE uses
    `products.verify.product.checkouts[repo]` as the iterate-judge's `cwd`
    (iterate.py:56-58), so the judge reviews whatever tree the path names. Read it only
    when VERIFY ran its default implementation. An external VERIFY then gets today's
    "no verify checkout" error, not a directory it chose.

27. **note. `marker_next` plumbing.** `_print_next(paths, next_)` (cli.py:176-185)
    has no `args`. The values come from `paths.project_root` and
    `paths.root.parent.parent` (the state home), or `args` must be threaded in.
    `tests/test_events.py:88,103` call `marker_next` with three arguments; add these
    to the test fallout.
    `LOOP_SPEC_WAIT` (`marker_wait`) should carry the same three fields: a lead
    resuming a run whose first printed line is a wait has seen no `LOOP_SPEC_NEXT` to
    take `program` from.
    The redispatch line (cli.py:244) should also name the `subagent_type` for an effort
    step. `Path(__file__).resolve().parents[1] / "loop-spec"` from `events.py` is
    `program/loop-spec`, which exists. Verified.

28. **note. Verified: the other rev-2 claims.** These match the code:
    - `review_evidence`'s four callers each have the product task in scope (:663, :690
      `task`, controller.py:1438 `by_id`, result.py:153).
    - The four `steps.issue` callers are 609, 627, 981 and 1681.
    - `issues[].retries` is set in `_retry_or_block` (execute.py:136-141).
    - `routeFacts` has three readers plus `route.py:33`.
    - `gaps_from_pr` fetches when the key is absent.
    - The finished test is `state.result`.
    - Latest-first applies to the adoption fallback.
    - The meta check fails closed.

    I did not re-probe `ClaudeAgentOptions.effort`; the plan cites the scratch venv
    for that.

## Round 3

This round checks rev 4 against findings 22-28 and looks at what rev 4 changed.

29. **note. Findings 22-28 are resolved as specified.** Rev 4 now has:
    - the `STATE_FORMAT` gate, written by `StateStore.create`, with a missing field read
      as format 1;
    - the check placed before the `baseline is None` return at controller.py:271-273;
    - finished runs exempt, so `_routed_run` and re-running a finished request behave
      as today;
    - the `--slug <new-slug>` repair, which works for `revise --pr <n> --slug <new>`
      because an explicit slug with no `state.json` creates a run
      (controller.py:237-247);
    - the revise lookup skipping old formats;
    - the `securitySignals` None guard;
    - `checkouts` read for a default VERIFY only;
    - `_print_next` threading, the `marker_wait` fields, the redispatch line, and the
      `test_events` fallout.

    No test builds `state.json` by hand in a way the gate would refuse: only
    `test_state.py:26` writes one, and it tests tampering. `StateStore.create` fixtures
    pick up the new field automatically.

30. **note. Checked: the rev-4 F2 cutoff, the prior run's `state.run.createdAt`.**
    The field is core-owned. It is written at controller.py:137 and :250 with
    `now_iso()`, which is `isoformat(timespec="seconds")` with `+00:00`
    (ids.py:34-35), so it converts cleanly to gh's `...Z` at the same precision. Under
    rev 4 the revise run fetches its comments on its first step. That step runs in the
    same `continue_run` call that follows creation, or later if `gh` failed. Either
    way the fetch happens at or after `createdAt`, so a comment posted in between
    reads as new, and the reviser handles it again only if the code still does not
    address it. That is the safe direction, and it also fixes my finding 10 without
    reading a plug-in bucket. `_find_delivering_run_products` already opens each
    candidate's state (controller.py:198), so reading `run.createdAt` and
    `run.cycleType == "revise"` there costs nothing.

31. **note. Rev 4 adds no new correctness defect that I found.** Two points for the
    implementer:
    - The gate's repair says `--slug`, but `auto` and the request entries build the
      slug from the request text (controller.py:126). An operator who passes `--slug`
      with the same request text gets a fresh run as intended.
    - The `test_entries`/`test_events` marker tests should assert the three new fields
      on both `LOOP_SPEC_NEXT` and `LOOP_SPEC_WAIT`.

VERDICT: go
