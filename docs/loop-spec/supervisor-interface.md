# The supervisor interface

For the engineer who embeds loop-spec in an autonomous agent on the Claude Agent SDK or
Google ADK, and for the maintainer who changes the plugin's boundary. When you finish
this page you can name the four ports a supervisor may implement, run the default
adapter that reproduces today's behavior, and see which increment adds what.

This page explains why the boundary sits where it does. The operating contract for each
port lives in the script header the port names; read the header before the code
(`bash lib/surface.sh show <name>`).

## Intent

These are the decisions from the design interview that shaped this page. Each one is a
constraint the rest of the page must satisfy.

- **The primary consumer is an autonomous agent** built on the Claude Agent SDK or
  Google ADK. Humans use Claude Code and opencode. All four harnesses stay peers behind
  `lib/harness.sh`; the two agent harnesses are proven first.
- **One agent takes a request end to end.** There is no swarm splitting a plan. The
  agent dies sometimes, and context fills up. Phase handoff
  (`LOOP_SPEC_PHASE_HANDOFF=1`) is how the run survives both.
- **The plugin ships interfaces, not opinions.** It owns the artifacts (`feature.json`,
  the phase markdown, `events.jsonl`, `decisions.jsonl`, the terminal result) and the
  contract each port obeys. The supervisor owns transport and policy: where state lives
  between deaths, where events go, who answers a question, when to retry.
- **Every port ships with today's behavior as its default adapter.** A user who sets
  nothing sees no change.
- **The four failures seen in the field** are a wrong answer at an interview point, a
  stall or a spin, a resume that misreads state, and a PR that passes every check and
  is still wrong. The oracle port targets the first; the store port targets the third.
- **The measure of success** is a cycle that ships a mergeable PR with no human turn.

## The boundary

```
supervisor (yours)                      plugin (loop-spec)
------------------                      ------------------
transport: fs | git | S3 | db   <---->  store port      lib/supervisor/store.sh
event stream, logs, metrics     <---->  event sink      lib/events.sh sink
answers, policy, halt           <---->  decision oracle lib/supervisor/oracle.sh
retry, lease, budget, relaunch  <---->  lifecycle       phase handoff + handoff port
```

A port is an executable the supervisor names by environment variable or profile. The
plugin never learns the transport. This is the same shape as the existing handoff port
(`skills/shared/handoff-port.md`): one reference adapter in the tree, a conformance
suite any adapter must pass, and `LOOP_SPEC_PORT` to point elsewhere.

## Port 1: state store

**Problem.** The feature directory `.loop-spec/features/{slug}` is the resume contract
(`skills/shared/feature-state-schema.md`). It lives in the checkout and the cycle
commits it at each phase transition (`lib/phase-exit.sh:86`). A supervisor on an
ephemeral container must persist the checkout or lose the run
(`docs/loop-spec/cloud-run-autonomous.md`, "Persist the control checkout").

**Where the seam sits.** Ninety-three files read `feature.json` from disk
(`grep -rl 'feature\.json' lib hooks skills agents extensions`). Every write already
goes through one script, `lib/feature-write.sh:114`. Routing each read through a
subprocess port would multiply cost by the reader count and rewrite the atomic-write
contract for no gain. The port therefore sits at the **durability boundary**: the
working copy on disk stays the working copy; the port decides where it is durable.

**Contract** (`lib/supervisor/store.sh`, dispatcher; adapter from `LOOP_SPEC_STORE`):

| Operation | Meaning | Default adapter (`store-local.sh`) |
|---|---|---|
| `open <feature-dir>` | Make the working copy present before a phase reads it | no-op: the checkout is the store |
| `persist <feature-dir> <reason>` | Make the working copy durable after a write | no-op: `phase-exit.sh` still commits |
| `list` | Slugs the store holds, one per line | the `.loop-spec/features/*` directories |
| `describe` | One line: `store=<name> reason=<text>` | `store=local reason=checkout-is-store` |

**Call sites.** `persist` after the rename in `lib/feature-write.sh`, and after
`commit_paths` in `lib/phase-exit.sh`. `open` and `list` in the resume scan of
`lib/cycle-preflight.sh:98`, so a store that holds a slug the checkout lacks
materializes it before the scan parses it.

**Failure rule.** `open` and `persist` fail loudly with exit 2; `feature-write.sh`
reports it as an I/O failure. A store the supervisor chose and that cannot hold state
is data loss waiting for the next death. The local adapter cannot fail.

