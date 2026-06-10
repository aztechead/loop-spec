# Planner + EXECUTE Discipline Hardening - Implementation Plan

**Spec:** `docs/super-spec/features/planner-execute-discipline/SPEC.md`
**Created:** 2026-05-28

## Architecture overview

Six enforcement additions land in three layers: (1) agent-prompt rules and docs, (2) three new `lib/` helper scripts, and (3) two new `hooks/team/` scripts wired into `hooks/hooks.json`. Two existing skill files (`skills/plan/SKILL.md` and `skills/execute/SKILL.md`) are amended to invoke the helpers at the appropriate phase gates. No existing hooks are removed or modified.

## Assumptions

- `lib/decision-coverage.sh` is a pure parser/comparator: it reads the spec and plan files, outputs `{"covered": true/false, "uncovered": [...]}` to stdout, exits 0 on full coverage and 1 on any gap. The lead's skill prose handles the tier-conditional branching (advisory vs. blocking); the script itself is tier-agnostic.
- `lib/plan-adherence.sh` is also a pure parser: it reads PLAN.md and outputs `{"plan_task_ids": [...], "gap_message": "..." | null}`. The lead compares its output against the harness `TaskList` inline in the skill. The script does not call the harness.
- `lib/detect-test-cmd.sh` probes for `Makefile`, `package.json`, `Cargo.toml`, `pyproject.toml`, `setup.py`, `go.mod` in that priority order and prints the first matching test command string. It prints nothing (empty string) and exits 0 when no recognizable test file is found.
- `hooks/team/strategy-rotation.sh` reads `tool_name` and failure status from hook stdin (PostToolUse payload). It uses `CLAUDE_CODE_SESSION_ID` then `CLAUDE_SESSION_ID` then `$$` as the session key. State file path: `/tmp/super-spec-failures-${SESSION}.json`.
- `hooks/team/budget-gate.sh` reads cost from `metrics-session.json` (field `.totals.estimated_cost_usd`) if the file exists at the current working directory, then falls back to `SUPER_SPEC_CURRENT_COST_USD`. If neither is present, it exits 0 unconditionally.
- `validate-agents.sh` already reads `EXPECTED=12` from the environment (confirmed by reading the file). No agent files are added or removed, so that count stays 12.
- `tests/run-all.sh` will be extended to run the two new `.test.sh` files. The task that writes the test files also updates `run-all.sh`.

## File map

- Create: `lib/decision-coverage.sh` - parses `<decisions>` block from SPEC and checks coverage in PLAN
- Create: `lib/plan-adherence.sh` - extracts `### task-NNN:` IDs from PLAN.md and emits JSON
- Create: `lib/detect-test-cmd.sh` - probes for known test-file markers and prints test command
- Create: `hooks/team/strategy-rotation.sh` - PostToolUse hook tracking consecutive tool failures
- Create: `hooks/team/strategy-rotation.test.sh` - unit tests for strategy-rotation.sh
- Create: `hooks/team/budget-gate.sh` - PreToolUse hook gating Agent calls against cost ceiling
- Create: `hooks/team/budget-gate.test.sh` - unit tests for budget-gate.sh
- Create: `docs/super-spec/planner-antipatterns.md` - do/don't reference for planner acceptance criteria
- Modify: `agents/super-spec-planner.md` - add BANNED PHRASES section + read_first[] requirement
- Modify: `agents/super-spec-spec-writer.md` - require `<decisions>` block in SPEC.md output
- Modify: `skills/shared/artifact-templates/PLAN.md.template` - add read_first: field + checkbox AC format
- Modify: `skills/plan/SKILL.md` - insert decision-coverage gate before Step 5 commit
- Modify: `skills/execute/SKILL.md` - insert plan-adherence gate in Step 10 + post-merge test gate in Step 8
- Modify: `hooks/hooks.json` - wire budget-gate (PreToolUse:Agent) and strategy-rotation (PostToolUse:Bash|Edit|Write)
- Modify: `tests/run-all.sh` - add strategy-rotation and budget-gate test suites
- Modify: `CHANGELOG.md` - document all six additions under [Unreleased]

## Task DAG

