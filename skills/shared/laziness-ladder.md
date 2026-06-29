# Laziness ladder (ponytail) — canonical prompt directive

Single source of truth for the ponytail simplicity directive that every **code-producing
phase dispatch** must carry, so the discipline is applied *every time* — not only on the
main thread (where `hooks/team/simplicity-inject.sh` injects it at SessionStart) but inside
each dispatched implementer/planner/reviewer, which a SessionStart hook does NOT reach.

Relevant phases (per `skills/simplicity/SKILL.md` "Relationship to the cycle"):
- **PLAN / planner** — `agents/planner.md` (ladder baked in; shapes tasks).
- **EXECUTE / implementer** — every rung: team (`agents/implementer.md`), subagent
  (`skills/shared/execute-subagent.md`), loop-fleet (`lib/plan-to-loop.sh`).
- **VERIFY / code-reviewer** — `agents/code-reviewer.md` over-engineering pass.

The directive realizes `skills/simplicity/SKILL.md`; that skill is the full reference. Keep
the canonical compact text below in sync with the skill. The session-level copy lives in
`hooks/team/simplicity-inject.sh`.

## Canonical compact directive (inline this verbatim into dispatch prompts)

> SIMPLICITY (ponytail laziness ladder — on by default). Write the shortest solution that
> actually works; the best code is the code never written. BEFORE writing code, stop at the
> first rung that holds: (1) does it need to exist at all? speculative = skip it (YAGNI);
> (2) already in this codebase? reuse the existing helper/util/type/pattern — do not
> re-implement it (use the graphify graph to find it); (3) stdlib does it? use it; (4) native
> platform feature covers it? use it; (5) an already-installed dependency solves it? use it,
> never add a new one for what a few lines do; (6) can it be one line? one line; (7) only
> then, the minimum code that works. The ladder runs AFTER you understand the problem, never
> instead of it. Bug fix = root cause, not symptom (fix the shared function once). NEVER cut
> input validation at trust boundaries, error handling that prevents data loss, security,
> accessibility, or anything the spec explicitly requires. Non-trivial logic leaves ONE
> runnable check behind. Mark deliberate shortcuts with a `simplicity:` comment naming the
> ceiling and upgrade path.