**Second adapter.** `store-mirror.sh` copies the feature directory to
`$LOOP_SPEC_STORE_DIR/<slug>` on `persist` and restores it on `open` when the working
copy is absent. It is small, it is what a mounted volume needs, and it proves the seam
holds two implementations. A git-remote or object-store adapter is the supervisor's.

**Conformance.** `tests/lib/supervisor-store-contract.test.sh <adapter>` runs against
any adapter; the tree runs it against both bundled ones.

## Port 2: event sink

**Today.** `lib/events.sh emit` appends one JSON line to `<feature-dir>/events.jsonl`
and prints phase markers (`lib/events.sh:365`). The terminal result prints as
`LOOP_SPEC_RESULT {...}` and lands in `.loop-spec/last-result.json`
(`docs/loop-spec/agent-output-contract.md` describes both). A supervisor tails a file
or parses stdout.

**Change.** `LOOP_SPEC_EVENT_SINK` names an executable. `events.sh sink` reads one JSON
line on stdin and hands it to that executable on its stdin; `emit` calls `sink` after
the append, and `lib/cycle-result.sh` calls it at publication with the terminal result
wrapped as an event named `result`. The file and the markers stay: the sink is
additive.

**Failure rule.** The observability contract holds: a sink that fails prints one
warning and `events.sh` exits 0. A broken sink never kills a two-hour run.

## Port 3: decision oracle

**Today.** Two modes exist. With a human attached, SPEC, DISCUSS, and PLAN interview
through the harness's native question tool: `AskUserQuestion` on Claude Code and the
Agent SDK, `question` on opencode, `get_user_choice` on ADK, `request_user_input` on
Codex (each harness contract maps the call). In autonomous mode no question is asked;
the orchestrator takes the answer it would have recommended and records it
(`skills/shared/autonomous-mode.md`, "The self-answer rule").

An SDK supervisor already answers questions today: the Agent SDK routes every
`AskUserQuestion` call to the `canUseTool` (Python `can_use_tool`) callback, and the
callback returns the answers as `updatedInput.answers`, keyed by question text
(Agent SDK guide "Handle approvals and user input"). ADK routes `get_user_choice` to the
caller as a long-running function call the caller resumes. So the interface exists on
both agent harnesses. What is missing is the middle mode: a run that is autonomous
**and** whose supervisor may answer.

**Change.** `lib/supervisor/oracle.sh mode --feature-dir DIR` is a probe. It answers
one line, `oracle=<human|supervisor|self> reason=<text>`:

| Answer | When | What the phase does |
|---|---|---|
| `human` | not autonomous | the interview path, unchanged |
| `supervisor` | autonomous and `LOOP_SPEC_ORACLE=supervisor` | ask through the native question tool; then apply the rules below |
| `self` | autonomous, `LOOP_SPEC_ORACLE` unset or `self` | the self-answer rule, unchanged (default) |

Rules on the `supervisor` path:

1. The question is the same question self-answer would have formulated. The recommended
   option is first and labeled `(Recommended)`, so a supervisor with no opinion can pick
   it by position.
2. An answer records as kind `supervised` in `decisions.jsonl` (`lib/decisions.sh add`
   gains that kind). An answer that is the recommended option, an empty answer, and a
   denied or failed tool call all fall back to the self-answer rule and record kind
   `assumed` with the rationale naming why.
3. A free-text answer of exactly `halt` pauses the cycle with a terminal result whose
   reason is `oracle-halt`; the supervisor resumes the cycle with the answer pinned
   through `LOOP_SPEC_ANSWER_*` or an edited SPEC.
4. Precedence is unchanged: a pinned `LOOP_SPEC_ANSWER_*`, a rule in `RULES.md`, or a
   decision already on record is never re-asked.

Why every question and not only high-stakes ones: a stakes tag would be a model judgment
that selects a code path, which this project replaces with probes (CLAUDE.md). The
supervisor is the policy layer; it filters by returning the recommendation. A later
probe may classify stakes from the perspective that asked (Boundary Keeper, Failure
Analyst); it is not in this increment.

The oracle only refines the self-answer path that `lib/phase-mode.sh` already selects.
It never selects a phase, and it never runs inside a dispatched agent: the SDK does not
offer `AskUserQuestion` to subagents, and loop-spec interviews are main-thread already.

## Port 4: lifecycle

No new code. The supervisor owns retry, timeout, budget, and relaunch; the plugin owns
idempotent phases and a claimable unit of work. The pieces exist and this page names
them as one port:

- **Phase handoff.** `LOOP_SPEC_PHASE_HANDOFF=1` returns after each durable phase with a
  paused `phase-handoff` result. The supervisor reissues the cycle command and resume
  detection continues (`docs/loop-spec/cloud-run-autonomous.md`).
