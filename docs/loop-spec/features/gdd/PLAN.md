# GDD — graph-driven development - Implementation Plan

**Spec:** `docs/loop-spec/features/gdd/SPEC.md`
**Created:** 2026-08-08
**Target release:** 3.0.0

## Architecture overview

Six stages, strictly ordered, each independently shippable and each leaving
`tests/run-all.sh` green.

**A. Declare** (task-001 … task-005). A `graph/` directory holds the schema and the cycle
graph. `lib/graph/validate.sh` enforces the schema, and `tests/graph-conformance.test.sh`
asserts the *current prose skills* match the declared topology. No engine exists yet and
nothing behaves differently — this stage exists to prove the declaration is correct before
anything executes it.

**B. Type the state** (task-006 … task-007). `lib/graph/state.sh` layers `reads[]`/`writes[]`
enforcement over `feature.json`. Writes still route through `lib/feature-write.sh`; the
committed resume contract is unchanged.

**C. Dual process** (task-008 … task-011). `lib/effort-probe.sh` and
`lib/conflict-monitor.sh` land as ordinary probes with unit tests, then bind to node
effort. Today's static role-to-model table becomes the `system2` column, so nothing gets
less capable by default.

**D. Engine and cutover** (task-012 … task-016). Checkpoint, trace, engine; then
`skills/cycle/SKILL.md` Step 6 hands sequencing to the engine; then the prose routing the
graph now owns is deleted and the conformance test is repurposed as the schema validator.

**E. Distribution** (task-017 … task-021). The handoff port contract, its dispatcher, one
reference adapter, an adapter conformance suite any implementation can be run against, and
the node-instance bundle that makes a foreign claimant possible.

**F. Ship** (task-022 … task-025). Harness coverage pins, the architecture doc, the roadmap
restructure, and the 3.0.0 version bump.

Layering, bottom-up: `graph/*.json` (data) → `lib/graph/*.sh` (mechanism) → `lib/*-probe.sh`
and `lib/conflict-monitor.sh` (decisions) → `skills/**` (bodies). Nothing in `lib/graph/`
may branch on the harness; only node bodies may, through `lib/harness.sh`.

## Assumptions

- `graph/` is a new top-level directory, sibling to `lib/` and `skills/`. Graph JSON is
  data only — never executable, never templated at runtime.
- `lib/graph/validate.sh` is a pure validator: reads a graph file, writes `FLAG` lines for
  each defect and one final answer line, exits 0 clean / 1 on any flag / 2 on bad
  invocation. It mirrors the established `lib/artifact-lint.sh` output contract exactly.
- `lib/effort-probe.sh` and `lib/conflict-monitor.sh` follow the probe contract from
  `CLAUDE.md`: one line carrying the answer and the reason, fail-safe on unknown, operator
  override wins. Neither reads or writes `feature.json` directly.
- `lib/graph/state.sh` never writes `feature.json` itself. It validates a proposed write
  against the node's declaration and then delegates to `lib/feature-write.sh`.
- `lib/graph/trace.sh` wraps `lib/events.sh` and inherits its never-abort contract: every
  internal failure prints one warning to stderr and exits 0.
- `lib/graph/run.sh` supports `--dry-run`, which traverses the graph and emits the node
  and edge sequence without dispatching any node body. Every engine unit test uses
  `--dry-run`; only `tests/e2e/` executes bodies.
- `lib/graph/port-local.sh` is the reference adapter and stores instances under the
  feature directory. It is a conformance target, not a recommended production substrate.
- `tests/lib/graph-port-contract.test.sh` takes an adapter path as `$1`, defaulting to
  `lib/graph/port-local.sh`, so an integrator runs it against their own adapter unchanged.
- `lib/execute-rung.sh` keeps its current signature and adds one rung value. Existing
  callers and its unit test continue to pass without modification.
- The seven phase skills keep their names, inputs, and artifact outputs. Only their
  routing prose is removed.
- `tests/e2e/graph-handoff.test.sh` is offline and hermetic (a subshell with a scrubbed
  environment, no network), so it can live in the default suite rather than the opt-in
  live e2e matrix.

## Decisions carried

Each SPEC decision, verbatim, against the task that implements it. A task cannot be
called done while its decision is unimplemented.

| Decision | Implemented by |
|---|---|
| the workflow graph is declared data that the engine executes, never a derived map of the codebase. | task-001, task-023 |
| full cutover — once a node's control flow lands in the graph, the prose routing it replaces is deleted, with no opt-in flag and no prose fallback path. | task-016 |
| a conformance test precedes the engine as build order, not as a parallel regime, and is repurposed as the graph's own schema validator once the cutover lands. | task-004, task-016 |
| every route edge condition names a probe script and an expected value; prose conditions are rejected by the validator. | task-002 |
| the typed state channel is a declaration layer over `feature.json`, not a replacement for it, and every write still routes through `lib/feature-write.sh`. | task-006 |
| `lib/effort-probe.sh` emits its mode and reason on one line from deterministic inputs only, and resolves to `system2` whenever an input cannot be resolved. | task-008 |
| System 1 authority is bounded to model alias, reasoning depth, and skipping only those gates a probe already licenses skipping; it may never skip a gate on a judgment. | task-010, task-011 |
| `lib/conflict-monitor.sh` escalates forward by raising the affected node's next attempt to `system2`, and never rewinds or replays from a checkpoint. | task-009 |
| an explicit operator override outranks the effort probe in both directions. | task-008 |
| distribution ships as a port with exactly one reference adapter; the transport is the integrator's choice and the plugin never learns it. | task-017, task-018 |
| a handoff bundle is self-contained and content-addressed, and a returning claimant whose state hash does not match is rejected rather than reconciled. | task-020 |
| solo and multi-agent runs execute the same graph — width selects the rung and never removes a node. | task-003, task-020 |
| this feature is the 3.0 headline and supersedes the ROADMAP-3.0 pillar sequencing, with Pillars A-D re-expressed as graphs over the new substrate. | task-024 |
| the six named agentic workflow patterns are documented as subgraph shapes bound to the loop-spec construct that already realizes each one. | task-023 |

## File map

**Create — graph data**
- `graph/schema.json` — node kinds, edge kinds, state key space
- `graph/cycle.graph.json` — the seven-phase cycle declared
- `graph/critique.graph.json` — the critique-gate subgraph, reused by DISCUSS and PLAN

**Create — mechanism**
- `lib/graph/validate.sh` — schema and referential validator
- `lib/graph/state.sh` — typed state channel over `feature.json`
- `lib/graph/checkpoint.sh` — per-node checkpoint ledger
- `lib/graph/trace.sh` — node-stamped trace wrapper over `lib/events.sh`
- `lib/graph/run.sh` — the engine
- `lib/graph/port.sh` — handoff port dispatcher
- `lib/graph/port-local.sh` — reference adapter
- `lib/graph/handoff.sh` — node-instance bundle export and import

