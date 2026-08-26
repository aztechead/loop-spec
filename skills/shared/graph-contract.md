# Graph contract (nodes, edges, state, and the harness seam) — canonical vocabulary

Single source of truth for the loop-spec workflow-graph vocabulary: what a declaration
under `graph/` may contain, what each construct means, and who enforces each rule. The
vocabulary is declared once in `graph/schema.json` and pinned by
`tests/lib/graph-schema.test.sh`; `lib/graph/validate.sh` applies it to a graph file
along with the referential rules below, mirroring the `lib/artifact-lint.sh` output
contract — one `FLAG <file>:<pointer>: <message>` per defect, exit 0 clean / 1 flagged /
2 bad invocation — and is exercised by `tests/lib/graph-validate.test.sh`.
`tests/graph-conformance.test.sh` asserts the shipped skills and
`graph/cycle.graph.json` agree on topology. Graph JSON is data only — never executable,
never templated at runtime. No rule in this document is documentation-only: every rule
names the script or test that enforces it.

## Node kinds

Five kinds, a closed enum: `agent`, `function`, `gate`, `human`, `subgraph`. An unknown
kind is a `FLAG` from `lib/graph/validate.sh`; the enum itself is pinned by
`tests/lib/graph-schema.test.sh`. A step earns a node by the boundary test — it would be
useful in an audit log, a retry rule, or a dashboard. Anything below that bar stays
inside a node body.

Every shipped node also has a concise `label` for people reading dry runs, traces, and
future visualizations. IDs remain the stable machine keys; labels may improve without
breaking checkpoints or edge references. The schema permits labels and
`tests/graph-conformance.test.sh` requires them on the shipped graphs.

1. **`agent`.** Dispatches a role through the harness: the body names a skill
   (`skills/plan/SKILL.md`) or a namespaced subagent (`loop-spec:implementer`). The body
   performs the craft; the graph owns what happens before and after it, so an agent node
   never decides its own successor. The kind is enforced by `lib/graph/validate.sh`, and
   the presence of the seven phase agent nodes is asserted by
   `tests/graph-conformance.test.sh`.
2. **`function`.** Runs a deterministic `lib/` script — `execute.join` running
   `lib/integrate-task.sh`, `completed` running `lib/cycle-result.sh`. No model judgment
   selects a code path inside a function body; that is the probes-not-judgments law from
   `CLAUDE.md` applied to graph vocabulary. The kind is enforced by
   `lib/graph/validate.sh`; each body is an ordinary `lib/` script with its own unit
   test.
3. **`gate`.** Runs a probe and admits or blocks — the marker scan, the tamper scan, the
   acceptance lint, code review. A gate that is unnecessary for a given run is ROUTED
   AROUND, never marked skippable: `route` skips the node, works for every node kind, and
   shows up in a dry run, whereas the `skippable` field this vocabulary carried through
   4.0 skipped only a `.sh` BODY and was never evaluated by the engine. The only shipped
   declaration was `plan.critique.gate`, whose body is a fast-path token rather than a
   script — so it skipped nothing, invisibly. One mechanism for "do not run this", not
   two. `tests/lib/graph-schema.test.sh` pins the field absent from the schema;
   `tests/lib/graph-run.test.sh` section 20 pins it absent from `graph/cycle.graph.json`.
4. **`human`.** Interrupts and waits for a person — the `step` style's inter-phase
   pause, ITERATE's spec-change approval. A human node is a real stop: a checkpoint is
   written to the node ledger by `lib/graph/checkpoint.sh` (covered by
   `tests/lib/graph-checkpoint.test.sh`), a resumable pause record is emitted, and any
   later invocation resumes at exactly that node — resume is a lookup, not a
   scan-and-infer procedure.
5. **`subgraph`.** Nests another graph file via its `graph` path so a protocol is
   declared once and reused — the critique protocol lives in
   `graph/critique.graph.json` and is referenced by both `discuss.critique` and
   `plan.critique`, never duplicated. The nested file must itself pass
   `lib/graph/validate.sh`; the single-declaration reuse is asserted by
   `tests/graph-conformance.test.sh`.

## Edge kinds

Five kinds, a closed enum pinned by `tests/lib/graph-schema.test.sh`: `chain`, `route`,
`fanout`, `fanin`, `loop`. Every edge endpoint must name a declared node and every node
must be reachable from `entry` — both `FLAG`s from `lib/graph/validate.sh`.

