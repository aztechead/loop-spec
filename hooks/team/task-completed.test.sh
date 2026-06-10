#!/usr/bin/env bash
# Test suite for hooks/team/task-completed.sh
# TaskCompleted hook: phase-aware quality gate on task completion.
# Usage: bash hooks/team/task-completed.test.sh
set -euo pipefail

HOOK="$(dirname "$0")/task-completed.sh"
TMPDIR_TESTS="${TMPDIR:-/tmp}/task-completed-tests-$$"
mkdir -p "$TMPDIR_TESTS"

PASS=0
FAIL=0

check() {
  local name="$1"
  local expected_exit="$2"
  local payload="$3"
  local feature_json="${4:-}"
  local actual_exit=0
  local env_args=()

  if [[ -n "$feature_json" ]]; then
    local fdir="$TMPDIR_TESTS/$name"
    mkdir -p "$fdir"
    printf '%s' "$feature_json" > "$fdir/feature.json"
    env_args=(LOOP_SPEC_FEATURE_DIR="$fdir")
  fi

  if [[ ${#env_args[@]} -gt 0 ]]; then
    echo "$payload" | env "${env_args[@]}" bash "$HOOK" >/dev/null 2>&1 || actual_exit=$?
  else
    echo "$payload" | bash "$HOOK" >/dev/null 2>&1 || actual_exit=$?
  fi

  if [[ "$actual_exit" -eq "$expected_exit" ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected exit $expected_exit, got $actual_exit)"
    ((FAIL++)) || true
  fi
}

# Build a TaskCompleted payload (loop-spec-marked via subject convention)
payload_completed() {
  local task_id="${1:-task-001}"
  printf '{"tool_name":"TaskCompleted","tool_input":{"taskId":"%s","subject":"%s: do the thing","metadata":{"loopSpec":true}}}' "$task_id" "$task_id"
}

# Build an UNMARKED TaskCompleted payload (ordinary task tracking)
payload_completed_unmarked() {
  local task_id="${1:-7}"
  printf '{"tool_name":"TaskCompleted","tool_input":{"taskId":"%s","subject":"Refactor the parser"}}' "$task_id"
}

# feature.json fixture: EXECUTE phase with lint and typecheck commands
feature_execute() {
  printf '{
  "schemaVersion": 3,
  "slug": "test-feature",
  "currentPhase": "execute",
  "commands": {
    "test": "bash tests/smoke.sh",
    "lint": "echo lint-ok",
    "typecheck": "echo typecheck-ok"
  }
}'
}

# feature.json fixture: EXECUTE phase with failing lint
feature_execute_failing_lint() {
  printf '{
  "schemaVersion": 3,
  "slug": "test-feature",
  "currentPhase": "execute",
  "commands": {
    "lint": "exit 1",
    "typecheck": "echo typecheck-ok"
  }
}'
}

# feature.json fixture: DISCUSS phase (schema validation mode)
feature_discuss() {
  printf '{
  "schemaVersion": 3,
  "slug": "test-feature",
  "currentPhase": "discuss",
  "commands": {}
}'
}

# feature.json fixture: PLAN phase (schema validation mode)
feature_plan() {
  printf '{
  "schemaVersion": 3,
  "slug": "test-feature",
  "currentPhase": "plan",
  "commands": {}
}'
}

# feature.json fixture: EXECUTE with no commands
feature_execute_no_commands() {
  printf '{
  "schemaVersion": 3,
  "slug": "test-feature",
  "currentPhase": "execute",
  "commands": {}
}'
}

# Build a TaskCompleted payload with task metadata for discuss/plan validation
# (marked loop-spec via subject convention so the metadata gate applies)
payload_completed_with_metadata() {
  local task_id="${1:-task-001}"
  local metadata="${2:-}"
  if [[ -z "$metadata" ]]; then metadata="{}"; fi
  printf '{"tool_name":"TaskCompleted","tool_input":{"taskId":"%s","subject":"%s: gated work","metadata":%s}}' \
    "$task_id" "$task_id" "$metadata"
}

echo "=== task-completed.sh tests ==="

# A: Missing feature.json (no LOOP_SPEC_FEATURE_DIR set) -> ALLOW (exit 0)
check "A: missing feature.json graceful exit 0" 0 \
  "$(payload_completed)"