**Create — decisions**
- `lib/effort-probe.sh` — System 1 / System 2 per node
- `lib/conflict-monitor.sh` — deterministic conflict signal

**Create — contracts**
- `skills/shared/graph-contract.md` — the canonical node/edge/state contract
- `skills/shared/dual-process.md` — the canonical effort contract
- `skills/shared/handoff-port.md` — the six-operation port contract
- `docs/loop-spec/gdd.md` — architecture, pattern bindings, graphify rebuttal

**Create — tests**
- `tests/lib/graph-schema.test.sh`, `tests/lib/graph-validate.test.sh`,
  `tests/lib/graph-state.test.sh`, `tests/lib/graph-checkpoint.test.sh`,
  `tests/lib/graph-trace.test.sh`, `tests/lib/graph-run.test.sh`,
  `tests/lib/graph-port-contract.test.sh`, `tests/lib/effort-probe.test.sh`,
  `tests/lib/conflict-monitor.test.sh`, `tests/graph-conformance.test.sh`,
  `tests/graph-docs-coverage.test.sh`, `tests/e2e/graph-handoff.test.sh`

**Modify**
- `skills/cycle/SKILL.md` — Step 6 hands sequencing to the engine
- `skills/{spec,discuss,plan,execute,verify,iterate,deliver}/SKILL.md` — routing prose removed
- `skills/shared/model-matrix.md` — role table becomes the `system2` column
- `lib/execute-rung.sh` — one additional rung for foreign claimants
- `tests/pi-harness-coverage.test.sh`, `tests/opencode-harness-coverage.test.sh` — pin new couplings
- `tests/run-all.sh` — register the twelve new suites
- `docs/loop-spec/ROADMAP-3.0.md` — pillars re-expressed as graphs
- `README.md`, `CHANGELOG.md`, `package.json`, `.claude-plugin/plugin.json`,
  `.claude-plugin/marketplace.json` — 3.0.0

## Task DAG

