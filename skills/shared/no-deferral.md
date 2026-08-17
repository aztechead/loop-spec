# No self-authored deferral (shared contract)

Once SPEC/DISCUSS/PLAN fix the design, the run's only job is to complete it.
**Everything in the spec ships.** There is no valid successful conclusion — in any
harness, any style, any cycle type — that includes an explicit model-authored
deferred-scope declaration. A "done" report with a `Deferred scope:` list is a failed
run wearing a green checkmark: it claims the design's scope while silently narrowing
it. Naming the concept in a negation, a template default, a quoted report, or a
runtime warning is not itself evidence that scope was dropped.

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

Anything else that explicitly declares unshipped scope on a completion surface is a
violation.

## Enforcement (deterministic probes, not prose hope)

- `lib/deferral-lint.sh text <path|->` — scans a completion surface (PR body, final
  report draft) for structured `Deferred scope:`, `Follow-ups:`, `Future work:`, or
  `Remaining work:` declarations and direct first-person commitments to defer. Empty
  (`none`) sections, negations, quoted/reported text, and code are ignored. Exit 0
  clean, 1 flagged.
- `lib/deferral-lint.sh warnings <feature.json>` validates warning shape only.
  `warnings[]` is an unstructured diagnostics channel and never proves scope was
  dropped.
- `lib/deliver.sh` runs the text lint on the rendered PR body before any push; **exit
  3** is the scope-violation route — the feature is NOT complete. Fix is never
  "reword the PR body": either ship the explicitly declared work (route back through
  EXECUTE) or remove an inaccurate scope declaration, then re-run DELIVER.
- `hooks/team/deferral-guard.sh` (Claude Code Stop hook) blocks any final message
  that combines a completion claim with an explicit unmarked scope declaration. The first denial
  records the transcript cursor and repository fingerprint; removing the words on the
  retry remains blocked. Clearing the obligation requires a later material repository
  change, implementation activity followed by verification, and a grounded
  `Resolved scope: <item> — <files and verification evidence>` line. OpenCode/ADK
  harnesses get delivery-surface protection from the `deliver.sh` gate and this
  contract.

## Before you print a completion report

Draft it, then probe it:

```bash
printf '%s' "$report" | bash "${CLAUDE_SKILL_DIR}/../../lib/deferral-lint.sh" text -
```

If it flags, do not soften the wording to slip past the probe — the declared dropped
scope is the defect. Ship the work.
