# Cycle Orchestration via Agent Teams

**Slug:** `cycle-agent-teams`
**Created:** 2026-05-11
**Tier:** quality
**Execution style:** auto

## Problem

The current loop-spec cycle dispatches every subagent through a one-shot `Agent({subagent_type, model, prompt})` call. The subagent runs to completion, returns a single report, and dies. This shape forces three structural compromises:

1. **No inter-agent dialogue.** The advocate / challenger critique gates in DISCUSS and PLAN cannot debate each other. Each writes a one-shot critique; the orchestrator (lead) hand-merges findings into a fix-list. Multi-round dialogue requires the lead to manually mediate every turn, which inflates context and loses nuance.
2. **Brittle hand-rolled state.** Wave scheduling, task lifecycle (`pending -> dispatching -> running -> reviewing -> merging -> completed`), retry counters, and gate history all live in `state.json`, written through `lib/state-write.sh`. Every status transition is an explicit atomic-write call from the orchestrator. This duplicates a substantial subset of what the harness now provides natively (`TaskCreate`, `TaskUpdate`, `TaskList`, `TaskGet`, file-locked self-claim).
3. **Static wave dispatch.** `EXECUTE` builds waves from the task DAG up front, then dispatches all tasks in a wave in parallel and waits for all to finish before starting the next wave. The slowest task in a wave gates the rest. With persistent teammates self-claiming from a shared task list, an idle implementer can immediately pick up the next unblocked task without waiting for its wave-mates.

The cycle skill explicitly bans the agent-team toolset (`TeamCreate`, `TeamDelete`, `SendMessage`, `TaskCreate`, `TaskUpdate`, `TaskList`, `TaskGet`) in its tool whitelist. This SPEC reverses that ban and rebuilds the cycle on top of agent teams.

## Goals

- Replace one-shot `Agent` dispatch with persistent agent teams in every phase (DISCUSS, PLAN, EXECUTE, VERIFY, MAP-CODEBASE).
- Enable direct teammate-to-teammate dialogue via `SendMessage` for advocate / challenger critique gates.
- Migrate task lifecycle off `state.json` and onto the harness task list (`TaskCreate` / `TaskUpdate` / `TaskList` / `TaskGet`).
- Replace static wave dispatch in EXECUTE with a shared task list that implementer teammates self-claim from, gated only by the `blockedBy` graph (no per-wave barrier).
- Preserve the user-facing cycle contract: same tier / preset / style / title prompts, same artifact paths under `docs/loop-spec/features/{slug}/`, same exit semantics for AUTO / STEP / INTERACTIVE / REVIEW-ONLY.
- Ship as a clean breaking change on a new branch from `main` with an explicit version bump and CHANGELOG entry. No silent migration of in-flight `state.json` features.

## Non-goals

- Backwards compatibility with `state.json` (v1 or v2). Features in flight at the moment of upgrade must be completed on the prior version or restarted.
- Resumable in-process teammates. The harness does not support session resumption with live teammates; this SPEC inherits and documents that limitation rather than working around it.
- Nested teams. The harness forbids teammates from spawning sub-teams; phase teams cannot themselves spin up sub-teams (e.g. EXECUTE cannot have a per-task sub-team).
- Cross-feature concurrency. The harness allows one team at a time per lead, so the cycle continues to run a single feature at a time.
- Re-architecting the worktree merge model. EXECUTE keeps its raw `git worktree add` / merge flow via `lib/git-ops.sh`; the harness `EnterWorktree` / `ExitWorktree` tools remain banned (lifecycle conflict with wave-aware merge logic, even though waves themselves are dropped).
- Skills frontmatter on teammates. The harness does not apply `skills` or `mcpServers` frontmatter when an agent runs as a teammate; teammate behavior is driven entirely by spawn prompt + agent definition body.
- Replacing `lib/gsd-ingest.sh` GSD ingestion. The script keeps writing the codebase docs; only the `state.json` writes inside it are removed.

### Known limitations

- **Per-task retry counters reset on full EXECUTE resume.** The `retries` field on harness task metadata lives inside the EXECUTE team's task list. When the team is torn down (clean exit at phase boundary, kill, or VERIFY -> EXECUTE re-entry), the task list goes with it. On a resumed EXECUTE, the lead recreates the task list from `PLAN.md` and on-disk artifacts; `retries` is initialized to 0 for every recreated task. Net effect: a task that exhausted its `tier.execute.maxRetriesPerTask` budget before the kill receives a fresh budget on resume. This is accepted because (a) the per-task budget is small (1-3 attempts depending on tier) so the worst case is a small amount of duplicate work, and (b) persisting per-task retry counters across team teardowns would require shadowing them in `feature.json`, which re-introduces the dual-write coupling between `feature.json` and the harness task list that this SPEC is explicitly removing. Per-gate, per-phase, and global retry counters DO persist across resume (they live in `feature.json.retryBudget`).
- **No automated cleanup on kill.** A killed cycle leaves its current team live in the harness; the user must manually run `TeamDelete` after the next invocation prints the orphan-cleanup message. See "Resume strategy" step 5.

## Constraints

- **Zero deps.** Markdown + bash + git only. No npm, pip, brew. (Project rule.)
- **Skills are code.** Don't restructure tested skill content without eval evidence. The team-based rewrite must keep equivalent gate semantics (advocate / challenger / fix-list loop) even though the transport changes.
- **`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` required.** This is an experimental harness feature. The cycle must hard-fail at startup if the env var is unset.
- **Teammates do not inherit the lead's conversation history.** All context (artifact paths, fix-lists, prior findings) must be passed explicitly in the spawn prompt or written to disk and read by the teammate.
- **One team per lead at a time.** Phase boundaries become team boundaries: each phase creates its own team and tears it down with `TeamDelete` before the next phase starts. Only the lead calls `TeamDelete`.
- **Team config is harness-managed.** Do not hand-author `~/.claude/teams/{team-name}/config.json`. The cycle interacts with it only via `TeamCreate` / `TeamDelete`.
- **Smoke test must keep passing.** `tests/smoke.sh` is the canonical regression gate (project rule); its assertions must be updated in lockstep with the artifact-shape changes.
- **No `--no-verify` commits.** All commits go through hooks (project rule).

## User-facing behavior

The user invocation is unchanged:

```
Skill(loop-spec:cycle)
```

What the user sees during a run changes in three observable ways:

