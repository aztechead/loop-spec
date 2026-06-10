# Resilience + operations layer - Implementation Plan

**Spec:** `docs/loop-spec/features/resilience-ops/SPEC.md`
**Created:** 2026-05-28

## Architecture overview

Eleven independent deliverables: four new skills (pause, forensics, rollback, discipline), four new lib scripts (pause-snapshot, regression-scan, checkpoint, ralph-remediation), four new hooks (discipline-inject, output-compressor, done-criteria, session-end-learnings), plus edits to existing artifacts (skills/verify/SKILL.md, agents/loop-spec-spec-writer.md, SPEC.md.template, agent frontmatter files, hooks/hooks.json, tests/run-all.sh, CHANGELOG.md). All new bash scripts expose a kill switch and fail-open. No new external dependencies.

## Assumptions

- `skills/pause/SKILL.md` and `skills/forensics/SKILL.md` are invoked by the lead skill as sub-skills via `Skill(loop-spec:pause)` and `Skill(loop-spec:forensics)`; slash commands for these are not in scope (SPEC does not mention them).
- `lib/ralph-remediation.sh` calls the `Agent(...)` harness tool internally (not a raw `claude` CLI invocation) since it runs inside a skill context; it accepts the feature-dir path and reads pending remediation tasks from `feature.json`.
- The regression gate calls `lib/regression-scan.sh` via a Bash tool call in `skills/verify/SKILL.md`; it is not a hook.
- `agents/README.md` does not currently exist (confirmed by ls output) and must be created.
- The SPEC says "at least 3 agents gain an `effort:` field and at least 1 gains `disallowedTools:`"; the plan adds `effort:` to `loop-spec-implementer`, `loop-spec-verifier`, and `loop-spec-spec-writer`, and `disallowedTools:` to `loop-spec-implementer` (excluding push/PR tools). `loop-spec-implementer` also gains `isolation: worktree`.
- `validate-agents.sh` currently expects 12 agents and checks for `skills:` and `mcpServers:` as forbidden keys. The new fields (`effort`, `disallowedTools`, `isolation`) are additive and are not in the forbidden key list, so the validator passes without modification.
- `tests/run-all.sh` must be updated to add the four new `.test.sh` suites; the verify command for that task checks exit 0.

## File map

- Create: `skills/pause/SKILL.md` - /loop-spec:pause skill documenting HANDOFF.json + .continue-here.md generation
- Create: `skills/forensics/SKILL.md` - /loop-spec:forensics read-only 7-pattern diagnostic
- Create: `skills/rollback/SKILL.md` - /loop-spec:rollback checkpoint rollback skill
- Create: `skills/discipline/SKILL.md` - /loop-spec:discipline on|off|status skill
- Create: `lib/pause-snapshot.sh` - executable; writes HANDOFF.json and .continue-here.md
- Create: `lib/regression-scan.sh` - executable; reads prior VERIFICATION.md files, outputs JSON
- Create: `lib/checkpoint.sh` - executable; supports `tag <type>` and `rollback <tag>` subcommands
- Create: `lib/ralph-remediation.sh` - executable; bash loop max 5 iterations, checks COMPLETE signal
- Create: `hooks/team/discipline-inject.sh` - SessionStart hook; conf-file-driven; 5 gates
- Create: `hooks/team/discipline-inject.test.sh` - unit tests for discipline-inject.sh
- Create: `hooks/team/output-compressor.sh` - PostToolUse hook; threshold 3000 chars; shape detection
- Create: `hooks/team/output-compressor.test.sh` - unit tests for output-compressor.sh
- Create: `hooks/team/done-criteria.sh` - UserPromptSubmit hook; compound task detection
- Create: `hooks/team/done-criteria.test.sh` - unit tests for done-criteria.sh
- Create: `hooks/team/session-end-learnings.sh` - Stop/SessionEnd hook; appends JSONL; cap 50
- Create: `hooks/team/session-end-learnings.test.sh` - unit tests for session-end-learnings.sh
- Create: `agents/README.md` - documents effort, disallowedTools, isolation fields
- Modify: `skills/verify/SKILL.md` - add regression-scan call + Ralph remediation routing
- Modify: `skills/discuss/SKILL.md` - add checkpoint.sh tag call at phase completion
- Modify: `skills/plan/SKILL.md` - add checkpoint.sh tag call at phase completion
- Modify: `skills/execute/SKILL.md` - add checkpoint.sh tag call at phase completion
- Modify: `agents/loop-spec-spec-writer.md` - require Boundaries + 2-tier Success criteria sections
- Modify: `agents/loop-spec-implementer.md` - add isolation, effort, disallowedTools to frontmatter
- Modify: `agents/loop-spec-verifier.md` - add effort field to frontmatter
- Modify: `agents/loop-spec-planner.md` - add effort field to frontmatter
- Modify: `skills/shared/artifact-templates/SPEC.md.template` - add Boundaries + Good Enough/Exceptional sections
- Modify: `hooks/hooks.json` - wire four new hooks (SessionStart, PostToolUse, UserPromptSubmit, Stop)
- Modify: `tests/run-all.sh` - add four new test suites
- Modify: `skills/cycle/SKILL.md` - add severity-tag parsing note for .continue-here.md (Exceptional criterion)
- Modify: `CHANGELOG.md` - add entries for all 11 items

## Task DAG

