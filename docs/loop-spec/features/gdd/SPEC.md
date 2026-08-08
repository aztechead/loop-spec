---
ambiguity_scores:
  goal_clarity: 0.90
  boundary_clarity: 0.85
  constraint_clarity: 0.80
  acceptance_clarity: 0.85
  ambiguity: 0.15
  rounds_completed: 2
  gate_passed: true
  unresolved_dimensions: []
---

# GDD — graph-driven development: the cycle as a typed, checkpointed, distributable graph

**Slug:** `gdd`
**Created:** 2026-08-08
**Tier:** standard
**Execution style:** step

## Problem

loop-spec 2.35 runs a seven-phase cycle whose *content* is excellent and whose
*control flow is prose*. Three consequences, each already observable in the tree:

**1. The topology is unreadable, untestable, and unrenderable.** Which phase follows
which, what makes a critique gate escalate, where ITERATE rewinds to, how many retries
a gate gets before it pauses — all of it lives in English spread across 35 `SKILL.md`
files and is re-derived by a model on every run. Nothing checks that
`skills/cycle/SKILL.md` Step 6's dispatch table agrees with what `skills/iterate/SKILL.md`
claims it can rewind to. There is no single artifact that states the topology, no unit
under test for an individual edge, and no way to render what a given run actually
traversed.

This contradicts the repo's own law. `CLAUDE.md` states: *"A model judgment that SELECTS
A CODE PATH must become a deterministic probe with a test. Prose criteria make a
consequential branch depend on how a model read a document that day: unreproducible,
unauditable, and invisible when wrong."* Four such judgments have been converted —
`lib/security-signal.sh`, `lib/teams-capability.sh`, `lib/harness.sh entrypoint`,
`lib/execute-rung.sh`. Each became a script *after it bit us*. The remaining branches —
phase sequencing, gate escalation, rewind targeting, retry budgets, resume routing — are
still prose, still selecting code paths, and still waiting their turn to bite.

**2. State is durable but untyped.** `feature.json` is atomically written through
`lib/feature-write.sh` and committed as the resume contract, but any phase may read or
write any key. No phase declares what it requires on entry or guarantees on exit. The
failure this permits has already occurred: hand-built inline state silently dropped
`iterateJudge` from the normalized models map, which is why `lib/feature-init.sh` became
the single source of truth for the skeleton (`skills/cycle/SKILL.md` Step 5 documents
exactly this). That fix hardened one construction site. The *class* of defect — a
producer that does not declare what it writes, handing to a consumer that does not
declare what it needs — is untouched, and it is the same defect that will appear the
moment work is handed to an agent that was not present when the state was built.

**3. Every dispatch rung is a child of one session.** `lib/execute-rung.sh` selects
among inline, batched subagent waves, an agent team, and the loop fleet. All four are
descendants of the invoking process: subagents are spawned by it, teammates are addressed
over in-session `SendMessage`, fleet workers are supervised by a synchronous call the
session must keep alive. Resume recovers a run *within a checkout*; it does not
distribute one. There is no representation of a unit of work that an independent agent —
a different session, a different machine, plausibly a different harness — can be handed,
execute against a known contract, and return. The intended future is explicit: an agent
is told *"you own task-002 of EXECUTE, this other agent owns task-003"*, and neither is a
child of the other. Nothing in the current architecture expresses that.

**And effort is assumed, never measured.** `skills/shared/model-matrix.md` binds model to
*role*: planner is always opus, implementer is always sonnet. A two-line documentation
correction and an authentication rewrite receive identical treatment because they are
performed by the same role. There is no probe that asks how hard a given node is actually
worth thinking about, and correspondingly no mechanism to spend more when a run starts
going wrong. The one place the plugin does adapt — PLAN's structural fast-path (at most
2 tasks and 3 files, no security signal) — proves the pattern works and proves it is
currently a one-off.