- **Armed runs.** `.loop-spec/active-run.json` is armed at routing and disarmed only by
  a published terminal result; `lib/cycle-reconcile.sh` converts a surviving armed run
  into a result after a death (`docs/loop-spec/agent-output-contract.md`).
- **Claim and lease.** The handoff port (`skills/shared/handoff-port.md`) gives a
  supervisor `claim`, `release`, and `complete` with an expiring lease and a state-hash
  check.

## Profile presets

**Problem.** `docs/loop-spec/configuration.md` documents 154 variable rows. A supervisor
cannot tell which ten matter, and the cloud-run page carries a block of eighteen
exports that every embedding copies by hand.

**Change.** `.loop-spec/profile.json` holds a preset name and overrides:

```json
{ "preset": "supervised", "env": { "LOOP_SPEC_ITERATE_MAX_ITERATIONS": "3" } }
```

`lib/profile.sh` reads it. `presets` lists the names; `show <preset>` prints one;
`env` prints `export` lines for the resolved profile, **skipping any variable already
set in the environment**, so the documented precedence holds (an explicit variable wins
over persisted project state). `validate` rejects unknown presets and unknown variable
names. Presets:

| Preset | What it sets | For |
|---|---|---|
| `interactive` | nothing | a human at a terminal (default) |
| `autonomous` | autonomous, non-interactive, oracle `self` | `claude -p`, `opencode run`, `adk run`, `codex exec` with no supervisor |
| `supervised` | `autonomous` plus oracle `supervisor`, phase handoff, checkpoint each phase | an SDK or ADK supervisor that answers and relaunches |
| `cloud` | `autonomous` plus phase handoff, checkpoint each phase, and the cloud-run resource policy; add `LOOP_SPEC_ORACLE=supervisor` in `env` when the launcher answers questions | an ephemeral container |

The launcher applies the profile: `eval "$(bash lib/profile.sh env)"` before
`claude -p`, or the same lines as the SDK `env` option. Inside the tree,
`cycle-preflight.sh`, `phase-mode.sh`, and the supervisor probes apply it themselves, so a
profile file works when the launcher forgot. `cycle-preflight.sh` reports
`profile:{preset,source}` so the run's first line says what policy it is under.

## The workbench pack

**Decision.** Skills a human runs at a terminal leave the core plugin: `walkthrough`,
`onboard`, `forensics`, `assess`, `sentinel`, `intake`, and `watch`. The first four are
diagnostics and tours. The last three are work sources and a queue, which is a supervisor
concern; behind the interface above they are one supervisor among many.

**Measure before cutting.** Those seven skills hold 1,185 of the 4,906 lines of skill
prose (`wc -l skills/*/SKILL.md`) and every one of their descriptions loads into the
model's context on each session. No `lib/` script is referenced only by them: the
scripts they call are shared with the core. The cut shrinks what the running agent
holds, not the script count. `retro` stays: its auto path runs at every autonomous
completion (`skills/shared/autonomous-mode.md`, "Precedence" item 4).

**Shape.** A second plugin in the same marketplace, `loop-spec-workbench`, sourced from
`packs/workbench/` with its own `plugin.json`. `.claude-plugin/marketplace.json` lists
both. The opencode, Codex, and ADK installers gain a `--pack workbench` flag. The core
keeps every script the pack calls.

**Sequence.** This is increment 3 and is not in this change. It moves files four
installers and several coverage suites pin, and it should land on top of a proven
interface, not beside it.

## Native integration map

Each port lands on a seam the harness already ships. Nothing below is a loop-spec
invention; the plugin's side is the executable named in the left column, the
supervisor's side is the SDK or ADK feature named in the other two. Sources: the
Agent SDK guides "Handle approvals and user input", "Work with sessions", "Persist
sessions to external storage", "Intercept and control agent behavior with hooks", and
"Plugins in the SDK"; ADK's `Runner.run_async`, `BasePlugin`, `BaseArtifactService`,
`LongRunningFunctionTool`, and `get_user_choice` sources (google/adk-python, main).

