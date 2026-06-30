# ARCH

> Mapped by loop-spec-mapper-arch on 2026-05-11. Incremental mode (since e4fea421). Sections updated: lib/, hooks/, Key Abstractions, Module Dependencies, Data Flow Summary, .loop-spec/ runtime state.

## Modules

loop-spec is a Claude Code plugin. There are no compiled source modules. The functional units are markdown files interpreted by the Claude Code harness. The layout below treats each directory as a logical module with its own boundary and responsibility.

### `.claude-plugin/` - Plugin Manifest

Declares the plugin identity (`name`, `version`, `author`, `homepage`) in `plugin.json` and a marketplace descriptor in `marketplace.json`. This is the install boundary: the CC harness reads `plugin.json` to register skills, agents, hooks, and commands from the repo.

### `skills/` - Phase Orchestration

Each subdirectory is a named skill invocable via `Skill(loop-spec:<name>)`. Skills are stateful orchestrators; they issue `TeamCreate`/`SendMessage` calls, read/write `feature.json` via `lib/feature-write.sh`, and drive phase transitions.

| Skill | Responsibility |
|---|---|
| `cycle/` | Top-level entry point. Step 2 resolves the agent-team capability mode via `lib/teams-capability.sh` (`none`/`explicit`/`implicit`, version-gated on the 2.1.178 `TeamCreate`/`TeamDelete` removal) and records `teamsMode`+`teamsAvailable` in `runtime.json`. Collects tier/preset/style/title, initializes `feature.json` (schemaVersion 3), triggers Step 5.5 codebase bootstrap on first run, drives the phase team per the resolved mode (explicit `TeamCreate`, implicit `Agent({name})`, or no-teams fallback), and routes to the current phase skill. Owns resume detection and orphan team cleanup. |
| `discuss/` | DISCUSS phase. Conversational requirements loop; creates a persistent team (spec-writer-1, advocate-1, challenger-1); drives spec-writer via SendMessage; runs advocate/challenger debate loop via SendMessage; commits SPEC.md; advances `feature.json` to `plan`. |
| `plan/` | PLAN phase. Creates a persistent team (pattern-mapper-1, planner-1, advocate-1, challenger-1); drives pattern-mapper and planner via SendMessage; runs critique/feasibility gates; commits PLAN.md; advances `feature.json` to `execute`. |
| `execute/` | EXECUTE phase. Pre-task file-conflict detection with synthetic `blockedBy` edges; TaskCreate for all tasks; parallel self-claim dispatch (implementers poll and claim via TaskUpdate); per-task spec-compliance review; FIFO merge queue; commits per task. |
| `verify/` | VERIFY phase. Creates a persistent team (verifier-1, code-reviewer-1); runs verifier and code-reviewer in parallel via SendMessage; acceptance gate; code-review hard gate; incremental map-codebase refresh; pushes branch; opens PR via `gh pr create`; commits VERIFICATION.md; marks `feature.json` `completed`. |
| `map-codebase/` | Standalone and auto-invoked skill. Determines stale domains from git diff against index.json; creates a mapper team; dispatches mapper-*-1 teammates via SendMessage; updates index.json; commits. |
| `shared/` | Shared reference data read by all skills and agents. Not invoked directly. |

### `skills/shared/` - Shared Policy and Templates

| File | Responsibility |
|---|---|
| `preset-matrix.md` | Table mapping role families to model IDs per preset (quality/balanced/fast). Single source of truth for all model selection. Opus is reserved for spec/plan authoring only. |
| `tier-matrix.md` | Gate behavior by tier (quality/balanced/quick): which gates run, round caps, severity thresholds. Tier and preset are orthogonal axes. |
| `feature-state-schema.md` | Canonical JSON schema for `feature.json` (schemaVersion 3): fields, harness task list usage per phase, atomic write contract. No migration from v2 (clean break). |
| `model-policy.md` | Allowed model IDs, 1M-context probe behavior, consuming-project compatibility notes. |
| `artifact-templates/` | Mustache-style templates for SPEC.md, PLAN.md, VERIFICATION.md, PATTERNS.md. Read by spec-writer, planner, verifier, pattern-mapper at artifact creation time. |