| ID | Subject | BlockedBy | Files | Est scope |
|----|---------|-----------|-------|-----------|
| task-001 | anti-shallow planner rules and template update | - | agents/super-spec-planner.md, skills/shared/artifact-templates/PLAN.md.template, docs/super-spec/planner-antipatterns.md | medium |
| task-002 | spec-writer decisions-block requirement | - | agents/super-spec-spec-writer.md | small |
| task-003 | lib/decision-coverage.sh with unit test | - | lib/decision-coverage.sh, tests/lib/decision-coverage.test.sh | medium |
| task-004 | lib/plan-adherence.sh with unit test | - | lib/plan-adherence.sh, tests/lib/plan-adherence.test.sh | medium |
| task-005 | lib/detect-test-cmd.sh with unit test | - | lib/detect-test-cmd.sh, tests/lib/detect-test-cmd.test.sh | small |
| task-006 | skills/plan/SKILL.md decision-coverage gate | task-003 | skills/plan/SKILL.md | small |
| task-007 | skills/execute/SKILL.md plan-adherence + post-merge test gate | task-004, task-005 | skills/execute/SKILL.md | medium |
| task-008 | hooks/team/strategy-rotation.sh | - | hooks/team/strategy-rotation.sh, hooks/team/strategy-rotation.test.sh | medium |
| task-009 | hooks/team/budget-gate.sh | - | hooks/team/budget-gate.sh, hooks/team/budget-gate.test.sh | medium |
| task-010 | hooks/hooks.json wiring | task-008, task-009 | hooks/hooks.json | small |
| task-011 | run-all.sh integration + CHANGELOG | task-003, task-004, task-005, task-008, task-009 | tests/run-all.sh, CHANGELOG.md | small |

## Tasks

---

### task-001: anti-shallow planner rules and template update

**Goal:** Add a BANNED PHRASES section and REQUIRED CONCRETE FORM rule to the planner agent, add a mandatory `read_first:` field requirement, update the PLAN.md template to reflect these fields, and create the antipatterns reference doc.

**Files:**
- `agents/super-spec-planner.md`
- `skills/shared/artifact-templates/PLAN.md.template`
- `docs/super-spec/planner-antipatterns.md`

**read_first:**
- `agents/super-spec-planner.md`
- `skills/shared/artifact-templates/PLAN.md.template`
- `docs/super-spec/features/planner-execute-discipline/SPEC.md` (section "User-facing behavior", first paragraph)

**Verify:** `grep -c "read_first" agents/super-spec-planner.md` returns 1 or more; `grep -A 10 "BANNED\|MUST NOT" agents/super-spec-planner.md | grep -c "looks correct\|properly configured"` returns 1 or more; `grep -c "read_first:\|- \[ \]" skills/shared/artifact-templates/PLAN.md.template` returns 2 or more; `grep -c "DO NOT\|BAD\|GOOD\|Instead\|instead" docs/super-spec/planner-antipatterns.md` returns 1 or more; `grep -rP "\xe2\x80\x94" agents/super-spec-planner.md docs/super-spec/planner-antipatterns.md skills/shared/artifact-templates/PLAN.md.template` exits 1 (no matches).

**Acceptance criteria:**
- [ ] `agents/super-spec-planner.md` gains a section titled "BANNED PHRASES" or "MUST NOT appear in acceptance criteria" that explicitly lists "looks correct", "properly configured", "consistent with", "align X with Y", "matches Y", and "well-formed" (without a schema reference).
- [ ] `agents/super-spec-planner.md` gains a section titled "REQUIRED CONCRETE FORM" or equivalent that states every acceptance criterion must contain at least one of: an exact value, a regex pattern, an exit code, a file path, a grep command, or a JSON path expression.
- [ ] `agents/super-spec-planner.md` states that every task must include a `read_first:` field (empty list is allowed) containing concrete file identifiers.
- [ ] `skills/shared/artifact-templates/PLAN.md.template` includes a `read_first:` line in the per-task section.
- [ ] `skills/shared/artifact-templates/PLAN.md.template` acceptance criteria are formatted as `- [ ] {criterion}` (checkbox markdown).
- [ ] `docs/super-spec/planner-antipatterns.md` exists and contains at least 3 do/don't pairs illustrating banned vs. required forms (e.g., "looks correct" vs. "`grep -c 'pattern' file` returns 1").
- [ ] No em-dash (U+2014) appears in any of the three modified/created files.

**Steps (TDD where applicable):**

This task modifies prose files only (agent prompt, template, reference doc). TDD ordering does not apply to prose-only tasks.

- [ ] Step 1: Read `agents/super-spec-planner.md` fully. Identify the "Role boundary" and "What NOT to do" sections as insertion points.
- [ ] Step 2: Edit `agents/super-spec-planner.md` to add the BANNED PHRASES section (after "Role boundary") and the REQUIRED CONCRETE FORM rule (after BANNED PHRASES). Add the `read_first:` field requirement to the per-task field list in "Role boundary".
- [ ] Step 3: Read `skills/shared/artifact-templates/PLAN.md.template` fully. Identify the per-task block.
- [ ] Step 4: Edit the template to add `read_first:` field and convert acceptance criteria to checkbox format. Preserve all other template content exactly.
- [ ] Step 5: Write `docs/super-spec/planner-antipatterns.md` with at least 6 do/don't pairs (one per banned phrase). Structure as a flat markdown doc with `## DO NOT` and `## DO` subsections or a paired table.
- [ ] Step 6: Verify grep commands from the "Verify" field all return expected values.
- [ ] Step 7: Commit.

---

