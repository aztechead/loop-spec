# User-gate flow (verification enforcement) - Implementation Plan

**Spec:** `docs/loop-spec/features/user-gate-flow/SPEC.md`
**Created:** 2026-05-28

## Architecture overview

This feature adds two new skills and four new bash hooks to loop-spec. The skills are pure markdown authored to match the SKILL.md frontmatter + section structure used by all existing skills. The hooks follow the exact `set -euo pipefail` + kill-switch + fail-open + `INPUT=$(cat)` + python3-inline pattern established by `hooks/team/task-created.sh` and `hooks/team/task-completed.sh`. No existing files are modified except `skills/shared/feature-state-schema.md`, `lib/validate-task-metadata.sh`, `hooks/hooks.json`, and `CHANGELOG.md`.

## Assumptions

- The CC `Stop` event payload delivers the session transcript as a JSON array under a top-level field (exact field name TBD; the hook must fail-open if the field is absent or unrecognized).
- The CC `PreToolUse:TaskUpdate` payload delivers `tool_input.taskId`, `tool_input.status`, and `tool_input.metadata` including `blockedBy`. The hook receives the full task's current metadata in the payload.
- `pre-task-blockedby-enforce.sh` can determine peer task statuses only from what is present in its own payload. If the payload does not include peer task statuses, the hook exits 0 (fail-open). This is a known limitation; a future cycle can extend it when the harness payload schema is clarified.
- `stop-deflection-guard.sh` reads context usage from the Stop payload's top-level `usage` object. If no `usage` key is present, it exits 0.
- `LOOP_SPEC_CONTEXT_LIMIT` defaults to 200000 when unset; `LOOP_SPEC_DEFLECTION_THRESHOLD_PCT` defaults to 50 when unset.
- Trace log directory `/tmp/claude-hooks/` may not exist; hooks must create it with `mkdir -p` before writing.

## File map

- Create: `skills/checking-gates/SKILL.md` - checking-gates skill definition
- Create: `skills/specifying-gates/SKILL.md` - specifying-gates skill definition
- Create: `hooks/team/post-task-complete-revalidate.sh` - TaskCompleted hook for evidence scanning
- Create: `hooks/team/post-task-complete-revalidate.test.sh` - unit tests for above
- Create: `hooks/team/stop-revalidate-user-gates.sh` - Stop hook for plan-complete net
- Create: `hooks/team/stop-revalidate-user-gates.test.sh` - unit tests for above
- Create: `hooks/team/pre-task-blockedby-enforce.sh` - PreToolUse:TaskUpdate blockedBy gate
- Create: `hooks/team/pre-task-blockedby-enforce.test.sh` - unit tests for above
- Create: `hooks/team/stop-deflection-guard.sh` - Stop hook for context-excuse blocking
- Create: `hooks/team/stop-deflection-guard.test.sh` - unit tests for above
- Modify: `skills/shared/feature-state-schema.md` - add 9 optional task metadata fields to table
- Modify: `lib/validate-task-metadata.sh` - accept (not require) 9 new optional fields
- Modify: `tests/lib/validate-task-metadata.test.sh` - add cases for new optional fields
- Modify: `hooks/hooks.json` - wire all 4 new hooks
- Modify: `tests/run-all.sh` - register 4 new hook test suites
- Modify: `CHANGELOG.md` - document all additions under [Unreleased]

## Task DAG

| ID | Subject | BlockedBy | Files | Est scope |
|----|---------|-----------|-------|-----------|
| task-001 | checking-gates skill | - | skills/checking-gates/SKILL.md | small |
| task-002 | specifying-gates skill | - | skills/specifying-gates/SKILL.md | small |
| task-003 | schema extension and validate-task-metadata update | - | skills/shared/feature-state-schema.md, lib/validate-task-metadata.sh, tests/lib/validate-task-metadata.test.sh | small |
| task-004 | post-task-complete-revalidate hook (TDD) | - | hooks/team/post-task-complete-revalidate.sh, hooks/team/post-task-complete-revalidate.test.sh | medium |
| task-005 | stop-revalidate-user-gates hook (TDD) | - | hooks/team/stop-revalidate-user-gates.sh, hooks/team/stop-revalidate-user-gates.test.sh | medium |
| task-006 | pre-task-blockedby-enforce hook (TDD) | - | hooks/team/pre-task-blockedby-enforce.sh, hooks/team/pre-task-blockedby-enforce.test.sh | medium |
| task-007 | stop-deflection-guard hook (TDD) | - | hooks/team/stop-deflection-guard.sh, hooks/team/stop-deflection-guard.test.sh | medium |
| task-008 | hooks.json wiring | task-004, task-005, task-006, task-007 | hooks/hooks.json | small |
| task-009 | run-all.sh registration | task-004, task-005, task-006, task-007 | tests/run-all.sh | small |
| task-010 | CHANGELOG entry | task-001, task-002, task-003, task-004, task-005, task-006, task-007, task-008, task-009 | CHANGELOG.md | small |

