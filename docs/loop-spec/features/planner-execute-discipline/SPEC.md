# Planner + EXECUTE discipline hardening

**Slug:** `planner-execute-discipline`
**Created:** 2026-05-28
**Tier:** quick
**Execution style:** auto

## Problem

loop-spec's planner and EXECUTE phase have six concrete failure modes that let bad plans and incomplete runs pass undetected:

1. Planner acceptance criteria use subjective phrases ("looks correct", "properly configured", "align X with Y") that give implementers no measurable target. The planner prompt has no banned-phrase list and no structural requirement for concrete form.
2. SPEC.md decisions can be silently dropped at plan time. No gate checks whether each decision named in the spec appears in at least one PLAN.md task.
3. EXECUTE Step 10 trusts harness task completion without verifying every PLAN.md task ID has a corresponding completed harness entry. Gaps go undetected.
4. After each worktree `git merge --ff-only`, no test suite runs. A task branch can introduce a regression that passes the reviewer's local verify command but breaks the integrated branch. The gsd-redux execute-phase workflow (Step 9) identifies this as the "generator self-evaluation blind spot."
5. Implementer agents can loop on the same failing approach without any behavioral interrupt. No consecutive-failure counter forces a strategy change.
6. No budget ceiling exists. A runaway session can exhaust cost with no warning or block.

<decisions>
- Decision: banned phrases list lives in `agents/loop-spec-planner.md` (not a separate linting script), enforced by prose instruction.
- Decision: decision coverage gate is ADVISORY on quick tier (log warning, proceed) and BLOCKING on quality and balanced tiers (re-dispatch planner).
- Decision: post-merge test gate is skipped entirely on quick tier; runs on quality and balanced tiers with hard-block on failure.
- Decision: strategy-rotation hook tracks per-tool consecutive failures in a temp JSON file keyed by SESSION env var.
- Decision: budget-gate hook reads cost from `metrics-session.json` if present, falls back to `LOOP_SPEC_CURRENT_COST_USD` env var; if `LOOP_SPEC_MAX_COST_USD` is unset the hook exits 0 unconditionally.
- Decision: `agents/loop-spec-spec-writer.md` is updated to require a `<decisions>` block in SPEC.md output (currently optional). No other SPEC.md sections are added or restructured.
- Decision: `lib/plan-adherence.sh` extracts PLAN task IDs via the regex `^### task-\d+:` and outputs JSON; gap detection compares those IDs against harness completed task subjects (which embed the plan task ID).
- Decision: all new hooks are fail-open and expose a kill-switch environment variable.
</decisions>

## Goals

- Require every planner acceptance criterion to contain at least one concrete form (exact value, regex pattern, exit code, file path, grep pattern, or JSON path) and ban subjective phrases by rule in the planner agent.
- Gate plan commit on decision coverage: every `<decisions>` entry in SPEC.md must appear in at least one PLAN.md task body.
- Gate EXECUTE phase exit on plan adherence: every PLAN.md task ID must have a matching completed harness entry.
- Gate each post-merge integration point with an auto-detected or configured test command on quality and balanced tiers.
- Interrupt looping implementers after a configurable consecutive-failure threshold, forcing explicit strategy verbalization before the next attempt.
- Warn at 80% and block at 100% of a configurable cost ceiling per session.

## Non-goals

- Ralph remediation executor (Cycle 4).
- Forensics command (Cycle 4).
- Any Cycle 4 or Cycle 5 items.
- Making the decision coverage gate hard-blocking on quick tier (it is advisory only on quick).
- Making the post-merge test gate run on quick tier (it is skipped on quick).
- Restructuring SPEC.md sections beyond adding the `<decisions>` block requirement.
- Removing or modifying any Cycle 1 or Cycle 2 hooks.

## Constraints

- Runtime: `bash`, `git`, `jq`, `python3` stdlib only. No npm, pip, or brew dependencies.
- All new hooks are opt-in via kill-switch environment variables (`LOOP_SPEC_STRATEGY_ROTATION=0`, `LOOP_SPEC_BUDGET_GUARD=0`).
- All new hooks are fail-open: any read error, JSON parse failure, or missing env var causes exit 0.
- Commit format: `<type>: NO_JIRA <message>`.
- References used for behavioral design:
  - `/Users/cbobrowitz/Projects/_reference/gsd-redux/get-shit-done/workflows/plan-phase.md` Section 13a (decision coverage gate pattern)
  - `/Users/cbobrowski/Projects/_reference/gsd-redux/get-shit-done/workflows/execute-phase.md` Step 9 (post-merge test gate pattern)
  - `/Users/cbobrowitz/Projects/_reference/claude-octopus/hooks/strategy-rotation.sh` (consecutive-failure interrupt pattern)
  - `/Users/cbobrowski/Projects/_reference/claude-octopus/hooks/budget-gate.sh` (cost threshold gate pattern)