### task-002: spec-writer decisions-block requirement

**Goal:** Update `agents/super-spec-spec-writer.md` to require that SPEC.md output includes a `<decisions>` XML block.

**Files:**
- `agents/super-spec-spec-writer.md`

**read_first:**
- `agents/super-spec-spec-writer.md`
- `docs/super-spec/features/planner-execute-discipline/SPEC.md` (the `<decisions>` block in that file itself serves as the canonical example)

**Verify:** `grep -c "<decisions>" agents/super-spec-spec-writer.md` returns 1 or more; `grep -rP "\xe2\x80\x94" agents/super-spec-spec-writer.md` exits 1 (no matches).

**Acceptance criteria:**
- [ ] `agents/super-spec-spec-writer.md` contains the string `<decisions>` in at least one location that binds it as a required output section (not just a passing reference).
- [ ] The requirement states that each entry in the `<decisions>` block documents a single binding design choice made during the DISCUSS phase.
- [ ] Existing role boundary and "What NOT to do" sections are preserved without structural change.
- [ ] No em-dash (U+2014) in the file.

**Steps:**

- [ ] Step 1: Read `agents/super-spec-spec-writer.md`.
- [ ] Step 2: Identify the "Output" section (currently describes only the SPEC.md file path). Add a note that the `<decisions>` block is required: each entry in the block records one binding design decision made during DISCUSS.
- [ ] Step 3: Add `<decisions>` to the "What NOT to do" section's negative example (DO NOT omit the `<decisions>` block).
- [ ] Step 4: Run `grep -c "<decisions>" agents/super-spec-spec-writer.md` and confirm result >= 1.
- [ ] Step 5: Commit.

---

### task-003: lib/decision-coverage.sh with unit test

**Goal:** Create `lib/decision-coverage.sh` and its test suite. The script reads a SPEC file path and a PLAN file path, extracts entries from the `<decisions>` block, and checks whether each appears (verbatim or by keyword) in the PLAN body.

**Files:**
- `lib/decision-coverage.sh`
- `tests/lib/decision-coverage.test.sh`

**read_first:**
- `lib/gsd-ingest.sh` (file-existence probe + output pattern analog; apply pattern from PATTERNS.md "Bash lib helper" concept)
- `lib/feature-write.sh` (jq guard pattern)
- `tests/lib/gsd-ingest.test.sh` (check() helper + process-substitution test pattern)
- `docs/super-spec/features/planner-execute-discipline/SPEC.md` (Success criteria lines 94-101 for exact verify invocations)

**Verify:** `bash tests/lib/decision-coverage.test.sh`; `echo $?` returns 0.

**Acceptance criteria:**
- [ ] `lib/decision-coverage.sh` is executable (`chmod +x`) and has `#!/usr/bin/env bash` shebang.
- [ ] When all `<decisions>` entries appear in PLAN, the script exits 0 and prints nothing (or a success line).
- [ ] `bash lib/decision-coverage.sh <(printf '<decisions>\n- Decision: use bash\n</decisions>') <(printf 'use bash in task'); echo $?` prints `0`.
- [ ] When at least one `<decisions>` entry is absent from PLAN, the script exits 1 and prints a non-empty uncovered-decisions list to stdout.
- [ ] `bash lib/decision-coverage.sh <(printf '<decisions>\n- Decision: use python\n</decisions>') <(printf 'no python here'); echo $?` prints `1` and a non-empty uncovered list.
- [ ] When the SPEC has no `<decisions>` block, the script exits 0 with a "skipped" indicator.
- [ ] The script uses POSIX-compatible grep (`grep -E` with `[0-9]` not `\d`).
- [ ] `bash tests/lib/decision-coverage.test.sh` exits 0 with all cases passing. Test cases must include: all-covered (exit 0), one-uncovered (exit 1), no-decisions-block (exit 0 skipped), missing-spec-file (exit 0 fail-open).
- [ ] No em-dash in either file.

**Steps (TDD):**

- [ ] Step 1: Write `tests/lib/decision-coverage.test.sh` with at least 4 cases (all-covered, one-uncovered, no-decisions-block, missing-file). Use the `check()` helper pattern from `tests/lib/gsd-ingest.test.sh:14-28`. Cases call `bash lib/decision-coverage.sh` -- the script does not exist yet, so all cases will FAIL at this point.
- [ ] Step 2: Run `bash tests/lib/decision-coverage.test.sh`. Confirm all cases FAIL (file not found).
- [ ] Step 3: Implement `lib/decision-coverage.sh`. Apply the bash lib helper + awk extraction pattern from PATTERNS.md. Use `awk '/<decisions>/,/<\/decisions>/'` to extract the block, `grep -v` to strip delimiters, then loop over each entry checking for presence in the plan file using `grep -qF` (fixed-string, case-sensitive).
- [ ] Step 4: Run `bash tests/lib/decision-coverage.test.sh`. All cases must PASS.
- [ ] Step 5: Run the exact verify commands from the SPEC success criteria (lines 94-101) and confirm exit codes match expectations.
- [ ] Step 6: Commit.