### `agents/` - Subagent Definitions

14 agent definition files. Each declares `name`, `description`, `tools` (allow-list), and `model` (default, overridden at dispatch by preset-matrix). In v1.0.0+ most agents run as persistent teammates spawned inside a `TeamCreate` call (the lead routes work to them via `SendMessage`); only the cycle Step 2 capability probe and Step 5.5b background codebase mappers still use one-shot `Agent({subagent_type, model, prompt})` dispatches.

**Phase agents** (write artifacts, called by phase skills):

| Agent | Writes | Tools |
|---|---|---|
| `loop-spec-spec-writer` | `docs/loop-spec/features/{slug}/SPEC.md` | Read, Write, Edit, Grep, Glob |
| `loop-spec-planner` | `docs/loop-spec/features/{slug}/PLAN.md` | Read, Write, Edit, Grep, Glob, Bash (read-only) |
| `loop-spec-implementer` | Code files in worktree, commits to `task/NNN-{slug}` branch | Read, Write, Edit, Bash, Grep, Glob |
| `loop-spec-verifier` | `docs/loop-spec/features/{slug}/VERIFICATION.md` | Read, Write, Edit, Bash, Grep, Glob |
| `loop-spec-pattern-mapper` | `docs/loop-spec/features/{slug}/PATTERNS.md` | Read, Write, Edit, Grep, Glob, Bash (read-only) |

**Gate agents** (read-only, no Write/Edit in tool list):

| Agent | Role |
|---|---|
| `loop-spec-advocate` | Defends SPEC.md or PLAN.md in critique gate |
| `loop-spec-challenger` | Critiques SPEC.md or PLAN.md in critique gate |
| `loop-spec-spec-compliance-reviewer` | Verifies one implementer commit matches task spec |
| `loop-spec-code-reviewer` | Quality and security review of feature branch diff |

**Mapper agents** (write codebase docs only):

| Agent | Writes |
|---|---|
| `loop-spec-mapper-tech` | `docs/loop-spec/codebase/TECH.md` |
| `loop-spec-mapper-arch` | `docs/loop-spec/codebase/ARCH.md` |
| `loop-spec-mapper-quality` | `docs/loop-spec/codebase/QUALITY.md` |
| `loop-spec-mapper-concerns` | `docs/loop-spec/codebase/CONCERNS.md` |
| `loop-spec-mapper-domain` | `docs/loop-spec/codebase/DOMAIN.md` |

### `commands/` - Slash Command Shims

Six thin command files (`cycle.md`, `discuss.md`, `plan.md`, `execute.md`, `verify.md`, `map-codebase.md`). Each is a one-line shim that tells the CC main thread to invoke the corresponding `Skill(loop-spec:<name>)`. They expose individual phases as standalone slash commands so users can invoke any phase directly without going through cycle.

### `hooks/` - PreToolUse / Event Enforcement

Three hook registration points in `hooks.json`:

**`hooks/restrict-agent-paths.sh`** (PreToolUse: Write|Edit): path-glob enforcement for agent write access.

- `loop-spec-spec-writer`, `loop-spec-planner`, `loop-spec-pattern-mapper`: write allowed only under `docs/loop-spec/features/**`
- `loop-spec-mapper-*`: write allowed only under `docs/loop-spec/codebase/**`
- `loop-spec-implementer`, `loop-spec-verifier`, main thread: unrestricted

Returns exit 0 (allow) or exit 2 (block with error message).

**`hooks/team/task-created.sh`** (PreToolUse: TaskCreate): validates required metadata fields on every `TaskCreate` call. Required fields: `blockedBy`, `files`, `verifyCommand` (non-empty string), `acceptanceCriteria` (non-empty array). Returns exit 0 or exit 2 with a `DENY:` message.

**`hooks/team/task-completed.sh`** (PostToolUse: TaskUpdate): phase-aware quality gate on task completion (fires when `tool_input.status == "completed"`). Reads `feature.json` to determine `currentPhase`:
- `execute`: runs `commands.lint` and `commands.typecheck` from `feature.json` if configured; blocks on failure (exit 2).
- `discuss` / `plan`: re-validates task metadata has all required fields; blocks if missing.
- Other phases: allow (exit 0).