## Tasks

---

### task-001: checking-gates skill

**Goal:** Author `skills/checking-gates/SKILL.md` with all sections required by SPEC.md success criterion 1.

**Files:**
- `skills/checking-gates/SKILL.md`

**Verify:** `grep -c "Path A\|Path B\|PROVEN BY\|failurePolicy\|stop-plan\|reopen-continue\|log-continue" skills/checking-gates/SKILL.md` returns 6 or more.

**Acceptance criteria:**
- [ ] File exists at `skills/checking-gates/SKILL.md`.
- [ ] Contains YAML frontmatter with `name: checking-gates` and non-empty `description`.
- [ ] Contains an announce statement: `"I'm using the checking-gates skill to verify Task N's acceptance criteria."` (verbatim or functionally equivalent).
- [ ] Contains the three-step process: Step 1 (Load and classify), Step 2 (Route), Step 3 (Execute and post evidence).
- [ ] Contains Path A (HOW ambiguous -> route to specifying-gates) and Path B (HOW clear -> execute) routing rules.
- [ ] Contains the three-element self-check definition: observable named, capture method named, pass/fail rule named.
- [ ] Contains failurePolicy handling for all three enum values: `stop-plan`, `reopen-continue`, `log-continue`.
- [ ] Contains a "What NOT to do" section.
- [ ] Contains an Integration section naming invoked-from, may-hand-off-to, and returns-to.
- [ ] `grep -c "Path A\|Path B\|PROVEN BY\|failurePolicy\|stop-plan\|reopen-continue\|log-continue" skills/checking-gates/SKILL.md` exits 0 and prints 6 or greater.
- [ ] No em-dash (U+2014) appears anywhere in the file: `grep -P "—" skills/checking-gates/SKILL.md` returns no matches.
- [ ] References harness tools (`TaskGet`, `TaskUpdate`) instead of the reference's `.tasks.json` file.

**Steps:**

- [ ] Step 1: Read `/Users/cbobrowitz/Projects/_reference/pcvelz-superpowers/skills/checking-gates/SKILL.md` and PATTERNS.md (PATTERNS section: "Markdown skill document structure") for the full upstream content and house structure rules.
- [ ] Step 2: Read `SPEC.md` section "User-facing behavior" (paragraphs 1-3) for the exact behavioral spec of this skill.
- [ ] Step 3: Write `skills/checking-gates/SKILL.md`. Replace all `.tasks.json` references with `TaskGet`/`TaskUpdate`. Replace `/gate-check` with `Skill(loop-spec:checking-gates)`. Replace `/specify-gate` with `Skill(loop-spec:specifying-gates)`. Do not reference `executing-plans` (that skill does not exist in loop-spec; substitute `skills/execute/SKILL.md` where needed).
- [ ] Step 4: Run verify command. Confirm count >= 6.
- [ ] Step 5: Run `grep -P "—" skills/checking-gates/SKILL.md` and confirm no output.

**BlockedBy:** []

---

### task-002: specifying-gates skill

**Goal:** Author `skills/specifying-gates/SKILL.md` with all sections required by SPEC.md success criterion 2.

**Files:**
- `skills/specifying-gates/SKILL.md`

**Verify:** `grep -c "AskUserQuestion\|requiresUserSpecification\|gateScope\|failurePolicy\|subagentBrief\|Specification" skills/specifying-gates/SKILL.md` returns 6 or more.

**Acceptance criteria:**
- [ ] File exists at `skills/specifying-gates/SKILL.md`.
- [ ] Contains YAML frontmatter with `name: specifying-gates` and non-empty `description`.
- [ ] Contains an announce statement: `"I'm using the specifying-gates skill to lock down verification mechanics for Task N."` (verbatim or functionally equivalent).
- [ ] Documents when-to-run trigger conditions: `requiresUserSpecification: true`, ambiguous self-check, and `/specify-gate` manual invocation.
- [ ] Contains all four `AskUserQuestion` blocks (Q1 observable, Q2 mechanism, Q3 scope, Q4 failure policy) with the exact option sets from SPEC.md.
- [ ] Contains the optional Q5 dispatch contract block (triggered when Q2 = "Subagent with briefing").
- [ ] Contains the writing-back section: json:metadata fence rewrite, Specification section append above the fence, `requiresUserSpecification` removal.
- [ ] Contains a "What NOT to do" section.
- [ ] Contains an Integration section.
- [ ] `grep -c "AskUserQuestion\|requiresUserSpecification\|gateScope\|failurePolicy\|subagentBrief\|Specification" skills/specifying-gates/SKILL.md` exits 0 and prints 6 or greater.
- [ ] No em-dash (U+2014) in the file.
- [ ] Writing-back section uses `TaskUpdate` (not `.tasks.json`) for persisting the enriched metadata.

