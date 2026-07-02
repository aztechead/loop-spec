---
name: spec
description: SPEC phase - Socratic interview with quantitative ambiguity scoring; gates ambiguity <= 0.20
allowed-tools: Bash Read Write Edit Glob Grep Skill AskUserQuestion
---

# SPEC Phase

You are the SPEC phase orchestrator, running on the **main thread**. Invoked by `loop-spec:cycle` after style + slug are chosen. Your responsibility: run a Socratic interview across up to 6 rounds, score 4 ambiguity dimensions after each round, gate on ambiguity <= 0.20 with per-dimension minimums, and write SPEC.md with an `ambiguity_scores` frontmatter block.

**The interview runs on the main thread, not in a subagent.** A spawned teammate cannot hold an interactive question-and-answer with the user (it runs one turn and goes idle). Only the main-thread orchestrator has a real `AskUserQuestion` loop with the user. This phase therefore creates no team and spawns no teammates; it asks questions, scores answers, and writes the file directly. This mirrors `skills/discuss/SKILL.md` Step 1, which already runs its clarifying loop on the main thread.

## Inputs (from cycle skill via feature.json)

- `slug`, `execStyle`, `feature_title`
- `feature_dir`: `.loop-spec/features/{slug}/`
- `feature_json_path`: `.loop-spec/features/{slug}/feature.json`

## Precondition — SPEC is cycle-initialized, not standalone

SPEC reads (and at Step 4 writes) `feature.json`; it does NOT bootstrap one. `feature.json`
is created by `loop-spec:cycle` Step 5 (slug, execStyle, the full `retryBudget`/
`iterate`/`models` blocks). Invoking `/loop-spec:spec` directly with no in-flight feature
leaves every downstream phase (DISCUSS/PLAN read `retryBudget`, ITERATE reads `iterate`)
without the state they require — do not hand-author a partial `feature.json` to work around
this.

Before Step 1, assert the contract and abort with guidance if it is unmet:

```bash
# A feature.json must already exist for some in-flight feature (cycle created it).
if ! ls .loop-spec/features/*/feature.json >/dev/null 2>&1; then
  echo "loop-spec:spec is a cycle phase, not a standalone entry point." >&2
  echo "  No .loop-spec/features/*/feature.json found. Start the feature with:" >&2
  echo "    /loop-spec:cycle <feature description>" >&2
  echo "  cycle runs SPEC as its first phase after initializing feature.json." >&2
  exit 2
fi
```

(When `loop-spec:cycle` invokes this skill it has already created `feature.json`, so the
guard is a no-op on the normal path; it only fires on a bare standalone invocation.)

## Ambiguity Model

Score each dimension 0.0 (completely unclear) to 1.0 (crystal clear):

| Dimension          | Weight | Minimum | What it measures                                  |
|--------------------|--------|---------|---------------------------------------------------|
| Goal Clarity       | 35%    | 0.60    | Is the outcome specific and measurable?           |
| Boundary Clarity   | 25%    | 0.50    | What is in scope vs out of scope?                 |
| Constraint Clarity | 20%    | 0.40    | Performance, compatibility, data requirements?    |
| Acceptance Clarity | 20%    | 0.50    | How do we know it is done?                         |

**Ambiguity score formula:** `1.0 - (0.35 * goal_clarity + 0.25 * boundary_clarity + 0.20 * constraint_clarity + 0.20 * acceptance_clarity)`

**Gate:** ambiguity <= 0.20 AND goal_clarity >= 0.60 AND boundary_clarity >= 0.50 AND constraint_clarity >= 0.40 AND acceptance_clarity >= 0.50

**Score from the SPEC text you could write right now, not from optimism about where the conversation is heading.** Anchor each dimension against these calibration examples (at the dimension minimum vs near-done at ~0.85):