**`hooks/team/teammate-idle.sh`** (TeammateIdle event): advisory-only (always exit 0). Emits a phase-contextual message to stderr when a teammate goes idle, derived from `currentPhase` in `feature.json`. Never blocks.

### `lib/` - Shared Bash Scripts

Called via `Bash` tool from skills. Not invokable as skills themselves.

| Script | Responsibility |
|---|---|
| `feature-write.sh` | Atomic write of `.loop-spec/features/{slug}/feature.json`. Three calling modes: (1) `<feature_dir> <json>` -- full replace; (2) `set <feature_dir> <dot_path> <value_json>` -- targeted key set via jq; (3) `append <feature_dir> <dot_path> <value_json>` -- array append via jq. Validates JSON, writes `.tmp`, fsyncs, rotates `.bak`, renames. Replaces the removed `lib/state-write.sh`. |
| `team-ops.sh` | Team name helpers. Functions: `team_name_for_phase <phase> <slug>` (returns `"loop-spec-{phase}-{slug}"`), `assert_team_env` (exits 2 if `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS != "1"`), `feature_json_path <slug>` (returns canonical path). Supports CLI dispatch (`bash lib/team-ops.sh <function_name> [args]`). |
| `teams-capability.sh` | Resolves the agent-team capability mode to one word: `none` (flag unset), `explicit` (flag=1, CC < 2.1.178, legacy `TeamCreate`/`TeamDelete`), or `implicit` (flag=1, CC >= 2.1.178, implicit team via `Agent({name})`). Deterministic + version-gated like `workflow-availability.sh`; unknown version defaults to `implicit`. Override: `LOOP_SPEC_TEAMS_MODE`. Consumed by cycle Step 2. |
| `git-ops.sh` | Git helpers: `detect-base-branch`, `slugify <text>`, `ensure-clean-or-stash`, `current-sha`. |
| `gsd-ingest.sh` | Ingests existing get-shit-done artifacts into loop-spec format. Two subcommands: `codebase` (maps `.planning/codebase/` files to the 5 codebase docs) and `patterns <slug> <target>` (copies GSD PATTERNS.md if present). Prints `INGESTED`/`SKIPPED`/`NONE` lines; caller parses stdout. |

### `.loop-spec/` - Runtime State (gitignored except index.json)

Per-feature runtime state and temporary worktrees. Not committed except `.loop-spec/codebase/index.json`.