| Port | Claude Agent SDK (Python / TypeScript) | Google ADK |
|---|---|---|
| profile (`lib/profile.sh`) | `ClaudeAgentOptions.env` / `options.env`: a dict merged onto the process environment; pass `profile.sh resolve` `.env` | `LocalEnvironment(env_vars=...)`: `extensions/adk/loop_spec_adk/bridge.py` resolves the profile itself, under the process environment |
| plugin load | `plugins=[{"type": "local", "path": <checkout>}]`; the init `SystemMessage` lists `plugins` and `skills` | `lib/adk-install.sh` mounts the package; skills load through `SkillToolset` |
| state store (`lib/supervisor/store.sh`) | The working directory is the store's key on both sides: `cwd` for the run, `projectKey` for a `session_store` / `sessionStore` adapter that mirrors transcripts. A supervisor with an S3 session store adds an S3 store adapter keyed the same way. | `Runner(artifact_service=...)`: `BaseArtifactService.save_artifact(app_name, user_id, filename, artifact, session_id)` holds a feature bundle per slug; a store adapter that calls it is increment 2 |
| event sink (`lib/events.sh sink`) | Native: a `PostToolUse` hook (`HookMatcher(matcher="Bash")`) receives `tool_input` and `tool_response`, where the `LOOP_SPEC_PHASE_START`, `LOOP_SPEC_PHASE_END`, and `LOOP_SPEC_RESULT` markers appear. Port: `LOOP_SPEC_EVENT_SINK` for every line, markers or not | `BasePlugin.after_tool_callback(tool, tool_args, tool_context, result)` sees each Execute result; `on_event_callback` sees every `Event`. Port: `LOOP_SPEC_EVENT_SINK` |
| decision oracle (`lib/supervisor/oracle.sh`) | `can_use_tool` / `canUseTool` with `tool_name == "AskUserQuestion"`; return `PermissionResultAllow(updated_input={"questions": ..., "answers": {question: label}})`. A `PreToolUse` hook may return `permissionDecision: "defer"` to end the query and resume later | `get_user_choice` is a `LongRunningFunctionTool`; the event carries `long_running_tool_ids`, the run pauses, and the caller resumes with a `FunctionResponse` for that call id |
| lifecycle | `ResultMessage.session_id`; `resume=<id>` and `fork_session`; `max_turns` and `max_budget_usd`; `continue_conversation`. Cross-host: `session_store` | `Runner.run_async(user_id, session_id, invocation_id=...)`: "set this to resume an interrupted invocation"; `App.resumability_config`; `RunConfig` |

Two things the SDK offers that the plugin deliberately does not wrap:

- **Transcript mirroring is the SDK's** (`session_store`). The store port mirrors
  feature state, which outlives any transcript. A supervisor that wants both keys them
  by the same working directory.
- **Cost and turn budgets are the SDK's** (`max_budget_usd`, `max_turns`). The plugin
  bounds iterations (`LOOP_SPEC_ITERATE_MAX_ITERATIONS`) and rounds (critique
  ceilings), never dollars.

The reference supervisor `examples/supervisor/supervisor.py` runs every row of the
SDK column; its README maps each port to the function that implements it.

## What does not change

- `feature.json`, `events.jsonl`, `decisions.jsonl`, the terminal result, and every
  phase artifact keep their schema. New fields are additive.
- An install that sets no port and no profile runs exactly as before. The default
  adapters are the current behavior.
- Autonomy authority is untouched. `lib/trust.sh`, `lib/autonomous-chain.sh`, and
  `lib/task-route.sh` do not read the profile or any port. A port can route state and
  answers; it cannot switch a gate off, for the reason `lib/extension-points.sh` gives.
- Model selection stays with the harness (`skills/shared/model-matrix.md`).

## Sequence and evidence

| Increment | Lands | Evidence |
|---|---|---|
| 1 | profile presets; store port with local and mirror adapters; event sink; oracle probe and the supervised path in SPEC, DISCUSS, PLAN | unit suites for each script; the store conformance suite against both adapters; harness coverage suites pin the new cites; one live autonomous run on Claude Code with the `supervised` preset, a file sink, and a mirror store |
| 2 | ADK bridge wires `get_user_choice` to the oracle path; opencode `question` and Codex `request_user_input` mappings cite the oracle | harness coverage suites; one live ADK run |
| 3 | the workbench pack | installer suites; a fresh install of core alone runs a full cycle |

## Rejected alternatives

| Alternative | Why rejected |
|---|---|
| Route every `feature.json` read through the store port | 93 readers, one subprocess each; rewrites the atomic-write contract for no supervisor gain |
| Ship a supervisor loop in the plugin | An opinion about transport and retry; the interview asked for interfaces only |
| Halt the cycle on every unanswered question | Costs a round trip per question; the default stays momentum with an audit trail |
| A stakes tag that decides which questions reach the supervisor | A model judgment selecting a code path; the supervisor filters instead |
| Profile file that can disable gates | Authority controls stay with tested scripts, never with config (`lib/extension-points.sh`) |
| Drop the ADK adapter | It is one of the two autonomous harnesses this design serves |
