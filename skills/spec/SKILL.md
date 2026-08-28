---
name: spec
description: SPEC phase - Socratic interview with quantitative ambiguity scoring; gates ambiguity <= 0.20. Cycle-internal - invoked by /loop-spec:cycle against the active feature's state; not for ad-hoc invocation on a bare user request (start via /loop-spec:cycle).
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
is created by `loop-spec:cycle` Step 5 (slug, execStyle, the full `iterate`/`models`
blocks). Invoking `/loop-spec:spec` directly with no in-flight feature
leaves every downstream phase (all phases read `feature.json`, ITERATE reads `iterate`)
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

**Score from the SPEC text you could write right now, not from optimism about where the conversation is heading.** Calibration anchors (per-dimension examples at the minimum vs ~0.85): `${CLAUDE_SKILL_DIR}/references/interview-prompts.md`.

## Interview Perspectives

Apply one perspective per round. Each perspective surfaces different blindspots. Ask 2-3 questions per round maximum; do not frontload all questions at once. Example question banks per perspective: `${CLAUDE_SKILL_DIR}/references/interview-prompts.md`.

| Round | Perspective      | Focus                                                  |
|-------|-----------------|--------------------------------------------------------|
| 1     | Researcher       | Ground the discussion in current reality               |
| 2     | Simplifier       | Surface minimum viable scope                           |
| 3     | Boundary Keeper  | Lock the perimeter of what is and is not in scope      |
| 4     | Failure Analyst  | Find edge cases that invalidate requirements           |
| 5     | Seed Closer      | Lock remaining undecided territory                     |
| 6     | Seed Closer      | Final pass on lowest-scoring dimensions                |

