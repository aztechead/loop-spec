# Harness Alignment + Graphify Migration - Implementation Plan

**Spec:** `docs/loop-spec/features/harness-alignment-graphify/SPEC.md`
**Patterns:** `docs/loop-spec/features/harness-alignment-graphify/PATTERNS.md`
**Created:** 2026-05-28

## Assumptions

1. `TaskCompleted` dedicated event payload shape: `{"tool_name":"TaskCompleted","tool_input":{"taskId":"..."}}`. If the CC harness uses a different shape, the implementer of task-003 must adapt the input-parsing block and update the test fixtures accordingly, then note the deviation in the commit message.
2. `TaskCreated` dedicated event (`PreToolUse`) payload shape: `{"tool_name":"TaskCreate","tool_input":{"metadata":{...}}}`. This is consistent with what ARCH.md documents for `task-created.sh`. If the payload differs, the implementer of task-004 must document the actual shape.
3. `graphify . --update` is the correct CLI invocation for incremental graph refresh (per graphify README: "re-extract only changed files"). `--wiki` additionally generates `graphify-out/wiki/`. The two calls in verify (update only) and map-codebase (update + wiki) are intentionally different per SPEC.
4. `.claude/settings.json` does not yet exist in the repo. The file must be created fresh; no existing content to preserve.
5. The `restrict-agent-paths.sh` hook uses a `loop-spec-mapper-*` glob (line 93) that covers the remaining three mappers after deletion of mapper-arch and mapper-tech; no update to that hook is needed.

## Architecture overview

This feature is three independent harness fixes bundled together: (1) a single-key JSON file creation to fix a CC regression; (2) a hooks.json event type migration plus corresponding hook script rewrites; (3) a skill/agent/schema update set that integrates graphify as an optional codebase mapping backend. The only runtime code changes are the bash hook scripts. All other changes are markdown document edits.

## File map

- Create: `.claude/settings.json` - worktree.baseRef fix
- Modify: `hooks/hooks.json:1-36` - replace PostToolUse:TaskUpdate with TaskCompleted + TaskCreated
- Modify: `hooks/team/task-completed.sh:1-174` - remove status-parsing guard, adapt to TaskCompleted payload
- Create: `hooks/team/task-created.sh` - new PreToolUse:TaskCreate schema validation hook
- Create: `hooks/team/task-created.test.sh` - test suite for task-created.sh
- Modify: `hooks/team/task-completed.test.sh:1-196` - update payloads to TaskCompleted event shape
- Delete: `agents/loop-spec-mapper-arch.md` - superseded by graphify in graphify-present path
- Delete: `agents/loop-spec-mapper-tech.md` - superseded by graphify in graphify-present path
- Modify: `tests/validate-agents.sh:4` - update EXPECTED from 14 to 12
- Modify: `skills/map-codebase/SKILL.md` - add graphify pre-flight step and conditional mapper dispatch
- Modify: `skills/verify/SKILL.md` - add graphify . --update before map-codebase invocation in Step 7
- Modify: `agents/loop-spec-planner.md` - add graphify query/path/explain preference
- Modify: `agents/loop-spec-pattern-mapper.md` - add graphify query/path/explain preference
- Modify: `skills/shared/feature-state-schema.md` - add graphify block to index.json schema
- Modify: `CHANGELOG.md` - add [Unreleased] entries for all three changes

## Task DAG