| Dimension | At the minimum | At ~0.85 |
|-----------|----------------|----------|
| Goal Clarity (min 0.60) | "Make the export faster" (direction only, no measurable target) | "Cut p95 export latency from 4s to under 1.5s for a 10k-row sheet" |
| Boundary Clarity (min 0.50) | "Mostly the export path" (fuzzy edges) | "Touch only `export/*`; CSV and PDF paths explicitly out of scope" |
| Constraint Clarity (min 0.40) | "Should work on the current stack" | "Must stay on Python 3.12, no new deps, within the 2GB worker cap" |
| Acceptance Clarity (min 0.50) | "It should feel snappy" (subjective) | "`pytest tests/export_test.py` passes AND latency assertion <1.5s holds in CI" |

## Interview Perspectives

Apply one perspective per round. Each perspective surfaces different blindspots. Ask 2-3 questions per round maximum; do not frontload all questions at once.

| Round | Perspective      | Focus                                                  |
|-------|-----------------|--------------------------------------------------------|
| 1     | Researcher       | Ground the discussion in current reality               |
| 2     | Simplifier       | Surface minimum viable scope                           |
| 3     | Boundary Keeper  | Lock the perimeter of what is and is not in scope      |
| 4     | Failure Analyst  | Find edge cases that invalidate requirements           |
| 5     | Seed Closer      | Lock remaining undecided territory                     |
| 6     | Seed Closer      | Final pass on lowest-scoring dimensions                |

**Researcher (round 1) example questions:**
- "What exists in the codebase today related to this feature?"
- "What is the delta between today and the target state?"
- "What triggers this work - what is broken or missing?"