**Steps:**

- [ ] Step 1: Read `/Users/cbobrowitz/Projects/_reference/pcvelz-superpowers/skills/specifying-gates/SKILL.md` and PATTERNS.md (PATTERNS section: "Markdown skill document structure") for the full upstream content and house structure rules.
- [ ] Step 2: Read `SPEC.md` section "User-facing behavior" (paragraph 2) for the full Q1-Q5 question text and writing-back spec.
- [ ] Step 3: Write `skills/specifying-gates/SKILL.md`. Replace all `.tasks.json` references with `TaskUpdate`. Replace `/specify-gate` with `Skill(loop-spec:specifying-gates)`. Keep Q1-Q5 AskUserQuestion blocks verbatim from the reference but with loop-spec tool references.
- [ ] Step 4: Run verify command. Confirm count >= 6.
- [ ] Step 5: Run em-dash check.

**BlockedBy:** []

---

### task-003: schema extension and validate-task-metadata update

**Goal:** Document 9 new optional task metadata fields in `skills/shared/feature-state-schema.md`; extend `lib/validate-task-metadata.sh` to accept (not require) them; add new test cases to `tests/lib/validate-task-metadata.test.sh`.

**Files:**
- `skills/shared/feature-state-schema.md`
- `lib/validate-task-metadata.sh`
- `tests/lib/validate-task-metadata.test.sh`

**Verify:** `grep -c "userGate\|requireEvidenceTokens\|requireABCompare\|subagentType\|dispatchBrief\|failurePolicy\|gateScope\|requiresUserSpecification" skills/shared/feature-state-schema.md` returns 8 or more. Then: `bash tests/lib/validate-task-metadata.test.sh` exits 0.

**Acceptance criteria:**
- [ ] `skills/shared/feature-state-schema.md` "Harness task list usage" table contains rows for all 9 new optional fields: `userGate` (bool), `requireEvidenceTokens` (array of arrays), `requireABCompare` (bool), `subagentType` (string), `model` (string), `dispatchBrief` (string), `failurePolicy` (string enum: `stop-plan` | `reopen-continue` | `log-continue`), `gateScope` (string enum: `once` | `per-target` | `one-then-all` | `custom`), `requiresUserSpecification` (bool). All marked optional.
- [ ] `grep -c "userGate\|requireEvidenceTokens\|requireABCompare\|subagentType\|dispatchBrief\|failurePolicy\|gateScope\|requiresUserSpecification" skills/shared/feature-state-schema.md` returns 8 or more.
- [ ] `lib/validate-task-metadata.sh` exits 0 when passed a metadata object containing any combination of the 9 new optional fields alongside the 4 required fields.
- [ ] `lib/validate-task-metadata.sh` still exits 2 when required fields are missing (regression: existing test cases A-N all pass).
- [ ] `tests/lib/validate-task-metadata.test.sh` includes at least 4 new cases: (O) userGate + failurePolicy + gateScope present -> exit 0; (P) requiresUserSpecification + requireEvidenceTokens present -> exit 0; (Q) requireABCompare + subagentType + dispatchBrief + model present -> exit 0; (R) all 9 new optional fields absent from valid payload -> exit 0 (regression guard).
- [ ] `bash tests/lib/validate-task-metadata.test.sh` exits 0 with all cases passing.
- [ ] No em-dash in any modified file.

**Steps (TDD):**

