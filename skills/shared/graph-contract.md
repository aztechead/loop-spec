# Graph contract

Canonical vocabulary for loop-spec workflow graphs. Declared data under `graph/`
is executed by `lib/graph/run.sh`; it is never a derived map of the codebase.
Every rule below names its enforcer.

## Node kinds

**agent.** Dispatches a role through the harness (a skill body or
`loop-spec:{role}` subagent). The engine selects the effort mode and model; the
node body performs craft. Enforced by `graph/schema.json` (`definitions.node`)
and dispatched by `lib/graph/run.sh`.

**function.** Runs a deterministic `lib/` script. No model judgment selects a
branch inside the body. Enforced by schema kind enum; bodies are ordinary
scripts under `lib/`.

**gate.** Runs a probe and admits or blocks. A gate may declare `skippable`
only by naming the licensing probe path. Enforced by `lib/graph/validate.sh`
(skippable-without-probe rejection) and exercised in
`tests/lib/graph-validate.test.sh`.

**subgraph.** Nests another graph file (for example the critique protocol).
Referenced via `graph` path; the nested file must itself pass
`lib/graph/validate.sh`.

**human.** Interrupts and waits for a person. The engine checkpoints, emits a
pause record, and stops; resume continues at this node. Enforced by engine
pause semantics in `lib/graph/run.sh` and the ledger in
`lib/graph/checkpoint.sh`.

## Edge kinds

**chain.** Unconditional successor. Must not form a cycle with other acyclic
kinds. Enforced by the Kahn DAG check in `lib/graph/validate.sh`.

**route.** Conditional successor. `condition` is always
`{probe, expects}` — never prose. The probe path must name an executable file
in the tree. Enforced by `lib/graph/validate.sh` (shape, existence,
executable bit) and closed by `graph/schema.json`
`definitions.routeCondition.additionalProperties: false`.

**fanout.** One-to-many dispatch (EXECUTE task waves). Paired with `fanin`.
Width selects the rung via `lib/execute-rung.sh`; it never removes nodes.
Enforced by graph declaration plus `tests/graph-conformance.test.sh`.

**fanin.** Many-to-one join; requires a `join` rule. Enforced by
`lib/graph/validate.sh`.

**loop.** Bounded repetition with numeric `ceiling` and `strategy` of
`unroll` or `contain`. The only legal form of iteration — `chain` / `route` /
`fanout` / `fanin` must remain a DAG, with rewind routes permitted only when
the source already declares a loop ceiling. Enforced by
`lib/graph/validate.sh` and `graph/schema.json` allOf on `kind == loop`.

## Route-condition rule

A route condition is a probe path and an expected value, never free text.
`lib/graph/validate.sh` rejects prose conditions with a `FLAG` line and exit 1.
The engine evaluates the probe and compares stdout to `expects` before taking
the edge (`lib/graph/run.sh`).

## State declaration rule

Every node declares `reads[]` and `writes[]` from the schema state key space.
`lib/graph/state.sh` rejects undeclared writes and unsatisfied reads;
`lib/graph/validate.sh` rejects unknown keys and reads that no node writes
(unless seeded by `lib/feature-init.sh`). Writes still route through
`lib/feature-write.sh`.

## Harness neutrality

Nothing under `lib/graph/` branches on the harness. Node *bodies* may branch
through `lib/harness.sh`. Pinned by `tests/pi-harness-coverage.test.sh` and
`tests/opencode-harness-coverage.test.sh` (task-022).

## Effort

Every node declares a default `effort` of `system1` or `system2`. Runtime mode
comes from `lib/effort-probe.sh` (operator override wins). Delivery-authorizing
nodes may not default to `system1` — enforced by `lib/graph/validate.sh`.
Canonical effort contract: `skills/shared/dual-process.md`.
