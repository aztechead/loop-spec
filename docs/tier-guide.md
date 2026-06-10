# Tier Guide

Two independent choices control how super-spec runs.

---

## Tier  -  controls gate behavior

### quality

**Use when:** core architecture changes, security-critical code, public APIs, anything hard to revert.

- Spec + plan critique gates run (advocate + challenger both fire)
- Code-review blocks on Critical AND Important
- Conversational clarification: up to 5 rounds (AUTO)
- Retry budgets: generous

### balanced (default)

**Use when:** typical feature work, most day-to-day tasks.

- Spec + plan critique gates run
- Code-review blocks on Critical AND Important
- Conversational clarification: up to 5 rounds (AUTO)

### quick

**Use when:** prototypes, throwaway scripts, time-pressure shipping, well-understood tweaks.

- **Critique gate SKIPPED** entirely (saves ~12-20 model calls)
- Code-review blocks on Critical only
- Conversational clarification: up to 3 rounds (AUTO)
- Spec-compliance + acceptance gates still run

---

## EXECUTE concurrency ladder  -  scales to the work, not the tier

EXECUTE does not pick its dispatch mechanism from the tier. It measures the structural
width `W` of the task DAG and uses the lightest mechanism that fits: a single subagent
for a serial plan (`W == 1`), batched one-shot subagent waves for modest parallelism
(`2 <= W < t_team`), a self-claim agent team for high parallelism (`t_team <= W < t_wf`),
and the Workflow DAG only for very wide plans (`W >= t_wf`) when you opt in with
`SUPER_SPEC_EXECUTE_WORKFLOW=1`. Tier only tunes the width thresholds and the per-wave
cap:

| Tier | t_team (team rung at W >=) | t_wf (workflow rung at W >=) | maxParallelImplementers |
|------|---|---|---|
| quality | 3 | 6 | 4 |
| balanced | 3 | 6 | 3 |
| quick | 4 | 8 | 2 |

So a one-task or fully-serial feature never pays for a team or a workflow, and Workflow
never runs unless you explicitly ask for it. See `skills/shared/tier-matrix.md` for the
authoritative rule.

---

## Model selection  -  fixed per role (no preset)

There is no model preset. Every feature uses the same fixed role -> model map. Tier
controls gate behavior, retries, and fan-out width only; it never changes which model
a role runs on. See `skills/shared/model-matrix.md` for the authoritative map.

| Role | Model |
|------|-------|
| spec-writer, planner | Opus |
| advocate, challenger | Opus |
| spec-compliance-reviewer (the Ralph loop) | Opus |
| implementer | Sonnet |
| code-reviewer | Sonnet |
| verifier | Sonnet |
| mapper-*, pattern-mapper | Sonnet |

**Rationale:** Opus runs the reasoning-heavy roles (spec/plan authoring, the SPEC/PLAN
critique gate, and the per-task spec-compliance gate). Sonnet runs the high-throughput
roles (implementation, code review, acceptance verification, codebase mapping). Haiku is
no longer assigned to any role.

---

## Tier recommendations

| Goal | Tier | Notes |
|------|------|-------|
| Production feature, critical path | quality | Full gates, Critical + Important block |
| Architecture change, max scrutiny | quality | Full critique + Important blocks |
| Standard feature, good safety | balanced | Default  -  usually the right call |
| Prototype, iterate fast | quick | Critique gate skipped, Critical-only block |

---

## Choosing tier

| Question | quality | balanced | quick |
|----------|---------|----------|-------|
| Irreversible change? | yes | maybe | no |
| Spec well-understood? | doesn't matter | doesn't matter | yes |
| Experimental / throwaway? | no | no | yes |
| Time pressure? | no | ok | yes |
| Production-bound? | yes | yes | no |