| ID | Subject | BlockedBy | Files | Est scope |
|----|---------|-----------|-------|-----------|
| task-001 | lib/pause-snapshot.sh: write HANDOFF.json + .continue-here.md | - | `lib/pause-snapshot.sh` | medium |
| task-002 | skills/pause/SKILL.md: pause skill document | task-001 | `skills/pause/SKILL.md` | small |
| task-003 | lib/regression-scan.sh: cross-feature test runner | - | `lib/regression-scan.sh` | medium |
| task-004 | skills/verify/SKILL.md: regression gate + Ralph routing | task-003, task-007 | `skills/verify/SKILL.md` | medium |
| task-005 | lib/checkpoint.sh: tag + rollback subcommands | - | `lib/checkpoint.sh` | medium |
| task-006 | skills/rollback/SKILL.md: rollback skill document | task-005 | `skills/rollback/SKILL.md` | small |
| task-007 | lib/ralph-remediation.sh: bash loop remediation executor | - | `lib/ralph-remediation.sh` | medium |
| task-008 | Phase skills: wire checkpoint.sh at phase completion | task-005 | `skills/discuss/SKILL.md`, `skills/plan/SKILL.md`, `skills/execute/SKILL.md` | small |
| task-009 | skills/forensics/SKILL.md: 7-pattern read-only diagnostic | - | `skills/forensics/SKILL.md` | medium |
| task-010 | agents/loop-spec-spec-writer.md + SPEC.md.template: Boundaries + 2-tier success | - | `agents/loop-spec-spec-writer.md`, `skills/shared/artifact-templates/SPEC.md.template` | small |
| task-011 | Agent frontmatter: effort, disallowedTools, isolation + agents/README.md | - | `agents/loop-spec-implementer.md`, `agents/loop-spec-verifier.md`, `agents/loop-spec-planner.md`, `agents/README.md` | small |
| task-012 | hooks/team/discipline-inject.sh + test | - | `hooks/team/discipline-inject.sh`, `hooks/team/discipline-inject.test.sh`, `skills/discipline/SKILL.md` | medium |
| task-013 | hooks/team/output-compressor.sh + test | - | `hooks/team/output-compressor.sh`, `hooks/team/output-compressor.test.sh` | medium |
| task-014 | hooks/team/done-criteria.sh + test | - | `hooks/team/done-criteria.sh`, `hooks/team/done-criteria.test.sh` | medium |
| task-015 | hooks/team/session-end-learnings.sh + test | - | `hooks/team/session-end-learnings.sh`, `hooks/team/session-end-learnings.test.sh` | medium |
| task-016 | hooks/hooks.json: wire all four new hooks | task-012, task-013, task-014, task-015 | `hooks/hooks.json` | small |
| task-017 | tests/run-all.sh + CHANGELOG.md: integrate new suites + document 11 items | task-012, task-013, task-014, task-015, task-016 | `tests/run-all.sh`, `CHANGELOG.md` | small |

---

## Tasks

### task-001: lib/pause-snapshot.sh - write HANDOFF.json + .continue-here.md

**Goal:** Create an executable bash lib script that generates two crash-recovery artifacts into `.loop-spec/features/{slug}/`.

**Files:**
- `lib/pause-snapshot.sh`

**read_first:**
- `lib/feature-write.sh` (atomic write pattern, lines 77-91)
- `hooks/team/task-completed.sh` (python3 inline JSON parsing, lines 39-47)
- `docs/loop-spec/features/resilience-ops/SPEC.md` (Pause and crash recovery section)

**Verify:** `test -x lib/pause-snapshot.sh && bash lib/pause-snapshot.sh --dry-run 2>/dev/null | jq 'has("currentPhase") and has("uncommittedFiles")' | grep -q true && echo PASS`

**Acceptance criteria:**
- [ ] Script is executable and has `set -euo pipefail`.
- [ ] `--dry-run` mode accepts a `--feature-dir <path>` argument (defaults to scanning `.loop-spec/features/*/feature.json`).
- [ ] Outputs HANDOFF.json with keys: `currentPhase`, `completedTasks`, `pendingTasks`, `blockers`, `decisions`, `uncommittedFiles`, `contextNotes`. JSON is valid (jq-parseable).
- [ ] `uncommittedFiles[]` is populated via `git diff --name-only HEAD` (or empty array when no uncommitted files).
- [ ] Writes `.continue-here.md` with a BLOCKING CONSTRAINTS checklist, severity-tagged anti-patterns (lines tagged `blocking:` or `advisory:`), and a Required Reading ordered list.
- [ ] Both artifacts are written to `.loop-spec/features/{slug}/` (not to project root).
- [ ] Kill switch: `LOOP_SPEC_PAUSE=0` causes exit 0 without writing files.
- [ ] Any IO error exits gracefully (fail-open for non-critical paths; HANDOFF.json write failure is exit 2 since it is the primary artifact).

**Steps (TDD):**

- [ ] Step 1: Create a minimal test file at a temporary path asserting `--dry-run` produces valid JSON with all required keys (use a fixture feature.json).
- [ ] Step 2: Run test, confirm FAIL (script does not exist yet).
- [ ] Step 3: Write `lib/pause-snapshot.sh` using the fail-open + kill-switch pattern from `hooks/team/stop-deflection-guard.sh:27-43`. Apply the python3 inline JSON parsing pattern from `hooks/team/task-completed.sh:39-47` to read feature.json. Use `printf '%s\n' "$JSON" > "$HANDOFF_PATH"` (atomic-write ceremony from feature-write.sh is unnecessary for a diagnostic artifact per PATTERNS.md gotcha).
- [ ] Step 4: Run test, confirm PASS.
- [ ] Step 5: Commit `lib/pause-snapshot.sh`.

---

### task-002: skills/pause/SKILL.md - pause skill document

**Goal:** Create a new skill that documents the /loop-spec:pause command and delegates to lib/pause-snapshot.sh.

**Files:**
- `skills/pause/SKILL.md`

**read_first:**
- `skills/verify/SKILL.md` (skill structure reference)
- `lib/pause-snapshot.sh` (what the script does)
- `docs/loop-spec/features/resilience-ops/SPEC.md` (Pause and crash recovery section)

**blockedBy:** task-001

**Verify:** `test -f skills/pause/SKILL.md && echo PASS`

**Acceptance criteria:**
- [ ] File exists at `skills/pause/SKILL.md` with YAML frontmatter (`name: pause`, `description`).
- [ ] Documents the HANDOFF.json schema (all 7 fields).
- [ ] Documents .continue-here.md format including severity tags (`blocking`, `advisory`).
- [ ] References `lib/pause-snapshot.sh` by name in the procedure.
- [ ] Describes the resume detection path: cycle/SKILL.md parses severity tags from .continue-here.md.

**Steps (no TDD - docs/skills task):**

- [ ] Step 1: Create `skills/pause/` directory.
- [ ] Step 2: Write `skills/pause/SKILL.md` following the structure of `skills/verify/SKILL.md` (frontmatter, Inputs, Procedure, sections documenting both artifacts and the severity-tag convention).
- [ ] Step 3: Verify file exists and frontmatter is valid.
- [ ] Step 4: Commit `skills/pause/SKILL.md`.