| ID | Subject | BlockedBy | Files | Est scope |
|----|---------|-----------|-------|-----------|
| task-001 | Fix worktree.baseRef regression in .claude/settings.json | - | `.claude/settings.json` | small |
| task-002 | Migrate hooks.json from PostToolUse:TaskUpdate to TaskCompleted + TaskCreated events | - | `hooks/hooks.json` | small |
| task-003 | Rewrite task-completed.sh for TaskCompleted event (remove status-parsing, adapt payload) | task-002 | `hooks/team/task-completed.sh`, `hooks/team/task-completed.test.sh` | medium |
| task-004 | Create task-created.sh and its test suite for PreToolUse:TaskCreate schema validation | task-002 | `hooks/team/task-created.sh`, `hooks/team/task-created.test.sh` | medium |
| task-005 | Delete mapper-arch and mapper-tech agents; update validate-agents.sh count to 12 | - | `agents/loop-spec-mapper-arch.md`, `agents/loop-spec-mapper-tech.md`, `tests/validate-agents.sh` | small |
| task-006 | Update map-codebase skill with graphify pre-flight detection and conditional mapper dispatch | task-005 | `skills/map-codebase/SKILL.md` | medium |
| task-007 | Update verify skill to run graphify . --update before map-codebase invocation | - | `skills/verify/SKILL.md` | small |
| task-008 | Add graphify query/path/explain preference to planner and pattern-mapper agents | - | `agents/loop-spec-planner.md`, `agents/loop-spec-pattern-mapper.md` | small |
| task-009 | Add graphify block to feature-state-schema index.json documentation | - | `skills/shared/feature-state-schema.md` | small |
| task-010 | Update CHANGELOG.md with [Unreleased] entries for all three change groups | task-001, task-003, task-004, task-005, task-006, task-007, task-008, task-009 | `CHANGELOG.md` | small |

## Tasks

---

### task-001: Fix worktree.baseRef regression in .claude/settings.json

**Goal:** Create `.claude/settings.json` with `worktree.baseRef: "head"` to restore the pre-v2.1.133 behavior where EXECUTE worktrees always branch from local HEAD.

**Files:**
- `.claude/settings.json` (create)

**blockedBy:** (none)

**read_first:**
- `/Users/cbobrowitz/Projects/loop-spec/.claude/` (confirm only `worktrees/` is present, no existing `settings.json`)
- `PATTERNS.md` concept: "Claude Code settings.json key injection"

**Verify:** `cat /Users/cbobrowitz/Projects/loop-spec/.claude/settings.json | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['worktree']['baseRef'] == 'head', 'FAIL'"` -> exits 0 with no output.

**Acceptance criteria:**
- [ ] `.claude/settings.json` exists and contains exactly `{"worktree":{"baseRef":"head"}}` (or equivalent valid JSON with that key set).
- [ ] `python3 -c "import json,sys; d=json.load(sys.stdin); assert d['worktree']['baseRef'] == 'head', 'FAIL'"` fed the file via stdin exits 0.
- [ ] No other keys are added to the file (minimum viable content only).

**Steps (TDD where applicable):**

Skill/config task - TDD does not apply. No test file to write.

- [ ] Step 1: Confirm `.claude/` directory exists and `settings.json` does not (`ls /Users/cbobrowitz/Projects/loop-spec/.claude/`).
- [ ] Step 2: Create `.claude/settings.json` with content `{"worktree":{"baseRef":"head"}}`.
- [ ] Step 3: Run verify command; confirm exit 0 and no output.
- [ ] Step 4: Commit as `chore: NO_JIRA fix worktree.baseRef regression (.claude/settings.json)`.

---

### task-002: Migrate hooks.json from PostToolUse:TaskUpdate to TaskCompleted + TaskCreated events

**Goal:** Replace the `PostToolUse:TaskUpdate` entry in `hooks/hooks.json` with dedicated `TaskCompleted` and `TaskCreated` top-level event entries. `TaskCompleted` gets `continueOnBlock: true`. Preserve the existing `PreToolUse:Write|Edit` and `TeammateIdle` entries.

**Files:**
- `hooks/hooks.json`

**blockedBy:** (none)

**read_first:**
- `hooks/hooks.json` (current content; already read - lines 1-36)
- `PATTERNS.md` concept: "hooks.json event-matcher migration"

**Verify:** `python3 -c "import json; d=json.load(open('hooks/hooks.json')); events=list(d['hooks'].keys()); assert 'TaskCompleted' in events, 'no TaskCompleted'; assert 'TaskCreated' in events, 'no TaskCreated'; tu=[h for h in d['hooks'].get('PostToolUse',[]) if h.get('matcher','')=='TaskUpdate']; assert len(tu)==0, 'PostToolUse:TaskUpdate still present'"` run from repo root exits 0.

