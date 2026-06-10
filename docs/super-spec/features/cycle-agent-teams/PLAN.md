# PLAN.md - cycle-agent-teams

> Produced by `super-spec-planner`. Read by EXECUTE phase implementers.
> Concept analogs come from `PATTERNS.md`. Path:line references in Steps point to existing code to mirror.

## Inputs

- **Slug**: `cycle-agent-teams`
- **Tier**: `quality` (3 critique rounds, 4 parallel implementers, 3 retries per task)
- **Branch**: `feat/cycle-agent-teams` (already created)
- **SPEC**: `docs/super-spec/features/cycle-agent-teams/SPEC.md`
- **PATTERNS**: `docs/super-spec/features/cycle-agent-teams/PATTERNS.md`
- **Codebase mapping**: `docs/super-spec/codebase/{TECH,ARCH,QUALITY,CONCERNS,DOMAIN}.md`

## Assumptions

The following implementation choices are explicit assumptions made here (rather than silently in tasks). Implementers may revisit if blocked.

1. **`.gitignore` resolution.** PATTERNS open question on `.super-spec/codebase/index.json` shadowing: we resolve by adding two specific paths to `.gitignore` instead of a blanket `.super-spec/`: `/.super-spec/features/` and `/.super-spec/worktrees/`. This preserves `.super-spec/codebase/index.json` (currently tracked, per `skills/map-codebase/SKILL.md:84`) without needing a negation rule. The SPEC's success-criterion `git status --ignored` check is satisfied because `.super-spec/features/{slug}/feature.json` is under one of the ignored prefixes.
2. **`lib/gsd-ingest.sh` task scope.** Verified by reading the file: it does **not** currently write `state.json`. The caller (`skills/cycle/SKILL.md`) does the state write. Therefore no task is allocated for "remove state writes from gsd-ingest.sh"; the only change to `lib/gsd-ingest.sh` is potential phrasing alignment in its header comment, deferred to the cycle-skill rewrite task.
3. **`tests/lib/state-write.test.sh` migration.** When `lib/state-write.sh` is deleted, its test must also be removed. We allocate that deletion in the same task as the new `lib/feature-write.sh` test creation, because both touch the `tests/lib/` directory in a single coherent commit.
4. **Hook script `${CLAUDE_PLUGIN_ROOT}` prefix.** Per PATTERNS gotcha, new hook entries in `hooks/hooks.json` use the absolute `${CLAUDE_PLUGIN_ROOT}/hooks/team/...` form even though SPEC's JSON snippet uses the relative form.
5. **Smoke fixture extension.** The smoke fixture (`tests/fixtures/minimal-py/`) needs >=4 tasks with >=2 having empty `blockedBy` and disjoint `files`. We allocate a dedicated fixture-extension task. The fixture extension is required before the smoke-assertion task can be authored against it.
6. **No partial migration of v2 state.** Per SPEC, no `lib/migrate-v2-to-v3.sh` is written. Tasks below do not include any migration helper.
7. **`agents/super-spec-*.md` count.** `validate-agents.sh` currently hard-codes `EXPECTED=14`. The agent set is reused as-is (no new agent files), so `EXPECTED` is unchanged. The frontmatter rule is purely additive.
8. **`probe-cc-capabilities.md` location.** The harness-capability probe lives in `tests/probe-cc-capabilities.md` already. The new agent-teams capability probe SPEC describes is a runtime probe inside `skills/cycle/SKILL.md` Step 2, **not** a new file under `tests/`. We do not allocate a separate task for `tests/probe-cc-capabilities.md` updates beyond what the cycle-skill rewrite touches.
9. **Cycle SKILL.md split.** The cycle-skill rewrite is split into three sequential tasks (013a/013b/013c) that all edit `skills/cycle/SKILL.md` in disjoint sections, sequenced via `blockedBy`. They are nominally in wave 5 but execute serially due to the chain. Same approach for execute SKILL.md (016a/016b). Cross-file blockedBy chains (task-015 -> task-014, task-017 -> task-016b) are placed in distinct waves (wave 6) per the strict planner rule.
10. **Shared team-prompt templates.** Per-role teammate prompt templates (advocate, challenger, implementer, reviewer) are factored out into `skills/shared/team-prompts/*.md` so phase skills can reference them rather than duplicating prompt bodies. Allocated to task-008b.
11. **task-012 scope.** task-012's verifyCommand only runs the negative fixture test. The full `tests/validate-agents.sh` against the live agent set runs in task-021 (after agent frontmatter cleanup) and task-024 (final integration), avoiding a circular dependency.

## Task overview

The plan decomposes into 28 tasks across 9 waves. Tasks within a wave touch disjoint files AND have no `blockedBy` edges among themselves; tasks that share a file or have a `blockedBy` edge are placed in distinct waves. Sequential waves resolve file-overlap dependencies and consumer-of-producer dependencies (e.g., the smoke-assertion task depends on the fixture extension task).

### Wave summary

| Wave | Tasks | Theme | Rationale |
|---|---|---|---|
| 1 | task-001..task-005 | Schema, prereq env, gitignore, plugin version, fixture extension | All disjoint; foundational changes other tasks read |
| 2 | task-006..task-008, task-008b | New libs (`lib/feature-write.sh` + test, `lib/team-ops.sh`); shared docs; team-prompt templates | Disjoint files; consumed by phase skills in later waves |
| 3 | task-009..task-011 | Hook scripts (3 new under `hooks/team/`); `hooks.json` registration | Three scripts disjoint; `hooks.json` edit is its own task |
| 4 | task-012 | `tests/validate-agents.sh` frontmatter rule + negative test fixture | Standalone; consumed by smoke later |
| 5 | task-013a, task-013b, task-013c, task-016a, task-016b, task-014, task-018 | Phase skill rewrites first pass (cycle, discuss, execute, map-codebase) | Disjoint SKILL.md files except cycle (sequential 013a->b->c) and execute (016a->b); task-015 and task-017 deferred to wave 6 because they `blockedBy` tasks in this wave |
| 6 | task-015, task-017 | plan SKILL rewrite (depends on task-014); verify SKILL rewrite (depends on task-016b) | Each `blockedBy` a wave-5 task; promoted to wave 6 to keep dependent tasks out of the same wave |
| 7 | task-019 | Delete `lib/state-write.sh` + its test | Sequenced after all phase-skill rewrites so no live caller remains |
| 8 | task-020, task-021 | Smoke test rewrite; agent frontmatter cleanup | Disjoint; both depend on phase skills + new schema |
| 9 | task-022..task-024 | README, CHANGELOG, plugin version verification + final smoke | Documentation and final integration; sequenced last |

