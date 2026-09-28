# Audit of v740-plan.md rev 1 (architecture)

For the plan's author. Read against `5cf7e4f`; line numbers are at that commit. The
focus is design: is each root cause the real one, is each change at the right seam and
the smallest that fixes it, and does F3's ownership rule survive its own guard test.

Verdict: revise

The evidence checks out. F1's two-part cause is what the code shows (`roles.py:196-199`
gives `{path, baseSha}` only; `planner/SKILL.md:29,54,64` say "base commit";
`lastKnownHead` is written at `controller.py:321,338` and read only at
`execute.py:324`). F2's cause is `controller.py:236-243` as stated. F3's inventory is
complete: a grep of every core module for a plug-in phase name as a string key finds
exactly the sites in the plan's two tables plus `state["route"]`, which is finding 1.
F4's "identical tail" claim holds (`skills/cycle/SKILL.md:14-71`). F5's reading of the
subagent docs is correct on every point I could check (effort values and inheritance,
no per-call effort, `agents/` auto-discovered and scoped as `<plugin>:<name>`, body
replaces the system prompt, `tools` omitted inherits, levels depend on the model).

The must-fixes are two places where the plan's own guard test fails against the plan's
own changes.

## Must-fix

1. **F3 guard versus `state["route"]["facts"]`.** The ownership rule lists `route.facts`
   as a core record, but it lives under the plug-in key `route`: written at
   `controller.py:147`, read at `controller.py:814` and `postconditions.py:1162`, and
   `route.py:5-6,33` documents the split. Guard rule (b) flags a subscript of `state`
   with the constant `"route"` in a core module, so `test_architecture.py` is red on
   day one, or it carries an allowlist, which is the prose rule the test exists to
   replace. Change: move the facts to a core key, `state["facts"] = {"prRefs": [...]}`
   (written where `:147` writes today), read by `route.py:33`, `controller.py:814` and
   `_a2` at `postconditions.py:1162`. `route.py` keeps `state["route"]["result"]` as
   its bucket. Re-word `phase-interface-7.0.md`'s A rows if they name `route.facts`
   (grep found no hit; check `architecture.md` and the ea-runs audit rev 2 finding 3,
   which is superseded by this).

2. **F3 REVISE migration fallback trips the same guard.** The plan has
   `execute._mark_adopted_tasks` (`execute.py:227`) fall back to `state.revise.prior`
   for a 7.3.0 run resumed on 7.4.0. That is a plug-in reading another plug-in's bucket
   by a string constant, which rule (b) for plug-in modules forbids. Drop the fallback
   in both `execute.py` and `revise.py`. The cost is one degraded case: a revise run
   started on 7.3.0 and resumed on 7.4.0 has no `adoption.prior`, so no task is marked
   adopted and EXECUTE redoes the PR's work; the reviser still gets its gaps. Say so in
   the CHANGELOG. The program already refuses resumes across a state-shape change
   (`controller.check_compatible:266`); if a silent degrade is unacceptable, refuse
   there when `state.revise.prior` exists and `adoption.prior` does not, in the core,
   which may read `state["revise"]` under no rule the guard enforces only if it is
   removed with the fallback later. Prefer the degrade: no code, one changelog line.

## Should-fix

3. **F3 `worktrees` product field is unnecessary.** The EXECUTE worktree is
   `paths.worktrees_dir / "feature" / name` (`execute.py:322`), deterministic from
   `FeaturePaths`, and `paths.py` is core ("where state lives"). `Boundary` already
   holds `self.paths` (`postconditions.py:261`) and `deliver.run` takes `paths`
   (`deliver.py:165`). Change: `FeaturePaths.feature_worktree(repo) -> Path`;
   `execute.py:322`, `_observed_head` (`postconditions.py:1002`) and `deliver.py:205`
   call it, falling back to the repo path when `not is_dir()` as today. No schema
   change, and a plug-in's filesystem layout never becomes contract surface for an
   external EXECUTE implementer. `verify.checkouts` is different (the path carries a
   suffix, `verify.py:120`), so that product field stays.