**Acceptance criteria:**
- [ ] `hooks/hooks.json` has a top-level `TaskCompleted` key in `hooks`.
- [ ] `hooks/hooks.json` has a top-level `TaskCreated` key in `hooks`.
- [ ] The `TaskCompleted` entry points to `${CLAUDE_PLUGIN_ROOT}/hooks/team/task-completed.sh` and has `"continueOnBlock": true`.
- [ ] The `TaskCreated` entry points to `${CLAUDE_PLUGIN_ROOT}/hooks/team/task-created.sh`.
- [ ] No `PostToolUse` entry with `matcher: "TaskUpdate"` remains.
- [ ] The existing `PreToolUse:Write|Edit` and `TeammateIdle` entries are unchanged.
- [ ] `python3` assertion from verify command exits 0.
- [ ] `python3 -c "import json; hooks=json.load(open('hooks/hooks.json')); tc=[h for ev,hl in hooks['hooks'].items() if ev=='TaskCompleted' for h in hl]; assert any(h.get('continueOnBlock') for h in tc), 'continueOnBlock missing'"` exits 0.

**Steps:**

Config task - TDD does not apply.

- [ ] Step 1: Read `hooks/hooks.json` (already done; 36 lines).
- [ ] Step 2: Replace `PostToolUse` block with `TaskCompleted` entry (with `continueOnBlock: true`) and `TaskCreated` entry. Keep `PreToolUse` and `TeammateIdle` blocks unchanged.
- [ ] Step 3: Validate JSON is well-formed: `python3 -c "import json; json.load(open('hooks/hooks.json'))"`.
- [ ] Step 4: Run both verify commands; confirm both exit 0.
- [ ] Step 5: Commit as `fix: NO_JIRA migrate hooks.json to TaskCompleted and TaskCreated events`.

---

### task-003: Rewrite task-completed.sh for TaskCompleted event (remove status-parsing)

**Goal:** Remove the `tool_name == "TaskUpdate"` and `status == "completed"` guards from `task-completed.sh` (they are no longer needed because `TaskCompleted` fires only on completion transitions). Adapt the input-parsing block to the `TaskCompleted` payload shape. Preserve all phase-gate logic (lint/typecheck in execute, metadata validation in discuss/plan). Update the test suite to match the new payload.

**Files:**
- `hooks/team/task-completed.sh`
- `hooks/team/task-completed.test.sh`

**blockedBy:** task-002

**read_first:**
- `hooks/team/task-completed.sh` (full file; already read - lines 1-174)
- `hooks/team/task-completed.test.sh` (full file; already read - lines 1-196)
- `PATTERNS.md` concept: "hook script event-payload adaptation (task-completed.sh)"
- Assumption A (see Assumptions section above): `TaskCompleted` payload shape

**Verify:** `bash hooks/team/task-completed.test.sh` run from repo root exits 0. Additionally: `grep -n 'status.*completed\|if.*status' hooks/team/task-completed.sh` returns no matches (grep exits 1).

**Acceptance criteria:**
- [ ] Lines 20-32 of the current `task-completed.sh` (the `TOOL_NAME` and `STATUS` blocks) are deleted or replaced with a comment block.
- [ ] `grep -n 'status.*completed\|if.*status' hooks/team/task-completed.sh` exits 1 (no match).
- [ ] `bash hooks/team/task-completed.test.sh` exits 0 with all test cases passing.
- [ ] The `run_check()` allowlist function (lines 96-117) is preserved verbatim.
- [ ] The `validate_metadata()` function (lines 63-93) is preserved (with any payload-path adjustments for the new event shape).
- [ ] The execute/discuss/plan phase-gate logic (case statement) is preserved.

**Steps (TDD):**