## Tasks

Each task lists: `id`, `subject`, `files`, `verifyCommand`, `acceptanceCriteria`, `blockedBy`, `wave`, and ordered `Steps` (TDD where code-producing).

### task-001: gitignore + .super-spec scaffolding
- **Files**: `.gitignore`
- **Verify**: `bash -c 'grep -q "^/.super-spec/features/$" .gitignore && grep -q "^/.super-spec/worktrees/$" .gitignore'`
- **Acceptance**: `.gitignore` contains `/.super-spec/features/` and `/.super-spec/worktrees/` lines; `git check-ignore .super-spec/features/x/feature.json` reports the path is ignored.
- **BlockedBy**: none
- **Wave**: 1
- **Steps**:
  1. Read existing `.gitignore`.
  2. Append `/.super-spec/features/` and `/.super-spec/worktrees/` (per Assumption 1).
  3. Run `mkdir -p .super-spec/features/dummy && git check-ignore .super-spec/features/dummy/feature.json && rmdir .super-spec/features/dummy`.

### task-002: Bump plugin version to 1.0.0
- **Files**: `.claude-plugin/plugin.json`
- **Verify**: `jq -e '.version == "1.0.0"' .claude-plugin/plugin.json`
- **Acceptance**: `.version` field equals `"1.0.0"`; `description` updated to drop "parallel waves" phrasing if present.
- **BlockedBy**: none
- **Wave**: 1
- **Steps**:
  1. Read `.claude-plugin/plugin.json`.
  2. Edit `version` from `0.3.2` to `1.0.0`.
  3. Update `description` to replace `"parallel waves"` with `"agent teams"` to match the new architecture.

### task-003: Add CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS prereq doc stub
- **Files**: `docs/super-spec/PREREQUISITES.md` (new)
- **Verify**: `grep -q CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS docs/super-spec/PREREQUISITES.md`
- **Acceptance**: New file documents the `export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` requirement, the abort message, and the harness-capability probe's purpose.
- **BlockedBy**: none
- **Wave**: 1
- **Steps**:
  1. Create the file with exact wording from SPEC `## Prerequisites` section.
  2. Include the verbatim health-check FAILED block and the suggested-fix line.
  3. README updates in task-022 will link to this file.

### task-004: Replace feature-state-schema.md with v3 schema
- **Files**: `skills/shared/feature-state-schema.md`
- **Verify**: `bash -c 'grep -q "schemaVersion.*3" skills/shared/feature-state-schema.md && grep -q "feature.json" skills/shared/feature-state-schema.md && ! grep -q "tasks\[\]\|waves\[\]\|executePerTask" skills/shared/feature-state-schema.md'`
- **Acceptance**: File documents `feature.json` v3 schema verbatim from SPEC `### feature.json schema (replaces state.json)`; includes per-phase harness-task-list usage notes; no `tasks[]`, `waves[]`, or `executePerTask` references remain.
- **BlockedBy**: none
- **Wave**: 1
- **Steps**:
  1. Read existing `skills/shared/feature-state-schema.md`.
  2. Rewrite from scratch using SPEC v3 schema as the canonical source.
  3. Add a "Harness task list usage" section that maps each phase to its task-metadata fields (`retries`, `claimedBy`, `blockedBy`, `files`, `verifyCommand`, `acceptanceCriteria`, `specPath`).

### task-005: Extend smoke fixture to >=4 tasks with >=2 disjoint
- **Files**: `tests/fixtures/minimal-py/spec-stub.md`, `tests/fixtures/minimal-py/expected-tasks.md` (new), `tests/fixtures/minimal-py/README.md` (new or updated)
- **Verify**: `bash -c 'test -f tests/fixtures/minimal-py/expected-tasks.md && grep -c "task-" tests/fixtures/minimal-py/expected-tasks.md | awk "{exit (\$1 < 4)}"'`
- **Acceptance**: The fixture's spec-stub describes a feature decomposable into >=4 implementation tasks with at least 2 having empty `blockedBy` and no shared `files` (per SPEC distinct-implementers criterion). Document the expected task layout in `expected-tasks.md` so the smoke-assertion task (task-020) has a known target.
- **BlockedBy**: none
- **Wave**: 1
- **Steps**:
  1. Read `tests/fixtures/minimal-py/spec-stub.md`.
  2. Expand the feature description to imply 4+ tasks. Suggested decomposition: `add()`, `subtract()`, `multiply()`, `divide()` plus their tests, with at least 2 functions having no shared files.
  3. Create `expected-tasks.md` listing the 4 tasks with task ids, `files` lists, and `blockedBy` to make the distinct-implementers expectation explicit. Use `task-NNN:` style headings so the verifyCommand grep can count >=4 occurrences.

### task-006: Implement lib/feature-write.sh + test
- **Files**: `lib/feature-write.sh`, `tests/lib/feature-write.test.sh`
- **Verify**: `bash tests/lib/feature-write.test.sh`
- **Acceptance**: Script writes atomically with `.tmp`/`.bak` rotation per `lib/state-write.sh:1-53` analog (PATTERNS Concept 1). Test covers: missing dir, invalid JSON, valid write, .bak rotation, two-write sequence.
- **BlockedBy**: none
- **Wave**: 2
- **Steps**:
  1. **Write failing test first.** Create `tests/lib/feature-write.test.sh` mirroring `tests/lib/state-write.test.sh` (PATTERNS Concept 1 test analog). Use the same `check()` helper pattern.
  2. Run `bash tests/lib/feature-write.test.sh` and confirm it fails with "lib/feature-write.sh not found".
  3. Implement `lib/feature-write.sh` cloning `lib/state-write.sh:1-53` verbatim, changing only the file names: `state.json` -> `feature.json`, `state.json.tmp` -> `feature.json.tmp`, `state.json.bak` -> `feature.json.bak`. Keep `sync` (do not change to `fsync` per CONCERNS note).
  4. Run `bash tests/lib/feature-write.test.sh` and confirm it passes.
  5. `chmod +x lib/feature-write.sh`.

