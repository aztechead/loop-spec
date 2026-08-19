# ADK harness adaptation (experimental reference)

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
static environment delivers `LOOP_SPEC_HARNESS=adk`, `CLAUDE_PLUGIN_ROOT`
(package root), and `CLAUDE_PROJECT_DIR` (the mounted project). The plugin's
`after_tool_callback` records the active skill's real directory in ADK session
state whenever `load_skill` runs. The custom Execute tool creates each shell
environment from that state and exports it as `CLAUDE_SKILL_DIR`.

The state is per session. Concurrent sessions in one `adk web` or
`adk api_server` process therefore cannot overwrite one global active-skill
directory and send another session's command through the wrong skill.

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
| Bash | session-aware `Execute` over `LocalEnvironment` — a REAL shell via `create_subprocess_shell`, so pipes, `&&`, and `$( )` all work |
| Read / Write / Edit | `ReadFile` / `WriteFile` / `EditFile` (same semantics) |
| Glob / Grep | no native tools — use `Execute` with `find` / `grep` / `rg` |
| Skill (invoke a skill) | `load_skill({skill_name: "<name>"})`; `list_skills` enumerates. Skill names are UNPREFIXED here (`cycle`, not `loop-spec-cycle`) because the toolset holds only loop-spec's skills |
| Agent (subagent) | `dispatch_subagent({subagent_type, description, prompt, model?})` — the bundled tool over ADK's `AgentTool`. Same call shape as Claude Code's `Agent` plus optional native `model`; a `loop-spec:` prefix on `subagent_type` is accepted and stripped |
| Teams (named spawns, SendMessage, TeamCreate/TeamDelete) | never — `teamsMode` is hard-gated to `none` (`lib/teams-capability.sh`). `AgentTool` returns a result to its caller and nothing more: no named peers, no peer messaging, no shared task list |
| Workflow | never — hard-gated `false` (`lib/workflow-availability.sh`) |
| TaskCreate / TaskUpdate / TaskList / TaskGet | none. DAG and wave state live where they already durably live: PLAN.md task blocks + `feature.json` |
| AskUserQuestion | `get_user_choice` (ADK's long-running HITL tool) when a human is attached; autonomous self-answering follows `skills/shared/autonomous-mode.md` unchanged |
| ToolSearch (deferred-tool rescue) | does not exist; nothing is deferred under ADK — skip rescue steps entirely |
| EnterWorktree / ExitWorktree | no session-root switch exists. Cycle uses `executionRootMode: "in-place"`: after a clean-base guard it creates/checks out `feat/{slug}` in the session repo and never calls either tool. It does not pretend worktree creation changed cwd |

**Security boundary:** ReadFile/EditFile/WriteFile reject paths that resolve
outside the project. Execute is different: its shell starts in the project but
is not sandboxed there, and it inherits every filesystem/network permission of
the OS user running ADK. Use an isolated container or restricted service account
for untrusted repositories. `LocalEnvironment` is also marked experimental by
ADK, which is why the real-package compatibility suite is part of release
verification. Session-scoped skill state prevents environment leakage, but all
sessions still edit the same mounted working tree. This is not tenant isolation:
never expose the working agent through `adk web` or `adk api_server` to
untrusted users.

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
- Optional `model` is an ADK id (`gemini-*` or `provider/model`). Pass
  `feature.models.<role>` when that value is an ADK id so
  `LOOP_SPEC_PHASE_MODEL_*` / `LOOP_SPEC_MODEL_<ROLE>` bind at dispatch.
  Empty, `inherit`, and Claude aliases fall back to the mounted agent's model
  — the same rule `adk_model()` and `loop.py`'s `model_args()` apply. The
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
runtime default. Re-run the installer to change it; generated shims are owned by
the installer and are replaced on reinstall.

The portable `inherit` selector means "use the mounted agent's model" — it is
never forwarded as a literal id. Pass a native ADK id through
`dispatch_subagent({model})` when `feature.models.<role>` carries one, so phase
and role env routes bind at dispatch rather than only on the loop-fleet
implementer. A Claude alias there is dropped rather than forwarded, the same
rule `loop.py`'s `model_args()` applies. `LOOP_SPEC_MODEL_IMPLEMENTER` still
routes fleet workers independently.

## Both run modes (parity map)

| Claude Code | ADK |
|---|---|
| interactive session | `adk web` / `adk api_server` against the mounted agent, or your own `Runner` over `build_app()` |
| `claude -p` headless / autonomous mode | `LOOP_SPEC_NON_INTERACTIVE=1 adk run "$LOOP_SPEC_ADK_AGENT_DIR" "Load the loop-spec auto skill and run: <description>" --jsonl` |
| loop-runner fleet spawning `claude -p` | same fleet spawning `adk run <agent-dir> --jsonl` — the agent CLI is resolved by `bash lib/harness.sh cli` and passed to `loop.py --agent-cli adk` (see `skills/shared/execute-loop-fleet.md`) |

Two ADK CLI facts the fleet backend encodes, both worth knowing before debugging
a run: dispatch targets a mounted agent DIRECTORY (hence
`LOOP_SPEC_ADK_AGENT_DIR` / `--adk-agent-dir`), and current one-shot `adk run`
restores the session passed with `--session_id`. (Interactive `--resume <file>`
is a separate exported-session path.) Continue-mode ticks therefore retain ADK
conversation state as well as loop-spec's durable PROGRESS notes. Read-only ticks
(`--permission-mode plan`) select the `_readonly` sibling agent; a missing one
fails closed rather than handing a judge the writable agent's edit tools.

Cost accounting is unavailable: ADK reports token counts, not money, so the
fleet records `cost_usd: None` ("unknown", never "free"). A requested
`--max-budget-usd` fails at configuration time instead of pretending a hard cap
can bind.

## Headless profile

ADK publishes no entrypoint stamp, so one-shot launchers assert the profile:
loop.py and `lib/issue-intake.sh` export `LOOP_SPEC_NON_INTERACTIVE=1`, and direct
`adk run` commands must set it as shown above. The bridge does not infer a profile
from the executable name because persistent `adk web` and `adk api_server` use
the same executable and must remain interactive. `lib/harness.sh` ranks the
explicit assertion below Claude Code's stamp and above an inherited
`LOOP_SPEC_EXECUTION_PROFILE` claim.

## Graph engine (GDD)

`lib/graph/run.sh` sequences `graph/cycle.graph.json`. Nothing under `lib/graph/`
branches on the harness — node bodies may call `lib/harness.sh`. Under ADK, agent
node dispatch continues through `dispatch_subagent`; the engine and handoff port
stay harness-neutral.