4. **F3 E11 should recompute, not trust the product.** The signals are the program's
   own probe: `probes.diff_probes` (core) at `execute.py:1321`, stored in the task
   state the product would now copy. A security check that reads a plug-in's claim of
   what the program found is weaker than the check today, and the product field is
   more contract surface. Change: `_e11` calls the same probe on the product task's
   own commit range (`task["commits"]`, which E4 already verifies against the ledger)
   and compares to the dispositions. One edit, no schema field. `steps` and `retries`
   stay as product fields: they name core records (`state.steps`) the check then
   consults, so a product cannot claim more than the core recorded. Have E3/E6 treat
   an unknown step id as a failure rather than a vacuous pass (Opus's line, noted
   here because it is what makes the product a safe carrier).

5. **F3 `record_execute_run`/`forget_execute_run` in `baseline.py`.** `baseline.py`
   writes no state today (grep: the only `store` mention is a docstring at `:605`).
   The core writer of `executeRuns` is `controller._run_execute_verifications:1157`.
   Two wrappers around a dict set and a pop satisfy the rule's fourth bullet, which
   the guard does not test, and give `baseline.py` a second reason to change. Drop
   them. State the bullet as: `executeRuns`, `verifyRuns` and `checkRuns` are shared
   evidence records; a plug-in may record a run it made through `baseline.run_command`
   (`execute.py:1396`, `repo_checks.py:40`); the core reads them.

6. **F3 `record_reproduction_runs` belongs beside its siblings, not in `baseline.py`.**
   The program's own re-runs live in `controller.py` (`_run_execute_verifications:1157`,
   `_run_verify_reruns:1198`). Put `_run_reproduction_runs` there, writing
   `state["debugRuns"]`, with `_with_error_class` (`debug.py:65`) moving with it (or
   folded into `run_command` as LF-23's root cause; that changes what E/V see for exit
   127, so not this release). `baseline.py` stays a pure service.

7. **F4 placeholder binding is a workaround for facts the program has.** The three
   values the stub binds (`{program}`, `{state-home}`, `{project-root}`) are the
   launcher path (`Path(__file__).parents[1] / "loop-spec"`) and two CLI arguments the
   program parsed. Put them in the `LOOP_SPEC_NEXT` marker (`events.marker_next:95`,
   two callers `cli.py:185,246`; its comment fixes the signature, so widen it
   deliberately) and let `runner.md` cite the marker's fields. Each stub's tail then
   becomes: read `${CLAUDE_SKILL_DIR}/../loop-spec/references/runner.md` and follow it.
   No binding paragraph in eleven stubs, and no lead-side substitution to get wrong.
   If not taken, option A with the binding paragraph is still right over B: it
   removes the copies, and `${CLAUDE_SKILL_DIR}` in the stub is substituted inline,
   which is the one place substitution is known to work.

8. **F5 `general-purpose` stays the default (open question 4).** The docs say a
   plugin agent's body is the whole system prompt. Dispatching `loop-spec:worker` for
   every role step replaces the built-in prompt every live run to date was measured
   under, in a release whose other work is D4/D5 cleanup; F5's own live run could not
   then tell effort from prompt. Keep `general-purpose` with no effort, and move the
   worker body to one file the five agents share only if the host allows an include
   (it does not today; five identical bodies is acceptable, and the agent test should
   assert the five bodies are equal so they do not drift). Revisit a single worker
   type after the F5 live run shows the body is at least as good.

## Notes