- [ ] Step 1: Read `lib/validate-task-metadata.sh` (analog: PATTERNS.md "lib/validate-task-metadata.sh extension") and `tests/lib/validate-task-metadata.test.sh` in full.
- [ ] Step 2: Add test cases O, P, Q, R to `tests/lib/validate-task-metadata.test.sh`. Run `bash tests/lib/validate-task-metadata.test.sh` - cases O-Q will PASS already (current validator ignores unknown fields) but confirm baseline.
- [ ] Step 3: Read `skills/shared/feature-state-schema.md` "Harness task list usage" section. Append 9 rows to the table for the new optional fields. Use identical column format to existing rows: `| \`field\` | type | Optional. Set by ... | Description. |`.
- [ ] Step 4: Extend `lib/validate-task-metadata.sh` python3 block to type-check the 9 new optional fields when present (e.g., `userGate` must be bool if present; `failurePolicy` must be one of three enum strings if present; etc.). If any present optional field has wrong type, print `'INVALID_OPTIONAL:fieldname'` and the caller exits 2.
- [ ] Step 5: Add a test case S to `tests/lib/validate-task-metadata.test.sh` for an invalid optional field value (e.g., `failurePolicy` set to `"bogus"`) -> exit 2.
- [ ] Step 6: Run `bash tests/lib/validate-task-metadata.test.sh` and confirm all pass.
- [ ] Step 7: Run `grep -c "userGate\|requireEvidenceTokens\|requireABCompare\|subagentType\|dispatchBrief\|failurePolicy\|gateScope\|requiresUserSpecification" skills/shared/feature-state-schema.md` and confirm >= 8.

**BlockedBy:** []

---

### task-004: post-task-complete-revalidate hook (TDD)

**Goal:** Implement `hooks/team/post-task-complete-revalidate.sh` (TaskCompleted event) with full kill-switch, fail-open, and trace-log behavior; implement its test suite.

**Files:**
- `hooks/team/post-task-complete-revalidate.sh`
- `hooks/team/post-task-complete-revalidate.test.sh`

**Verify:** `test -x hooks/team/post-task-complete-revalidate.sh && echo PASS`. Then: `bash hooks/team/post-task-complete-revalidate.test.sh`.

**Acceptance criteria:**
- [ ] `hooks/team/post-task-complete-revalidate.sh` exists and is executable (`test -x` passes).
- [ ] Hook exits 0 unconditionally when `LOOP_SPEC_USERGATE_GUARD=0` is set, regardless of payload content. Test suite "kill-switch" case passes.
- [ ] Hook exits 0 when payload is empty or malformed JSON. Test suite "fail-open" case passes.
- [ ] Hook exits 0 when the task does NOT have `userGate: true` in its metadata (non-gate tasks are not inspected).
- [ ] Hook exits 2 when a `userGate: true` task is closed with no `AC:` or `PROVEN BY` tokens in the transcript window and no direct user message in the window. Test suite "miss" case passes.
- [ ] Hook exits 0 when a `userGate: true` task is closed and both `AC:` and `PROVEN BY` tokens are present in the transcript window. Test suite "match" case passes.
- [ ] Hook writes at least one pipe-separated trace-log line to `${LOOP_SPEC_USERGATE_TRACE_LOG:-/tmp/claude-hooks/loop-spec-user-gate-trace.log}` per invocation in the format `<ISO-8601-timestamp>|post-task-complete-revalidate|<task-id-or-?>|<event>|<reason>`. Verified by inspecting the log file after running the test suite.
- [ ] Hook uses `set -euo pipefail` and `#!/usr/bin/env bash` header.
- [ ] No em-dash in any new file.

**Steps (TDD):**

- [ ] Step 1: Read PATTERNS.md sections "Hook kill-switch and fail-open pattern" and "Hook test harness (check() + payload helpers)" and "Stdin JSON capture and python3 parsing". Read `hooks/team/task-created.test.sh` for the full `check()` harness idiom.
- [ ] Step 2: Write `hooks/team/post-task-complete-revalidate.test.sh` with the following cases: (a) kill-switch: `LOOP_SPEC_USERGATE_GUARD=0` -> exit 0; (b) fail-open: empty payload -> exit 0; (c) fail-open: malformed JSON payload -> exit 0; (d) non-gate task (no `userGate` field) -> exit 0; (e) gate task, transcript has `AC:` and `PROVEN BY` -> exit 0 ("match" case); (f) gate task, transcript has neither marker -> exit 2 ("miss" case); (g) trace-log line written: after any invocation, the log file contains a pipe-separated line. Run the test script - it will fail because the hook does not yet exist. Confirm FAIL output.
- [ ] Step 3: Write `hooks/team/post-task-complete-revalidate.sh`. Assumption about payload: the TaskCompleted payload delivers `tool_input.metadata.userGate` (bool) and a `transcript` array or similar field containing the recent conversation. If the transcript field is absent or the structure is unexpected, exit 0 (fail-open). The hook scans the assistant-role messages in the transcript for `AC:` and `PROVEN BY` substrings. Trace-log: `mkdir -p` the directory before appending.
- [ ] Step 4: `chmod +x hooks/team/post-task-complete-revalidate.sh`.
- [ ] Step 5: Run `bash hooks/team/post-task-complete-revalidate.test.sh` and confirm all cases pass.
- [ ] Step 6: Run `test -x hooks/team/post-task-complete-revalidate.sh && echo PASS`.

