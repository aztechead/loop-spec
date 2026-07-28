# Claude Code Invocation Contract

How loop-spec drives Claude Code, and the places where the CLI and the Agent SDK
disagree in ways that break an unattended run. Companion to
`agent-output-contract.md`, which covers what comes back out.

Verified against Claude Code 2.1.212. loop-spec owns only the surfaces named
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

## `--permission-mode`: the CLI and the SDK are not the same set

This is the trap most likely to burn a whole unattended run, because the CLI
rejects the bad value on *every* tick and the rejection surfaces only as a
nonzero exit.

| Mode | `claude --permission-mode` | SDK `permission_mode` |
|---|---|---|
| `acceptEdits` | yes | yes |
| `auto` | yes | yes |
| `bypassPermissions` | yes | yes |
| `dontAsk` | yes | yes |
| `plan` | yes | yes |
| `manual` | **yes** | no |
| `default` | **no** | **yes** |

Copying `permission_mode="default"` out of Agent SDK code into a CLI flag is
therefore a silent, total failure. `loop.py` rejects it up front
(`LoopConfig.permission_conflict()`, exit 2) and names both the valid CLI set and
the SDK origin of the mistake. Unattended loops want `acceptEdits`.

Only the claude backend is validated — pi and opencode give special meaning to
`plan` alone and keep their own vocabulary.

## Spend

`claude -p --max-budget-usd <amount>` caps a single print-mode invocation. It is
the only CLI-level spend control; `--max-turns` does not exist on the CLI (it is
SDK-only, `ClaudeAgentOptions.max_turns`).

`loop.py --max-budget-usd` builds a loop-level cap on top of it: the summed
per-tick `total_cost_usd` is checked before each iteration and halts
`budget_exhausted`, while each tick is handed the *remaining* budget so one
runaway turn cannot overshoot between checks. `supervisor.py --max-budget-usd`
applies the cap per task; the fleet-wide worst case is that times the task count.

Unset means unbounded and passes no flag — iteration, wall-clock and stall caps
do not bound cost on their own.

## Driving loop-spec from the Python Agent SDK

`pip install claude-agent-sdk`. loop-spec is a plugin, so it must be loaded
explicitly and the settings sources that carry it must be enabled:

```python
import asyncio
from claude_agent_sdk import query, ClaudeAgentOptions

options = ClaudeAgentOptions(
    plugins=[{"type": "local", "path": "/path/to/loop-spec"}],
    setting_sources=["project"],
    permission_mode="acceptEdits",   # NOT "default" if you also shell out to the CLI
    cwd="/path/to/target/repo",
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

Set `LOOP_SPEC_NON_INTERACTIVE=1` as well if you invoke a non-autonomous entry
point, and `LOOP_SPEC_LOOP_RUNTIME=1` only if your wrapper genuinely keeps a
foreground call alive for the life of a fleet.

## Credential TTL

A long cycle can outlive a short-lived credential (GitHub App installation
tokens are typically an hour; DELIVER runs last and needs push and API access).
`LOOP_SPEC_CREDENTIAL_REFRESH_CMD` is the seam: set it to a command that re-mints
credentials and `lib/credential-refresh.sh` runs it before authenticated git and
`gh` operations, and again on a 401/403 before one retry. It is sourced by
`pr-delivery.sh` (DELIVER), `checkpoint-pr.sh`, and `pr-comments.sh`.