<decisions>
- Decision: the workflow graph is declared data that the engine executes, never a derived map of the codebase.
- Decision: full cutover — once a node's control flow lands in the graph, the prose routing it replaces is deleted, with no opt-in flag and no prose fallback path.
- Decision: a conformance test precedes the engine as build order, not as a parallel regime, and is repurposed as the graph's own schema validator once the cutover lands.
- Decision: every route edge condition names a probe script and an expected value; prose conditions are rejected by the validator.
- Decision: the typed state channel is a declaration layer over `feature.json`, not a replacement for it, and every write still routes through `lib/feature-write.sh`.
- Decision: `lib/effort-probe.sh` emits its mode and reason on one line from deterministic inputs only, and resolves to `system2` whenever an input cannot be resolved.
- Decision: System 1 authority is bounded to model alias, reasoning depth, and skipping only those gates a probe already licenses skipping; it may never skip a gate on a judgment.
- Decision: `lib/conflict-monitor.sh` escalates forward by raising the affected node's next attempt to `system2`, and never rewinds or replays from a checkpoint.
- Decision: an explicit operator override outranks the effort probe in both directions.
- Decision: distribution ships as a port with exactly one reference adapter; the transport is the integrator's choice and the plugin never learns it.
- Decision: a handoff bundle is self-contained and content-addressed, and a returning claimant whose state hash does not match is rejected rather than reconciled.
- Decision: solo and multi-agent runs execute the same graph — width selects the rung and never removes a node.
- Decision: this feature is the 3.0 headline and supersedes the ROADMAP-3.0 pillar sequencing, with Pillars A-D re-expressed as graphs over the new substrate.
- Decision: the six named agentic workflow patterns are documented as subgraph shapes bound to the loop-spec construct that already realizes each one.
</decisions>

### Why these decisions

| Decision | Rationale | Alternatives rejected |
|---|---|---|
| Declared data, not a derived map | Graphify rotted silently because it described a subject that drifted. A declared contract *is* the control flow, so a wrong edge breaks the next run at the node that took it. | Regenerating the graph from the skills (reintroduces derive-and-rot); leaving control flow in prose (that is the problem). |
| Full cutover | Two control-flow implementations guarantee the unexercised one decays untested — the drift `lib/feature-init.sh` exists to prevent. | Opt-in flag with prose default (dual maintenance); graph as documentation only (nothing enforces it). |
| Conformance test as build order | Proves the change is a refactor before it is an extension, and makes the cutover mechanical. | Cutting over directly (no evidence behavior was preserved); keeping the test as a permanent parallel check (that is dual maintenance by another name). |
| Probe-and-expects conditions | `CLAUDE.md`'s "probes, not judgments" applied to the whole topology instead of to four spots. | Model-evaluated conditions (unreproducible and unauditable, by house law). |
| State channel layered over `feature.json` | `feature.json` is already the committed resume contract with atomic writes and `.bak` rotation; a second store would fork the source of truth. | A separate state file per node (forks resume). |
| Deterministic effort probe | Matches the established probe contract: answer and reason on one line, fail safe when unknown. | A model-scored effort judgment (rejected by house law). |
| Bounded System 1 authority | The user chose both "model and depth only" and "may skip gates, fail-safe"; the coherent union is that effort controls cost freely and controls gate presence only where determinism already licenses it. | Letting effort skip any gate (removes checks on a judgment); effort touching model only (leaves the one existing probe-licensed skip unexplained). |
| Forward-only conflict escalation | The user declined checkpoint-rewind authority; forward escalation buys automatic deliberation without paying for a rerun. | Interrupt-and-replay (declined); prose "try harder" guidance (that is the status quo). |
| Operator override wins | `CLAUDE.md` states this as a standing rule for every probe, so it is house law rather than a per-feature choice. | Probe-only authority (contradicts house law). |
| Port with one reference adapter | The user asked for the interface and explicitly not for the transport; `CLAUDE.md` requires an interface with one shipped implementation and no speculative adapters. | Mandating a git-backed substrate (the user declined to fix the transport); shipping several adapters (speculation). |
| Content-addressed bundles | A foreign agent cannot be assumed to share the originating session's context, and a stale return must fail deterministically. Generalizes the loop fleet's existing SPEC/PLAN hash-lock. | Trusting the claimant's returned state (silent divergence); re-deriving state on return (expensive and still ambiguous). |
| Same graph at every width | Today a solo run silently receives a weaker path; identical semantics at every width is what makes distribution safe to add. | Width-specific node sets (reintroduces the degradation this fixes). |
| 3.0 headline | The user directed it; each roadmap pillar needs durable typed state and cross-session resume, which is exactly what this substrate provides. | Shipping as 2.36 with pillars unchanged (the pillars would each rebuild this substrate badly). |
| Patterns as subgraph shapes | The vocabulary must be proven sufficient by exhibiting existing behavior in it, not by asserting generality. | Naming the patterns in prose without binding them to constructs (documentation nobody can check). |

## Goals

- Express the loop-spec cycle as one declared graph artifact: nodes, typed state
  channels, and edges whose route conditions are named probe scripts with expected
  values.
- Make the graph the single authoritative source of control flow, with the prose
  routing it replaces deleted rather than retained as a fallback.
- Give every node a typed contract (`reads[]` / `writes[]`) that a validator enforces at
  the boundary, so a producer cannot under-deliver and a consumer cannot silently proceed
  on missing state.
