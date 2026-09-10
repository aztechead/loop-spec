# No self-authored deferral (shared contract)

Complete the scope set by SPEC, DISCUSS, and PLAN.
**Everything in the spec ships**, except work recorded by the bounded gates below.
No harness, style, or cycle type permits the model to declare completion after deferring scope on its own.
Negations, template defaults, quoted reports, and runtime warnings do not by themselves prove that the run dropped scope.

## The rule

- If it is in the spec/design, it is in scope. Implement it before concluding.
- Never suggest deferring spec scope.
  Resolve scope questions during SPEC or DISCUSS through the user or autonomous decision record.
  The spec's "Out of scope" section defines the design boundary.
- If an item cannot or should not ship during EXECUTE or VERIFY, route the gap through ITERATE's rewind machinery.
  Do not replace that route with a deferral note.

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

## Enforcement

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
printf '%s' "$report" | bash "${LOOP_SPEC_SKILL_DIR}/../../lib/deferral-lint.sh" text -
```

If the report identifies unfinished scope, complete that work. Do not hide it by changing the report's wording.
