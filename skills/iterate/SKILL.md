---
name: iterate
description: ITERATE phase - the outer convergence loop. Judges the integrated result against the ORIGINAL goal, then advances to DELIVER or classifies the highest-leverage gap so the graph's rewind routes send the cycle back to EXECUTE, PLAN, or (with human approval) SPEC/DISCUSS. Cycle-internal - invoked by /loop-spec:cycle; not for ad-hoc invocation (start there).
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion
---

# ITERATE

VERIFY proved the acceptance checklist; you ask whether the ORIGINAL goal
(`feature_title`, immutable, in the user's words) is met, and if not, what to fix
first. Main thread, no team: one fresh `iterate-judge` per pass (maker ≠ checker).
Inputs from `feature.json`: `slug`, `feature_title`, `iterate` (`maxIterations`,
`used`, `confirmationUsed`, `lastVerdict`, `feedback`, `history[]`), `artifacts`,
`execStyle`, `autonomous`, `backlogEntryId`, `models.iterateJudge`. The round limit is
the one bound the cycle respects.

## 1. Limit gate

`used >= maxIterations`: stop iterating and ship LOUD, never silent.

1. **Confirmation pass** (once): if `used > 0` and `confirmationUsed` is not true, set
   `iterate.confirmationUsed = true` first, then dispatch the judge as in step 2 with
   `mode=confirmation`. It never increments `used` and never rewinds. `converged` closes
   the goal with no limit warnings; otherwise its gaps are the fresher ones below.
2. **Harvest every gap** from the freshest verdict into `warnings[]`, each prefixed
   `iterate-budget-spent:`, and queue each on the backlog with its deterministic id:
   ```bash
   gid="$(bash "${CLAUDE_SKILL_DIR}/../../lib/backlog.sh" gap-id "<gap.fix_first>")"
   bash "${CLAUDE_SKILL_DIR}/../../lib/backlog.sh" add "{slug}" iterate-gap "<gap.description> — fix first: <gap.fix_first>" --id "$gid"
   ```
   This is the only point where ITERATE writes the backlog. **Terminal rule** (autonomous
   and `gid == feature.json.backlogEntryId`): two limits on the same gap means the
   approach is wrong. Record `iterate-terminal:` instead, close the entry with
   `backlog.sh terminal "$gid" "two iteration limits spent on {slug}; approach wrong"`,
   and write the evidence trail into ITERATION.md. Record the pattern once:
   `lib/rules.sh add "iterate limit spent on {slug} with a <type>-level gap: ..." --check "bash lib/criteria-coverage.sh <spec> <plan>"`.
   No confirmation pass possible: add `iterate-budget-spent: final remediation was never
   re-judged against the original goal`.
3. Write the final ITERATION.md section listing the warnings verbatim, run the exit
   command with `--terminal` (step 4), and return; the graph routes to DELIVER.

## 2. Judge

Emit the `dispatch` event, then ONE `Agent({description: "Iterate goal re-judge",
subagent_type: "loop-spec:iterate-judge", prompt: ...})` (add `model` only for an
alias) with: `slug`, `iteration = used + 1`, `original_goal = feature_title`, the
SPEC.md / PLAN.md / VERIFICATION.md paths, the `feat/{slug}` diff, and
`prior_feedback = iterate.feedback`. Dispatch, then stop. Never AskUserQuestion as a wait
(`skills/shared/dispatch.md`). Save its completion message to `$feature_dir/.iterate-judge.out` and extract the
verdict deterministically:

```bash
verdict=$(python3 - "$feature_dir/.iterate-judge.out" <<'PY'
import json, re, sys
txt = open(sys.argv[1]).read()
m = re.search(r"```json\s*(\{.*?\})\s*```", txt, re.S) or re.search(r"(\{.*\})", txt, re.S)
if not m: sys.exit("iterate-judge: no JSON verdict found")
d = json.loads(m.group(1))
for k in ("converged", "deterministic_gate_passed", "summary"):
    if k not in d: sys.exit(f"iterate-judge: verdict missing '{k}'")
print(json.dumps(d))
PY
) || { echo "ITERATE: malformed judge verdict; not shipping. Re-dispatch once, then escalate." >&2; }
```

A malformed verdict is never "converged": re-dispatch once, then escalate. Schema
(`agents/iterate-judge.md`): `{converged, deterministic_gate_passed, scores[], weakest,
gap{type,description,fix_first}, remaining_gaps[], summary}`.

Record it:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set "$feature_dir" iterate.used "$((used+1))"
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set "$feature_dir" iterate.lastVerdict "$verdict"
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" append "$feature_dir" iterate.history "$verdict"
bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit "$feature_dir" iterate_verdict --phase iterate \
  --data "{\"verdict\":\"$(jq -r 'if .converged then "converged" else "not-converged" end' <<<"$verdict")\",\"iteration\":$((used+1)),\"gap\":\"$(jq -r '.gap.type // "none"' <<<"$verdict")\"}" || true
```

Append one section to `docs/loop-spec/features/{slug}/ITERATION.md` (number,
converged?, per-criterion scores, weakest point, gap and fix-first, summary).

## 3. Decide

**Converged:** the deterministic floor runs first and can veto the judge:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/converged-floor.sh" "docs/loop-spec/features/{slug}/SPEC.md" "docs/loop-spec/features/{slug}/VERIFICATION.md"
```

Exit 1: print the `FLOOR` lines and treat the round as not converged with an
`execute`-type gap whose `fix_first` is the first FLOOR line. Exit 0: clear
`iterate.feedback`, run the exit command with `--terminal`, return; the graph routes to
DELIVER.

**Not converged:** write the gap so the re-entered phase fixes the weakest point first
(`feature-write.sh set "$feature_dir" iterate.feedback "<gap json>"`), then by `gap.type`:

- `execute`: one FULL-SHAPE remediation task per implementation gap, including every
  `remaining_gaps[]` entry of type `execute` (`subject: "Iterate fix: <fix_first>"`,
  `verifyCommand` from `commands.test` or the criterion's check, `files` as implicated
  or `[]`, `acceptanceCriteria: ["<fix_first>"]`), appended to `pendingRemediationTasks[]`.
- `plan`: PLAN re-plans the affected slice from `iterate.feedback`.
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

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/phase-exit.sh" iterate --feature-dir "$feature_dir" [--terminal]
```

Commits ITERATION.md (and the backlog) in single-repo mode; `--terminal` (converged or
limit spent) also closes the phase. A rewind leaves it open for the next pass. Return
to the cycle; in `step`/`interactive` print the verdict and where the graph routes next.