**BlockedBy:** []

---

### task-005: stop-revalidate-user-gates hook (TDD)

**Goal:** Implement `hooks/team/stop-revalidate-user-gates.sh` (Stop event) with full kill-switch, fail-open, and trace-log behavior; implement its test suite.

**Files:**
- `hooks/team/stop-revalidate-user-gates.sh`
- `hooks/team/stop-revalidate-user-gates.test.sh`

**Verify:** `test -x hooks/team/stop-revalidate-user-gates.sh && echo PASS`. Then: `bash hooks/team/stop-revalidate-user-gates.test.sh`.

**Acceptance criteria:**
- [ ] `hooks/team/stop-revalidate-user-gates.sh` exists and is executable.
- [ ] Hook exits 0 unconditionally when `LOOP_SPEC_USERGATE_STOP_GUARD=0` is set. Test suite "kill-switch" case passes.
- [ ] Hook exits 0 when payload is empty or malformed JSON. Test suite "fail-open" case passes.
- [ ] Hook exits 2 when the last assistant message contains a plan-complete phrase (e.g., "all gates passed", "plan complete", "all tasks completed") AND at least one closed `userGate: true` task has no post-close `AC:` / `PROVEN BY` markers in the full transcript. Test suite "blocked" case passes.
- [ ] Hook exits 0 when no plan-complete phrase is detected in the last assistant message. Test suite "no-trigger" case passes.
- [ ] Hook exits 0 when all closed `userGate: true` tasks have `AC:` + `PROVEN BY` evidence present. Test suite "all-proven" case passes.
- [ ] Hook writes at least one pipe-separated trace-log line per invocation in the format `<ISO-8601-timestamp>|stop-revalidate-user-gates|<task-id-or-?>|<event>|<reason>`. Verified after test suite run.
- [ ] Hook uses `set -euo pipefail` and `#!/usr/bin/env bash`.
- [ ] No em-dash in any new file.

**Steps (TDD):**

- [ ] Step 1: Read PATTERNS.md sections "Hook kill-switch and fail-open pattern" and "Hook test harness". Read `hooks/team/task-completed.test.sh` for env-var override pattern using `env VAR=value bash "$HOOK"`.
- [ ] Step 2: Write `hooks/team/stop-revalidate-user-gates.test.sh` with cases: (a) kill-switch: `LOOP_SPEC_USERGATE_STOP_GUARD=0` -> exit 0; (b) fail-open: empty payload -> exit 0; (c) fail-open: malformed JSON -> exit 0; (d) no-trigger: last assistant message has no plan-complete phrase -> exit 0; (e) all-proven: plan-complete phrase present, all gate tasks have AC:/PROVEN BY -> exit 0; (f) blocked: plan-complete phrase present, one gate task missing evidence -> exit 2; (g) trace-log line written. Run to confirm FAIL on missing hook.
- [ ] Step 3: Write `hooks/team/stop-revalidate-user-gates.sh`. Assumption: the Stop payload contains a `transcript` array; the last assistant-role message is inspected for plan-complete phrases. The full transcript is scanned for closed `userGate: true` tasks (by looking for task metadata patterns and status `completed`). If transcript field is absent, exit 0.
- [ ] Step 4: `chmod +x hooks/team/stop-revalidate-user-gates.sh`.
- [ ] Step 5: Run `bash hooks/team/stop-revalidate-user-gates.test.sh` and confirm all cases pass.
- [ ] Step 6: Run `test -x hooks/team/stop-revalidate-user-gates.sh && echo PASS`.

**BlockedBy:** []

---

### task-006: pre-task-blockedby-enforce hook (TDD)

**Goal:** Implement `hooks/team/pre-task-blockedby-enforce.sh` (PreToolUse:TaskUpdate on `status=in_progress`) with full kill-switch, fail-open, and trace-log behavior; implement its test suite.

**Files:**
- `hooks/team/pre-task-blockedby-enforce.sh`
- `hooks/team/pre-task-blockedby-enforce.test.sh`

**Verify:** `test -x hooks/team/pre-task-blockedby-enforce.sh && echo PASS`. Then: `bash hooks/team/pre-task-blockedby-enforce.test.sh`.