- [ ] Step 1: Read current `task-completed.sh` and `task-completed.test.sh` in full.
- [ ] Step 2: Update test fixtures in `task-completed.test.sh` to use the `TaskCompleted` payload shape (assumption A). Replace `payload_completed()` helper to emit `{"tool_name":"TaskCompleted","tool_input":{"taskId":"..."}}` instead of the `TaskUpdate` shape. Update the `payload_completed_with_metadata()` helper analogously.
- [ ] Step 3: Run `bash hooks/team/task-completed.test.sh`; expect failures (tests now send TaskCompleted payloads, hook still has TaskUpdate guards). Confirm test cases B and C (non-TaskUpdate and non-completed status filters) now fail.
- [ ] Step 4: Rewrite `task-completed.sh`: delete the `TOOL_NAME` and `STATUS` guard blocks (lines 20-32 and the two `if` branches). Update the `INPUT` parsing at the top to extract task id from the new payload path if needed for the feature.json lookup. Keep the feature.json location logic and all phase-gate logic unchanged.
- [ ] Step 5: Run `bash hooks/team/task-completed.test.sh`; expect all tests to pass. If test case B or C are no longer meaningful (because there is no tool_name or status filtering), remove those test cases and document the removal.
- [ ] Step 6: Run verify grep: `grep -n 'status.*completed\|if.*status' hooks/team/task-completed.sh`; confirm exit 1.
- [ ] Step 7: Commit as `fix: NO_JIRA rewrite task-completed.sh for TaskCompleted event`.

---

### task-004: Create task-created.sh and test suite for PreToolUse:TaskCreate schema validation

**Goal:** Create `hooks/team/task-created.sh` that validates required task metadata fields (`blockedBy`, `files`, `verifyCommand`, `acceptanceCriteria`) at `TaskCreate` time. Exit 2 with a `DENY:` message to stderr when any required field is missing or invalid. Create a companion test suite `hooks/team/task-created.test.sh`.

**Files:**
- `hooks/team/task-created.sh` (create)
- `hooks/team/task-created.test.sh` (create)

**blockedBy:** task-002

**read_first:**
- `hooks/team/teammate-idle.sh` (graceful feature.json location pattern; lines 19-27)
- `hooks/restrict-agent-paths.sh` (DENY exit 2 pattern; lines 86-91)
- `hooks/team/task-completed.sh` (`validate_metadata()` function; lines 63-93 - reuse this logic)
- `hooks/team/task-completed.test.sh` (`check()` harness pattern; lines 14-42)
- `PATTERNS.md` concepts: "new hook script creation (task-created.sh)"
- Assumption B (see Assumptions section above): `TaskCreated` payload shape

**Verify:** `test -x hooks/team/task-created.sh` exits 0. `echo '{"tool_name":"TaskCreate","tool_input":{"metadata":{}}}' | bash hooks/team/task-created.sh; echo $?` from repo root produces `2`. `bash hooks/team/task-created.test.sh` exits 0.

**Acceptance criteria:**
- [ ] `hooks/team/task-created.sh` exists and is executable (`test -x` exits 0).
- [ ] `echo '{"tool_name":"TaskCreate","tool_input":{"metadata":{}}}' | bash hooks/team/task-created.sh` exits 2.
- [ ] A payload with all four required fields present and valid exits 0.
- [ ] `bash hooks/team/task-created.test.sh` exits 0 with all test cases passing.
- [ ] The script uses `set -euo pipefail`.
- [ ] The DENY message to stderr contains the list of missing fields.
- [ ] `hooks/team/task-created.test.sh` covers at minimum: (a) all four fields present and valid -> exit 0; (b) empty metadata `{}` -> exit 2; (c) missing `verifyCommand` -> exit 2; (d) empty `acceptanceCriteria` array -> exit 2; (e) missing `blockedBy` -> exit 2; (f) missing `files` -> exit 2.

**Steps (TDD):**

- [ ] Step 1: Write `hooks/team/task-created.test.sh` with the `check()` harness and all six test cases (a-f above). Use the `TaskCreate` payload shape from assumption B. Run it; expect all tests to fail (script does not exist yet).
- [ ] Step 2: Create `hooks/team/task-created.sh` with `#!/usr/bin/env bash`, `set -euo pipefail`, stdin capture, and python3-based metadata validation logic (mirror `validate_metadata()` from `task-completed.sh` but adapted for `tool_input.metadata` on a `TaskCreate` payload). Exit 2 with DENY message on missing/invalid fields; exit 0 otherwise.
- [ ] Step 3: Make the script executable: `chmod +x hooks/team/task-created.sh`.
- [ ] Step 4: Run `bash hooks/team/task-created.test.sh`; expect all tests to pass.
- [ ] Step 5: Run `test -x hooks/team/task-created.sh`; confirm exit 0.
- [ ] Step 6: Run `echo '{"tool_name":"TaskCreate","tool_input":{"metadata":{}}}' | bash hooks/team/task-created.sh; echo $?`; confirm output is `2`.
- [ ] Step 7: Commit as `feat: NO_JIRA add task-created.sh PreToolUse hook for TaskCreate schema validation`.

