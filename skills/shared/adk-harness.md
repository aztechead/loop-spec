# ADK harness adaptation (reference)

Applies when loop-spec runs under **Google's Agent Development Kit**
(https://google.github.io/adk-docs/): `bash
"${CLAUDE_SKILL_DIR}/../../lib/harness.sh" detect` prints `adk` (equivalently,
`cycle-preflight.sh` reports `harness.name == "adk"` /
`.loop-spec/runtime.json.harness == "adk"`). loop-spec mounts there through the
bundled installer (`bash lib/adk-install.sh install --project <dir>`), which
writes two agent directories that wrap the checked-in package in
`extensions/adk/`. This file is ADDITIVE — when the harness is `claude`, nothing
here applies and every skill runs exactly as written.

ADK differs from the other two harnesses in kind, not just in surface: it is a
FRAMEWORK, so nothing runs until a program builds an agent. The installer writes
that program. Everything below follows from that one fact.

## What the installer mounts

| Path | Agent | Tools |
|---|---|---|
| `<mount>/loop_spec/` | working agent | Execute, ReadFile, EditFile, WriteFile, `list_skills`/`load_skill`/`load_skill_resource`, `dispatch_subagent` |
| `<mount>/loop_spec_readonly/` | judge / spec compiler | ReadFile + the three skill tools only |

Both expose a module-level `app` (an ADK `App`), because `adk run` looks for
`app` before `root_agent` and only the `App` form carries the lifecycle plugin.
The shims reference this clone by absolute path rather than copying it, so a
`git pull` updates behavior; `bash lib/adk-install.sh check` reports a shim whose
package root has moved.

## Environment contract (who sets what)

`extensions/adk/loop_spec_adk/bridge.py` builds a `LocalEnvironment` whose
`env_vars` mapping delivers, into every shell command: `LOOP_SPEC_HARNESS=adk`,
`CLAUDE_PLUGIN_ROOT` (package root), `CLAUDE_PROJECT_DIR` (the project the agent
was mounted for), and `CLAUDE_SKILL_DIR` (the active skill's real directory).

`LocalEnvironment.execute()` reads that mapping at call time, so the bridge
updates `CLAUDE_SKILL_DIR` live — no rebuild, no session restart. The plugin's
`after_tool_callback` sets it whenever `load_skill` runs.

**Skill-directory rule:** ADK's `Skill` model holds instructions and resources in
memory and carries NO source path, so the name→directory map comes from
loop-spec's own loader. An unknown skill name leaves the previous value in place:
a skill that is still executing must not lose its directory because an unrelated
lookup missed. Sibling paths (`${CLAUDE_SKILL_DIR}/../../lib/...`) resolve
because the map points into the real package, never into a materialized copy.

**Why skills are not materialized:** `SkillToolset` is built WITHOUT
`environment=` or `code_executor=`. Passing either makes it copy each skill into
a temp or `skills_folder` directory and expose `run_skill_script` over that copy
— which would sever every `../../lib` path, since no per-skill copy contains
loop-spec's shared scripts. Skills supply instructions here; the filesystem the
shell tools see is the real package. `run_skill_script` is filtered out for the
same reason (and, on the read-only agent, because a judge must hold no execution
vector).

## Tool substitution table

| Claude Code tool | Under ADK |
|---|---|
| Bash | `Execute` (`EnvironmentToolset` over `LocalEnvironment`) — a REAL shell via `create_subprocess_shell`, so pipes, `&&`, and `$( )` all work |
| Read / Write / Edit | `ReadFile` / `WriteFile` / `EditFile` (same semantics) |
| Glob / Grep | no native tools — use `Execute` with `find` / `grep` / `rg` |
| Skill (invoke a skill) | `load_skill({skill_name: "<name>"})`; `list_skills` enumerates. Skill names are UNPREFIXED here (`cycle`, not `loop-spec-cycle`) because the toolset holds only loop-spec's skills |
| Agent (subagent) | `dispatch_subagent({subagent_type, description, prompt})` — the bundled tool over ADK's `AgentTool`. Same parameter shape as Claude Code's `Agent`; a `loop-spec:` prefix on `subagent_type` is accepted and stripped |
| Teams (named spawns, SendMessage, TeamCreate/TeamDelete) | never — `teamsMode` is hard-gated to `none` (`lib/teams-capability.sh`). `AgentTool` returns a result to its caller and nothing more: no named peers, no peer messaging, no shared task list |
| Workflow | never — hard-gated `false` (`lib/workflow-availability.sh`) |
| TaskCreate / TaskUpdate / TaskList / TaskGet | none. DAG and wave state live where they already durably live: PLAN.md task blocks + `feature.json` |
| AskUserQuestion | `get_user_choice` (ADK's long-running HITL tool) when a human is attached; autonomous self-answering follows `skills/shared/autonomous-mode.md` unchanged |
| ToolSearch (deferred-tool rescue) | does not exist; nothing is deferred under ADK — skip rescue steps entirely |
| EnterWorktree / ExitWorktree | no session-root switch exists. Cycle uses `executionRootMode: "in-place"`: after a clean-base guard it creates/checks out `feat/{slug}` in the session repo and never calls either tool. It does not pretend worktree creation changed cwd |

## Ambient verification enforcement

ADK receives the SessionStart injections (`hooks/team/*-inject.sh`) through the
plugin's `on_user_message_callback`, which prepends them to the first message of
a session; `hooks/team/done-criteria.sh` runs on every message, the
UserPromptSubmit analogue.

Enforcement is directive-only. ADK has no vetoable Stop event —
`after_run_callback` observes a finished run, it cannot continue one — so
`adhoc-verify-guard.sh` is not bridged, exactly as under opencode. Explicit micro
runs still own the full grounding/validation protocol, and full cycles use the
deterministic `lib/verification-grounding-lint.sh` gate.

`route-terminal-guard.sh` is unbridged for the same reason, which makes the Step 4
`lib/cycle-reconcile.sh` call the only thing holding the route-exit contract here
(`skills/shared/route-exit-contract.md`). Run it on every route.

## Dispatch mapping rule (every one-shot `Agent` call)

`harness.sh subagents` prints `true` under ADK: the full EXECUTE ladder below the
team rung survives, and every one-shot dispatch a phase skill (or
`skills/shared/no-teams-fallback.md`) prescribes maps onto `dispatch_subagent`:

- `subagent_type: "loop-spec:<role>"` → `subagent_type: "<role>"` (the prefix is
  stripped for you; either spelling works). Roles are the filenames in
  `agents/`, parsed at build time — the same charters Claude Code dispatches.
- `prompt` and `description` pass through verbatim.
- There is NO per-dispatch `model` parameter. A role's model comes from its
  charter when that names an ADK id; `model: inherit` (which every charter
  ships) and Claude aliases fall back to the mounted agent's model. The
  `model-matrix.md` aliases are Claude Code-only.
- There is no session resumption for a dispatch: `AgentTool` runs the role once
  and returns. Follow-up work is a new dispatch carrying its own context.

An unknown `subagent_type` returns a structured error listing the known roles
rather than dispatching something else.

Gates, artifacts, and delivery semantics do not change. DELIVER still calls the
same explicit-path `lib/deliver.sh` / `lib/pr-delivery.sh` controller as Claude
Code.

## Startup probes

Skip the cycle's model probe (Step 3.5) entirely — it pre-flights Claude Code
model aliases, which do not exist here. Model failures surface loudly on the
first dispatch. Teams and Workflow probes need no special-casing: the capability
scripts return `none` / `false` under ADK on their own.

## Model routing

ADK model ids are `gemini-*` natively or `provider/model` through LiteLLM, so one
mount can drive Gemini, Claude, or a local model without changing this contract.
The mounted default is set at install time (`--model`, or `$LOOP_SPEC_ADK_MODEL`,
default `gemini-2.5-pro`) and written into the generated shim, where it is the
one line intended for hand-editing.

The portable `inherit` selector means "use the mounted agent's model" — it is
never forwarded as a literal id. `LOOP_SPEC_MODEL_<ROLE>` routes fleet workers
only and must be an ADK id; a Claude alias there is dropped rather than
forwarded, the same rule `loop.py`'s `model_args()` applies.

## Both run modes (parity map)

| Claude Code | ADK |
|---|---|
| interactive session | `adk web` / `adk api_server` against the mounted agent, or your own `Runner` over `build_app()` |
| `claude -p` headless / autonomous mode | `adk run "$LOOP_SPEC_ADK_AGENT_DIR" "Load the loop-spec auto skill and run: <description>" --jsonl` |
| loop-runner fleet spawning `claude -p` | same fleet spawning `adk run <agent-dir> --jsonl` — the agent CLI is resolved by `bash lib/harness.sh cli` and passed to `loop.py --agent-cli adk` (see `skills/shared/execute-loop-fleet.md`) |

Two ADK CLI facts the fleet backend encodes, both worth knowing before debugging
a run: dispatch targets a mounted agent DIRECTORY (hence
`LOOP_SPEC_ADK_AGENT_DIR` / `--adk-agent-dir`), and one-shot `adk run` CANNOT
resume a session — its `--resume` is interactive-only and `--session_id` merely
names the file `--save_session` writes on exit. Every tick therefore starts a
fresh session and carries context in the prompt, which is what the loop already
does through PROGRESS notes and verifier feedback. Read-only ticks
(`--permission-mode plan`) select the `_readonly` sibling agent; a missing one
fails closed rather than handing a judge the writable agent's edit tools.

Cost accounting is unavailable: ADK reports token counts, not money, so the
fleet records `cost_usd: None` ("unknown", never "free") and a
`--max-budget-usd` cap cannot bind here.

## Headless profile

ADK publishes no entrypoint stamp, so the bridge asserts the profile instead:
under `adk run` (one-shot, nobody attached) it exports
`LOOP_SPEC_NON_INTERACTIVE=1`; `adk web` and `adk api_server` are persistent and
leave it unset. `lib/harness.sh` ranks that assertion below Claude Code's stamp
and above an inherited `LOOP_SPEC_EXECUTION_PROFILE` claim.

## Graph engine (GDD)

`lib/graph/run.sh` sequences `graph/cycle.graph.json`. Nothing under `lib/graph/`
branches on the harness — node bodies may call `lib/harness.sh`. Under ADK, agent
node dispatch continues through `dispatch_subagent`; the engine and handoff port
stay harness-neutral.
