# EXECUTE rungs: inline, agent team, Workflow DAG, disposable session

The rungs of the EXECUTE concurrency ladder other than the subagent waves
(`execute-subagent.md`) and the headless loop fleet (`execute-loop-fleet.md`).
`lib/execute-rung.sh select` picks one from the measured DAG width and the probed
capabilities; the skill follows the matching section. Every rung returns the same
result object, with the same fixed vocabulary, so the consuming code never branches:

```json
{ "merged": ["task-001", ...],
  "blocked": [{"taskId": "...", "reason": "spec-compliance-block|retry-exhausted|commit-missing|zero-commit"}],
  "escalation": null | {"reason": "deadlock|rebase-conflict|env-fault", "detail": "..."} }
```

Common to every rung: `mergedSet` is seeded from `lib/task-progress.sh done` and each
publication persists `mark-done`; every implementer carries the contract stanza from
`execute-subagent.md` ("Implementer contract stanza") and the design gate in
`implementer-contract.md`; one `dispatch` event per agent launched and a
`task_start`/`task_end` pair per task (`dispatch.md`); repository-wide test/lint/
typecheck never run here (VERIFY owns that suite); a failed integration is never
stashed, reset, or cleaned by hand. Dispatch, then stop; never AskUserQuestion as a wait.

## Inline (no dispatch tool)

Selected when `lib/harness.sh subagents` prints `false` and no fleet is available: the
lead performs every task itself on `feat/{slug}`. No task worktrees, no separate
reviewer dispatch, one verify per task (the green already comes from the integrated
branch), per-task model pins ignored. Loop until `remaining` is empty:

1. `remaining = tasks - mergedSet - blocked`; `ready` = those whose `blockedBy` are all
   merged. Empty `ready` with non-empty `remaining` → `escalation.reason = "deadlock"`.
2. Take `ready[0]` in DAG order; `bash lib/cycle-driver.sh task dispatch --feature-dir
   "$fdir" --task task-NNN` requires a clean `git status` (drift from the previous task
   dissolves attribution; `dispatchable: false` names the dirt) and emits
   `task_start` (`lib/events.sh emit ... task_start --phase execute --data
   '{"index":N,"total":T,"id":"task-NNN","subject":"..."}'`).
3. Implement under `agents/implementer.md` and the design gate in
   `implementer-contract.md` (can I make it more modular? more extensible? is this the
   least code that makes it happen? does this hold at production scale?) plus
   `engineering-directives.md` (simple over clever, idiomatic for the pinned version,
   versions from a tool never from recall, scaling input named first): read
   `readFirst`, TDD (failing test first for every code-producing task; skill, config, and
   docs tasks excluded), touch only `files`.
4. Run `lib/prepare-environment.sh run` with `commands.prepare`, then review inline
   against `acceptanceCriteria` with the reviewer brief's verdicts before publishing.
5. On `pass`, `bash lib/cycle-driver.sh task integrate --feature-dir "$fdir" --task
   task-NNN` runs `bash lib/output-digest.sh run --log
   ".loop-spec/features/{slug}/logs/verify-{taskId}.log" --label "verify {taskId}" --
   {verifyCommand}` (exits with the command's code; up to `maxRetriesPerTask` in-place
   fixes before you call it), commits exactly `task.files` on `feat/{slug}` with the
   task id in the message, persists `mark-done`, and emits `task_end`; nothing staged
   → `.blocked == "commit-missing"`, `blocked += {taskId, reason: "commit-missing"}`.
