---
name: status
description: Show loop-spec run status and aggregate telemetry stats. Default lists every feature (phase, iterations, last event, warnings, result, PR); "stats" aggregates across runs — convergence rate, gate rounds, iterate gap histogram, dispatch counts by model/role/rung, loop-fleet cost. Read-only consumer of feature.json + events.jsonl + result.json.
argument-hint: '[status [<slug>] | stats] [--json]'
---

# Status Skill

Invoked as `/loop-spec:status [subcommand] [args]`.

Read-only. All mechanics live in `lib/status.sh`; this skill is the thin command
surface. It never mutates state, never dispatches agents, and works mid-cycle
(the telemetry writers are append-only, so reading is always safe).

## Subcommands

Run from the project root (the directory containing `.loop-spec/`):

```bash
# Per-feature status table (default; optional slug filter)
bash "${CLAUDE_SKILL_DIR}/../../lib/status.sh" status
bash "${CLAUDE_SKILL_DIR}/../../lib/status.sh" status my-feature

# Aggregate stats across all runs
bash "${CLAUDE_SKILL_DIR}/../../lib/status.sh" stats

# Machine-readable variants
bash "${CLAUDE_SKILL_DIR}/../../lib/status.sh" --json status
bash "${CLAUDE_SKILL_DIR}/../../lib/status.sh" --json stats
```

Pass the user's arguments through verbatim (`status`, `stats`, a slug, `--json`).
Print the script output as-is — do not paraphrase numbers. If the user asked a
question about the output (e.g. "why is this stuck?"), answer AFTER showing the
raw output, citing rows/fields.

## What the fields mean

- **status table**: one row per feature under `.loop-spec/features/`. `ITER` =
  `iterate.used/maxIterations`. `LAST EVENT` = tail of `events.jsonl` with age.
  `RESULT` = `result.json.status` (`-` = still in flight). `PR` = merged/checkpoint
  PR URL when one exists.
- **stats**: `convergence` counts finished runs with `result.json.converged ==
  true`. `gate rounds` and `iterate gaps` histogram the `gate_round` /
  `iterate_verdict` events (gap = which phase the judge rewound to — a high
  `plan` count means decomposition is the weak link). `dispatches` counts
  `dispatch` events by model/role/rung (`skills/shared/dispatch-events.md`).
  `loop-fleet cost` sums the agent CLI's reported cost (`claude -p`
  `total_cost_usd`, or pi usage cost when reported) from
  `.loop/fleet-result.json` when the loop-fleet rung ran; `n/a` = fleet never
  ran or the CLI did not report cost (unknown, not free).

## Workspace note

In workspace mode run from the workspace root (state is rooted there). The
`--root` flag can point anywhere explicitly: `--root path/to/.loop-spec`.