### task-007: Implement lib/team-ops.sh helpers
- **Files**: `lib/team-ops.sh`, `tests/lib/team-ops.test.sh`
- **Verify**: `bash tests/lib/team-ops.test.sh`
- **Acceptance**: Provides shell helpers callable from skill bodies for non-MCP team operations: `team_name_for_phase <phase> <slug>`, `assert_team_env`, `feature_json_path <slug>`. Does NOT call `TeamCreate`/`TeamDelete` (those are MCP tools, only callable from skill bodies). Test covers each helper.
- **BlockedBy**: none
- **Wave**: 2
- **Steps**:
  1. **Write failing test first.** `tests/lib/team-ops.test.sh` asserts: `team_name_for_phase discuss foo` -> `super-spec-discuss-foo`; `assert_team_env` exits 0 when `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, exits 2 with the documented message otherwise; `feature_json_path foo` -> `.super-spec/features/foo/feature.json`.
  2. Run test, confirm fail.
  3. Implement `lib/team-ops.sh` with the three functions. Reuse the exit-code/message contract from `lib/state-write.sh` (PATTERNS Concept 1).
  4. Run test, confirm pass.
  5. `chmod +x lib/team-ops.sh`.

### task-008: Update tier-matrix.md and preset-matrix.md with team params
- **Files**: `skills/shared/tier-matrix.md`, `skills/shared/preset-matrix.md`
- **Verify**: `bash -c 'grep -q "maxParallelImplementers" skills/shared/tier-matrix.md && grep -q "maxRetriesPerTask" skills/shared/tier-matrix.md'`
- **Acceptance**: `tier-matrix.md` adds the four new columns from SPEC `### Tier-driven team parameters` table (`discuss.maxCritiqueRounds`, `plan.maxCritiqueRounds`, `execute.maxParallelImplementers`, `execute.maxRetriesPerTask`). `preset-matrix.md` adds a note that team params come from the tier, not the preset.
- **BlockedBy**: none
- **Wave**: 2
- **Steps**:
  1. Read both files.
  2. Edit `tier-matrix.md` to add the 4 columns with values from SPEC's table (`quality: 3/3/4/3`, `balanced: 2/2/3/2`, `quick: 1/1/2/1`).
  3. Add a one-paragraph note in `preset-matrix.md` clarifying that the new team params are tier-driven.

### task-008b: Create skills/shared/team-prompts/ templates for advocate, challenger, implementer, reviewer
- **Files**: `skills/shared/team-prompts/advocate.md`, `skills/shared/team-prompts/challenger.md`, `skills/shared/team-prompts/implementer.md`, `skills/shared/team-prompts/reviewer.md`
- **Verify**: `test -f skills/shared/team-prompts/advocate.md && test -f skills/shared/team-prompts/implementer.md`
- **Acceptance**: 4 template files exist with `ROUND-N DONE` protocol for advocate/challenger and self-claim loop for implementer/reviewer.
- **BlockedBy**: task-004
- **Wave**: 2
- **Steps**:
  1. Create `skills/shared/team-prompts/advocate.md` documenting the round-end signal `ROUND-{N} DONE:` / `ROUND-{N} DONE-WITH-ISSUES:` and the `SendMessage({to: "challenger-1", body: ...})` contract from SPEC `## Critique debate protocol`.
  2. Create `skills/shared/team-prompts/challenger.md` mirroring advocate but addressed to `advocate-1`.
  3. Create `skills/shared/team-prompts/implementer.md` documenting the self-claim loop: `TaskList` -> pick first unblocked `pending` -> `TaskUpdate({status: "in_progress", owner: "<own-name>"})` -> on lost race, retry. Include the `worktree_path` / `worktree_branch` SendMessage contract from SPEC `#### EXECUTE team`.
  4. Create `skills/shared/team-prompts/reviewer.md` documenting the self-claim of `awaiting_review` tasks and the `completed` / `needs_rework` decision contract.
  5. Each template uses placeholder `{slug}`, `{tier}`, `{N}` tokens that phase skills substitute at dispatch time.

### task-009: New hook script hooks/team/teammate-idle.sh + test
- **Files**: `hooks/team/teammate-idle.sh`, `hooks/team/teammate-idle.test.sh`
- **Verify**: `bash hooks/team/teammate-idle.test.sh`
- **Acceptance**: Script reads `feature.json` and emits a phase-aware nudge. Per PATTERNS Concept 4: exit 0 always (advisory). Handles missing/corrupt `feature.json` gracefully (exit 0, never block). Test covers: present/missing `feature.json`, each phase, corrupt JSON.
- **BlockedBy**: task-004
- **Wave**: 3
- **Steps**:
  1. **Write failing test first.** Mirror `hooks/restrict-agent-paths.test.sh` (PATTERNS Concept 4 test analog) with the `check()` helper.
  2. Run test, confirm fail.
  3. Implement script per PATTERNS Concept 4. Use `${CLAUDE_PLUGIN_ROOT}`-relative paths inside the script (Assumption 4). On missing `feature.json`, log to stderr and exit 0 (advisory). Read schema field names from `skills/shared/feature-state-schema.md`.
  4. Run test, confirm pass.

### task-010: New hook scripts hooks/team/task-created.sh and task-completed.sh + tests
- **Files**: `hooks/team/task-created.sh`, `hooks/team/task-created.test.sh`, `hooks/team/task-completed.sh`, `hooks/team/task-completed.test.sh`
- **Verify**: `bash hooks/team/task-created.test.sh && bash hooks/team/task-completed.test.sh`
- **Acceptance**: `task-created.sh` validates task metadata shape (required fields: `blockedBy`, `files`, `verifyCommand`, `acceptanceCriteria`, `specPath`); exits 2 on bad shape (PATTERNS Concept 4 contract). `task-completed.sh` is phase-aware: in EXECUTE runs `lint`/`typecheck` from `feature.json.commands` against the merged worktree, exits 2 on failure to trigger `needs_rework`; in DISCUSS/PLAN runs schema validation. Both handle missing `feature.json` gracefully.
- **BlockedBy**: task-004
- **Wave**: 3
- **Steps**:
  1. **Write failing tests first** for both scripts using the `check()` pattern from `hooks/restrict-agent-paths.test.sh:1-end`.
  2. Run, confirm fail.
  3. Implement `task-created.sh`: parse stdin JSON via `jq`, assert presence of required metadata fields per `skills/shared/feature-state-schema.md`, exit 0/2.
  4. Implement `task-completed.sh`: read `feature.json.currentPhase`, dispatch to phase-specific validator. EXECUTE branch reads `feature.json.commands.{lint,typecheck}` and runs them.
  5. Run tests, confirm pass.