9. **F1, open question 1.** Keep the baseline at the merge-base. It is the current
   `_adopt` behaviour (`controller.py:335`), VERIFY's comparisons and `featureAdded`
   (`postconditions.py:375`) depend on it, and a revise run that ignores a PR's own
   breakage would deliver an unverified PR. `startSha` from `lastKnownHead` beside
   `adoption.headSha` in `_phase_probes:478` and `_p8:490` is two sources for one
   fact; the plan's deferral is fine, but name it in `architecture.md`'s follow-ups so
   the map stays complete.

10. **F2, open question 2.** A new run per round is right. `result.json` is written
    once (`result.py:138,173`) and read as final by `_find_delivering_run_products`,
    `status` and the ledger; reopening would make every reader re-verify a record
    that was final. `--slug` resuming a finished run by name is consistent. The
    latest-`finishedAt` rule is the right tie-break; `finishedAt` exists in the record.

11. **F3 `compact` hook.** `contract.default_adapter(phase).compact` is the right
    registry call, and it is right even when the phase is bound external: compaction
    is the phase's meaning, not the implementer's. Say that in the plan so the next
    reader does not swap it for `resolve_implementation`.

12. **F3 guard test shape.** Rule (b) must check the receiver: `store.state["products"]
    .get("execute")` (`controller.py:1258`) and `store.state["implementations"]["phases"]
    .get("execute")` (`postconditions.py:160`) are legal, so only a subscript or `.get`
    whose receiver is the name `state` or an attribute chain ending in `.state` counts.
    Skip dict-literal keys (`state.py`'s initial shape). Scan `loop_spec/` only; tests
    read buckets freely.

13. **F5, open question 3.** Keep the mismatch as `unattested`. It is the same class
    of lead protocol error as a reworded prompt, and the existing re-dispatch path
    (`steps.submit:323-361`) already handles it with a reason the lead reads. A
    warning would be a second mechanism for one fault. Two edges for the live run:
    a `.meta.json` without `agentType` (older host) should read as a mismatch only
    when effort is set, and a level the model does not offer (`max` on a Sonnet
    worker) is refused by the host, not by `EFFORT_LEVELS`; the attestation reason
    should carry the host's text.

14. **F5 lead steps.** Recording a configured effort on a step the lead ran itself
    records what did not apply. `model` already has this property (`defaults.py:72`),
    so the plan is consistent with precedent; the README sentence is enough.

15. **F5 seam.** `dispatch_settings` beside `resolve_model`, `effort` on the step
    record and marker, `subagentType` derived rather than stored twice, and the SDK
    runner passing `effort` straight to `ClaudeAgentOptions` with no worker agents is
    the minimal shape. Nothing here needs a new module or dependency.

16. **Order.** Wave 3's dependency (F5's marker text lands in `runner.md`) holds; if
    finding 7 is taken, F4's marker fields and F5's `subagentType` land in one
    `marker_next` change, so do F4 and F5 in one wave.

## Round 2

Read against rev 2. Every round-1 finding is resolved as the plan's last section says,
and I checked the ones with design consequences:

- 1 (route facts): `state.routeFacts` is a core key; `route.py` keeps `state.route.result`.
  Resolved.
- 2 (fallbacks): no fallback reads; `check_compatible` (`controller.py:266`) refuses a
  pre-7.4.0 resume. The state-home scans call `StateStore.open` directly
  (`controller.py:167,196`), not `_open_existing:287`, so the refusal never fires on an
  old run being listed. Resolved.
- 3 (worktree): `FeaturePaths.feature_worktree`, no product field. Resolved.
- 4 (E11 recompute): declined with a reason I accept. The signals are what the reviewer
  was shown (`execute.py:489`), the product is read for the default implementation only,
  and that is the same trust the check has today. E3 fails on an unknown step. Resolved.
- 5, 6 (`baseline.py` stays pure; `_run_reproduction_runs` beside its siblings). Resolved.
- 7 (marker values): `program`, `stateHome`, `projectRoot` on the marker, stubs cite
  `runner.md`, no placeholder binding. Resolved.
