# Implicit-team mode (reference)

Applies when `.loop-spec/runtime.json.teamsMode == "implicit"` (set by cycle Step 2
on Claude Code **>= 2.1.178**, where `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` is set).

In this harness generation the `TeamCreate` and `TeamDelete` tools were **removed**.
Every session already has exactly one implicit team, so there is nothing to create
or tear down: a teammate is just an `Agent` spawned with a `name`, and named teammates
persist for the rest of the session and are addressable by `SendMessage`. The
`team_name` parameter on `Agent` is accepted but ignored.

This is NOT the no-teams fallback. Teams are fully live here — persistent teammates,
peer messaging, and a shared task list all work. Only the *create/destroy* ceremony
is gone. The artifacts, gates, and result contracts are identical to
the explicit-team path.

Live-verified end to end on CC 2.1.187 with `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`
(2026-07-03): `TeamCreate`/`TeamDelete` absent from the tool surface; named
`Agent({name})` spawns return mailbox agents (`<name>@session-<id>`); teammates see the
shared task list, self-claim via `TaskUpdate({owner})`, and complete tasks; teammate→
teammate and teammate→main `SendMessage({to, message, summary})` all deliver.

## Model routing (named spawn ignores `model`)

A named `Agent({name})` spawn is an **in-process teammate**
(`task_type: "in_process_teammate"`). It inherits the lead's session model.
The Agent `model` parameter and the role charter's `model:` frontmatter are both
ignored — that is the harness contract
(https://code.claude.com/docs/en/agent-teams), not a loop-spec bug. Passing
`model: "sonnet"` on a named teammate is therefore a no-op: every role runs on
whatever launched the session.

`lib/implicit-team-model.sh spawn-kind --teams-mode implicit --selector <role>`
is the probe. It prints `KIND REASON` on one line:

| KIND | When | Dispatch |
|---|---|---|
| `named` | selector is `inherit` (the default) | `Agent({name, description, subagent_type, prompt})` — omit `model`. Persist and rework via `SendMessage`. |
| `oneshot` | selector is a Claude Agent alias (`sonnet`/`opus`/`haiku`/`fable`) | **nameless one-shot** `Agent({description, subagent_type, model, prompt})` — no `name`. The alias is honored. Rework is a fresh Agent call with the prior round inlined, per `skills/shared/no-teams-fallback.md`. |

Do not "add the model key per teammate" on a named implicit spawn. Either omit
`name` so the alias can bind, or leave the selector at `inherit` and keep the
persistent teammate. Mixed rosters are allowed: inherit roles stay named, aliased
roles go oneshot.

EXECUTE's team rung cannot honor an implementer alias this way (self-claim needs
named teammates). `lib/execute-rung.sh` skips that rung when the probe returns
`oneshot` and selects loop-fleet or subagent instead — those surfaces still pass
the selector.

## Substitution table (explicit team op -> implicit equivalent)

| Explicit-team primitive | Implicit-team equivalent |
|---|---|
| `TeamCreate({name, agents:[{name, subagent_type, model}, ...]})` | **No call.** The team already exists. Do not declare a roster up front. Record `feature.json.currentTeamName` (for resume bookkeeping) but create nothing. |
| Spawn a teammate + send its first work prompt | Probe `lib/implicit-team-model.sh spawn-kind` first. `named`: one `Agent({name: "<teammate-name>", description: "<short task label>", subagent_type, prompt: "<work prompt>"})` with **no** `model` key. `oneshot`: nameless one-shot `Agent({description, subagent_type, model, prompt})` so the alias binds. Passing `name` makes the teammate persistent, addressable, **and bound to the lead model**. |
| `SendMessage({to, message})` rework / critique / notify | **Unchanged.** `SendMessage` still exists and addresses any live named teammate (lead-to-teammate and teammate-to-teammate). |
| `TaskCreate` / `TaskUpdate` / `TaskList` / `TaskGet` | **Unchanged.** All teammates in the session-implicit team share the same task list; the EXECUTE self-claim model and the `team:`-scoped `TaskList` liveness probe work as written. |
| `TeammateIdle` wake / idle protocol | **Unchanged.** Idle named teammates wake on `SendMessage` exactly as documented. |
| `TeamDelete({name})` | **No call.** There is no team object to delete. At phase boundary just stop messaging the phase's teammates and clear `feature.json.currentTeamName`; the next phase spawns its own named teammates. |

## Deferred tool schemas

Modern harnesses may list `SendMessage` / `TaskCreate` / `TaskUpdate` / `TaskList` /
`TaskGet` as **deferred tools**: the tool exists, but calling it before its schema is
loaded fails with `InputValidationError` (or a "schema not loaded" error) — NOT
`No such tool available`. On that failure, call `ToolSearch("select:<ToolName>")` to
load the schema and retry the op once. Treat it as a missing capability only when
`ToolSearch` finds no match. (Full contract: cycle Step 2 "Deferred-tool rescue".)

## Phase notes

- **DISCUSS / PLAN / VERIFY:** for each roster member (e.g. `spec-writer-1`,
  `challenger-1`, `verifier-1`, `code-reviewer-1` — and `advocate-1` lazily, only when a
  critique gate escalates to the paired debate) run the spawn-kind probe on
  `feature.models.<role>`. `named`: one `Agent({name, description, subagent_type, prompt})`
  carrying its first work prompt, then `SendMessage` for critique and rework.
  `oneshot`: nameless one-shot Agent with the alias, then re-dispatch with
  `gate-logs/` inlined. Skip `TeamCreate` / `TeamDelete` either way.
- **EXECUTE:** the concurrency ladder already skips the team rung when the
  implementer selector is an alias (`lib/execute-rung.sh`). When it still selects
  team, spawn inherit implementers as named `Agent` teammates (no `TeamCreate`) and
  let them self-claim from the shared `TaskList`. The loop-fleet and subagent rungs
  honor an alias themselves.
- **MAP-CODEBASE:** same probe per mapper. `named`: persistent teammate plus
  `SendMessage`. `oneshot`: nameless Agent with the alias; no `TeamCreate` /
  `TeamDelete`.
- **Resume / orphan detection (cycle Step 1):** a non-null `currentTeamName` from
  a prior `implicit` run refers to teammates that did not survive the session.
  Treat it like the no-teams case: clear `currentTeamName` and add the feature to
  the resumable list (no "needs cleanup" entry — there is no team to delete).

## What does NOT change

Artifacts, gates, worktree layout, `feature.json`
schema, phase routing, and every `{merged, blocked, escalation}` result
shape. A feature can move freely between `explicit`, `implicit`, and `none`
harnesses across resumes.
