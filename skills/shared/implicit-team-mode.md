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
is gone. The artifacts, gates, retry budgets, and result contracts are identical to
the explicit-team path.

## Substitution table (explicit team op -> implicit equivalent)

| Explicit-team primitive | Implicit-team equivalent |
|---|---|
| `TeamCreate({name, agents:[{name, subagent_type, model}, ...]})` | **No call.** The team already exists. Do not declare a roster up front. Record `feature.json.currentTeamName` (for resume bookkeeping) but create nothing. |
| Spawn a teammate + send its first work prompt | One `Agent({name: "<teammate-name>", subagent_type, model, prompt: "<work prompt>"})` call. Passing `name` makes the teammate persistent and addressable; the prompt that the explicit path delivered via the post-`TeamCreate` `SendMessage` becomes this spawn's `prompt`. |
| `SendMessage({to, body})` rework / critique / notify | **Unchanged.** `SendMessage` still exists and addresses any live named teammate (lead-to-teammate and teammate-to-teammate). |
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

- **DISCUSS / PLAN / VERIFY:** spawn each roster member (e.g. `spec-writer-1`,
  `advocate-1`, `challenger-1`, `verifier-1`, `code-reviewer-1`) with one
  `Agent({name, ...})` call carrying its first work prompt, then drive critique
  rounds and rework with `SendMessage` exactly as the explicit path describes.
  The only edits to those phases are: skip the `TeamCreate` block, fold its
  per-teammate prompt into the spawn, and skip the closing `TeamDelete`.
- **EXECUTE:** the concurrency ladder is unchanged — when it selects the team
  rung, spawn the implementers as named `Agent` teammates (no `TeamCreate`) and
  let them self-claim tasks from the shared `TaskList`. The loop-fleet and
  subagent rungs are unaffected.
- **MAP-CODEBASE:** spawn each domain mapper as a named teammate and message it
  via `SendMessage`; no `TeamCreate` / `TeamDelete`.
- **Resume / orphan detection (cycle Step 1):** a non-null `currentTeamName` from
  a prior `implicit` run refers to teammates that did not survive the session.
  Treat it like the no-teams case: clear `currentTeamName` and add the feature to
  the resumable list (no "needs cleanup" entry — there is no team to delete).

## What does NOT change

Artifacts, gates, retry budgets, worktree layout, `feature.json`
schema, phase routing, and every `{merged, blocked, escalation}` result
shape. A feature can move freely between `explicit`, `implicit`, and `none`
harnesses across resumes.