- 8, 13, 14 (F5 defaults, refusal scope, lead steps): as recommended, with the refusal
  limited to `ATTESTATION_REQUIRED_ROLES` through the existing path. Resolved.
- 9-12, 15, 16: taken as notes; nothing to check.

Rev 2's "evidence fields read for default implementations only" rule closes the hole
Opus 2 found without adding a mechanism (`postconditions.py:160` is the precedent).

### Must-fix

17. **F2 `commentsCutoff` is a core read of `state.revise`.** Rev 2 has the prior
    record carry "the prior run's `gapsFetchedAt` when that run was a revise run", and
    `revise.step` records `gapsFetchedAt` in its own bucket. The only reader that can
    build `adoption.prior` is `_find_delivering_run_products`/`_delivering_run_entry`
    (`controller.py:176-218`), which would then read `state["revise"]["gapsFetchedAt"]`
    of the prior run: a subscript of `state` with the constant `"revise"` in a core
    module, which guard rule (b) flags. Same class as round-1 findings 1 and 2. Change:
    use the prior run's `state["run"]["createdAt"]` (core, `controller.py:137,250`) as
    the cutoff, normalised to gh's `...Z` form in `_delivering_run_entry`. It is earlier
    than any fetch that run made, so the error is in the safe direction (a comment
    posted between creation and the fetch is re-examined by the reviser under the
    same "only when the code still does not address it" sentence), and `gapsFetchedAt`
    then has no reader and is dropped. If the plan keeps a fetch time, it belongs in a
    record the core owns for that run at the time of the fetch, which the plug-in
    cannot write; there is none, so `createdAt` is the one that exists.

### Notes

18. **Resume refusal on runs without `loopSpecVersion`.** `state.py:36` writes it at
    create, but the comparison should treat a missing key as older than 7.4.0 rather
    than raise (Opus's line; named here because it is the one path the guard cannot
    see).

19. **`program` on the marker.** `Path(__file__).resolve().parents[1] / "loop-spec"`
    from `events.py` is `program/loop-spec`, the launcher the stubs run. Right file;
    the `test_events` case should assert it `is_file()` so a later move of `events.py`
    is caught.

## Round 3

Read against rev 4.

- 17 (`commentsCutoff`): now the prior revise run's `state.run.createdAt`, core-owned,
  rewritten to gh's `Z` form, `null` for a non-revise prior; `gapsFetchedAt` is gone.
  The core builds `adoption.prior` from core keys only. Resolved.
- 18 (missing version key): superseded by the `stateFormat` gate, which defaults a
  missing key to 1. Resolved.
- 19 (`program` on the marker): `Path(__file__).resolve().parents[1] / "loop-spec"`
  exists, and both `marker_next` and `marker_wait` carry the three fields. Resolved.

Rev 4's new material, checked for the ownership rule and the seam:

- `state.STATE_FORMAT = 2` written by `StateStore.create` is the right shape and place:
  `state.py` owns `state.json`, and it mirrors `baseline.NORMALIZATION_VERSION`
  (`baseline.py`, checked at `controller.py:279`). Gating on the format rather than
  `VERSION` is correct for the reason given (waves 2-3 run under 7.3.0's version
  string). Placing it before the `baseline is None` return (`controller.py:271-273`)
  and letting finished runs pass keeps `_routed_run` and re-printed results working.
  The scans still use `StateStore.open`, so old runs remain listable.
- `_find_run_by_adoption_number` skipping an old-format revise run reads `stateFormat`
  and `run`, both core. Fine.
- `checkouts` read for the default VERIFY only follows the rule rev 2 stated for every
  evidence field; consistent.
- `marker_wait(paths, ...)` already holds `paths`, so `project_root` and the state
  home (`paths.root.parents[1]`) are derivable there without threading; either way is
  one call site. Note only.

No new finding. Nothing in rev 4 adds a core read of a plug-in bucket, a plug-in
import in the core, a new module, or a dependency.

VERDICT: go
