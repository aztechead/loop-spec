# Engineering stances — canonical prompt directive

Single source of truth for the five senior-engineer stances a phase adopts when the work
has that shape: build from scratch, system design, refactor, debug, and performance. A
stance is a mindset plus the deliverables that prove it was held. A stance
never selects a route or a phase (`lib/task-route.sh` and the graph do that); it says
how the phase already running does its job and what its artifact must contain. Enforced by
`tests/engineering-stances-coverage.test.sh`.

Reader: an agent about to write, plan, review, or debug under loop-spec, and the
maintainer editing a dispatch prompt. The quality contracts stay where they are: the
laziness ladder (how much code), design for change (where the boundaries sit), code for
humans (how it reads), docs for humans (the markdown), engineering directives (versions,
idiom, scale, tests). This file adds the *posture* each phase takes toward the work.

## Why a stance is not a prompt

"Think like a senior engineer" is a fine opening line for a chat and a useless one in a
dispatch: the executor cannot tell whether it held the stance. Each row below therefore
pairs the mindset with an artifact section, so VERIFY and ITERATE can check the section
instead of the attitude. A phase that adopts a stance writes the deliverables; a phase
that skips a deliverable says why in one line where the section would be.

## The five stances

| Stance | Fires when | Mindset | Deliverables | Artifact | Binds in |
|---|---|---|---|---|---|
| **Build from scratch** | `feature.json.greenfield == true` | A senior full-stack engineer building a production-ready application. Design the system first, then build the smallest version that can scale: the true MVP of a startup, never a prototype that has to be thrown away. | Architecture; file structure; database schema; API endpoints; interface architecture; complete code | SPEC.md `## Constraints` and `## User-facing behavior` (the stack, the walking skeleton); PLAN.md `## System design` and `## File map` | SPEC (Foundations round), DISCUSS (grill), PLAN (planner) |
| **System design** | The spec adds a component, a store, a service boundary, or a cache; always under greenfield | A senior systems architect. Name every component and its owner, trace each data flow end to end, and bound the design against the input the deployment controls before a line of code exists. | Architecture; component structure; data flows; API design; database schema; caching strategy; implementation code | PLAN.md `## System design` (one bullet per deliverable, `- none` with a reason for any that does not apply); task steps carry the scale bound | DISCUSS (grill), PLAN (planner, challenger) |
| **Refactor** | The request or SPEC says features stay unchanged and only quality improves | A senior engineer who has just joined a large, unfamiliar codebase. Understand the architecture and the data flow before judging anything; then name what is structurally wrong, duplicated, slow, or hard to maintain. Behavior is frozen: the tests that pass before must pass after, unchanged. | Architecture summary; problematic areas (structural issues, duplicated code, performance bottlenecks, maintainability risks); refactoring strategies; improved code | PATTERNS.md (the summary and the problem areas, cited `file:line`); PLAN.md tasks (one strategy each, behavior-preserving verify command); the quality-loop findings list | PLAN (pattern-mapper, planner), quality-loop, VERIFY (code-reviewer) |
| **Debug** | `/loop-spec:debug` | A senior engineer investigating a bug in production. Read the code carefully, reason step by step, find the root cause, and ship a fix that is robust, not a patch that hides the symptom. | What the code does; what the problem is; why it fails; edge cases; corrected code ready for production | BUG.md `## Fix` (root cause, the change, why it is sufficient, the edge cases the fix covers and the test that proves each) | debug (Step 3 FIX, Step 4 VERIFY) |
| **Performance** | The goal or a criterion names speed, memory, or scale; every VERIFY review checks for regressions | An engineer specializing in performance. Goals: speed, memory use, scalability. Find bottlenecks, inefficient logic, and unnecessary rendering; measure before and after. | Performance issues; optimization strategies; improved code | VERIFICATION.md `## Code review` performance findings (`perf:` lines, each with the input that grows and the measurement); ITERATE's goal criteria when the goal names performance | VERIFY (code-reviewer), ITERATE (iterate-judge), quality-loop |

## Rules that hold every stance

- **Cite, never recall.** A stance grounds in the code read on this run and in the
  evidence ledger (`skills/shared/grounding-protocol.md`), the same as every other phase.
  "A senior engineer would know" is not evidence.
- **Deliverables are sections, not adjectives.** "Scalable" is a claim; a named scaling
  input and the bound the design holds against it is a deliverable
  (`skills/shared/engineering-directives.md`, "Design for scale before code exists").
- **A stance never widens scope.** Refactor freezes behavior; debug fixes the mechanism
  and sweeps siblings (`skills/debug/SKILL.md`); performance changes what a measurement
  shows is slow. New scope is a SPEC decision (`skills/shared/no-deferral.md`).
- **The ladder still applies.** A stance says what to deliver, never how much code to
  write; `skills/shared/laziness-ladder.md` decides that.

## Where it binds

| Surface | File |
|---|---|
| SPEC Foundations round (greenfield) | `skills/spec/SKILL.md`, `skills/spec/references/interview-prompts.md`, `agents/spec-writer.md` |
| DISCUSS design grill | `skills/discuss/SKILL.md` |
| PLAN | `skills/plan/SKILL.md`, `agents/planner.md`, `agents/pattern-mapper.md`, `skills/shared/artifact-templates/PLAN.md.template` |
| VERIFY | `agents/code-reviewer.md`, `skills/shared/artifact-templates/VERIFICATION.md.template` |
| ITERATE | `agents/iterate-judge.md` |
| Debug loop | `skills/debug/SKILL.md` |
| Pre-commit review | `skills/quality-loop/SKILL.md` |
| Index of every directive | `skills/shared/engineering-directives.md` |
