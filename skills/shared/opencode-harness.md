# opencode harness adaptation (reference)

Applies when loop-spec runs under **opencode** (https://opencode.ai) instead of
Claude Code: `bash "${CLAUDE_SKILL_DIR}/../../lib/harness.sh" detect` prints
`opencode` (equivalently, `cycle-preflight.sh` reports `harness.name ==
"opencode"` / `.loop-spec/runtime.json.harness == "opencode"`). loop-spec
installs there via the bundled installer (`bash lib/opencode-install.sh
install` from a clone — global `~/.config/opencode/` by default, `--project
<dir>` for a per-project `.opencode/`): skills load through the Agent Skills
standard both harnesses share (opencode's native `skill` tool),
`commands/loop-debug.md` loads as the `/loop-debug` command, every skill also
gets a generated command wrapper at `commands/loop-spec/<name>.md` loading as
`/loop-spec/<name>` (opencode's TUI hides skill-sourced entries from the "/"
autocomplete popup, so real commands are the user-discoverable surface; the
namespace keeps them clear of opencode's built-in `/debug`, `/status`, and
`/skills` palette slashes), agents are converted to opencode subagents named
`loop-spec-<role>`, and the bundled plugin
(`extensions/opencode/loop-spec.ts`) bridges env and hooks. This file is
ADDITIVE — when the harness is `claude`, nothing here applies and every skill
runs exactly as written.

opencode is a much closer harness than pi: skills, one-shot subagents,
questions, and commands all have NATIVE equivalents. The deltas below are the
complete list.

## Environment contract (who sets what)

The opencode plugin delivers, into every bash invocation (via the documented
`shell.env` plugin hook — opencode merges the returned env over `process.env`
for each shell call): `LOOP_SPEC_HARNESS=opencode`, `CLAUDE_PLUGIN_ROOT`
(package root, realpath'd through the install symlink), `CLAUDE_PROJECT_DIR`
(session directory), and `CLAUDE_SKILL_DIR` (the active skill's directory —
set from the native `skill` tool's result metadata, or from the last SKILL.md
`read`, and realpath'd so symlinked installs still resolve
`${CLAUDE_SKILL_DIR}/../../lib/...`).

**Re-export rule (cross-skill reads):** identical to pi — the tracked
`CLAUDE_SKILL_DIR` follows the LAST skill loaded (skill tool call or SKILL.md
read). When a skill reads another skill's SKILL.md mid-flow and then needs a
**skill-local** path of the skill it is still executing, re-export the
variable to that skill's directory first. Sibling paths like
`${CLAUDE_SKILL_DIR}/../../lib/...` are unaffected.

**Fallback rule (plugin not loaded):** before running any
`${CLAUDE_SKILL_DIR}/...` command, export the variable yourself — it is the
"Base directory for this skill" line the skill tool printed when it loaded
the skill (or the directory of the SKILL.md you read):

```bash
export CLAUDE_SKILL_DIR="<base directory the skill tool reported>"
```

## Tool substitution table

| Claude Code tool | Under opencode |
|---|---|
| Read / Write / Edit / Bash | `read` / `write` / `edit` / `bash` (same semantics) |
| Glob / Grep | `glob` / `grep` (native) |
| Skill (invoke a skill) | the native `skill` tool: `skill({name: "<name>"})` — loop-spec skill names are unchanged; users invoke via the generated `/loop-spec/<name>` commands (the CC `/loop-spec:<name>` analogue), the skill tool, or `/loop-debug` for the one-shot command |
| Agent (one-shot subagent) | the native `task` tool — SAME parameter shape `{description, prompt, subagent_type}`; see the dispatch mapping rule below |
| Teams (named `Agent` spawns, SendMessage, TeamCreate/TeamDelete) | never — `teamsMode` is hard-gated to `none` under opencode (`lib/teams-capability.sh`); the task tool is one-shot only |
| Workflow | never — hard-gated `false` (`lib/workflow-availability.sh`) |
| TaskCreate / TaskUpdate / TaskList / TaskGet | none with that shape — opencode's `todowrite` is a flat checklist (no deps/metadata). DAG and wave state live where they already durably live: PLAN.md task blocks + `feature.json` (same rule as pi) |
| AskUserQuestion | the native `question` tool (multi-question, options — near-identical shape); autonomous: self-answer per `skills/shared/autonomous-mode.md`, unchanged |
| ToolSearch (deferred-tool rescue) | does not exist; nothing is deferred under opencode — skip rescue steps entirely |
| EnterWorktree | `git worktree add` via bash (the skills already script this path) |

## Dispatch mapping rule (every one-shot `Agent` call)

Under opencode, `harness.sh subagents` prints `true`: the full EXECUTE ladder
below the team rung survives, and every one-shot `Agent` dispatch a phase
skill (or `skills/shared/no-teams-fallback.md`) prescribes maps 1:1 onto the
native `task` tool:

- `subagent_type: "loop-spec:<role>"` → `subagent_type: "loop-spec-<role>"`
  (the installer generates `agents/loop-spec-<role>.md` in the opencode
  config dir; colons are Claude Code plugin namespacing, hyphens are the
  opencode agent id).
- `prompt` and `description` pass through verbatim.
- There is NO per-dispatch `model` parameter — omit it. Per-role models come
  from the generated agent file (default: inherit the session model; pin by
  editing `model: provider/model` there). The `model-matrix.md` aliases are
  Claude Code-only.

If a `task` call fails because the agent id is unknown, the agents were not
installed — fall back to performing the prompt inline after reading the
role's charter (`agents/<role>.md`), exactly like the pi inline dispatch
rule, and tell the user to run `bash lib/opencode-install.sh install`.

Gates, artifacts, worktree layout, and the `feature.json` schema DO NOT
CHANGE — only the tool name and agent id spelling do.

## Startup probes

Skip the cycle's model probe (Step 3.5) entirely — it pre-flights Claude Code
model aliases, which do not exist here; per-role models are pinned in the
generated agent files instead. Model failures surface loudly on the first
task or loop-fleet dispatch. Teams and Workflow probes need no
special-casing: the capability scripts return `none` / `false` under opencode
on their own.

## Model routing

opencode model ids are `provider/model` (e.g. `anthropic/claude-sonnet-4-5`).
Loop-fleet rungs pass them via `--model`; the `LOOP_SPEC_MODEL_<ROLE>`
overrides are still honored, but values must be opencode ids — Claude Code
aliases like `sonnet`/`opus` mean nothing to opencode
(`skills/shared/model-matrix.md`).

## Both run modes (parity map)

| Claude Code | opencode |
|---|---|
| interactive session | opencode TUI (`opencode`) |
| `claude -p` headless / autonomous mode | `opencode run --format json "<prompt>"` (or the SDK: `createOpencode()` / `createOpencodeClient()` from `@opencode-ai/sdk`, then `client.session.prompt(...)` against `opencode serve`) with `LOOP_SPEC_AUTONOMOUS=1` |
| loop-runner fleet spawning `claude -p` | same fleet spawning `opencode run --format json` — the agent CLI is resolved by `bash lib/harness.sh cli` and passed to `loop.py --agent-cli opencode` (see `skills/shared/execute-loop-fleet.md`) |

Headless permission note: `opencode run` auto-REJECTS permission asks;
loop-spec's fleet passes `--auto` on work ticks (approve what is not
explicitly denied — the acceptEdits analogue) and `--agent plan` on
read-only judge/compiler ticks.
