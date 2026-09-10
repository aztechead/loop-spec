---
name: iterate
description: "Judge the integrated result against the original goal. Route unresolved gaps through the graph or advance to DELIVER. Internal phase of /loop-spec:cycle. Start there for repository work."
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion
---

# ITERATE

Check whether the integrated result meets the original goal after VERIFY passes the acceptance checklist.
Use the immutable `feature_title` in the user's words. If the goal remains unmet, identify what to fix first.
Run in the main thread without a team. Use one fresh `iterate-judge` per pass, separate from the implementation author.

The `iterate` block stores `maxIterations`, `used`, `confirmationUsed`, `lastVerdict`, `feedback`, and `history[]`.
It controls the iteration limit. Read only the entry packet as input:

```bash
pb="$(bash "${LOOP_SPEC_SKILL_DIR}/../../lib/cycle-driver.sh" phase-begin iterate --feature-dir "$feature_dir")"
# .entry.fields .entry.read[] .entry.flags[] (a missing ingress; relay and return)
```

## 1. Limit gate

```bash
lim="$(bash "${LOOP_SPEC_SKILL_DIR}/../../lib/cycle-driver.sh" iterate limit --feature-dir "$feature_dir")"
# .route=judge|confirmation|harvest .used .max
```

For `judge`, continue to step 2.
When `used >= maxIterations`, stop ordinary iterations and record the remaining gaps before delivery:

1. **Confirmation pass** (`confirmation`, once): `confirmationUsed` is now set; dispatch
   the judge as in step 2 with `mode=confirmation` and record it with `--confirmation`.
   It never increments `used` and never rewinds. `converged` closes the goal with no
   limit warnings; otherwise its gaps are the fresher ones below.
2. **Harvest** (`harvest`): one call moves every gap of the freshest verdict into
   `warnings[]`, each prefixed `iterate-budget-spent:`, and onto the backlog with its
   deterministic id (`lib/backlog.sh gap-id`, `lib/backlog.sh add {slug} iterate-gap ... --id`):
   ```bash
   harvest="$(bash "${LOOP_SPEC_SKILL_DIR}/../../lib/cycle-driver.sh" iterate harvest --feature-dir "$feature_dir")"
   # .route=deliver .warnings[] .terminal
   ```
   This is the only point where ITERATE writes the backlog. **Terminal rule** (autonomous
   and `gid == feature.json.backlogEntryId`, reported as `.terminal`): two limits on the
   same gap means the approach is wrong; the warning is `iterate-terminal:`, the entry is
   closed with `backlog.sh terminal`, and the pattern is recorded once with
   `lib/rules.sh add "iterate limit spent on {slug} with a <type>-level gap: ..."`. Write
   the evidence trail into ITERATION.md. No confirmation pass possible: the warning is
   `iterate-budget-spent: final remediation was never re-judged against the original goal`.
3. Write the final ITERATION.md section listing `.warnings[]` verbatim and return; the
   cycle's `next` closes the phase (`--terminal`) and the graph routes to DELIVER.

## 2. Judge

Emit the `dispatch` event, then ONE `Agent({description: "Iterate goal re-judge",
subagent_type: "loop-spec:iterate-judge", run_in_background: false, prompt: ...})` (add
`model` only for an alias) with: `slug`, `iteration = used + 1`, `original_goal =
feature_title`, the SPEC.md / PLAN.md / VERIFICATION.md paths, the `feat/{slug}` diff, and
`prior_feedback = iterate.feedback`. The tool result is its completion message.
Never AskUserQuestion as a wait (`skills/shared/dispatch.md`). Save that message to
`$feature_dir/.iterate-judge.out` and record it with
one call, which extracts the verdict deterministically, writes `iterate.used`,
`iterate.lastVerdict`, and `iterate.history[]`, emits `iterate_verdict`, runs the
converged floor, and writes the feedback and remediation tasks a gap needs:

```bash
rec="$(bash "${LOOP_SPEC_SKILL_DIR}/../../lib/cycle-driver.sh" iterate record --feature-dir "$feature_dir" \
  --judge-out "$feature_dir/.iterate-judge.out" [--confirmation])"
# .verdict .converged .floor[] .route=deliver|execute|plan|spec|harvest|escalate .tasks[]
```

