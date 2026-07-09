# Dispatch telemetry contract

Every phase that launches an agent — teammate spawn (explicit or implicit team
mode), one-shot subagent, loop-fleet worker, or workflow-rung task — emits ONE
`dispatch` event per agent launched, so `events.jsonl` carries a complete record
of who ran on which model. This feeds `/loop-spec:status --stats` (dispatch
counts by model/role) and gives headless callers per-run dispatch accounting.

## Rule

Immediately before (or right after) each spawn, run:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit ".loop-spec/features/${slug}" dispatch \
  --phase "<phase>" \
  --data '{"role":"<agent role, e.g. challenger>","model":"<resolved alias, e.g. opus>","rung":"<team|subagent|loop-fleet|workflow>"}' || true
```

- `role` = the agent role name (`advocate`, `challenger`, `implementer`,
  `verifier`, `code-reviewer`, `iterate-judge`, `mapper`, `pattern-mapper`, ...).
- `model` = the resolved model alias actually used (from `feature.models.<role>`
  or the task's `modelTier` resolution) — never re-derived from the matrix.
- `rung` = how it was launched: `team` (persistent teammate), `subagent`
  (one-shot Agent call), `loop-fleet` (headless loop worker), `workflow`
  (Workflow DAG task).

## Boundaries

- One event per agent LAUNCHED. `SendMessage` rework to an already-spawned
  teammate is NOT a new dispatch — do not re-emit on critique-gate rounds.
- Loop-fleet: the lead emits one `dispatch` per compiled task when launching the
  fleet (`rung: "loop-fleet"`); worker iterations are not separate dispatches.
- Non-fatal always: the trailing `|| true` is mandatory (observability never
  aborts a cycle — same contract as `lib/events.sh` itself).
- Debug/standalone skills without a feature dir skip this contract (no
  `events.jsonl` target exists).
