# GDD remediation contract

Binding interface between the declaration layer (`graph/*.json`, `lib/graph/validate.sh`,
`lib/graph/probes/*.sh`) and the engine (`lib/graph/run.sh`). Both sides are repaired
independently and must agree here. Written after a critique found the shipped 3.0 engine
silently skipping the PLAN critique gate and losing ITERATE's rewind entirely.

## 1. Route conditions

A `route` edge condition is:

```json
"condition": {
  "probe": "lib/graph/probes/iterate-gap.sh",
  "args": ["--feature-dir", "{featureDir}"],
  "expects": "gap=execute"
}
```

- `args` is REQUIRED (may be `[]`). The engine substitutes `{featureDir}`, `{repoRoot}`,
  `{slug}`, `{node}` in each element. No other placeholder is legal.
- The engine runs `bash <probe> <args...>` with `cwd = repoRoot`.

## 2. Probe answer contract

Every route probe:

- Exits **0** on a resolved answer and prints **exactly one line** to stdout of the shape
  `<key>=<value> reason=<text>`. This is the house probe shape (`lib/security-signal.sh`).
- Exits non-zero, or prints nothing, when it cannot resolve an answer.
- Supports a `--answers` verb printing its complete answer-token set, one `<key>=<value>`
  per line, exit 0. This is what makes `expects` checkable at validate time.

**Match rule: the probe's first whitespace-delimited token must equal `expects` exactly.**
No substring matching. No alternation inside `expects` — `style=step|interactive` is
illegal; declare two edges.

## 3. Unresolved is never satisfied (fail closed)

A condition is UNRESOLVED when the probe is missing, exits non-zero, prints nothing, or
prints a first token outside its declared answer set.

- An unresolved condition NEVER satisfies its edge. `expects: "none"` is an ordinary
  token like any other and is satisfied only by a successful probe whose first token is
  literally the expected one.
- If a node has route edges and none is satisfied, the engine **aborts** with exit 5 and a
  diagnostic naming the node and every probe result. It MUST NOT fall through to a `chain`
  edge. Silent fallthrough is the defect this contract exists to prevent.
- A node may declare `"routeDefault": "<nodeId>"` to make the no-route case explicit and
  legal. Absent that field, no-route is an abort.

## 4. Human nodes

A `human` node carries an `admit` object of the same shape as a condition:

```json
{ "id": "human.after-spec", "kind": "human",
  "admit": { "probe": "lib/graph/probes/exec-style.sh",
             "args": ["--feature-dir", "{featureDir}"], "expects": "style=step" } }
```

- Evaluated on entry. Admitted → write a checkpoint, write the pause record, exit 4.
- Not admitted → the node is **skipped**; traversal continues to its successor in the same
  run. An unresolved `admit` skips the node (a human gate must not deadlock an unattended
  run; the gates that must never be skipped are `gate` nodes, not `human` nodes).
- `execStyle: auto` and `review-only` must traverse the whole graph without pausing at any
  `human` node.

## 5. Resume

`lib/graph/run.sh --resume` resolves its start node in this order:

1. A pause record present → start at the **successor** of the paused node, and delete the
   pause record. Re-entering the paused node is the deadlock this replaces.
2. Else a non-empty checkpoint ledger → start at the successor of the last checkpointed node.
3. Else `feature.json.currentPhase` is set and names a declared node → start there.
   **This is the pre-3.0 compatibility path**: a feature created before the ledger existed
   must resume where its committed state says, never at the graph's start node.
4. Else the graph's start node.

The engine MUST NOT write `currentPhase` before it has resolved the start node.

## 6. Node dispatch

`lib/graph/run.sh --step` runs at most one node and returns a JSON dispatch descriptor on
stdout: `{node, kind, body, model, effort, nextEdge}`. The cycle skill drives `agent` nodes
by dispatching `body` itself and calling `--step` again. Without `--step` the engine runs to
the next pause or terminal node, dispatching only what it can execute in-process
(`function` and `gate` bodies).

`gate` nodes ARE dispatched: a gate body is a script whose non-zero exit blocks the phase.
`subgraph` nodes execute their nested graph for real, not as a dry run.

## 7. State, effort, conflict, trace

The engine MUST call the components the spec promised:

- `lib/graph/state.sh assert-reads` on node entry; `state.sh write` for every state write.
- `lib/effort-probe.sh` to compute the runtime effort mode. The declared `node.effort` is a
  DEFAULT the probe may raise; the probe's answer is what gets traced and dispatched.
- `lib/conflict-monitor.sh` after a node whose body reports failure; a `conflict=yes` raises
  that node's next attempt to `system2` and is recorded.
- `lib/graph/trace.sh` with the REAL probe token and reason for the edge taken, never the
  literal `probe="none"`.

## 8. Terminal result

The `completed` node must invoke `lib/cycle-result.sh` with its real arguments so
`.loop-spec/last-result.json` is published. The engine must not hand-build a result object
that a canonical constructor already owns.

## 9. Acyclicity carve-out

`chain`, `route`, `fanout`, `fanin` must form a DAG, with one exemption: a `route` back-edge
is legal only when **that exact (from,to) pair** also carries a bounded `loop` edge with its
own ceiling. Keying the exemption on the source node alone (as shipped) exempts every route
from that node and lets a real cycle validate.

## 10. Non-negotiable

- Runtime stays `bash >= 4`, `git`, `jq >= 1.5`, `python3 >= 3.7`. No new dependency.
- Nothing under `lib/graph/` branches on the harness.
- Every behavior above lands with a test that FAILS when the behavior is removed. A test
  that passes against a broken implementation is worse than no test — that is how the
  shipped engine passed 154 suites with its critique gate disabled.
</content>