| Path | Responsibility |
|---|---|
| `.loop-spec/features/{slug}/feature.json` | Feature lifecycle state (schemaVersion 3): phase, currentTeamName, currentTeammates, currentGate, gateHistory[], retryBudget, artifact paths, commands, mergeQueue, warnings. Replaces `state.json` (v2). Tasks and waves are no longer stored here; they live in the harness task list. |
| `.loop-spec/features/{slug}/feature.json.bak` | Last-good backup; used by cycle on parse failure. |
| `.loop-spec/features/{slug}/discuss-transcript.md` | Conversational transcript from DISCUSS Step 1. Read by spec-writer at dispatch. |
| `.loop-spec/features/{slug}/gate-logs/` | Per-round debate transcripts (`spec-critique-round-N.md`, `plan-critique-round-N.md`). Written by lead after each round; read on resume to populate advocate/challenger prior context. |
| `.loop-spec/features/{slug}/tasks/task-NNN.spec.md` | Per-task spec files; created by EXECUTE only when a task is complex enough to warrant a dedicated spec (set by planner). |
| `.loop-spec/worktrees/{slug}/task-NNN/` | Git worktrees; one per in-flight task, lifecycle = task (created on claim, pruned after the task's commit merges into `feat/{slug}`). |
| `.loop-spec/codebase/index.json` | Committed. Maps file paths to domain names for incremental refresh. Records `last_refreshed_at` per domain. |

### `docs/loop-spec/` - Committed Artifacts (in consuming project)

| Path | Responsibility |
|---|---|
| `docs/loop-spec/codebase/{TECH,ARCH,QUALITY,CONCERNS,DOMAIN}.md` | Five-domain codebase map. Written by mapper agents or ingested from GSD. Auto-refreshed incrementally at end of each VERIFY. |
| `docs/loop-spec/features/{slug}/SPEC.md` | Feature specification. Committed at end of DISCUSS. |
| `docs/loop-spec/features/{slug}/PATTERNS.md` | Code pattern analogs for this feature. Written by pattern-mapper at start of PLAN. |
| `docs/loop-spec/features/{slug}/PLAN.md` | Task DAG with files, verify commands, acceptance criteria, and explicit `blockedBy` edges. Committed at end of PLAN. |
| `docs/loop-spec/features/{slug}/VERIFICATION.md` | Acceptance criteria results, code-review findings, test suite output. Committed at end of VERIFY. |

### `tests/` - Test Infrastructure

| File | Responsibility |
|---|---|
| `smoke.sh` | Zero-dep bash smoke test. Copies `tests/fixtures/minimal-py` to a temp dir, runs `claude --print "Skill(loop-spec:cycle)"` in non-interactive mode, asserts SPEC/PLAN/VERIFICATION exist, `feature.json` `currentPhase` is `completed`, `schemaVersion` is 3, and at least 4 commits landed. |
| `validate-agents.sh` | Validates all 14 agent files: filename matches `name:` frontmatter, `description` non-empty, `tools` list present, `model` is an allowed ID, restricted agents have no Write/Edit. |
| `run-all.sh` | Runs smoke.sh and validate-agents.sh. |
| `README.md` | 36-cell smoke matrix (3 features x 3 tiers x 4 styles). Defines what full coverage looks like. |

---

## Module Dependencies

Dependencies flow top-down. No circular dependencies.

```
commands/           ->  skills/cycle (shim, no logic)
                    ->  skills/{discuss,plan,execute,verify,map-codebase} (phase shims)

skills/cycle        ->  skills/discuss, skills/plan, skills/execute, skills/verify (Skill invocations)
                    ->  skills/map-codebase (Step 5.5)
                    ->  lib/git-ops.sh, lib/feature-write.sh, lib/team-ops.sh, lib/gsd-ingest.sh
                    ->  skills/shared/preset-matrix.md, tier-matrix.md, feature-state-schema.md
                    ->  TeamCreate, TeamDelete, SendMessage, TaskCreate, TaskList (harness tools, Step 2 probe + Step 6 routing)

skills/discuss      ->  TeamCreate, TeamDelete, SendMessage (persistent team: spec-writer-1, advocate-1, challenger-1)
                    ->  lib/feature-write.sh
                    ->  skills/shared/preset-matrix.md

skills/plan         ->  TeamCreate, TeamDelete, SendMessage (persistent team: pattern-mapper-1, planner-1, advocate-1, challenger-1)
                    ->  lib/feature-write.sh, lib/gsd-ingest.sh
                    ->  skills/shared/preset-matrix.md

skills/execute      ->  TeamCreate, TeamDelete, SendMessage, TaskCreate, TaskUpdate, TaskList, TaskGet
                    ->  (implementer-N, reviewer-N teammates; self-claim via TaskUpdate)
                    ->  lib/feature-write.sh, lib/git-ops.sh
                    ->  skills/shared/preset-matrix.md

skills/verify       ->  TeamCreate, TeamDelete, SendMessage (persistent team: verifier-1, code-reviewer-1)
                    ->  skills/map-codebase (Skill invocation, incremental; map team: mapper-*-1 teammates)
                    ->  lib/feature-write.sh
                    ->  skills/shared/preset-matrix.md

skills/map-codebase ->  TeamCreate, TeamDelete, SendMessage, TaskCreate, TaskUpdate (mapper team: one task per stale domain)
                    ->  lib/feature-write.sh (via index.json write)
                    ->  skills/shared/preset-matrix.md

agents/*            ->  skills/shared/artifact-templates/*.template (read at runtime)
                    ->  docs/loop-spec/codebase/*.md (read for context)
                    ->  docs/loop-spec/features/{slug}/*.md (read/write own artifact)

lib/team-ops.sh     ->  (no deps; pure bash helpers)
lib/feature-write.sh ->  jq (JSON validation + key mutation subcommands)

hooks/restrict-agent-paths.sh  ->  (no internal deps; reads CC session transcript via stdin)
hooks/team/task-created.sh     ->  python3 (JSON parsing of tool payload)
hooks/team/task-completed.sh   ->  python3, .loop-spec/features/*/feature.json (reads currentPhase + commands)
hooks/team/teammate-idle.sh    ->  jq or python3, .loop-spec/features/*/feature.json (reads currentPhase)
```

---

## Entrypoints

There are three ways a user enters loop-spec:

1. **`/loop-spec:cycle`** (commands/cycle.md) - Full 4-phase pipeline from any starting state. This is the primary entrypoint. Checks for resumable features first. Collects tier, preset, style, and feature title before dispatching.

2. **`/loop-spec:{discuss,plan,execute,verify}`** (commands/*.md) - Phase-direct entrypoints. Each invokes the corresponding skill without going through cycle. Require `feature.json` to exist and `currentPhase` to match (except discuss, which can start fresh).

3. **`/loop-spec:map-codebase`** (commands/map-codebase.md) - Standalone codebase map refresh. Supports `--full`, `--domain`, `--preset` flags. Operates with or without an active feature.

---

## External Integrations

loop-spec has zero runtime external dependencies by design. The only external surface is the Claude Code harness itself.

| Integration | How accessed | Notes |
|---|---|---|
| Claude Code harness | Implicit (skill invocation, `TeamCreate`/`SendMessage`/`TaskCreate` etc., `AskUserQuestion`) | Harness interprets skills, runs persistent phase teams, serializes concurrent task claims, fires hook events |
| GitHub / git remote | `gh pr create` via Bash in VERIFY Step 5 | Only network call; used to open the PR. Requires `gh` CLI authenticated. |
| GSD (get-shit-done) artifacts | `lib/gsd-ingest.sh` reads `.planning/codebase/` and `.planning/phases/{slug}/` | Optional; if `.planning/` absent, ingest prints NONE and mappers run instead. No network. |
| Git | `git worktree`, `git merge`, `git push`, `git diff` via Bash throughout EXECUTE and VERIFY | Local git operations only |
| `jq` | Used by `lib/feature-write.sh` for JSON validation and key mutation, and by `lib/gsd-ingest.sh` implicitly | Assumed present; `hooks/team/teammate-idle.sh` falls back to python3 if absent |

---

## Data Flow Summary

The central data object is `feature.json`. Every phase reads it on entry, writes it atomically via `lib/feature-write.sh` after each significant transition, and hands off to the next phase by setting `currentPhase`. Live task state during EXECUTE and VERIFY lives in the harness task list, not in `feature.json`.

### Feature lifecycle data flow

```
User input (tier, preset, style, title)
    |
    v
skills/cycle  -->  feature.json initialized  (schemaVersion:3, currentPhase:"discuss")
               -->  lib/team-ops.sh team_name_for_phase -> team name
               -->  TeamCreate (phase team) + lib/feature-write.sh (currentTeamName)
    |
    v
skills/discuss
    |-- AskUserQuestion (conversational loop) -> discuss-transcript.md
    |-- TeamCreate: {spec-writer-1, advocate-1, challenger-1}
    |-- SendMessage -> spec-writer-1          -->  docs/.../SPEC.md
    |-- TeammateIdle (spec-writer-1 done)
    |-- Debate loop (advocate-1 <-> challenger-1 via SendMessage):
    |     SendMessage challenger-1 -> advocate-1 (critique)
    |     SendMessage advocate-1 -> challenger-1 (defense)
    |     Both send ROUND-N DONE[...] to lead
    |     Lead writes gate-logs/spec-critique-round-N.md
    |     Convergence or cap -> synthesize fix_list
    |-- If fix_list non-empty: SendMessage -> spec-writer-1 (revise); repeat debate
    |-- lib/feature-write.sh: gateHistory append, currentGate zeroed
    |-- git commit SPEC.md
    |-- lib/feature-write.sh: currentPhase = "plan", artifacts.spec = path
    |-- TeamDelete
    v
skills/plan
    |-- lib/gsd-ingest.sh patterns     -->  PATTERNS.md (if GSD present, skip pattern-mapper)
    |-- TeamCreate: {pattern-mapper-1, planner-1, advocate-1, challenger-1}
    |-- SendMessage -> pattern-mapper-1   -->  docs/.../PATTERNS.md
    |-- SendMessage -> planner-1          -->  docs/.../PLAN.md (task DAG with metadata)
    |-- Debate loop (advocate-1 <-> challenger-1, plan-critique gate)
    |-- Local feasibility check (lead reads PLAN.md, no agent dispatch)
    |-- git commit PLAN.md
    |-- lib/feature-write.sh: currentPhase = "execute"
    |-- TeamDelete
    v
skills/execute
    |-- Step 2: pre-task file-conflict detection (synthetic blockedBy edges)
    |-- Step 3: lib/validate-task-metadata.sh per task, then TaskCreate
    |           (metadata: blockedBy, files, verifyCommand, acceptanceCriteria, specPath)
    |-- TeamCreate: {implementer-1..N, reviewer-1..N}
    |
    | Implementers self-claim: TaskUpdate(status:"in_progress", owner:"implementer-N",
    |                                     metadata:{claimedBy, phase:null})
    |   (harness serializes concurrent claims; loser must retry)
    |   git worktree add .loop-spec/worktrees/{slug}/task-NNN/
    |   implementer commits to task/NNN-{slug} branch in worktree
    |   Hand off: TaskUpdate(owner:null, metadata:{phase:"awaiting_review"})
    |             (status stays "in_progress"; harness has 3 documented statuses,
    |              implementer/reviewer handoff lives in metadata.phase)
    |
    | Reviewer claims (filter: status=in_progress, metadata.phase="awaiting_review", owner=null):
    |   TaskUpdate(owner:"reviewer-N", metadata:{phase:null})
    |   TaskGet -> reads claimedBy, files, acceptanceCriteria, specPath, retries
    |   Runs spec-compliance check
    |   -> PASS:  TaskUpdate(status:"completed")
    |   -> FAIL (retries left): TaskUpdate(owner:null,
    |                                       metadata:{phase:"needs_rework", retries:R+1})
    |                            SendMessage({to: claimedBy, body:"REWORK NEEDED..."})
    |   -> FAIL (budget exhausted): TaskUpdate(status:"completed",
    |                                            metadata:{result:"blocked"})
    |                                SendMessage({to: lead, body:"TASK BLOCKED..."})
    |   hooks/team/task-completed.sh (PostToolUse:TaskUpdate matcher) runs lint + typecheck
    |   when status flips to "completed"
    |
    | Lead: mergeQueue FIFO (TaskList poll)
    |   Sequential merge: git merge --ff-only task/NNN-{slug}
    |   git worktree remove
    |
    |-- lib/feature-write.sh: currentPhase = "verify"
    |-- TeamDelete
    v
skills/verify
    |-- Scan source files for TBD/FIXME/XXX markers (Bash, fail-fast if found)
    |-- TeamCreate: {verifier-1, code-reviewer-1}
    |-- SendMessage -> verifier-1 + code-reviewer-1 (parallel)
    |     verifier-1    -->  docs/.../VERIFICATION.md (acceptance table)
    |     code-reviewer-1 -->  findings (in-memory, reported to lead via SendMessage)
    |-- TeammateIdle (both done)
    |-- acceptance gate: FAIL -> generate remediation tasks -> loop back to execute
    |-- code-review hard gate: BLOCK -> generate remediation tasks -> loop back to execute
    |-- TeamDelete
    |-- skills/map-codebase (incremental, own TeamCreate inside)
    |   |-- git diff baseSha..HEAD --name-only
    |   |-- index.json lookup -> stale domains
    |   |-- TeamCreate mapper team; SendMessage per stale domain -> mapper-*-1 teammates
    |   |-- mapper-*-1 teammates write docs/loop-spec/codebase/*.md
    |   |-- index.json updated, committed
    |-- git push branch
    |-- gh pr create  -->  PR URL
    |-- git commit VERIFICATION.md
    |-- lib/feature-write.sh: currentPhase = "completed", currentTeamName = null
```

### Codebase map data flow (first run)

```
skills/cycle Step 5.5
    |-- lib/gsd-ingest.sh codebase  -->  docs/loop-spec/codebase/{TECH,ARCH,QUALITY,CONCERNS}.md (if .planning/ exists)
    |-- lib/feature-write.sh: codebaseSource.{domain} = "gsd-ingest" for ingested domains
    |-- git commit ingested docs (if any)
    |-- skills/map-codebase --domain <missing>
    |   |-- TeamCreate mapper team; SendMessage per domain -> mapper-*-1 teammates (parallel)
    |   |-- mapper-*-1 teammates write remaining docs/loop-spec/codebase/*.md
    |   |-- .loop-spec/codebase/index.json created
    |   |-- git commit
    |-- lib/feature-write.sh: codebaseSource.{domain} = "mapper" for mapped domains
```

### Feature state write protocol

All feature state mutations go through `lib/feature-write.sh <feature_dir> <json_string>` (or `set`/`append` subcommands):
1. Validate JSON (`jq -e .`)
2. Write to `feature.json.tmp`
3. `sync`
4. `mv feature.json -> feature.json.bak`
5. `mv feature.json.tmp -> feature.json`

On resume after crash: cycle parses `feature.json`; on parse failure, tries `feature.json.bak`. Cycle then probes team liveness via `TaskList({team: currentTeamName})` before offering resume. Tasks are re-created from `PLAN.md` at EXECUTE entry (not read from `feature.json`, which no longer stores them).

---

## Key Abstractions

**Tier vs Preset.** Tier (`quality`/`balanced`/`quick`) controls gate behavior: which critique gates run and code-review severity thresholds. Preset (`quality`/`balanced`/`fast`) controls model selection via `preset-matrix.md`. They are orthogonal; a user can pick `tier=quick + preset=quality` (quick gates, opus for spec/plan authoring) or `tier=quality + preset=fast` (full gates, haiku for everything except authoring).

**Persistent phase teams.** Every phase runs inside a `TeamCreate` team. Teammates are spawned once and persist for the full phase; rework is routed via `SendMessage` to the existing teammate rather than a new `Agent` call. `Agent` is reserved for the Step 2 capability probe only. Teams are torn down via `TeamDelete` at each phase boundary and between phases.

**Self-claim parallelism in EXECUTE.** Implementers use `TaskUpdate(status:"in_progress", owner:"<name>")` to claim tasks from the shared harness task list. The harness serializes concurrent claims; the losing implementer re-queries and retries. This replaces the old wave-based parallel `Agent` dispatch. Merges are driven by the lead from a FIFO `mergeQueue` in `feature.json`.

**Harness task list as the source of truth for tasks.** `feature.json` no longer stores `tasks[]` or `waves[]`. Live task state (status, owner, metadata) lives exclusively in the harness task list (`TaskCreate`/`TaskUpdate`/`TaskList`/`TaskGet`). On EXECUTE resume the lead recreates the task list from `PLAN.md`; on DISCUSS/PLAN resume there is no task list to restore.

**Retry budget hierarchy.** Gate failures consume budget at three levels simultaneously: per-gate (3 retries max), per-phase (3-4 depending on phase), and global (30 across the feature). EXECUTE uses per-task budget (3) instead of per-phase. The most restrictive limit wins.

**Path enforcement layering.** Three complementary mechanisms: agent `tools:` frontmatter excludes Write/Edit from read-only agents entirely; `hooks/restrict-agent-paths.sh` (PreToolUse Write|Edit) enforces path globs for agents that do have Write/Edit; `hooks/team/task-created.sh` (PreToolUse TaskCreate) ensures all task metadata is structurally valid before a task enters the harness task list.

**Provenance tracking.** `feature.json.artifacts.codebaseSource.{domain}` records whether each codebase doc came from `gsd-ingest`, `mapper`, or `manual`. `feature.json.artifacts.patternsSource` records the same for PATTERNS.md.