**Acceptance criteria:**
- [ ] `hooks/team/pre-task-blockedby-enforce.sh` exists and is executable.
- [ ] Hook exits 0 unconditionally when `LOOP_SPEC_BLOCKEDBY_GUARD=0` is set. Test suite "kill-switch" case passes.
- [ ] Hook exits 0 when payload is empty or malformed JSON. Test suite "fail-open" case passes.
- [ ] Hook exits 0 when the `TaskUpdate` payload does NOT have `status=in_progress` (hook only fires for in_progress transitions).
- [ ] Hook exits 2 when a `TaskUpdate` to `in_progress` is attempted and a `blockedBy` entry in the task's metadata is not `completed`. The stderr output contains a structured rejection (e.g., `DENY: task-NNN is blocked by task-MMM (status: pending)`). Test suite "blocked dep" case passes.
- [ ] Hook exits 0 when all `blockedBy` entries are `completed` or the `blockedBy` array is empty. Test suite "all-clear" case passes.
- [ ] Hook writes at least one pipe-separated trace-log line per invocation. Verified after test suite run.
- [ ] Hook uses `set -euo pipefail` and `#!/usr/bin/env bash`.
- [ ] No em-dash in any new file.

**Steps (TDD):**

- [ ] Step 1: Read PATTERNS.md sections "Hook kill-switch and fail-open pattern", "Stdin JSON capture and python3 parsing", and "Hook test harness". Read `hooks/team/task-created.sh` as the closest structural analog (PreToolUse, exit 2 with DENY).
- [ ] Step 2: Write `hooks/team/pre-task-blockedby-enforce.test.sh` with cases: (a) kill-switch: `LOOP_SPEC_BLOCKEDBY_GUARD=0` -> exit 0; (b) fail-open: empty payload -> exit 0; (c) fail-open: malformed JSON -> exit 0; (d) status not in_progress: payload with `status=completed` -> exit 0; (e) all-clear: blockedBy=[], status=in_progress -> exit 0; (f) blocked dep: blockedBy=["task-001"], task-001 status=pending, status=in_progress -> exit 2; (g) trace-log line written. Construct payloads using `printf`. Run to confirm FAIL on missing hook.
- [ ] Step 3: Write `hooks/team/pre-task-blockedby-enforce.sh`. Assumption: the `PreToolUse:TaskUpdate` payload provides `tool_input.status`, `tool_input.metadata.blockedBy` (array of task IDs), and a `tasks` array or equivalent field that lists peer task statuses. If the `tasks` field is absent (harness does not include it), the hook exits 0 (fail-open -- cannot enforce without peer data). When peer statuses ARE available, check each `blockedBy` entry.
- [ ] Step 4: `chmod +x hooks/team/pre-task-blockedby-enforce.sh`.
- [ ] Step 5: Run `bash hooks/team/pre-task-blockedby-enforce.test.sh` and confirm all cases pass.
- [ ] Step 6: Run `test -x hooks/team/pre-task-blockedby-enforce.sh && echo PASS`.

**BlockedBy:** []

---

### task-007: stop-deflection-guard hook (TDD)

**Goal:** Implement `hooks/team/stop-deflection-guard.sh` (Stop event) with full kill-switch, fail-open, and trace-log behavior; implement its test suite.

**Files:**
- `hooks/team/stop-deflection-guard.sh`
- `hooks/team/stop-deflection-guard.test.sh`

**Verify:** `test -x hooks/team/stop-deflection-guard.sh && echo PASS`. Then: `bash hooks/team/stop-deflection-guard.test.sh`.

**Acceptance criteria:**
- [ ] `hooks/team/stop-deflection-guard.sh` exists and is executable.
- [ ] Hook exits 0 unconditionally when `LOOP_SPEC_DEFLECTION_GUARD=0` is set. Test suite "kill-switch" case passes.
- [ ] Hook exits 0 when payload is empty or malformed JSON. Test suite "fail-open" case passes.
- [ ] Hook exits 2 when the last assistant text contains a deflection phrase ("fresh session", "context is full", "context is high") AND computed context usage (input_tokens + cache_read_input_tokens + cache_creation_input_tokens) is below `LOOP_SPEC_DEFLECTION_THRESHOLD_PCT` percent of `LOOP_SPEC_CONTEXT_LIMIT`. Test suite "deflection below threshold" case passes.
- [ ] Hook exits 0 when the last assistant text contains a deflection phrase but context usage is at or above the threshold. Test suite "high-context" case passes.
- [ ] Hook exits 0 when context usage is below threshold but no deflection phrase is present. Test suite "no-deflection-phrase" case passes.
- [ ] Hook exits 0 when the `usage` field is absent from the payload (fail-open).
- [ ] The exit 2 rejection message cites the actual computed usage percentage: e.g., `DENY: deflection phrase detected but context usage is only 15% (30000/200000 tokens). Provide a substantive response.`
- [ ] Hook writes at least one pipe-separated trace-log line per invocation. Verified after test suite run.
- [ ] Hook uses `set -euo pipefail` and `#!/usr/bin/env bash`.
- [ ] No em-dash in any new file.