**Greenfield (`feature.json.greenfield == true`): round 1 runs the Foundations perspective instead of Researcher** — there is no codebase to research; the foundations ARE the round-1 blindspot (stack, tooling, walking skeleton — question bank in the reference; autonomous mode self-answers preferring the boring industry-standard choice for the app's domain). The chosen stack and its canonical test/lint/typecheck commands MUST land in SPEC.md as explicit requirements (PLAN's scaffold task and EXECUTE's command backfill read them). Rounds 2-6 are unchanged.

## Procedure

### Step 1 - Scout the codebase

Before asking any questions, read for grounding context:
- `.loop-spec/features/{slug}/` - feature.json and any prior `spec-interview-transcript.md` (resume context)
- `docs/loop-spec/features/{slug}/` - any prior SPEC.md or committed artifacts
- `docs/loop-spec/codebase/` - domain maps (TECH, ARCH, QUALITY, CONCERNS, DOMAIN) if present
- **Read the code that already exists.** Before interviewing, find out what is there — there is no stored map to consult, so derive it:
  - Search for the feature area by name, by the vocabulary the user used, and by the obvious symbol names. Does an implementation already exist? What does it touch?
  - Read the entry points you find, not just the matches. A hit tells you where to look; the surrounding file tells you what it does.
  - Follow the imports and callers of anything you will change, far enough to name the boundaries the change crosses. Those boundaries are what turn a generic interview question into a precise one ("this would touch `X` which also feeds `Y` — in scope?").
  - **Fan this out.** Send subagents to scan and return findings with `file:line` evidence rather than pulling a large tree through your own context. Interrogate what they return; do not adopt it unread.
  - **Workspace mode:** scan each participating repository separately and preserve the repository name in every finding.
  Every claim you carry into SPEC.md cites `file:line`. (**Greenfield:** there is no code yet — ground in the stated goal and the chosen stack's conventions instead.)

**External-reality scout (probe-before-assert).** Before treating any factual premise about an external system as fact (in synthesis, ambiguity scoring, or interview questions):

1. Enumerate every external system the ask names or implies (datasets, APIs, services, infra).
2. For each, run the cheapest READ-ONLY probe available (`bq show`, `bq query --dry_run`, `gcloud describe`, `aws ... describe`, `psql -c '\d'`, `curl -s`, `<tool> --version`) and record the result:
   ```bash
   bash "${CLAUDE_SKILL_DIR}/../../lib/evidence.sh" add \
     "docs/loop-spec/features/{slug}/EVIDENCE.md" \
     "<claim>" "<command>" "<output>"
   ```
   The script prints the assigned `EVID-NNN` id; use it to cite the probe in interview questions and the eventual `## Grounding` section.
3. Researcher-round questions must state probed facts with their `EVID-NNN`, never memory-asserted facts.
4. Unverifiable (no CLI, no creds, offline): record it as `ASSUMPTION: <claim> | verify: <command>` per `skills/shared/grounding-protocol.md`. In autonomous styles (`feature.json.autonomous == true` or `LOOP_SPEC_AUTONOMOUS=1`) also record via `bash "${CLAUDE_SKILL_DIR}/../../lib/decisions.sh" add ...` — never ask the user about it. In step/interactive styles, surface the assumption conversationally but do not block indefinitely.

Synthesize current state internally: what exists today related to this feature, and the gap to the target state. Do not present this synthesis to the user - use it to ask precise, grounded questions.

Score all 4 dimensions from what you already know (feature title, any existing context). This is the initial assessment; display it before the first round.

If `feature.json.autonomous == true` (or `LOOP_SPEC_AUTONOMOUS=1`): run Step 2 in **self-answered form** per the **Autonomous mode** section below — do NOT fall through to the thinner non-interactive synthesis.

If `LOOP_SPEC_NON_INTERACTIVE=1` is set (and autonomous is not): skip Step 2 entirely and go to the **Non-interactive mode** section below.

**`execStyle: auto` still interviews.** Auto means the cycle does not pause after this phase. A human is attached. Run Step 2 with `AskUserQuestion`. Self-answer only under **Autonomous mode** below. Do not skip rounds because the request seems clear enough to write SPEC.md already — the gate scores the interview, not the one-liner.

**Maintenance profile:** if `feature.json.executionProfile == "maintenance"`, skip the
interview (Step 2) and synthesize SPEC.md from the request plus the Step 1 scout, exactly
as **Non-interactive mode** does. The classification that earned this profile already
established a low-risk mechanical change of at most five files with low ambiguity
(`lib/cycle-profile.sh`); a six-round Socratic interview has nothing left to resolve.
The ambiguity gate is NOT skipped: score the 4 dimensions against the synthesized draft
and, if any dimension is below its minimum, fall back to the ordinary Step 2 interview
(non-interactive styles write `gate_passed: false` with the failing dimensions as usual).
Log one line: `spec interview skipped (maintenance profile)`.

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

**On gate pass** (ambiguity <= 0.20 AND all per-dimension minimums met), ask the "Spec gate" question (full prompt in `${CLAUDE_SKILL_DIR}/references/interview-prompts.md`): "Yes - write SPEC.md" or "Done talking - write it" → Step 3; "One more round" → continue the loop.

**On round 6 reached with the gate still failing**, ask the "Max rounds" question (same reference): "Write SPEC.md anyway" → Step 3, marking unresolved dimensions in the `ambiguity_scores` block (`gate_passed: false`); "Keep talking" → continue without a round limit; "Abandon" → stop without writing; report that the user abandoned and return to the cycle.

### Step 3 - Write SPEC.md and the transcript

Write SPEC.md directly (the main thread is unrestricted by `hooks/restrict-agent-paths.sh`):

- SPEC.md to `docs/loop-spec/features/{slug}/SPEC.md` (must begin with the `ambiguity_scores` frontmatter block - see SPEC.md Output Format below).
- Interview transcript (all rounds, all questions, all scores) to `.loop-spec/features/{slug}/spec-interview-transcript.md`.

Then run the structural format gate — DISCUSS and every later phase parse SPEC.md by its
template headings, so a drifted section name or a fence-wrapped file costs the next phase
cycles it should not spend:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/artifact-lint.sh" spec "docs/loop-spec/features/{slug}/SPEC.md"
```

Exit 1 BLOCKS: fix SPEC.md in place per the FLAG lines (you wrote it; use
`skills/shared/artifact-templates/SPEC.md.template` as the shape) and re-run until it
prints `artifact-lint: ok`.

### Step 3.5 - Fresh-eyes pruning pass (advisory)

The lints above catch malformed and ungrounded content, never surplus content — and the
orchestrator that just ran the interview cannot honestly judge surplus, because it heard
every line justified. Dispatch ONE context-free reviewer (a fresh subagent, not this
thread) carrying `${CLAUDE_SKILL_DIR}/../../skills/shared/review-prompts/prose-pruning.md`
verbatim, plus ONLY the written SPEC.md and
`skills/shared/artifact-templates/SPEC.md.template` — never the interview transcript.

Skip the dispatch when SPEC.md is under 60 lines (`wc -l`): a spec that small cannot
repay a subagent.

Adjudicate the returned `cut:`/`merge:`/`shrink:` list yourself, as the maker:

- Apply proposals failing `duplicate` or `narrative` — those tests are near-mechanical.
- Judge `derivable`/`speculative`/`over-template` proposals on their merits; the prompt's
  carve-outs are hard limits (`### Good Enough` criteria, decisions, `ambiguity_scores`,
  grounding lines are NEVER cut here — an `out-of-scope:` line goes to the user in
  interactive styles and to `.loop-spec/BACKLOG.md` in autonomous ones).
- Re-run the Step 3 `artifact-lint.sh spec` after applying any cut.
- Record the full proposal list and each disposition in the interview transcript.

Advisory means advisory: an empty list, a declined list, or a failed dispatch never
blocks Step 4.

### Step 4 - Update feature.json

Update `feature.json` via `lib/feature-write.sh`:
- `artifacts.specInterview = ".loop-spec/features/{slug}/spec-interview-transcript.md"`
- `artifacts.spec = "docs/loop-spec/features/{slug}/SPEC.md"`
- `completedPhases` append `"spec"`

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

Always return to the cycle orchestrator; never invoke a successor phase directly.
SPEC declares no successor — `graph/cycle.graph.json` does, and the engine
(`lib/graph/run.sh`, cycle Step 6) selects the next node. Cycle owns the phase
boundary: continuous mode enters the engine-selected node immediately, while
`phaseHandoff == true` writes the paused result and ends the main-agent invocation.
For `step` / `interactive`, include
`SPEC complete. SPEC.md at docs/loop-spec/features/{slug}/SPEC.md.` in the returned
phase summary.

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

Section structure and per-requirement shape (testable statement, current state, target state, acceptance criterion; mandatory in/out-of-scope boundary lists; pass/fail checkbox criteria only) follow `skills/shared/artifact-templates/SPEC.md.template` — the Step 3 `artifact-lint.sh spec` gate enforces it.

The discuss phase reads this SPEC.md and refines it; if its frontmatter contains `ambiguity_scores`, discuss preserves the block verbatim.

## Non-interactive mode

When `LOOP_SPEC_NON_INTERACTIVE=1` is set there is no user to interview. The orchestrator does not run Step 2; instead it synthesizes SPEC.md from the available context (feature title, codebase domain maps) and always writes the file - it never abandons.

| Env var                           | Values       | Behavior it controls                                            |
|-----------------------------------|--------------|-----------------------------------------------------------------|
| `LOOP_SPEC_ANSWER_SPEC_CONFIRM`  | `yes`, `no`  | Confirm writing SPEC.md when the synthesized gate passes (default: `yes`) |
| `LOOP_SPEC_ANSWER_SPEC_OVERRIDE` | `yes`, `no`  | Write SPEC.md despite a failing synthesized gate (default: `yes`) |

Synthesis procedure (non-interactive):
1. Resolve both answers and reject invalid values before scouting:
   ```bash
   spec_confirm="${LOOP_SPEC_ANSWER_SPEC_CONFIRM:-yes}"
   spec_override="${LOOP_SPEC_ANSWER_SPEC_OVERRIDE:-yes}"
   case "$spec_confirm" in yes|no) ;; *) echo "SPEC: LOOP_SPEC_ANSWER_SPEC_CONFIRM must be yes or no" >&2; exit 2 ;; esac
   case "$spec_override" in yes|no) ;; *) echo "SPEC: LOOP_SPEC_ANSWER_SPEC_OVERRIDE must be yes or no" >&2; exit 2 ;; esac
   ```
2. Run Step 1 (scout + initial scoring) only.
3. Derive the best SPEC.md you can from the feature title and codebase context. Score the 4 dimensions honestly from that text.
4. If the synthesized gate passes and `spec_confirm == yes`, write SPEC.md with
   `gate_passed: true`. If it passes and `spec_confirm == no`, do not write or advance
   the phase: write a paused cycle result with reason `spec-confirmation-declined` and
   summary `SPEC synthesis passed, but LOOP_SPEC_ANSWER_SPEC_CONFIRM=no declined the write.`,
   then return to cycle.
5. If the synthesized gate fails and `spec_override == yes`, write SPEC.md with
   `gate_passed: false` and list the failing dimensions in `unresolved_dimensions`.
   If it fails and `spec_override == no`, do not write or advance the phase: write a
   paused cycle result with reason `spec-override-declined` and a summary naming the
   failing dimensions, then return to cycle.
6. Write the transcript (a short note that the spec was synthesized non-interactively, with the scores).
7. Proceed to Step 4 (update feature.json), Step 5 (commit), Step 6 (route).

The defaults always write, preserving unattended behavior. An explicit `no` is an
operator-requested durable pause, not an ignored answer and not a completion claim.

## Autonomous mode (self-answered interview)

When `feature.json.autonomous == true` (or `LOOP_SPEC_AUTONOMOUS=1`), there is no user —
but the interview still runs, because the perspectives are what surface blindspots. The
orchestrator plays both roles (`skills/shared/autonomous-mode.md` self-answer rule):

1. Run Step 1 (scout + initial scoring) as normal. The graph scout matters MORE here —
   it is the only source of grounding.
2. **Run all six perspectives in ONE pass, not round-by-round.** The round structure
   exists to pace a human's turn-taking; self-answering needs the perspectives (they are
   the blindspot coverage), not the turns. Walk the perspectives table in order
   (Researcher/Foundations → Simplifier → Boundary Keeper → Failure Analyst → Seed
   Closer): for each, formulate its 2-3 questions, then answer each one yourself with
   the recommendation you would have marked as the default option — grounded first in
   what the codebase already does (graph/map evidence), then industry best practice,
   then the most reversible choice. Do not skip a perspective because earlier answers
   feel sufficient.