## User-facing behavior

**Anti-shallow planner rules.** The planner agent document gains a BANNED PHRASES section listing phrases that must not appear in acceptance criteria ("looks correct", "properly configured", "consistent with", "align X with Y", "matches Y", "well-formed" without an explicit schema reference). It gains a REQUIRED CONCRETE FORM rule: every acceptance criterion must contain at least one of an exact value, a regex pattern, an exit code, a file path, a grep command, or a JSON path expression. Each task gains a mandatory `read_first:` field (empty list is allowed, but the field must be present). The PLAN.md template is updated to show these fields with checkbox-format acceptance criteria.

An anti-patterns reference doc at `docs/loop-spec/planner-antipatterns.md` shows six do/don't pairs that illustrate the difference between banned and required forms.

**Decision coverage gate.** After the plan critique gate (or immediately after planner output on quick tier), the plan skill invokes `lib/decision-coverage.sh <spec-path> <plan-path>` before committing PLAN.md. The script extracts each line inside the `<decisions>...</decisions>` block in SPEC.md and checks whether it appears verbatim or by keyword in any PLAN.md task body (acceptanceCriteria, read_first, or Steps). On quality and balanced tiers, an uncovered decision re-dispatches the planner with the gap list. On quick tier, a warning is logged and the plan proceeds. If no `<decisions>` block exists, the gate is skipped with a warning.

**Plan-adherence exit check.** Before EXECUTE Step 10 declares the phase complete, the lead invokes `lib/plan-adherence.sh <plan-path>`. The script parses every heading matching `^### task-\d+:` in PLAN.md, emits a JSON object `{plan_task_ids: [...], gap_message: "..." | null}`, and the lead compares that list against harness `TaskList({status: "completed"})` subjects. If any plan task ID has no matching completed harness entry and is not in the remediation list, the lead blocks exit and escalates via `AskUserQuestion`.

**Post-merge build/test gate.** After each successful `git merge --ff-only` of a task branch (Step 8 of EXECUTE), the lead runs the test command. The command is sourced from `feature.json.commands.test` if set; otherwise `lib/detect-test-cmd.sh` auto-detects it by probing for `Makefile`, `package.json`, `Cargo.toml`, `pyproject.toml`, `setup.py`, and `go.mod`. On test failure the lead creates a remediation task and routes back to the implementer phase. This gate runs on quality and balanced tiers only; it is logged-as-skipped on quick tier.

**Strategy-rotation hook.** A new `hooks/team/strategy-rotation.sh` fires on `PostToolUse` for Bash, Edit, and Write tools. It tracks consecutive tool failures per tool name in `/tmp/loop-spec-failures-${SESSION:-default}.json`. When consecutive failures reach the threshold (default 2, overridden by `LOOP_SPEC_STRATEGY_ROTATION_THRESHOLD`), the hook emits a `hookSpecificOutput.additionalContext` block instructing the agent to stop, verbalize what the failure mode was, describe a completely different approach, and explain why the new approach avoids the same failure. The counter resets on any successful tool call. Setting `LOOP_SPEC_STRATEGY_ROTATION=0` disables the hook.

**Budget-gate hook.** A new `hooks/team/budget-gate.sh` fires on `PreToolUse` for Agent tool calls. It reads current session cost from `metrics-session.json` if present, otherwise from the `LOOP_SPEC_CURRENT_COST_USD` env var. If `LOOP_SPEC_MAX_COST_USD` is unset, the hook exits 0 unconditionally. At 80-99% of the ceiling it emits a `hookSpecificOutput.additionalContext` warning. At 100% or above it exits 2, blocking the Agent call. Setting `LOOP_SPEC_BUDGET_GUARD=0` disables the hook.

