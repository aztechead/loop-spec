# User-gate flow (verification enforcement)

**Slug:** `user-gate-flow`
**Created:** 2026-05-28
**Tier:** quick
**Execution style:** auto

## Problem

In long-running agent sessions the agent silently substitutes a cheaper verification method for the one the user requested, or skips verification entirely, then declares the task done. The user discovers the failure only after the session ends. loop-spec has no mechanism to detect or block this pattern.

The failure is structural: the executing-plans skill has no self-check gate, no evidence requirement at task close, and no harness-level net that catches end-of-plan completion claims made without proof.

## Goals

- Provide a `checking-gates` skill that codifies the "do I know HOW?" three-element self-check and routes ambiguous gates to `specifying-gates` before any verification attempt.
- Provide a `specifying-gates` skill that elicits a concrete observable, capture method, scope, and failure policy from the user via four sequential `AskUserQuestion` calls, then writes the answers back into the task's metadata.
- Add a `post-task-complete-revalidate.sh` hook (event `TaskCompleted`) that scans the transcript window for `AC:` and `PROVEN BY` markers whenever a `userGate: true` task is closed, blocking the close with exit 2 if evidence is absent.
- Add a `stop-revalidate-user-gates.sh` hook (event `Stop`) that acts as a final net, scanning all closed user-gate tasks for missing evidence when the assistant makes a plan-complete claim.
- Add a `pre-task-blockedby-enforce.sh` hook (event `PreToolUse:TaskUpdate` on `status=in_progress`) that blocks an implementer from starting a task whose `blockedBy` entries are not all `completed`.
- Add a `stop-deflection-guard.sh` hook (event `Stop`) that blocks low-context excuse phrases when actual context usage is below a configurable threshold.
- Extend `skills/shared/feature-state-schema.md` with 9 optional task metadata fields that the new skills and hooks consume.
- Update `lib/validate-task-metadata.sh` to accept (without requiring) the 9 new optional fields.
- Wire all 4 new hooks into `hooks/hooks.json`.

## Non-goals

- `pre-agent-task-dispatch-validate.sh` and `post-agent-return-validate.sh` hooks. loop-spec uses persistent `TeamCreate` teammates routed via `SendMessage`, not per-task `Agent` dispatches, so dispatch validation hooks provide no value in this codebase. These are explicitly deferred.
- Any Cycle 3-5 work.
- Mandatory user-gate enforcement. All new behavior is opt-in via `userGate: true` in task metadata.
- Modifications to existing loop-spec hooks (`restrict-agent-paths.sh`, `task-created.sh`, `task-completed.sh`, `teammate-idle.sh`).
- Interrupting the user during plan writing. Tagging (`userGate: true`, `requiresUserSpecification: true`) happens silently at plan time; clarification questions are deferred to execution time.

## Constraints

- Runtime stack: `bash`, `git`, `jq`, `python3` (stdlib only). No npm, pip, or brew dependencies.
- All 4 new hooks are opt-in. Each exposes a kill-switch environment variable that, when set to `0`, causes the hook to exit 0 unconditionally without reading any input.
- All 4 new hooks are fail-open. Any read error, JSON parse failure, transcript access error, or unexpected exception must cause the hook to exit 0 rather than block the session.
- All 4 new hooks write to a shared trace log: `${LOOP_SPEC_USERGATE_TRACE_LOG:-/tmp/claude-hooks/loop-spec-user-gate-trace.log}`. One pipe-separated line per decision point: `timestamp|hook-name|task-id|event|reason`.
- Existing hooks are not modified. Only new files are added and `hooks/hooks.json` is updated.
- Commit format: `<type>: NO_JIRA <message>`.

## User-facing behavior

When a plan contains a task tagged `userGate: true` in its `json:metadata` fence, the agent invokes `checking-gates` instead of executing the verification inline.

The checking-gates skill runs a three-element self-check on each acceptance criterion: (a) is a named observable present, (b) is a concrete capture method named, (c) is a pass/fail rule named. If any element is missing or vague (phrases like "it works", "is fine", "as expected", "properly" without a concrete target), the skill routes to `specifying-gates` (Path A). If all three elements are present and concrete for every criterion, the skill runs the verification directly (Path B).

When `specifying-gates` runs, it asks the user four questions one at a time via `AskUserQuestion`: (1) what is the exact observable state, (2) what is the capture mechanism (CLI, REST, subagent, direct read), (3) what is the scope (once / per-target / one-then-all / custom), (4) what happens on failure (stop-plan / reopen-continue / log-continue). If the user selected "Subagent with briefing" for question 2, a fifth question collects the dispatch contract. After all answers are collected, the skill rewrites the task's `json:metadata` fence with the concrete fields, removes `requiresUserSpecification`, appends a human-readable "Specification" section above the fence, and returns control to executing-plans without running the verification itself.

When the agent marks a `userGate: true` task as completed, `post-task-complete-revalidate.sh` fires. It scans the session transcript from the point the task transitioned to `in_progress` forward, looking for `AC:` and `PROVEN BY` tokens in assistant text. If neither marker is found and no direct user message confirmed the close in that window, the hook emits a structured rejection to stderr and exits 2, forcing the agent to produce explicit per-criterion evidence before proceeding.

