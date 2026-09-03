# Operating Guide (single-tier)

The quick/balanced/quality tier axis was removed in v2.5.0 (hard cutover). One
independent choice remains: the **execution style**.

## Fixed gate behavior

Every feature gets the same treatment (`skills/shared/tier-matrix.md`):

- Spec critique (challenger-only): skipped when the spec is already gated (`gate_passed`, no unresolved dimensions, no security signal) or on the maintenance profile. ITERATE re-entry always runs it. A passed SPEC gate does not skip the DISCUSS design loop.
- Plan critique: runs unless the **structural fast-path** holds — <=2 tasks,
  <=3 files, no security-signal match in SPEC/PLAN. Measured AFTER planning,
  never inferred from the prompt.
- Code review HARD-GATE: blocks on Critical + Important; Minor findings are
  appended to `.loop-spec/BACKLOG.md`, never silently dropped.
- Test-tamper scan, marker scan, acceptance gate, coverage gates: always on,
  always blocking.
- The one limit: `iterate.maxIterations` defaults to 10 and may be set from 1 to 100
  with `LOOP_SPEC_ITERATE_MAX_ITERATIONS`. Critique gates stop re-dispatching the
  author at the delta ceiling `graph/critique.graph.json` declares
  (`LOOP_SPEC_CRITIQUE_ROUNDS` overrides it; `0` means unbounded).

**Why no tiers:** the tier was chosen from prompt wording before anyone knew the
real scope, and every gate it skipped became a shipped defect class (unjudged
iterate fixes, deferred-to-nowhere findings, uncritiqued specs). Scope-based
control (fast-path + DAG-width ladder) replaces intent-based tiering.

## Execution style — controls how much you supervise

| Style | Behavior |
|---|---|
| `auto` (default) | Runs the full cycle without pausing between phases. SPEC and DISCUSS still grill a human (DISCUSS caps at 5 Q rounds). Pauses only on iteration-limit exhaustion or hard escalation. Not autonomous mode. |
| `step` | Stops after every phase; you re-invoke to continue. SPEC/DISCUSS clarifying loops have no round cap. |
| `interactive` | Like step, and also pauses before every agent dispatch. SPEC/DISCUSS clarifying loops have no round cap. |
| `review-only` | No SPEC/DISCUSS clarifying loop; critique-gate findings pause for your review. |

Override inline anywhere in the prompt: `style:step`. Never asked via menu.

## Model map (fixed)

Opus authors and judges: spec-writer, planner, challenger,
spec-compliance-reviewer, iterate-judge, code-reviewer. Sonnet implements,
verifies (mechanical command execution), and maps. See
`skills/shared/model-matrix.md`.