---

### task-005: Delete mapper-arch and mapper-tech agents; update validate-agents.sh count to 12

**Goal:** Remove `agents/loop-spec-mapper-arch.md` and `agents/loop-spec-mapper-tech.md` (superseded by graphify in the graphify-present path). Update the hard-coded `EXPECTED` constant in `tests/validate-agents.sh` from 14 to 12 in the same commit so the validator never sees a transient count mismatch.

**Files:**
- `agents/loop-spec-mapper-arch.md` (delete)
- `agents/loop-spec-mapper-tech.md` (delete)
- `tests/validate-agents.sh`

**blockedBy:** (none)

**read_first:**
- `tests/validate-agents.sh` (full; already read - lines 1-48)
- `agents/loop-spec-mapper-arch.md` (confirm it exists; already read)
- `agents/loop-spec-mapper-tech.md` (confirm it exists; already read)
- `PATTERNS.md` concept: "mapper agent deletion + validate-agents.sh count update"

**Verify:** `bash tests/validate-agents.sh` exits 0 and prints `All 12 agents validated.`. `test ! -f agents/loop-spec-mapper-arch.md && test ! -f agents/loop-spec-mapper-tech.md` exits 0.

**Acceptance criteria:**
- [ ] `agents/loop-spec-mapper-arch.md` does not exist (`test ! -f` exits 0).
- [ ] `agents/loop-spec-mapper-tech.md` does not exist (`test ! -f` exits 0).
- [ ] `tests/validate-agents.sh` line 4 reads `EXPECTED="${EXPECTED:-12}"`.
- [ ] `bash tests/validate-agents.sh` exits 0 and prints `All 12 agents validated.`.
- [ ] No other agent files are deleted or modified.

**Steps:**

Docs/config task - TDD does not apply.

- [ ] Step 1: Confirm file count before deletion: `ls agents/loop-spec-*.md | wc -l` should return 14.
- [ ] Step 2: Delete `agents/loop-spec-mapper-arch.md` and `agents/loop-spec-mapper-tech.md`.
- [ ] Step 3: Edit `tests/validate-agents.sh` line 4: change `EXPECTED="${EXPECTED:-14}"` to `EXPECTED="${EXPECTED:-12}"`.
- [ ] Step 4: Run `bash tests/validate-agents.sh`; confirm exit 0 and `All 12 agents validated.`.
- [ ] Step 5: Run `test ! -f agents/loop-spec-mapper-arch.md && test ! -f agents/loop-spec-mapper-tech.md`; confirm exit 0.
- [ ] Step 6: Commit as `feat: NO_JIRA remove mapper-arch and mapper-tech agents (superseded by graphify)`.

---

### task-006: Update map-codebase skill with graphify pre-flight detection and conditional mapper dispatch

**Goal:** Add a Step 0 to `skills/map-codebase/SKILL.md` that: (a) detects graphify with `command -v graphify`; (b) if present, runs `graphify . --update --wiki`; (c) if absent, prints a one-line install hint. In Step 2, make the teammate list conditional: graphify-present dispatches only `mapper-quality-1`, `mapper-concerns-1`, `mapper-domain-1`; graphify-absent dispatches all five (now three, because mapper-arch and mapper-tech are deleted in task-005; the fallback is the three remaining mappers plus a note that graphify-absent means ARCH and TECH coverage is missing). Document the graphify-absent fallback explicitly.

**Files:**
- `skills/map-codebase/SKILL.md`

**blockedBy:** task-005

**read_first:**
- `skills/map-codebase/SKILL.md` (full; already read)
- `PATTERNS.md` concepts: "optional external tool detection (graphify pre-flight)", "skill markdown conditional-path documentation"
- graphify CLI docs: `graphify . --update --wiki` (re-extract changed files + build wiki)