When the agent makes a plan-complete or all-gates-passed statement, `stop-revalidate-user-gates.sh` fires on the `Stop` event. It walks the full session transcript, identifies all closed user-gate tasks, checks each for `AC:` / `PROVEN BY` markers in assistant text after the close, and blocks with exit 2 if any gate is missing evidence.

When the agent attempts to transition any task to `in_progress`, `pre-task-blockedby-enforce.sh` fires. It reconstructs the task DAG from the transcript and exits 2 with a list of unmet blockers if any `blockedBy` entry is not yet `completed`.

When the agent ends a turn with context-excuse language (e.g., "fresh session", "context is full", "context is high"), `stop-deflection-guard.sh` fires. It measures actual context usage from the transcript's usage data and blocks with exit 2 if context usage is below the configured threshold percentage, citing the actual usage in the rejection.

## Success criteria

The following criteria define done. Each can be verified with the command shown.

- [ ] `skills/checking-gates/SKILL.md` exists and contains all required sections: the announce statement, three-step process (Load and classify, Route, Execute and post evidence), Path A/B routing rules, the three-element self-check definition (observable named, capture method named, pass/fail rule named), `failurePolicy` handling for all three enum values (`stop-plan`, `reopen-continue`, `log-continue`), the "What NOT to do" list, and the integration block.
  Verify: `grep -c "Path A\|Path B\|PROVEN BY\|failurePolicy\|stop-plan\|reopen-continue\|log-continue" skills/checking-gates/SKILL.md` returns 6 or more.

- [ ] `skills/specifying-gates/SKILL.md` exists and contains all required sections: the announce statement, when-to-run trigger conditions (`requiresUserSpecification: true`, ambiguous self-check, `/specify-gate` manual invocation), all four `AskUserQuestion` blocks (Q1 observable, Q2 mechanism, Q3 scope, Q4 failure policy), the optional Q5 dispatch contract block, the writing-back section (json:metadata fence rewrite, Specification section append, `requiresUserSpecification` removal), and the integration block.
  Verify: `grep -c "AskUserQuestion\|requiresUserSpecification\|gateScope\|failurePolicy\|subagentBrief\|Specification" skills/specifying-gates/SKILL.md` returns 6 or more.

- [ ] `hooks/team/post-task-complete-revalidate.sh` exists and is executable.
  Verify: `test -x hooks/team/post-task-complete-revalidate.sh && echo PASS`.

- [ ] `hooks/team/post-task-complete-revalidate.sh` exits 2 when a `userGate: true` task is closed with no `AC:` or `PROVEN BY` tokens in the transcript window and no direct user message in the window.
  Verify: `bash hooks/team/post-task-complete-revalidate.test.sh` passes the "miss" case.

- [ ] `hooks/team/post-task-complete-revalidate.sh` exits 0 when a `userGate: true` task is closed and `AC:` + `PROVEN BY` tokens are present in the transcript window.
  Verify: `bash hooks/team/post-task-complete-revalidate.test.sh` passes the "match" case.

- [ ] `hooks/team/stop-revalidate-user-gates.sh` exists and is executable.
  Verify: `test -x hooks/team/stop-revalidate-user-gates.sh && echo PASS`.

- [ ] `hooks/team/stop-revalidate-user-gates.sh` exits 2 when the last assistant message contains a plan-complete phrase and at least one closed `userGate: true` task has no post-close `AC:` / `PROVEN BY` markers in the transcript.
  Verify: `bash hooks/team/stop-revalidate-user-gates.test.sh` passes the "blocked" case.

- [ ] `hooks/team/pre-task-blockedby-enforce.sh` exists and is executable.
  Verify: `test -x hooks/team/pre-task-blockedby-enforce.sh && echo PASS`.

- [ ] `hooks/team/pre-task-blockedby-enforce.sh` exits 2 (emitting a `hookSpecificOutput` block with `permissionDecision` absent or `deny`) when `TaskUpdate` to `in_progress` is attempted and a listed `blockedBy` task is not `completed`.
  Verify: `bash hooks/team/pre-task-blockedby-enforce.test.sh` passes the "blocked dep" case.

- [ ] `hooks/team/stop-deflection-guard.sh` exists and is executable.
  Verify: `test -x hooks/team/stop-deflection-guard.sh && echo PASS`.

- [ ] `hooks/team/stop-deflection-guard.sh` exits 2 when the last assistant text contains a deflection phrase and context usage (input_tokens + cache_read_input_tokens + cache_creation_input_tokens) is below the configured threshold percentage of `LOOP_SPEC_CONTEXT_LIMIT`.
  Verify: `bash hooks/team/stop-deflection-guard.test.sh` passes the "deflection below threshold" case.

- [ ] All 4 hooks honor their respective kill-switch env var (`LOOP_SPEC_USERGATE_GUARD=0`, `LOOP_SPEC_USERGATE_STOP_GUARD=0`, `LOOP_SPEC_BLOCKEDBY_GUARD=0`, `LOOP_SPEC_DEFLECTION_GUARD=0`): setting the var to `0` causes the hook to exit 0 unconditionally regardless of input.
  Verify: Each hook's `.test.sh` passes a "kill-switch" case.

