# Agent Output Compatibility Contract

loop-spec owns two machine-readable outputs: terminal cycle results and the normalized
headless-agent result consumed by the bundled loop runner. It does not own the complete
Claude Code, pi, or OpenCode CLI event protocols.

## Terminal Cycle Result

Every full, micro, and debug terminal path emits one line:

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

Compatibility fields present for every cycle type:

```json
{
  "schema": 1,
  "cycleType": "full | micro | debug",
  "slug": "string or null",
  "status": "completed | paused | escalated | terminal | failed",
  "outcome": "cycle-specific string",
  "reason": "string or null",
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
unit, not a claim that Claude turns, pi `turn_end` events, and OpenCode `step_finish`
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

### pi

loop-spec consumes newline-delimited JSON from `pi --mode json`:

- first object `id` as the session id;
- `turn_end` count as turns;
- the last assistant `message_end.message.content` text as the result;
- numeric `message_end.message.usage.cost.total` as cost.

Unknown and malformed lines are ignored. This is the observed compatibility profile,
not pi's complete session schema.

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