**Verify:** `grep -n 'command -v graphify' skills/map-codebase/SKILL.md` exits 0. `grep -n 'graphify.*--update\|--update.*graphify' skills/map-codebase/SKILL.md` exits 0. `grep -n 'fallback\|5.*mapper\|five.*mapper\|mapper-tech\|mapper-arch' skills/map-codebase/SKILL.md` exits 0.

**Acceptance criteria:**
- [ ] `grep -n 'command -v graphify' skills/map-codebase/SKILL.md` exits 0 (at least one match).
- [ ] `grep -n 'graphify.*--update\|--update.*graphify' skills/map-codebase/SKILL.md` exits 0.
- [ ] `grep -n 'fallback\|5.*mapper\|five.*mapper\|mapper-tech\|mapper-arch' skills/map-codebase/SKILL.md` exits 0 (fallback path documented).
- [ ] The new Step 0 appears before existing Step 1 (Determine stale domains) in the file.
- [ ] The Step 2 teammate list (TeamCreate) is conditional: graphify-present spawns only quality/concerns/domain mappers; graphify-absent spawns quality/concerns/domain mappers plus a documented note that arch and tech coverage requires graphify.
- [ ] A one-line install hint (`pip install graphifyy`) appears when graphify is absent.

**Steps:**

Skill/docs task - TDD does not apply.

- [ ] Step 1: Read `skills/map-codebase/SKILL.md` in full (already done).
- [ ] Step 2: Insert a new `### Step 0 - Graphify pre-flight detection` section before `### Step 1 - Determine stale domains`. The section must include: `command -v graphify` check, `graphify . --update --wiki` invocation when present, and install hint to stderr when absent.
- [ ] Step 3: Update the `### Step 2 - Create map-codebase team and spawn mapper teammates` section. Remove `mapper-tech-1` and `mapper-arch-1` from the TeamCreate block unconditionally (they are deleted). Add a prose note: "When graphify is not installed, ARCH and TECH domains are not refreshed by this skill invocation. Install graphify to restore full coverage."
- [ ] Step 4: Renumber existing Steps 1-6 to Steps 1-6 (Step 0 is an insertion, not a renumber of Step 1 - keep Step 1 as Step 1; Step 0 is the new prefix step).
- [ ] Step 5: Run three verify greps; confirm all exit 0.
- [ ] Step 6: Commit as `feat: NO_JIRA integrate graphify into map-codebase skill (optional pre-flight)`.

---

### task-007: Update verify skill to run graphify . --update before map-codebase invocation

**Goal:** Add a conditional `graphify . --update` call to `skills/verify/SKILL.md` Step 7 (map-codebase refresh), before the `Skill(loop-spec:map-codebase)` invocation. The call is conditional on `command -v graphify`; it runs without `--wiki` (faster, no wiki rebuild needed at verify time).

**Files:**
- `skills/verify/SKILL.md`

**blockedBy:** (none)

**read_first:**
- `skills/verify/SKILL.md` Step 7 (lines 174-181; already read)
- `PATTERNS.md` concept: "optional external tool detection (graphify pre-flight)"

**Verify:** `grep -n 'command -v graphify\|graphify.*--update' skills/verify/SKILL.md` exits 0 (at least one match).

**Acceptance criteria:**
- [ ] `grep -n 'command -v graphify\|graphify.*--update' skills/verify/SKILL.md` exits 0.
- [ ] The graphify block appears in Step 7 (map-codebase refresh), before the `Skill(loop-spec:map-codebase)` invocation line.
- [ ] The invocation is `graphify . --update` (without `--wiki`).
- [ ] Failure of the graphify call is non-blocking (consistent with existing Step 7 map-codebase failure handling: "log warning... and continue").

**Steps:**

Skill/docs task - TDD does not apply.

- [ ] Step 1: Read `skills/verify/SKILL.md` Step 7 (already done).
- [ ] Step 2: Insert a conditional graphify block at the start of Step 7, before the `Skill(loop-spec:map-codebase)` line. Pattern: `if command -v graphify: graphify . --update; on failure: log warning and continue`.
- [ ] Step 3: Run verify grep; confirm exit 0.
- [ ] Step 4: Commit as `feat: NO_JIRA run graphify . --update in verify before map-codebase`.