---

### task-003: lib/regression-scan.sh - cross-feature test runner

**Goal:** Create an executable bash lib script that scans prior completed features' VERIFICATION.md files, extracts test commands, runs them, and returns structured JSON.

**Files:**
- `lib/regression-scan.sh`

**read_first:**
- `lib/feature-write.sh` (project bash conventions)
- `docs/loop-spec/features/resilience-ops/SPEC.md` (Regression gate section)

**Verify:** `test -x lib/regression-scan.sh && bash lib/regression-scan.sh . 2>/dev/null | jq 'has("prior_features") and has("failed_tests")' | grep -q true && echo PASS`

**Acceptance criteria:**
- [ ] Script is executable with `set -euo pipefail`.
- [ ] Accepts a single argument: `<project-root>`.
- [ ] Reads `docs/loop-spec/features/*/VERIFICATION.md` for each completed feature (skips the current feature by checking feature.json `currentPhase != completed` or by accepting a `--exclude <slug>` flag).
- [ ] Extracts verify commands from VERIFICATION.md (lines matching `Verify:` or fenced bash blocks after acceptance criteria headers).
- [ ] Runs each extracted command; captures pass/fail.
- [ ] Outputs JSON: `{"prior_features":[{"slug":"...","status":"pass|fail"}], "failed_tests":[{"slug":"...","command":"...","output":"..."}]}`.
- [ ] On any parse error or missing file, outputs `{"prior_features":[],"failed_tests":[]}` and exits 0 (fail-open advisory).
- [ ] Does not modify any file; read-only operation.

**Steps (TDD):**

- [ ] Step 1: Write test in a temp dir with a fixture VERIFICATION.md; assert output JSON has required keys.
- [ ] Step 2: Run test, expect FAIL.
- [ ] Step 3: Implement `lib/regression-scan.sh` using `find docs/loop-spec/features -name VERIFICATION.md` to locate targets. Parse verify commands via `grep` patterns. Use python3 inline for JSON construction (per PATTERNS.md python3 inline pattern from `hooks/team/task-completed.sh:39-47`).
- [ ] Step 4: Run test, expect PASS.
- [ ] Step 5: Commit `lib/regression-scan.sh`.

---

### task-004: skills/verify/SKILL.md - regression gate + Ralph remediation routing

**Goal:** Edit skills/verify/SKILL.md to add the regression-scan advisory gate before Step 2 and route HARD-GATE remediations to Ralph when count is at or below threshold.

**Files:**
- `skills/verify/SKILL.md`

**read_first:**
- `skills/verify/SKILL.md` (full current content)
- `lib/regression-scan.sh` (what it outputs)
- `lib/ralph-remediation.sh` (what it does)
- `docs/loop-spec/features/resilience-ops/SPEC.md` (Regression gate + Ralph executor sections)

**blockedBy:** task-003, task-007

**Verify:** `grep -c "regression-scan.sh" skills/verify/SKILL.md | grep -qE '^[1-9]' && grep -c "ralph-remediation.sh\|RALPH_THRESHOLD" skills/verify/SKILL.md | grep -qE '^[1-9]' && echo PASS`

**Acceptance criteria:**
- [ ] A new "Step 0 - Regression gate" is inserted before the current Step 1 (or labeled clearly before Step 2), calling `bash lib/regression-scan.sh <project-root>`.
- [ ] Failure of regression-scan produces an advisory warning logged in VERIFICATION.md output; VERIFY is NOT blocked.
- [ ] The HARD-GATE remediation section documents: if `pendingRemediationTasks.length <= LOOP_SPEC_RALPH_THRESHOLD` (default 3), invoke `lib/ralph-remediation.sh <feature-dir>`; else use the existing full EXECUTE team path.
- [ ] `LOOP_SPEC_RALPH_THRESHOLD` env var is documented with default value of 3.
- [ ] No existing gate logic is removed or degraded.

**Steps (no TDD - skill markdown edit):**

- [ ] Step 1: Read full current `skills/verify/SKILL.md`.
- [ ] Step 2: Insert regression-scan step before Step 1 (shift numbering). Apply the advisory (non-blocking) pattern consistent with the graphify update in Step 7.
- [ ] Step 3: In the code-review HARD-GATE section (currently Step 5), add Ralph threshold check before routing to EXECUTE.
- [ ] Step 4: Run verify command to confirm both grep counts return 1+.
- [ ] Step 5: Commit `skills/verify/SKILL.md`.

---

### task-005: lib/checkpoint.sh - tag + rollback subcommands

**Goal:** Create an executable bash lib script with `tag <type>` and `rollback <tag>` subcommands that creates git tags and performs history-safe rollbacks.

**Files:**
- `lib/checkpoint.sh`

**read_first:**
- `lib/git-ops.sh` (git helper patterns: current-sha, slugify)
- `docs/loop-spec/features/resilience-ops/SPEC.md` (Checkpoint rollback section)

**Verify:** `test -x lib/checkpoint.sh && bash lib/checkpoint.sh 2>&1 | grep -c "tag\|rollback" | grep -qE '^[1-9]' && echo PASS`

**Acceptance criteria:**
- [ ] Script is executable with `set -euo pipefail`.
- [ ] `tag <type>` subcommand: creates a git tag `loop-spec-checkpoint-{type}-YYYYMMDD-HHMMSS` using `git tag`. Supports the 4 automatic types: `post-discuss`, `post-plan`, `post-execute`, `post-verify`, `pre-rollback`, `manual`.
- [ ] `rollback <tag>` subcommand: runs `git checkout <TAG> -- .` (NOT `git reset --hard`), then creates a new commit with message `chore: NO_JIRA rollback to <tag>`. Requires the caller to set `LOOP_SPEC_ROLLBACK_CONFIRMED=1` env var (instead of interactive confirmation which is not available in skill context).
- [ ] Usage/help text visible when called with no args or `--help` (enables the verify command grep).
- [ ] Script exits 1 on unknown subcommand with usage message.
- [ ] Script exits 0 on success.

**Steps (TDD):**