### task-011: Register new hooks in hooks/hooks.json
- **Files**: `hooks/hooks.json`
- **Verify**: `jq -e '.hooks.TeammateIdle and .hooks.TaskCreated and .hooks.TaskCompleted' hooks/hooks.json`
- **Acceptance**: `hooks/hooks.json` adds three new top-level keys under `.hooks`: `TeammateIdle`, `TaskCreated`, `TaskCompleted`. Each entry uses the `${CLAUDE_PLUGIN_ROOT}/hooks/team/...` absolute path (Assumption 4).
- **BlockedBy**: task-009, task-010
- **Wave**: 3
- **Steps**:
  1. Read `hooks/hooks.json`.
  2. Add the three entries per PATTERNS Concept 4 "New entries to add" snippet, using absolute `${CLAUDE_PLUGIN_ROOT}` prefix.
  3. Validate with `jq -e .` to confirm parse.

### task-012: Add frontmatter rule to validate-agents.sh + negative test
- **Files**: `tests/validate-agents.sh`, `tests/validate-agents.test.sh` (new), `tests/fixtures/agent-with-skills-key.md` (new)
- **Verify**: `bash tests/validate-agents.test.sh`
- **Acceptance**: Script gains the structural rule from PATTERNS Concept 5 "New check to add". A new test (`validate-agents.test.sh`) confirms: when run against a temp dir containing a bad fixture (`agent-with-skills-key.md`), the script exits non-zero with the documented message. The full `validate-agents.sh` against the live agent set is verified later (task-021 + task-024) to avoid a circular dependency between adding the rule and cleaning up agents to satisfy it.
- **BlockedBy**: none
- **Wave**: 4
- **Steps**:
  1. **Write failing test first.** `tests/validate-agents.test.sh` copies `agents/` to `$TMPDIR/agents-test/`, injects the `agent-with-skills-key.md` fixture, runs the validator with `cd $TMPDIR/agents-test`, asserts exit code != 0 and the documented error message appears in stderr.
  2. Run, confirm fail.
  3. Add the new check from PATTERNS Concept 5 inside the for-loop in `tests/validate-agents.sh`.
  4. Run `bash tests/validate-agents.test.sh` (negative test) and confirm pass.
  5. NOTE: Do NOT run `bash tests/validate-agents.sh` here against the live agent set; that runs in task-021 (after agent cleanup) and task-024 (final smoke).

### task-013a: Rewrite cycle/SKILL.md - tool whitelist + model probes + harness capability probe
- **Files**: `skills/cycle/SKILL.md`
- **Verify**: `bash -c 'grep -q "TeamCreate" skills/cycle/SKILL.md && grep -q "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS" skills/cycle/SKILL.md && ! grep -E "^- .SendMessage|^- .EnterWorktree|^- .CronCreate" skills/cycle/SKILL.md'`
- **Acceptance**: Tool whitelist inverted (allow `TeamCreate, TeamDelete, TaskCreate, TaskUpdate, TaskList, TaskGet, Read, Write, Edit, Bash, AskUserQuestion, Skill` as comma-separated inline list; document `Agent` as restricted to Step 2 model probes only). `SendMessage`, `EnterWorktree`, `CronCreate` MUST NOT appear as bullet entries (lines starting with `- \`Tool\``) anywhere in cycle SKILL.md - the cycle lead does not directly send teammate-to-teammate messages or enter worktrees; those are teammate-only contracts referenced in prose only. Step 2 includes the env-var prereq abort and the harness-capability probe per SPEC `## User-facing behavior` item 1 (creates `super-spec-probe-{pid}`, exercises `TaskUpdate`+`metadata`+`SendMessage`+concurrent self-claim+`TeamDelete`).
- **BlockedBy**: task-004, task-006, task-007, task-008, task-011
- **Wave**: 5
- **Steps**:
  1. Read current `skills/cycle/SKILL.md`.
  2. Apply the tool-whitelist inversion from PATTERNS Concept 3 gotcha. Allowed tools: `TeamCreate, TeamDelete, SendMessage, TaskCreate, TaskUpdate, TaskList, TaskGet, Read, Write, Edit, Bash, AskUserQuestion, Skill`. Document `Agent` as restricted to Step 2 model probes only.
  3. Step 2: clone the existing 1-token model probe pattern (analog at the pre-rewrite cycle SKILL `## Step 2` block) and add the env-var prereq check from PATTERNS Concept 7. On missing env var, abort with the verbatim FAILED block from SPEC `## Prerequisites`.
  4. Step 2 (continued): add the harness-capability probe described in SPEC `## User-facing behavior` item 1: create `super-spec-probe-{pid}`, exercise `TaskUpdate`+`metadata`+`SendMessage`+concurrent self-claim+`TeamDelete`. On any failure, emit the documented PROBE FAILED block and abort.

### task-013b: Rewrite cycle/SKILL.md - Step 5/6: feature.json init + TeamCreate routing
- **Files**: `skills/cycle/SKILL.md`
- **Verify**: `bash -c 'grep -q "feature.json" skills/cycle/SKILL.md && ! grep -q "state.json" skills/cycle/SKILL.md'`
- **Acceptance**: Step 5 init writes `feature.json` (not `state.json`) via `lib/feature-write.sh`; drops `tasks[]`, `waves[]`, `executePerTask`. Step 6 routing wraps each phase Skill call in `TeamCreate` (before) / `TeamDelete` (after); writes `currentTeamName` per phase.
- **BlockedBy**: task-013a
- **Wave**: 5
- **Steps**:
  1. Read updated `skills/cycle/SKILL.md` (post 013a).
  2. Step 5 init: replace the `jq -n` block (analog at the pre-rewrite cycle SKILL `## Step 5` block) with a v3-shaped block per `skills/shared/feature-state-schema.md`. Drop `tasks[]`, `waves[]`, `executePerTask`. Write via `lib/feature-write.sh` (PATTERNS Concept 1).
  3. Step 6 routing: add `TeamCreate({name: super-spec-{phase}-{slug}, teammates: [...]})` before each phase Skill call. Mirror `currentTeamName` write pattern. After phase completes, `TeamDelete` and clear `currentTeamName`.
  4. Reuse `lib/team-ops.sh` helpers (`assert_team_env`, `team_name_for_phase`, `feature_json_path`) where applicable.