3. **Score the 4 dimensions ONCE, at the end of the pass**, from the complete Q→A set —
   honestly; do not inflate scores because you authored the answers. Display one scoring
   block (`rounds_completed: 1`). Gate prompts self-answer: on gate pass take "Yes -
   write SPEC.md"; on a failing gate, spend ONE targeted follow-up pass on the failing
   dimensions (Seed Closer questions only), re-score, then take "Write SPEC.md anyway"
   if still failing (`gate_passed: false`, dimensions listed in `unresolved_dimensions`
   for DISCUSS's autonomous resolution). Never "Abandon".
4. Record every Q → A → one-line rationale TO DISK — `bash
   "${CLAUDE_SKILL_DIR}/../../lib/decisions.sh" add "{feature_dir}" spec "<q>" "<a>"
   "<why>"` — and mark it `(self-answered)` in the transcript. Batch the writes: one
   Bash invocation chaining the `decisions.sh add` calls at the end of the pass (the
   answers exist on disk before SPEC.md is written; there is no human turn boundary to
   flush at). The store already holds any setup decisions the cycle staged before SPEC
   ran (workspace repos, resume choice, detected commands — migrated at Step 5). When
   writing SPEC.md, render the complete record into a `## Decisions (assumed —
   autonomous)` list inside the `<decisions>` block: `decisions.sh render
   "{feature_dir}"` emits the lines verbatim. PLAN copies these forward into `## User
   decisions (already made)` suffixed `(assumed)`, so the escalation contract treats
   them exactly like human answers.
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