---

### task-004: lib/plan-adherence.sh with unit test

**Goal:** Create `lib/plan-adherence.sh` that parses every `### task-NNN:` heading in PLAN.md and emits a JSON object with `plan_task_ids` array and `gap_message` string or null.

**Files:**
- `lib/plan-adherence.sh`
- `tests/lib/plan-adherence.test.sh`

**read_first:**
- `lib/gsd-ingest.sh` (output-to-JSON pattern)
- `tests/lib/gsd-ingest.test.sh` (check() + heredoc test input pattern)
- `docs/super-spec/features/planner-execute-discipline/SPEC.md` (Success criteria line 106: exact verify invocation using `/dev/stdin` heredoc)

**Verify:** `bash tests/lib/plan-adherence.test.sh`; `echo $?` returns 0.

**Acceptance criteria:**
- [ ] `lib/plan-adherence.sh` is executable and has `#!/usr/bin/env bash` shebang.
- [ ] `bash lib/plan-adherence.sh /dev/stdin <<< '### task-001: do a thing' | jq '.plan_task_ids | length'` returns `1`.
- [ ] Output JSON always includes both `plan_task_ids` (array of strings) and `gap_message` (string or null) keys.
- [ ] When the PLAN has no matching headings, `plan_task_ids` is `[]` and `gap_message` is null.
- [ ] The script accepts a file path argument (not stdin-only) and also supports `/dev/stdin` as argument.
- [ ] `bash tests/lib/plan-adherence.test.sh` exits 0. Test cases include: single task, multiple tasks, no tasks, invalid-file (fail-open).
- [ ] No em-dash in either file.

**Steps (TDD):**

- [ ] Step 1: Write `tests/lib/plan-adherence.test.sh` with at least 4 cases. Each case pipes PLAN content via heredoc or process substitution and checks `jq '.plan_task_ids | length'` and `.gap_message` values. Script does not exist yet -- cases FAIL.
- [ ] Step 2: Run `bash tests/lib/plan-adherence.test.sh`. Confirm FAIL.
- [ ] Step 3: Implement `lib/plan-adherence.sh`. Use `grep -E '^### task-[0-9]+:' "$1"` to extract headings. Pipe through `sed 's/^### //' | cut -d: -f1` to get IDs. Build JSON using `jq -n` with `--argjson` injection or a python3 one-liner. Exit 0 always (fail-open for missing file).
- [ ] Step 4: Run tests. All PASS.
- [ ] Step 5: Confirm exact verify command from SPEC line 106 returns `1`.
- [ ] Step 6: Commit.

---

### task-005: lib/detect-test-cmd.sh with unit test

**Goal:** Create `lib/detect-test-cmd.sh` that probes the current directory for known test-file markers and prints a test command string (or empty string) then exits 0.

**Files:**
- `lib/detect-test-cmd.sh`
- `tests/lib/detect-test-cmd.test.sh`

**read_first:**
- `lib/git-ops.sh` (file-probe + exit pattern)
- `tests/lib/git-ops.test.sh` (check() pattern for scripts that inspect the filesystem)
- `docs/super-spec/features/planner-execute-discipline/SPEC.md` (User-facing behavior, "Post-merge build/test gate" paragraph: exact probe list -- Makefile, package.json, Cargo.toml, pyproject.toml, setup.py, go.mod)

**Verify:** `bash lib/detect-test-cmd.sh ; echo "exit:$?"` exits 0 and prints a string (possibly empty); `bash tests/lib/detect-test-cmd.test.sh`; `echo $?` returns 0.

**Acceptance criteria:**
- [ ] `lib/detect-test-cmd.sh` is executable and has `#!/usr/bin/env bash` shebang.
- [ ] The script exits 0 in all cases (even when no marker is found).
- [ ] Priority order (first match wins): `Makefile` -> `make test`, `package.json` -> `npm test`, `Cargo.toml` -> `cargo test`, `pyproject.toml` -> `python -m pytest`, `setup.py` -> `python -m pytest`, `go.mod` -> `go test ./...`.
- [ ] When run in this repo (which has a `Makefile` target or none of the above), it prints either a command or an empty string without error.
- [ ] `bash tests/lib/detect-test-cmd.test.sh` exits 0. Test cases run the script in temp dirs with each marker file present; one case tests with no markers (empty output).
- [ ] No em-dash in either file.

**Steps (TDD):**

- [ ] Step 1: Write `tests/lib/detect-test-cmd.test.sh`. For each probe marker, create a temp dir with that file, `cd` into it, run the script, capture output, check expected command string. Also test empty case. Script does not exist -- all FAIL.
- [ ] Step 2: Run tests. Confirm FAIL.
- [ ] Step 3: Implement `lib/detect-test-cmd.sh`. Simple if/elif chain probing `[[ -f Makefile ]]`, etc. Print the matching command; if none match, print nothing. Exit 0.
- [ ] Step 4: Run tests. All PASS.
- [ ] Step 5: Commit.