---

### task-008: Add graphify query/path/explain preference to planner and pattern-mapper agents

**Goal:** Add a conditional graphify preference instruction to `agents/loop-spec-planner.md` and `agents/loop-spec-pattern-mapper.md`. The instruction must: (a) check for `graphify-out/wiki/index.md` existence; (b) if present, prefer `graphify query/path/explain` over reading flat ARCH.md and TECH.md; (c) keep QUALITY.md, CONCERNS.md, DOMAIN.md reads unchanged.

**Files:**
- `agents/loop-spec-planner.md`
- `agents/loop-spec-pattern-mapper.md`

**blockedBy:** (none)

**read_first:**
- `agents/loop-spec-planner.md` (full; already read - the role boundary section)
- `agents/loop-spec-pattern-mapper.md` (full; already read)
- `PATTERNS.md` concept: "agent prompt instruction update (graphify query preference)"

**Verify:** `grep -n 'graphify.*query\|graphify.*path\|graphify.*explain\|graphify-out/wiki' agents/loop-spec-planner.md` exits 0. `grep -n 'graphify.*query\|graphify.*path\|graphify.*explain\|graphify-out/wiki' agents/loop-spec-pattern-mapper.md` exits 0.

**Acceptance criteria:**
- [ ] `grep -n 'graphify.*query\|graphify.*path\|graphify.*explain\|graphify-out/wiki' agents/loop-spec-planner.md` exits 0.
- [ ] `grep -n 'graphify.*query\|graphify.*path\|graphify.*explain\|graphify-out/wiki' agents/loop-spec-pattern-mapper.md` exits 0.
- [ ] The instruction in each agent is conditional on `graphify-out/wiki/index.md` existing (agents cannot run shell; phrase as "If graphify-out/wiki/index.md exists...").
- [ ] QUALITY.md, CONCERNS.md, and DOMAIN.md read instructions are not modified.
- [ ] The flat-file fallback (read ARCH.md and TECH.md when graphify is absent) is preserved.

**Steps:**

Docs task - TDD does not apply.

- [ ] Step 1: Read both agent files in full (already done).
- [ ] Step 2: In `agents/loop-spec-planner.md`, add a "Graphify-first navigation" block to the Role boundary or Procedure section: "If `graphify-out/wiki/index.md` exists, prefer `graphify query "<question>"`, `graphify path "<A>" "<B>"`, `graphify explain "<concept>"` for structural and architectural questions over reading flat ARCH.md or TECH.md. QUALITY.md, CONCERNS.md, and DOMAIN.md reads are unchanged."
- [ ] Step 3: Apply the same instruction block to `agents/loop-spec-pattern-mapper.md` in the appropriate section (Step 1 - Read inputs or Find analogs).
- [ ] Step 4: Run both verify greps; confirm both exit 0.
- [ ] Step 5: Commit as `feat: NO_JIRA add graphify query preference to planner and pattern-mapper agents`.

---

### task-009: Add graphify block to feature-state-schema index.json documentation

**Goal:** Add a `graphify` block to the `.loop-spec/codebase/index.json` schema documentation in `skills/shared/feature-state-schema.md`. The block must include at least one of: `last_updated`, `graph_json_path`, or `wiki_path`. Also document that in graphify-present mode the `last_refreshed_at` domain set only covers `quality`, `concerns`, and `domain` (not `tech` or `arch`).

**Files:**
- `skills/shared/feature-state-schema.md`

**blockedBy:** (none)

**read_first:**
- `skills/shared/feature-state-schema.md` (full; already read)
- `PATTERNS.md` concept: "feature-state-schema graphify block addition"

**Verify:** `grep -n 'graphify' skills/shared/feature-state-schema.md` exits 0 and the matched line(s) include `last_updated` or `graph_json_path` or `wiki_path`.

**Acceptance criteria:**
- [ ] `grep -n 'graphify' skills/shared/feature-state-schema.md` exits 0.
- [ ] The graphify block includes at least one of `last_updated`, `graph_json_path`, or `wiki_path`.
- [ ] The schema doc notes that in graphify-present mode only `quality`, `concerns`, and `domain` appear in `last_refreshed_at` (not `tech` or `arch`).
- [ ] Existing `feature.json` schema content is unchanged.