**hooks.json wiring.** A `PreToolUse` entry with matcher `Agent` runs `budget-gate.sh`. A `PostToolUse` entry with matcher `Bash|Edit|Write` runs `strategy-rotation.sh`.

## Success criteria

- [ ] `agents/loop-spec-planner.md` contains a `read_first[]` requirement per task with language specifying it must contain concrete file identifiers.
  Verify: `grep -c "read_first" agents/loop-spec-planner.md` returns 1 or more.

- [ ] `agents/loop-spec-planner.md` contains a banned-phrases section with the phrase "BANNED" or "MUST NOT" near a list that includes "looks correct" and "properly configured".
  Verify: `grep -A 10 "BANNED\|MUST NOT" agents/loop-spec-planner.md | grep -c "looks correct\|properly configured"` returns 1 or more.

- [ ] `docs/loop-spec/planner-antipatterns.md` exists with at least one do/don't pair.
  Verify: `grep -c "DO NOT\|BAD\|GOOD\|Instead\|instead" docs/loop-spec/planner-antipatterns.md` returns 1 or more.

- [ ] `skills/shared/artifact-templates/PLAN.md.template` contains a `read_first:` line and checkbox-format acceptance criteria (`- [ ]`).
  Verify: `grep -c "read_first:\|- \[ \]" skills/shared/artifact-templates/PLAN.md.template` returns 2 or more.

- [ ] `lib/decision-coverage.sh` exists and exits 0 when all `<decisions>` block entries in the given SPEC appear in the given PLAN.
  Verify: `bash lib/decision-coverage.sh <(echo '<decisions>\n- Decision: use bash\n</decisions>') <(echo 'use bash in task') ; echo $?` prints `0`.

- [ ] `lib/decision-coverage.sh` exits 1 and prints an uncovered-decisions list when at least one `<decisions>` entry is absent from PLAN.
  Verify: `bash lib/decision-coverage.sh <(echo '<decisions>\n- Decision: use python\n</decisions>') <(echo 'no python here') ; echo $?` prints `1` and a non-empty uncovered list.

- [ ] `skills/plan/SKILL.md` Step 5 (commit) is preceded by a `decision-coverage.sh` invocation that gates on its exit code (verify grep confirms the invocation reference).
  Verify: `grep -c "decision-coverage.sh" skills/plan/SKILL.md` returns 1 or more.

- [ ] `agents/loop-spec-spec-writer.md` requires a `<decisions>` block in the SPEC.md output (verify grep confirms a `<decisions>` or `decisions block` requirement in the agent prompt).
  Verify: `grep -c "<decisions>" agents/loop-spec-spec-writer.md` returns 1 or more.

- [ ] `lib/plan-adherence.sh` exists and outputs a JSON object with `plan_task_ids` array and `gap_message` string or null.
  Verify: `bash lib/plan-adherence.sh /dev/stdin <<< '### task-001: do a thing' | jq '.plan_task_ids | length'` returns 1.

- [ ] `skills/execute/SKILL.md` Step 10 references `lib/plan-adherence.sh` and gates phase exit on gap detection.
  Verify: `grep -c "plan-adherence.sh" skills/execute/SKILL.md` returns 1 or more.

- [ ] `lib/detect-test-cmd.sh` exists and prints a test command string or empty string for the current repo.
  Verify: `bash lib/detect-test-cmd.sh ; echo "exit:$?"` exits 0 and prints a string (possibly empty).

- [ ] `skills/execute/SKILL.md` Step 8 (merge queue) references `commands.test` or `detect-test-cmd.sh` and describes running the test command after each successful ff-only merge.
  Verify: `grep -c "detect-test-cmd.sh\|commands.test" skills/execute/SKILL.md` returns 1 or more.

- [ ] `hooks/team/strategy-rotation.sh` exists and is executable.
  Verify: `test -x hooks/team/strategy-rotation.sh && echo PASS`.

- [ ] `hooks/team/strategy-rotation.sh` emits a `hookSpecificOutput` additionalContext block when consecutive failures reach the threshold.
  Verify: `bash hooks/team/strategy-rotation.test.sh` passes the "threshold trigger" case.

- [ ] `hooks/team/strategy-rotation.sh` resets the failure counter on a successful tool call and honors `LOOP_SPEC_STRATEGY_ROTATION=0` kill switch.
  Verify: `bash hooks/team/strategy-rotation.test.sh` passes the "success reset" and "kill switch" cases.

