# Graph-driven development (GDD)

loop-spec 3.0 expresses the cycle as a typed, checkpointed, distributable graph.
Control flow is declared data under `graph/` and executed by `lib/graph/run.sh`.
It is not a derived map of the codebase.

## Pattern bindings

The source vocabulary is one building block (the tool-using agent) plus five
recurring **patterns** — chaining, routing, parallelization, reflection, and
human-in-the-loop (EVID-018). Orchestrator-workers is a run-time variant of
parallelization, not a sixth pattern.

The **shapes** each pattern binds to below — `chain`, `route`, `fanout`,
`fanin`, `loop`, `gate`, `human` — are loop-spec's own graph vocabulary, not
the source's. The source names the five patterns; it does not name these
edge/node kinds, and `gate` in particular has no counterpart in any supplied
source as a formal node kind (see `docs/loop-spec/features/gdd/SPEC.md` §1).
Only the left column below is source-derived; the middle and right columns
are how loop-spec expresses and already realizes each pattern.

| Pattern (source) | Graph shape (loop-spec) | Realized today by |
|---|---|---|
| Prompt chaining | `chain` edges | SPEC → DISCUSS → PLAN → EXECUTE → VERIFY → ITERATE → DELIVER |
| Routing | `route` edges | `skills/auto/` + `lib/task-route.sh` (micro / debug / full) |
| Parallelization | `fanout` + `fanin` | EXECUTE's DAG waves; the five `mapper-*` agents |
| Reflection | bounded `loop` around a `gate` | critique gates, spec-compliance review, ITERATE's judge |
| Human-in-the-loop | `human` node | `step` / `interactive` styles, the ambiguity gate, checkpoint PRs |

## Why this is not graphify

Graphify was a **derived map of the codebase** — generated, stored, and consulted
as authority. It was mandatory from 2.29 and removed in 2.35 on measured evidence
recorded in `CLAUDE.md`: across every feature authored while it was required it
produced zero citations, zero recorded refreshes, and zero evidence entries,
while costing a Python 3.10+/uv dependency and a cycle-aborting startup gate.
Stored maps rot, and a rotted map is wrong with authority.

The workflow graph is a **declared contract the engine executes**. It describes
no external subject that can drift; it *is* the control flow. A wrong edge
breaks the next run at the node that took it. The rot failure mode is
structurally unavailable. Structure is still read fresh from the tree when a
phase needs it, citing `file:line`.

## Source corrections that shaped the design

1. **Reflection is a cycle a DAG engine will not run** (EVID-019). A literal
   back-edge deadlocks: each node waits on the other. Iteration is expressed
   only as a bounded `loop` edge (`unroll` or `contain`).
2. **"System 1 creates bias, System 2 fixes it" is a misconception**
   (EVID-023). Both modes are bias-prone; effort is not a correctness oracle.
   Deliberation wakes on surprise (EVID-024) via `lib/conflict-monitor.sh`.

Primary sources are cited by EVID id from
`docs/loop-spec/features/gdd/EVIDENCE.md` (user-supplied archives of
arXiv 2607.19297, workflowbuilder.io, ADK graphs, The Decision Lab — not live
fetches).

## Contracts

| Contract | Enforcer |
|---|---|
| `skills/shared/graph-contract.md` | `lib/graph/validate.sh`, `tests/graph-conformance.test.sh` |
| `skills/shared/dual-process.md` | `lib/effort-probe.sh`, `lib/conflict-monitor.sh` |
| `skills/shared/handoff-port.md` | `tests/lib/graph-port-contract.test.sh` |

## Rejected alternatives

| Alternative | Why rejected |
|---|---|
| Regenerating the graph from skills | Reintroduces derive-and-rot |
| Opt-in flag with prose fallback | Dual maintenance; unexercised path decays |
| Model-evaluated route conditions | Unreproducible; violates probes-not-judgments |
| Separate state store per node | Forks the resume contract |
| Mandating a git-backed transport | User declined to fix the transport |
| Free cycles among chain/route/fanout/fanin | Documented deadlock (EVID-019) |
