# SPEC interview prompts — calibration anchors, question banks, gate prompts

Reference for the SPEC orchestrator (`skills/spec/SKILL.md`). Loaded when running the
Step 2 interview or the autonomous self-answered pass; the skill body holds the scoring
model, the perspectives table, and the gate — this file holds the worked examples.

## Calibration anchors

Anchor each dimension against these examples (at the dimension minimum vs near-done at ~0.85):

| Dimension | At the minimum | At ~0.85 |
|-----------|----------------|----------|
| Goal Clarity (min 0.60) | "Make the export faster" (direction only, no measurable target) | "Cut p95 export latency from 4s to under 1.5s for a 10k-row sheet" |
| Boundary Clarity (min 0.50) | "Mostly the export path" (fuzzy edges) | "Touch only `export/*`; CSV and PDF paths explicitly out of scope" |
| Constraint Clarity (min 0.40) | "Should work on the current stack" | "Must stay on Python 3.12, no new deps, within the 2GB worker cap" |
| Acceptance Clarity (min 0.50) | "It should feel snappy" (subjective) | "`pytest tests/export_test.py` passes AND latency assertion <1.5s holds in CI" |

## Example questions per perspective

**Researcher (round 1):**
- "What exists in the codebase today related to this feature?"
- "What is the delta between today and the target state?"
- "What triggers this work - what is broken or missing?"

**Foundations (round 1 replacement when `feature.json.greenfield == true`):**
- "What language/runtime and framework? What is the deployment target (CLI, web service, desktop, library)?"
- "What project structure and tooling — test framework, linter, formatter, build tool?"
- "What is the smallest end-to-end slice that proves the app works (the walking skeleton)?"

**Simplifier (round 2):**
- "What is the simplest version that solves the core problem?"
- "If you had to cut 50%, what is the irreducible core?"
- "What would make this feature a success even without the nice-to-haves?"

**Boundary Keeper (round 3):**
- "What explicitly will NOT be done in this phase?"
- "What adjacent problems is it tempting to solve but should not be?"
- "What does 'done' look like - what is the final deliverable?"

**Failure Analyst (round 4):**
- "What is the worst thing that could go wrong if we get the requirements wrong?"
- "What does a broken version of this look like?"
- "What would cause a verifier to reject the output?"

**Seed Closer (rounds 5-6):**
- "We have [dimension] at [score] - what would make it completely clear?"
- "The remaining ambiguity is in [area] - can we make a decision now?"
- "Is there anything you would regret not specifying before planning starts?"

## Gate prompts (AskUserQuestion)

Call shapes per `skills/shared/harness-call-contracts.md`; `multiSelect: false` on both.
Routing after the answer lives in `skills/spec/SKILL.md`. Emit these as written —
never a prose shorthand or a wait.

**On gate pass:**

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