# B: EXECUTE phase, lint+typecheck pass -> ALLOW (exit 0)
check "B: execute phase lint+typecheck pass ALLOW" 0 \
  "$(payload_completed)" \
  "$(feature_execute)"

# C: EXECUTE phase, failing lint -> DENY (exit 2)
check "C: execute phase failing lint DENY" 2 \
  "$(payload_completed)" \
  "$(feature_execute_failing_lint)"

# D: EXECUTE phase, no commands configured -> ALLOW (exit 0)
check "D: execute phase no commands ALLOW" 0 \
  "$(payload_completed)" \
  "$(feature_execute_no_commands)"

# E: DISCUSS phase, valid task metadata -> ALLOW (exit 0)
VALID_META='{"blockedBy":[],"files":["foo.sh"],"verifyCommand":"bash t.sh","acceptanceCriteria":["works"]}'
check "E: discuss phase valid metadata ALLOW" 0 \
  "$(payload_completed_with_metadata "task-001" "$VALID_META")" \
  "$(feature_discuss)"

# F: DISCUSS phase, missing verifyCommand -> DENY (exit 2)
MISSING_VERIFY='{"blockedBy":[],"files":["foo.sh"],"acceptanceCriteria":["works"]}'
check "F: discuss phase missing verifyCommand DENY" 2 \
  "$(payload_completed_with_metadata "task-001" "$MISSING_VERIFY")" \
  "$(feature_discuss)"

# G: PLAN phase, missing acceptanceCriteria -> DENY (exit 2)
MISSING_AC='{"blockedBy":[],"files":["foo.sh"],"verifyCommand":"bash t.sh"}'
check "G: plan phase missing acceptanceCriteria DENY" 2 \
  "$(payload_completed_with_metadata "task-001" "$MISSING_AC")" \
  "$(feature_plan)"

# H: PLAN phase with valid metadata -> ALLOW (exit 0)
check "H: plan phase valid metadata ALLOW" 0 \
  "$(payload_completed_with_metadata "task-001" "$VALID_META")" \
  "$(feature_plan)"

# I: UNMARKED completion in EXECUTE phase with failing lint -> ALLOW (scope: pass-through)
check "I: unmarked task passes through failing-lint gate ALLOW" 0 \
  "$(payload_completed_unmarked)" \
  "$(feature_execute_failing_lint)"

# J: UNMARKED completion in DISCUSS phase without metadata -> ALLOW (scope: pass-through)
check "J: unmarked task passes through discuss metadata gate ALLOW" 0 \
  "$(payload_completed_unmarked)" \
  "$(feature_discuss)"

# J2: kill switch -> ALLOW even for marked task with failing lint
check_exit=0
fdir_ks="$TMPDIR_TESTS/kill-switch"
mkdir -p "$fdir_ks"
printf '%s' "$(feature_execute_failing_lint)" > "$fdir_ks/feature.json"
echo "$(payload_completed)" | LOOP_SPEC_FEATURE_DIR="$fdir_ks" LOOP_SPEC_TASK_GUARD=0 bash "$HOOK" >/dev/null 2>&1 || check_exit=$?
if [[ "$check_exit" -eq 0 ]]; then
  echo "PASS: J2: kill switch ALLOW"
  ((PASS++)) || true
else
  echo "FAIL: J2: kill switch ALLOW (expected 0, got $check_exit)"
  ((FAIL++)) || true
fi

# J3: malformed payload -> ALLOW (fail-open)
check "J3: malformed payload fail-open ALLOW" 0 \
  'not json at all' \
  "$(feature_execute_failing_lint)"

# K: EXECUTE phase with LOOP_SPEC_FEATURE_DIR pointing to empty dir -> ALLOW (exit 0)
EMPTY_DIR="$TMPDIR_TESTS/empty-dir"
mkdir -p "$EMPTY_DIR"
check_exit=0
echo "$(payload_completed)" | LOOP_SPEC_FEATURE_DIR="$EMPTY_DIR" bash "$HOOK" >/dev/null 2>&1 || check_exit=$?
if [[ "$check_exit" -eq 0 ]]; then
  echo "PASS: K: feature dir exists but no feature.json exit 0"
  ((PASS++)) || true
else
  echo "FAIL: K: feature dir exists but no feature.json (expected 0, got $check_exit)"
  ((FAIL++)) || true
fi

# Cleanup
rm -rf "$TMPDIR_TESTS"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
