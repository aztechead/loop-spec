# Dispatch: how a phase launches agents and waits for them

Read by every phase skill that spawns a role. One contract for team modes, tool call
shapes (verified against live schemas), waiting, concurrency, and telemetry. Each peer
harness maps these shapes onto its own tools in its adaptation contract
(`claude-harness.md`, `opencode-harness.md`, `codex-harness.md`, `adk-harness.md`);
apply that file on top, never a from-memory translation.

## Team mode decides the mechanism

`.loop-spec/runtime.json.teamsMode` is set at cycle start by `lib/teams-capability.sh`:

| Mode | When | Spawn a role | Rework a role | Phase end |
|---|---|---|---|---|
| `explicit` | Claude Code < 2.1.178 with `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` | `TeamCreate({name, teammates:[{name, subagent_type}]})` then `SendMessage` the work prompt | `SendMessage` to the same teammate | `TeamDelete({name})` |
| `implicit` | Claude Code >= 2.1.178 with the flag | probe `lib/implicit-team-model.sh spawn-kind --teams-mode implicit --selector <feature.models.role>`: `named` → `Agent({name, description, subagent_type, prompt})` with NO `model` key; `oneshot` → nameless `Agent({description, subagent_type, run_in_background: false, model, prompt})` | `named`: `SendMessage`; `oneshot`: a fresh nameless Agent with the prior round inlined | no call; the driver clears team state |
| `none` | flag unset, or any non-Claude harness | one-shot `Agent({description, subagent_type, run_in_background: false, prompt})` with the same role and prompt template | a fresh Agent with the prior round (from `gate-logs/`) inlined | nothing |

Artifacts, gates, and result shapes are identical in every mode; a feature can resume
under a different mode. Teams are an accelerator, never a prerequisite. A named
implicit teammate inherits the session model and ignores `model`; that is why an alias
selector goes `oneshot`. EXECUTE's ladder (`lib/execute-rung.sh`) already skips the team
rung when the implementer selector is an alias. Never spawn `advocate-1`: critique is
challenger-only.

**Explicit-mode refutation.** If the first team op throws `No such tool available`,
the harness disagrees with the version gate: re-resolve to `implicit` (modern harness)
or `none`, merge-write `teamsMode` into `.loop-spec/runtime.json`, print one line, and
re-run the phase on that path. **Deferred schemas first:** `InputValidationError` or
"schema not loaded" on `SendMessage`/`TaskCreate`/`TaskUpdate`/`TaskList`/`TaskGet` is
NOT a missing tool. Call `ToolSearch("select:<Tool>")`, retry once, and only then
treat a still-missing tool as a refutation.

## Call shapes (Claude Code; other harnesses map them)

**Verification method:** these shapes are checked against the live tool schemas, not
the prose docs. The Agent `model` enum was re-verified on 2026-08-11 by issuing
`Agent({model: "inherit"})`, which returns `InputValidationError: Invalid option:
expected one of "sonnet"|"opus"|"haiku"|"fable"`. Re-verify after a harness upgrade
with `ToolSearch("select:<Tool>")` in a live session and diff against this file;
`tests/lib/harness-call-shapes.test.sh` lints the skill corpus against it.

```
Agent({
  description: "<3-5 word task label>",   // REQUIRED
  prompt: "<the task>",                    // REQUIRED
  subagent_type: "loop-spec:<role>",       // optional; omit = general-purpose
  run_in_background: false,                // REQUIRED on every one-shot Agent; see Waiting
  model: "sonnet" | "opus" | "haiku" | "fable",  // optional; ALIAS ENUM — "inherit" and literal IDs REJECTED
  name: "<teammate-name>",                 // optional; named = persistent in-process teammate, SendMessage-addressable
  mode: "acceptEdits" | ... | "plan",      // deprecated and ignored since CC 2.1.212
})
SendMessage({ to: "<name>", message: "<text>", summary: "<5-10 words>" })   // `body` is invalid
TaskCreate({ subject: "...", description: "...", activeForm: "...", metadata: {...} })   // description REQUIRED
TaskUpdate({ taskId, status, owner, metadata, addBlocks, addBlockedBy })
TaskList()            // no parameters on the modern harness; filter client-side
TaskList({team})      // explicit mode only: the orphan-liveness probe
TaskGet({ taskId })
AskUserQuestion({ questions: [{ question, header /* <= 12 chars */,
  options: [{label, description}, ...] /* 2-4 */, multiSelect: false }] })
EnterWorktree({ path })  ExitWorktree({ action: "keep" | "remove" })   // Claude Code only
Skill({ skill: "loop-spec:<name>", args: "..." })
```

