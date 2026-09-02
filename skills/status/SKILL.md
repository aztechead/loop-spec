---
name: status
description: Use when the user says "status", "what's running", "stats", "metrics", or "trust level". Read-only over feature.json, events.jsonl, result.json, and the metrics contract. Do not use this to start, pause, or deliver a feature.
argument-hint: '[status [<slug>] | stats | metrics | trust] [--json]'
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

# Persisted phase timing across committed run digests (seconds per phase attempt)
bash "${CLAUDE_SKILL_DIR}/../../lib/status.sh" metrics

# Earned-autonomy level with the evidence that produced it (D1/D2)
bash "${CLAUDE_SKILL_DIR}/../../lib/trust.sh" level

# Machine-readable variants
bash "${CLAUDE_SKILL_DIR}/../../lib/status.sh" --json status
bash "${CLAUDE_SKILL_DIR}/../../lib/status.sh" --json stats
bash "${CLAUDE_SKILL_DIR}/../../lib/status.sh" metrics
bash "${CLAUDE_SKILL_DIR}/../../lib/trust.sh" level --json
```

After the default table (and always for `trust`), check for sentinel items a
human owes a decision on — never let them rot silently:

```bash
Q="${CLAUDE_PROJECT_DIR:-.}/.loop-spec/sentinel-queue.json"
[[ -f "$Q" ]] && jq -r '.needsHuman[]? | "needs-human: \(.id // "?") [\(.source // "?")] \(.reason // "?") — \(.title // "")"' "$Q"
```

Pass the user's arguments through verbatim (`status`, `stats`, `metrics`, a slug, `--json`).
Print the script output as-is — do not paraphrase numbers. If the user asked a
question about the output (e.g. "why is this stuck?"), answer AFTER showing the
raw output, citing rows/fields.

## What the fields mean

- **status table**: one row per feature under `.loop-spec/features/`. `ITER` =
  `iterate.used/maxIterations`. `LAST EVENT` = tail of `events.jsonl` with age.
  `RESULT` = `result.json.status` (`-` = still in flight). `PR` = merged/checkpoint
  PR URL when one exists.
- **trust**: the level (L0-L3) is COMPUTED from the committed metrics
  contract, fail-closed on every missing signal. The evidence lines state
  each input against its threshold — the distance to the next level is read
  straight off them (e.g. `consecutiveConverged: 3 (L1 needs >= 5)` means two
  more converged cycles). L1 unlocks trust-governed sentinel batches
  (`lib/trust.sh authorize`); nothing merges without a human at any level in
  this release.
- **stats**: `convergence` counts finished runs with `result.json.converged ==
  true`. `gate rounds` and `iterate gaps` histogram the `gate_round` /
  `iterate_verdict` events (gap = which phase the judge rewound to — a high
  `plan` count means decomposition is the weak link). `dispatches` counts
  `dispatch` events by model/role/rung (`skills/shared/dispatch.md`).
  `loop-fleet cost` sums the agent CLI's reported cost (`claude -p`
  `total_cost_usd`, or harness usage cost when reported) from
  `.loop/fleet-result.json` when the loop-fleet rung ran; `n/a` = fleet never
  ran or the CLI did not report cost (unknown, not free). `phase timing` is the
  live event aggregate, so it includes current local runs.
- **metrics**: committed digests retain `phaseTimings` by phase. `attempts` counts
  completed phase attempts, `totalSeconds` is their sum, `avgSeconds` is per attempt,
  and `maxSeconds` reveals the slowest attempt. Missing timing means an older digest,
  not a zero-cost phase.

## Workspace note

In workspace mode run from the workspace root (state is rooted there). The
`--root` flag can point anywhere explicitly: `--root path/to/.loop-spec`.