- Checkpoint at every node boundary — state snapshot hash, git SHA, node id, timestamp —
  so a run can stop at any node and be resumed at exactly that node.
- Make interrupts a first-class node kind, so a human gate is a declared point in the
  topology rather than an ad-hoc `AskUserQuestion` inside prose.
- Stamp every trace event with node id, edge taken, probe answer, and probe reason, so
  the graph a run actually traversed is reconstructable from `events.jsonl` alone.
- Replace the static role-to-model table with a deterministic per-node effort probe that
  reports `system1|system2` and a reason, and bind model, depth, and probe-licensed gate
  skips to its answer.
- Detect conflict deterministically and escalate the affected node's next attempt to the
  deliberate path automatically.
- Define — and ship one reference implementation of — a persistence and handoff port
  through which an integrator can store resumable node instances anywhere (git, a pub/sub
  stream, an object store, a queue) without the plugin knowing the transport.
- Make a node instance a claimable, self-contained work item, so an agent that is not a
  child of the originating session can be handed EXECUTE task-002, run it, and return a
  contract-checked result.
- Preserve semantics exactly across the cutover: the same invocation produces the same
  artifacts, gates, and result contract as 2.35.

## Non-goals

- Choosing the distribution transport. The port is the deliverable; git, Redis, Kafka,
  SQS and friends are adapters an integrator writes.
- A scheduler, broker, daemon, or long-running service of any kind.
- Replacing `feature.json` as the durable resume contract.
- Replacing the harness's own task list, team, or subagent mechanisms; the engine
  dispatches through them, it does not reimplement them.
- Reintroducing a derived map of the codebase in any form. Structure is still read fresh
  from the tree per `CLAUDE.md`.
- Changing the *content* of any phase — what the spec-writer asks, what the planner
  produces, what the code-reviewer checks. This feature changes sequencing, typing,
  checkpointing, and effort, not craft.
- Multi-tenant authorization, identity, or access control for foreign claimants.

## Boundaries (what NOT to do)

- Never let a route edge carry a prose condition. The schema validator must reject any
  edge whose condition is not `{probe, expects}` naming an executable script.
- Never let the effort probe skip a gate that is not already probe-licensed to be
  skipped, and never let an unknown probe input resolve to `system1`.
- Never let a node write a state key it did not declare, and never let a node begin with
  a declared read unsatisfied.
- Never ship a second control-flow implementation "for safety". No fallback prose path,
  no opt-in flag gating the engine.
- Never make the engine harness-specific. Node *bodies* branch on `lib/harness.sh`; the
  engine, the schema, the state channel, and the port must not.
- Never introduce a runtime dependency beyond `bash >= 4`, `git`, `jq >= 1.5`,
  `python3 >= 3.7`. No npm, pip, or brew for shipped code.
- Never let a returning foreign claimant merge work whose bundle state hash does not
  match. A stale return fails; it does not reconcile.
- Never allow the trace writer to abort a run. `lib/events.sh`'s observability contract
  ("a broken telemetry writer must not kill a 2-hour run") extends to every new trace
  surface.
- Never let the graph describe anything it does not execute. A node in the graph that no
  engine path dispatches is a validator failure, not documentation.

## Constraints

- Runtime: `bash >= 4`, `git`, `jq >= 1.5`, `python3 >= 3.7` only, per `CLAUDE.md`.
- Multi-harness: Claude Code, pi, and opencode from one source tree. Every accommodation
  is an additive branch keyed on `lib/harness.sh`, never a change to the Claude Code
  path. New cross-file couplings pinned in `tests/pi-harness-coverage.test.sh` and
  `tests/opencode-harness-coverage.test.sh`.
- Version lockstep across `package.json`, `.claude-plugin/plugin.json`,
  `.claude-plugin/marketplace.json`, and the README line, set via
  `bash lib/bump-version.sh 3.0.0`.
- `tests/run-all.sh` must pass at every commit.
- Semver stance inherited from `ROADMAP-3.0.md`: 3.0 is not a breaking change to *user
  surface*. Every 2.x invocation, artifact path, config file, and hook keeps working.
  The break is internal — prose routing is deleted — and must be invisible to a caller.
- Artifacts must satisfy the existing structural gates: `lib/artifact-lint.sh`,
  `lib/acceptance-lint.sh`, `lib/grounding-lint.sh`, `lib/criteria-coverage.sh`,
  `lib/decision-coverage.sh`.
- House style is measured, not recalled: `lib/house-style.sh probe` and
  `lib/comment-tells.sh` govern the new sources.