- [ ] `hooks/team/strategy-rotation.sh` exits 0 on malformed JSON input or missing session file (fail-open).
  Verify: `bash hooks/team/strategy-rotation.test.sh` passes the "fail-open" case.

- [ ] `hooks/team/budget-gate.sh` exists and is executable.
  Verify: `test -x hooks/team/budget-gate.sh && echo PASS`.

- [ ] `hooks/team/budget-gate.sh` emits a warning additionalContext when cost is between 80% and 99% of `LOOP_SPEC_MAX_COST_USD`.
  Verify: `bash hooks/team/budget-gate.test.sh` passes the "warn at 80%" case.

- [ ] `hooks/team/budget-gate.sh` exits 2 when cost is at or above 100% of `LOOP_SPEC_MAX_COST_USD`.
  Verify: `bash hooks/team/budget-gate.test.sh` passes the "block at 100%" case.

- [ ] `hooks/team/budget-gate.sh` exits 0 when `LOOP_SPEC_MAX_COST_USD` is unset and when `LOOP_SPEC_BUDGET_GUARD=0`.
  Verify: `bash hooks/team/budget-gate.test.sh` passes the "no ceiling" and "kill switch" cases.

- [ ] `hooks/team/budget-gate.sh` exits 0 on malformed JSON or missing metrics file (fail-open).
  Verify: `bash hooks/team/budget-gate.test.sh` passes the "fail-open" case.

- [ ] `hooks/hooks.json` contains a `PreToolUse` entry with matcher `Agent` that runs `budget-gate.sh` and a `PostToolUse` entry with matcher `Bash|Edit|Write` that runs `strategy-rotation.sh`.
  Verify: `jq '.hooks.PreToolUse | map(select(.matcher == "Agent")) | length' hooks/hooks.json` returns 1; `jq '.hooks.PostToolUse | map(select(.matcher | test("Bash"))) | length' hooks/hooks.json` returns 1.

- [ ] `bash tests/run-all.sh` exits 0 with no failures (all existing suites plus the two new test files pass).
  Verify: `bash tests/run-all.sh`.

- [ ] `bash tests/validate-agents.sh` exits 0 with output `All 12 agents validated.` (no agent file count change).
  Verify: `bash tests/validate-agents.sh | grep "All 12 agents validated."`.

- [ ] No em-dash character (U+2014) appears in any new or modified file.
  Verify: `grep -rP "—" agents/loop-spec-planner.md docs/loop-spec/planner-antipatterns.md skills/shared/artifact-templates/PLAN.md.template lib/decision-coverage.sh lib/plan-adherence.sh lib/detect-test-cmd.sh hooks/team/strategy-rotation.sh hooks/team/budget-gate.sh hooks/hooks.json agents/loop-spec-spec-writer.md skills/plan/SKILL.md skills/execute/SKILL.md CHANGELOG.md` returns no matches.

- [ ] `CHANGELOG.md` contains entries under `[Unreleased]` documenting all six enforcement additions: anti-shallow planner rules, decision coverage gate, plan-adherence exit check, post-merge test gate, strategy-rotation hook, and budget-gate hook.
  Verify: `grep -c "anti-shallow\|decision-coverage\|plan-adherence\|detect-test-cmd\|strategy-rotation\|budget-gate" CHANGELOG.md` returns 6 or more.

## Out of scope

- Ralph remediation executor. The transcript considered integrating Ralph's loop stop-condition as a full remediation executor; only the plan-adherence exit check is included. The executor is deferred to Cycle 4.
- Forensics command. Considered for surfacing root causes of blocked tasks; deferred to Cycle 4.
- Hard-blocking decision coverage gate on quick tier. The gate runs in advisory mode only on quick tier; a full blocking re-dispatch cycle was considered and explicitly excluded for the quick tier to preserve its speed profile.
- Post-merge test gate on quick tier. Running tests after each merge on quick tier was considered and explicitly excluded; quick tier skips this gate entirely (logged).
- Mandatory (non-opt-in) budget ceiling. A hard system-level cost cap without a kill switch was considered and rejected because it would block sessions that intentionally operate without a ceiling.
- Strategy-rotation on all tool events. Limiting the hook to Bash, Edit, and Write (not Read or Agent) was an explicit choice to avoid counting informational reads as failures.

## Open questions

(none - resolved during DISCUSS phase)
