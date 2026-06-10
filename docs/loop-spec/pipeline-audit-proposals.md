# Pipeline audit: propose-only improvements

Source: multi-agent audit of the 5 phase skills (SPEC/DISCUSS/PLAN/EXECUTE/VERIFY) plus shared infrastructure, run 2026-05-29. 56 raw findings were synthesized, ranked, and adversarially verified. The safe, high-value findings were implemented directly (see CHANGELOG `### Fixed` / `### Changed`). The items below restructure tested skill flow and therefore need eval evidence before shipping, per the project rule "skills are code; don't restructure tested skill content without eval evidence."

Each item lists the change, the rationale, and the evidence that would justify shipping it. Run the eval, attach the numbers, then promote to an implementation PR.

## Biggest levers (from the audit narrative)

The pipeline's largest losses are structural duplication and dropped structured data, not slow models:

1. The default new-feature path authors and commits SPEC.md twice (SPEC phase, then DISCUSS) and debates a spec already gated to <=0.20 ambiguity. Largest front-half wall-clock cost.
2. Structured data the producer computed is discarded at phase boundaries and re-derived downstream (planner `tasks[]` JSON re-parsed from PLAN.md markdown in EXECUTE).
3. Cheap deterministic gates run after expensive LLM debate, and every revision resets the debate to round 1.
4. Per-merge full-suite test runs serialize EXECUTE (O(tasks) suite runs).

## P1 - Collapse the duplicate SPEC.md pipeline

**Finding:** spec-1 / discuss-1 / shared-2.

**Change:** Pick a single owner of SPEC.md. Recommended: the SPEC phase produces the gated SPEC.md (with `ambiguity_scores`) and owns the spec-critique debate (wiring the advocate-1/challenger-1 it already spawns but never messages). DISCUSS is demoted to a thin open-questions pass that revises SPEC.md in place (Edit, not Write) and short-circuits its debate when SPEC.md frontmatter shows `gate_passed: true` and `unresolved_dimensions` empty. Dedupe the identical `spec: NO_JIRA {slug}` commit so only one phase commits SPEC.md.

**Why:** The default new-feature path pays for SPEC.md authoring twice plus two debates before PLAN starts, and the DISCUSS writer can clobber the gated spec (only a soft "preserve verbatim" guard exists).

**Eval needed:** A/B the spec-phase-only-authoring path vs current on a fixture set, comparing (1) final SPEC.md decision-coverage + downstream PLAN/VERIFY pass rate and (2) wall-clock. Ship only if quality is equal-or-better with materially lower wall-clock. Requires a smoke re-run (restructures two tested phases).

## P1 - Persist the planner's validated tasks[] as tasks.json

**Finding:** shared-1.

**Change:** At PLAN Step 6 write the validated `tasks[]` the lead already holds to `.loop-spec/features/{slug}/tasks.json` and add `artifacts.tasks` to the schema. EXECUTE Step 2a reads `tasks.json` when present, falling back to PLAN.md markdown parsing only if absent (preserves resume / manual-edit).

**Why:** The planner produces clean machine-readable `tasks[]` used only for the Step 4b gate, then dropped; EXECUTE re-derives the identical structure by markdown-parsing PLAN.md. Any drift between the prose table and per-task sections yields wrong `files[]`/`blockedBy`/`verifyCommand` at TaskCreate, surfacing only as a deep EXECUTE failure. This is the most ambiguity-prone handoff in the pipeline.

**Eval needed:** Validate the `tasks.json` fallback keeps smoke green and that resume / manual-edited PLAN.md still works via the markdown fallback. Changes the load-bearing PLAN->EXECUTE contract; warrants a fixture run.

## P2 - Dispatch pattern-mapper as a real teammate instead of inlining it into the opus planner

**Finding:** plan-2.

**Change:** Add `pattern-mapper-1` as a 4th teammate in the PLAN TeamCreate on sonnet/haiku, dispatch it first to produce PATTERNS.md, gate the planner spawn on its idle. Remove the inlined Step 0 mapper procedure from the planner brief and `loop-spec-planner.md`.

