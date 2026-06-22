---
name: iterate
description: ITERATE phase - the outer convergence loop. Judges the integrated result against the ORIGINAL goal (deterministic acceptance gate + an LLM goal re-judge), and either ships (converged or iteration budget spent) or classifies the highest-leverage gap and routes the cycle back to EXECUTE, PLAN, or (with human approval) SPEC/DISCUSS. Bounded by feature.iterate.maxIterations.
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion
---

# ITERATE Phase

You are the ITERATE phase orchestrator, running on the **main thread**. Invoked by `loop-spec:cycle` when `feature.json.currentPhase == "iterate"` — i.e. after VERIFY's gates passed. VERIFY proves the SPEC acceptance checklist is met; ITERATE asks the harder question the article calls the heart of a loop: **are we actually there yet, measured against the original goal — and if not, feed the result back in and repeat.**

This phase runs no team. It dispatches ONE fresh `iterate-judge` subagent (maker ≠ checker) for the goal re-judge, decides on its verdict, and rewinds or advances the phase pointer. The bounded outer loop is: `... EXECUTE → VERIFY → ITERATE → (EXECUTE|PLAN|SPEC again | completed)`.

## Inputs (from feature.json)

- `slug`, `tier`, `feature_dir`, `feature_title` (the **original goal**, in the user's words).
- `iterate`: `{maxIterations, used, lastVerdict, feedback, history[]}`.
- `retryBudget.global` / `globalUsed` (cycle-wide ceiling).
- `artifacts`: `spec`, `plan`, `verification` paths.
- `models.iterateJudge` (opus).

## Procedure

### Step 0 - Budget gate (hard stop first)

A loop with no exit drains the account. Before judging, check the caps:

```bash
fdir=".loop-spec/features/${slug}"
used=$(jq -r '.iterate.used' "$fdir/feature.json")
maxit=$(jq -r '.iterate.maxIterations' "$fdir/feature.json")
gused=$(jq -r '.retryBudget.globalUsed' "$fdir/feature.json")
gmax=$(jq -r '.retryBudget.global' "$fdir/feature.json")
```

If `used >= maxit` OR `gused >= gmax`: **stop iterating and ship.** Set `currentPhase = "completed"`, append a note to `warnings[]` that the iteration budget was spent with the last verdict's gaps unresolved, write the final ITERATION.md, and go to Phase exit. Do NOT re-enter an upstream phase — this is the article's `STOP WHEN: ... OR N iterations reached`.

### Step 1 - Dispatch the judge (maker ≠ checker)

One-shot `Agent` dispatch (not a team), fresh context, strict grader:

```
Agent({
  subagent_type: "loop-spec:iterate-judge",
  model: feature.models.iterateJudge,   // opus
  prompt: "<iterate-judge.md inputs: slug, tier, iteration=(used+1), original_goal=feature_title,
            paths to SPEC.md / VERIFICATION.md / PLAN.md, feat/{slug} diff, and prior_feedback=feature.iterate.feedback>"
})
```

Parse the verdict JSON from its completion message (schema in `agents/iterate-judge.md`): `{converged, deterministic_gate_passed, scores[], weakest, gap{type,description,fix_first}, summary}`.

### Step 2 - Record the iteration

```bash
# increment counters and append the verdict to history
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set "$fdir" iterate.used "$((used+1))"
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set "$fdir" retryBudget.globalUsed "$((gused+1))"
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set "$fdir" iterate.lastVerdict "<verdict json>"
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" append "$fdir" iterate.history "<verdict json>"
```

Write a human-readable `docs/loop-spec/features/{slug}/ITERATION.md` (append one section per iteration: number, converged?, per-criterion scores, weakest point, gap + fix-first, summary). Set `artifacts.iteration` to that path. Commit it:

```bash
git add docs/loop-spec/features/{slug}/ITERATION.md
git commit -m "iterate: NO_JIRA {slug} iteration $((used+1))"
```

### Step 3 - DECIDE

**Converged** (`verdict.converged == true`): set `currentPhase = "completed"`. Clear `iterate.feedback = null`. Go to Phase exit → the cycle ships.

**Not converged:** route by `gap.type`. In every case, write the gap so the re-entered phase can "fix the weakest point first":

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set "$fdir" iterate.feedback "<gap json>"
```

- **`execute`** — implementation gap. Convert `gap` into a remediation task (`subject = "Iterate fix: {gap.fix_first}"`, `verifyCommand` from `feature.commands.test` or the relevant acceptance check) and append to `pendingRemediationTasks[]` (EXECUTE Step 2a consumes it alongside PLAN.md tasks). Set `currentPhase = "execute"`.
- **`plan`** — decomposition gap. Set `currentPhase = "plan"`. PLAN reads `iterate.feedback` and re-plans the affected slice (it does not re-author the whole plan from scratch; it addresses the gap). 
- **`spec`** — goal unmet because the SPEC captured the wrong thing. This is the expensive rewind and **requires human approval** (it can change scope):
  ```
  AskUserQuestion({
    header: "Re-open SPEC?",
    question: "ITERATE judges the goal still unmet because of a SPEC-level gap: {gap.description}. Re-open SPEC/DISCUSS (may change scope), ship as-is, or stop and hand back?",
    options: ["Re-open SPEC/DISCUSS", "Ship as-is", "Stop - escalate to me"]
  })
  ```
  - "Re-open SPEC/DISCUSS": set `currentPhase = "discuss"` (DISCUSS refines the SPEC; full re-open of the Socratic interview only if the user asks). 
  - "Ship as-is": `currentPhase = "completed"`, record the accepted gap in `warnings[]`.
  - "Stop - escalate": pause per the **cycle-resume-escalation** contract, surfacing the gap.
  - **Non-interactive** (`LOOP_SPEC_NON_INTERACTIVE=1`): never silently re-open SPEC. Default to escalate (pause) with the gap recorded; honor `LOOP_SPEC_ANSWER_ITERATE_SPEC` ∈ {reopen, ship, escalate} if set.

Clear `currentTeamName`/`currentTeammates` are already null (ITERATE ran no team).

### Step 4 - Phase routing

| execStyle | Action |
|---|---|
| `auto`, `review-only` | If `currentPhase == "completed"`: proceed to the cycle's On-completion. Else: return to cycle, which re-invokes `Skill(loop-spec:{currentPhase})` for the rewind. |
| `step`, `interactive` | Print the iteration verdict (converged? / gap / where it routes next) and return to the user; they re-invoke `Skill(loop-spec:cycle)` to continue. |

## Phase exit

ITERATE does not append itself to `completedPhases` on a rewind (it will run again after the next VERIFY). It appends `"iterate"` to `completedPhases` only on the terminal pass (converged or budget-spent), immediately before `currentPhase = "completed"`.

## Design notes

- **The deterministic gate is the floor; the goal re-judge is the ceiling.** ITERATE never ships on the judge's word alone — `deterministic_gate_passed` (from VERIFICATION.md) must hold too. And it never ships on a green checklist alone — the judge must agree the *goal* is met. This is the dual oracle.
- **Bounded, always.** `maxIterations` is tier-scaled (quick 1 / balanced 2 / quality 3) and the cycle-wide `global` budget is also respected. The loop ships or escalates; it never spins.
- **Don't stop to ask mid-loop**, except the one SPEC-rewind approval gate (scope changes are the user's call). Everywhere else, the judge assumes, notes it, and the loop continues — per the article's self-checking-loop rule.
- **Fix the weakest first.** Each rewind carries `iterate.feedback` so the re-entered phase targets the single highest-leverage gap rather than re-doing everything.
