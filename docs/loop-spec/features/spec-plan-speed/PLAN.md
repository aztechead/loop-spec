# PLAN: SPEC/PLAN wall-clock shorteners

**Slug:** `spec-plan-speed`

## Approach

Deterministic probes and skill/graph agreement. No new runtime dependencies.

## Tasks

### task-001: skip gated spec critique

- **Files:** `lib/graph/probes/discuss-critique.sh`, `graph/cycle.graph.json`, `skills/discuss/SKILL.md`, `tests/lib/graph-probes.test.sh`
- **Steps:** Add the probe; wire `discuss.critique.gate`; skill runs the same probe and logs `discuss critique skipped (<reason>)`.
- **Verify:** `bash tests/lib/graph-probes.test.sh`

### task-002: drop advocate, keep challenger

- **Files:** `graph/critique.graph.json`, `skills/shared/critique-gate-protocol.md`, `skills/shared/tier-matrix.md`, DISCUSS/PLAN skills, fallback/implicit-team docs
- **Steps:** Remove debate nodes; challenger-only protocol; disputed `[major]` stays; never TeamCreate advocate.
- **Verify:** `bash tests/spec-plan-speed-coverage.test.sh`

### task-003: PLAN lints-before-challenger and PATTERNS mapper

- **Files:** `skills/plan/SKILL.md`, `skills/plan/references/patterns-bootstrap.md`
- **Steps:** After planner, run 4b then 5.5 then critique. Missing PATTERNS.md → one-shot mapper, check-once prefetch join (no sleep).
- **Verify:** coverage needles in `tests/spec-plan-speed-coverage.test.sh`

## Spec coverage

- `discuss-critique.sh` skip/run matrix → task-001
- no `loop-spec:advocate` spawn → task-002
- lints before critique; pattern-mapper for PATTERNS → task-003
- `tests/run-all.sh` green → all three