---

### task-006: skills/plan/SKILL.md decision-coverage gate

**Goal:** Insert the decision-coverage gate invocation into Step 5 of `skills/plan/SKILL.md`, before the `git add` commit. The gate is advisory on quick tier and blocking on quality/balanced tiers per SPEC decisions.

**Files:**
- `skills/plan/SKILL.md`

**read_first:**
- `skills/plan/SKILL.md` (full file, especially Step 5)
- `lib/decision-coverage.sh` (must exist; blockedBy task-003)
- `docs/super-spec/features/planner-execute-discipline/SPEC.md` (Decision 2: advisory on quick, blocking on quality/balanced)

**Verify:** `grep -c "decision-coverage.sh" skills/plan/SKILL.md` returns 1 or more; `grep -rP "\xe2\x80\x94" skills/plan/SKILL.md` exits 1 (no matches).

**Acceptance criteria:**
- [ ] `skills/plan/SKILL.md` Step 5 (commit) is preceded by a `decision-coverage.sh` invocation gate.
- [ ] The gate description specifies: on exit 1, quality/balanced tiers re-dispatch the planner with the uncovered-decision list; quick tier logs a warning and proceeds.
- [ ] If no `<decisions>` block exists in SPEC.md, the gate is skipped (exit 0 from script).
- [ ] Steps 1-4 and 6+ are preserved without structural change.
- [ ] No em-dash in the file.

**Steps:**

- [ ] Step 1: Read `skills/plan/SKILL.md` Step 5 (lines around the `git add` and `git commit`).
- [ ] Step 2: Edit Step 5 to insert the gate prose block before the `git add` line. The inserted block: invokes `bash "${CLAUDE_PLUGIN_ROOT}/lib/decision-coverage.sh" "{spec_path}" "docs/super-spec/features/{slug}/PLAN.md"`, captures exit code, and describes the tier-conditional branching.
- [ ] Step 3: Run `grep -c "decision-coverage.sh" skills/plan/SKILL.md`. Confirm >= 1.
- [ ] Step 4: Commit.

---

### task-007: skills/execute/SKILL.md plan-adherence + post-merge test gate

**Goal:** Amend Step 10 to invoke `lib/plan-adherence.sh` before declaring the phase complete, and amend Step 8 (merge queue) to run a post-merge test gate on quality and balanced tiers.

**Files:**
- `skills/execute/SKILL.md`

**read_first:**
- `skills/execute/SKILL.md` (full file, especially Step 8 merge procedure and Step 10 exit condition)
- `lib/plan-adherence.sh` (must exist; blockedBy task-004)
- `lib/detect-test-cmd.sh` (must exist; blockedBy task-005)
- `docs/super-spec/features/planner-execute-discipline/SPEC.md` (Decision 3: plan-adherence; Decision 6: post-merge test gate skipped on quick, runs on quality/balanced)

**Verify:** `grep -c "plan-adherence.sh" skills/execute/SKILL.md` returns 1 or more; `grep -c "detect-test-cmd.sh\|commands.test" skills/execute/SKILL.md` returns 1 or more; `grep -rP "\xe2\x80\x94" skills/execute/SKILL.md` exits 1.

**Acceptance criteria:**
- [ ] `skills/execute/SKILL.md` Step 10 "Exit condition" sub-section references `lib/plan-adherence.sh`. It states: the lead calls `bash "${CLAUDE_PLUGIN_ROOT}/lib/plan-adherence.sh" "{plan_path}"`, compares the returned `plan_task_ids` against `TaskList({status: "completed"})` subjects, and if any plan task ID has no matching completed entry (and is not in the remediation list), blocks exit and escalates via `AskUserQuestion`.
- [ ] `skills/execute/SKILL.md` Step 8 "Merge procedure" or "Post-merge cleanup" sub-section references `detect-test-cmd.sh` or `commands.test`. It states: after a successful ff-only merge on quality and balanced tiers, the lead runs the test command sourced from `feature.json.commands.test` if set, else from `lib/detect-test-cmd.sh`. On failure the lead creates a remediation task. On quick tier, this gate is logged as skipped.
- [ ] Steps 1-9 and 11+ are preserved without structural change.
- [ ] No em-dash in the file.

**Steps:**

- [ ] Step 1: Read `skills/execute/SKILL.md` Steps 8 and 10 fully.
- [ ] Step 2: Edit Step 10 "Exit condition" to prepend the plan-adherence gate block before the `TaskList` zero-check.
- [ ] Step 3: Edit Step 8 "Post-merge cleanup (per task)" to append a "Post-merge test gate" sub-block after the `git worktree remove` and `git branch -D` lines. Describe the tier-conditional logic.
- [ ] Step 4: Run both grep verify commands. Confirm counts >= 1.
- [ ] Step 5: Commit.