1. **Startup health-check gains a team-capability probe.** Step 2 still probes the 3 model IDs and the 1M-context flag, then additionally:
   - Checks that `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` is set. If unset, abort with:
     ```
     loop-spec health check FAILED
       Capability: agent teams
       Error: CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS is not set to 1
       Suggested fix: export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 and re-run
     ```
   - Runs a **harness API capability probe** that creates a throwaway team `loop-spec-probe-{pid}` with one teammate, then exercises the three contracts the cycle hard-requires:
     1. `TaskUpdate` accepts the `status: "awaiting_review"` enum value (probe sets the status and reads it back via `TaskGet`).
     2. The task `metadata` field exists and round-trips a written value (probe writes a small JSON blob to `metadata`, reads back via `TaskGet`, asserts equality).
     3. `SendMessage` from the lead to the throwaway teammate and from the teammate back to the lead.
     4. **Concurrent self-claim serialization.** Spawn two throwaway teammates and instruct both to race-claim the same task by calling `TaskUpdate({taskId, status: "in_progress", owner: "<own-name>"})` simultaneously. The harness must serialize: exactly one call succeeds and the other returns an error. Probe asserts that `TaskGet({taskId}).status == "in_progress"` and `owner` is set to one of the two teammate names (not both, not empty). The losing teammate's error response is read and logged. This validates the self-claim contract relied on by EXECUTE.
     5. `TeamDelete` cleanup.
   - On any probe failure, abort with:
     ```
     loop-spec health check FAILED
       Capability: agent teams
       Error: Agent teams capability probe failed.
       Suggested fix: Ensure CC v2.1.32+, CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1, and harness supports TaskUpdate metadata.
     ```
   - There are **no fallbacks**. Direct task-metadata API and the `awaiting_review` status are used everywhere; if the harness does not support them, the cycle does not run.
   - The probe is the documented prerequisite for the rest of Step 2.
2. **Phase progress is visible via the harness task list.** Where the previous cycle printed wave-status lines synthesized from `state.json`, the new cycle prints them from `TaskList` output, with the same wording (`task-NNN: {subject} [{status}]`). EXECUTE additionally prints self-claim events as implementers pick up tasks (see Self-claim log format below).
3. **Resume behavior is more restrictive.** Instead of scanning `.loop-spec/features/*/state.json`, the cycle scans `.loop-spec/features/*/feature.json` (a thin manifest in the gitignored state directory, see "State migration" below). Resume is only offered for features whose phase has a clean restart point (a phase whose team is gone, or a phase with no live teammates). In-process teammate resume is explicitly not supported, and the cycle prints a one-line note when it skips a stale in-progress feature for that reason.

All artifact paths (`docs/loop-spec/features/{slug}/SPEC.md`, `PLAN.md`, etc.) and all user prompts (tier / preset / style / title) are unchanged.

## Architecture overview

### Current architecture (one-shot dispatch)

| Component | Mechanism |
|---|---|
| Subagent dispatch | `Agent({subagent_type, model, prompt})` — runs to completion, returns one report |
| Inter-agent communication | None. Lead mediates every exchange. |
| Task lifecycle | `state.json` `tasks[]` array, transitioned via `lib/state-write.sh` |
| Wave scheduling | `state.json` `waves[]` array, dispatched in parallel batches per wave, barrier between waves |
| Critique gates | Two parallel one-shot `Agent` calls (advocate, challenger); lead merges findings |
| Per-task retries | `state.tasks[].retries` integer, capped by `state.retryBudget.executePerTask` |
| Gate history | `state.gateHistory[]` array |
| Resume | Scan `state.json` files; jump to `state.currentPhase` |
| Codebase mapping | 5 parallel one-shot mapper `Agent` calls |

### Target architecture (agent teams)

| Component | Mechanism |
|---|---|
| Subagent dispatch | `TeamCreate` once per phase; teammates persist for the phase's duration |
| Inter-agent communication | `SendMessage` (lead <-> teammate, teammate <-> teammate by name; teammate-to-teammate messaging is a first-class harness feature, no broker required) |
| Task lifecycle | Harness task list per team (`TaskCreate` / `TaskUpdate` / `TaskList` / `TaskGet`) |
| Wave scheduling | Replaced. Shared task list with `blockedBy` dependencies; teammates self-claim unblocked tasks. No wave barrier. |
| Critique gates | Advocate and challenger teammates exchange `SendMessage` rounds directly; lead observes and synthesizes the fix-list when both signal "done" |
| Per-task retries | Task metadata field (set via `TaskUpdate`) plus a phase-level retry-budget counter on the lead-side feature manifest |
| Gate history | Appended to `docs/loop-spec/features/{slug}/feature.json` (lightweight log, see schema below) |
| Resume | Scan `feature.json` files; jump to phase by recreating the phase team from scratch (no teammate-state resume) |
| Codebase mapping | One MAP-CODEBASE team with 5 mapper teammates running in parallel |

### Teammate naming and messaging

The lead assigns each teammate a name at spawn time, following the convention `{role}-{N}` where `N` is the 1-indexed spawn order within that team (e.g., `implementer-1`, `implementer-2`, `reviewer-1`, `advocate-1`, `challenger-1`). The lead records the full roster in `feature.json` under `currentTeammates: ["implementer-1", "implementer-2", ...]` so it can address any teammate by name and so reviewers and implementers can address each other.

`SendMessage({to: "<name>", body: "..."})` is the only transport. Per the harness contract:

- Any teammate can `SendMessage` any other teammate by name. No "cc" semantics, no broadcast, no broker. The lead does not need to be addressed on every message.
- The lead is automatically notified by the harness when a teammate goes idle (`TeammateIdle` hook). The lead does not need to be cc'd to observe progress.
- Any teammate can `SendMessage` the lead by addressing it as `lead` (the harness reserves this name).

Where this SPEC says "advocate and challenger debate directly", the mechanism is exactly: `advocate-1` calls `SendMessage({to: "challenger-1", body: ...})` and vice versa. The lead reads the conversation only through the `TeammateIdle` notifications and through explicit `ROUND-{N} DONE: ...` / `ROUND-{N} DONE-WITH-ISSUES: ...` messages each teammate sends to `lead` at the end of each round (which the lead appends to `gate-logs/`).

### Phase-team structure

Each phase below specifies: team name, lead, teammates, hooks, primary tools used, and the exit condition that triggers `TeamDelete`.

#### DISCUSS team

- **Team name:** `loop-spec-discuss-{slug}`
- **Lead:** the cycle skill's main thread
- **Teammates:**
  - `spec-writer` (1 instance) — writes `SPEC.md` from the user's discuss-phase Q&A transcript
  - `advocate` (1 instance) — argues SPEC is ready
  - `challenger` (1 instance) — argues SPEC is not ready
- **Communication pattern:** Lead spawns `spec-writer-1` with the transcript; on report-back, lead spawns `advocate-1` and `challenger-1` and instructs each to address the other directly via `SendMessage` (e.g., `SendMessage({to: "challenger-1", body: ...})`). The two debate for up to N rounds (N = `tier.discuss.maxCritiqueRounds`, currently 3 in quality / 2 in balanced / 1 in quick) under the convergence rules in "Critique debate protocol" below. Lead is notified of each teammate going idle via `TeammateIdle` and reads the round outcome via `SendMessage` from each teammate to `lead` formatted as `ROUND-{N} DONE: ...` or `ROUND-{N} DONE-WITH-ISSUES: ...`. The lead appends each round-end message to `.loop-spec/features/{slug}/gate-logs/{gate}-round-{N}.md`. When the convergence rules fire, lead synthesizes the fix-list from the gate logs and instructs `spec-writer-1` via `SendMessage` (not a fresh `Agent` call).
- **Hooks:** `TeammateIdle` exit-2 nudge for spec-writer if it goes idle without producing `SPEC.md`. `TaskCompleted` runs the SPEC.md schema validator.
- **Tools used by lead in this phase:** `TeamCreate`, `SendMessage`, `TaskCreate`, `TaskList`, `TaskGet`, `TeamDelete`, `Read`, `Write`, `Edit`, `AskUserQuestion`, `Bash`.
- **Exit:** lead writes the fix-list-resolved `SPEC.md`, calls `TeamDelete`, and routes to PLAN.