Exit 1 is a malformed verdict, never "converged": re-dispatch once, then escalate.
Schema (`agents/iterate-judge.md`): `{converged, deterministic_gate_passed, scores[],
weakest, gap{type,description,fix_first}, remaining_gaps[], summary}`.

Append one section to `docs/loop-spec/features/{slug}/ITERATION.md` (number,
converged?, per-criterion scores, weakest point, gap and fix-first, summary).

## 3. Decide

`.route` is the decision; `lib/converged-floor.sh` ran first and can veto the judge.

**Converged** (`deliver`): the floor held (`.floor[]` empty), `iterate.feedback` is
cleared; return, the cycle's `next` closes the phase with `--terminal` and the graph
routes to DELIVER. A violated floor (`.floor[]` holds the `FLOOR` lines) was already
treated as not converged with an `execute`-type gap whose `fix_first` is the first
FLOOR line: print the lines. Never edit VERIFICATION.md here: the verifier owns it, and
VERIFY's exit already ran `converged-floor.sh --shape` on the table.
Follow the recorded route for the failed result or incomplete evidence. Do not repair verification records in ITERATE.

**Not converged:** `iterate.feedback` holds the gap so the re-entered phase fixes the
weakest point first; by `.route` (`gap.type`):

- `execute`: one FULL-SHAPE remediation task per implementation gap, including every
  `remaining_gaps[]` entry of type `execute` (`subject: "Iterate fix: <fix_first>"`,
  `verifyCommand` from `commands.test` or the criterion's check, `files` as implicated
  or `[]`, `acceptanceCriteria: ["<fix_first>"]`), is already appended to
  `pendingRemediationTasks[]` (`.tasks[]`).
- `verify`: the converged floor vetoed over an incomplete verification record with no
  FAIL row (a missing grounding row, a non-PASS result). VERIFY re-runs the verifier,
  which completes VERIFICATION.md; nothing is dispatched to an implementer.
- `plan`: PLAN re-plans the affected slice from `iterate.feedback`.
- `escalate`: the gap needs an operator (`gap.needs_operator`, or the same `fix_first`
  survived a remediation round). Print the fix and return; the cycle's `next` ends the
  run `DONE status=escalated` with that fix as the reason, in every mode. Never rewind
  again for it and never `AskUserQuestion` (autonomous and headless runs have nobody to
  answer; the result record carries the action).
- `spec`: the expensive rewind. `auto`/`review-only`/autonomous (ITERATE re-entry; do not block an unattended loop):
  proceed without asking; DISCUSS refines toward the immutable original goal. `step`/`interactive`
  only: emit as written
  ```
  AskUserQuestion({
    questions: [{
      question: "ITERATE judges the goal still unmet because of a SPEC-level gap: <gap.description>. Re-open SPEC/DISCUSS, ship as-is, or stop?",
      header: "Re-open SPEC",
      options: [
        { label: "Re-open SPEC/DISCUSS", description: "Rewind to refine the spec toward the original goal (costs an iteration)" },
        { label: "Ship as-is", description: "Complete now; the accepted gap is recorded in warnings[] and the backlog" },
        { label: "Stop - hand back", description: "Pause the cycle and return control (resume later)" }
      ],
      multiSelect: false
    }]
  })
  ```
  Ship as-is records the gap in `warnings[]` and exits terminal; Stop pauses through the
  cycle. Non-interactive reads `LOOP_SPEC_ANSWER_ITERATE_SPEC` (`reopen` default |
  `ship`; anything else exits 2).

The backlog is never an option while rounds remain, and a gap "noted as a follow-up"
instead of routed is self-authored deferral (`skills/shared/no-deferral.md`). You
record the gap; `graph/cycle.graph.json` selects the rewind target from it. In
`auto`/`review-only` no gap type ever blocks on a human.

## 4. Exit

Return to the cycle; never run the exit yourself. Its `next --returned-from iterate`
runs `lib/phase-exit.sh iterate`, which commits ITERATION.md (and the backlog) in
single-repo mode, with `--terminal` (converged, or the limit spent) when the recorded
verdict says so, closing the phase. A rewind leaves it open for the next pass. In
`step`/`interactive` print the verdict and where the graph routes next.