**Steps (TDD):**

- [ ] Step 1: Read PATTERNS.md sections "Hook kill-switch and fail-open pattern" and "Hook test harness". Note: context usage calculation is novel (see PATTERNS.md "Concepts with no clear analog").
- [ ] Step 2: Write `hooks/team/stop-deflection-guard.test.sh` with cases: (a) kill-switch: `LOOP_SPEC_DEFLECTION_GUARD=0` -> exit 0; (b) fail-open: empty payload -> exit 0; (c) fail-open: malformed JSON -> exit 0; (d) no-deflection-phrase: usage low but no phrase -> exit 0; (e) high-context: phrase present but usage=180000 out of 200000 (90%) above default 50% threshold -> exit 0; (f) deflection below threshold: phrase "context is full" present, usage=15000 (7.5%) below 50% -> exit 2; (g) no-usage-field: deflection phrase present but no usage field in payload -> exit 0 (fail-open); (h) trace-log line written. Construct JSON payloads using `printf`. Run to confirm FAIL.
- [ ] Step 3: Write `hooks/team/stop-deflection-guard.sh`. Deflection phrases to detect: "fresh session", "context is full", "context is high", "running low on context", "start a new session". Default `LOOP_SPEC_CONTEXT_LIMIT=200000`, `LOOP_SPEC_DEFLECTION_THRESHOLD_PCT=50`. Compute: `total_used = input_tokens + cache_read_input_tokens + cache_creation_input_tokens`. Compute: `pct = total_used * 100 / LOOP_SPEC_CONTEXT_LIMIT`. If `pct < LOOP_SPEC_DEFLECTION_THRESHOLD_PCT` and a phrase is found, exit 2 with the DENY message citing actual numbers.
- [ ] Step 4: `chmod +x hooks/team/stop-deflection-guard.sh`.
- [ ] Step 5: Run `bash hooks/team/stop-deflection-guard.test.sh` and confirm all cases pass.
- [ ] Step 6: Run `test -x hooks/team/stop-deflection-guard.sh && echo PASS`.

**BlockedBy:** []

---

### task-008: hooks.json wiring

**Goal:** Update `hooks/hooks.json` to wire all 4 new hooks: chain `post-task-complete-revalidate.sh` under `TaskCompleted`; add `stop-revalidate-user-gates.sh` and `stop-deflection-guard.sh` under `Stop`; add a `PreToolUse` entry with matcher `TaskUpdate` for `pre-task-blockedby-enforce.sh`.

**Files:**
- `hooks/hooks.json`

**Verify:** `jq '.hooks.TaskCompleted | length' hooks/hooks.json` returns 2. Then: `jq '.hooks.Stop | length' hooks/hooks.json` returns 2. Then: `jq '.hooks.PreToolUse | map(select(.matcher == "TaskUpdate")) | length' hooks/hooks.json` returns 1.

**Acceptance criteria:**
- [ ] `hooks.json` `TaskCompleted` array has exactly 2 entries: the existing `task-completed.sh` entry (first, `continueOnBlock: true`) and the new `post-task-complete-revalidate.sh` entry (second, also `continueOnBlock: true`).
- [ ] `hooks.json` `Stop` array has exactly 2 entries: one for `stop-revalidate-user-gates.sh` and one for `stop-deflection-guard.sh`.
- [ ] `hooks.json` `PreToolUse` array has an entry with `matcher: "TaskUpdate"` wiring `pre-task-blockedby-enforce.sh`.
- [ ] `jq '.hooks.TaskCompleted | length' hooks/hooks.json` returns 2.
- [ ] `jq '.hooks.Stop | length' hooks/hooks.json` returns 2.
- [ ] `jq '.hooks.PreToolUse | map(select(.matcher == "TaskUpdate")) | length' hooks/hooks.json` returns 1.
- [ ] `jq '.' hooks/hooks.json` exits 0 (valid JSON).
- [ ] No em-dash in `hooks/hooks.json`.

**Steps:**

- [ ] Step 1: Read `hooks/hooks.json` in full (PATTERNS.md "hooks.json event wiring with continueOnBlock" section as reference).
- [ ] Step 2: Edit `hooks/hooks.json`:
  - Under `TaskCompleted`: append a second entry for `post-task-complete-revalidate.sh` with `continueOnBlock: true`.
  - Add a new top-level `Stop` key with an array of two entries: one for `stop-revalidate-user-gates.sh` and one for `stop-deflection-guard.sh` (no `continueOnBlock` needed for Stop events).
  - Under `PreToolUse`: append a new entry with `matcher: "TaskUpdate"` and a single hook for `pre-task-blockedby-enforce.sh`.