- Commit format: `<type>: NO_JIRA <message>`. Never `--no-verify`.

## User-facing behavior

### 1. The graph vocabulary

A new top-level `graph/` directory holds graph definitions as JSON, with
`graph/schema.json` as their schema.

**Nodes** are the units of work. Five kinds:

| Kind | Body | Example |
|---|---|---|
| `agent` | dispatches a role through the harness | the PLAN node dispatching `loop-spec:planner` |
| `function` | runs a `lib/` script deterministically | the width measurement calling `lib/dag-width.sh` |
| `gate` | runs a probe and admits or blocks | the acceptance gate, the test-tamper scan |
| `subgraph` | nests another graph | the critique-gate protocol, reused by DISCUSS and PLAN |
| `human` | interrupts and waits for a person | the `step` style's inter-phase pause |

Every node declares `id`, `kind`, `reads[]`, `writes[]`, and a default `effort`.

**Edges** are the transitions. Five kinds: `chain` (unconditional successor), `route`
(conditional), `fanout` (one to many), `fanin` (many to one, with a join rule), and
`loop` (bounded repetition with an explicit ceiling).

A `route` edge's condition is **always** an object naming a probe and its expected value:

```json
{ "from": "plan.critique", "to": "plan.debate",
  "kind": "route",
  "condition": { "probe": "lib/security-signal.sh", "expects": "matched" } }
```

There is no prose condition form. `lib/graph/validate.sh` rejects any edge whose
condition is not of this shape, and rejects any probe path that is not an executable file
in the tree. This is what makes the whole topology testable: an edge is a script, an
expected value, and a unit test.

**State** is a typed channel over `feature.json`. `graph/schema.json` declares the key
space; each node declares which keys it reads and which it writes.
`lib/graph/state.sh` enforces both directions — a write to an undeclared key is an error,
and entering a node whose declared read is unsatisfied is an error. Writes still route
through `lib/feature-write.sh`, so atomicity, `.bak` rotation, and the committed resume
contract are unchanged.

### 2. The seven-phase cycle, declared

`graph/cycle.graph.json` states today's cycle exactly: SPEC through DELIVER as chained
nodes; the critique gate as a reusable subgraph invoked by DISCUSS and PLAN; EXECUTE as a
`fanout` over plan tasks with a `fanin` merge queue; VERIFY's scans as gates; ITERATE's
three gap classes as three `route` edges back to `execute`, `plan`, and `spec`; DELIVER's
CI-failure path as a route back through EXECUTE. The `step` and `interactive` styles
become `human` nodes rather than prose pauses.

Nothing about this run *behaves* differently. That is the point of Stage 1: the graph is
declared and `tests/graph-conformance.test.sh` asserts the skills agree with it, before
any engine executes it.

### 3. The six patterns, named and bound

`docs/loop-spec/gdd.md` documents each named agentic workflow pattern as a shape in this
vocabulary, bound to the loop-spec construct that already realizes it:

| Pattern | Graph shape | Realized today by |
|---|---|---|
| Prompt chaining | `chain` edges | SPEC → DISCUSS → PLAN → EXECUTE → VERIFY → ITERATE → DELIVER |
| Routing | `route` edges | `skills/auto/` + `lib/task-route.sh` (micro / debug / full) |
| Parallelization | `fanout` + `fanin` | EXECUTE's DAG waves; the five `mapper-*` agents |
| Orchestrator-workers | `subgraph` with a lead node | EXECUTE lead + implementers claiming tasks |
| Evaluator-optimizer | `loop` with a `gate` | critique gates, spec-compliance review, ITERATE's judge |
| Human-in-the-loop | `human` node | `step` / `interactive` styles, the ambiguity gate, checkpoint PRs |

The plugin already implements all six. Each is currently a bespoke prose mechanism. The
value here is not new capability; it is that six mechanisms collapse into one vocabulary
with one validator and one trace format.

### 4. Dual-process effort

`lib/effort-probe.sh` answers, per node, how hard to think:

```
$ bash lib/effort-probe.sh --node execute.task-002 --feature-dir .loop-spec/features/gdd
mode=system2 reason=security-signal:credential at lib/graph/port-local.sh:41
```

Inputs are deterministic and enumerated: node kind, `lib/security-signal.sh` result,
measured DAG width, changed-file count, task count, prior attempt count for this node,
and whether the node authorizes delivery. No model judgment participates. Any input that
cannot be resolved yields `system2` — the probe fails safe toward deliberation, never
toward speed.