### task-013c: Rewrite cycle/SKILL.md - resume strategy + escalation + cleanup
- **Files**: `skills/cycle/SKILL.md`
- **Verify**: `bash -c 'grep -q "TaskList" skills/cycle/SKILL.md && grep -q -i "resume" skills/cycle/SKILL.md && ! grep -q "state.json" skills/cycle/SKILL.md'`
- **Acceptance**: Resume section follows SPEC `## Resume strategy` algorithm (live-team probe via `TaskList` -> alive=orphan, error=safe). Escalation reads counters from `feature.json` via `lib/feature-write.sh` (PATTERNS Concept 7). Final cleanup section documents per-phase `TeamDelete` invariant.
- **BlockedBy**: task-013b
- **Wave**: 5
- **Steps**:
  1. Read updated `skills/cycle/SKILL.md` (post 013b).
  2. Resume section: rewrite per SPEC `## Resume strategy` algorithm. Probe via `TaskList({teamName: feature.json.currentTeamName})`: alive -> orphan path; error -> safe-reentry path.
  3. Escalation: keep the pattern from PATTERNS Concept 7, but now read counters from `feature.json` via `lib/feature-write.sh`.
  4. Cleanup section: document the per-phase `TeamDelete` invariant and the wedge-recovery instructions.

### task-014: Rewrite skills/discuss/SKILL.md (team-based with debate protocol)
- **Files**: `skills/discuss/SKILL.md`
- **Verify**: `bash -c 'grep -q "TeamCreate" skills/discuss/SKILL.md && grep -q "SendMessage" skills/discuss/SKILL.md && grep -q "ROUND-" skills/discuss/SKILL.md'`
- **Acceptance**: Skill follows SPEC `#### DISCUSS team` structure. Spawns spec-writer, advocate, challenger as teammates via `TeamCreate`. Implements `## Critique debate protocol` with `ROUND-{N} DONE:` / `ROUND-{N} DONE-WITH-ISSUES:` signals and `gate-logs/` transcript capture. Reads tier from `feature.json`. Frontmatter still has only `name` and `description` keys (no `skills:`/`mcpServers:` per PATTERNS Concept 2 gotcha). Imports prompt bodies from `skills/shared/team-prompts/`.
- **BlockedBy**: task-004, task-006, task-008, task-008b, task-013c
- **Wave**: 5
- **Steps**:
  1. Read `skills/discuss/SKILL.md` for current structure (PATTERNS Concept 2 analog at `skills/discuss/SKILL.md:1-127`).
  2. Preserve frontmatter `name: discuss` and `description: ...`. Update Inputs section to reference `feature.json` instead of `state.json`.
  3. Step 1: dispatch via `TeamCreate({name: super-spec-discuss-{slug}, teammates: [{name: spec-writer-1, agent: super-spec-spec-writer, model, prompt}]})` per PATTERNS Concept 3 gotcha mapping.
  4. Critique-gate steps: spawn `advocate-1` and `challenger-1` using the prompt templates at `skills/shared/team-prompts/advocate.md` and `challenger.md`. Instruct each to address the other via `SendMessage({to: "challenger-1", body: ...})` per SPEC `## Critique debate protocol`.
  5. Round handling: append each round-end message to `.super-spec/features/{slug}/gate-logs/discuss-round-{N}.md`. Persist round counter via `lib/feature-write.sh` to `feature.json.currentGate`.
  6. Convergence detection: implement the three rules (mutual-done, cap-reached, one-sided) from SPEC.
  7. Resume section: rewrite per PATTERNS Concept 2 gotcha (call `TaskList` to probe team liveness; read `gate-logs/` to reconstruct debate).
  8. Final step: `TeamDelete` and clear `feature.json.currentTeamName`.

### task-015: Rewrite skills/plan/SKILL.md (team-based with debate)
- **Files**: `skills/plan/SKILL.md`
- **Verify**: `bash -c 'grep -q "TeamCreate" skills/plan/SKILL.md && grep -q "SendMessage" skills/plan/SKILL.md && grep -q "pattern-mapper" skills/plan/SKILL.md'`
- **Acceptance**: Skill follows SPEC `#### PLAN team` structure. Order: pattern-mapper -> planner -> advocate/challenger debate. Same `ROUND-` protocol as DISCUSS. Frontmatter unchanged (no `skills:`/`mcpServers:`). Imports prompt bodies from `skills/shared/team-prompts/`.
- **BlockedBy**: task-004, task-006, task-008, task-008b, task-013c, task-014 (mirrors DISCUSS structure)
- **Wave**: 6
- **Steps**:
  1. Read `skills/plan/SKILL.md` for current structure.
  2. Frontmatter and Inputs same migration as task-014 step 2.
  3. Step 1: spawn `pattern-mapper-1` via `TeamCreate` (only teammate at first), wait for completion, then add `planner-1` via a second `TeamCreate` call OR include both in initial teammates list and serialize via `SendMessage` ordering.
  4. Critique gate: identical pattern to DISCUSS task-014 steps 4-6, swap `discuss` for `plan` in gate-log filenames and `feature.json` keys. Reuse advocate/challenger templates from `skills/shared/team-prompts/`.
  5. Resume + cleanup same shape as task-014.

