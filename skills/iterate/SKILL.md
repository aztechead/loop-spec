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

If `used >= maxit` OR `gused >= gmax`: **stop iterating and ship — but ship LOUD, never silent.** Do NOT re-enter an upstream phase — this is the article's `STOP WHEN: ... OR N iterations reached`. Before setting `currentPhase = "completed"`:

1. **Harvest every unresolved gap from `iterate.lastVerdict`** into `warnings[]` (one entry per below-8 criterion and per gap in `gap` / `remaining_gaps[]`), each prefixed `iterate-budget-spent:`. A budget-exhausted ship with an empty warning trail is indistinguishable from a clean converge — that silence is the failure mode this step exists to prevent.
2. **If a rewind fix landed after the last judge pass** (i.e. `used > 0` and the phase pointer arrived here from VERIFY, not from a fresh feature), append one more warning: `iterate-budget-spent: final remediation was never re-judged against the original goal (maxIterations reached before a confirming pass)`.
3. Write the final ITERATION.md section stating the budget was spent, listing the harvested warnings verbatim.
4. Set `currentPhase = "completed"` and go to Phase exit. The cycle's On-completion summary prints `warnings[]` — the user must see the accepted gaps without opening feature.json.

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

Parse the verdict JSON from its completion message (schema in `agents/iterate-judge.md`): `{converged, deterministic_gate_passed, scores[], weakest, gap{type,description,fix_first}, remaining_gaps[], summary}`. `gap` is the single highest-leverage miss that decides the routing; `remaining_gaps[]` (possibly empty) lists the other known misses so one pass can remediate several and a budget-exhausted ship can report ALL of them.

**Defensive parse (the verdict is the loop's oracle — extract it deterministically, do not eyeball it):** the judge returns the verdict inside a fenced ```json block. Capture its completion message to `$fdir/.iterate-judge.out`, then extract and validate before acting:

```bash
verdict=$(python3 - "$fdir/.iterate-judge.out" <<'PY'
import json, re, sys
txt = open(sys.argv[1]).read()
m = re.search(r"```json\s*(\{.*?\})\s*```", txt, re.S) or re.search(r"(\{.*\})", txt, re.S)
if not m: sys.exit("iterate-judge: no JSON verdict found in completion message")
d = json.loads(m.group(1))
for k in ("converged", "deterministic_gate_passed", "summary"):
    if k not in d: sys.exit(f"iterate-judge: verdict missing required key '{k}'")
print(json.dumps(d))
PY
) || { echo "ITERATE: malformed judge verdict; not shipping. Re-dispatch once, then escalate." >&2; }
```

A malformed or missing verdict must NOT be read as "converged": treat it as re-dispatch-once-then-escalate. The convergence decision (Step 3) reads the validated `$verdict`, never the raw message.

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

- **`execute`** — implementation gap. Convert `gap` into a remediation task (`subject = "Iterate fix: {gap.fix_first}"`, `verifyCommand` from `feature.commands.test` or the relevant acceptance check) and append to `pendingRemediationTasks[]` (EXECUTE Step 2a consumes it alongside PLAN.md tasks). **Also convert every `remaining_gaps[]` entry with `type == "execute"` into its own remediation task** — the iteration budget counts judge passes, not fixes, so burning one pass per known miss when several are already identified wastes the budget the loop needs to converge. Set `currentPhase = "execute"`.
- **`plan`** — decomposition gap. Set `currentPhase = "plan"`. PLAN reads `iterate.feedback` and re-plans the affected slice (it does not re-author the whole plan from scratch; it addresses the gap). 
- **`spec`** — goal unmet because the SPEC captured the wrong thing. This is the expensive rewind, but it is **autonomous in the autonomous styles** — it does NOT block on a human. The loop stays hands-off because the rewind cannot game its own oracle: the `iterate-judge` always scores against the **immutable original goal** (`feature.json.feature_title`), never the rewritten SPEC, so refining the spec can only move the work toward the original goal, not redefine "done". The iteration budget (Step 0) hard-caps the number of rewinds.

  Branch by `execStyle` (read from `feature.json`):
  - **`auto` / `review-only` (autonomous):** set `currentPhase = "discuss"` and proceed WITHOUT asking. DISCUSS re-entry runs in **autonomous refinement mode** (driven by `iterate.feedback` + the immutable original goal; it does not run its interactive clarifying loop — see `skills/discuss/SKILL.md` ITERATE re-entry note). No `AskUserQuestion`. The next VERIFY→ITERATE pass re-judges against the original goal and either converges or spends another iteration.
  - **`step` / `interactive` (human-in-loop by choice):** the user explicitly opted into per-phase control, so here — and ONLY here — present the approval gate:
    ```
    AskUserQuestion({
      header: "Re-open SPEC?",
      question: "ITERATE judges the goal still unmet because of a SPEC-level gap: {gap.description}. Re-open SPEC/DISCUSS, ship as-is, or stop?",
      options: ["Re-open SPEC/DISCUSS", "Ship as-is", "Stop - hand back"]
    })
    ```
    Re-open → `currentPhase = "discuss"`; Ship as-is → `currentPhase = "completed"` + record the accepted gap in `warnings[]`; Stop → pause per the **cycle-resume-escalation** contract.
  - **Non-interactive** (`LOOP_SPEC_NON_INTERACTIVE=1`): treat as autonomous — re-enter DISCUSS in refinement mode (same as `auto`). `LOOP_SPEC_ANSWER_ITERATE_SPEC` ∈ {reopen, ship} overrides; default `reopen`.

The autonomy guarantee: in `auto`/`review-only`, **no gap type ever blocks on a human**. The loop runs EXECUTE/PLAN/SPEC rewinds on its own until it converges or the iteration budget is spent, then it ships-with-warnings (Step 0). The only thing that ever returns control to you mid-loop is the explicit human-in-loop styles, or a hard escalation (budget-exhausted in `step`/`interactive`). An overnight `auto` run never waits for input.

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
- **Fix the weakest first — but carry the whole list.** Each rewind carries `iterate.feedback` so the re-entered phase targets the single highest-leverage gap first; `remaining_gaps[]` rides along so already-identified execute-level misses are remediated in the same pass instead of costing one judge iteration each.
- **Never ship silent.** Both terminal paths (converged, budget-spent) end in the cycle's On-completion summary; the budget-spent path must arrive there with every accepted gap in `warnings[]` so the summary shows them.