6. `rework` with attempts left → revert, fix, repeat 4-5; exhausted → `retry-exhausted`
   (revert the task's commits); `block` → `spec-compliance-block` (revert likewise).
7. `task integrate` emits `task_end --phase execute` (same shape, plus
   `"result":"merged|failed|skipped"`) on every outcome it decides; emit it yourself for
   a task you blocked before integrating.

## Agent team (explicit or implicit teams)

Selected at `t_team <= W` (or `W >= t_wf` without Workflow opt-in) when the implementer
selector is `inherit`. Size: `M = min(taskCount, maxParallelImplementers)` implementers,
`R = ceil(M/2)` spec-compliance reviewers. Resolve `WT_ROOT=$(git rev-parse --show-toplevel)`
and `worktreeBase="$(bash lib/worktree-base.sh resolve "$WT_ROOT" task "{slug}" | jq -r .path)"`
once and substitute both into every prompt.

1. **Register tasks.** Validate each task's metadata with
   `lib/validate-task-metadata.sh '<json>'` (abort on failure), then `TaskCreate` once
   per task not already in `mergedSet`:
   `{subject: "{id}: {subject}", description: "{brief}", activeForm: "Working on ...",
   metadata: {loopSpec: true, blockedBy: [explicit + synthetic], files, verifyCommand,
   acceptanceCriteria, readFirst, specPath, claimedBy: null, retries: 0}}`. Keep the
   harness task id beside the plan id. A task with `userGate: true` closes through
   `Skill(loop-spec:checking-gates)` when those hooks are active.
2. **Spawn.** Explicit mode: one `TeamCreate({name: "loop-spec-execute-{slug}",
   teammates: [implementer-1..M (loop-spec:implementer), reviewer-1..R
   (loop-spec:spec-compliance-reviewer)]})` with each prompt from
   `team-prompts/implementer.md` / `team-prompts/reviewer.md` (placeholders `{slug}`,
   `{N}`, `{maxRetriesPerTask}`, `{worktreeBase}`, the roster). Implicit mode: one named
   `Agent({name, description, subagent_type, prompt})` per teammate, no `model` key.
   Record `currentTeamName` and `currentTeammates`.
3. **Self-claim loops** run inside the teammates (their prompts are the loops). The
   contract the lead relies on: the harness serializes concurrent `TaskUpdate` claims;
   every status transition is written BEFORE its `SendMessage`; rework and review queues
   are `metadata.phase` (`needs_rework` / `awaiting_review`) with `owner == null`; a
   blocked task terminates as `status: "completed"` with `metadata.result: "blocked"`;
   implementers resolve their worktree through `lib/worktree-base.sh resolve` on branch
   `task/{taskId}-{slug}`; a reviewer `pass` requires empty `unverified[]`, otherwise
   the lead rules on each `UNVERIFIED:` item.
4. **Wake and reconcile.** Every wake (any teammate `SendMessage`, or a `TeammateIdle`
   notification, which the harness guarantees) triggers the same reconcile from
   `TaskList` state, never from message content: re-read the list; enqueue on
   `feature.json.mergeQueue` (via `feature-write.sh append`) every `completed` task with
   `metadata.result != "blocked"` whose branch has commits over `feat/{slug}` and is not
   yet merged or queued; process the queue; re-check the exit condition. Idle
   implementers are woken with `SendMessage({to, message: "New tasks unblocked: [...]"})`
   when a merge unblocks work. Log `[TEAM-EXECUTE] task-{id} claimed by implementer-{N}`
   on each `CLAIMED:` message.
5. **Merge queue** (FIFO, dependency-aware, persisted): a head whose blockers are not all
   merged rotates to the back. Integrate with
   `lib/integrate-task.sh --feature-root "$WT_ROOT" --feature-branch feat/{slug}
   --task-worktree <path> --task-branch task/{id}-{slug} --verify "<verifyCommand>" --cleanup`,
   parse the JSON (`.published == true` → remove from the queue, `mark-done`), and treat
   `zero-commit` as unmergeable, `verify-failed` as remediation, and `rebase-conflict`,
   `check-dirty-worktree`, `feature-moved`, `publish-failed` as escalations.
6. **Exit** when no task is `pending` or `in_progress`, the queue is empty, and every
   merged task's worktree is cleaned up. Any `completed` task with
   `metadata.result == "blocked"` pauses EXECUTE with its id and last findings.
   Explicit mode: `TeamDelete({name})`; then clear `currentTeamName`.

## Workflow DAG (opt-in)

Selected only with `LOOP_SPEC_EXECUTE_WORKFLOW=1`, `workflowsAvailable`, and
`W >= t_wf`. Persist `feature.json.activeWorkflow = {scriptPath, startedAt}`, then:

```
Workflow({
  scriptPath: "${CLAUDE_SKILL_DIR}/../../lib/workflows/execute-dag.js",
  args: { slug, featureWorktreeRoot, featureBranch: "feat/{slug}",
          models: {implementer, specComplianceReviewer}, maxParallelImplementers,
          maxRetriesPerTask, reviewersEnabled: true, commands: feature.commands, skillDir,
          taskWorktreeBase, tasks: <tasks[]>, doneTaskIds: <mergedSet> }
})
```

Clear `activeWorkflow` after the call and consume the frozen `{merged, blocked,
escalation}` exactly like every other rung; the merge agent persists `mark-done` per
publication.

## Foreign claimants (opt-in)

Selected with `LOOP_SPEC_FOREIGN_CLAIMANTS=1` and a reachable handoff port
(`handoff-port.md`). Each remaining task becomes one content-addressed bundle:

```bash
bash lib/graph/handoff.sh export --feature-dir "$fdir" --node execute.worker --task "$id" \
  --verify "$verifyCommand" --brief "$brief" --files "$files" --out "$WORK/bundle-$id.json"
bash lib/graph/port.sh put "$WORK/bundle-$id.json"      # prints id=...
```

There is no supervisor loop: after putting the bundles, return control like a
`step`/`interactive` phase. On re-entry, `port.sh get "$id"` then
`handoff.sh import --feature-dir "$fdir" --bundle ...` merges each finished result (a
stale state hash is rejected and the task re-offered); a merged import still re-runs
`verifyCommand` on the integrated branch before it counts as done. Continue to the
phase exit once every task assigned to this rung has merged or exhausted its retries.

## Disposable session (headless)

Selected when `lib/harness.sh session-layer` answers `session`: the invocation is
headless (`claude -p`, `codex exec`, `opencode run`, or `LOOP_SPEC_NON_INTERACTIVE=1`),
`extensions/sessions/profiles/<cli>.toml` exists for `lib/harness.sh cli`, that CLI is
on PATH, and `python3` is 3.11 or newer. `LOOP_SPEC_SESSION_LAYER=0` keeps a headless
run on the subagent waves; `=1` forces the rung and fails loudly without the CLI. In
every other respect this is the subagent path (`execute-subagent.md`): the same wave
loop, the same `dispatch`/`package`/`verdict`/`integrate` driver steps, the same
lead-created task worktrees (`subagentIsolation=lead-worktree`), the same ff-merge.
Only the launch differs, and the driver owns it: each implementer and each reviewer is
its own headless CLI process that the driver starts, so nothing it reads or writes
lands in the lead's context, and the lead never sees a launch command
(`docs/loop-spec/orchestrator-port-principles.md`, rule 12).

Per task, after `cycle-driver.sh task dispatch` returns the packet:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-driver.sh" task run --feature-dir "$feature_dir" --task "$taskId" --role implementer
```

The driver writes the prompt (one line: the brief, the spec, the report path), runs
`extensions/sessions/session_run.py` with this harness's profile in the task worktree,
retries an `env-fault` or `timeout` once, and prints the runner's JSON line. `status:
completed` continues to `package`. `failed` is one attempt: read the report file and
the `stderr` path, then `verdict rework` as for a failed subagent. A second fault is
the answer: escalate with `reason: "env-fault"` and the `envFault` pattern or the
timeout as `detail`. Exit 2 is a configuration fault (no profile, no CLI, old
interpreter): stop and escalate with the driver's stderr; never fall back to `Agent` by
hand, because the probe already answered `session` for this run.

After `package`, the reviewer is a session too:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-driver.sh" task run --feature-dir "$feature_dir" --task "$taskId" --role reviewer
```

It runs in the feature root with the reviewer's model; the verdict is read from the
report file as on the subagent path. On any other rung `task run` answers
`{action: "in-harness"}` and the harness tool dispatches as that rung says.

`extensions/sessions/README.md` lists the profile keys, the child's environment, and the
exit codes. The session's own log stays under `{featureDir}/dispatch/sessions/`; quote
paths, never the log body.
