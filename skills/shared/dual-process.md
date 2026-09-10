# Dual-process effort

`lib/effort-probe.sh` selects effort for each node. `lib/conflict-monitor.sh` raises effort after conflicts or failures.
Effort changes node instructions, never the model.
Each node uses one effort mode. Do not run System 1 and System 2 as sequential passes.
Both modes must pass the same gates. Higher effort does not guarantee correctness.

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

Raise effort after a contradiction or failure. Never raise it based on elapsed time or cost.

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

## Authority bound

Effort controls one thing today: the guidance the cycle lead applies to the
node named by the step descriptor.

- `system1`: work directly and do not add optional review rounds.
- `system2`: state assumptions and check their evidence before committing to
  the node result.

Every declared gate, route, and loop ceiling stays unchanged. A gate may be
skipped only when its own deterministic licensing probe says so; effort does
not license the skip. Model routing is also independent. Claude Code and
OpenCode can therefore execute the same effort decision on any inherited model.

The descriptor, checkpoint, and trace record the final effort and its reason.

## Binding to the graph

`graph/cycle.graph.json` declares a default `effort` on every node (task-011);
the runtime mode is the probe answer, or the operator override where set.
`lib/graph/validate.sh` rejects a `system1` default on any node that
authorizes delivery — the effort probe independently forces those nodes to
`system2` at runtime (`delivery-authorizing-node`).