`model` never carries `inherit` or a full model ID; inheritance is expressed by
omitting the key (`model-matrix.md`). A named `Agent({name})` is an in-process teammate
that inherits the session model and ignores `model` (that is why `lib/implicit-team-model.sh`
routes an alias to a nameless one-shot). Every one-shot (nameless) Agent carries
`run_in_background: false`; `run_in_background: true`, `team_name`, and `mode` are
never emitted. "Other" is added to `AskUserQuestion` automatically; a question that
says it is "not a real question", or carries dummy options, is forbidden.

Peer harness surfaces (full tables in each adaptation contract):

- **ADK harness**: `dispatch_subagent` over `AgentTool` takes `{description, prompt,
  subagent_type}` (`adk-harness.md`).
- **opencode harness**: `Agent` → native `task`
  `{description, prompt, subagent_type, task_id?, command?}`, agent ids
  `loop-spec-<role>` (`opencode-harness.md`).
- **Codex harness**: `Agent` → `spawn_agent`; `AskUserQuestion` → `request_user_input`,
  which blocks when a human is attached, so apply the HITL rule before calling
  (`codex-harness.md`).
- `run_in_background` has no peer equivalent: `task`, `spawn_agent`, and
  `dispatch_subagent` block until the child returns, and each adaptation contract
  drops the key.

## Waiting

A one-shot Agent is meant to run in the foreground: `run_in_background: false` on the
call, so the tool result IS the subagent's report and the step reads it there. Claude
Code's fork mode launches an Agent in the background by default, the key on the call
does not override it (a headless 6.3.0 run saw the stub on all eight calls), and a
background launch answers with a launch stub ("Async agent launched"), not the report;
the report arrives later as a task notification. The operator's switch is the harness's
own: `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` in the session environment forces
foreground execution (`skills/shared/claude-harness.md`); every headless launcher this
plugin ships sets it. A lead that read the stub as an empty report dispatched the SPEC
pruner twice. A stub therefore means the key was dropped: end the turn and wait for
the notification; never re-dispatch on a stub. Independent lead work belongs before
the Agent call, not in the wait.

Named teammates (explicit and implicit team modes) are the exception: send the work,
then stop. The harness resumes the turn when an Agent returns, a teammate goes idle
(`TeammateIdle`), or a background Bash task exits; adjudicate then. This holds
under `claude -p` too: a pending Agent, teammate reply, or background task keeps the
process alive and its completion re-invokes the lead, so ending the turn never ends the
run (verified on the 2026-09-07 live headless runs). Do independent lead work while a
wave runs; stop only at the join. Never AskUserQuestion as a wait, keep-alive, or placeholder
(`hooks/team/placeholder-question-guard.sh` blocks it on Claude Code).
Never `sleep` to join a background Agent, and never poll. A teammate's plain-text output is invisible
and its last `SendMessage` can be dropped: on the team rung the source of truth is
`TaskList` state at every wake, not messages. A teammate that goes idle without its
artifact gets ONE re-dispatch; a second miss is a real stuck-teammate question in
interactive styles and lead-authored output in autonomous mode (recorded in
`warnings[]`).

## Concurrency

`LOOP_SPEC_MAX_PARALLEL_SUBAGENTS=N` (optional, positive integer) caps simultaneous
one-shot Agents deployment-wide: issue Agent calls in waves of at most N, await each
wave, leave nothing running across a later dispatch point, and skip optional background
prefetches. `N=1` is serial. The capability scripts disable teams, Workflow fan-out, and
loop fleets under the cap; EXECUTE also clamps `maxParallelImplementers` to N. One-shot
Agents share the lead's cwd, so parallel implementers need lead-created task worktrees
(`subagentIsolation=lead-worktree`); a failed `git worktree add` serializes the wave.

## Workflow fan-out (opt-in rung)

Fan-out points (`plan` multi-angle, `verify` acceptance and code-review, `execute` DAG)
read `.loop-spec/runtime.json.workflowsAvailable` (missing file = false). When true and
the point's opt-in holds, dispatch
`Workflow({scriptPath: "${CLAUDE_SKILL_DIR}/../../lib/workflows/<name>.js", args})`,
persist `feature.json.activeWorkflow = {scriptPath, args, startedAt}` while it runs, and
clear it after. Otherwise run the Agent path; both branches return the same JSON shape.

## Telemetry (dispatch telemetry contract)

Emit one event per agent launched (never per `SendMessage` rework round; one per
compiled task at loop-fleet launch), always non-fatal:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit ".loop-spec/features/${slug}" dispatch \
  --phase "<phase>" --data '{"role":"<role>","model":"<resolved selector>","rung":"<team|subagent|loop-fleet|workflow>"}' || true
```