### task-016a: Rewrite execute/SKILL.md - file-conflict detection + TaskCreate + TeamCreate sizing + self-claim docs + worktree creation
- **Files**: `skills/execute/SKILL.md`
- **Verify**: `bash -c 'grep -q "TaskCreate" skills/execute/SKILL.md && grep -q "self-claim\|claimedBy" skills/execute/SKILL.md && ! grep -q "mergeQueue\|TEAM-EXECUTE\|awaiting_review" skills/execute/SKILL.md'`
- **Acceptance**: Removes wave dispatch entirely. Implements pre-task file-conflict detection (with default-empty exclusion list), `TaskCreate` per planned task with metadata, `TeamCreate` sizing (`M = min(plannedTaskCount, tier.execute.maxParallelImplementers)`, `R = ceil(M/2)`), self-claim loop docs (`TaskUpdate({status: "in_progress", owner: ...})`), and worktree creation pattern (PATTERNS Concept 6) preserved verbatim. Boundary: this task MUST NOT introduce reviewer-flow content - `mergeQueue`, `TEAM-EXECUTE` log lines, and `awaiting_review` status keyword belong to task-016b and MUST NOT appear in execute SKILL.md after task-016a completes.
- **BlockedBy**: task-004, task-005, task-006, task-007, task-008, task-008b, task-013c
- **Wave**: 5
- **Steps**:
  1. Read `skills/execute/SKILL.md` for current structure (PATTERNS Concept 6 analog at `skills/execute/SKILL.md:57-165`).
  2. Frontmatter and Inputs migration. Drop all `waves[]` references.
  3. Step 0 (entry): per-entry pre-task file-conflict detection per SPEC `#### EXECUTE team` "Pre-task file-conflict detection". Read exclusion list from `feature.json.fileConflictExcludeGlobs[]` and `.super-spec/file-conflict-exclude.txt` (union). Default empty.
  4. Step 1: `TaskCreate` per `PLAN.md` task, populating `metadata` with `blockedBy`, `files`, `verifyCommand`, `acceptanceCriteria`, `specPath`.
  5. Step 2: `TeamCreate` with `M = min(plannedTaskCount, tier.execute.maxParallelImplementers)` implementers and `R = ceil(M/2)` reviewers. Implementer/reviewer prompts come from `skills/shared/team-prompts/implementer.md` and `reviewer.md`.
  6. Self-claim loop docs: implementer queries `TaskList`, picks first unblocked `pending`, calls `TaskUpdate({status: "in_progress", owner: "<own-name>"})`. Lost-race retry behavior is the implementer's responsibility per SPEC.
  7. Worktree creation: keep the `git worktree add -b ...` pattern verbatim from PATTERNS Concept 6. Lead creates worktree on successful claim and `SendMessage`s `worktree_path` and `worktree_branch` to the claiming implementer.

### task-016b: Rewrite execute/SKILL.md - reviewer flow + idle/wake protocol + merge queue + cleanup + retries + log emission
- **Files**: `skills/execute/SKILL.md`
- **Verify**: `bash -c 'grep -q "mergeQueue" skills/execute/SKILL.md && grep -q "TEAM-EXECUTE" skills/execute/SKILL.md && grep -q "awaiting_review" skills/execute/SKILL.md'`
- **Acceptance**: Reviewer self-claims `awaiting_review`; idle/wake protocol via `SendMessage`; merge queue (FIFO dependency-aware) per SPEC; final per-task worktree cleanup; per-task retries capped by `tier.execute.maxRetriesPerTask`; lead emits `[TEAM-EXECUTE] task-NNN claimed by implementer-M` log lines (consumed by smoke task-020).
- **BlockedBy**: task-016a
- **Wave**: 5
- **Steps**:
  1. Read updated `skills/execute/SKILL.md` (post 016a).
  2. Reviewer flow: reviewer self-claims `awaiting_review`, sets `completed` (notify lead) or `needs_rework` (SendMessage implementer named in `claimedBy`).
  3. Idle/wake protocol per SPEC: implementer sends `implementer-N idle: no available tasks` message to lead; lead wakes via `SendMessage` on `TaskCompleted` events that unblock dependents.
  4. Lead emits `[TEAM-EXECUTE] task-NNN claimed by implementer-M` to stdout on every claim transition (smoke assertion in task-020).
  5. Merge queue: lead processes `feature.json.mergeQueue[]` FIFO with rotate-to-back on unmerged blockers per SPEC. Use raw git commands per PATTERNS Concept 6.
  6. Final cleanup: per-task worktree `git worktree remove` + `git branch -D`. `TaskList` empty check; `mergeQueue` empty check; `TeamDelete`.
  7. Per-task retries: live in harness `metadata.retries`, capped by `tier.execute.maxRetriesPerTask`. Per-phase/global counters in `feature.json` via `lib/feature-write.sh` (PATTERNS Concept 7).

### task-017: Rewrite skills/verify/SKILL.md (team-based)
- **Files**: `skills/verify/SKILL.md`
- **Verify**: `bash -c 'grep -q "TeamCreate" skills/verify/SKILL.md && grep -q "code-reviewer" skills/verify/SKILL.md && grep -q "VERIFICATION.md" skills/verify/SKILL.md'`
- **Acceptance**: Skill follows SPEC `#### VERIFY team` structure. Spawns verifier + code-reviewer in parallel, plus optional mappers (only stale domains). Code-reviewer is hard gate: on FAIL, route back to EXECUTE with fix-list. Frontmatter unchanged.
- **BlockedBy**: task-004, task-006, task-013c, task-016b
- **Wave**: 6
- **Steps**:
  1. Read `skills/verify/SKILL.md` for current structure (PATTERNS analog at `skills/verify/SKILL.md:41-55` for parallel dispatch).
  2. Frontmatter and Inputs migration.
  3. Step 1: `TeamCreate({name: super-spec-verify-{slug}, teammates: [{name: verifier-1, ...}, {name: code-reviewer-1, ...}, ...mappers if stale]})`.
  4. Wait for both `verifier-1` and `code-reviewer-1` to complete via `TaskList`/`TaskGet` polling or `TeammateIdle` notifications.
  5. On code-reviewer FAIL: `TeamDelete` then route back to EXECUTE phase (the cycle skill handles re-entry with the fix-list pre-loaded).
  6. On both pass: write cycle-completion summary, set `feature.json.currentPhase = "completed"`, `TeamDelete`.