The answer binds three things. **Model**: `system1` takes the throughput alias,
`system2` the reasoning alias, replacing the static role table in
`skills/shared/model-matrix.md` (the table becomes the `system2` column, so nothing gets
*less* capable than today by default). **Depth**: how many rounds a bounded loop is
allowed. **Gate presence**: `system1` may skip only gates a probe already licenses
skipping — concretely, PLAN's structural fast-path — and may never skip one on a
judgment.

`LOOP_SPEC_EFFORT=system2` (and per-phase / per-node forms) outranks the probe in both
directions, per the standing house rule that an explicit operator override beats a probe.

`lib/conflict-monitor.sh` is the other half — the question of when deliberation *wakes
up*. It reports a conflict from deterministic signals only: a failing test command, a
`[major]` gate finding, contradictory outputs from two agents on the same node, or N
consecutive identical failures. When it fires, the node's **next attempt** is raised to
`system2` and the signal is written to the trace. It does not rewind, does not replay
from a checkpoint, and never blocks on its own.

### 5. Checkpoints, interrupts, trace

`lib/graph/checkpoint.sh` appends one record per node boundary: node id, state snapshot
hash, git SHA, timestamp, effort mode, and the edge that admitted it. This generalizes
`lib/checkpoint.sh`, which today tags git at phase boundaries only and captures no state.

A `human` node is a real interrupt: the engine writes a checkpoint, emits a resumable
pause record, and stops. Any later invocation — same session, a new session tomorrow, a
different machine that cloned the repo — resumes at exactly that node with exactly that
state. Resume stops being a scan-and-infer procedure and becomes a lookup.

`lib/graph/trace.sh` wraps `lib/events.sh`, adding `node`, `edge`, `probe`, `probeReason`,
and `effort` to every event, and inherits its never-abort contract verbatim. Because the
trace records the edge taken and why, the executed graph is reconstructable from
`events.jsonl` alone — which is what makes a run reviewable after the fact rather than
only observable while it happens.

### 6. The handoff port

`skills/shared/handoff-port.md` defines the contract an integrator implements. Six
operations over node-instance bundles:

| Operation | Meaning |
|---|---|
| `put <bundle>` | store a node instance, return its id |
| `get <id>` | retrieve a stored bundle |
| `list [--claimable]` | enumerate stored instances |
| `claim <id> <owner> <ttl>` | take exclusive ownership for a bounded lease |
| `release <id>` | relinquish a claim without completing |
| `complete <id> <result>` | return a contract-checked result |

`lib/graph/port.sh` dispatches to an adapter named by `LOOP_SPEC_PORT`, defaulting to
`lib/graph/port-local.sh`, which implements all six against the repository. An integrator
pointing `LOOP_SPEC_PORT` at their own executable gets the same six operations backed by
whatever they like — a git branch, a pub/sub topic, an object store, a work queue. The
plugin never learns the transport. `tests/lib/graph-port-contract.test.sh` is a
conformance suite any adapter can be run against, so "does my adapter work" is a command,
not an opinion.

A **bundle** is self-contained: typed inputs, the node contract, the verify command, the
base SHA, and a state hash. A claimant needs the repository and the bundle, nothing else
from the originating session. On `complete`, the state hash is re-checked; a stale return
is rejected rather than reconciled. This generalizes the SPEC/PLAN hash-lock the loop
fleet already uses to stop a worker rewriting requirements to match its work.

### 7. Solo and together

The same graph runs at every width. Width selects the rung — inline, subagent waves, a
team, the loop fleet, or now foreign claimants over the port — and never removes a node.
A lone agent walks the graph sequentially and plays every role in turn, *including* the
adversarial ones: it does not skip the challenger because there is nobody else to be the
challenger.

This is what makes distribution safe. When EXECUTE fans out and task-002 goes to an agent
in another session, that agent is not running a degraded variant of the workflow; it is
running the same declared node under the same typed contract, and its return is checked
against the same criteria. `lib/execute-rung.sh` keeps its job — measuring width and
capability — and gains one more rung to select.

### 8. Why this is not graphify

The obvious objection deserves an answer in the spec rather than in review.

Graphify was a **derived map of the codebase**: generated, stored, and consulted as
authority. It was made a hard requirement in 2.29 and removed in 2.35 on evidence —
across every feature authored while it was mandatory it produced zero citations, zero
recorded refreshes, and zero evidence entries, while costing a Python 3.10+/uv dependency
and a cycle-aborting startup gate. `CLAUDE.md` records the lesson precisely: *"Stored maps
rot, and a rotted map is worse than none because it is wrong with authority."*

