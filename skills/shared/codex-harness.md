# Codex harness adaptation (reference)

Applies when loop-spec runs under **OpenAI Codex**
(https://developers.openai.com/codex): `bash
"${CLAUDE_SKILL_DIR}/../../lib/harness.sh" detect` prints `codex`
(equivalently, `cycle-preflight.sh` reports `harness.name == "codex"` /
`.loop-spec/runtime.json.harness == "codex"`). loop-spec installs there as a
native Codex plugin (`.codex-plugin/plugin.json`) plus the bundled installer
(`bash lib/codex-install.sh install` from a clone — user `~/.codex` by
default, `--project <dir>` for a per-project `.codex/`). This file is ADDITIVE
— when the harness is `claude`, nothing here applies and every skill runs
exactly as written.

Codex is a coding agent with skills, plugins, hooks, and subagents. It is not
a framework that has to be programmed before anything runs (that is ADK) and
it is not a port of Claude Code. Everything below follows from the public
Codex surfaces: plugins, skills, `codex exec`, `spawn_agent`, and lifecycle
hooks.

## What the installer and plugin mount

| Path | What Codex loads |
|---|---|
| `.codex-plugin/plugin.json` | plugin identity; `skills: ./skills/`; `hooks: ./hooks/codex-hooks.json` |
| `.agents/plugins/marketplace.json` | repo marketplace Codex auto-discovers next to a clone |
| `<codex-home>/agents/loop-spec-<role>.toml` | custom agents for `spawn_agent` (`name` / `description` / `developer_instructions`) |
| `<skills-root>/loop-spec-<name>/SKILL.md` | generated adapters (`$loop-spec-cycle`, …) that embed this contract then the source skill |
| `<codex-home>/config.toml` `[shell_environment_policy.set]` | `LOOP_SPEC_HARNESS=codex` plus `CLAUDE_PLUGIN_ROOT` / `CLAUDE_SKILL_DIR` for every Bash subprocess |
| `<codex-home>/hooks.json` | SessionStart / UserPromptSubmit / PreToolUse Bash env rewrite, merged without clobbering other hooks |

Preferred headless entry: `LOOP_SPEC_HARNESS=codex LOOP_SPEC_NON_INTERACTIVE=1 codex exec --json --sandbox workspace-write '$loop-spec-auto <description>'`. Plugin install: `codex plugin marketplace add https://github.com/aztechead/loop-spec.git` then `codex plugin add loop-spec`. Plugin-bundled hooks stay skipped until `/hooks` trusts them; the installer-written `shell_environment_policy.set` block does not wait on that review.

## Environment contract (who sets what)

Codex plugin hook processes receive `PLUGIN_ROOT` and `PLUGIN_DATA`, and Codex
also sets `CLAUDE_PLUGIN_ROOT` / `CLAUDE_PLUGIN_DATA` for compatibility
(https://developers.openai.com/codex/plugins/build). Those variables exist
inside hook commands; they are **not** automatically copied into the model's
Bash tool.

Three deterministic injections close that gap:

1. `lib/codex-install.sh` writes a marked `[shell_environment_policy.set]`
   block so every Codex-spawned subprocess gets `LOOP_SPEC_HARNESS=codex`,
   `CLAUDE_PLUGIN_ROOT` (this checkout), and `CLAUDE_SKILL_DIR` pointing at
   `skills/cycle` as the package-relative anchor (`../../lib` and `../../hooks`
   resolve from any skill directory).
2. `hooks/codex-shell-env.sh` is a PreToolUse Bash rewrite that prefixes the
   same exports onto the command. It is the fallback when hook trust is on
   and the config block is missing.
3. Generated skill adapters re-export `CLAUDE_SKILL_DIR` to the **source** skill
   directory before every bundled command. Codex starts each Bash tool in a new
   process, while the installer and PreToolUse fallback deliberately provide
   `skills/cycle` only as a package anchor. Keeping that anchor during another
   skill would break local paths such as `${CLAUDE_SKILL_DIR}/scripts/...`.

**Re-export rule (cross-skill reads):** `CLAUDE_SKILL_DIR` must point at the
skill that is still executing when a skill-local path is needed. Sibling
package paths (`${CLAUDE_SKILL_DIR}/../../lib/...`) are unaffected by which
skill directory is the anchor.

**Per-skill re-export rule:**

```bash
export CLAUDE_SKILL_DIR="<package>/skills/<name>"
```

Verify before relying on it:

```bash
[ -f "${CLAUDE_SKILL_DIR}/../../lib/harness.sh" ] || \
  CLAUDE_SKILL_DIR="${CLAUDE_PLUGIN_ROOT}/skills/<name>"
```

Detection requires that injection. Codex stamps no `CLAUDECODE`-equivalent
that this probe may treat as proof, and inventing a weak hint would guess
wrong on a machine that also has Claude Code installed.

## Tool substitution table

| Claude Code tool | Under Codex |
|---|---|
| Read / Write / Edit | native file tools, plus `apply_patch` for edits. PreToolUse/PostToolUse match `apply_patch` as `Edit` or `Write` (https://developers.openai.com/codex/hooks) |
| Bash | `Bash` (and unified exec `exec_command`, which hooks also match as `Bash`) |
| Glob / Grep | no separate tools — use Bash with `find` / `rg` / `grep` |
| Skill | `$loop-spec-<name>` (installer adapters) or a plugin skill `$<name>` from `.codex-plugin`. Explicit `$` mention; generated adapters set `policy.allow_implicit_invocation: false` in `agents/openai.yaml` so a generic prompt cannot silently bind `status` |
| Agent (subagent) | `spawn_agent` — see the dispatch mapping rule below |
| Teams (named spawns, SendMessage, TeamCreate/TeamDelete) | never — `teamsMode` is hard-gated to `none` (`lib/teams-capability.sh`). `spawn_agent` returns a child thread; it does not provide named teammates, peer messaging, or a shared task list |
| Workflow | never — hard-gated `false` (`lib/workflow-availability.sh`) |
| TaskCreate / TaskUpdate / TaskList / TaskGet | none. DAG and wave state live where they already durably live: PLAN.md task blocks + `feature.json` |
| AskUserQuestion | none with that shape. Ask in the transcript when a human is attached; autonomous self-answering follows `skills/shared/autonomous-mode.md` unchanged |
| ToolSearch (deferred-tool rescue) | does not exist; nothing is deferred under Codex — skip rescue steps entirely |
| EnterWorktree / ExitWorktree | no session-root switch exists. Cycle uses `executionRootMode: "in-place"`: after a clean-base guard it creates/checks out `feat/{slug}` in the session repo and never calls either tool. It does not pretend worktree creation changed cwd |

## Ambient verification enforcement

Codex Stop is **not** Claude Code Stop. On Codex, `decision: "block"` on Stop
continues the turn with a new user prompt; `continue: false` allows the stop
(https://developers.openai.com/codex/hooks). Shipping Claude Code's Stop
guards unchanged would invert their polarity, so they are not bridged.

Ambient enforcement is therefore directive-only, matching OpenCode and ADK:
SessionStart injects the micro protocol, UserPromptSubmit runs
`done-criteria.sh`, and full cycles still use
`lib/verification-grounding-lint.sh`. `adhoc-verify-guard.sh` and
`route-terminal-guard.sh` are unbridged.

`route-terminal-guard.sh` being unbridged makes the Step 4
`lib/cycle-reconcile.sh` call in `/loop-spec/auto` the only thing holding the
route-exit contract here (`skills/shared/route-exit-contract.md`). Run it on
every route.

Plugin-bundled hooks remain skipped until the user reviews and trusts the
current definition (`/hooks`). `--dangerously-bypass-hook-trust` exists for
already-vetted automation and is never the default.

## Dispatch mapping rule (every one-shot `Agent` call)

`harness.sh subagents` prints `true` under Codex: the full EXECUTE ladder
below the team rung survives, and every one-shot `Agent` dispatch a phase
skill (or `skills/shared/no-teams-fallback.md`) prescribes maps onto
`spawn_agent` (stable; `agents.enabled` is on by default —
https://developers.openai.com/codex/subagents):

- `subagent_type: "loop-spec:<role>"` → `agent_type: "loop-spec-<role>"`
  (the installer writes `~/.codex/agents/loop-spec-<role>.toml` or
  `.codex/agents/loop-spec-<role>.toml`; hyphens are the Codex custom-agent
  `name`).
- `prompt` becomes `message`.
- `description` becomes `task_name` when the schema includes that field
  (multi-agent v2 currently requires `task_name` and `message`).
- Pass `fork_turns: "none"` (or `fork_context: false` on v1) when the schema
  includes a fork control. A full-history fork rejects `agent_type` / `model`
  overrides.
- Optional `model` is a Codex slug. Pass `feature.models.<role>` when that
  value is a Codex id so `LOOP_SPEC_PHASE_MODEL_*` / `LOOP_SPEC_MODEL_<ROLE>`
  bind at spawn. Empty, `inherit`, and Claude aliases (`sonnet` / `opus` /
  `haiku` / `fable`) are omitted — the custom agent file or the parent model
  applies. The `model-matrix.md` aliases are Claude Code-only.
- Some Codex releases hide `agent_type` on the model-visible schema. When the
  field is absent, still spawn with `message` / `task_name` and prefix the
  message with the role charter from `agents/<role>.md` (the portable inline
  fallback). Do not guess a different tool.

If `spawn_agent` fails because the agent name is unknown, the agents were not
installed — fall back to performing the prompt inline after reading the
role's charter (`agents/<role>.md`), matching the portable inline dispatch
rule, and tell the user to run `bash lib/codex-install.sh install`.

Follow-up work uses only the steering and wait controls exposed by the current
multi-agent schema while the child thread is available. Do not synthesize tool
names from another Codex release. When no follow-up control or live thread is
available, use a fresh `spawn_agent` with the prior round inlined from
`gate-logs/`.

Gates, artifacts, and delivery semantics do not change. DELIVER still calls
the same explicit-path `lib/deliver.sh` / `lib/pr-delivery.sh` controller as
Claude Code.

## Startup probes

Skip the cycle's model probe (Step 3.5) entirely — it pre-flights Claude Code
model aliases, which do not exist here. Model failures surface loudly on the
first `spawn_agent` or `codex exec`. Teams and Workflow probes need no
special-casing: the capability scripts return `none` / `false` under Codex
on their own.

## Model routing

Codex model ids are slugs (`gpt-5.6`, `gpt-5.6-terra`, …), not Claude aliases and not
OpenCode `provider/model`. Generated custom agents inherit the parent session
model unless `codex-install.sh install --model` pins a role:

```bash
bash lib/codex-install.sh install \
  --model adversarial=gpt-5.6 \
  --model planner=gpt-5.6
```

`adversarial` pins `challenger`, `iterate-judge`, `code-reviewer`, and
`security-reviewer`. Any agent role name is accepted as an explicit route; an
explicit role wins over the group shorthand. Unrouted roles continue
inheriting the session model. Routes are written as `model = "..."` in the
generated TOML.

The main-thread cycle/phase lead remains on the model that launched the Codex
session. Loop-fleet subprocesses omit `--model` for the portable `inherit`
selector; an explicit implementer value through `LOOP_SPEC_MODEL_IMPLEMENTER`
must be a Codex slug.

## Both run modes (parity map)

| Claude Code | Codex |
|---|---|
| interactive session | Codex TUI (`codex`) |
| `claude -p` headless / autonomous mode | `LOOP_SPEC_HARNESS=codex LOOP_SPEC_NON_INTERACTIVE=1 codex exec --json --sandbox workspace-write '$loop-spec-auto <description>'` |
| loop-runner fleet spawning `claude -p` | same fleet spawning `codex exec --json --sandbox workspace-write` — the agent CLI is resolved by `bash lib/harness.sh cli` and passed to `loop.py --agent-cli codex` (see `skills/shared/execute-loop-fleet.md`) |

Headless permission note: `codex exec` defaults to a read-only sandbox.
Work ticks pass `--sandbox workspace-write` so in-repo edits can proceed;
they do **not** pass `--dangerously-bypass-approvals-and-sandbox`. Read-only
judge/compiler ticks use `--sandbox read-only` and the installer-provided
`loop-spec-readonly` custom agent (`sandbox_mode = "read-only"`). Continue-
mode ticks resume with `codex exec resume <thread_id> --json`.

Cost accounting is unavailable: Codex `exec --json` reports usage tokens,
not money, so the fleet records `cost_usd: None` ("unknown", never "free").
A requested `--max-budget-usd` fails at configuration time instead of
pretending a hard cap can bind.

## Headless profile

Codex publishes no entrypoint stamp, so one-shot launchers assert both the
harness and profile. `loop.py --agent-cli codex` exports
`LOOP_SPEC_HARNESS=codex` and `LOOP_SPEC_NON_INTERACTIVE=1` into the child;
`lib/issue-intake.sh` retains the explicit harness value it used to select
Codex. Direct `codex exec` commands must set both as shown above. The installer
does not infer a profile from the executable name because the interactive TUI
uses the same `codex` binary. `lib/harness.sh` ranks the explicit assertion
below Claude Code's stamp and above an inherited
`LOOP_SPEC_EXECUTION_PROFILE` claim.

## Graph engine (GDD)

`lib/graph/run.sh` sequences `graph/cycle.graph.json`. Nothing under
`lib/graph/` branches on the harness — node bodies may call `lib/harness.sh`.
Under Codex, agent node dispatch continues through `spawn_agent`; the engine
and handoff port stay harness-neutral.
