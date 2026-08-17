# Claude Code Invocation Contract

How loop-spec drives Claude Code, and the places where the CLI and the Agent SDK
disagree in ways that break an unattended run. Companion to
`agent-output-contract.md`, which covers what comes back out.

Re-verified against the live Claude Code and Python Agent SDK references on
2026-07-30. loop-spec owns only the surfaces named
here; everything else about the CLI and the SDKs is Anthropic's to change.

## Execution profile: `CLAUDE_CODE_ENTRYPOINT`

Claude Code stamps `CLAUDE_CODE_ENTRYPOINT` into every process it spawns, naming
how the session was launched. Three values mean a one-shot agent invocation with
no interactive session behind it:

| Stamp | Launched by |
|---|---|
| `sdk-cli` | `claude -p` / `--print` — the CLI rewrites its own `cli` stamp to `sdk-cli` when print mode is on |
| `sdk-py` | the Claude Agent SDK for Python (`claude-agent-sdk`) |
| `sdk-ts` | the Claude Agent SDK for TypeScript |
| `cli` | the interactive TUI |

Other values exist (`mcp`, `bench`, `remote*`, `claude-desktop`,
`claude-code-github-action`, …). loop-spec treats them as neither proven headless
nor proven interactive.

`lib/harness.sh` exposes this:

```bash
bash lib/harness.sh entrypoint   # the raw stamp, or "unknown"
bash lib/harness.sh headless     # true | false — the one execution-profile answer
```

`cycle-preflight.sh` reports it once at startup as `execution:{entrypoint,headless}`,
and warns when a proven-headless invocation carries neither autonomous mode nor
`LOOP_SPEC_NON_INTERACTIVE=1` — every `AskUserQuestion` site would otherwise block
on a human who is not there.

### Why it gates the loop-fleet rung

EXECUTE's loop-fleet rung needs a persistent runtime that can hold one synchronous,
long-running tool call open. A one-shot `claude -p` job has none. Before the stamp
was read, the execution profile was only as good as the operator remembering to
export `LOOP_SPEC_NON_INTERACTIVE=1`, and an inherited
`LOOP_SPEC_EXECUTION_PROFILE=interactive` could actively claim a runtime the job
did not have — routing a headless run onto a rung it cannot execute.

Precedence in `harness.sh loop-runtime`, strongest first:

1. `LOOP_SPEC_LOOP_RUNTIME=1|0` — the integrator's explicit assertion that their
   wrapper can (or cannot) hold a foreground call open. Absolute.
2. `LOOP_SPEC_NON_INTERACTIVE=1` → no runtime.
3. **A headless entrypoint stamp** → no runtime, reason `headless/<stamp>`. This
   outranks `LOOP_SPEC_EXECUTION_PROFILE=interactive`: the stamp is a fact, the
   profile is an unverified claim.
4. `LOOP_SPEC_EXECUTION_PROFILE=interactive|headless`.
5. Nothing → `unproven-runtime`, fails safe to no loop rung.

The interactive TUI still requires the explicit `interactive` opt-in. Being at a
terminal is not by itself proof the invocation will stay alive.

## `--permission-mode`

| Mode | `claude --permission-mode` | SDK `permission_mode` |
|---|---|---|
| `acceptEdits` | yes | yes |
| `auto` | yes | yes |
| `bypassPermissions` | yes | yes |
| `dontAsk` | yes | yes |
| `plan` | yes | yes |
| `manual` | yes (CLI alias for `default`) | no |
| `default` | yes | yes |

Older Claude Code releases rejected CLI `default`; current releases accept it.
`loop.py` validates the current CLI set up front. Unattended edit-capable loops
normally want `acceptEdits`; `dontAsk` is the fail-closed choice when any
unapproved tool call should be denied instead of waiting for a human.

Only the claude backend is validated — opencode and adk give special meaning to
`plan` alone and keep their own vocabulary.

