# Agent Output Compatibility Contract

loop-spec owns two machine-readable outputs: terminal cycle results and the normalized
headless-agent result consumed by the bundled loop runner. It does not own the complete
Claude Code, OpenCode, or Google ADK CLI event protocols.

## Terminal Cycle Result

Every full, micro, and debug terminal path, plus standalone forensics, assessment, and
retrospective diagnostics, emits one line:

```text
LOOP_SPEC_RESULT {"schema":1,...}
```

The same JSON object is atomically copied to the control checkout at:

```text
.loop-spec/last-result.json
```

Entry points resolve linked worktrees to the control checkout and clear this pointer
before starting. They fail loudly rather than following a symlinked `.loop-spec` or
leaving a pointer they could not remove. Its absence means the current run did not reach
a terminal emission; callers must never reuse an older successful result.

**Every routed run publishes one.** `/loop-spec:auto` arms the run at routing time
(`.loop-spec/active-run.json`, git-ignored), and only a published terminal result
disarms it, so leaving a protocol without emitting one is detectable rather than
silent: `lib/cycle-result.sh state` reports `published | unaccounted | idle` for a
root, `hooks/team/route-terminal-guard.sh` refuses to end an autonomous session whose
armed run published nothing, and `lib/cycle-reconcile.sh` converts a surviving armed
run into a terminal result. A route that judges its protocol a poor fit reports that
(`outcome: "protocol-mismatch"`, below) instead of completing the task off-protocol.
Full contract: `skills/shared/route-exit-contract.md`.

`loopSpecVersion` is the version that produced the run (`"unknown"` when the
manifest is unreadable). It is what lets a consumer date a result: a report from an
unattended harness is otherwise impossible to check against the version that fixed
the behavior it describes, and findings arrive already stale with no way to tell.
The same field is stamped into every `docs/loop-spec/telemetry/runs/{slug}.json`
digest. Both are additive — consumers read every field with a default, so older
artifacts without it stay valid and the schema numbers do not change.

Compatibility fields present for every cycle type. New writers require a non-empty
`summary`; consumers still tolerate older schema-1 records where the additive field is
absent:

```json
{
  "schema": 1,
  "loopSpecVersion": "2.25.0",
  "cycleType": "full | micro | debug | diagnostic",
  "slug": "string or null",
  "status": "completed | paused | escalated | terminal | failed",
  "outcome": "cycle-specific string",
  "reason": "string or null",
  "summary": "non-empty concise terminal synthesis",
  "noChangeReason": "already-satisfied | diagnostic-only | null",
  "phaseReached": "string or null",
  "branch": "string or null",
  "baseBranch": "string or null",
  "prUrl": "string or null",
  "checkpointPrUrl": "string or null",
  "delivery": "object or null",
  "converged": true,
  "iterations": {"used": 0, "max": null},
  "warnings": [],
  "autonomous": true,
  "feature_title": "string",
  "createdAt": "ISO-8601 string or null",
  "finishedAt": "ISO-8601 string",
  "verification": {"status": "passed | failed | not-run", "command": "string or null"}
}
```

Full-cycle per-feature `result.json` remains available. `last-result.json` is a copied
record, not a symlink into a disposable Claude worktree.

`summary` is the conclusion a human should see without scraping streamed output or
opening workflow artifacts: the finding for a no-change/diagnostic run, the change and
verification synthesis for delivered work, or the stopping condition for a failed,
paused, or escalated run. `reason` remains the failure/pause detail and does not carry
intentional no-change semantics.

`noChangeReason` is null unless no implementation PR was intentional:

- `already-satisfied`: the requested end state was present. Full cycles require a
  converged ITERATE verdict, its passed deterministic floor, no unresolved iteration
  warnings, plus `no_commits`/`skipped-no-commits` evidence for every delivery target;
  micro/debug must have grounded and validated the unchanged baseline.
- `diagnostic-only`: the invocation was explicitly read-only/reporting. It means no
  implementation was requested, not that the diagnostic found no problems.

Two outcomes belong to every cycle type rather than to one:

- `protocol-mismatch`: the routed protocol does not fit the request. It requires
  `status: "escalated"`, `converged: false`, a non-empty `reason` naming the mismatch,
  and an unmodified tracked tree — a route that already changed the repository reports
  what it did instead. The caller's move is to re-route the request, not to retry it.
- `interrupted`: the run stopped before it could finish. It requires `status: "failed"`
  and is what `lib/cycle-reconcile.sh` writes for an armed run whose process is gone.

Both successful cases use `status: "completed"`, `outcome: "no-change-needed"`,
`converged: true`, `prUrl: null`, and `checkpointPrUrl: null`. Zero commits without one of these explicit,
validated declarations remains failed/escalated, so inability to progress cannot look
like a successful no-change conclusion.