---

### task-008: hooks/team/strategy-rotation.sh

**Goal:** Create `hooks/team/strategy-rotation.sh` (PostToolUse:Bash|Edit|Write) and its test suite. The hook tracks consecutive tool failures per tool per session, emits an `additionalContext` rotation prompt at threshold, resets on success, and honors `SUPER_SPEC_STRATEGY_ROTATION=0` kill-switch.

**Files:**
- `hooks/team/strategy-rotation.sh`
- `hooks/team/strategy-rotation.test.sh`

**read_first:**
- `hooks/team/post-task-complete-revalidate.sh` (fail-open + kill-switch + trace-log pattern; apply concept from PATTERNS.md "Fail-open hook" section)
- `hooks/team/stop-deflection-guard.sh` (additionalContext emission + stdin drain pattern; apply concept from PATTERNS.md "hookSpecificOutput additionalContext" section)
- `/Users/cbobrowitz/Projects/_reference/claude-octopus/hooks/strategy-rotation.sh` (per-session JSON state file pattern; apply concept from PATTERNS.md "JSON state file per session" section)
- `hooks/team/task-completed.test.sh` (check() test helper structure)
- `docs/super-spec/features/planner-execute-discipline/SPEC.md` (Success criteria lines 117-127 for exact test case names)

**Verify:** `test -x hooks/team/strategy-rotation.sh && echo PASS`; `bash hooks/team/strategy-rotation.test.sh`; `echo $?` returns 0.

**Acceptance criteria:**
- [ ] `hooks/team/strategy-rotation.sh` exists and is executable.
- [ ] The hook fires on PostToolUse for Bash, Edit, and Write tools only (ignores other tool names by exiting 0).
- [ ] State file is `/tmp/super-spec-failures-${SESSION}.json` where SESSION is resolved from `CLAUDE_CODE_SESSION_ID`, then `CLAUDE_SESSION_ID`, then `$$`.
- [ ] Consecutive-failure threshold defaults to 2, overridden by `SUPER_SPEC_STRATEGY_ROTATION_THRESHOLD`.
- [ ] When consecutive failures for a tool reach the threshold, the hook emits a JSON object `{"additionalContext":"..."}` to stdout. The message instructs the agent to stop, verbalize the failure mode, describe a completely different approach, and explain why the new approach avoids the same failure.
- [ ] On any successful tool call, the failure counter for that tool resets to 0.
- [ ] `SUPER_SPEC_STRATEGY_ROTATION=0` causes the hook to exit 0 without reading stdin or state.
- [ ] Malformed JSON in the state file causes the state to reset to `{}` and the hook to exit 0 (fail-open).
- [ ] Missing state file causes the hook to start fresh (fail-open).
- [ ] `bash hooks/team/strategy-rotation.test.sh` exits 0, covering: "threshold trigger", "success reset", "kill switch", and "fail-open" cases.
- [ ] No em-dash in either file.

**Steps (TDD):**

- [ ] Step 1: Write `hooks/team/strategy-rotation.test.sh` with at least 4 cases: threshold trigger (send 2 consecutive failures for Bash -> verify additionalContext in stdout), success reset (send 1 failure then 1 success -> verify counter resets, no additionalContext on next failure-1), kill switch (SUPER_SPEC_STRATEGY_ROTATION=0 -> exit 0 with no output), fail-open (malformed state file -> exit 0). Script does not exist -- all FAIL.
- [ ] Step 2: Run `bash hooks/team/strategy-rotation.test.sh`. Confirm FAIL.
- [ ] Step 3: Implement `hooks/team/strategy-rotation.sh`. Apply: (a) fail-open kill-switch pattern from `post-task-complete-revalidate.sh`; (b) per-session state file from claude-octopus reference; (c) additionalContext emission from `stop-deflection-guard.sh`. Use `jq` for JSON state manipulation. Drain stdin at start. Exit 0 on any parse failure.
- [ ] Step 4: Run tests. All PASS.
- [ ] Step 5: Confirm `test -x hooks/team/strategy-rotation.sh` passes.
- [ ] Step 6: Commit.

---

### task-009: hooks/team/budget-gate.sh

**Goal:** Create `hooks/team/budget-gate.sh` (PreToolUse:Agent) and its test suite. The hook reads session cost, emits an `additionalContext` warning at 80-99% of ceiling, exits 2 (block) at 100%+, exits 0 unconditionally when `SUPER_SPEC_MAX_COST_USD` is unset or `SUPER_SPEC_BUDGET_GUARD=0`.

**Files:**
- `hooks/team/budget-gate.sh`
- `hooks/team/budget-gate.test.sh`