**Steps:**

Docs task - TDD does not apply.

- [ ] Step 1: Read `skills/shared/feature-state-schema.md` in full (already done).
- [ ] Step 2: Locate the `index.json` structure documentation. Add a new subsection or note after the existing `index.json` description: a `graphify` block documenting the optional graphify-side state tracked alongside the domain map. Example fields: `graph_json_path`, `wiki_path`, `last_updated`.
- [ ] Step 3: Add a field note explaining the reduced `last_refreshed_at` domain set in graphify-present mode.
- [ ] Step 4: Run verify grep; confirm exit 0 and content includes required field name.
- [ ] Step 5: Commit as `docs: NO_JIRA add graphify block to feature-state-schema index.json docs`.

---

### task-010: Update CHANGELOG.md with [Unreleased] entries for all three change groups

**Goal:** Add entries under the `[Unreleased]` heading in `CHANGELOG.md` documenting: (a) `worktree.baseRef` fix; (b) `TaskCompleted` and `TaskCreated` hook migration with `continueOnBlock`; (c) graphify optional integration. This task is blocked by all other tasks so entries reflect what was actually implemented.

**Files:**
- `CHANGELOG.md`

**blockedBy:** task-001, task-003, task-004, task-005, task-006, task-007, task-008, task-009

**read_first:**
- `CHANGELOG.md` (full; already read - lines 1-6 show `[Unreleased]` section is empty)
- The v1.0.1 and v1.0.0 entry styles for formatting reference

**Verify:** `grep -n 'worktree.baseRef\|TaskCompleted\|TaskCreated\|continueOnBlock\|graphify' CHANGELOG.md` exits 0 and matches appear under the `[Unreleased]` heading.

**Acceptance criteria:**
- [ ] `grep -n 'worktree.baseRef\|TaskCompleted\|TaskCreated\|continueOnBlock\|graphify' CHANGELOG.md` exits 0.
- [ ] All matched lines appear under the `## [Unreleased]` heading (before the `## [1.0.1]` heading).
- [ ] Three sub-groups are documented: Fixed (worktree.baseRef), Changed (hook migration), Added (graphify integration).
- [ ] No em-dash appears in the new entries.

**Steps:**

Docs task - TDD does not apply.

- [ ] Step 1: Read `CHANGELOG.md` (already done; `[Unreleased]` section is currently empty).
- [ ] Step 2: Add three entries under `## [Unreleased]`: `### Fixed` for worktree.baseRef; `### Changed` for hook event migration (TaskCompleted + TaskCreated, continueOnBlock, creation-time schema validation); `### Added` for graphify optional integration (map-codebase pre-flight, verify pre-update, agent query preference, schema block, mapper deletion).
- [ ] Step 3: Run verify grep; confirm exit 0 and matches are above `## [1.0.1]`.
- [ ] Step 4: Commit as `docs: NO_JIRA update CHANGELOG for harness-alignment-graphify feature`.

---

## Test strategy

- task-003: `bash hooks/team/task-completed.test.sh` (full suite after payload shape update)
- task-004: `bash hooks/team/task-created.test.sh` (new suite, 6+ cases)
- task-005: `bash tests/validate-agents.sh` (expected count 12)
- All tasks: `bash tests/run-all.sh` as the final integration check before each commit
- Smoke test (`bash tests/smoke.sh`) is end-to-end only, requires live Claude CLI, and is the release gate; it is not run per-task.

## Rollback plan

All changes are to markdown files, JSON configs, and bash scripts - none are compiled. To revert:

1. `git revert` the commits for any task in reverse order.
2. For task-005 (agent deletion): restore from `git show HEAD~N:agents/loop-spec-mapper-arch.md` if needed.
3. For task-001 (settings.json creation): `git rm .claude/settings.json` and commit.
4. The `hooks/hooks.json` migration (task-002) is the highest-risk revert because task-003 and task-004 depend on it; revert task-004, task-003, then task-002 in that order.