- [ ] All 4 hooks fail-open: when the transcript path is missing or the JSON input is malformed, the hook exits 0 without blocking.
  Verify: Each hook's `.test.sh` passes a "fail-open" case (empty or corrupt input).

- [ ] All 4 hooks write at least one pipe-separated trace-log line to `${LOOP_SPEC_USERGATE_TRACE_LOG:-/tmp/claude-hooks/loop-spec-user-gate-trace.log}` per invocation. The line format is `<ISO-8601-timestamp>|<hook-name>|<task-id-or-?>|<event>|<reason>`.
  Verify: After running each hook's test suite, `cat /tmp/claude-hooks/loop-spec-user-gate-trace.log` (or the overridden path) contains at least one line per hook in pipe-separated format.

- [ ] `skills/shared/feature-state-schema.md` documents all 9 new optional task metadata fields in the "Harness task list usage" table: `userGate` (bool), `requireEvidenceTokens` (array of arrays), `requireABCompare` (bool), `subagentType` (string), `model` (string), `dispatchBrief` (string), `failurePolicy` (string enum: `stop-plan` | `reopen-continue` | `log-continue`), `gateScope` (string enum: `once` | `per-target` | `one-then-all` | `custom`), `requiresUserSpecification` (bool). All are marked optional.
  Verify: `grep -c "userGate\|requireEvidenceTokens\|requireABCompare\|subagentType\|dispatchBrief\|failurePolicy\|gateScope\|requiresUserSpecification" skills/shared/feature-state-schema.md` returns 8 or more distinct fields documented.

- [ ] `lib/validate-task-metadata.sh` accepts metadata objects that include any subset of the 9 new fields alongside the 4 required fields, without exiting 2.
  Verify: `bash tests/lib/validate-task-metadata.test.sh` passes all cases including new cases with `userGate`, `failurePolicy`, `gateScope`, `requiresUserSpecification`, `requireEvidenceTokens`, `requireABCompare` present and absent.

- [ ] `hooks/hooks.json` chains the `TaskCompleted` event: `task-completed.sh` fires first (with `continueOnBlock: true`), then `post-task-complete-revalidate.sh` (also with `continueOnBlock: true`). The `Stop` event wires both `stop-revalidate-user-gates.sh` and `stop-deflection-guard.sh`. A `PreToolUse` entry with matcher `TaskUpdate` wires `pre-task-blockedby-enforce.sh`.
  Verify: `jq '.hooks.TaskCompleted | length' hooks/hooks.json` returns 2; `jq '.hooks.Stop | length' hooks/hooks.json` returns 2 (or the array entry has 2 hooks); `jq '.hooks.PreToolUse | map(select(.matcher == "TaskUpdate")) | length' hooks/hooks.json` returns 1.

- [ ] `bash tests/run-all.sh` exits 0 with no failures (no regression in existing suites).
  Verify: `bash tests/run-all.sh`.

- [ ] `bash tests/validate-agents.sh` exits 0 with the output `All 12 agents validated.` (no new agent files added, count unchanged).
  Verify: `bash tests/validate-agents.sh | grep "All 12 agents validated."`.

- [ ] `CHANGELOG.md` contains entries under `[Unreleased]` in a `### Added` section documenting: `checking-gates` skill, `specifying-gates` skill, `post-task-complete-revalidate.sh` hook, `stop-revalidate-user-gates.sh` hook, `pre-task-blockedby-enforce.sh` hook, `stop-deflection-guard.sh` hook, and the 9 new optional task metadata fields.
  Verify: `grep -c "checking-gates\|specifying-gates\|post-task-complete-revalidate\|stop-revalidate\|pre-task-blockedby\|stop-deflection" CHANGELOG.md` returns 6 or more.

- [ ] No em-dash character (U+2014) appears anywhere in any new or modified file.
  Verify: `grep -rP "—" skills/checking-gates/ skills/specifying-gates/ hooks/team/post-task-complete-revalidate.sh hooks/team/stop-revalidate-user-gates.sh hooks/team/pre-task-blockedby-enforce.sh hooks/team/stop-deflection-guard.sh hooks/hooks.json CHANGELOG.md skills/shared/feature-state-schema.md` returns no matches.

## Out of scope

- `pre-agent-task-dispatch-validate.sh` and `post-agent-return-validate.sh` hooks. These were considered and explicitly excluded because loop-spec dispatches teammates via `TeamCreate` + `SendMessage` rather than per-task `Agent` calls, making dispatch-validation hooks inapplicable to this codebase.
- Mandatory enforcement of user-gate flow. It was considered and rejected: opting all tasks into gate verification would break the existing flow and add friction for users who do not need it.
- Silent tagging during plan writing that interrupts the user at plan time with clarification questions. Tagging is silent; questions come only at execution time.
- Node.js, npm, pip, or brew packages.
- All Cycle 3-5 work.

## Open questions

(none - resolved during DISCUSS phase)