#### PLAN team

- **Team name:** `loop-spec-plan-{slug}`
- **Lead:** cycle main thread
- **Teammates:**
  - `pattern-mapper` (1 instance) — writes `PATTERNS.md` from codebase scan
  - `planner` (1 instance) — writes `PLAN.md` (task DAG + acceptance criteria)
  - `advocate` (1 instance) — argues PLAN is feasible
  - `challenger` (1 instance) — argues PLAN is infeasible
- **Communication pattern:** `pattern-mapper-1` runs first (no debate). When `PATTERNS.md` exists, `planner-1` runs (consuming `PATTERNS.md`). When `PLAN.md` exists, `advocate-1` and `challenger-1` debate up to N rounds (same tier-driven N as DISCUSS) using teammate-to-teammate `SendMessage` and the convergence rules in "Critique debate protocol" below. Feasibility check runs as a teammate-internal `Bash` step inside `planner-1` (verify each task's `verifyCommand` shell-parses). Lead synthesizes fix-list and instructs `planner-1` via `SendMessage` to revise.
- **Hooks:** same shape as DISCUSS, plus a `TaskCompleted` hook that validates the PLAN's task DAG (no cycles, every task has `acceptanceCriteria`, every task has `verifyCommand`, every `blockedBy` references an existing task).
- **Exit:** `PLAN.md` accepted; lead pre-creates one harness task per planned task in the EXECUTE team's task list (deferred to EXECUTE Step 0 since the EXECUTE team doesn't exist yet); calls `TeamDelete`.

#### EXECUTE team

- **Team name:** `loop-spec-execute-{slug}`
- **Lead:** cycle main thread
- **Teammates:**
  - `implementer` (M instances; `M = min(plannedTaskCount, tier.execute.maxParallelImplementers)`) — self-claim unblocked tasks, write code in worktrees, run verify command
  - `reviewer` (R instances; `R = ceil(M/2)`) — self-claim tasks in `awaiting_review` status, run spec-compliance review
- **Communication pattern:**
  - Lead calls `TaskCreate` once per planned task at phase start, populating `blockedBy`, `files`, `verifyCommand`, `acceptanceCriteria`, and `specPath` directly on the task `metadata` field (the capability probe in Step 2 has already verified `metadata` round-trips).
  - **Self-claim API (concrete).** Implementer teammates (`implementer-1`, `implementer-2`, ...) claim tasks by calling `TaskUpdate({taskId, status: "in_progress", owner: "<own-teammate-name>"})`. The harness serializes concurrent `TaskUpdate` calls on the same task id; if two implementers race, only one call succeeds and the other returns an error. The losing implementer must catch the error and re-run its self-claim loop: re-query `TaskList` for the next unblocked `pending` task and retry. This serialization contract is exercised at startup by the Step 2 capability probe (concurrent-claim sub-probe); EXECUTE relies on the probed behavior, no additional locking is implemented at the cycle level. After a successful claim, the implementer additionally writes its own teammate name into the task metadata field `claimedBy` (redundant with the `owner` field, kept for backward-compatible observability and reviewer addressing). Each implementer picks the first unassigned task whose `blockedBy` set is fully `completed`. The lead emits `[TEAM-EXECUTE] task-NNN claimed by implementer-M` to the run log on every successful claim transition (the metadata write is the source of truth; the log line is for observability and is asserted by smoke).
  - On verify pass, implementer sets task status to `awaiting_review` and leaves `claimedBy` populated with its own name so the reviewer knows whom to address.
  - Reviewer teammates (`reviewer-1`, `reviewer-2`, ...) self-claim `awaiting_review` tasks, perform spec-compliance review, and either set status to `completed` (and notify `lead` via `SendMessage`) or `needs_rework` and `SendMessage` the implementer named in `claimedBy` with the fix-list (e.g., `SendMessage({to: "implementer-3", body: ...})`).
  - On `needs_rework`, any implementer (typically the same one, but any unassigned implementer may pick it up) re-claims the task and re-runs. Per-task retry counter lives in task metadata (`retries` field, incremented on each `needs_rework -> claim` transition). Cap = `tier.execute.maxRetriesPerTask`.
  - **Pre-task file-conflict detection** runs on **every EXECUTE entry** in lead-side bash. "Every entry" means both the first entry from PLAN and any re-entry triggered by VERIFY routing back after a code-review HARD-GATE failure (which generates new remediation tasks). On each entry, before calling `TaskCreate` for the new or replayed task set, the lead recomputes synthetic `blockedBy` edges for **all tasks in `pending` status** (including remediation tasks added on re-entry). For each pair of pending tasks, intersect each task's `files` list. Any non-empty intersection (after applying the exclusion list described below) forces a synthetic `blockedBy` edge (the lower-numbered task blocks the higher-numbered one). This recompute prevents remediation tasks from inheriting stale conflict data from the original EXECUTE pass when VERIFY adds new tasks that touch files already covered by completed or in-flight tasks. File-name overlap is sufficient at the spec stage; no merge-content analysis is performed. Documented as the trade-off for self-claim parallelism.
  - **Exclusion list.** By default, all file overlaps are flagged (the default exclusion list is empty). Projects configure exclusions via either:
    - `fileConflictExcludeGlobs[]` in `feature.json` (per-feature override), or
    - `.loop-spec/file-conflict-exclude.txt` (one glob per line, repo-wide, lives in the gitignored state dir).
    Both sources are unioned. The spec ships **no project-specific defaults** so loop-spec stays generic across consuming repos.
- **Idle / wake protocol (event-driven, no polling):**
  - When an implementer finishes the last available task and `TaskList` shows no unblocked `pending` tasks it can claim, it sends `SendMessage({to: "lead", body: "implementer-N idle: no available tasks"})` then goes idle normally. It does **not** exit-2 to keep polling.
  - The lead maintains an in-memory set of "known idle implementers" populated from these notifications and reset whenever it wakes a teammate.
  - When the lead processes a `TaskCompleted` event for a task that unblocks one or more dependent tasks, it sends `SendMessage({to: "implementer-N", body: "New tasks unblocked: [task-NNN, ...]"})` to each known idle implementer (round-robin if multiple are idle and multiple tasks unblocked) to wake them. Each woken teammate re-runs the self-claim loop.
  - **Harness contract (cited).** This wake-on-message behavior is the documented harness contract: "Idle teammates can receive messages. Sending a message to an idle teammate wakes them up and they will process it normally." (Source: agent teams documentation.) The cycle relies on this contract directly and does not implement any compensating polling, watchdog, or re-spawn logic for idle teammates. If the harness ever changes this contract, EXECUTE's wake path breaks loudly (idle implementers stay idle and `TaskList` shows tasks pending forever); the smoke fixture's distinct-implementers criterion will catch the regression.
  - The lead's `TeammateIdle` hook is **not** used for task-waiting in EXECUTE.