### task-018: Rewrite skills/map-codebase/SKILL.md (team-based mappers)
- **Files**: `skills/map-codebase/SKILL.md`
- **Verify**: `bash -c 'grep -q "TeamCreate" skills/map-codebase/SKILL.md && grep -q "mapper-tech" skills/map-codebase/SKILL.md'`
- **Acceptance**: Skill follows SPEC `#### MAP-CODEBASE team` structure. Spawns 5 mapper teammates in parallel that may share findings via `SendMessage`. Frontmatter unchanged.
- **BlockedBy**: task-004, task-006, task-013c
- **Wave**: 5
- **Steps**:
  1. Read `skills/map-codebase/SKILL.md` for current structure.
  2. Frontmatter and Inputs migration.
  3. `TeamCreate({name: super-spec-map-codebase-{project-id}, teammates: [{mapper-tech, mapper-arch, mapper-quality, mapper-concerns, mapper-domain}]})`.
  4. Document the cross-mapper `SendMessage` pattern (e.g., mapper-arch shares module boundaries with mapper-domain).
  5. Exit: validate all 5 docs present, `TeamDelete`, single commit.

### task-019: Delete lib/state-write.sh and its test
- **Files**: `lib/state-write.sh` (deleted), `tests/lib/state-write.test.sh` (deleted)
- **Verify**: `bash -c '! test -f lib/state-write.sh && ! test -f tests/lib/state-write.test.sh && ! grep -rn "state-write.sh" skills/ lib/ hooks/ tests/'`
- **Acceptance**: Both files removed. No live references in `skills/`, `lib/`, `hooks/`, `tests/`. (Historical references in CHANGELOG and docs are allowed per SPEC success criteria.)
- **BlockedBy**: task-013c, task-014, task-015, task-016b, task-017, task-018 (all callers migrated)
- **Wave**: 7
- **Steps**:
  1. Confirm no callers remain by `grep -rn 'state-write\.sh\|state\.json' skills/ lib/ hooks/`.
  2. `git rm lib/state-write.sh tests/lib/state-write.test.sh`.
  3. Run verify command to confirm clean.

### task-020: Rewrite tests/smoke.sh assertions for v3 + distinct-implementers
- **Files**: `tests/smoke.sh`
- **Verify**: `bash tests/smoke.sh`
- **Acceptance**: All assertions from PATTERNS Concept 8 "New assertions to add" snippet are present: `feature.json` existence; schema v3; `currentPhase == completed`; `currentTeamName == null`; `currentTeammates == []`; `currentGate.round == 0`; no `state.json`; at least 2 distinct `implementer-N` suffixes appear across all `[TEAM-EXECUTE]` claim log lines in the run; gate-history convergence assertions per SPEC.
- **BlockedBy**: task-013c, task-014, task-015, task-016b, task-017, task-018, task-005, task-019
- **Wave**: 8
- **Steps**:
  1. **Update assertions first.** Read `tests/smoke.sh:33-90` (PATTERNS Concept 8 analog).
  2. Replace `STATE` variable with `FSTATE=".super-spec/features/$SLUG/feature.json"`. Add the new `assert_file "$FSTATE"`.
  3. Add jq assertions per PATTERNS snippet.
  4. Add the negative assertion: `state.json` MUST NOT exist.
  5. Add the distinct-implementers assertion: capture all `[TEAM-EXECUTE] task-NNN claimed by implementer-M` lines from the run log, extract the `implementer-N` suffix from each, count unique values, assert `>= 2`. Example: `grep -oE 'implementer-[0-9]+' "$RUN_LOG" | sort -u | wc -l` must be `>= 2`.
  6. Add gate-history convergence assertion: each gate entry has `convergence in {mutual-done, cap-reached, one-sided}` and `rounds <= tier max`.
  7. Run `bash tests/smoke.sh` and iterate until pass.

### task-021: Audit + clean agent frontmatter (remove any skills:/mcpServers: keys)
- **Files**: `agents/super-spec-*.md` (any files containing the banned keys)
- **Verify**: `bash -c '! grep -E "^(skills|mcpServers):" agents/super-spec-*.md && bash tests/validate-agents.sh'`
- **Acceptance**: No agent file has `skills:` or `mcpServers:` in frontmatter (per SPEC breaking-change row "Skills frontmatter on teammates is inert"). `bash tests/validate-agents.sh` passes against the live agent set (rule from task-012 now satisfied). If any phase-skill rewrite (013-018) removes a `Skill()` invocation from an agent prompt body, document the inline invocation in the agent prompt instead.
- **BlockedBy**: task-012, task-013c, task-014, task-015, task-016b, task-017, task-018
- **Wave**: 8
- **Steps**:
  1. `grep -lE '^(skills|mcpServers):' agents/super-spec-*.md` to identify offenders.
  2. For each offender, read the file, remove the offending key + value lines from the YAML frontmatter.
  3. If a removed `skills:` was load-bearing for the agent's behavior, document an inline `Skill(super-spec:{name})` invocation in the agent's prompt body per SPEC breaking-change note. If any phase-skill rewrite (013-018) removed a Skill() invocation from an agent prompt body, document the inline invocation in the agent prompt instead.
  4. Run `bash tests/validate-agents.sh` and confirm pass on the live agent set.

### task-022: Update README.md with prereq, architecture, limitations
- **Files**: `README.md`
- **Verify**: `bash -c 'grep -q CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS README.md && grep -q "Limitations" README.md && grep -q "agent teams" README.md'`
- **Acceptance**: README Quick Start mentions `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`. Architecture section replaces "wave dispatch" paragraph with "agent teams" paragraph (one paragraph per phase plus EXECUTE self-claim model). New "Limitations" section lists the 5 harness limitations from SPEC `## Constraints`. Skills list updated if any names changed (none should change).
- **BlockedBy**: task-013c, task-014, task-015, task-016b, task-017, task-018, task-002
- **Wave**: 9
- **Steps**:
  1. Read `README.md` in full.
  2. Update Quick Start prereqs list to include the env var.
  3. Replace wave-dispatch paragraph with agent-teams paragraph per SPEC `## Version and CHANGELOG guidance` README updates section.
  4. Add a `## Limitations` section with the 5 bullet items from SPEC Constraints + Non-goals (in-process resume, nested teams, cross-feature concurrency, EnterWorktree banned, skills frontmatter inert on teammates).