| ID | Subject | BlockedBy | Files | Est scope |
|----|---------|-----------|-------|-----------|
| task-001 | graph schema: five node kinds, five edge kinds, state key space | - | graph/schema.json, tests/lib/graph-schema.test.sh | medium |
| task-002 | lib/graph/validate.sh with probe-condition enforcement | task-001 | lib/graph/validate.sh, tests/lib/graph-validate.test.sh | large |
| task-003 | declare the cycle and critique graphs | task-002 | graph/cycle.graph.json, graph/critique.graph.json | large |
| task-004 | conformance test: skills match the declared topology | task-003 | tests/graph-conformance.test.sh | large |
| task-005 | skills/shared/graph-contract.md | task-003 | skills/shared/graph-contract.md | medium |
| task-006 | lib/graph/state.sh typed channel over feature.json | task-001 | lib/graph/state.sh, tests/lib/graph-state.test.sh | large |
| task-007 | annotate reads/writes on every declared node | task-003, task-006 | graph/cycle.graph.json, graph/critique.graph.json | medium |
| task-008 | lib/effort-probe.sh | task-001 | lib/effort-probe.sh, tests/lib/effort-probe.test.sh | large |
| task-009 | lib/conflict-monitor.sh | - | lib/conflict-monitor.sh, tests/lib/conflict-monitor.test.sh | medium |
| task-010 | skills/shared/dual-process.md + model-matrix rework | task-008, task-009 | skills/shared/dual-process.md, skills/shared/model-matrix.md | medium |
| task-011 | bind effort to nodes and license gate skips | task-007, task-010 | graph/cycle.graph.json, lib/graph/validate.sh | medium |
| task-012 | lib/graph/checkpoint.sh node ledger | task-006 | lib/graph/checkpoint.sh, tests/lib/graph-checkpoint.test.sh | medium |
| task-013 | lib/graph/trace.sh node-stamped events | task-001 | lib/graph/trace.sh, tests/lib/graph-trace.test.sh | medium |
| task-014 | lib/graph/run.sh engine with dry-run and resume | task-011, task-012, task-013 | lib/graph/run.sh, tests/lib/graph-run.test.sh | large |
| task-015 | cycle Step 6 cutover to the engine | task-014 | skills/cycle/SKILL.md | large |
| task-016 | delete prose routing; repurpose conformance test | task-015, task-004 | skills/{spec,discuss,plan,execute,verify,iterate,deliver}/SKILL.md, tests/graph-conformance.test.sh | large |
| task-017 | skills/shared/handoff-port.md six-operation contract | task-005 | skills/shared/handoff-port.md | medium |
| task-018 | lib/graph/port.sh dispatcher + port-local.sh adapter | task-017 | lib/graph/port.sh, lib/graph/port-local.sh | large |
| task-019 | adapter conformance suite | task-018 | tests/lib/graph-port-contract.test.sh | large |
| task-020 | lib/graph/handoff.sh bundles + foreign-claimant rung | task-019, task-014 | lib/graph/handoff.sh, lib/execute-rung.sh | large |
| task-021 | hermetic cross-process handoff e2e | task-020 | tests/e2e/graph-handoff.test.sh | medium |
| task-022 | pi and opencode harness coverage pins | task-016, task-020 | tests/pi-harness-coverage.test.sh, tests/opencode-harness-coverage.test.sh | medium |
| task-023 | docs/loop-spec/gdd.md architecture and pattern bindings | task-016, task-020 | docs/loop-spec/gdd.md, tests/graph-docs-coverage.test.sh | large |
| task-024 | ROADMAP-3.0 restructure: pillars as graphs | task-023 | docs/loop-spec/ROADMAP-3.0.md | medium |
| task-025 | 3.0.0 bump, README, CHANGELOG, suite registration | task-021, task-022, task-024 | README.md, CHANGELOG.md, package.json, .claude-plugin/*.json, tests/run-all.sh | medium |

## Tasks

---

### task-001: graph schema — five node kinds, five edge kinds, state key space

**Goal:** Establish `graph/schema.json` as the single declaration of what a loop-spec graph
may contain. Node kinds are `agent`, `function`, `gate`, `subgraph`, `human`. Edge kinds are
`chain`, `route`, `fanout`, `fanin`, `loop`. A `route` edge's `condition` is an object with
`probe` (a repo-relative path) and `expects` (a string); no other condition form is
representable. The state key space enumerates every `feature.json` key a node may declare
in `reads[]` or `writes[]`.

**Files:**
- `graph/schema.json`
- `tests/lib/graph-schema.test.sh`

**read_first:**
- `skills/shared/feature-state-schema.md` (the schema v7 key list — the state key space must be a subset)
- `lib/artifact-lint.sh` lines 1-40 (the output and exit-code contract new validators mirror)
- `docs/loop-spec/features/gdd/SPEC.md` section "1. The graph vocabulary"

**Verify:** `jq -e '(.definitions.node.properties.kind.enum | sort) == ["agent","function","gate","human","subgraph"]' graph/schema.json` exits 0; `jq -e '(.definitions.edge.properties.kind.enum | sort) == ["chain","fanin","fanout","loop","route"]' graph/schema.json` exits 0; `bash tests/lib/graph-schema.test.sh` exits 0.

**Acceptance criteria:**
- [ ] `graph/schema.json` parses as JSON and declares exactly the five node kinds and five edge kinds named above.
- [ ] The schema's `route` condition definition requires both `probe` and `expects` and sets `additionalProperties: false`, so a prose or free-text condition cannot validate.
- [ ] The schema declares a `state` key space, and every key in it is present in the schema v7 listing in `skills/shared/feature-state-schema.md`.
- [ ] `tests/lib/graph-schema.test.sh` asserts the two enum sets, the closed condition shape, and that a graph declaring an unknown node kind fails validation.
- [ ] The schema file contains no executable content and no runtime templating.

---

### task-002: lib/graph/validate.sh with probe-condition enforcement

**Goal:** A pure validator over a graph file. It enforces the schema, then the referential
rules the schema cannot express: every `route` condition's `probe` must name an existing
executable file in the tree; every edge endpoint must name a declared node; every node must
be reachable from an entry node; every `loop` edge must carry a numeric ceiling; every
`fanin` must name a join rule. Output and exit codes mirror `lib/artifact-lint.sh` exactly —
one `FLAG <file>:<pointer>: <message>` per defect, then one answer line, exit 0 clean / 1 on
any flag / 2 on bad invocation.

**Files:**
- `lib/graph/validate.sh`
- `tests/lib/graph-validate.test.sh`

**read_first:**
- `lib/artifact-lint.sh` (the FLAG-then-answer output contract, mirrored here)
- `graph/schema.json` (written by task-001)
- `lib/security-signal.sh` (the one-line answer-plus-reason probe idiom)

**Verify:** `bash tests/lib/graph-validate.test.sh` exits 0; `bash lib/graph/validate.sh` with no argument exits 2.

**Acceptance criteria:**
- [ ] `lib/graph/validate.sh` exits 0 and prints one line matching `^graph-validate: ok` on a valid graph.
- [ ] It exits 1 and emits a `FLAG` line when a `route` edge's condition is a free-text string rather than a `{probe, expects}` object. This is the decision that every route edge condition names a probe script and an expected value.
- [ ] It exits 1 when a `route` condition's `probe` path does not exist in the tree or is not executable.
- [ ] It exits 1 for an edge whose `from` or `to` names an undeclared node, for a node unreachable from any entry node, for a `loop` edge with no numeric ceiling, and for a `fanin` with no join rule.
- [ ] It exits 2 on missing or unreadable arguments, and never exits 0 on an unreadable file (fail safe).
- [ ] `tests/lib/graph-validate.test.sh` covers one accepting case and one case per rejection rule above.

---

### task-003: declare the cycle and critique graphs

**Goal:** State today's topology as data, with no behavior change anywhere. `graph/cycle.graph.json`
declares SPEC through DELIVER as chained `agent` nodes; EXECUTE as a `fanout` over plan tasks
with a `fanin` merge queue; VERIFY's marker, tamper, and acceptance scans as `gate` nodes;
ITERATE's three gap classes as three `route` edges back to `execute`, `plan`, and `spec`;
DELIVER's CI-failure path as a route through EXECUTE; and the `step` / `interactive` style
pauses as `human` nodes. `graph/critique.graph.json` declares the critique-gate protocol once,
referenced as a `subgraph` from both DISCUSS and PLAN. The graph must express the property
that a solo run and a multi-agent run traverse the same nodes — width selects the rung, never
the node set.

**Files:**
- `graph/cycle.graph.json`
- `graph/critique.graph.json`

**read_first:**
- `skills/cycle/SKILL.md` Step 6 (the prose dispatch table this declares)
- `skills/iterate/SKILL.md` (the three gap classes and their rewind targets)
- `README.md` section "The cycle in detail" (phase, product, and gate table)
- `README.md` section "Critique gate protocol (escalated form)"

**Verify:** `bash lib/graph/validate.sh graph/cycle.graph.json` exits 0; `bash lib/graph/validate.sh graph/critique.graph.json` exits 0; `jq -e '[.nodes[] | select(.kind=="agent")] | length >= 7' graph/cycle.graph.json` exits 0; `jq -e '[.edges[] | select(.kind=="route" and .to=="spec")] | length >= 1' graph/cycle.graph.json` exits 0.

**Acceptance criteria:**
- [ ] `graph/cycle.graph.json` and `graph/critique.graph.json` both pass `lib/graph/validate.sh`.
- [ ] The cycle graph declares at least one node per phase: spec, discuss, plan, execute, verify, iterate, deliver.
- [ ] ITERATE's three gap classes appear as three distinct `route` edges targeting `execute`, `plan`, and `spec`, each with a `{probe, expects}` condition.
- [ ] EXECUTE appears as a `fanout` node with a matching `fanin` join, so the same declaration serves width 1 and width N.
- [ ] The critique protocol is declared once in `graph/critique.graph.json` and referenced by `subgraph` nodes from both discuss and plan — not duplicated.
- [ ] No skill file is modified by this task; the declaration is additive and behavior is unchanged.

---

### task-004: conformance test — skills match the declared topology

**Goal:** Prove the declaration is correct before anything executes it. The test extracts each
phase skill's asserted successors, rewind targets, and gate escalation triggers, and asserts
they agree with `graph/cycle.graph.json`. It carries its own negative case: a mutated in-memory
copy of the graph must be detected. This is build order, not a parallel regime — the test's job
is to make the later cutover mechanical, and task-016 repurposes it.

**Files:**
- `tests/graph-conformance.test.sh`

**read_first:**
- `graph/cycle.graph.json` (written by task-003)
- `skills/cycle/SKILL.md` Step 6
- `skills/execute/SKILL.md` section "Phase exit"
- `tests/run-all.sh` (the `run_suite` registration idiom)

**Verify:** `bash tests/graph-conformance.test.sh` exits 0 on the tree as shipped, and its embedded negative case asserts a mutated graph copy exits non-zero.

**Acceptance criteria:**
- [ ] `tests/graph-conformance.test.sh` exits 0 against the unmodified tree.
- [ ] It fails with a named, greppable message when a phase skill declares a successor that the graph does not.
- [ ] It fails when the graph declares a rewind target that no skill implements.
- [ ] It includes a self-check that mutates a copy of the graph in memory and asserts detection, so a vacuously-passing test cannot ship.
- [ ] It is registered in `tests/run-all.sh` via `run_suite` and passes as part of `bash tests/run-all.sh`.

---

### task-005: skills/shared/graph-contract.md

**Goal:** The canonical, human-readable contract for the graph vocabulary: the five node kinds
and what each one's body may do, the five edge kinds and their semantics, the route-condition
rule, the state declaration rule, and the invariant that the engine and everything under
`lib/graph/` must stay harness-neutral while node bodies branch through `lib/harness.sh`.

**Files:**
- `skills/shared/graph-contract.md`

**read_first:**
- `graph/schema.json`, `graph/cycle.graph.json`
- `skills/shared/design-for-change.md` (the seams-not-speculation framing this doc must match)
- `skills/shared/feature-state-schema.md` (the writing-rules section, mirrored for state declarations)

**Verify:** `bash tests/graph-docs-coverage.test.sh` exits 0 once task-023 lands; until then, `test -f skills/shared/graph-contract.md` and `bash lib/graph/validate.sh graph/cycle.graph.json` exits 0.

**Acceptance criteria:**
- [ ] `skills/shared/graph-contract.md` documents all five node kinds and all five edge kinds with one paragraph each.
- [ ] It states the route-condition rule — a condition is a probe path and an expected value, never prose — and cites `lib/graph/validate.sh` as the enforcer.
- [ ] It states the harness-neutrality invariant: nothing under `lib/graph/` branches on the harness; only node bodies do, through `lib/harness.sh`.
- [ ] Every rule it states is enforced by a named script or test, cited inline. No rule is documentation-only.

---

### task-006: lib/graph/state.sh typed channel over feature.json

**Goal:** Enforce node contracts at the state boundary. `state.sh assert-reads <node>` fails when
a declared read is unsatisfied; `state.sh write <node> <key> <json>` fails when the key is not in
that node's `writes[]`, and otherwise delegates to `lib/feature-write.sh`. This realizes the
decision that the typed state channel is a declaration layer over `feature.json`, not a
replacement for it — atomic writes, `.bak` rotation, and the committed resume contract are
untouched.

**Files:**
- `lib/graph/state.sh`
- `tests/lib/graph-state.test.sh`

**read_first:**
- `skills/shared/feature-state-schema.md` (writing rules; why raw jq mutation is forbidden)
- `lib/feature-write.sh` (the delegate — its `set` and `append` signatures)
- `graph/schema.json` (the state key space)

**Verify:** `bash tests/lib/graph-state.test.sh` exits 0.

**Acceptance criteria:**
- [ ] `lib/graph/state.sh write` exits non-zero and writes nothing when the key is absent from the node's `writes[]` declaration.
- [ ] `lib/graph/state.sh write` on a declared key delegates to `lib/feature-write.sh` and leaves `feature.json.bak` rotated, exactly as a direct `feature-write.sh` call would.
- [ ] `lib/graph/state.sh assert-reads` exits non-zero when any declared read key is absent or null in `feature.json`.
- [ ] `lib/graph/state.sh` never mutates `feature.json` by any path other than `lib/feature-write.sh`; the test asserts this by pointing the delegate at a stub and confirming no write occurs when the stub is not invoked.
- [ ] `tests/lib/graph-state.test.sh` covers the undeclared-write rejection, the unsatisfied-read rejection, and the accepting case.

---

### task-007: annotate reads and writes on every declared node

**Goal:** Give every node in both graphs an explicit `reads[]` and `writes[]` drawn from the
schema's state key space, so the typed handoff contract is real for the whole cycle rather than
for a sample. Where a phase today reads state nobody declared writing, that is a finding to
record, not a gap to paper over.

**Files:**
- `graph/cycle.graph.json`
- `graph/critique.graph.json`

**read_first:**
- `skills/shared/feature-state-schema.md` (schema v7 full key listing)
- `lib/feature-init.sh` (which keys the skeleton creates, and when)
- each phase skill's "Inputs" section

**Verify:** `jq -e '[.nodes[] | select((.reads|type)!="array" or (.writes|type)!="array")] | length == 0' graph/cycle.graph.json` exits 0; `bash lib/graph/validate.sh graph/cycle.graph.json` exits 0; `bash tests/graph-conformance.test.sh` exits 0.

**Acceptance criteria:**
- [ ] Every node in both graph files carries `reads` and `writes` arrays; no node omits either.
- [ ] Every key named in any `reads` or `writes` array is present in `graph/schema.json`'s state key space.
- [ ] Every key read by some node is written by an earlier node on every path that reaches it, or is present in the `lib/feature-init.sh` skeleton. `lib/graph/validate.sh` enforces this as a referential rule.
- [ ] Any phase found reading state no node declares writing is recorded in the task's completion notes rather than silently added to a `writes[]` list.

---

### task-008: lib/effort-probe.sh

**Goal:** Answer, per node, how hard to think. Deterministic inputs only: node kind, the
`lib/security-signal.sh` result, measured DAG width, changed-file count, task count, the prior
attempt count for this node, and whether the node authorizes delivery. Output is one line —
`mode=<system1|system2> reason=<text>`. Any unresolvable input yields `system2`: the probe fails
safe toward deliberation, never toward speed. `LOOP_SPEC_EFFORT` and its per-phase and per-node
forms outrank the computed answer in both directions, per the standing rule that an explicit
operator override outranks a probe.

**Files:**
- `lib/effort-probe.sh`
- `tests/lib/effort-probe.test.sh`

**read_first:**
- `lib/security-signal.sh` (the one-line answer-plus-reason contract, and the matched-term reporting idiom)
- `lib/execute-rung.sh` (a probe that logs its selection reason, and its env-override handling)
- `CLAUDE.md` section "Probes, not judgments"

**Verify:** `bash tests/lib/effort-probe.test.sh` exits 0.

**Acceptance criteria:**
- [ ] `lib/effort-probe.sh` prints exactly one line to stdout, matching `^mode=(system1|system2) reason=`, and exits 0 on every well-formed invocation.
- [ ] No model judgment participates: every input is read from a file, an environment variable, or another probe's output.
- [ ] Any input that cannot be resolved produces `mode=system2` with a reason naming the unresolved input.
- [ ] `LOOP_SPEC_EFFORT=system1` and `LOOP_SPEC_EFFORT=system2` each override the computed answer, and the reason field names the override as the cause.
- [ ] Per-phase and per-node override forms are honored, with the more specific form winning.
- [ ] `tests/lib/effort-probe.test.sh` asserts the single-line output shape, one case per input dimension, the unresolved-input fail-safe, and both override directions.

---

### task-009: lib/conflict-monitor.sh

**Goal:** Decide when deliberation wakes up. Report a conflict from four deterministic signals
only: a failing test command, a `[major]` gate finding, contradictory outputs from two agents on
the same node, and N consecutive identical failures. This realizes the decision that the monitor
escalates forward — its output raises the affected node's *next attempt* to `system2` and is
written to the trace. It never rewinds, never replays from a checkpoint, and never blocks.

**Files:**
- `lib/conflict-monitor.sh`
- `tests/lib/conflict-monitor.test.sh`

**read_first:**
- `hooks/team/strategy-rotation.sh` (the existing consecutive-failure counter, whose state shape this reuses)
- `lib/security-signal.sh` (the probe output contract)
- `docs/loop-spec/features/gdd/SPEC.md` section "4. Dual-process effort"

**Verify:** `bash tests/lib/conflict-monitor.test.sh` exits 0.

**Acceptance criteria:**
- [ ] `lib/conflict-monitor.sh` prints one line matching `^conflict=(yes|no) reason=` and exits 0 in all four signal cases and the no-conflict case.
- [ ] It reports `conflict=yes` for each of: a non-zero test command exit, a `[major]` gate finding, contradictory outputs from two agents on one node, and N consecutive identical failures.
- [ ] It reports `conflict=no` when none of the four signals is present.
- [ ] It performs no rewind, no replay, and no checkpoint restore; the test asserts the checkpoint ledger is byte-identical before and after a `conflict=yes` invocation.
- [ ] The consecutive-failure threshold N is configurable by environment variable and defaults to the value already used by `hooks/team/strategy-rotation.sh`.
- [ ] `tests/lib/conflict-monitor.test.sh` covers one case per signal, the no-conflict case, and the no-side-effects assertion.

---

### task-010: skills/shared/dual-process.md and model-matrix rework

**Goal:** Document the effort contract canonically, and rework `skills/shared/model-matrix.md` so
today's static role-to-model table becomes the `system2` column with a `system1` column beside it.
Nothing gets less capable than 2.35 by default. The doc must state the authority bound explicitly:
System 1 controls model alias and reasoning depth freely, and may skip only gates a probe already
licenses skipping (PLAN's at-most-2-tasks/3-files fast-path with no security signal). It may never
skip a gate on a judgment.

**Files:**
- `skills/shared/dual-process.md`
- `skills/shared/model-matrix.md`

**read_first:**
- `skills/shared/model-matrix.md` (current role table and design rules)
- `README.md` section "The cycle in detail" (PLAN's structural fast-path, the only probe-licensed skip today)
- `lib/effort-probe.sh`, `lib/conflict-monitor.sh` (written by task-008 and task-009)

**Verify:** `bash tests/lib/effort-probe.test.sh` exits 0; `grep -cE '^\| *system1 *\|' skills/shared/model-matrix.md` returns 1 or more; `bash tests/graph-docs-coverage.test.sh` exits 0 once task-023 lands.

**Acceptance criteria:**
- [ ] `skills/shared/dual-process.md` states the two probes, their output contracts, and the exact bound on System 1's authority.
- [ ] It states that unknown inputs resolve to `system2` and that an operator override outranks the probe, citing both scripts.
- [ ] It names the one probe-licensed gate skip that exists (PLAN's structural fast-path) and states that no other gate may be skipped by effort.
- [ ] `skills/shared/model-matrix.md` presents two model columns, and every role's `system2` value equals its current 2.35 value, so no role is downgraded by default.
- [ ] The forward-escalation rule is stated: a conflict raises the node's next attempt, and does not rewind.

---

### task-011: bind effort to nodes and license gate skips

**Goal:** Wire the probes into the graph. Every node gains a default `effort`, and
`lib/graph/validate.sh` gains two rules: a `gate` node may declare itself skippable only by
naming the probe that licenses the skip, and a node whose kind authorizes delivery may not
declare a `system1` default.

**Files:**
- `graph/cycle.graph.json`
- `lib/graph/validate.sh`

**read_first:**
- `skills/shared/dual-process.md` (written by task-010)
- `lib/graph/validate.sh` (existing referential rules to extend)
- `graph/schema.json`

**Verify:** `bash lib/graph/validate.sh graph/cycle.graph.json` exits 0; `bash tests/lib/graph-validate.test.sh` exits 0 with the two new rule cases; `jq -e '[.nodes[] | select(.effort == null)] | length == 0' graph/cycle.graph.json` exits 0.

**Acceptance criteria:**
- [ ] Every node in `graph/cycle.graph.json` declares a default `effort` of `system1` or `system2`.
- [ ] `lib/graph/validate.sh` exits 1 for a `gate` node marked skippable without a licensing probe path.
- [ ] `lib/graph/validate.sh` exits 1 for a delivery-authorizing node declaring `effort: system1`.
- [ ] `tests/lib/graph-validate.test.sh` gains one case per new rule, each asserting a non-zero exit.
- [ ] No gate that is unconditional in 2.35 becomes skippable by this task.

---

### task-012: lib/graph/checkpoint.sh node ledger

**Goal:** Append one record per node boundary — node id, state snapshot hash, git SHA, timestamp,
effort mode, and the admitting edge — to a durable, append-only ledger. This generalizes
`lib/checkpoint.sh`, which today tags git at phase boundaries only and captures no state. The
ledger is what makes resume a lookup instead of a scan.

**Files:**
- `lib/graph/checkpoint.sh`
- `tests/lib/graph-checkpoint.test.sh`

**read_first:**
- `lib/checkpoint.sh` (the existing phase-boundary tagger it generalizes)
- `lib/graph/state.sh` (the state snapshot source, written by task-006)
- `lib/events.sh` (the append-only file idiom)

**Verify:** `bash tests/lib/graph-checkpoint.test.sh` exits 0.

**Acceptance criteria:**
- [ ] Each appended record carries a non-null node id, state hash, git SHA, timestamp, effort mode, and admitting edge.
- [ ] The ledger is append-only: the test asserts an existing record is byte-identical after a subsequent append.
- [ ] `checkpoint.sh latest` returns the most recent record for a feature, and returns a distinguishable empty result rather than failing when none exists.
- [ ] The state hash changes when `feature.json` changes and is stable when it does not.
- [ ] `tests/lib/graph-checkpoint.test.sh` covers append, field completeness, append-only immutability, and hash stability.

---

### task-013: lib/graph/trace.sh node-stamped events

**Goal:** Wrap `lib/events.sh`, adding `node`, `edge`, `probe`, `probeReason`, and `effort` to
every emitted event, and inherit its observability contract verbatim: a telemetry failure prints
one warning to stderr and exits 0. Because the trace records the edge taken and why, the executed
graph is reconstructable from `events.jsonl` alone.

**Files:**
- `lib/graph/trace.sh`
- `tests/lib/graph-trace.test.sh`

**read_first:**
- `lib/events.sh` lines 1-30 (the never-abort contract and the JSONL record shape)
- `lib/run-digest.sh` (the existing consumer, which must keep parsing the augmented records)
- `graph/schema.json`

**Verify:** `bash tests/lib/graph-trace.test.sh` exits 0.

**Acceptance criteria:**
- [ ] Every event emitted through `lib/graph/trace.sh` carries `node`, `edge`, `probe`, `probeReason`, and `effort` fields.
- [ ] The wrapper exits 0 even when the underlying writer fails, printing one warning to stderr; the test asserts this with a failing stub.
- [ ] Records remain valid JSONL and remain parseable by `lib/run-digest.sh` unchanged.
- [ ] `tests/lib/graph-trace.test.sh` includes a reconstruction case that rebuilds the traversed node-and-edge sequence from a recorded `events.jsonl` and compares it to the expected sequence.

---

### task-014: lib/graph/run.sh engine with dry-run and resume

**Goal:** The engine. Load a graph, compute ready nodes from satisfied edges and typed state,
evaluate each `route` condition by executing its probe and comparing to `expects`, dispatch the
node body, checkpoint, trace, and repeat. `--dry-run` traverses without dispatching any body. A
`human` node writes a checkpoint, emits a resumable pause record, and stops; a later invocation
resumes at exactly that node. The engine owns sequencing, not content — a node body is still a
skill dispatch.

**Files:**
- `lib/graph/run.sh`
- `tests/lib/graph-run.test.sh`

**read_first:**
- `skills/cycle/SKILL.md` Step 6 (the prose sequencing being replaced)
- `lib/graph/state.sh`, `lib/graph/checkpoint.sh`, `lib/graph/trace.sh`
- `lib/cycle-result.sh` (the terminal result contract the engine must reproduce)
- `lib/execute-rung.sh` (how a fanout node selects its dispatch rung)

**Verify:** `bash tests/lib/graph-run.test.sh` exits 0.

**Acceptance criteria:**
- [ ] `lib/graph/run.sh --dry-run graph/cycle.graph.json` visits the seven phase nodes in declared order and dispatches no node body.
- [ ] A `route` edge is taken only when its probe's output equals `expects`; the test asserts both the taken and not-taken directions with a stub probe.
- [ ] Reaching a `human` node writes a checkpoint, emits a pause record, and exits with a distinct, documented status rather than a failure.
- [ ] A fresh process resuming from that pause record begins traversal at exactly the interrupted node id.
- [ ] The engine emits a terminal result object whose keys match those produced by `lib/cycle-result.sh`.
- [ ] The engine contains no harness-specific branching; harness differences are confined to node bodies via `lib/harness.sh`.
- [ ] A `loop` edge stops at its declared ceiling rather than running unbounded.

---

### task-015: cycle Step 6 cutover to the engine

**Goal:** `skills/cycle/SKILL.md` Step 6 stops enumerating phases in prose and hands sequencing to
`lib/graph/run.sh`. Semantics are identical: the same invocation must produce the same artifacts,
the same gates, and the same terminal result contract as 2.35.

**Files:**
- `skills/cycle/SKILL.md`

**read_first:**
- `skills/cycle/SKILL.md` Step 6 and the "Resume strategy + phase pause/escalation" section
- `lib/graph/run.sh` (written by task-014)
- `graph/cycle.graph.json`

**Verify:** `bash tests/graph-conformance.test.sh` exits 0; `bash tests/lib/graph-run.test.sh` exits 0; `bash tests/run-all.sh` exits 0.

**Acceptance criteria:**
- [ ] Step 6 invokes `lib/graph/run.sh` and no longer enumerates phase successors in prose.
- [ ] Resume routes through the checkpoint ledger rather than through the prose scan-and-infer procedure.
- [ ] Every documented invocation form from 2.35 still works: the four execution styles, autonomous mode, non-interactive mode, greenfield, and backlog.
- [ ] The terminal result contract is unchanged, asserted by the existing result-contract tests passing without modification.
- [ ] No phase skill is modified by this task; the cutover is confined to the orchestrator.

---

### task-016: delete prose routing; repurpose the conformance test

**Goal:** Complete the cutover. Remove from the seven phase skills the routing prose the graph now
owns — declared successors, rewind targets, gate escalation triggers, retry budgets. This realizes
the full-cutover decision: there is no `LOOP_SPEC_GRAPH=1` opt-in and no prose fallback path,
because two control-flow implementations guarantee the unexercised one decays untested. The
conformance test is repurposed from skills-match-graph into the graph's own schema validator plus a
residual-prose check.

**Files:**
- `skills/spec/SKILL.md`, `skills/discuss/SKILL.md`, `skills/plan/SKILL.md`,
  `skills/execute/SKILL.md`, `skills/verify/SKILL.md`, `skills/iterate/SKILL.md`,
  `skills/deliver/SKILL.md`
- `tests/graph-conformance.test.sh`

**read_first:**
- `tests/graph-conformance.test.sh` (its extraction rules identify exactly what prose to delete)
- `graph/cycle.graph.json`
- `CLAUDE.md` section "Skills are code" (do not restructure tested skill content beyond the routing being removed)

**Verify:** `bash tests/graph-conformance.test.sh` exits 0 including its residual-prose check; `bash tests/run-all.sh` exits 0.

**Acceptance criteria:**
- [ ] No phase skill declares a successor phase, a rewind target, or a gate escalation trigger that `graph/cycle.graph.json` also declares.
- [ ] `tests/graph-conformance.test.sh` gains a residual-prose check that exits non-zero when such a declaration reappears.
- [ ] No `LOOP_SPEC_GRAPH` environment variable exists anywhere in the tree, and no prose fallback path is retained.
- [ ] Phase *content* is unchanged: interview questions, agent prompts, gate criteria, and artifact formats are untouched. Only routing is removed.
- [ ] `bash tests/run-all.sh` exits 0 with every pre-existing suite passing unmodified.

---

### task-017: skills/shared/handoff-port.md six-operation contract

**Goal:** Define the interface, not the transport. Six operations over node-instance bundles —
`put`, `get`, `list`, `claim`, `release`, `complete` — with exact arguments, exit codes, and
concurrency semantics. This realizes the decision that distribution ships as a port with exactly one
reference adapter: git, a pub/sub stream, an object store, or a queue are adapters an integrator
writes against this contract, and the plugin never learns which.

**Files:**
- `skills/shared/handoff-port.md`

**read_first:**
- `skills/shared/design-for-change.md` (interface with one shipped implementation; no speculative adapters)
- `skills/shared/graph-contract.md` (written by task-005)
- `docs/loop-spec/features/gdd/SPEC.md` section "6. The handoff port"

**Verify:** `bash tests/lib/graph-port-contract.test.sh` exits 0 once task-019 lands; until then, `test -f skills/shared/handoff-port.md`.

**Acceptance criteria:**
- [ ] All six operations are specified with arguments, stdout shape, and exit codes.
- [ ] `claim` semantics are specified: exclusive ownership, a bounded lease with a TTL, and a defined outcome for a second claimant on an unexpired lease.
- [ ] `complete` semantics are specified: the bundle state hash is re-checked, and a stale return is rejected rather than reconciled.
- [ ] The doc states that `lib/graph/port-local.sh` is a conformance target, not a recommended production substrate.
- [ ] The doc names `tests/lib/graph-port-contract.test.sh` as the executable definition an integrator runs against their own adapter.

---

### task-018: lib/graph/port.sh dispatcher and port-local.sh adapter

**Goal:** One dispatcher that routes the six operations to the adapter named by `LOOP_SPEC_PORT`,
defaulting to `lib/graph/port-local.sh`, plus that reference adapter implementing all six against
the repository. An integrator pointing `LOOP_SPEC_PORT` at their own executable gets the same six
operations over whatever substrate they like.

**Files:**
- `lib/graph/port.sh`
- `lib/graph/port-local.sh`

**read_first:**
- `skills/shared/handoff-port.md` (written by task-017)
- `lib/resolve-bin.sh` (the existing executable-resolution idiom for env-named binaries)
- `lib/feature-write.sh` (the atomic write pattern the local adapter reuses)

**Verify:** `bash tests/lib/graph-port-contract.test.sh` exits 0 once task-019 lands; `bash lib/graph/port.sh` with no argument exits 2.

**Acceptance criteria:**
- [ ] `lib/graph/port.sh` dispatches all six operations to the adapter named by `LOOP_SPEC_PORT` and defaults to `lib/graph/port-local.sh` when unset.
- [ ] An unset, missing, or non-executable `LOOP_SPEC_PORT` target fails with a named error and a non-zero exit; it never silently falls back after an explicit setting.
- [ ] `lib/graph/port-local.sh` implements all six operations, with `claim` using an atomic primitive so two concurrent claims cannot both succeed.
- [ ] A lease expires: an instance claimed with an elapsed TTL becomes claimable again.
- [ ] Neither file branches on the harness.

---

### task-019: adapter conformance suite

**Goal:** Make "does my adapter work" a command rather than an opinion. The suite takes an adapter
path as `$1`, defaulting to `lib/graph/port-local.sh`, and exercises the full contract including
the two cases that matter most for correctness under concurrency: a second claimant on an
unexpired lease, and a `complete` whose bundle state hash no longer matches.

**Files:**
- `tests/lib/graph-port-contract.test.sh`

**read_first:**
- `skills/shared/handoff-port.md`
- `lib/graph/port-local.sh` (written by task-018)
- `tests/lib/execute-rung.test.sh` (the house test-harness structure to match)

**Verify:** `bash tests/lib/graph-port-contract.test.sh` exits 0; `bash tests/lib/graph-port-contract.test.sh lib/graph/port-local.sh` exits 0.

**Acceptance criteria:**
- [ ] The suite accepts an adapter path as `$1` and defaults to `lib/graph/port-local.sh`.
- [ ] It exercises `put`, `get`, `list`, `claim`, `release`, and `complete` in a round trip that asserts the returned bundle matches the stored one.
- [ ] It includes a double-claim case asserting the second `claim` exits non-zero while the first lease is unexpired.
- [ ] It includes a lease-expiry case asserting the instance becomes claimable after the TTL elapses.
- [ ] It includes a stale-return case asserting `complete` exits non-zero and leaves the instance unmerged when the bundle state hash does not match.
- [ ] It is registered in `tests/run-all.sh` and passes as part of the default offline suite.

---

### task-020: lib/graph/handoff.sh bundles and the foreign-claimant rung

**Goal:** Make a node instance a self-contained, claimable work item. A bundle carries typed
inputs, the node contract, the verify command, the base SHA, and a state hash — content-addressed,
so a claimant needs the repository and the bundle and nothing else from the originating session,
and a stale return fails deterministically rather than merging silently. `lib/execute-rung.sh`
gains one rung so EXECUTE can select foreign claimants, without changing its signature or breaking
its existing test.

**Files:**
- `lib/graph/handoff.sh`
- `lib/execute-rung.sh`

**read_first:**
- `lib/execute-rung.sh` (full file — the rung selection ladder and its JSON output shape)
- `skills/shared/handoff-port.md`
- `skills/shared/execute-loops.md` (the SPEC/PLAN hash-lock this generalizes)
- `lib/dag-width.sh` (width measurement feeding the ladder)

**Verify:** `bash tests/lib/execute-rung.test.sh` exits 0 unmodified; `bash tests/e2e/graph-handoff.test.sh` exits 0 once task-021 lands.

**Acceptance criteria:**
- [ ] `lib/graph/handoff.sh export` produces a bundle carrying typed inputs, the node contract, the verify command, the base SHA, and a state hash.
- [ ] A bundle is self-contained: `tests/e2e/graph-handoff.test.sh` executes one in a subshell with a scrubbed environment and no session state.
- [ ] `lib/graph/handoff.sh import` rejects a returning bundle whose state hash does not match the current state, with a non-zero exit and an unmerged result.
- [ ] `lib/execute-rung.sh` gains exactly one new rung value, keeps its existing signature, and logs its selection reason in the same one-line form as today.
- [ ] `tests/lib/execute-rung.test.sh` passes without modification, and the new rung is only selected when the port is reachable and foreign claimants are opted in.
- [ ] The same graph node definition serves both the in-session rungs and the foreign-claimant rung; width selects the rung and never removes a node.

---

### task-021: hermetic cross-process handoff e2e

**Goal:** Prove the distribution claim end to end, offline. Claim a bundle from a subshell with a
scrubbed environment, execute it, complete it, and assert the result merges — with no network, no
live harness, and no shared session state.

**Files:**
- `tests/e2e/graph-handoff.test.sh`

**read_first:**
- `lib/graph/handoff.sh`, `lib/graph/port-local.sh`
- `tests/e2e/run-e2e.sh` (the existing e2e conventions; note this new test is offline and joins the default suite instead)
- `tests/lib/graph-port-contract.test.sh`

**Verify:** `bash tests/e2e/graph-handoff.test.sh` exits 0 with no network access.

**Acceptance criteria:**
- [ ] The test runs offline and hermetically, with no network calls and no live harness dependency.
- [ ] It claims a bundle from a subshell whose environment is scrubbed of session state, executes the node, and completes it.
- [ ] It asserts the completed result merges into the feature branch and that the checkpoint ledger records the completion.
- [ ] It asserts a second claimant is refused while the first lease is unexpired.
- [ ] It is registered in `tests/run-all.sh` as part of the default offline suite, not the opt-in live matrix.

---

### task-022: pi and opencode harness coverage pins

**Goal:** Pin the new cross-file couplings so the multi-harness contract cannot silently drift, per
the repository rule that every non-Claude accommodation is an additive branch keyed on
`lib/harness.sh` and pinned in the coverage tests.

**Files:**
- `tests/pi-harness-coverage.test.sh`
- `tests/opencode-harness-coverage.test.sh`

**read_first:**
- `tests/pi-harness-coverage.test.sh`, `tests/opencode-harness-coverage.test.sh` (existing pin idiom)
- `skills/shared/pi-harness.md`, `skills/shared/opencode-harness.md`
- `lib/graph/run.sh`, `lib/graph/port.sh`

**Verify:** `bash tests/pi-harness-coverage.test.sh` exits 0; `bash tests/opencode-harness-coverage.test.sh` exits 0.

**Acceptance criteria:**
- [ ] Both coverage tests assert that nothing under `lib/graph/` references a harness-specific construct.
- [ ] Both assert the engine's node-body dispatch resolves through `lib/harness.sh` rather than through a hard-coded harness name.
- [ ] `skills/shared/pi-harness.md` and `skills/shared/opencode-harness.md` document the graph engine's behavior on each harness, including any documented degradation.
- [ ] Both tests pass as part of `bash tests/run-all.sh`.

---

### task-023: docs/loop-spec/gdd.md architecture and pattern bindings

**Goal:** The architecture document. It binds each of the six named agentic workflow patterns to a
graph shape and to the loop-spec construct that already realizes it — proving the vocabulary
sufficient by exhibiting existing behavior in it rather than by asserting generality. It also
carries the graphify rebuttal: graphify was a derived map of the codebase that rotted silently, and
a declared control-flow contract the engine executes cannot rot silently because a wrong edge
breaks the next run at the node that took it.

**Files:**
- `docs/loop-spec/gdd.md`
- `tests/graph-docs-coverage.test.sh`

**read_first:**
- `CLAUDE.md` section "No stored code map; derive structure fresh" (the graphify evidence and rationale)
- `docs/loop-spec/bmad-scan-proposals.md` (the house structure for an external-scan document, including its rejected-alternatives section)
- `graph/cycle.graph.json`, `skills/shared/graph-contract.md`

**Verify:** `grep -cE '^\| (Prompt chaining|Routing|Parallelization|Orchestrator-workers|Evaluator-optimizer|Human-in-the-loop) \|' docs/loop-spec/gdd.md` returns 6; `bash tests/graph-docs-coverage.test.sh` exits 0.

**Acceptance criteria:**
- [ ] `docs/loop-spec/gdd.md` contains a table binding all six named patterns to a graph shape and to the loop-spec construct realizing it.
- [ ] It contains a section explaining why the workflow graph is not a return of graphify, citing the measured evidence recorded in `CLAUDE.md`.
- [ ] It records rejected alternatives with reasons, in the style of `docs/loop-spec/bmad-scan-proposals.md`, so the decisions are not relitigated.
- [ ] It cites the four external sources and marks any claim about them that could not be probed as an assumption with a verify command.
- [ ] `tests/graph-docs-coverage.test.sh` asserts each of `graph-contract.md`, `dual-process.md`, and `handoff-port.md` exists and has at least one referencing skill.

---

### task-024: ROADMAP-3.0 restructure — pillars as graphs

**Goal:** Restructure `docs/loop-spec/ROADMAP-3.0.md` so this feature is the 3.0 headline and
Pillars A-D are re-expressed as graphs over the new substrate rather than as independent prose
subsystems. Each pillar needs durable typed state and cross-session resume, which is exactly what
the substrate provides.

**Files:**
- `docs/loop-spec/ROADMAP-3.0.md`

**read_first:**
- `docs/loop-spec/ROADMAP-3.0.md` (full file — the four pillars and the five carried-forward design constraints)
- `docs/loop-spec/gdd.md` (written by task-023)
- `graph/cycle.graph.json`

**Verify:** `grep -cE '^\| Pillar [A-D] \|' docs/loop-spec/ROADMAP-3.0.md` returns 4.

**Acceptance criteria:**
- [ ] The roadmap states that graph-driven development is the 3.0 headline and supersedes the prior pillar sequencing.
- [ ] A table binds each of Pillars A-D to a graph file or node set over the new substrate.
- [ ] The five carried-forward design constraints are preserved verbatim and each is shown to be satisfied by this feature.
- [ ] The semver stance is restated and shown to hold: every 2.x invocation, artifact path, config file, and hook keeps working, because the break is internal.

---

### task-025: 3.0.0 bump, README, CHANGELOG, suite registration

**Goal:** Ship it. Version in lockstep across all four declaration sites via `lib/bump-version.sh`,
README updated for the graph architecture and the handoff port, CHANGELOG entry, and all twelve new
suites registered in `tests/run-all.sh`.

**Files:**
- `README.md`
- `CHANGELOG.md`
- `package.json`
- `.claude-plugin/plugin.json`
- `.claude-plugin/marketplace.json`
- `tests/run-all.sh`

**read_first:**
- `lib/bump-version.sh` (the four declaration sites and the `--check` mode)
- `README.md` sections "Architecture" and "The cycle in detail"
- `tests/run-all.sh` (the `run_suite` registration idiom)
- `CHANGELOG.md` (the most recent entry, for house format)

**Verify:** `bash lib/bump-version.sh --check` exits 0 and reports `3.0.0`; `bash tests/run-all.sh` exits 0; `bash tests/validate-manifest.test.sh` exits 0; `bash tests/validate-pi-manifest.test.sh` exits 0.

**Acceptance criteria:**
- [ ] Version is `3.0.0` in `package.json`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and the README line, set via `bash lib/bump-version.sh 3.0.0` rather than by hand.
- [ ] `README.md` documents the graph architecture, the effort probe, the checkpoint ledger, and the handoff port, and its mermaid cycle diagram reflects the declared graph.
- [ ] `CHANGELOG.md` records the change under 3.0.0, including the removal of prose routing and the fact that no user-facing invocation changed.
- [ ] All twelve new test suites are registered in `tests/run-all.sh` via `run_suite`.
- [ ] `bash tests/run-all.sh` exits 0.
</content>