- **Hooks:**
  - `TaskCreated` hook validates task metadata shape.
  - `TaskCompleted` hook runs `lint` and `typecheck` commands (project-detected) on the merged worktree before the lead accepts the task as truly done. On failure, hook re-opens the task with status `needs_rework`.
- **Merge queue (replaces wave barrier).** With waves removed, the lead serializes worktree merges through a FIFO merge queue persisted in `feature.json` under `mergeQueue: ["task-NNN", ...]`:
  - When a reviewer marks a task `completed` (via `SendMessage` to `lead`), the lead appends the task id to `mergeQueue` in arrival order.
  - The lead processes `mergeQueue` sequentially in FIFO order. Before merging task B at the head of the queue, the lead checks that all of B's `blockedBy` tasks are already merged on `feat/{slug}`. If not, B is rotated to the back of the queue and the next entry is tried (B will return to the head once its blockers merge). This dependency-aware FIFO replaces the wave barrier without forcing tasks to wait on unrelated peers.
  - Each merge: `git checkout feat/{slug} && git merge --ff-only {worktree_branch}`. On non-fast-forward, the lead rebases the worktree branch onto `feat/{slug}` and retries the `--ff-only` merge. On rebase failure (conflicts the lead cannot auto-resolve), escalate to the user (pause EXECUTE, print conflict, return control).
  - After all tasks are merged and `mergeQueue` is empty, the lead runs worktree cleanup: `git worktree remove` for each worktree directory, then `git branch -D` for each per-task branch.
  - Net effect: tasks merge as they complete, in dependency-respecting FIFO order. No two merges run concurrently (the lead serializes them); implementation work itself remains parallel across implementers.
- **Exit:** `TaskList` reports zero tasks in any non-`completed` status, `mergeQueue` is empty, and worktree cleanup has run (or per-task retry budget exhausted on any task, which triggers escalation). Lead writes `EXECUTION.md` (summary), calls `TeamDelete`, routes to VERIFY.

#### VERIFY team

- **Team name:** `loop-spec-verify-{slug}`
- **Lead:** cycle main thread
- **Teammates:**
  - `verifier` (1 instance) — writes `VERIFICATION.md` (runs `test`, `lint`, `typecheck` end-to-end on the merged feature branch)
  - `code-reviewer` (1 instance) — hard gate; reviews the full diff against `SPEC.md` and `PLAN.md` acceptance criteria
  - `mapper-{tech,arch,quality,concerns,domain}` (up to 5 instances, only for stale domains) — incremental codebase-map refresh
- **Communication pattern:** verifier and code-reviewer run in parallel as teammates. Mapper teammates run in parallel only if the staleness check (in `lib/codebase-staleness.sh` or equivalent) reports any domain as stale. Code-reviewer is a hard gate: if it returns FAIL, lead routes back to EXECUTE phase (recreates the EXECUTE team) with the failing findings as a fix-list pre-loaded on the offending task(s).
- **Hooks:** `TaskCompleted` hook on the verifier task triggers the lead to read `VERIFICATION.md` and decide pass/fail.
- **Exit:** verifier and code-reviewer both pass; lead writes the cycle-completion summary, calls `TeamDelete`, marks the feature `completed` in `feature.json`.

#### MAP-CODEBASE team (one-time per project, plus incremental refresh inside VERIFY)

- **Team name:** `loop-spec-map-codebase-{project-id}` (project-id derived from repo root path hash)
- **Lead:** cycle main thread (when invoked from Step 5.5) or VERIFY lead (when invoked incrementally)
- **Teammates:** `mapper-tech`, `mapper-arch`, `mapper-quality`, `mapper-concerns`, `mapper-domain` (5 total when first-run; subset when incremental)
- **Communication pattern:** mappers run in parallel and may share findings via `SendMessage` (e.g., `mapper-arch` sharing detected module boundaries with `mapper-domain`). Lead does not interject.
- **Hooks:** `TaskCompleted` validates each `docs/loop-spec/codebase/{DOMAIN}.md` against schema before accepting.
- **Exit:** all 5 docs present and validated; lead calls `TeamDelete` and (for first-run) makes a single commit covering all writes.

## Critique debate protocol

The advocate / challenger debate (used in DISCUSS and PLAN) follows a fixed protocol so convergence is unambiguous and persisted.

- **Round structure.** A round is one challenger turn followed by one advocate turn:
  1. Challenger sends a `SendMessage` to advocate enumerating issues for this round (or "no new issues this round").
  2. Advocate sends a `SendMessage` to challenger responding to each issue.
  3. Each teammate then ends the round with a single message to `lead`:
     - `SendMessage({to: "lead", body: "ROUND-{N} DONE: {summary of findings/defenses this round}"})` if it has no new issues to raise next round, or
     - `SendMessage({to: "lead", body: "ROUND-{N} DONE-WITH-ISSUES: {summary of findings/defenses this round}"})` if it still has open issues.
- **Transcript capture (resume support).** When the lead receives each round-end message, it appends the raw message body to `.loop-spec/features/{slug}/gate-logs/{gate}-round-{N}.md`, with one entry per teammate per round. The gate-logs directory is the durable record of the debate. On resume after a kill, the lead reads `gate-logs/` to reconstruct the debate state and feeds the prior round summaries into the spawn prompts of the new advocate / challenger so the resumed teammates have the full prior context.
- **"DONE" semantics.** "DONE" means "I have no new issues to raise this round." It is explicitly **not** "I agree with the other side." A teammate sending DONE while the other still has issues simply means the debate has narrowed to a one-sided fix-list.
- **Convergence detection.** After each round, the lead inspects the latest two round-end messages (one per teammate):
  1. **Mutual DONE:** both messages start with `ROUND-{N} DONE:` (no `-WITH-ISSUES`). Lead synthesizes the fix-list from `gate-logs/` and exits the loop.
  2. **Cap reached:** round counter reaches `tier.{phase}.maxCritiqueRounds`. Lead synthesizes the fix-list regardless of teammate signals, recording in `gateHistory[].notes` that the cap fired.
  3. **One-sided convergence:** if one teammate sends `ROUND-{N} DONE:` for two consecutive rounds while the other still sends `DONE-WITH-ISSUES:`, lead synthesizes from the still-active teammate's findings and exits.
- **Round counter persistence.** The per-gate round counter is written to `feature.json` under `currentGate: {phase, gate, round, advocateName, challengerName, startedAt}` after every round. The counter is **not** in-memory only; it survives a kill so resume can pick up the round it left off, with the prior transcript loaded from `gate-logs/`.
- **Per-gate retry counter persistence.** `feature.json.retryBudget.perGateUsed` is a map keyed by `{phase}.{gate}` (e.g., `discuss.spec-critique`) of integer retry counts, written via `lib/feature-write.sh` on every gate failure. This replaces the previously in-memory per-gate counter so a kill mid-gate does not reset the budget.