## Spend

`claude -p --max-budget-usd <amount>` caps a single print-mode invocation.
`--max-turns` separately caps agentic tool-use round trips. Both also exist in
the Python SDK as `ClaudeAgentOptions.max_budget_usd` and `max_turns`.

`loop.py --max-budget-usd` builds a loop-level cap on top of it: the summed
per-tick `total_cost_usd` is checked before each iteration and halts
`budget_exhausted`, while each tick is handed the *remaining* budget so one
runaway turn cannot overshoot between checks. `supervisor.py --max-budget-usd`
applies the cap per task; the fleet-wide worst case is that times the task count.

`--judge` calls bill to the same total and are capped at the loop's remaining
budget. With a judge configured, "verified" means verifier *and* judge, so a loop
that cannot afford the judge halts `budget_exhausted` rather than claiming a
completion it never validated — `verifier.passed` is still recorded in the result.

Unset means unbounded and passes no flag — iteration, wall-clock and stall caps
do not bound cost on their own. The per-tick cap is a claude flag; under adk and
opencode only the cumulative check applies.

## Driving loop-spec from the Python Agent SDK

`pip install claude-agent-sdk`. loop-spec is a plugin, so it must be loaded
explicitly and the settings sources that carry it must be enabled:

```python
import asyncio
from claude_agent_sdk import query, ClaudeAgentOptions

options = ClaudeAgentOptions(
    plugins=[{"type": "local", "path": "/path/to/loop-spec"}],
    setting_sources=["project"],
    permission_mode="acceptEdits",
    cwd="/path/to/target/repo",
    max_turns=80,
    max_budget_usd=20.0,
    effort="medium",
    fallback_model="haiku",
    include_partial_messages=True,
    max_buffer_size=8 * 1024 * 1024,
)

async def main():
    async for message in query(
        prompt="/loop-spec:auto add an Airline column to the Routes table",
        options=options,
    ):
        print(message)

asyncio.run(main())
```

The SDK stamps `sdk-py`, so loop-spec detects the headless profile with no extra
configuration: EXECUTE stays on the subagent rung at any DAG width and the
startup warning about absent humans is suppressed by `/loop-spec:auto` (which is
autonomous by construction).

For phase-specific models, pass
`LOOP_SPEC_PHASE_MODEL_SPEC`/`DISCUSS`/`PLAN`/`EXECUTE`/`VERIFY`/`ITERATE`/`DELIVER`
through `ClaudeAgentOptions.env`. loop-spec activates each phase value on every
subagent and gate launch. To move the main SDK query between those models too,
set `LOOP_SPEC_PHASE_HANDOFF=1` and construct a fresh `ClaudeAgentOptions` for
each paused handoff with `model` set to the next phase alias. The complete,
bounded controller is in
[`cloud-run-autonomous.md`](cloud-run-autonomous.md); a continuous `query()`
cannot change its already-running main model.

Set `LOOP_SPEC_NON_INTERACTIVE=1` as well if you invoke a non-autonomous entry
point, and `LOOP_SPEC_LOOP_RUNTIME=1` only if your wrapper genuinely keeps a
foreground call alive for the life of a fleet.

For resource-constrained or ephemeral Cloud Run jobs of any configured size, use
the parameterized wrapper, signal/reconciliation contract, and example policy in
`docs/loop-spec/cloud-run-autonomous.md`.

## Credential TTL

A long cycle can outlive a short-lived credential (GitHub App installation
tokens are typically an hour; DELIVER runs last and needs push and API access).
`LOOP_SPEC_CREDENTIAL_REFRESH_CMD` is the seam: set it to a command that re-mints
credentials and `lib/credential-refresh.sh` runs it before authenticated git and
`gh` operations, and again on a 401/403 before one retry. It is sourced by
`pr-delivery.sh` (DELIVER), `checkpoint-pr.sh`, and `pr-comments.sh`.