**read_first:**
- `hooks/team/post-task-complete-revalidate.sh` (fail-open + kill-switch structure)
- `hooks/team/stop-deflection-guard.sh` (awk float comparison + stdin drain)
- `/Users/cbobrowitz/Projects/_reference/claude-octopus/hooks/budget-gate.sh` (cost-reading from metrics-session.json + awk threshold logic; apply concept from PATTERNS.md "JSON parsing + exit-code comparison" section)
- `hooks/team/task-completed.test.sh` (check() pattern with env var injection)
- `docs/super-spec/features/planner-execute-discipline/SPEC.md` (Decision 5: cost source hierarchy; Success criteria lines 129-142)

**Verify:** `test -x hooks/team/budget-gate.sh && echo PASS`; `bash hooks/team/budget-gate.test.sh`; `echo $?` returns 0.

**Acceptance criteria:**
- [ ] `hooks/team/budget-gate.sh` exists and is executable.
- [ ] When `SUPER_SPEC_MAX_COST_USD` is unset, the hook exits 0 unconditionally (no stdin drain required, but must not error).
- [ ] When `SUPER_SPEC_BUDGET_GUARD=0`, the hook exits 0 unconditionally.
- [ ] Cost is read from `metrics-session.json` field `.totals.estimated_cost_usd` if the file exists in CWD; otherwise from `SUPER_SPEC_CURRENT_COST_USD` env var; otherwise treated as 0.
- [ ] At 80-99% of `SUPER_SPEC_MAX_COST_USD`, exits 0 and emits `{"additionalContext":"WARNING: session cost is at ...% of ceiling ..."}` to stdout.
- [ ] At 100%+ of `SUPER_SPEC_MAX_COST_USD`, exits 2 with a block message to stderr naming the current cost and ceiling.
- [ ] Malformed `metrics-session.json` causes the hook to exit 0 (fail-open).
- [ ] `bash hooks/team/budget-gate.test.sh` exits 0, covering: "warn at 80%", "block at 100%", "no ceiling" (unset MAX), "kill switch" (GUARD=0), and "fail-open" (malformed JSON) cases.
- [ ] No em-dash in either file.

**Steps (TDD):**

- [ ] Step 1: Write `hooks/team/budget-gate.test.sh` with at least 5 cases. Use temp dirs and `SUPER_SPEC_CURRENT_COST_USD` env var (simpler than writing a metrics-session.json in each test). Cases: warn-at-80 (cost=8, max=10 -> stdout contains additionalContext, exit 0), block-at-100 (cost=10, max=10 -> exit 2), no-ceiling (MAX unset -> exit 0), kill-switch (GUARD=0 -> exit 0), fail-open (metrics-session.json contains invalid JSON -> exit 0). Script does not exist -- all FAIL.
- [ ] Step 2: Run tests. Confirm FAIL.
- [ ] Step 3: Implement `hooks/team/budget-gate.sh`. Structure: drain stdin; check kill-switch; check MAX_COST unset -> exit 0; read cost (metrics-session.json then env var then 0); awk comparison; emit warning or exit 2. Apply fail-open pattern: any jq/awk error -> exit 0.
- [ ] Step 4: Run tests. All PASS.
- [ ] Step 5: Confirm `test -x hooks/team/budget-gate.sh` passes.
- [ ] Step 6: Commit.

---

### task-010: hooks/hooks.json wiring

**Goal:** Add a `PreToolUse` entry matching `Agent` that runs `budget-gate.sh`, and a `PostToolUse` entry matching `Bash|Edit|Write` that runs `strategy-rotation.sh`.

**Files:**
- `hooks/hooks.json`

**read_first:**
- `hooks/hooks.json` (full file; must exist -- blockedBy task-008 and task-009)
- `docs/super-spec/features/planner-execute-discipline/SPEC.md` (Success criteria line 144-145: exact jq verify commands)

**Verify:** `jq '.hooks.PreToolUse | map(select(.matcher == "Agent")) | length' hooks/hooks.json` returns 1; `jq '.hooks.PostToolUse | map(select(.matcher | test("Bash"))) | length' hooks/hooks.json` returns 1; `jq empty hooks/hooks.json` exits 0 (valid JSON); `grep -P "\xe2\x80\x94" hooks/hooks.json` exits 1.

**Acceptance criteria:**
- [ ] `hooks/hooks.json` contains a `PreToolUse` entry with `"matcher": "Agent"` and `"command"` pointing to `${CLAUDE_PLUGIN_ROOT}/hooks/team/budget-gate.sh`.
- [ ] `hooks/hooks.json` contains a `PostToolUse` entry with `"matcher": "Bash|Edit|Write"` and `"command"` pointing to `${CLAUDE_PLUGIN_ROOT}/hooks/team/strategy-rotation.sh`.
- [ ] All existing entries (`Write|Edit` restrict-agent-paths, `TaskUpdate` pre-task-blockedby-enforce, `TaskCompleted` task-completed and post-task-complete-revalidate, `TaskCreated` task-created, `TeammateIdle` teammate-idle, `Stop` stop-revalidate-user-gates and stop-deflection-guard) are preserved exactly.
- [ ] `jq empty hooks/hooks.json` exits 0 (file is valid JSON after edit).
- [ ] No em-dash in the file.

