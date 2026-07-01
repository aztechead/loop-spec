# Operating Guide (single-tier)

The quick/balanced/quality tier axis was removed in v2.5.0 (hard cutover). One
independent choice remains: the **execution style**.

## Fixed gate + budget behavior

Every feature gets the same treatment (`skills/shared/tier-matrix.md`):

- Spec critique (advocate + challenger): ALWAYS runs.
- Plan critique: runs unless the **structural fast-path** holds — <=2 tasks,
  <=3 files, no security-signal match in SPEC/PLAN. Measured AFTER planning,
  never inferred from the prompt.
- Code review HARD-GATE: blocks on Critical + Important; Minor findings are
  appended to `.loop-spec/BACKLOG.md`, never silently dropped.
- Test-tamper scan, marker scan, acceptance gate, coverage gates: always on,
  always blocking.
- Budgets: 3 retries per gate, 40 global, `iterate.maxIterations = 10`.

**Why no tiers:** the tier was chosen from prompt wording before anyone knew the
real scope, and every gate it skipped became a shipped defect class (unjudged
iterate fixes, deferred-to-nowhere findings, uncritiqued specs). Scope-based
cost control (fast-path + DAG-width ladder) replaces intent-based cost control.

## Execution style — controls how much you supervise

| Style | Behavior |
|---|---|
| `auto` (default) | Runs the full cycle hands-off; pauses only on budget exhaustion or hard escalation. |
| `step` | Stops after every phase; you re-invoke to continue. |
| `interactive` | Like step, plus interactive clarifying loops in SPEC/DISCUSS. |
| `review-only` | Autonomous, but critique-gate findings pause for your review. |

Override inline anywhere in the prompt: `style:step`. Never asked via menu.

## Model map (fixed)

Opus authors and judges: spec-writer, planner, advocate, challenger,
spec-compliance-reviewer, iterate-judge, code-reviewer. Sonnet implements,
verifies (mechanical command execution), and maps. See
`skills/shared/model-matrix.md`.