**Why:** At quality preset the planner runs on opus and does the read-only pattern-mapping that `model-policy.md` reserves for sonnet/haiku, burning the most expensive model on scouting. The standalone pattern-mapper agent and its richer report are dead code.

**Eval needed:** Compare PATTERNS.md analog precision and total cost/wall-clock of dispatched-mapper vs inlined-mapper across fixtures. Restructures the tested PLAN team; needs smoke validation that PLAN.md still emits and gates pass.

## P2 - Run cheap gates before the debate; cap revision re-debates at 1 round

**Finding:** plan-4 / plan-5 / discuss-5.

**Change:** PLAN: insert a debate-free validation pass (Step 4b feasibility + decision-coverage) immediately after the planner's first PLAN.md, re-dispatching the planner without a debate if it fails; keep the post-debate run too. On any fix-list re-dispatch (PLAN and DISCUSS), run a single targeted verification round (challenger confirms each fix-list item resolved) and only escalate to a full multi-round debate if a new issue is raised. Encode `reDebateRoundCap` in `tier-matrix.md`.

**Why:** A DAG cycle, empty acceptance criteria, non-runnable verify command, or dropped decision is caught only after 1-3 paid debate rounds, which then trigger a full re-debate from round 1. A one-line fix forces a brand-new full-length debate (up to ~9 debate rounds for trivial deltas on a quality feature).

**Eval needed:** Measure debate-round count and defect-escape rate with pre-debate validation + 1-round re-verify vs current full-reset, on a fixture set with seeded plan defects. Ship only if escape rate is unchanged. Restructures the tested debate loop; smoke must stay green.

## P2 - Batch the EXECUTE post-merge test gate; fast-path disjoint-file merges

**Finding:** execute-2 / execute-7.

**Change:** Run the full test suite once after the merge queue drains (end of Step 8) rather than after every merged task. Per-merge, run only the task's own verify command. Allow merges of tasks with disjoint `files[]` (using the synthetic-blockedBy set from Step 2b) to proceed without the full per-task gate; reserve serialization for tasks that share files. Keep ff-only semantics and the quick-tier skip.

**Why:** For N tasks the lead currently runs the entire suite N times, strictly serially inside the single-threaded FIFO merge loop, for largely redundant signal. This is the dominant EXECUTE wall-clock cost.

**Eval needed:** Confirm a final-only full-suite run catches the same regressions as per-task on a fixture with a deliberately introduced cross-task break, and measure wall-clock delta. Touches the tested merge-queue flow; smoke's implementer-distinctness and >=4-commit assertions must still hold.

## P3 - Unify the acceptance-criteria contract across SPEC/PLAN/EXECUTE/VERIFY

**Finding:** shared-7.

**Change:** Adopt a single flat acceptance-criteria list under a stable heading (recommend `## Acceptance criteria` to match VERIFY's awk and VERIFICATION.md) with pass/fail checkboxes and stable ids (`AC-1..`). If the Good Enough / Exceptional distinction is kept, encode it as a per-criterion tag (`[ ] AC-3 (stretch): ...`) not a section split. Update `SPEC.md.template`, the `## Success criteria` wording in `spec/SKILL.md`, and confirm `verify/SKILL.md`'s awk header matches.

**Why:** `SPEC.md.template` uses `## Success criteria` split into Good Enough / Exceptional, but VERIFY greps `## Acceptance criteria`, the VERIFICATION table and reviewer expect a flat per-criterion list, and the planner must guess whether Exceptional criteria become tasks. The acceptance-criteria contract is the spine of the pipeline and currently diverges in name and shape across four artifacts.

**Eval needed:** Renames a heading in tested prose and the SPEC template; verify the smoke awk still extracts a VERIFICATION table and that PLAN/EXECUTE/VERIFY still resolve criteria. Run on fixtures before shipping.

> Note: the VERIFY-side half of this (gate only on "Good Enough", report "Exceptional" as informational) was shipped as a brief-level instruction in the implemented batch; the full contract unification across all four artifacts remains eval-gated here.
