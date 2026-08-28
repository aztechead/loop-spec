---
ambiguity_scores:
  goal_clarity: 0.90
  boundary_clarity: 0.90
  constraint_clarity: 0.85
  acceptance_clarity: 0.90
  ambiguity: 0.12
  rounds_completed: 0
  gate_passed: true
  unresolved_dimensions: []
---

# SPEC/PLAN wall-clock: skip gated critique, drop advocate

**Slug:** `spec-plan-speed`
**Created:** 2026-08-28
**Execution style:** auto

## Problem

SPEC and PLAN felt longest because of a serial Agent stack, not skill size. After a
gated SPEC.md, DISCUSS still spawned a spec-writer and a critique (and, on
escalation, an advocate debate) for the same artifact. PLAN paid opus to mine
PATTERNS.md and ran the challenger before cheap lints that often bounced the
planner anyway.

## Goals

- DISCUSS keeps the design grill. `execStyle: auto` still asks.
- Skip spec-writer when SPEC.md exists (lead Edits from the transcript).
- Skip spec-critique when a probe says the spec is already gated (and there is
  no security signal and this is not an ITERATE re-entry).
- Drop the advocate entirely. Critique is challenger-only. Disputed `[major]`
  stays on the fix-list.
- PLAN: feasibility + coverage + grounding before the challenger.
- PATTERNS.md from a one-shot pattern-mapper, not the opus planner.

## Non-goals

- Skipping the DISCUSS grill on a normal new feature.
- Skipping spec-critique on an ungated or security-signaled spec.
- Fire-and-forget pruning (racy with DISCUSS/EXECUTE).
- Enabling `LOOP_SPEC_PLAN_MULTI_ANGLE=1`.
- Deleting `agents/advocate.md` (schema / `validate-agents.sh` keep the role id).

<decisions>
- Decision: one probe (`lib/graph/probes/discuss-critique.sh`) selects the skip, shared by the skill and `graph/cycle.graph.json`. Rationale: a model must not pick a code path. Alternatives considered: overloading `short-path.sh` (rejected — that probe also skips DISCUSS itself and code-review).
- Decision: fail closed to `gate=run`. Rationale: missing SPEC or a failed security scan must not silently skip the critic.
- Decision: keep the advocate agent file, stop dispatching it. Rationale: resume schema still has `currentGate.advocateName`; installers pin the restricted-agent list.
- Decision: one-shot pattern-mapper rather than a 4th teammate. Rationale: portable with no-teams; DISCUSS prefetch already uses that shape.
</decisions>

## Boundaries (what NOT to do)

- Do not skip the grill because the SPEC gate passed.
- Do not spawn `advocate-1` or `loop-spec:advocate`.
- Do not `sleep` to join a background Agent.
- Do not AskUserQuestion as a wait.

### Good Enough

- [ ] `discuss-critique.sh` answers `gate=skip` on a gated spec and `gate=run` on iterate re-entry or a security signal
- [ ] DISCUSS and PLAN TeamCreate lists do not include `loop-spec:advocate`
- [ ] PLAN runs Step 4b and coverage before Step 3
- [ ] PATTERNS.md missing after cache/GSD dispatches `loop-spec:pattern-mapper`
- [ ] `tests/run-all.sh` stays green