## State migration

`state.json` and `lib/state-write.sh` are removed. State splits across three places:

| State category | Old location | New location |
|---|---|---|
| Per-task lifecycle (status, blockedBy, files, verifyCommand, acceptanceCriteria, retries, commitSha) | `state.json` `tasks[]` | Harness task list (`TaskCreate` / `TaskUpdate` / `TaskGet`) per phase team |
| Wave scheduling | `state.json` `waves[]` | Removed entirely. Replaced by `blockedBy` graph + self-claim. |
| Phase / artifact paths / tier / preset / style / commands / branch / baseSha | `state.json` top-level fields | `.loop-spec/features/{slug}/feature.json` (new lightweight manifest in the gitignored state dir, see schema below) |
| Gate history | `state.json` `gateHistory[]` | `.loop-spec/features/{slug}/feature.json` `gateHistory[]` (same shape) |
| Per-phase retry budget | `state.json` `retryBudget.perPhaseUsed` | `.loop-spec/features/{slug}/feature.json` `retryBudget` (same shape, minus `executePerTask` which moves to per-task metadata) |
| Per-task retry counter | `state.json` `tasks[].retries` | Harness task metadata `retries` field |
| Codebase-source provenance | `state.json` `artifacts.codebaseSource` | `.loop-spec/features/{slug}/feature.json` `artifacts.codebaseSource` (same shape) |
| Warnings | `state.json` `warnings[]` | `.loop-spec/features/{slug}/feature.json` `warnings[]` |

**Path split rationale.** Committed artifacts (`SPEC.md`, `PLAN.md`, `PATTERNS.md`, `EXECUTION.md`, `VERIFICATION.md`) remain under `docs/loop-spec/features/{slug}/` exactly as today. Volatile state (`updatedAt`, `currentTeamName`, `currentTeammates`, `currentGate`, `retryBudget.*Used`, `warnings`) lives in `.loop-spec/features/{slug}/feature.json`, which is gitignored. This keeps churn out of the tracked tree while preserving the discoverability of artifacts.

### `feature.json` schema (replaces `state.json`)

Path: `.loop-spec/features/{slug}/feature.json` (gitignored).

```json
{
  "schemaVersion": 3,
  "slug": "string (kebab-case)",
  "createdAt": "ISO-8601 timestamp",
  "updatedAt": "ISO-8601 timestamp",
  "tier": "quality | balanced | quick",
  "preset": "opus | quality | balanced | fast | economy",
  "execStyle": "auto | step | interactive | review-only",
  "currentPhase": "discuss | plan | execute | verify | completed",
  "completedPhases": ["array of phase names"],
  "artifacts": {
    "spec": "path or null",
    "patterns": "path or null",
    "patternsSource": "gsd-ingest | pattern-mapper | manual | null",
    "plan": "path or null",
    "execution": "path or null",
    "verification": "path or null",
    "codebaseSource": {
      "tech": "gsd-ingest | mapper | manual | null",
      "arch": "gsd-ingest | mapper | manual | null",
      "quality": "gsd-ingest | mapper | manual | null",
      "concerns": "gsd-ingest | mapper | manual | null",
      "domain": "gsd-ingest | mapper | manual | null"
    }
  },
  "branch": "string (feat/{slug})",
  "baseSha": "git sha at branch creation",
  "currentTeamName": "string or null (e.g., loop-spec-execute-{slug}); null between phases",
  "currentTeammates": ["array of teammate names currently spawned, e.g., implementer-1, reviewer-1; empty between phases"],
  "currentGate": {
    "phase": "string or null",
    "gate": "string or null",
    "round": "integer (current round of advocate/challenger debate, 0 if no gate active)",
    "advocateName": "string or null (e.g., advocate-1)",
    "challengerName": "string or null (e.g., challenger-1)",
    "startedAt": "ISO-8601 timestamp or null"
  },
  "fileConflictExcludeGlobs": ["optional array of additional globs excluded from EXECUTE pre-task file-conflict detection"],
  "mergeQueue": ["array of task ids in FIFO arrival order awaiting merge to feat/{slug}; empty between phases and at EXECUTE exit"],
  "gateHistory": [
    {
      "phase": "string",
      "gate": "spec-critique | plan-critique | plan-feasibility | spec-compliance | acceptance | code-review",
      "attempt": "integer",
      "result": "pass | fail",
      "advocateModel": "string or null",
      "challengerModel": "string or null",
      "rounds": "integer (rounds the debate ran)",
      "convergence": "mutual-done | cap-reached | one-sided",
      "findingsAddressed": ["string", "..."],
      "notes": "string or null"
    }
  ],
  "retryBudget": {
    "perGate": 3,
    "perPhase": {"discuss": 3, "plan": 4, "execute": null, "verify": 4},
    "global": 30,
    "globalUsed": 0,
    "perPhaseUsed": {"discuss": 0, "plan": 0, "execute": 0, "verify": 0},
    "perGateUsed": {}
  },
  "commands": {
    "test": "string",
    "lint": "string",
    "typecheck": "string"
  },
  "stalenessHours": 48,
  "warnings": ["array of strings"]
}
```

Notes:
- `tasks[]` and `waves[]` are gone. Live task state lives in the harness, not on disk.
- `retryBudget.executePerTask` is gone (per-task retries live on task metadata).
- `retryBudget.perPhase.execute: null` means **unlimited** (no per-phase cap for EXECUTE). The per-task budget (`tier.execute.maxRetriesPerTask`) is the operative limit during EXECUTE; a phase-level cap is intentionally omitted because EXECUTE's progress is bounded by the task DAG, not by gate retries.
- `currentTeamName`, `currentTeammates`, and `currentGate` are the rapidly-mutating fields. They let resume detection know whether a team for the current phase exists, who its teammates were, and where in the critique-debate loop the kill happened. All three are reset (`null` / `[]` / zeroed) after `TeamDelete`.
- Schema version jumps from 2 to 3. There is **no migration from v2** (clean break, see "Breaking changes" below).
- Atomic write via a new `lib/feature-write.sh` (same temp-rename pattern as `state-write.sh`, but writing to `.loop-spec/features/{slug}/feature.json` instead). Backup file is `feature.json.bak`.
- `.gitignore` gains a `.loop-spec/` entry as part of this change.

### Files removed or changed

