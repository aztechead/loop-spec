# Claude Code harness adaptation (reference)

Applies when loop-spec runs under **Claude Code**, including the **Claude Agent
SDK** for Python and TypeScript: `bash
"${CLAUDE_SKILL_DIR}/../../lib/harness.sh" detect` prints `claude` (equivalently,
`cycle-preflight.sh` reports `harness.name == "claude"` /
`.loop-spec/runtime.json.harness == "claude"`). loop-spec installs there as a
Claude Code plugin (`.claude-plugin/plugin.json`).

This file exists so that Claude Code is DESCRIBED rather than assumed. The other
three contracts (`opencode-harness.md`, `adk-harness.md`, `codex-harness.md`)
used to read as deviations from an unstated norm; they are peers, and the
norm needed writing down. Nothing here is new behavior — it is the surface
every skill was already written against.

## Detection

Claude Code's Bash tool sets `CLAUDECODE=1`, which is the positive signal.
`claude` is also the back-compat DEFAULT when no harness signal is present at
all, because every install predating the multi-harness seam is a Claude Code
plugin. Unknown override values still resolve here for compatibility. The
retired explicit value `LOOP_SPEC_HARNESS=pi` is the exception: it exits with a
migration error rather than silently running a different harness. A stale
`PI_CODING_AGENT_DIR` alone remains ignored so it cannot disable Claude Code
capabilities.

## Environment contract (who sets what)

Claude Code supplies `CLAUDE_PROJECT_DIR`, `CLAUDE_SKILL_DIR` (the documented
skill substitution), and `CLAUDE_PLUGIN_ROOT` itself — no bridge is needed, which
is the one structural advantage this harness has over the other two.

`CLAUDE_SKILL_DIR` is correct in skill Bash; `CLAUDE_PLUGIN_ROOT` is a
hooks/MCP variable and is EMPTY in skill Bash. A skill at `skills/<name>/`
reaches shared code as `${CLAUDE_SKILL_DIR}/../../lib/...`. This is the rule the
other harnesses' bridges exist to reproduce.

## Tool surface

The full surface, and the only harness where all of it exists:
`Read`/`Write`/`Edit`/`Bash`/`Glob`/`Grep`, `Skill`, `Agent`, `AskUserQuestion`,
`TaskCreate`/`TaskUpdate`/`TaskList`/`TaskGet`, `Workflow`, `SendMessage` and the
team primitives, `EnterWorktree`/`ExitWorktree`, and `ToolSearch` for
deferred-tool rescue. Exact parameter schemas — which are live-verified and NOT
inferred from prose — live in `skills/shared/dispatch.md`.

Four of those are Claude Code-only today. They are NOT the default path other
harnesses fall short of; each is gated by a probe that answers for every harness
and fails safe:

| Capability | Probe | Answer elsewhere |
|---|---|---|
| Agent teams | `lib/teams-capability.sh` | `none` |
| `Workflow` | `lib/workflow-availability.sh` | `false` |
| One-shot dispatch | `lib/harness.sh subagents` | `true` on all three (different tools, one call shape) |
| Worktree execution root | `feature.json.executionRootMode` | `in-place` |

A probe answering "absent" is a fact about a harness, and an operator override
may turn a capability OFF anywhere but never conjure one that is not there —
`LOOP_SPEC_HARNESS=adk LOOP_SPEC_TEAMS_MODE=implicit` still answers `none`.

## Ambient verification enforcement

Claude Code is the only harness with a vetoable `Stop` event, so it is the only
one where ambient enforcement can BLOCK rather than merely instruct:
`hooks/hooks.json` wires `SessionStart`, `UserPromptSubmit`, `PreToolUse`,
`PostToolUse`, `Stop`, `TaskCompleted`, and `TeammateIdle`, and
`hooks/team/adhoc-verify-guard.sh` plus `route-terminal-guard.sh` can refuse a
termination.

Do not read that as the other harnesses being broken. The deterministic gates
(`lib/verification-grounding-lint.sh`, `lib/cycle-reconcile.sh`) hold the same
contracts everywhere, and running `cycle-reconcile.sh` on every route is required
on all three — it is simply the ONLY enforcement on opencode and ADK.

## Model routing

