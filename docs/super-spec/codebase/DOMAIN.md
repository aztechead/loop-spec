# DOMAIN

> Produced by `super-spec-mapper-domain`. Last refreshed: 2026-05-11.

## Glossary

| Term | Definition |
|------|------------|
| **Cycle** | The end-to-end feature-development workflow: DISCUSS -> PLAN -> EXECUTE -> VERIFY. A single cycle produces one feature branch, its four committed artifacts, and a PR. |
| **Phase** | One of the four named stages of a cycle: DISCUSS, PLAN, EXECUTE, VERIFY. Each phase is implemented as a separate skill and produces a committed artifact. |
| **Skill** | A reusable, named procedure invoked via `Skill(super-spec:{name})`. Skills are Claude Code plugin entry points defined in `skills/{name}/SKILL.md`. |
| **Agent** | A one-shot, specialized subagent dispatched via the `Agent` tool. Each agent has a fixed role, a tool allow-list, and a default model. Agents are defined in `agents/super-spec-{role}.md`. |
| **Tier** | A user-chosen quality/gate level for a cycle: `quality`, `balanced`, or `quick`. Controls whether the critique gate runs and which code-review severity threshold blocks the cycle. Does not control which model is used. |
| **Model Preset** | A user-chosen cost/quality level that maps each agent role to a specific model: `quality`, `balanced`, or `fast`. Orthogonal to tier. Opus is reserved for spec/plan authoring only (see `skills/shared/preset-matrix.md`). |
| **Execution Style** | A user-chosen control mode for how much the cycle pauses for human input: `auto`, `step`, `interactive`, or `review-only`. |
| **Feature** | A unit of planned work identified by a human-readable title and a derived kebab-case slug. A feature has exactly one cycle run (or a resumed run). |
| **Slug** | The kebab-case identifier derived from the feature title (e.g., "add subtract function" -> `add-subtract-function`). Used as the key for directory paths, branch names, and state files. |
| **Artifact** | A committed markdown document produced by a phase: SPEC.md, PATTERNS.md, PLAN.md, VERIFICATION.md. Artifacts survive context clears. |
| **SPEC.md** | The requirements document produced by DISCUSS. Captures problem, goals, non-goals, constraints, user-facing behavior, and testable success criteria. |
| **PLAN.md** | The implementation plan produced by PLAN. Captures task DAG, file map, per-task acceptance criteria, and verify commands. (Wave assignments were removed in v1.0.0; EXECUTE now uses harness-managed self-claim parallelism, with synthetic `blockedBy` edges derived from file overlap.) |
| **PATTERNS.md** | A codebase pattern reference produced by the pattern-mapper at the start of PLAN. Maps feature concepts to existing implementation analogs so the planner can write house-style-conformant tasks. |
| **VERIFICATION.md** | The acceptance evidence document produced by VERIFY. Records pass/fail per criterion, verify command outputs, code-review findings, and PR URL. |
| **Codebase Map** | Five committed markdown files (`TECH.md`, `ARCH.md`, `QUALITY.md`, `CONCERNS.md`, `DOMAIN.md`) under `docs/super-spec/codebase/` that describe the consuming project. Generated once on first cycle run, refreshed incrementally at end of each cycle. |
| **Task** | An atomic, committable unit of implementation work within a feature. Has a PLAN.md id (`task-NNN`), subject, file list, verify command, acceptance criteria, and a harness-managed lifecycle status. Persisted in the harness task list (not in `feature.json`). |
| **Task DAG** | The directed acyclic graph of tasks for a feature. Tasks declare dependencies via `blockedBy`. The planner ensures the DAG is acyclic; EXECUTE additionally adds synthetic `blockedBy` edges between any pair of pending tasks whose file lists overlap (see `skills/execute/SKILL.md` Step 2b), preventing concurrent worktree races on shared files. |
| **Worktree** | A git worktree created under `.super-spec/worktrees/{slug}/task-NNN/` for exactly one implementing agent. Each worktree is isolated from all other concurrent worktrees, eliminating working-tree races. Lifecycle is bounded to the task: created on claim, removed after the implementer's commit merges into `feat/{slug}`. |
| **Gate** | A quality checkpoint between steps in a phase. On failure, the gate re-dispatches the upstream agent with a fix-list (bounded by retry budgets). Named gates: spec-critique, plan-critique, plan-feasibility, spec-compliance, acceptance, code-review HARD-GATE. |
| **Critique Gate** | A paired review gate run during DISCUSS (on SPEC.md) and PLAN (on PLAN.md). Dispatches an advocate and a challenger in parallel; their findings are reconciled into a fix-list. Skipped on `quick` tier. |
| **HARD-GATE** | The code-review gate in VERIFY that blocks the PR if Critical (or Important, on quality/balanced tier) findings are found. Generates remediation tasks and re-enters EXECUTE. |
| **Retry Budget** | Bounded counters preventing the self-heal loop from running forever. Three scopes: per-gate (max 3 consecutive retries on one gate), per-phase (separate cap per phase), and global (30 across the entire feature). |
| **Self-heal Loop** | The AUTO execution style's failure recovery mechanism. On gate failure, the orchestrator re-dispatches the upstream agent with findings, increments retry counters, and re-runs the gate -- without user intervention. |
| **Stall Detection** | Logic applied during EXECUTE resume against an orphaned `in_progress` task in the harness task list. Distinguishes three cases on the per-task worktree: a commit on the task branch (release ownership + set `metadata.phase = "awaiting_review"`), uncommitted dirty changes (instruct the resuming implementer to re-claim with the partial diff as context), or a clean stall (re-claim and restart from scratch). |
| **Staleness Window** | The 48-hour window within which an incomplete feature's `feature.json` is considered resumable. Features last updated beyond this window are not offered for resume. |
| **GSD / get-shit-done** | An upstream multi-phase spec-driven workflow (`gsd-build/get-shit-done`). super-spec can ingest its `.planning/codebase/` artifacts on first run via `lib/gsd-ingest.sh`. DOMAIN.md has no GSD analog and is always freshly mapped. |
| **Health Check** | A startup probe run by the cycle skill that dispatches a 1-token completion against each of the three model IDs to verify they are accessible under the project's `CLAUDE.md` model policy. Aborts loudly on failure. |
| **Provenance** | Tracking of how each artifact was produced: `gsd-ingest`, `pattern-mapper`, `mapper`, or `manual`. Stored in `feature.json.artifacts.codebaseSource.*` and `feature.json.artifacts.patternsSource`. |
| **Remediation Task** | A task generated by VERIFY when an acceptance criterion fails or a code-review HARD-GATE fires. Appended to `feature.json.pendingRemediationTasks[]` (so it survives the verify team's `TeamDelete`), then consumed by EXECUTE Step 2a on re-entry and merged into the harness task list alongside PLAN.md tasks. Gets a fresh retry budget. |
| **TDD Ordering** | The requirement that code-producing tasks in PLAN write a failing test before implementing. Non-code tasks (config, docs, skills) are excluded. Enforced by the planner's role definition and the spec-compliance reviewer. |
| **Non-interactive Mode** | A CI/scripting mode activated by `SUPER_SPEC_NON_INTERACTIVE=1`. Reads tier, preset, style, and title from env vars, bypassing all `AskUserQuestion` calls. |
| **index.json** | A tracked file at `.super-spec/codebase/index.json` mapping file paths to the codebase domains they belong to. Used to compute which domains are stale after a feature branch lands. |

---

## Entities

### Feature

The central runtime entity. Corresponds to one planned and implemented piece of work.

| Attribute | Type | Description |
|-----------|------|-------------|
| `schemaVersion` | integer | `3` (current) |
| `slug` | string (kebab-case) | Unique identifier derived from feature title |
| `tier` | enum | `quality`, `balanced`, or `quick` |
| `preset` | enum | `quality`, `balanced`, or `fast` |
| `execStyle` | enum | `auto`, `step`, `interactive`, or `review-only` |
| `currentPhase` | enum | `discuss`, `plan`, `execute`, `verify`, `completed` |
| `completedPhases` | string[] | Ordered list of phases that have exited successfully |
| `currentTeamName` | string \| null | Harness team name for the active phase (used by resume detection to probe team liveness) |
| `currentTeammates` | string[] | Roster of the active phase team |
| `currentGate` | object | `{phase, gate, round, advocateName, challengerName, startedAt}` for the active critique gate (zeroed when no gate is running) |
| `branch` | string | Git branch: `feat/{slug}` |
| `baseSha` | string | Git SHA at time of branch creation |
| `baseBranch` | string | Base branch for the eventual PR (detected from origin/HEAD; default `main`) |
| `artifacts` | object | Paths to SPEC.md, PATTERNS.md, PLAN.md, VERIFICATION.md plus provenance fields (`patternsSource`, `codebaseSource.{domain}`) |
| `mergeQueue` | string[] | FIFO queue of task ids awaiting `git merge --ff-only` into `feat/{slug}` |
| `pendingRemediationTasks` | object[] | Remediation tasks generated by VERIFY (acceptance gate or code-review HARD-GATE); consumed and cleared by EXECUTE Step 2a on re-entry |
| `fileConflictExcludeGlobs` | string[] | Per-feature glob list that exempts file overlaps from synthetic `blockedBy` edges in EXECUTE Step 2 |
| `gateHistory` | GateRecord[] | Audit log of every gate attempt |
| `retryBudget` | object | Per-gate, per-phase, and global retry counters (used and ceiling fields) |
| `commands` | object | Project-specific test/lint/typecheck commands |
| `stalenessHours` | integer | Resume window, default 48 |
| `bootstrapPendingDomains` | string[] | Codebase domains fired as background mappers in cycle Step 5.5b; cleared by DISCUSS Step 1.5 |
| `warnings` | string[] | Non-fatal issues logged during the cycle |

Persisted as `feature.json` (schema v3) under `.super-spec/features/{slug}/`. The previous v2 `state.json` filename and schema (which embedded `tasks[]` and `waves[]` directly) was removed in v1.0.0; tasks are now persisted via the harness `TaskList` for the active EXECUTE team and waves were replaced by self-claim parallelism (see `skills/execute/SKILL.md`).

---

### Task

An atomic unit of implementation work within a feature. Persisted in the harness task list (`TaskCreate`/`TaskUpdate`/`TaskGet`/`TaskList`) for the active EXECUTE team, NOT inside `feature.json`. The harness assigns the durable task id; PLAN.md task ids (`task-NNN`) are stored in `metadata` for cross-reference.

| Attribute | Type | Description |
|-----------|------|-------------|
| `taskId` | string | Harness-assigned id (used in `TaskUpdate`/`TaskGet`) |
| `title` | string | `{plan-task-id}: {subject}` for traceability |
| `status` | enum | `pending`, `in_progress`, `completed` (the three statuses documented by the Claude Code agent-teams harness) |
| `metadata.phase` | enum \| null | Sub-state used while `status == "in_progress"`: `null` (mid-implementation), `"awaiting_review"` (implementer handed off, reviewer should claim), `"needs_rework"` (reviewer rejected, implementer should re-claim). Owner is `null` when the task is in the review or rework queue. |
| `metadata.result` | string \| null | Set when `status == "completed"`: `null` for normal pass, `"blocked"` when reviewer hit `tier.execute.maxRetriesPerTask` (lead pauses and escalates). |
| `owner` | string \| null | Teammate name that holds the claim (set on successful self-claim) |
| `metadata.blockedBy` | string[] | Union of explicit `blockedBy` edges from PLAN.md and synthetic edges from EXECUTE Step 2b file-conflict detection |
| `metadata.files` | string[] | Explicit list of files this task may create or modify |
| `metadata.verifyCommand` | string | Shell command whose exit code proves completion |
| `metadata.acceptanceCriteria` | string[] | Human-readable criteria checked by the reviewer (or by the implementer in quick tier) |
| `metadata.claimedBy` | string \| null | Implementer teammate name (written after claim; used by reviewer to address rework) |
| `metadata.retries` | integer | Count of reviewer re-dispatches consumed; capped by `tier.execute.maxRetriesPerTask` |
| `metadata.specPath` | string \| null | Optional per-task spec section path inside SPEC.md |

---

### Gate Record

An entry in the audit log of gate attempts.

| Attribute | Type | Description |
|-----------|------|-------------|
| `phase` | string | Which phase owned this gate |
| `gate` | enum | `spec-critique`, `plan-critique`, `plan-feasibility`, `spec-compliance`, `acceptance`, `code-review` |
| `attempt` | integer | Attempt number (1 = first try) |
| `result` | enum | `pass` or `fail` |
| `advocateModel` | string | Model used for advocate (critique gates only) |
| `challengerModel` | string | Model used for challenger (critique gates only) |
| `findingsAddressed` | string[] | Fix-list items resolved in this attempt |
| `convergence` | enum | `mutual-done`, `cap-reached`, or `one-sided` (critique gates only) |
| `notes` | string \| null | Free-text annotation (e.g., `"cap reached"`) |

---

### Codebase Domain

One of five named lenses through which the consuming project's codebase is documented.

| Domain | Covers |
|--------|--------|
| `TECH` | Languages, package manager, production and dev dependencies, build/run commands |
| `ARCH` | Modules, boundaries, import graph, entrypoints, external integrations, data flow |
| `QUALITY` | Test coverage, lint state, type safety, conventions |
| `CONCERNS` | Security hotspots, performance risks, tech debt |
| `DOMAIN` | Business concepts, glossary, entity model (this document) |

Each domain is a file under `docs/super-spec/codebase/` and is refreshed incrementally based on which files changed since the last cycle.

---

## Workflows

### Full Feature Cycle

1. User invokes `Skill(super-spec:cycle)`.
2. Cycle skill probes model availability (health check) and the agent-teams harness capabilities (capability probe).
3. User selects tier, model preset, execution style, and feature title.
4. Cycle detects project test/lint/typecheck commands.
5. If first run: codebase map is produced (GSD ingest where possible, mapper agents for the rest).
6. DISCUSS phase: conversational clarification, spec-writer produces SPEC.md, critique gate runs (skipped on quick tier).
7. PLAN phase: pattern-mapper produces PATTERNS.md, planner produces PLAN.md plus task DAG, critique gate + feasibility gate run.
8. EXECUTE phase: a long-lived team of implementers (and reviewers on quality/balanced tiers) self-claim unblocked tasks from the harness task list, work in per-task worktrees, and the lead sequentially `git merge --ff-only`s reviewed tasks into the feature branch.
9. VERIFY phase: unresolved marker scan, verifier + code-reviewer run in parallel, acceptance gate and code-review HARD-GATE run, codebase map refreshes, branch is pushed and PR is opened.

### Resume

1. User re-invokes `Skill(super-spec:cycle)`.
2. Cycle scans `.super-spec/features/*/feature.json` for incomplete features within the staleness window. For each candidate it probes `currentTeamName` via `TaskList`: if the team is still live, the feature is added to a "needs cleanup" list (manual `TeamDelete` required); if the team is gone, `currentTeamName` is cleared and the feature is offered for resume.
3. User selects a resumable feature (or starts a new one).
4. Cycle loads `feature.json`, recreates the phase team fresh via `TeamCreate` (the harness does not support in-process teammate resume), and the phase skill replays from the last completed subphase using the persisted artifact and gate state.
5. Execution continues from the last completed step.

### Codebase Map Refresh

Auto-runs at end of VERIFY. Can also be invoked standalone:
- Incremental: derives stale domains from `git diff` since `baseSha` compared to `index.json`.
- Full: re-maps all five domains.
- Per-domain: `--domain tech,arch`.

Mapper agents run in parallel; each writes one domain file. `index.json` is updated after all mappers return.

### Self-heal (AUTO style)

On any gate failure: build fix-list from findings, check all three retry budgets, re-dispatch the owning agent with fix-list embedded in prompt, re-run gate. Escalate to user when any budget is exhausted.

---

## External Stakeholders

| Stakeholder | Role |
|-------------|------|
| **Developer (user)** | The sole human operator. Chooses tier, preset, execution style, and feature title. Reviews artifacts in STEP/INTERACTIVE styles. Resolves escalations. |
| **Claude Code (CC) harness** | The runtime that executes skills, dispatches agents, runs the PreToolUse hook, and provides the `Agent`, `Bash`, `Read`, `Write`, `AskUserQuestion`, and `Skill` tools. |
| **Anthropic model API** | Provides the three model tiers (`claude-opus-4-7`, `claude-sonnet-4-6`, `claude-haiku-4-5`) used by all agents. |
| **Git / GitHub** | Hosts the consuming project's repository. super-spec creates branches, commits, worktrees, and PRs via git CLI and `gh`. |
| **get-shit-done (GSD)** | An optional upstream tool whose `.planning/codebase/` and `.planning/phases/{slug}/PATTERNS.md` artifacts can be ingested on first run. No runtime coupling; ingest is one-way and one-time. |
| **Claude Code plugin marketplace** | The mechanism by which super-spec is distributed and installed into a consuming project (`claude plugin install super-spec@super-spec-marketplace`). |