| Path | Change |
|---|---|
| `lib/state-write.sh` | Deleted |
| `lib/feature-write.sh` | New file (atomic writer for `feature.json`) |
| `lib/gsd-ingest.sh` | Modified: stop writing `state.json`; instead emit `INGESTED <DOMAIN>` lines for the lead to update `feature.json` |
| `skills/shared/feature-state-schema.md` | Replaced with `feature.json` schema (above) and a section on harness-task-list usage per phase |
| `skills/cycle/SKILL.md` | Major rewrite (tool whitelist, Step 5 init, Step 6 routing, escalation handling) |
| `skills/discuss/SKILL.md` | Rewrite to team-based (TeamCreate, advocate/challenger SendMessage debate) |
| `skills/plan/SKILL.md` | Rewrite to team-based |
| `skills/execute/SKILL.md` | Rewrite to team-based with self-claim implementers; remove wave scheduling logic |
| `skills/verify/SKILL.md` | Rewrite to team-based |
| `skills/map-codebase/SKILL.md` | Rewrite to team-based mappers with shared findings |
| `tests/smoke.sh` | Update assertions: check `feature.json` instead of `state.json`; check team-creation log markers; update task-status assertions to read from harness via a smoke helper |
| `tests/validate-agents.sh` | Add a structural frontmatter rule: every file under `agents/*.md` is parsed for YAML frontmatter; if the frontmatter contains a `skills:` or `mcpServers:` key, the script exits non-zero with `agent {path} declares {key}: which is inert when the agent runs as a teammate; remove the key`. The rule applies to every file under `agents/` because in v1.0.0 every agent is teammates-only. If a future agent is intended to run standalone, the validator can be extended to honor an explicit `# loop-spec:standalone` marker as an opt-out; no such marker is added in v1.0.0. This is a frontmatter structural check only; the script does not analyze prompt bodies. |
| `.gitignore` | Add `.loop-spec/` so volatile state stays untracked. |
| `hooks/hooks.json` | Add `TeammateIdle`, `TaskCreated`, `TaskCompleted` hook entries pointing at new scripts under `hooks/team/` |
| `hooks/team/teammate-idle.sh` | New: nudge idle teammates that still have work |
| `hooks/team/task-created.sh` | New: validate task metadata shape |
| `hooks/team/task-completed.sh` | New: per-phase quality gate (lint / typecheck for EXECUTE; schema validation for DISCUSS / PLAN) |
| `hooks/restrict-agent-paths.sh` | Update path globs for any agent whose write scope changes |
| `README.md` | Document `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` requirement; document breaking change; update architecture diagram |
| `CHANGELOG.md` | New entry for v1.0.0 (breaking) |
| `.claude-plugin/plugin.json` | Bump version `0.3.2 -> 1.0.0` (breaking change warrants major) |

## Breaking change catalog