- [ ] Step 1: Write test asserting `bash lib/checkpoint.sh tag post-discuss` creates a git tag matching the expected format in a temp git repo.
- [ ] Step 2: Run test, expect FAIL.
- [ ] Step 3: Implement `lib/checkpoint.sh` following lib/git-ops.sh conventions (`set -euo pipefail`, function-based structure). Use `git tag "loop-spec-checkpoint-${type}-$(date +%Y%m%d-%H%M%S)"` for tagging. Use `git checkout "$tag" -- .` for rollback.
- [ ] Step 4: Run test, expect PASS.
- [ ] Step 5: Commit `lib/checkpoint.sh`.

---

### task-006: skills/rollback/SKILL.md - rollback skill document

**Goal:** Create a new skill that documents the /loop-spec:rollback command, all 6 checkpoint types, and the ROLLBACK confirmation requirement.

**Files:**
- `skills/rollback/SKILL.md`

**read_first:**
- `lib/checkpoint.sh` (what it does)
- `docs/loop-spec/features/resilience-ops/SPEC.md` (Checkpoint rollback section)

**blockedBy:** task-005

**Verify:** `grep -c "post-discuss\|post-plan\|post-execute\|post-verify\|pre-rollback\|manual" skills/rollback/SKILL.md | grep -qE '^[6-9]|^[1-9][0-9]' && echo PASS`

**Acceptance criteria:**
- [ ] File exists at `skills/rollback/SKILL.md` with YAML frontmatter.
- [ ] Documents all 6 checkpoint types (`post-discuss`, `post-plan`, `post-execute`, `post-verify`, `pre-rollback`, `manual`).
- [ ] Documents the typed "ROLLBACK" confirmation requirement (user must type ROLLBACK).
- [ ] Documents that rollback uses `git checkout TAG -- .` (not `git reset --hard`).
- [ ] Documents that rollback creates a new commit (history-safe).
- [ ] References `lib/checkpoint.sh` by name.

**Steps (no TDD - docs/skills task):**

- [ ] Step 1: Create `skills/rollback/` directory.
- [ ] Step 2: Write `skills/rollback/SKILL.md` with frontmatter and all required sections.
- [ ] Step 3: Run verify grep command, confirm 6+ matches.
- [ ] Step 4: Commit `skills/rollback/SKILL.md`.

---

### task-007: lib/ralph-remediation.sh - bash loop remediation executor

**Goal:** Create an executable bash lib script that runs a bash loop (max 5 iterations) dispatching Agent calls with single remediation tasks and checking for the COMPLETE signal.

**Files:**
- `lib/ralph-remediation.sh`

**read_first:**
- `/Users/cbobrowitz/Projects/_reference/ralph/ralph.sh` (loop structure, COMPLETE signal check)
- `lib/feature-write.sh` (reading feature.json for pending tasks)
- `docs/loop-spec/features/resilience-ops/SPEC.md` (Ralph remediation executor section)
- `docs/loop-spec/features/resilience-ops/PATTERNS.md` (Bash remediation loop concept - ralph.sh:84-108)

**Verify:** `test -x lib/ralph-remediation.sh && grep -c "COMPLETE\|max.*5\|iteration" lib/ralph-remediation.sh | grep -qE '^[1-9]' && echo PASS`

**Acceptance criteria:**
- [ ] Script is executable with `set -euo pipefail`.
- [ ] Accepts `<feature-dir>` as first argument.
- [ ] Reads `pendingRemediationTasks` from `feature.json` at `<feature-dir>/feature.json`.
- [ ] Exits 0 immediately if task count exceeds `LOOP_SPEC_RALPH_THRESHOLD` (default 3); caller routes to full EXECUTE team.
- [ ] For at or below threshold: runs a loop up to 5 iterations. Each iteration dispatches an Agent call with a single remediation task as the prompt and checks for `<promise>COMPLETE</promise>` in stdout.
- [ ] Exits 0 when all tasks complete; exits 1 when ceiling reached without all completing.
- [ ] Logs each iteration outcome (task, resolution status, iteration number) to `${TMPDIR:-/tmp}/ralph-remediation-${slug}.log`.
- [ ] Does NOT use `sleep` between iterations.
- [ ] No octopus emoji in any log output.

**Steps (TDD):**

- [ ] Step 1: Write test asserting `LOOP_SPEC_RALPH_THRESHOLD=3` + feature-dir with 4 pending tasks exits 0 immediately (above threshold). Also assert the script is executable.
- [ ] Step 2: Run test, expect FAIL.
- [ ] Step 3: Implement using the ralph.sh loop pattern (`for i in $(seq 1 $MAX_ITERATIONS)`), grep for COMPLETE signal. Replace raw `claude` CLI call with a placeholder `Agent({...})` comment (since this runs inside a skill, the actual dispatch is by the orchestrating skill, not a raw shell call). Add iteration log per the Exceptional criterion.
- [ ] Step 4: Run test, expect PASS.
- [ ] Step 5: Commit `lib/ralph-remediation.sh`.

---

### task-008: Phase skills - wire checkpoint.sh at phase completion

**Goal:** Edit the three non-verify phase skill files to call `lib/checkpoint.sh tag <type>` at their phase-completion step.

**Files:**
- `skills/discuss/SKILL.md`
- `skills/plan/SKILL.md`
- `skills/execute/SKILL.md`

**read_first:**
- `skills/discuss/SKILL.md` (find the phase-completion commit step)
- `skills/plan/SKILL.md` (find the phase-completion commit step)
- `skills/execute/SKILL.md` (find the phase-completion commit step)
- `lib/checkpoint.sh` (what the tag subcommand does)

**blockedBy:** task-005

**Verify:** `grep -l "checkpoint.sh" skills/discuss/SKILL.md skills/plan/SKILL.md skills/execute/SKILL.md skills/verify/SKILL.md | wc -l | tr -d ' ' | grep -q 4 && echo PASS`

**Acceptance criteria:**
- [ ] `skills/discuss/SKILL.md` contains a `bash lib/checkpoint.sh tag post-discuss` call after the `git commit SPEC.md` step.
- [ ] `skills/plan/SKILL.md` contains a `bash lib/checkpoint.sh tag post-plan` call after the `git commit PLAN.md` step.
- [ ] `skills/execute/SKILL.md` contains a `bash lib/checkpoint.sh tag post-execute` call after the final merge step (before setting `currentPhase = verify`).
- [ ] `skills/verify/SKILL.md` contains a `bash lib/checkpoint.sh tag post-verify` call (added as part of task-004 or here; verify grep counts 4 total).
- [ ] No other content in the skill files is modified.