1. **`chain`.** Unconditional succession: when the source completes, the target runs.
   Chains carry the happy path of the cycle (spec through deliver). Together with
   `route`, `fanout`, and `fanin`, chains must form a DAG — the Kahn check in
   `lib/graph/validate.sh` flags any cycle among the four acyclic kinds, with a
   back-edge negative case in `tests/lib/graph-validate.test.sh`.
2. **`route`.** Conditional succession: the edge is taken only when its
   `{probe, expects}` condition holds (see the route-condition rule below). Routes carry
   every branch the prose used to own — ITERATE's three gap-class rewinds, DELIVER's
   CI-failure re-entry. Shape and probe executability are enforced by
   `lib/graph/validate.sh`.
3. **`fanout`.** One-to-many dispatch: one source, N parallel instances of the target —
   EXECUTE's task waves, `execute` fanning out to `execute.worker`. The same declaration
   serves width 1 and width N; width selects an execution rung via
   `lib/execute-rung.sh`, it never edits the topology. The execute node body already
   runs the selected rung to completion (inline, subagent, loop, team, workflow), so
   walking the fanout afterward would dispatch `loop-spec:implementer` against an
   empty `mergeQueue`. `lib/graph/probes/execute-fanout.sh` admits the fanout only
   when `mergeQueue` still has work; otherwise the engine routes to
   `human.after-execute`. The execute node declares `routeDefault` to that same
   skip target, so an unresolved probe cannot abort the cycle the way DELIVER's
   missing sidecar used to. The EXECUTE fanout/fanin pairing is asserted by
   `tests/graph-conformance.test.sh`.
4. **`fanin`.** Many-to-one join: the target runs once after the fanned-out instances
   return, merged under a declared `join` rule (`merge-queue` for EXECUTE). A `fanin`
   without a `join` is a `FLAG` from `lib/graph/validate.sh`, required by the
   `graph/schema.json` conditional and pinned in `tests/lib/graph-schema.test.sh`.
