# No-teams fallback (reference)

Applies when `.loop-spec/runtime.json.teamsAvailable == false`. This is set
either by the cycle Step 2 env probe (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS != 1`)
**or** by the guarded-team-op contract (cycle Step 2): when the env var claimed teams
were available but the first `TeamCreate` throws `No such tool available`, the phase flips
`teamsAvailable=false` and re-runs itself on this fallback instead of hard-erroring. Either
way, every phase still runs and produces the same artifacts and gates; only the dispatch
mechanism changes.
Teams are an accelerator (persistent context across critique rounds), not a
prerequisite — a missing experimental flag must never make the plugin throw.

**pi harness (one level further down):** this table substitutes team primitives
with one-shot `Agent` calls — but under pi (`runtime.json.harness == "pi"`) the
`Agent` tool does not exist either. Apply this table first, then the **inline
dispatch rule** in `skills/shared/pi-harness.md` on top: every one-shot `Agent`
call below becomes the lead performing that same brief itself, sequentially,
producing identical artifacts. EXECUTE is unaffected by both layers — its ladder
already selects the loop-fleet or inline rung on that harness.

## Substitution table

| Team primitive | Fallback |
|---|---|
| `TeamCreate` (phase roster) | none — no team is created; `feature.json.currentTeamName` stays `null` |
| Teammate spawn prompt | one-shot `Agent` call with the SAME agent type, model, and prompt template |
| `SendMessage` rework/revision round | fresh `Agent` call to the same agent type with the prior round's summary inlined in the prompt (read it from `gate-logs/`) |
| `SendMessage` teammate-to-teammate critique | sequential `Agent` calls; the lead carries each output into the next prompt |
| `TeammateIdle` wake / idle protocol | not needed — one-shot calls are synchronous; the lead simply proceeds when the call returns |
| `TeamDelete` | none |

## Phase notes

- **DISCUSS / PLAN critique gates:** the default single-critic pass is ONE
  one-shot `challenger` Agent call (solo-critic brief from
  `skills/shared/team-prompts/critic.md`); each delta re-verify is a fresh
  one-shot `challenger` call with the fix-list + diff inlined. An escalated
  debate runs each round as `challenger` then `advocate` one-shot Agent calls
  (challenger output feeds the advocate prompt). Round transcripts still land
  in `.loop-spec/features/{slug}/gate-logs/` and the ladder/adjudication rules
  (`skills/shared/tier-matrix.md`) are unchanged. What is lost without teams is
  in-context memory between rounds; compensate by inlining
  `prior_round_summaries` (already persisted to gate-logs) into each new spawn
  prompt — the same mechanism the team path uses after an author revision.
- **EXECUTE:** does not use this table — its ladder already selects the
  loop-fleet rung (`skills/shared/execute-loop-fleet.md`) when teams are
  unavailable and the `claude` CLI exists, else the subagent rung
  (`skills/shared/execute-subagent.md`).
- **VERIFY:** verifier and code-reviewer become sequential one-shot Agent
  calls; the acceptance gate and code-review HARD-GATE semantics are unchanged.
- **Resume / orphan detection (cycle Step 1):** the explicit-mode-only `TaskList({team: ...})`
  liveness probe is meaningless without teams. When `teamsAvailable == false`
  and a candidate `feature.json` carries a non-null `currentTeamName`, treat the
  team as gone: clear `currentTeamName` and add the feature to the resumable
  list (no "needs cleanup" entry).

## What does NOT change

Artifacts, gates, worktree layout, feature.json
schema, phase routing. A feature started with teams can resume without them and
vice versa.