| Break | Detail | User impact |
|---|---|---|
| Tool whitelist inversion | The cycle skill's whitelist now requires `TeamCreate`, `TeamDelete`, `SendMessage`, `TaskCreate`, `TaskUpdate`, `TaskList`, `TaskGet`. The previous explicit ban is removed. | Any user-side hook or wrapper that filtered these tools must be updated. |
| `state.json` removed | Files in `.loop-spec/features/{slug}/state.json` are no longer read or written. | Any in-flight feature mid-cycle at upgrade time must be completed on the prior version (`git checkout v0.3.2`) or restarted from scratch. The cycle does not auto-migrate v2 state to v3. |
| `lib/state-write.sh` removed | Direct callers (only in-tree caller is the cycle skill itself, plus `lib/gsd-ingest.sh`) break. | Out-of-tree callers (none known) must migrate to `lib/feature-write.sh` or harness `TaskUpdate`. |
| `state.json` schema v2 deprecated | `feature.json` schema v3 is not a superset (no `tasks[]`, no `waves[]`, no `executePerTask`). | Documented in CHANGELOG; no auto-migration. |
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` required | Cycle aborts at startup if unset. | New prerequisite; documented in README and in the abort message. |
| Wave dispatch removed | `state.waves[]` and per-wave barrier logic are gone. | Behavior change in EXECUTE: implementers may finish in any order. Any external observer parsing `state.waves[]` for progress breaks. |
| Resume restricted | Cycle no longer resumes a feature with a live team. If the live-team probe (Resume strategy step 2) finds the team still alive (a `TaskList` call returns successfully against `currentTeamName`), the cycle prints the orphan-cleanup message with the explicit team name and asks the user to delete the team manually before retrying. | New friction on resume in narrow cases; documented in README and in the warning text. |
| Skills frontmatter on teammates is inert | Agent definitions used **exclusively** as teammates are forbidden from declaring `skills:` or `mcpServers:` in frontmatter (those keys are no-ops when the agent runs as a teammate). In v1.0.0, **all** agents under `agents/` are teammates-only, so the ban applies to every file under `agents/`. Agents that may run standalone (none currently exist in this repo) would be exempt from the ban; if such an agent is introduced later, the validator must be extended to special-case it via an opt-in marker. | `tests/validate-agents.sh` enforces this as a frontmatter structural check on every file under `agents/`; affected agents must be rewritten to invoke skills explicitly via `Skill(...)` calls in their prompt body, or get those tools through the tool whitelist directly. |
| State path moved | `feature.json` lives under `.loop-spec/features/{slug}/` (gitignored), not `docs/loop-spec/features/{slug}/`. | Anything that grepped `docs/loop-spec/features/*/feature.json` for live state must read `.loop-spec/features/*/feature.json`. Committed artifacts (`SPEC.md`, `PLAN.md`, `PATTERNS.md`, `EXECUTION.md`, `VERIFICATION.md`) stay in `docs/loop-spec/features/{slug}/`. |

## Prerequisites and configuration

### New prerequisite

```
export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
```

The cycle skill checks this in Step 2 (Startup health-check) and aborts on absence with the explicit error / fix message above.

### Tier-driven team parameters

New constants live in `skills/shared/tier-matrix.md` (extends the existing tier matrix):

| Tier | discuss.maxCritiqueRounds | plan.maxCritiqueRounds | execute.maxParallelImplementers | execute.maxRetriesPerTask |
|---|---|---|---|---|
| quality | 3 | 3 | 4 | 3 |
| balanced | 2 | 2 | 3 | 2 |
| quick | 1 | 1 | 2 | 1 |

These supersede the per-phase entries in the deleted `state.retryBudget.perPhase` for execute (which was previously `null`) and the implicit "all-tasks-in-wave-parallel" cap.

### Hook configuration

`hooks/hooks.json` gains three entries:

```json
{
  "TeammateIdle": [{"command": "bash hooks/team/teammate-idle.sh"}],
  "TaskCreated":  [{"command": "bash hooks/team/task-created.sh"}],
  "TaskCompleted":[{"command": "bash hooks/team/task-completed.sh"}]
}
```

These run for every team the cycle creates. Hook scripts read `feature.json` to determine the current phase and dispatch to the right validator.

## Resume strategy

Given the harness limitation that in-process teammates cannot be resumed:

1. **Resume detection (Step 1)** scans `.loop-spec/features/*/feature.json`.
2. **Live-team detection algorithm.** The harness exposes no `TeamList` tool, so the cycle infers liveness via a non-destructive read on the team's task list:
   - For each candidate with `currentTeamName != null`, the lead calls `TaskList({team: currentTeamName})`.
   - If `TaskList` returns without error: the team is live. Treat as orphan needing manual cleanup (see step 3 below).
   - If `TaskList` errors (team not found): the prior team is gone. The lead clears `currentTeamName` in `feature.json` and treats the candidate as resumable.
   - This algorithm is the same for any phase team name; no special-casing per phase. It is read-only and cannot accidentally create or delete a team.
3. **For each candidate:**
   - If `currentPhase == "completed"`: skip.
   - If the live-team probe (`TaskList`) returns successfully: print
     ```
     Previous team {currentTeamName} for feature {slug} was orphaned and is still live in the harness.
     Run TeamDelete for team {currentTeamName} (e.g., via the harness CLI or by re-invoking cycle in cleanup mode), then restart cycle to resume feature {slug}.
     ```
     Add the candidate to a "needs cleanup" sub-list shown to the user. The team name is included verbatim so the user can copy-paste.
   - If the live-team probe (`TaskList`) errors (team not found): print `"feature {slug} had stale team reference {name}; cleared and ready to resume"`. Add to resumable list. On resume, the lead recreates the phase team via `TeamCreate` with the full roster and replays phase Step 0 to re-populate the task list from on-disk artifacts (e.g. EXECUTE re-creates one harness task per row in `PLAN.md`). If `currentGate` is non-null in `feature.json`, the lead loads the prior debate transcript (from per-round logs under `.loop-spec/features/{slug}/gate-logs/`) into the spawn prompt of the new advocate / challenger so the resumed debate has prior context.
   - If `currentTeamName == null` AND `(now - updatedAt) < stalenessHours * 3600`: standard resumable case.
4. **No partial-task resume in EXECUTE.** When EXECUTE resumes after a kill, the lead inspects each `PLAN.md` task: if a commit on the feature branch already implements it (heuristic: any commit message containing the task id, or any commit touching all of the task's `files`), mark the task `completed` and skip. Otherwise re-create it via `TaskCreate` in `pending` status. This is best-effort; the user can manually mark tasks complete via a forthcoming `lib/feature-mark-task.sh` helper if the heuristic mis-identifies.
5. **Orphaned-team cleanup on exit.** Bash `trap` cannot invoke harness MCP tools (`TeamDelete` is only callable from inside the lead's tool-using context, not from a shell signal handler), so cleanup is implemented at the orchestration layer rather than via signal trap:
   - **Clean exit (orchestration-layer cleanup).** The cycle skill's main routing loop calls `TeamDelete({name: currentTeamName})` and clears `currentTeamName` in `feature.json` before every `return`, before every phase transition, and before every escalation that returns control to the user. This makes the common-case "cycle finishes a phase" and "cycle escalates to user" cleanly tear down the team.
   - **Kill (no automated cleanup).** If the cycle is killed mid-execution (SIGINT / SIGTERM / SIGKILL / OS crash / harness disconnect), no automated cleanup runs. The team remains live in the harness with `currentTeamName` still recorded in `feature.json`. Detection and cleanup happen on the next cycle invocation via the live-team probe in step 3 above: the lead prints the orphan-cleanup message with the explicit team name, and the user must run `TeamDelete` manually (e.g., via the harness CLI) before re-invoking the cycle to resume the feature.
   - There is no automatic recovery from a kill. The orphan path in step 3 is the sole cleanup mechanism for killed sessions.
6. **Document the limitation** in `README.md`: `"Resume after kill is supported at phase boundaries and at the task-list level inside EXECUTE, but not mid-teammate-conversation. A killed cycle replays the current critique gate from the persisted transcript; in-flight teammate scratch state is lost."`

## Retry / quality-gate strategy

The team architecture eliminates per-task retry counters in the lead-side `state.json`. New layout:

| Counter | Where it lives | Bumped by |
|---|---|---|
| Per-task retries | Harness task metadata `retries` field, accessed via `TaskGet` / `TaskUpdate` | `task-completed.sh` hook on `needs_rework` transition |
| Per-gate retries (advocate / challenger rounds) | `feature.json` `retryBudget.perGateUsed.{phase}.{gate}` (persisted, not in-memory; see "Critique debate protocol") | Each round of the critique-debate loop, via `lib/feature-write.sh` |
| Per-phase retries | `feature.json` `retryBudget.perPhaseUsed.{phase}` | Lead, on every gate failure in that phase, via `lib/feature-write.sh` |
| Global retries | `feature.json` `retryBudget.globalUsed` | Lead, on every gate failure across phases |
| Gate history | `feature.json` `gateHistory[]` | Lead, on every gate pass/fail |

Escalation triggers (unchanged in spirit, only transport changes):

- Any per-task `retries >= tier.execute.maxRetriesPerTask`: pause EXECUTE, print task and last review findings, return control to user.
- `retryBudget.perPhaseUsed.{phase} >= retryBudget.perPhase.{phase}`: pause phase, print `gateHistory` tail, return control to user.
- `retryBudget.globalUsed >= retryBudget.global`: hard abort, print full history, return control to user.

User can reset counters by editing `feature.json` directly (`globalUsed = 0`, `perPhaseUsed.{phase} = 0`) and re-invoking the cycle.

## Version and CHANGELOG guidance

- Bump `.claude-plugin/plugin.json` `version` from `0.3.2` to `1.0.0`. Breaking changes (state schema, prerequisite env var, removed library) warrant a major bump under semver.
- New CHANGELOG entry under a `## [1.0.0] - 2026-05-XX` heading. Required sub-sections:
  - `### Added` — agent-team architecture, `feature.json` schema v3, `lib/feature-write.sh`, three new hook scripts under `hooks/team/`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` requirement.
  - `### Changed` — every phase skill rewritten; tool whitelist inverted; resume semantics; codebase-mapper parallelism now via team.
  - `### Removed` — `state.json`, `lib/state-write.sh`, wave dispatch, `state.json` v2 schema migration path.
  - `### Migration` — explicit one-line guidance: "In-flight features cannot be migrated. Complete on v0.3.2 or restart on v1.0.0. New features start with `feature.json` v3."
- `README.md` updates:
  - Add `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` to the Quick Start prereqs list.
  - Replace the "wave dispatch" architecture paragraph with an "agent teams" paragraph (one paragraph per phase, plus the EXECUTE self-claim model).
  - Add a "Limitations" section listing the 5 harness limitations from the Constraints section above.

## Success criteria

- [ ] `bash tests/smoke.sh` passes end-to-end against the rewritten cycle (including a full DISCUSS -> PLAN -> EXECUTE -> VERIFY happy path on the smoke fixture).
- [ ] `bash tests/validate-agents.sh` passes. Verify command for the new rule: `bash tests/validate-agents.sh` exits 0 on the cleaned-up agent set, and exits non-zero when run against a temp copy where any one agent has `skills: [foo]` or `mcpServers: [foo]` injected into its frontmatter (the script's frontmatter parser must catch the structural presence of either key).
- [ ] Grep verification: `grep -rn "state.json\|state-write.sh" skills/ lib/ hooks/ tests/` returns only matches inside `CHANGELOG.md` (historical notes) and `docs/` (migration documentation). No live code references.
- [ ] Grep verification: `grep -rn "TeamCreate\|SendMessage\|TaskCreate" skills/cycle/ skills/discuss/ skills/plan/ skills/execute/ skills/verify/ skills/map-codebase/` returns at least one match per phase skill (proves the rewrite actually uses the new tools).
- [ ] Running `Skill(loop-spec:cycle)` with `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` unset aborts at Step 2 with the documented error message; running with it set proceeds past Step 2.
- [ ] Step 2 capability probe runs to completion against a real harness (creates `loop-spec-probe-{pid}`, exercises `TaskUpdate` with `awaiting_review`, writes/reads task `metadata`, sends a `SendMessage` round-trip, calls `TeamDelete`). Verify by inspecting the run log for `[PROBE] PASSED` lines for each of the three checks. With the env var set on a supported harness, Step 2 returns success; with `metadata` write disabled or `awaiting_review` rejected on a doctored harness, Step 2 aborts with the documented error message.
- [ ] After a successful cycle run on the smoke fixture, `.loop-spec/features/{slug}/feature.json` exists, validates against schema v3, has `currentPhase == "completed"` and `currentTeamName == null` and `currentTeammates == []` and `currentGate.round == 0`, and no `state.json` exists anywhere under `.loop-spec/features/{slug}/`. The committed `docs/loop-spec/features/{slug}/` directory contains `SPEC.md`, `PLAN.md`, `PATTERNS.md`, `EXECUTION.md`, `VERIFICATION.md` and **no `feature.json`**.
- [ ] `.gitignore` contains a `.loop-spec/` entry; `git status --ignored` confirms `.loop-spec/features/{slug}/feature.json` is ignored.
- [ ] **Distinct-implementers criterion (greppable, deterministic).** Smoke fixture extended to >= 4 tasks with at least 2 tasks having empty `blockedBy` and no `files` overlap (so no synthetic edge is added between them). After EXECUTE, the run log contains lines matching the regex `^\[TEAM-EXECUTE\] task-[0-9]+ claimed by implementer-[0-9]+$`. The number of distinct `implementer-M` suffixes appearing in those lines must be >= 2, proving more than one implementer ran tasks. Verify command: `grep -oE 'implementer-[0-9]+' run.log | sort -u | wc -l` returns >= 2. No timing or simultaneity assertion is made; the test passes deterministically as long as at least two distinct implementers each claimed at least one task.
- [ ] During DISCUSS on the smoke fixture, the run log shows at least one `SendMessage` from `advocate-1` to `challenger-1` (or vice versa, addressed by name) prior to the lead synthesizing the fix-list.
- [ ] Critique-debate convergence: for each critique gate run on the smoke fixture, `feature.json.gateHistory[]` contains an entry whose `convergence` field is one of `mutual-done | cap-reached | one-sided` and whose `rounds` field is `<= tier.{phase}.maxCritiqueRounds`.
- [ ] Per-gate retry counter persistence: kill the cycle mid-debate (round 2 of a 3-round gate), restart, and verify that `feature.json.retryBudget.perGateUsed.{phase}.{gate}` retained its non-zero value across the kill (the resumed gate does not get a fresh budget).
- [ ] CHANGELOG `## [1.0.0]` entry exists with all four required sub-sections (`Added`, `Changed`, `Removed`, `Migration`).
- [ ] `.claude-plugin/plugin.json` `version` field is `"1.0.0"`.
- [ ] `README.md` Quick Start section mentions `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` and the README has a "Limitations" section listing the 5 harness limitations.
- [ ] **Resume detection algorithm.** Resume on a feature whose `currentTeamName` references a team that no longer exists: the live-team probe `TaskList({team: currentTeamName})` errors, the lead clears `currentTeamName`, recreates the phase team with the full roster, and continues. Resume on a feature with a still-live `currentTeamName`: the probe `TaskList` returns successfully, the cycle prints the orphan-cleanup message with the explicit team name and does not attempt to recreate.
- [ ] **Clean-exit team cleanup.** On a normal cycle exit (all phases complete, `currentPhase == "completed"`), verify that `TeamDelete` was called for the final phase team: `feature.json.currentTeamName == null` after exit, and a follow-up `TaskList({team: "<final-phase-team-name>"})` against the harness errors with team-not-found (proving the team is actually gone, not just dereferenced in `feature.json`). Repeat the assertion at every phase boundary during the run (between DISCUSS->PLAN, PLAN->EXECUTE, EXECUTE->VERIFY, VERIFY->completed): each transition's prior team must be gone before the next team is created.
- [ ] **Kill-path orphan detection.** Send `SIGTERM` to the cycle while it has an active team; verify the team is **still alive** in the harness after kill (no automated cleanup ran, as documented), `feature.json.currentTeamName` still references the live team, and the next cycle invocation prints the orphan-cleanup message with the explicit team name. After the user manually runs `TeamDelete` for the printed name and re-invokes cycle, resume proceeds normally.
- [ ] **File-conflict scope.** Default behavior: smoke fixture includes two tasks whose `files` lists overlap on a single shared file; verify a synthetic `blockedBy` edge IS added (default exclusion list is empty). Override behavior: re-run with `.loop-spec/file-conflict-exclude.txt` containing the shared file's path as a single line; verify no synthetic edge is added on the second run. Repeat with the same path placed in `feature.json.fileConflictExcludeGlobs[]` instead of the file; verify the same suppression result. Add a third task whose `files` list shares a non-excluded implementation file with one of the first two; verify a synthetic `blockedBy` edge IS added in that case.
- [ ] All commits on the feature branch follow the project's conventional-commit format (`feat: NO_JIRA ...`, `chore: ...`, etc.) and `bash tests/smoke.sh` is run prior to each commit per the project's `# Change Process` rule.

## Out of scope

- Auto-migration of `state.json` v2 to `feature.json` v3. Considered and explicitly excluded: writing a `lib/migrate-v2-to-v3.sh` would couple the breaking-change release to a code path that exists only to handle a one-time transition, and the user-facing migration story (finish on v0.3.2 or restart) is acceptable for a pre-1.0 plugin.
- Cross-feature concurrency (e.g., running DISCUSS for feature A while EXECUTE runs for feature B). Considered and excluded: the harness one-team-per-lead constraint plus the cycle's worktree model would require non-trivial coordination work for a use case no current user has requested.
- Sub-teams inside EXECUTE (e.g., a per-task team with implementer + reviewer pair). Considered and excluded: harness forbids nested teams.
- A new harness-native worktree integration via `EnterWorktree` / `ExitWorktree`. Considered and excluded: the existing raw `git worktree add` flow in `lib/git-ops.sh` is well-tested and the new cycle no longer has waves to coordinate against, removing the original justification for switching but also removing any urgency.
- Replacing `lib/gsd-ingest.sh` with a teammate. Considered and excluded: ingestion is a deterministic file-copy operation with no agent reasoning required; running it in-line via `Bash` is simpler than spinning up a team.
- Live progress UI / dashboard reading from `TaskList`. Considered and excluded: out-of-band tooling; the cycle prints task status to stdout, which is sufficient for the existing CLI workflow.
- Telemetry on team-message volume or per-teammate token cost. Considered and excluded: no current cost-tracking infrastructure to plug into.
- Backporting any agent-team feature to v0.3.x. Considered and excluded: the whole point of v1.0.0 is the breaking rewrite.

## Open questions

(none - resolved during DISCUSS phase)