The workflow graph is not a map of anything. It is a **declared contract that the engine
executes**. It describes no external subject that could drift out from under it; it *is*
the control flow. A wrong edge does not sit silently misinforming a future reader — it
breaks the very next run, loudly, at the node that took it. The rot failure mode is
structurally unavailable.

The two rules from that lesson still bind, and this design honors both: nothing here
generates a graph from the code, and nothing here consults a stored artifact in place of
citing `file:line`. Structure is still read fresh from the tree when a phase needs it.

### 9. Migration

Three stages, in order, each shippable:

1. **Declare.** `graph/schema.json`, `graph/cycle.graph.json`, `lib/graph/validate.sh`,
   and `tests/graph-conformance.test.sh` asserting the current skills match the declared
   topology. No engine, no behavior change. A failing conformance test at this stage
   means the graph is wrong, and it is corrected until it is right.
2. **Execute.** `lib/graph/run.sh` drives the declared graph. Every phase produces byte-
   identical artifacts and an identical terminal result contract for the same input.
3. **Delete.** The prose routing the graph replaced is removed from the skills, and the
   conformance test is repurposed as the graph's schema validator.

There is no fourth stage in which the old path is kept around.

## Success criteria

### Good Enough

- [ ] `graph/schema.json` exists and defines the five node kinds and five edge kinds.
  Verify: `jq -e '(.definitions.node.properties.kind.enum | length) == 5 and (.definitions.edge.properties.kind.enum | length) == 5' graph/schema.json` exits 0.

- [ ] `graph/cycle.graph.json` declares a node for each of the seven phases and validates against the schema.
  Verify: `bash lib/graph/validate.sh graph/cycle.graph.json` exits 0 and prints a line matching `^graph-validate: ok`; `jq -e '[.nodes[] | select(.kind=="agent") | .id] | length >= 7' graph/cycle.graph.json` exits 0.

- [ ] `lib/graph/validate.sh` rejects a route edge whose condition is not a `{probe, expects}` object naming an executable file.
  Verify: `bash tests/lib/graph-validate.test.sh` passes, including a case where a prose condition exits non-zero and a case where a non-existent probe path exits non-zero.

- [ ] `lib/graph/state.sh` rejects a write to a key the node did not declare, and rejects entry to a node with an unsatisfied declared read.
  Verify: `bash tests/lib/graph-state.test.sh` passes, covering both rejection cases and the accepting case.

- [ ] `lib/effort-probe.sh` prints exactly one line of the form `mode=<system1|system2> reason=<text>` and exits 0.
  Verify: `bash tests/lib/effort-probe.test.sh` passes, including a case asserting the output line count is 1 and the mode is one of the two values.

- [ ] `lib/effort-probe.sh` resolves to `system2` when any input is unavailable.
  Verify: `bash tests/lib/effort-probe.test.sh` includes an unresolvable-input case whose stdout mode field equals `system2`.

- [ ] `LOOP_SPEC_EFFORT` overrides the probe in both directions.
  Verify: `bash tests/lib/effort-probe.test.sh` includes cases asserting `LOOP_SPEC_EFFORT=system1` and `LOOP_SPEC_EFFORT=system2` each win over the computed answer.

- [ ] `lib/conflict-monitor.sh` reports a conflict for each of its four deterministic signals and reports none otherwise.
  Verify: `bash tests/lib/conflict-monitor.test.sh` passes with one case per signal plus a no-conflict case.

- [ ] `lib/graph/checkpoint.sh` appends one record per node boundary carrying node id, state hash, git SHA, timestamp, and effort mode.
  Verify: `bash tests/lib/graph-checkpoint.test.sh` passes, asserting each of the five fields is non-null on a written record.

- [ ] `lib/graph/trace.sh` stamps `node`, `edge`, `probe`, `probeReason`, and `effort` onto emitted events and never exits non-zero.
  Verify: `bash tests/lib/graph-trace.test.sh` passes, including a case where the underlying writer fails and the wrapper still exits 0.

- [ ] `lib/graph/port.sh` implements the six-operation contract and dispatches to the adapter named by `LOOP_SPEC_PORT`.
  Verify: `bash tests/lib/graph-port-contract.test.sh` passes against `lib/graph/port-local.sh`, exercising `put`, `get`, `list`, `claim`, `release`, and `complete`.

- [ ] A second claimant cannot claim an instance already under an unexpired lease.
  Verify: `tests/lib/graph-port-contract.test.sh` includes a double-claim case whose second `claim` exits non-zero.

- [ ] A `complete` whose bundle state hash does not match the current state is rejected.
  Verify: `tests/lib/graph-port-contract.test.sh` includes a stale-return case whose `complete` exits non-zero and leaves the instance unmerged.