Per-dispatch models use the `Agent` tool's ALIAS ENUM (`sonnet`, `opus`,
`haiku`, `fable`). The literal string `inherit` and full model IDs are both
REJECTED there — inheritance is expressed by omitting the field. These aliases
are Claude Code-only; `skills/shared/model-matrix.md` resolves the portable
selector for every harness.

On the implicit-team harness, a **named** Agent spawn is an in-process teammate
and ignores that alias. Honor `feature.models.<role>` with a nameless one-shot
Agent when `lib/implicit-team-model.sh` returns `oneshot`
(`skills/shared/dispatch.md`).

## Both run modes (parity map)

| Mode | Invocation |
|---|---|
| interactive session | the Claude Code TUI (`claude`) |
| headless / autonomous | `claude -p "/loop-spec:auto <description>"` |
| SDK-embedded | the Claude Agent SDK for Python (`claude-agent-sdk`) or TypeScript, which loads plugins and skills natively — the same harness, not a fourth one |
| loop-runner fleet | `claude -p --output-format json`, resolved by `bash lib/harness.sh cli` and driven as `loop.py --agent-cli claude` |

**Headless proof:** Claude Code stamps `CLAUDE_CODE_ENTRYPOINT` into every child
process, and three values prove a one-shot unattended invocation — `sdk-cli`
(`claude -p`), `sdk-py`, and `sdk-ts` (the Agent SDKs). `lib/harness.sh headless`
reads that stamp, which is why this is the one harness whose execution profile is
PROVEN rather than asserted; opencode and ADK export
`LOOP_SPEC_NON_INTERACTIVE=1` from their bridges instead. Other entrypoint values
(`mcp`, `bench`, `remote`, `claude-desktop`, ...) are neither proven headless nor
proven interactive and stay unknown, failing safe.

## Decision oracle (SDK supervisors)

The Agent SDK routes every `AskUserQuestion` call to the `canUseTool`
(Python `can_use_tool`) callback and takes the answers back as
`updatedInput.answers`, keyed by question text. That callback is the supervisor's
seat at the interview. `lib/supervisor/oracle.sh mode` answers `supervisor` when
`LOOP_SPEC_ORACLE=supervisor` (the `supervised` preset of `lib/profile.sh`), and
the autonomous self-answer sites then ask first
(`skills/shared/autonomous-mode.md`, "The supervised path"). A callback that
wants no say returns the recommended option; one that wants the run stopped
answers `halt`. `AskUserQuestion` is unavailable inside subagents, and loop-spec
interviews are main-thread already.

The whole supervisor interface on this harness's own seams
(`docs/loop-spec/supervisor-interface.md`, "Native integration map"):

| Port | Agent SDK seam |
|---|---|
| profile | `ClaudeAgentOptions.env` (`options.env`) carries `lib/profile.sh resolve` |
| plugin | `plugins=[{"type": "local", "path": ...}]`; verify in the init `SystemMessage` |
| state store | `cwd` is the key; `session_store` mirrors transcripts beside it |
| event sink | `PostToolUse` hook on `Bash` reads the phase markers; `LOOP_SPEC_EVENT_SINK` gets every line |
| decision oracle | `can_use_tool` on `AskUserQuestion`, answers keyed by question text |
| lifecycle | `ResultMessage.session_id`, `resume`, `max_turns`, `max_budget_usd`; `PreToolUse` `defer` to park a question |

Runnable: `examples/supervisor/supervisor.py`.

## Chat output style

Claude Code is the only peer with an output-style slot. loop-spec ships
`output-styles/loop-spec.md` with `force-for-plugin: true` and
`keep-coding-instructions: true`, so enabling the plugin binds the working
contract: name the phase when it changes, one thought per action, then one
outcome-first close. Built-in Concise does not do that (~6% shorter, same
chatter, and it also hides the phase). If another enabled plugin also sets
`force-for-plugin`, Claude Code uses the first one loaded.

Do not re-home those instructions into `hooks/team/*-inject.sh` or CLAUDE.md.
Durable reports stay in `skills/shared/report-style.md`.

## Graph engine (GDD)

`lib/graph/run.sh` sequences `graph/cycle.graph.json`. Nothing under `lib/graph/`
branches on the harness — node bodies may call `lib/harness.sh`. Under Claude
Code, agent node dispatch goes through the `Agent` tool.