- [ ] Step 3: Run `jq '.' hooks/hooks.json` to validate JSON.
- [ ] Step 4: Run all three `jq` verify commands and confirm expected values.

**BlockedBy:** [task-004, task-005, task-006, task-007]

---

### task-009: run-all.sh registration

**Goal:** Register all 4 new hook test suites in `tests/run-all.sh` so they run as part of the standard test suite.

**Files:**
- `tests/run-all.sh`

**Verify:** `bash tests/run-all.sh` exits 0 with no suite failures.

**Acceptance criteria:**
- [ ] `tests/run-all.sh` contains `run_suite` calls for all 4 new test suites: `hooks/team/post-task-complete-revalidate.test.sh`, `hooks/team/stop-revalidate-user-gates.test.sh`, `hooks/team/pre-task-blockedby-enforce.test.sh`, `hooks/team/stop-deflection-guard.test.sh`.
- [ ] `bash tests/run-all.sh` exits 0 (all suites pass, no regressions in existing suites).
- [ ] The existing suite registrations (validate-agents, restrict-agent-paths, lib/*, hooks/team/task-completed, etc.) are all preserved unchanged.
- [ ] No em-dash added to `tests/run-all.sh`.

**Steps:**

- [ ] Step 1: Read `tests/run-all.sh` in full.
- [ ] Step 2: Append 4 `run_suite` calls after the existing `hooks/team/task-completed` entry, one per new test file, following the exact `run_suite "name" "bash path/to/test.sh"` pattern.
- [ ] Step 3: Run `bash tests/run-all.sh` and confirm all suites pass.

**BlockedBy:** [task-004, task-005, task-006, task-007]

---

### task-010: CHANGELOG entry

**Goal:** Add entries under `[Unreleased] ### Added` in `CHANGELOG.md` documenting all new deliverables.

**Files:**
- `CHANGELOG.md`

**Verify:** `grep -c "checking-gates\|specifying-gates\|post-task-complete-revalidate\|stop-revalidate\|pre-task-blockedby\|stop-deflection" CHANGELOG.md` returns 6 or more.

**Acceptance criteria:**
- [ ] `CHANGELOG.md` has entries under `[Unreleased]` in a `### Added` section (created if not already present alongside existing `### Fixed`/`### Changed` entries) documenting: `checking-gates` skill, `specifying-gates` skill, `post-task-complete-revalidate.sh` hook, `stop-revalidate-user-gates.sh` hook, `pre-task-blockedby-enforce.sh` hook, `stop-deflection-guard.sh` hook, and the 9 new optional task metadata fields.
- [ ] `grep -c "checking-gates\|specifying-gates\|post-task-complete-revalidate\|stop-revalidate\|pre-task-blockedby\|stop-deflection" CHANGELOG.md` returns 6 or more.
- [ ] No em-dash in `CHANGELOG.md` entries added by this task.
- [ ] Existing `CHANGELOG.md` content is preserved unchanged.

**Steps:**

- [ ] Step 1: Read `CHANGELOG.md` in full to find the `[Unreleased]` section and understand existing entry format.
- [ ] Step 2: Under `[Unreleased]`, add or extend a `### Added` section with one bullet per deliverable. Use the existing bullet style (e.g., `- **hook-name**: description`). List the 9 new optional task metadata fields in a sub-list or parenthetical. Do not use em-dash.
- [ ] Step 3: Run the verify `grep -c` command and confirm >= 6.

**BlockedBy:** [task-001, task-002, task-003, task-004, task-005, task-006, task-007, task-008, task-009]

---

## Test strategy

Each hook has its own `.test.sh` co-located in `hooks/team/`. All 4 test files are registered in `tests/run-all.sh`. The existing `lib/validate-task-metadata.test.sh` gains new cases for optional fields. The full suite is validated with `bash tests/run-all.sh`. Skills and schema changes are validated via `grep -c` verify commands in each task.

## Rollback plan

All new files are additive. If VERIFY fails after merges:

1. Delete the 4 new `hooks/team/*.sh` and 4 new `hooks/team/*.test.sh` files.
2. Revert `hooks/hooks.json` to its state before task-008.
3. Revert `tests/run-all.sh` to its state before task-009.
4. Revert the `### Added` bullets added to `CHANGELOG.md` by task-010.
5. Revert the 9 new rows added to `skills/shared/feature-state-schema.md` and the type-checking additions to `lib/validate-task-metadata.sh`.
6. Delete `skills/checking-gates/SKILL.md` and `skills/specifying-gates/SKILL.md`.

No compiled artifacts, no database migrations, no external state to roll back.