### task-023: Add CHANGELOG v1.0.0 entry
- **Files**: `CHANGELOG.md`
- **Verify**: `bash -c 'grep -q "## \[1.0.0\]" CHANGELOG.md && grep -q "### Added" CHANGELOG.md && grep -q "### Changed" CHANGELOG.md && grep -q "### Removed" CHANGELOG.md && grep -q "### Migration" CHANGELOG.md'`
- **Acceptance**: New entry under `## [1.0.0] - 2026-05-XX` with all four required sub-sections per SPEC `## Version and CHANGELOG guidance`.
- **BlockedBy**: task-002, task-013c, task-014, task-015, task-016b, task-017, task-018, task-019
- **Wave**: 9
- **Steps**:
  1. Read `CHANGELOG.md`.
  2. Insert the v1.0.0 entry above the v0.3.2 entry.
  3. Populate Added / Changed / Removed / Migration sections verbatim from SPEC.

### task-024: Final smoke + integration verify
- **Files**: (none modified — verification-only task that runs all gates)
- **Verify**: `bash -c 'bash tests/smoke.sh && bash tests/validate-agents.sh && bash tests/validate-agents.test.sh && jq -e ".version == \"1.0.0\"" .claude-plugin/plugin.json && ! grep -rn "state.json\|state-write.sh" skills/ lib/ hooks/ tests/ | grep -v "CHANGELOG\|# \|\.bak\|feature-state-schema\|PREREQUISITES"'`
- **Acceptance**: All success criteria from SPEC `## Success criteria` pass. Final cycle integration is verified end-to-end on the smoke fixture. The grep negative-assertion EXCLUDES historical and documentation references (CHANGELOG entries describing the v1.0.0 removal, comment lines starting with `# `, `.bak` rotation files, the `feature-state-schema.md` "replaces state.json" prose note, and PREREQUISITES.md migration notes). Only live executable references in skills/lib/hooks/tests would fail this check.
- **BlockedBy**: task-001, task-002, task-003, task-004, task-005, task-006, task-007, task-008, task-008b, task-009, task-010, task-011, task-012, task-013a, task-013b, task-013c, task-014, task-015, task-016a, task-016b, task-017, task-018, task-019, task-020, task-021, task-022, task-023
- **Wave**: 9
- **Steps**:
  1. Run `bash tests/smoke.sh`. If failure, return to the failing task, do not patch in this task.
  2. Run `bash tests/validate-agents.sh` and `bash tests/validate-agents.test.sh`.
  3. Verify plugin version with `jq`.
  4. Run grep negative-assertion: `grep -rn "state.json\|state-write.sh" skills/ lib/ hooks/ tests/ | grep -v "CHANGELOG\|# \|\.bak\|feature-state-schema\|PREREQUISITES"` should be empty (historical and documentation references whitelisted).
  5. Verify capability probe in cycle SKILL.md: `grep -q "PROBE.*PASSED\|PROBE.*FAILED" skills/cycle/SKILL.md`.
  6. Confirm no `feature.json` is committed under `docs/super-spec/features/cycle-agent-teams/`: `! test -f docs/super-spec/features/cycle-agent-teams/feature.json`.

## Dependency graph (DAG summary)

```
Wave 1: task-001  task-002  task-003  task-004  task-005
Wave 2: task-006  task-007  task-008  task-008b (depends on 004)
Wave 3: task-009 (depends on 004) -> task-011
        task-010 (depends on 004) -> task-011
Wave 4: task-012
Wave 5: task-013a (depends on 004,006,007,008,011)
        task-013b (depends on 013a)        # same file as 013a, sequential
        task-013c (depends on 013b)        # same file as 013b, sequential
        task-014  (depends on 004,006,008,008b,013c)
        task-016a (depends on 004,005,006,007,008,008b,013c)
        task-016b (depends on 016a)        # same file as 016a, sequential
        task-018  (depends on 004,006,013c)
Wave 6: task-015  (depends on 014; promoted out of wave 5 because of blockedBy task-014)
        task-017  (depends on 016b; promoted out of wave 5 because of blockedBy task-016b)
Wave 7: task-019  (depends on 013c,014,015,016b,017,018)
Wave 8: task-020  (depends on 013c,014,015,016b,017,018,019,005)
        task-021  (depends on 012,013c,014,015,016b,017,018)
Wave 9: task-022  (depends on 013c,014,015,016b,017,018,002)
        task-023  (depends on 002,013c,014,015,016b,017,018,019)
        task-024  (depends on everything)
```

Note: Wave assignments respect both file-disjointness AND blockedBy edges. Same-file tasks with `blockedBy` chains (013a/b/c on cycle SKILL.md, 016a/b on execute SKILL.md) remain sequential within wave 5 - they execute serially because they share a file even though they're nominally in the same wave; the blockedBy edges enforce ordering. Cross-file tasks with blockedBy edges (task-015 depends on task-014; task-017 depends on task-016b) are placed in distinct waves (wave 6) per the planner rule "Do NOT put dependent tasks in the same wave". Implementers within a wave pick the lowest-numbered unblocked task first.

## Acceptance verification map

Every SPEC success-criterion bullet maps to at least one task verifyCommand:

| SPEC criterion | Covered by task |
|---|---|
| `tests/smoke.sh` end-to-end | task-020, task-024 |
| `tests/validate-agents.sh` + frontmatter rule | task-012 (negative test), task-021 (live agent set), task-024 (final) |
| Grep no `state.json`/`state-write.sh` in live code | task-019, task-024 |
| Grep `TeamCreate`/`SendMessage`/`TaskCreate` per phase | task-013a..task-018 verify commands |
| Step 2 env-var abort | task-013a |
| Step 2 capability probe | task-013a, task-024 |
| feature.json shape after run | task-020 |
| `.gitignore` entry | task-001 |
| Distinct-implementers (>=2) | task-005, task-016b, task-020 |
| Advocate->challenger SendMessage | task-014, task-020 |
| Critique-debate convergence in feature.json.gateHistory | task-014, task-015, task-020 |
| Per-gate retry-counter persistence across kill | task-013c, task-014, task-015 (debate protocol writes to feature.json) |
| CHANGELOG v1.0.0 four sub-sections | task-023, task-024 |
| plugin.json version 1.0.0 | task-002, task-024 |
| README mentions env var + Limitations section | task-022 |
| Resume detection algorithm | task-013c (resume section) |
| Clean-exit team cleanup | task-013c, task-014..task-018 (each phase TeamDelete) |
| Kill-path orphan detection | task-013c (resume section) |
| File-conflict scope (default + override) | task-016a |
| Conventional commits + smoke before commits | enforced at commit time, not as a task |