**Steps:**

- [ ] Step 1: Read `hooks/hooks.json` in full.
- [ ] Step 2: Add `"PostToolUse"` as a new top-level key in `.hooks` with an array containing the `strategy-rotation.sh` entry.
- [ ] Step 3: Add a new entry to the `.hooks.PreToolUse` array for `budget-gate.sh` with `"matcher": "Agent"`.
- [ ] Step 4: Run `jq empty hooks/hooks.json` to confirm valid JSON.
- [ ] Step 5: Run both jq verify commands from SPEC line 144-145 and confirm results are 1.
- [ ] Step 6: Commit.

---

### task-011: run-all.sh integration + CHANGELOG

**Goal:** Register the five new test suites in `tests/run-all.sh` and write the CHANGELOG entries for all six enforcement additions.

**Files:**
- `tests/run-all.sh`
- `CHANGELOG.md`

**read_first:**
- `tests/run-all.sh` (full file)
- `CHANGELOG.md` (full `[Unreleased]` section)
- `docs/super-spec/features/planner-execute-discipline/SPEC.md` (Success criteria lines 147-157 for exact grep patterns)

**Verify:** `bash tests/run-all.sh` exits 0; `grep -c "anti-shallow\|decision-coverage\|plan-adherence\|detect-test-cmd\|strategy-rotation\|budget-gate" CHANGELOG.md` returns 6 or more; `grep -rP "\xe2\x80\x94" tests/run-all.sh CHANGELOG.md` exits 1.

**Acceptance criteria:**
- [ ] `tests/run-all.sh` includes `run_suite` calls for: `tests/lib/decision-coverage.test.sh`, `tests/lib/plan-adherence.test.sh`, `tests/lib/detect-test-cmd.test.sh`, `hooks/team/strategy-rotation.test.sh`, `hooks/team/budget-gate.test.sh`.
- [ ] `bash tests/run-all.sh` exits 0 with 0 suite failures (all new and all existing suites pass).
- [ ] `CHANGELOG.md` `[Unreleased]` section contains entries mentioning all six enforcement additions: anti-shallow planner rules, decision-coverage gate, plan-adherence exit check, post-merge test gate (detect-test-cmd), strategy-rotation hook, budget-gate hook.
- [ ] `grep -c "anti-shallow\|decision-coverage\|plan-adherence\|detect-test-cmd\|strategy-rotation\|budget-gate" CHANGELOG.md` returns 6 or more.
- [ ] No em-dash in either file.

**Steps:**

- [ ] Step 1: Read `tests/run-all.sh` and `CHANGELOG.md` fully.
- [ ] Step 2: Edit `tests/run-all.sh` to add the five `run_suite` calls after the existing `lib/validate-task-metadata` suite line.
- [ ] Step 3: Run `bash tests/run-all.sh` to confirm exit 0.
- [ ] Step 4: Edit `CHANGELOG.md` under `[Unreleased]` to add an `### Added` subsection (or extend the existing one) with entries for all six additions. Use the same style as existing CHANGELOG entries: bold title + description.
- [ ] Step 5: Run `grep -c "anti-shallow\|decision-coverage\|plan-adherence\|detect-test-cmd\|strategy-rotation\|budget-gate" CHANGELOG.md`. Confirm >= 6.
- [ ] Step 6: Commit.

---

## Test strategy

Each lib helper (`decision-coverage.sh`, `plan-adherence.sh`, `detect-test-cmd.sh`) has a dedicated `.test.sh` file under `tests/lib/`. Each hook (`strategy-rotation.sh`, `budget-gate.sh`) has a `.test.sh` sibling in `hooks/team/`. All five test files are registered in `tests/run-all.sh` (task-011). TDD ordering is enforced for all five: test file written and confirmed FAIL before implementation is written.

Prose-only tasks (001, 002, 006, 007, 010) verify via `grep` assertions on the output files as documented in each task's "Verify" field.

## Rollback plan

All changes are additive: three new lib scripts, two new hook scripts, one new docs file, and targeted edits to five existing files. If VERIFY fails after merges:

1. `git revert` the task commits for the failing tasks (each task is one commit).
2. The hooks (`strategy-rotation.sh`, `budget-gate.sh`) are wired in `hooks/hooks.json`; removing their entries from `hooks/hooks.json` disables them without deleting the files.
3. The lib helper references in `skills/plan/SKILL.md` and `skills/execute/SKILL.md` are prose instructions to the lead agent; reverting those commits restores the pre-feature behavior without affecting any runtime state.
