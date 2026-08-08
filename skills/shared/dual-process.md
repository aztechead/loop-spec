# Dual-process effort

Per-node effort replaces the static role-to-model table. Two deterministic
probes decide how hard to think and when deliberation wakes up. Neither probe
reads or writes `feature.json` directly.

## `lib/effort-probe.sh`

Answers `mode=system1|system2 reason=<text>` on one stdout line from
deterministic inputs only: node kind, `lib/security-signal.sh` result, measured
DAG width, changed-file count, task count, prior attempt count, and whether the
node authorizes delivery.

- Any unresolvable input yields `system2` (fail safe toward deliberation).
- `LOOP_SPEC_EFFORT`, `LOOP_SPEC_EFFORT_PHASE`, and `LOOP_SPEC_EFFORT_NODE`
  outrank the computed answer in both directions; more-specific forms win.
- Enforced by `tests/lib/effort-probe.test.sh`.

## `lib/conflict-monitor.sh`

Answers `conflict=yes|no reason=<text>` from four signals only: failing test
command, `[major]` gate finding, contradictory agent outputs on one node, and
N consecutive identical failures (N defaults to
`LOOP_SPEC_STRATEGY_ROTATION_THRESHOLD`, same as
`hooks/team/strategy-rotation.sh`).

Forward escalation only: a `conflict=yes` raises the node's *next attempt* to
`system2` and is written to the trace. It never rewinds, never replays a
checkpoint, and never blocks. Enforced by `tests/lib/conflict-monitor.test.sh`.

## System 1 authority bound

System 1 may control:

1. **Model alias** — throughput column in `skills/shared/model-matrix.md`
2. **Reasoning depth** — how many rounds a bounded loop may run
3. **Probe-licensed gate skips only** — today, PLAN's structural fast-path
   (at most 2 tasks and 3 files, no security signal, measured from the actual
   plan; see `skills/shared/tier-matrix.md`)

System 1 may **never** skip a gate on a judgment. Unknown probe inputs resolve
to `system2`. Both modes remain subject to the gates that check them — more
effort is not a correctness oracle.

## Binding

`graph/cycle.graph.json` gives every node a default `effort`. Runtime mode is
the probe answer (or override). Delivery-authorizing nodes must not declare a
`system1` default — `lib/graph/validate.sh` rejects that shape.