**Steps (no TDD - skill markdown edit):**

- [ ] Step 1: Read each of the three skill files; identify the exact line after which to insert the checkpoint tag call.
- [ ] Step 2: Edit `skills/discuss/SKILL.md`: insert checkpoint tag call after `git commit SPEC.md`.
- [ ] Step 3: Edit `skills/plan/SKILL.md`: insert checkpoint tag call after `git commit PLAN.md`.
- [ ] Step 4: Edit `skills/execute/SKILL.md`: insert checkpoint tag call after final merge, before phase advance.
- [ ] Step 5: Run verify grep, confirm 4 files contain checkpoint.sh reference (includes task-004's verify edit).
- [ ] Step 6: Commit the three modified skill files.

---

### task-009: skills/forensics/SKILL.md - 7-pattern read-only diagnostic

**Goal:** Create a new skill that documents the /loop-spec:forensics read-only diagnostic, all 7 anomaly patterns, and the report path format.

**Files:**
- `skills/forensics/SKILL.md`

**read_first:**
- `skills/verify/SKILL.md` (read-only git scan pattern for marker detection, Step 1)
- `docs/loop-spec/features/resilience-ops/SPEC.md` (Forensics diagnostic section)

**Verify:** `grep -c "stuck loop\|missing artifact\|plan drift\|abandoned\|crash\|scope drift\|regression" skills/forensics/SKILL.md | grep -qE '^[7-9]|^[1-9][0-9]' && echo PASS`

**Acceptance criteria:**
- [ ] File exists at `skills/forensics/SKILL.md` with YAML frontmatter (`name: forensics`, `description`).
- [ ] Documents all 7 anomaly patterns: stuck loop, missing artifact, partial plan drift, abandoned work, crash or interruption, scope drift, test regression.
- [ ] Each pattern has a detection method described (what git/file check to run).
- [ ] Documents that the report is written to `.loop-spec/forensics/report-{ISO-8601}.md` and ONLY to that path.
- [ ] Documents that the skill makes no changes to any other file (read-only constraint).
- [ ] References the `forensics/report-` path format explicitly (for the Exceptional verify criterion).

**Steps (no TDD - docs/skills task):**

- [ ] Step 1: Create `skills/forensics/` directory.
- [ ] Step 2: Write `skills/forensics/SKILL.md` with all 7 patterns documented, each with detection method.
- [ ] Step 3: Run verify grep, confirm 7+ distinct pattern keyword matches.
- [ ] Step 4: Commit `skills/forensics/SKILL.md`.

---

### task-010: agents/loop-spec-spec-writer.md + SPEC.md.template - Boundaries + 2-tier success

**Goal:** Edit spec-writer agent to require Boundaries and 2-tier Success criteria sections, and update SPEC.md.template to include both sections.

**Files:**
- `agents/loop-spec-spec-writer.md`
- `skills/shared/artifact-templates/SPEC.md.template`

**read_first:**
- `agents/loop-spec-spec-writer.md` (full current content)
- `skills/shared/artifact-templates/SPEC.md.template` (full current content)
- `docs/loop-spec/features/resilience-ops/SPEC.md` (Intent contract section)

**Verify:** `grep -c "Boundaries\|Good Enough\|Exceptional" agents/loop-spec-spec-writer.md | grep -qE '^[3-9]|^[1-9][0-9]' && grep -c "Boundaries\|Good Enough\|Exceptional" skills/shared/artifact-templates/SPEC.md.template | grep -qE '^[3-9]|^[1-9][0-9]' && echo PASS`

**Acceptance criteria:**
- [ ] `agents/loop-spec-spec-writer.md` mentions `## Boundaries (what NOT to do)` as a required section.
- [ ] `agents/loop-spec-spec-writer.md` mentions `## Success criteria` with `### Good Enough` and `### Exceptional` as required subsections.
- [ ] `skills/shared/artifact-templates/SPEC.md.template` contains `## Boundaries` and both `### Good Enough` and `### Exceptional` sections.
- [ ] All additions are additive; no existing spec-writer role boundary or engineering principle is removed.
- [ ] No em-dash character appears in any modified line.

**Steps (no TDD - config/docs task):**

- [ ] Step 1: Read both files fully.
- [ ] Step 2: Edit `agents/loop-spec-spec-writer.md`: in the "Role boundary" section, add bullet requiring Boundaries section; in the "What NOT to do" section, add a bullet prohibiting omission of Success criteria tiers.
- [ ] Step 3: Edit `skills/shared/artifact-templates/SPEC.md.template`: add `## Boundaries (what NOT to do)` section after Non-goals, and expand `## Success criteria` into `### Good Enough` and `### Exceptional` subsections.
- [ ] Step 4: Run verify grep commands, confirm 3+ matches in each file.
- [ ] Step 5: Commit both files.

---

### task-011: Agent frontmatter - effort, disallowedTools, isolation + agents/README.md

**Goal:** Add `isolation: worktree` to implementer, `effort:` to implementer/verifier/planner, `disallowedTools:` to implementer, and create agents/README.md documenting all three new fields.

**Files:**
- `agents/loop-spec-implementer.md`
- `agents/loop-spec-verifier.md`
- `agents/loop-spec-planner.md`
- `agents/README.md`

**read_first:**
- `agents/loop-spec-implementer.md` (full current frontmatter)
- `agents/loop-spec-verifier.md` (frontmatter)
- `agents/loop-spec-planner.md` (frontmatter)
- `tests/validate-agents.sh` (validate field constraints so additions do not break the test)
- `docs/loop-spec/features/resilience-ops/SPEC.md` (Agent frontmatter section)

**Verify:** `grep -rl "effort:" agents/ | wc -l | tr -d ' ' | grep -qE '^[3-9]|^[1-9][0-9]' && grep -rl "disallowedTools:" agents/ | wc -l | tr -d ' ' | grep -qE '^[1-9]' && grep -c "isolation: worktree" agents/loop-spec-implementer.md | grep -qE '^[1-9]' && test -f agents/README.md && echo PASS`

**Acceptance criteria:**
- [ ] `agents/loop-spec-implementer.md` frontmatter gains `isolation: worktree`, `effort: high`, and `disallowedTools:` list (at minimum: `Push`, `CreatePullRequest`, or their equivalents to match the implementer's documented constraints).
- [ ] `agents/loop-spec-verifier.md` frontmatter gains `effort: medium`.
- [ ] `agents/loop-spec-planner.md` frontmatter gains `effort: medium`.
- [ ] `agents/README.md` exists and documents `effort:` (enum: low/medium/high/xhigh/max), `disallowedTools:` (purpose: block destructive tools), and `isolation:` (purpose: run in git worktree).
- [ ] `bash tests/validate-agents.sh` still exits 0 (new fields do not conflict with forbidden key checks for `skills:` and `mcpServers:`).
- [ ] All additions are additive; no existing required frontmatter field is modified.

**Steps (no TDD - config/docs task):**

- [ ] Step 1: Read all three agent files and validate-agents.sh to confirm new fields will not trigger false failures.
- [ ] Step 2: Edit `agents/loop-spec-implementer.md` frontmatter: add `isolation: worktree`, `effort: high`, `disallowedTools: [Push]` (use whatever tool name the CC harness recognizes for git push; document the assumption).
- [ ] Step 3: Edit `agents/loop-spec-verifier.md` frontmatter: add `effort: medium`.
- [ ] Step 4: Edit `agents/loop-spec-planner.md` frontmatter: add `effort: medium`.
- [ ] Step 5: Create `agents/README.md` documenting all three fields with their valid values and semantics.
- [ ] Step 6: Run `bash tests/validate-agents.sh` and confirm exit 0.
- [ ] Step 7: Commit all four files.

---

### task-012: hooks/team/discipline-inject.sh + discipline-inject.test.sh + skills/discipline/SKILL.md

**Goal:** Create the SessionStart discipline hook, its companion test, and the discipline slash-command skill.

**Files:**
- `hooks/team/discipline-inject.sh`
- `hooks/team/discipline-inject.test.sh`
- `skills/discipline/SKILL.md`

**read_first:**
- `/Users/cbobrowitz/Projects/_reference/claude-octopus/hooks/discipline-inject.sh` (reference implementation)
- `hooks/team/stop-deflection-guard.sh:27-43` (kill-switch + fail-open pattern)
- `hooks/team/strategy-rotation.sh:48-49` (session ID for state file)
- `docs/loop-spec/features/resilience-ops/SPEC.md` (Discipline-mode section)
- `docs/loop-spec/features/resilience-ops/PATTERNS.md` (Conf-file-driven feature toggle concept)

**Verify:** `bash hooks/team/discipline-inject.test.sh`

**Acceptance criteria:**
- [ ] `hooks/team/discipline-inject.sh` is executable with `set -euo pipefail`.
- [ ] Reads `.loop-spec/discipline.conf` in `CLAUDE_PROJECT_DIR` (or CWD if env var absent); if file absent or `ENABLED=1` not present, exits 0 with `{}` (no injection).
- [ ] When `ENABLED=1`, outputs `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"..."}}` with all 5 behavioral gates listed (brainstorm-before-coding, verification-before-claims, investigation-before-fixes, decision-gate, intent-gate).
- [ ] Kill switch: `LOOP_SPEC_DISCIPLINE=0` exits 0 with `{}` before reading conf file.
- [ ] Fail-open: `trap 'exit 0' ERR`.
- [ ] No emoji in the injected directive text.
- [ ] `discipline-inject.test.sh` has at least 3 test cases: "enabled inject" (conf file with ENABLED=1 produces additionalContext), "kill switch" (LOOP_SPEC_DISCIPLINE=0 exits 0 with no context), "file absent" (no conf file exits 0 with no context).
- [ ] `skills/discipline/SKILL.md` exists with frontmatter and documents `on`, `off`, and `status` subcommands that write/update `.loop-spec/discipline.conf`.
- [ ] grep -c "on\|off\|status" `skills/discipline/SKILL.md` returns 3 or more.

**Steps (TDD):**

- [ ] Step 1: Write `discipline-inject.test.sh` with the 3 test cases; run it, expect FAIL (hook does not exist).
- [ ] Step 2: Implement `hooks/team/discipline-inject.sh` using the kill-switch + fail-open pattern from `hooks/team/stop-deflection-guard.sh:27-43` and conf-file check from the octopus reference. Use `LOOP_SPEC_DISCIPLINE` as the kill switch var. Read conf from `${CLAUDE_PROJECT_DIR:-.}/.loop-spec/discipline.conf`. Escape the directive for JSON using `printf '%s' "$DIRECTIVE" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' '`.
- [ ] Step 3: Run test suite, expect PASS.
- [ ] Step 4: Create `skills/discipline/SKILL.md` with frontmatter and on/off/status subcommand documentation.
- [ ] Step 5: Commit all three files.

---

### task-013: hooks/team/output-compressor.sh + output-compressor.test.sh

**Goal:** Create the PostToolUse output compressor hook and its companion test.

**Files:**
- `hooks/team/output-compressor.sh`
- `hooks/team/output-compressor.test.sh`

**read_first:**
- `/Users/cbobrowitz/Projects/_reference/claude-octopus/hooks/output-compressor.sh` (reference implementation)
- `hooks/team/stop-deflection-guard.sh:27-43` (kill-switch + fail-open pattern)
- `hooks/team/strategy-rotation.sh:48-49` (session ID pattern for debounce file)
- `docs/loop-spec/features/resilience-ops/SPEC.md` (Output compressor section)
- `docs/loop-spec/features/resilience-ops/PATTERNS.md` (Per-session temp-file state concept + additionalContext injection concept)

**Verify:** `bash hooks/team/output-compressor.test.sh`

**Acceptance criteria:**
- [ ] `hooks/team/output-compressor.sh` is executable with `set -euo pipefail`.
- [ ] Fires on PostToolUse; reads tool output JSON from stdin.
- [ ] Kill switch: `LOOP_SPEC_COMPRESSOR=0` exits 0 immediately.
- [ ] Fail-open: `trap 'exit 0' ERR`.
- [ ] Threshold: 3000 chars (hard-coded constant, not configurable per SPEC out-of-scope).
- [ ] Debounce: fires on every 3rd qualifying call. State persisted in `${TMPDIR:-/tmp}/loop-spec-compress-${SESSION}.count` where `SESSION="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-$$}}"`.
- [ ] Shape detection:
  - JSON array: first 2 + last 2 elements + count.
  - JSON object: first 15 keys + count.
  - HTML (detected by `<html` or `<!doctype` in first 5 lines): strip tags, retain first 30 lines.
  - Log/verbose (40+ lines): head 15 + tail 15 lines.
- [ ] Outputs `{"decision":"continue","additionalContext":"<summary>"}` when compression applied; exits 0 with no output otherwise.
- [ ] No analytics file write (omit octopus analytics; not in SPEC scope).
- [ ] No emoji in output.
- [ ] `output-compressor.test.sh` covers: "threshold trigger" (output >= 3000 chars compresses), "JSON array" (correct shape), "kill switch" (LOOP_SPEC_COMPRESSOR=0 exits 0 silently), "fail-open" (malformed JSON exits 0).
- [ ] For the Exceptional criterion: "debounce every 3rd call" test case also passes.

**Steps (TDD):**

- [ ] Step 1: Write `output-compressor.test.sh` with the 4 required cases (plus debounce case for Exceptional). Run, expect FAIL.
- [ ] Step 2: Implement `hooks/team/output-compressor.sh` adapting the octopus reference. Replace `OCTOPUS_COMPRESS_ENABLED` with `LOOP_SPEC_COMPRESSOR`. Use `${TMPDIR:-/tmp}` (not `/tmp`). Remove analytics file write. Remove emoji from summary string. Match the 3000-char threshold exactly.
- [ ] Step 3: Run test suite, expect PASS.
- [ ] Step 4: Commit both files.

---

### task-014: hooks/team/done-criteria.sh + done-criteria.test.sh

**Goal:** Create the UserPromptSubmit compound-task detection hook and its companion test.

**Files:**
- `hooks/team/done-criteria.sh`
- `hooks/team/done-criteria.test.sh`

**read_first:**
- `/Users/cbobrowitz/Projects/_reference/claude-octopus/hooks/done-criteria.sh` (reference implementation)
- `hooks/team/stop-deflection-guard.sh:27-43` (kill-switch + fail-open pattern)
- `docs/loop-spec/features/resilience-ops/SPEC.md` (Done-criteria detector section)
- `docs/loop-spec/features/resilience-ops/PATTERNS.md` (Compound task detection heuristics concept)

**Verify:** `bash hooks/team/done-criteria.test.sh`

**Acceptance criteria:**
- [ ] `hooks/team/done-criteria.sh` is executable with `set -euo pipefail`.
- [ ] Kill switch: `LOOP_SPEC_DONE_CRITERIA=0` exits 0 immediately.
- [ ] Fail-open: `trap 'exit 0' ERR`.
- [ ] Extracts user prompt from UserPromptSubmit JSON payload via python3 inline (field: `prompt` or `message`).
- [ ] Compound detection heuristics:
  1. Numbered lists (two or more `1.` / `2.` / `1)` patterns in the prompt).
  2. Multi-verb prompts: action verb + `and|then|also` + action verb.
  3. Bullet lists: 2 or more lines starting with `- ` or `* `.
- [ ] On detection, outputs: `{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"Enumerate completion criteria explicitly before starting. Verify each before declaring done."}}`.
- [ ] No detection: exits 0 with no output.
- [ ] No emoji in the injected directive.
- [ ] `done-criteria.test.sh` covers: "numbered list", "multi-verb and", "bullet list", "kill switch", "fail-open" (all 5 cases from the SPEC verify command).

**Steps (TDD):**

- [ ] Step 1: Write `done-criteria.test.sh` with all 5 cases. Run, expect FAIL.
- [ ] Step 2: Implement `hooks/team/done-criteria.sh` adapting the octopus reference. Replace `OCTO_DONE_CRITERIA` kill switch with `LOOP_SPEC_DONE_CRITERIA`. Replace emoji in directive with plain text. Use `python3` for prompt extraction, falling back to grep. Match the three heuristics exactly as specified.
- [ ] Step 3: Run test suite, expect PASS.
- [ ] Step 4: Commit both files.

---

### task-015: hooks/team/session-end-learnings.sh + session-end-learnings.test.sh

**Goal:** Create the Stop/SessionEnd hook that appends JSONL learnings and its companion test.

**Files:**
- `hooks/team/session-end-learnings.sh`
- `hooks/team/session-end-learnings.test.sh`

**read_first:**
- `/Users/cbobrowitz/Projects/_reference/claude-octopus/hooks/session-end.sh:118-191` (learnings pattern, FIFO cap)
- `hooks/team/stop-deflection-guard.sh:27-43` (kill-switch + fail-open pattern)
- `docs/loop-spec/features/resilience-ops/SPEC.md` (Session-end learnings section)
- `docs/loop-spec/features/resilience-ops/PATTERNS.md` (JSONL append with FIFO cap concept)

**Verify:** `bash hooks/team/session-end-learnings.test.sh`

**Acceptance criteria:**
- [ ] `hooks/team/session-end-learnings.sh` is executable with `set -euo pipefail`.
- [ ] Kill switch: `LOOP_SPEC_LEARNINGS=0` exits 0 immediately.
- [ ] Fail-open: `trap 'exit 0' ERR`.
- [ ] Appends a JSONL line to `.loop-spec/learnings.jsonl` (relative to `CLAUDE_PROJECT_DIR` or CWD). Line schema: `{"timestamp":"...","sessionId":"...","taskType":"...","approach":"...","outcome":"...","lesson":"..."}`.
- [ ] Heuristic lesson generation: agent count > 3 produces `lesson: "parallel dispatch effective"`; any errors logged produces `lesson: "partial outcome"`. Both signals can combine (use first match that applies).
- [ ] FIFO cap: after append, if file exceeds 50 lines, trim to last 50 lines using `tail -n 50` rewrite (per PATTERNS.md JSONL cap gotcha).
- [ ] Creates `.loop-spec/` directory if absent.
- [ ] `session-end-learnings.test.sh` covers: "append" (valid JSONL line appended), "cap at 50" (file trimmed to 50 lines when over 50), "kill switch" (LOOP_SPEC_LEARNINGS=0 exits 0, file untouched).
- [ ] For Exceptional: "heuristic lessons" test case also passes (>3 agents -> specific lesson text).

**Steps (TDD):**

- [ ] Step 1: Write `session-end-learnings.test.sh` with the 3 required cases (plus heuristic case for Exceptional). Run, expect FAIL.
- [ ] Step 2: Implement `hooks/team/session-end-learnings.sh`. Session ID: `SESSION="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-$$}}"`. Agent count and error signals: parse from hook payload stdin via python3 inline (field paths TBD by payload shape; fail-open if absent). Build JSONL line with jq or python3. Append via `printf '%s\n' "$LINE" >> "$LEARNINGS_FILE"`. Cap via `tail -n 50` rewrite per PATTERNS.md.
- [ ] Step 3: Run test suite, expect PASS.
- [ ] Step 4: Commit both files.

---

### task-016: hooks/hooks.json - wire all four new hooks

**Goal:** Add entries for discipline-inject (SessionStart), output-compressor (PostToolUse), done-criteria (UserPromptSubmit), and session-end-learnings (Stop) to hooks.json.

**Files:**
- `hooks/hooks.json`

**read_first:**
- `hooks/hooks.json` (full current content)
- `docs/loop-spec/features/resilience-ops/SPEC.md` (hooks.json wiring success criterion)

**blockedBy:** task-012, task-013, task-014, task-015

**Verify:** `jq '[.hooks | to_entries[] | .value[] | .command] | map(select(test("discipline-inject|output-compressor|done-criteria|session-end-learnings"))) | length' hooks/hooks.json | grep -qE '^[4-9]|^[1-9][0-9]' && echo PASS`

**Acceptance criteria:**
- [ ] `SessionStart` event key added with `discipline-inject.sh` entry.
- [ ] `PostToolUse` entry for `Bash|Read|Grep` matcher added with `output-compressor.sh` (separate from existing `Bash|Edit|Write` matcher for strategy-rotation).
- [ ] `UserPromptSubmit` event key added with `done-criteria.sh` entry.
- [ ] `Stop` event gains a new entry for `session-end-learnings.sh` (alongside existing stop hooks).
- [ ] All new entries use `${CLAUDE_PLUGIN_ROOT}/hooks/team/<name>.sh` path convention.
- [ ] Existing entries are not modified or removed.
- [ ] JSON is valid (`jq . hooks/hooks.json` exits 0).

**Steps (no TDD - config task):**

- [ ] Step 1: Read full `hooks/hooks.json`.
- [ ] Step 2: Add `SessionStart` key with discipline-inject entry.
- [ ] Step 3: Add PostToolUse `Bash|Read|Grep` matcher entry with output-compressor.
- [ ] Step 4: Add `UserPromptSubmit` key with done-criteria entry.
- [ ] Step 5: Add session-end-learnings to existing `Stop` array.
- [ ] Step 6: Run `jq . hooks/hooks.json > /dev/null && echo valid` to confirm JSON validity.
- [ ] Step 7: Run verify jq command, confirm 4+ matches.
- [ ] Step 8: Commit `hooks/hooks.json`.

---

### task-017: tests/run-all.sh + CHANGELOG.md - integrate new suites and document all 11 items

**Goal:** Add the four new hook test suites to tests/run-all.sh and write CHANGELOG entries for all 11 resilience-ops items.

**Files:**
- `tests/run-all.sh`
- `CHANGELOG.md`

**read_first:**
- `tests/run-all.sh` (full current content)
- `CHANGELOG.md` (first 30 lines for format reference)
- `docs/loop-spec/features/resilience-ops/SPEC.md` (all 11 success criteria for changelog text)

**blockedBy:** task-012, task-013, task-014, task-015, task-016

**Verify:** `bash tests/run-all.sh && grep -c "pause\|forensics\|regression.*gate\|rollback\|ralph\|intent.*contract\|discipline\|compressor\|done-criteria\|learnings\|frontmatter" CHANGELOG.md | grep -qE '^1[1-9]|^[2-9][0-9]' && echo PASS`

**Acceptance criteria:**
- [ ] `tests/run-all.sh` includes `run_suite` calls for:
  - `hooks/team/discipline-inject` running `bash hooks/team/discipline-inject.test.sh`
  - `hooks/team/output-compressor` running `bash hooks/team/output-compressor.test.sh`
  - `hooks/team/done-criteria` running `bash hooks/team/done-criteria.test.sh`
  - `hooks/team/session-end-learnings` running `bash hooks/team/session-end-learnings.test.sh`
- [ ] `bash tests/run-all.sh` exits 0 with all suites passing.
- [ ] `CHANGELOG.md` [Unreleased] section contains entries covering all 11 items: pause, forensics, regression gate, checkpoint rollback, Ralph executor, intent contract (Boundaries + 2-tier success), discipline hook, output compressor, done-criteria hook, session learnings, agent frontmatter.
- [ ] No em-dash in any new CHANGELOG text.

**Steps (no TDD - config/docs task):**

- [ ] Step 1: Read `tests/run-all.sh` fully.
- [ ] Step 2: Add four `run_suite` calls for the new test suites, following the existing naming pattern.
- [ ] Step 3: Run `bash tests/run-all.sh` and confirm exit 0 (all new test suites must pass).
- [ ] Step 4: Read CHANGELOG.md header for format reference.
- [ ] Step 5: Add 11 `### Added` entries under `## [Unreleased]`, one per deliverable. Match the existing CHANGELOG prose style (no em-dash, imperative verb, file paths in backticks).
- [ ] Step 6: Run verify grep on CHANGELOG.md, confirm 11+ matches.
- [ ] Step 7: Commit `tests/run-all.sh` and `CHANGELOG.md`.

---

## Test strategy

- All bash lib scripts have companion unit tests (task-001, task-003, task-005, task-007 via TDD).
- All new hooks have companion `.test.sh` files (task-012 through task-015 via TDD).
- Final integration: `bash tests/run-all.sh` (task-017) gates the overall feature.
- `bash tests/validate-agents.sh` confirms agent count stays at 12 and new frontmatter fields do not break schema validation.

## Rollback plan

Each task produces a discrete commit. If VERIFY fails, `git log --oneline` to identify the offending commit(s) and `git revert <sha>` each one. The checkpoint tagging added in task-005/task-008 provides a `loop-spec-checkpoint-post-plan-*` tag to roll back to if needed.
