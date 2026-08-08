# Dual-process effort

Per-node effort selection: two deterministic probes decide, node by node, how
hard to think (`lib/effort-probe.sh`) and when deliberation wakes up
(`lib/conflict-monitor.sh`). This is the canonical contract; the per-mode model
columns live in `skills/shared/model-matrix.md`.

Two misreadings this design must not encode: the modes are not sequential (there
is no System 1 pass followed by a System 2 pass — the probe picks an effort mode
for a node, not a stage the run passes through), and `system2` is not a
correctness oracle (both modes stay subject to every gate that checks them;
escalation buys effort, not a guarantee).

## The effort probe — `lib/effort-probe.sh`

Answers, per node, how hard to think.

**Output contract:** exactly one stdout line, `mode=(system1|system2)
reason=<text>`, exit 0 on every well-formed invocation. Enforced by
`tests/lib/effort-probe.test.sh`.

**Inputs are deterministic and enumerated** — node kind, the
`lib/security-signal.sh` result, measured DAG width, changed-file count, task
count, prior attempt count for the node, and whether the node authorizes
delivery. No model judgment participates.

**Unknown resolves to system2.** Any input that cannot be resolved yields
`mode=system2` with a reason naming the unresolved input. The probe fails safe
toward deliberation, never toward speed.

**Operator override outranks the probe, in both directions.** Per the standing
house rule (an explicit operator override outranks a probe):

```
LOOP_SPEC_EFFORT_NODE > LOOP_SPEC_EFFORT_PHASE > LOOP_SPEC_EFFORT
```

More-specific forms win; the reason field names the override as the cause.

## The conflict monitor — `lib/conflict-monitor.sh`

Answers when deliberation wakes up: System 2 is activated when an event violates
the model of the world System 1 maintains, so the monitor keys on contradiction
and failure, never on elapsed time or cost.

**Output contract:** exactly one stdout line, `conflict=(yes|no) reason=<text>`,
exit 0 on every well-formed invocation. Enforced by
`tests/lib/conflict-monitor.test.sh`.

**Four deterministic signals only:** a failing test command, a `[major]` gate
finding, contradictory outputs from two agents on the same node, and N
consecutive identical failures (N from `LOOP_SPEC_STRATEGY_ROTATION_THRESHOLD`,
default 2, matching `hooks/team/strategy-rotation.sh`).

**Forward escalation, never rewind.** A `conflict=yes` raises the affected
node's *next attempt* to `system2` and is written to the trace. The monitor
never rewinds, never replays from a checkpoint, and never blocks on its own —
the run always moves forward at higher effort.

## System 1 authority bound

`system1` controls exactly three things:

1. **Model alias** — the role's `system1` column in
   `skills/shared/model-matrix.md` instead of its `system2` column.
2. **Reasoning depth** — how many rounds a bounded loop is allowed.
3. **Gate presence, probe-licensed skips only** — `system1` may skip only a gate
   that a probe already licenses skipping. Exactly one such skip exists today:
   **PLAN's structural fast-path** (at most `fastPathMaxTasks`/`fastPathMaxFiles`
   — defaults 2 tasks, 3 files — and no `lib/security-signal.sh` match, measured
   from the actual plan; see `skills/shared/tier-matrix.md`). No other gate may
   be skipped by effort.

**System 1 may never skip a gate on a judgment.** A skip must trace to a
deterministic probe answer, per CLAUDE.md "Probes, not judgments". When in
doubt there is no doubt: unknown probe inputs already resolve to `system2`.

## Binding to the graph

`graph/cycle.graph.json` declares a default `effort` on every node (task-011);
the runtime mode is the probe answer, or the operator override where set.
`lib/graph/validate.sh` rejects a `gate` node marked skippable without a
licensing probe path, and rejects a `system1` default on any node that
authorizes delivery — the effort probe independently forces those nodes to
`system2` at runtime (`delivery-authorizing-node`).
