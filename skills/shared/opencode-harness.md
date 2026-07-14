# opencode harness adaptation (reference)

Applies when loop-spec runs under **opencode** (https://opencode.ai) instead of
Claude Code: `bash "${CLAUDE_SKILL_DIR}/../../lib/harness.sh" detect` prints
`opencode` (equivalently, `cycle-preflight.sh` reports `harness.name ==
"opencode"` / `.loop-spec/runtime.json.harness == "opencode"`). loop-spec
installs there via the bundled installer (`bash lib/opencode-install.sh
install` from a clone — global `~/.config/opencode/` by default, `--project
<dir>` for a per-project `.opencode/`): namespaced adapters load through
opencode's native `skill` tool as `loop-spec-<name>`,
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
| Skill (invoke a skill) | the native `skill` tool: `skill({name: "loop-spec-<name>"})`; generated adapters load this contract and then the source skill without occupying generic user skill names. Users normally invoke `/loop-spec/<name>` (the CC `/loop-spec:<name>` analogue) or `/loop-debug` |
| Agent (one-shot subagent) | the native `task` tool — `{description, prompt, subagent_type}`; unlike Claude Code, `subagent_type` is REQUIRED; see the dispatch mapping rule below |
| Teams (named `Agent` spawns, SendMessage, TeamCreate/TeamDelete) | never — `teamsMode` is hard-gated to `none` under opencode (`lib/teams-capability.sh`); the task tool is one-shot only |
| Workflow | never — hard-gated `false` (`lib/workflow-availability.sh`) |
| TaskCreate / TaskUpdate / TaskList / TaskGet | none with that shape — opencode's `todowrite` is a flat checklist (no deps/metadata). DAG and wave state live where they already durably live: PLAN.md task blocks + `feature.json` (same rule as pi) |
| AskUserQuestion | the native `question` tool. Preserve `questions`, `question`, `header`, and option objects, but rename Claude Code's `multiSelect` field to OpenCode's `multiple`; autonomous self-answering follows `skills/shared/autonomous-mode.md` unchanged |
| ToolSearch (deferred-tool rescue) | does not exist; nothing is deferred under opencode — skip rescue steps entirely |
| EnterWorktree / ExitWorktree | no session-root switch exists. Cycle uses `executionRootMode: "in-place"`: after a clean-base guard it creates/checks out `feat/{slug}` in the session repo and never calls either tool. It does not pretend worktree creation changed cwd. |

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

OpenCode's `task` schema always requires `subagent_type`; it has no generic
default-agent form. When a Claude Code dispatch intentionally omits that field,
choose the generated agent matching the prompt's role. In particular, the
generic EXECUTE dispatches in `execute-subagent.md` map implementer prompts to
`loop-spec-implementer` and review prompts to
`loop-spec-spec-compliance-reviewer`. The generated OpenCode agents do not carry
Claude Code's `isolation: worktree`, so this does not create the nested worktree
that the Claude Code instructions are avoiding.

If a `task` call fails because the agent id is unknown, the agents were not
installed — fall back to performing the prompt inline after reading the
role's charter (`agents/<role>.md`), exactly like the pi inline dispatch
rule, and tell the user to run `bash lib/opencode-install.sh install`.

Gates, artifacts, and delivery semantics do not change. The additive OpenCode
execution-root branch is intentionally in-place because its tools remain rooted at the
session directory; `feature.json.executionRootMode` records that difference. DELIVER
still calls the same explicit-path `lib/deliver.sh` / `lib/pr-delivery.sh` controller as
Claude Code.

## Startup probes

Skip the cycle's model probe (Step 3.5) entirely — it pre-flights Claude Code
model aliases, which do not exist here; per-role models are pinned in the
generated agent files instead. Model failures surface loudly on the first
task or loop-fleet dispatch. Teams and Workflow probes need no
special-casing: the capability scripts return `none` / `false` under opencode
on their own.

## Model routing

OpenCode model ids are `provider/model`. Generated loop-spec subagents inherit the
current session model unless explicitly routed, so one run can use multiple logged-in
providers without changing its primary model. Install-wide routes are OpenCode-only:

```bash
bash lib/opencode-install.sh install \
  --model adversarial=github-copilot/<frontier-model> \
  --model planner=google-vertex-anthropic/<opus-model>
```

`adversarial` pins `challenger`, `iterate-judge`, `code-reviewer`, and
`security-reviewer`. Any agent role name is accepted as an explicit route; an explicit
role wins over the group shorthand. Unrouted roles continue inheriting the session
provider/model. Routes are persisted in `loop-spec-install.json.modelRoutes` and written
as native `model: provider/model` fields in generated agent files.

For a project-only override, OpenCode's normal config merge can override those generated
agents without reinstalling globally:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "agent": {
    "loop-spec-challenger": {"model": "github-copilot/<frontier-model>"},
    "loop-spec-iterate-judge": {"model": "github-copilot/<frontier-model>"}
  }
}
```

The main-thread cycle/phase lead remains on the model that launched the OpenCode session;
these routes apply to native `task` subagents. Loop-fleet subprocesses retain their
separate `--model` routing. `LOOP_SPEC_MODEL_<ROLE>` is the Claude alias mechanism and
must not be used for OpenCode provider selection. Restart OpenCode after reinstalling
agents or changing project configuration; config-time files are not hot-reloaded.

Inside the Plugin API and SDK, a selected model is represented as
`{providerID, modelID}`. The bridge injects only OpenCode's neutral text-part
shape and never branches on either value; OpenCode performs the provider wire
conversion. Continuations should omit `model` to inherit both values from the
session. If a model is explicitly selected through the SDK, pass both fields —
never treat `modelID` alone as globally unique.

## Both run modes (parity map)

| Claude Code | opencode |
|---|---|
| interactive session | opencode TUI (`opencode`) |
| `claude -p` headless / autonomous mode | `opencode run --format json "<prompt>"` (or the SDK: `createOpencode()` / `createOpencodeClient()` from `@opencode-ai/sdk`, then `client.session.prompt(...)` against `opencode serve`) with `LOOP_SPEC_AUTONOMOUS=1` |
| loop-runner fleet spawning `claude -p` | same fleet spawning `opencode run --format json` — the agent CLI is resolved by `bash lib/harness.sh cli` and passed to `loop.py --agent-cli opencode` (see `skills/shared/execute-loop-fleet.md`) |

Headless permission note: `opencode run` rejects permission asks. Work ticks do
not pass `--auto`: normal in-worktree build-agent edits remain allowed, while
external-directory and other sensitive asks fail closed. Read-only
judge/compiler ticks select the installer-provided `--agent
loop-spec-readonly`, whose permissions deny all tools except read/glob/grep.