**Greenfield (`feature.json.greenfield == true`): round 1 runs the Foundations perspective instead of Researcher** — there is no codebase to research; the foundations ARE the round-1 blindspot. Ask (or in autonomous mode self-answer, preferring the boring industry-standard choice for the app's domain):
- "What language/runtime and framework? What is the deployment target (CLI, web service, desktop, library)?"
- "What project structure and tooling — test framework, linter, formatter, build tool?"
- "What is the smallest end-to-end slice that proves the app works (the walking skeleton)?"
The chosen stack and its canonical test/lint/typecheck commands MUST land in SPEC.md as explicit requirements (PLAN's scaffold task and EXECUTE's command backfill read them). Rounds 2-6 are unchanged.

**Simplifier (round 2) example questions:**
- "What is the simplest version that solves the core problem?"
- "If you had to cut 50%, what is the irreducible core?"
- "What would make this feature a success even without the nice-to-haves?"

**Boundary Keeper (round 3) example questions:**
- "What explicitly will NOT be done in this phase?"
- "What adjacent problems is it tempting to solve but should not be?"
- "What does 'done' look like - what is the final deliverable?"

**Failure Analyst (round 4) example questions:**
- "What is the worst thing that could go wrong if we get the requirements wrong?"
- "What does a broken version of this look like?"
- "What would cause a verifier to reject the output?"

**Seed Closer (rounds 5-6) example questions:**
- "We have [dimension] at [score] - what would make it completely clear?"
- "The remaining ambiguity is in [area] - can we make a decision now?"
- "Is there anything you would regret not specifying before planning starts?"

## Procedure

### Step 1 - Scout the codebase

Before asking any questions, read for grounding context:
- `.loop-spec/features/{slug}/` - feature.json and any prior `spec-interview-transcript.md` (resume context)
- `docs/loop-spec/features/{slug}/` - any prior SPEC.md or committed artifacts
- `docs/loop-spec/codebase/` - domain maps (TECH, ARCH, QUALITY, CONCERNS, DOMAIN) if present
- **The code graph (required).** graphify is a hard requirement, so `graphify-out/graph.json` is present. Ground yourself in what already exists for this feature area before interviewing:
  - `graphify query "<feature area>"` — does an implementation already exist? What does it touch?
  - `graphify-out/GRAPH_REPORT.md` — "god nodes" and cross-module connections reveal which subsystems a change will ripple through, so you can ask sharper boundary/constraint questions.
  - `graphify explain "<entity>"` / `graphify path "<A>" "<B>"` — confirm how the target area connects to the rest of the system.
  Use the graph to ask precise questions ("this would touch `X` which also feeds `Y` — in scope?") instead of generic ones. (Absent only under `LOOP_SPEC_REQUIRE_GRAPHIFY=0` degraded mode; then use flat-file reads. **Greenfield:** the graph build is deferred until source exists — skip the graph scout and ground in the stated goal and the chosen stack's conventions instead.)
- Relevant source files to understand current state

Synthesize current state internally: what exists today related to this feature, and the gap to the target state. Do not present this synthesis to the user - use it to ask precise, grounded questions.

Score all 4 dimensions from what you already know (feature title, any existing context). This is the initial assessment; display it before the first round.

If `feature.json.autonomous == true` (or `LOOP_SPEC_AUTONOMOUS=1`): run Step 2 in **self-answered form** per the **Autonomous mode** section below — do NOT fall through to the thinner non-interactive synthesis.

If `LOOP_SPEC_NON_INTERACTIVE=1` is set (and autonomous is not): skip Step 2 entirely and go to the **Non-interactive mode** section below.

**Spec-file ingest mode:** if `.loop-spec/features/{slug}/spec-draft.md` exists (cycle Step 3 placed it there — the user pre-authored the spec), skip the interview (Step 2) entirely:

1. Read the draft. Treat it as the primary source of truth for goal, scope, constraints, and criteria; the Step 1 graph scout grounds it against the actual codebase.
2. Score the 4 ambiguity dimensions against the DRAFT (not against interview answers). A well-written spec file typically passes the gate outright.
3. Normalize the draft into the required SPEC.md output format below — preserve the author's requirements verbatim wherever they already fit a section; add only what the format requires (`ambiguity_scores` frontmatter, `<decisions>` block from any decisions the draft states, `## Boundaries (what NOT to do)`, `### Good Enough` / `### Exceptional` split). Do not invent scope the draft doesn't state.
4. If a dimension is below its minimum, do NOT interview: in `step`/`interactive` styles ask ONE targeted `AskUserQuestion` per failing dimension; in `auto`/`review-only`/non-interactive, write SPEC.md with `gate_passed: false` and the failing dimensions in `unresolved_dimensions` (DISCUSS Step 1 consumes them).
5. Continue at Step 3 (write SPEC.md + transcript; note `source: spec-draft.md` in the transcript).

### Step 2 - Interview loop (main thread, max 6 rounds)

Run the loop directly on the main thread. For each round N = 1 .. 6:

1. Ask 2-3 questions using the perspective for round N. Use `AskUserQuestion`. **When a question has discernible options (a scope cut, a data shape, an integration point, a yes/no decision), present them as structured multiple-choice with explicit tradeoffs**; reserve free-text for genuinely open prompts. This matches the discuss-phase convention.
2. Read the user's answers.
3. Update all 4 dimension scores from the answers.
4. Compute the ambiguity score and display the scoring block (format below).
5. Run the gate check.

**Scoring block displayed after each round:**

```
After round [N]:
  Goal Clarity:       [score] (min 0.60) [pass or needs improvement]
  Boundary Clarity:   [score] (min 0.50) [pass or needs improvement]
  Constraint Clarity: [score] (min 0.40) [pass or needs improvement]
  Acceptance Clarity: [score] (min 0.50) [pass or needs improvement]
  Ambiguity: [score] (gate: <= 0.20)
```

**On gate pass** (ambiguity <= 0.20 AND all per-dimension minimums met):

```
AskUserQuestion({
  questions: [{
    question: "Ambiguity is [score] after round [N] - requirements are clear enough to write SPEC.md. Proceed?",
    header: "Spec gate",
    options: [
      { label: "Yes - write SPEC.md", description: "Requirements are clear; proceed to the draft" },
      { label: "One more round", description: "Ask another round of clarifying questions first" },
      { label: "Done talking - write it", description: "Stop the interview and write with what we have" }
    ],
    multiSelect: false
  }]
})
```

If the user selects "Yes" or "Done talking - write it": go to Step 3. If "One more round": continue the loop.

**On round 6 reached with the gate still failing:**

```
AskUserQuestion({
  questions: [{
    question: "After 6 rounds, ambiguity is [score]. Dimensions still below minimum: [list]. What would you like to do?",
    header: "Max rounds",
    options: [
      { label: "Write SPEC.md anyway", description: "Flag unresolved dimensions as assumptions; DISCUSS resolves them" },
      { label: "Keep talking", description: "Continue the interview with no round limit from here" },
      { label: "Abandon", description: "Exit without writing a spec" }
    ],
    multiSelect: false
  }]
})
```

If "Write SPEC.md anyway": go to Step 3, marking unresolved dimensions in the `ambiguity_scores` block (`gate_passed: false`). If "Keep talking": continue without a round limit. If "Abandon": stop without writing; report that the user abandoned and return to the cycle.

### Step 3 - Write SPEC.md and the transcript

Write SPEC.md directly (the main thread is unrestricted by `hooks/restrict-agent-paths.sh`):

- SPEC.md to `docs/loop-spec/features/{slug}/SPEC.md` (must begin with the `ambiguity_scores` frontmatter block - see SPEC.md Output Format below).
- Interview transcript (all rounds, all questions, all scores) to `.loop-spec/features/{slug}/spec-interview-transcript.md`.

### Step 4 - Update feature.json

Update `feature.json` via `lib/feature-write.sh`:
- `artifacts.specInterview = ".loop-spec/features/{slug}/spec-interview-transcript.md"`
- `artifacts.spec = "docs/loop-spec/features/{slug}/SPEC.md"`
- `completedPhases` append `"spec"`
- `currentPhase = "discuss"`

### Step 5 - Commit SPEC.md

```bash
git add docs/loop-spec/features/{slug}/SPEC.md
git commit -m "spec: NO_JIRA {slug}"
```

Also commit the interview transcript if it was written:

```bash
if [[ -f ".loop-spec/features/{slug}/spec-interview-transcript.md" ]]; then
  git add ".loop-spec/features/{slug}/spec-interview-transcript.md"
  git commit -m "docs: NO_JIRA {slug} spec interview transcript"
fi
```

### Step 6 - Phase routing

| execStyle    | Action                                                                          |
|--------------|---------------------------------------------------------------------------------|
| auto         | Invoke `Skill(loop-spec:discuss)` immediately                                  |
| step         | Print "SPEC complete. SPEC.md at docs/loop-spec/features/{slug}/SPEC.md." Return to user. |
| interactive  | Same as step.                                                                   |
| review-only  | Invoke `Skill(loop-spec:discuss)` (gate already paused for human if findings)  |

Return.

## SPEC.md Output Format

SPEC.md MUST begin with an `ambiguity_scores` YAML frontmatter block:

```yaml
---
ambiguity_scores:
  goal_clarity: 0.85
  boundary_clarity: 0.80
  constraint_clarity: 0.75
  acceptance_clarity: 0.80
  ambiguity: 0.18
  rounds_completed: 3
  gate_passed: true
  unresolved_dimensions: []
---
```

If any dimension is below its minimum when SPEC.md is written (user override at round 6, or non-interactive synthesis with thin input), set `gate_passed: false` and list the dimension names in `unresolved_dimensions`. DISCUSS Step 1 consumes this list: each entry is resolved with the user (interactive styles) or as an explicit graph-grounded assumption (autonomous styles), converted into a testable `### Good Enough` criterion, and removed from the list — see `skills/discuss/SKILL.md`.

Every requirement entry in SPEC.md MUST have:
- One specific, testable statement
- Current state (what exists now)
- Target state (what it should become)
- Acceptance criterion (how to verify it was met)

Boundaries are mandatory explicit lists:
- "In scope" - what this feature produces
- "Out of scope" - what it explicitly does NOT do (with brief reasoning)

Acceptance criteria must be pass/fail checkboxes. No subjective criteria.

The discuss phase reads this SPEC.md and refines it; if its frontmatter contains `ambiguity_scores`, discuss preserves the block verbatim.

## Non-interactive mode

When `LOOP_SPEC_NON_INTERACTIVE=1` is set there is no user to interview. The orchestrator does not run Step 2; instead it synthesizes SPEC.md from the available context (feature title, codebase domain maps) and always writes the file - it never abandons.

| Env var                           | Values       | Behavior it controls                                            |
|-----------------------------------|--------------|-----------------------------------------------------------------|
| `LOOP_SPEC_ANSWER_SPEC_CONFIRM`  | `yes`, `no`  | Confirm writing SPEC.md when the synthesized gate passes (default: `yes`) |
| `LOOP_SPEC_ANSWER_SPEC_OVERRIDE` | `yes`, `no`  | Write SPEC.md despite a failing synthesized gate (default: `yes`) |

Synthesis procedure (non-interactive):
1. Run Step 1 (scout + initial scoring) only.
2. Derive the best SPEC.md you can from the feature title and codebase context. Score the 4 dimensions honestly from that text.
3. If the synthesized gate passes (or `LOOP_SPEC_ANSWER_SPEC_CONFIRM` is unset/`yes`): write SPEC.md with `gate_passed: true`.
4. If the synthesized gate fails: write SPEC.md anyway (default, or when `LOOP_SPEC_ANSWER_SPEC_OVERRIDE` is unset/`yes`) with `gate_passed: false` and the failing dimensions listed in `unresolved_dimensions`.
5. Write the transcript (a short note that the spec was synthesized non-interactively, with the scores).
6. Proceed to Step 4 (update feature.json), Step 5 (commit), Step 6 (route).

Non-interactive mode never selects "Abandon": SPEC.md is always written.

## Autonomous mode (self-answered interview)

When `feature.json.autonomous == true` (or `LOOP_SPEC_AUTONOMOUS=1`), there is no user —
but the interview still runs, because the perspectives are what surface blindspots. The
orchestrator plays both roles (`skills/shared/autonomous-mode.md` self-answer rule):

1. Run Step 1 (scout + initial scoring) as normal. The graph scout matters MORE here —
   it is the only source of grounding.
2. For each round N (same perspectives table, max 6 — in practice self-answering
   converges in 2-3): formulate the round's 2-3 questions, then answer each one yourself
   with the recommendation you would have marked as the default option — grounded first
   in what the codebase already does (graph/map evidence), then industry best practice,
   then the most reversible choice. Score the 4 dimensions after each round from the
   answers, honestly — do not inflate scores because you authored the answers.
3. Gate prompts self-answer: on gate pass take "Yes - write SPEC.md"; at round 6 with a
   failing gate take "Write SPEC.md anyway" (`gate_passed: false`, dimensions listed in
   `unresolved_dimensions` for DISCUSS's autonomous resolution). Never "Abandon".
4. Record every Q → A → one-line rationale in the transcript (marked `(self-answered)`),
   and add a `## Decisions (assumed — autonomous)` list inside SPEC.md's `<decisions>`
   block — one entry per assumed answer, PLUS any setup decisions the cycle buffered
   before SPEC ran (workspace repos, resume choice, detected commands). PLAN copies these
   forward into `## User decisions (already made)` suffixed `(assumed)`, so the
   escalation contract treats them exactly like human answers.
5. Proceed to Steps 3-6 unchanged.

Autonomous beats non-interactive synthesis when both are set: the self-answered interview
produces a spec with explicit, auditable assumptions instead of a one-shot guess.

## Resume

If invoked with `currentPhase == "spec"` already in `feature.json`:

1. Read `feature.json` and check `artifacts.spec`:
   - `artifacts.spec` is set: SPEC.md was written but the phase advance failed; jump to Step 4.
   - `artifacts.spec` is null: the interview did not complete. Check `.loop-spec/features/{slug}/spec-interview-transcript.md` for partial progress.
2. On resume with a partial transcript: read it, restore the prior round scores, and continue the interview loop (Step 2) from the next round rather than restarting. Do not re-ask questions already answered in the transcript.
3. This phase holds no team, so there is no team-liveness probe and no `currentTeamName` to clear (it stays `null` throughout the spec phase).
