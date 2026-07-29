# No self-authored deferral (shared contract)

Once SPEC/DISCUSS/PLAN fix the design, the run's only job is to complete it.
**Everything in the spec ships.** There is no valid successful conclusion — in any
harness, any style, any cycle type — that includes deferred items, follow-ups,
"future work", "next steps", or scope notes the MODEL chose on its own. A "done"
report with a deferral list is a failed run wearing a green checkmark: it claims the
design's scope while silently narrowing it.

## The rule

- If it is in the spec/design, it is in scope. Implement it before concluding.
- Never SUGGEST deferring spec scope, in any phase. Scope questions belong to the
  design phases (SPEC's interview, DISCUSS's boundary work) where the USER (or the
  autonomous decision record) sets them — a spec's "Out of scope" section is design,
  not deferral.
- If mid-EXECUTE/VERIFY you believe an item cannot or should not ship, that is a gap:
  route it through ITERATE's rewind machinery, not into a "deferred" note. The loop
  works gaps; it does not annotate them away.

## The only legitimate deferral writers (bounded gates, not judgment)

Three rule-driven mechanisms may record unshipped work, and each stamps its marker on
the line it writes — that marker is what the probes exempt:

| Marker | Writer | Bound |
|---|---|---|
| `iterate-budget-spent:` | ITERATE, when `iterate.maxIterations` is exhausted | iteration limit |
| `iterate-terminal:` | ITERATE, when a re-drained gap spends a second full limit | two limits, exact gap-id match |
| `verify-deferred` | VERIFY's Minor-finding backlog rule on PASS_WITH_MINOR | code-review severity gate |

Anything else that speaks deferral language on a completion surface is a violation.

## Enforcement (deterministic probes, not prose hope)

- `lib/deferral-lint.sh text <path|->` — scans a completion surface (PR body, final
  report draft) for self-authored deferral vocabulary; gate-marked lines are exempt.
  Exit 0 clean, 1 flagged.
- `lib/deferral-lint.sh warnings <feature.json>` — `warnings[]` entries carrying
  deferral language must START with a bounded-gate prefix.
- `lib/deliver.sh` runs both on the rendered PR body and feature warnings before any
  push; **exit 3** is the scope-violation route — the feature is NOT complete. Fix is
  never "reword the PR body": either ship the flagged work (route back through
  EXECUTE) or correct a mislabeled gate line at its source, then re-run DELIVER.
- `hooks/team/deferral-guard.sh` (Claude Code Stop hook) blocks any final message
  that combines a completion claim with unmarked deferral language. pi/OpenCode
  harnesses get the same protection from the `deliver.sh` gate and this contract.

## Before you print a completion report

Draft it, then probe it:

```bash
printf '%s' "$report" | bash "${CLAUDE_SKILL_DIR}/../../lib/deferral-lint.sh" text -
```

If it flags, do not soften the wording to slip past the probe — the vocabulary is the
symptom, the dropped scope is the defect. Ship the work.