5. **`loop`.** The only legal form of iteration: a numeric `ceiling > 0` and a
   `strategy` of `unroll` (re-dispatch the target segment each pass) or `contain` (the
   iteration runs inside a single node's body). Both fields are required by the
   `graph/schema.json` conditional and enforced by `lib/graph/validate.sh`, so unbounded
   iteration is not representable. A `route` back-edge is tolerated by the DAG check
   only when its source also declares a bounded `loop` edge — that is the declared form
   of ITERATE/DELIVER re-entry; an uncovered back-edge still `FLAG`s.

## Path-length rule

A graph declares ONE topology and more than one path through it. The cycle graph's long
path walks every phase; its short path is the same graph with `discuss`, the spec
critique, and the `verify.code-review` agent routed around, selected by
`lib/graph/probes/short-path.sh` (maintenance
execution profile AND no security signal in the artifacts the run has written so far).
This is where run length becomes a declared, auditable property instead of prose inside
a phase body.

Three rules keep a short path honest, all enforced:

1. **Same graph, same continuity.** A short path is routing, never a second graph and
   never a different protocol. The checkpoint ledger, the state contract, and the
   terminal result are identical; `tests/lib/graph-run.test.sh` section 20 asserts the
   short path still visits every remaining phase and `completed`, and that PLAN critique
   remains a `plan-critique.sh` decision (`plan.critique.gate` is still on the path).
2. **The long path is the default.** Every bypass route is paired with a route to the
   long path, and the branching node declares `routeDefault` to the long path, so an
   unresolved probe lengthens the run rather than stranding it.
   `tests/lib/graph-run.test.sh` section 20 asserts that pairing on every short-path
   branch in `graph/cycle.graph.json`.
3. **The evidence is re-read, not remembered.** `short-path.sh` re-runs the security
   signal over the artifacts that exist NOW, because SPEC and DISCUSS author them after
   the profile was chosen. A change that turns out to touch a security surface lengthens
   its own path mid-run. `tests/lib/graph-probes.test.sh` pins a written security
   artifact forcing `path=full`.

## Route-condition rule

A route condition is a probe path and an expected answer token — never prose. This is
the graph form of the probes-not-judgments law in `CLAUDE.md`: an edge is a script, an
expected value, and a unit test, so a consequential branch never depends on how a model
read a document that day. `lib/graph/validate.sh` is the enforcer: it flags a condition
that is not a `{probe, expects}` object, a condition carrying extra keys, and a probe
path that does not exist or is not executable, each exercised by
`tests/lib/graph-validate.test.sh`. The shape itself is closed by
`graph/schema.json` (`routeCondition` with `additionalProperties: false`), pinned by
`tests/lib/graph-schema.test.sh`.

## Body-argument rule

A `function` or `gate` node whose body is a `lib/` script may declare `bodyArgs`, the
argument vector the engine passes it. The engine substitutes a closed placeholder set —
`{featureDir}`, `{repoRoot}`, `{featureRepoRoot}`, `{slug}`, `{node}`, `{baseSha}` — and
nothing else; `lib/graph/validate.sh` flags an unknown placeholder, a non-array
`bodyArgs`, and `bodyArgs` on any node that is not a function/gate with a `.sh` body,
each exercised in `tests/lib/graph-validate.test.sh`. A placeholder that resolves EMPTY
is a dispatch failure carrying its own reason, never an empty argument handed to the
script: a body invoked without the arguments it requires exits on a usage error, and a
gate reads that as a finding. `tests/lib/graph-gate-dispatch.test.sh` runs each shipped
VERIFY gate through this path, on the node declarations read out of
`graph/cycle.graph.json` rather than a copy.

`{repoRoot}` is the loop-spec install; `{featureRepoRoot}` is the git repository holding
the feature. They are the same directory only when self-hosting, so a body that reads the
PROJECT tree takes `{featureRepoRoot}`.

## State declaration rule

Every node declares `reads[]` and `writes[]` from the `stateKey` enum in
`graph/schema.json` — a subset of the `feature.json` schema v7 key space in
`skills/shared/feature-state-schema.md`. Statically, `lib/graph/validate.sh` flags a key
outside the enum and a read key that no node writes and no feature-init skeleton seeds.
At runtime, `lib/graph/state.sh` is the typed channel: a write to a key absent from the
node's `writes[]` fails and writes nothing, and entering a node with a declared read
absent or null fails. In workspace mode the schema relocates `branch`, `baseSha`, and
`baseBranch` onto `workspace.repos[]` and leaves the top-level keys null; `assert-reads`
treats those per-repo values as the read. No other key is relocated — a null one still
fails in both modes, and `optionalReads[]` below remains the way to declare a key the
schema lets be null. Covered by `tests/lib/graph-state.test.sh`.

A node may also declare `optionalReads[]`: keys it consults that are legitimately absent
or null because the schema documents an opt-out for them. `verificationBaseline` is the
case that forced the rule — the startup baseline is opt-in, so with it disabled the key
is null BY DESIGN, and asserting it made the VERIFY node capture a baseline mid-phase to
satisfy a contract that was never meant to bind. Entering the node never asserts an
optional read; the body owns the null case. The producer/consumer rule still applies, and
a key declared in both `reads` and `optionalReads` is a `FLAG` — the two lists say
different things about the same key. Accepted writes
delegate to `lib/feature-write.sh`, so the atomic write, `.bak` rotation, and the
committed resume contract from `skills/shared/feature-state-schema.md` are unchanged;
the ban on raw `jq`/`python3` mutation applies to node bodies verbatim.

## Harness-neutrality invariant

Nothing under `lib/graph/` branches on the harness: no `lib/harness.sh` call, no
entrypoint probe, no per-harness case. Only node *bodies* adapt, through
`lib/harness.sh`, under the additive-branch contract of
`skills/shared/opencode-harness.md`, `skills/shared/adk-harness.md`, and
`skills/shared/codex-harness.md`. The
enforcers are the coupling pins
`tests/opencode-harness-coverage.test.sh`, `tests/adk-harness-coverage.test.sh`,
and `tests/codex-harness-coverage.test.sh`: every
legitimate `lib/harness.sh` coupling is enumerated there, and a `lib/graph/` file
appearing in that inventory is a contract violation to reject in review, never a pin to
add.

The step descriptor is model-neutral:
`{node,label,kind,body,effort,nextEdge,terminal,paused}`. Model selection belongs to the
dispatch adapter, not the control-flow engine. This keeps the same graph executable
under Claude Code, OpenCode, ADK, and Codex even when their model registries differ.

## Effort declaration

Every node declares a default `effort` of `system1` or `system2` — required by
`graph/schema.json` and pinned by `tests/lib/graph-schema.test.sh`. A
delivery-authorizing node may not default to `system1`; `lib/graph/validate.sh` flags
it. Runtime escalation between the two modes is the dual-process contract: the
deterministic per-node answer comes from `lib/effort-probe.sh`, and the canonical
contract is `skills/shared/dual-process.md`.