- [ ] `tests/graph-conformance.test.sh` fails when a skill's routing disagrees with `graph/cycle.graph.json`.
  Verify: `bash tests/graph-conformance.test.sh` passes on the tree as shipped, and passes its own negative case in which a mutated graph copy is detected.

- [ ] `lib/graph/run.sh` executes the declared cycle graph and produces the same terminal result contract as the 2.35 prose path.
  Verify: `bash tests/lib/graph-run.test.sh` passes, asserting a dry-run traversal of `graph/cycle.graph.json` visits the seven phase nodes in declared order and emits a terminal result object with the same keys as `lib/cycle-result.sh` produces.

- [ ] No prose routing remains for control flow the graph owns.
  Verify: `bash tests/graph-conformance.test.sh` includes a residual-prose check that exits non-zero if any skill still declares a phase successor or rewind target the graph also declares.

- [ ] `skills/shared/handoff-port.md`, `skills/shared/graph-contract.md`, and `skills/shared/dual-process.md` exist and are referenced by the skills that depend on them.
  Verify: `bash tests/graph-docs-coverage.test.sh` passes, asserting each doc exists and each has at least one referencing skill.

- [ ] `docs/loop-spec/gdd.md` binds all six named workflow patterns to a graph shape and a loop-spec construct.
  Verify: `grep -cE '^\| (Prompt chaining|Routing|Parallelization|Orchestrator-workers|Evaluator-optimizer|Human-in-the-loop) \|' docs/loop-spec/gdd.md` returns 6.

- [ ] The engine, schema, state channel, and port contain no harness-specific branching.
  Verify: `bash tests/pi-harness-coverage.test.sh` and `bash tests/opencode-harness-coverage.test.sh` pass with the new couplings pinned.

- [ ] Version is 3.0.0 in lockstep across all four declaration sites.
  Verify: `bash lib/bump-version.sh --check` exits 0 and reports `3.0.0`.

- [ ] The full offline suite passes.
  Verify: `bash tests/run-all.sh` exits 0.

### Exceptional

- [ ] The executed graph is reconstructable from the trace alone, with no other input.
  Verify: `bash tests/lib/graph-trace.test.sh` includes a case that rebuilds the traversed node-and-edge sequence from a recorded `events.jsonl` and compares it to the engine's own record.

- [ ] A node instance handed to a process with no shared session state completes and returns a contract-checked result.
  Verify: `bash tests/e2e/graph-handoff.test.sh` claims a bundle from a subshell with a scrubbed environment, executes it, completes it, and asserts the result merges.

- [ ] A run interrupted at a `human` node resumes at exactly that node in a fresh process.
  Verify: `bash tests/lib/graph-run.test.sh` includes an interrupt-and-resume case asserting the resumed traversal begins at the interrupted node id.

- [ ] The effort probe measurably reduces cost on low-stakes nodes without changing artifacts.
  Verify: `bash tests/lib/effort-probe.test.sh` asserts a docs-only single-file node resolves to `system1`, and `tests/graph-conformance.test.sh` asserts no `### Good Enough` criterion is gated on an effort mode.

- [ ] `ROADMAP-3.0.md` Pillars A-D are re-expressed as graphs over this substrate.
  Verify: `grep -cE '^\| Pillar [A-D] \|' docs/loop-spec/ROADMAP-3.0.md` returns 4 in a table binding each pillar to a graph file or node set.

## Out of scope

- Any specific distribution transport implementation beyond the local reference adapter.
- A UI or web renderer for the graph. The trace is machine-readable; rendering is an
  integrator concern.
- Cost accounting or budget enforcement per node beyond what `hooks/team/budget-gate.sh`
  already does.
- Retiring `lib/execute-rung.sh`. It keeps measuring width and capability; it gains a
  rung.
- Changing the ambiguity gate, the critique protocol's content, or any agent prompt's
  craft guidance.
- Authorization or identity for foreign claimants. The port defines ownership as an
  opaque owner string and a lease; who is allowed to claim is the integrator's policy.

## Grounding

<!-- Probe-before-assert (skills/shared/grounding-protocol.md). Repo facts below were
     read directly from the tree at 836ef34. The four external sources could NOT be
     probed: this session's egress proxy denied arxiv.org, workflowbuilder.io, adk.dev,
     and thedecisionlab.com (403 from the policy proxy, per
     `curl -sS "$HTTPS_PROXY/__agentproxy/status"`). Their content is recorded as
     ASSUMPTION with a verify command, not asserted as fact. -->