Full-cycle results add these schema-1 fields:

```json
{
  "implementationConverged": true,
  "eligibleTargets": [{"branch":"feat/example","targetSha":"..."}],
  "retryable": false,
  "retryPhase": null,
  "verifiedSha": "immutable single-repository delivery target SHA or null"
}
```

`converged` retains end-to-end meaning, including an explicitly validated no-change
conclusion. A full cycle that completed implementation and
verification but hit a SHA-bound delivery failure (`delivery.json.nextPhase ==
"deliver"`) reports `status: "failed"`, `outcome: "delivery-blocked"`,
`phaseReached: "deliver"`, `implementationConverged: true`, `converged: false`, passed
verification, and a retry at `deliver`. In single-repository mode, `branch` and
`verifiedSha` come from that delivery target. In workspace mode, top-level `branch` and
`verifiedSha` remain null and `eligibleTargets[]` retains each SHA-bound repository's
branch and `targetSha`. A delivery `nextPhase` of `execute` is a remediation rewind, not a terminal
delivery block.

## Phase Boundary Markers

`lib/events.sh` continues to append the existing JSONL event shape. `phase_start` and
`phase_end` add fields and also print one greppable line. A full cycle's boundaries are
emitted by `lib/graph/run.sh` at node transitions — not by cycle-skill prose the agent
can skip — so a run that `--step`s the graph and then works inline still surfaces them.
`--step` keeps its JSON descriptor on stdout; the greppable lines share stderr with the
`[PHASE]` console line so a `step_json=$(run.sh --step)` capture cannot trap them.
micro and debug still emit from their skills.

```text
LOOP_SPEC_PHASE_START {"event":"phase_start","attemptId":"...","timestamp":"...",...}
LOOP_SPEC_PHASE_END {"event":"phase_end","attemptId":"...","timestamp":"...","elapsedSeconds":4,"verdict":"advanced","next":"verify",...}
```

The fixed phase-end verdicts are `advanced`, `rewind`, `blocked`, and `completed`.
`data.next` remains present for compatibility; `next` is its phase-marker projection.
Attempt pairing is maintained in an ignored local sidecar, so phase callers do not pass
or remember attempt IDs. Generic events retain their original JSONL shape and print no
marker.

## Headless Agent Normalization

`skills/loop-runner/scripts/loop.py` normalizes successful backend responses to:

```json
{
  "ok": true,
  "error": null,
  "turns": 3,
  "session_id": "string or null",
  "result": "final assistant text",
  "cost_usd": 1.25
}
```

`cost_usd` is `null` when the backend does not report cost. `turns` is a backend-derived
unit, not a claim that Claude turns, ADK text events, and OpenCode `step_finish`
events are semantically identical.

## Observed Backend Profiles

These profiles document only fields loop-spec consumes. They are not official or
complete upstream schemas. Unknown fields and events may be added by the provider.

### Claude Code

loop-spec invokes `claude -p --output-format json`, not `stream-json`. It consumes one
terminal JSON object and reads only:

```json
{
  "is_error": false,
  "subtype": "success",
  "num_turns": 3,
  "session_id": "string",
  "result": "final assistant text",
  "total_cost_usd": 1.25
}
```

An external renderer using Claude Code `--output-format stream-json` is consuming an
Anthropic-owned protocol outside loop-spec's compatibility boundary. In observed
versions, assistant messages may contain `text` and `tool_use` content blocks, user
messages may contain `tool_result` blocks, and a terminal `result` event carries the
final status/result fields. Those shapes can change with Claude Code; use Anthropic's
current headless/Agent SDK documentation and tolerate unknown event and content types.

### Google ADK

loop-spec consumes newline-delimited JSON from `adk run <agent-dir> --jsonl`:

- first object `session_id` as the session id;
- the count of non-`user`-authored events carrying text as turns;
- the last such event's `content.parts[].text` as the result;
- `error_code` / `error_message` on any event as the failure reason;
- NO cost: ADK reports `usage_metadata` token counts, not money, so `cost_usd`
  stays `None` — "unknown", never "free". A `--max-budget-usd` cap cannot bind here.

Unknown and malformed lines are ignored. This is the observed compatibility profile,
not ADK's complete Event schema.

### OpenCode

loop-spec consumes newline-delimited JSON from `opencode run --format json`:

- first object `sessionID` as the session id;
- `step_finish` count and `part.cost`;
- the last nonblank `text.part.text` as the result;
- `error.error` when no result text was produced.

Tool, reasoning, token, and other events are outside the normalized contract.

## Versioning Policy

Changes to `LOOP_SPEC_RESULT` or the compatibility keys above require a schema bump or
an additive field. Backend parser changes must keep the normalized shape stable and add
synthetic fixture coverage; raw live transcripts must not be committed because they can
contain prompts, tool inputs, source code, and secrets.