- EVID-001: `lib/execute-rung.sh:33-46` selects the EXECUTE rung from probed subagent, CLI, and loop-runtime capability; all four rungs are in-session.
- EVID-002: `lib/dag-width.sh:1-22` computes peak wave width by Kahn's algorithm and documents that the ladder reads W to choose subagent vs team vs workflow.
- EVID-003: `skills/shared/feature-state-schema.md:1-20` establishes `feature.json` as the committed resume contract, written atomically through `lib/feature-write.sh` with `.bak` rotation, and forbids raw `jq`/`python3` mutation.
- EVID-004: `skills/cycle/SKILL.md:563-568` records that hand-building `feature.json` inline previously dropped `iterateJudge` from the models map, which is why `lib/feature-init.sh` is the single source of truth.
- EVID-005: `CLAUDE.md` "Probes, not judgments" names the four converted probes (`lib/security-signal.sh`, `lib/teams-capability.sh`, `lib/harness.sh entrypoint`, `lib/execute-rung.sh`) and requires answer plus reason on one line, fail-safe on unknown, and operator override outranking the probe.
- EVID-006: `CLAUDE.md` "No stored code map" records graphify's removal in 2.35 with the measured evidence (zero citations, zero refreshes, zero evidence entries) and the "wrong with authority" rationale.
- EVID-007: `lib/events.sh:1-8` states the observability contract that a telemetry failure must never abort a run.
- EVID-008: `lib/artifact-lint.sh` `lint_spec` requires `## Problem`, `## Success criteria`, `### Good Enough` with at least one `- [ ]` item, and `## Grounding`; `lint_plan` requires `## Task DAG` with `| task-` rows, `## Tasks` with `### task-<id>` blocks each carrying `**Files:**`, `**Verify:**`, and `**Acceptance criteria:**`.
- EVID-009: `lib/acceptance-lint.sh:29-46` flags any acceptance criterion containing an unanchored `grep`; anchoring markers are `-w`, `\b`, `grep -v`, or `grep -E` with `^`/`function `/`def `/`class `.
- EVID-010: `skills/shared/model-matrix.md` binds model to role statically, with no per-node effort input.
- EVID-011: `README.md` "The cycle in detail" documents PLAN's structural critique fast-path as at most 2 tasks and 3 files with no security signal, measured from the plan and never inferred from the prompt.
- EVID-012: `docs/loop-spec/ROADMAP-3.0.md:1-50` states the 3.0 semver stance (not a breaking change to user surface) and the five carried-forward design constraints, including lean deps, dual harness, deterministic predicates for autonomous decisions, and seams-not-speculation.
- ASSUMPTION: arXiv 2607.19297 (*Graph-Based Agentic AI with LangGraph: Workflow Pathways for Long-Running Stateful Business Processes*, Pearson / Shapiro / Gonzalez Venegas / Al-Khatib / Pinzón Arzola, 21 Jul 2026) presents typed shared state, graph nodes and edges, conditional routing, deterministic tools, retries, interrupts, durable checkpoints, and traces as the primitives that make long-running agentic processes inspectable, with three recipes (SQL-with-repair-loop, agentic RAG with evidence gating, HITL policy review with interrupt and checkpoint recovery). | verify: `curl -s https://arxiv.org/abs/2607.19297` from a network permitting arxiv.org, and confirm the primitive list against Sections 3-5.
- ASSUMPTION: workflowbuilder.io/blog/agentic-workflow-patterns enumerates six patterns drawn as graphs — prompt chaining, routing, parallelization, orchestrator-workers, evaluator-optimizer, human-in-the-loop — and argues production systems compose rather than choose among them. | verify: `curl -s https://www.workflowbuilder.io/blog/agentic-workflow-patterns` from a network permitting that host, and confirm the pattern list matches the table in `docs/loop-spec/gdd.md`.
- ASSUMPTION: adk.dev/graphs defines nodes as agents, functions, tools, nested workflow agents, and human-input nodes; edges as sequential chains, conditional routers with typed route matching, fan-out/fan-in, nested subgraphs, and loops; passes each node's typed return value to the next via `event.Output`; and renders the live graph with node states and traces. | verify: `curl -s https://raw.githubusercontent.com/google/adk-docs/main/docs/graphs/index.md` and confirm the node and edge taxonomies.
- ASSUMPTION: System 1 is fast, automatic, associative, and cheap but bias-prone; System 2 is slow, deliberate, effortful, and expensive; System 2 engages on novelty, stakes, and detected conflict, and acts as the monitor that can override System 1. | verify: `curl -s https://thedecisionlab.com/reference-guide/philosophy/system-1-and-system-2-thinking` from a network permitting that host.
</content>
