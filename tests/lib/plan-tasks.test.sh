#!/usr/bin/env bash
# Tests for lib/plan-tasks.sh -- tasks[] derived from PLAN.md, never from a message.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/lib/plan-tasks.sh"
LINT="$REPO_ROOT/lib/artifact-lint.sh"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then PASS=$((PASS+1)); echo "PASS: $name"
  else FAIL=$((FAIL+1)); echo "FAIL: $name (expected '$expected', got '$actual')"; fi
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/plan-tasks-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/PLAN.md" <<'MD'
# Export - Implementation Plan

## Task DAG

| ID | Subject | BlockedBy | Files | Est scope |
|----|---------|-----------|-------|-----------|
| task-001 | add the endpoint | - | api/export.py | small |
| task-002 | write the CSV | task-001 | lib/csv.py, tests/test_csv.py | small |
| task-003 | wire the flag | task-001, task-002 | api/flags.py | small |

## Tasks

### task-001: add the endpoint

**Goal:** one sentence.

**Files:**
- `api/export.py`

**read_first:**
- `api/routes.py:10-40`

**Interfaces:**
- consumes: none
- produces: `GET /export` returning 202

**Verify:** `pytest tests/test_export.py` -> 1 passed

**Acceptance criteria:**
- [ ] `pytest tests/test_export.py` exits 0
- [x] the route is registered

**Steps (TDD where applicable):**

- [ ] Step 1: Write failing test (tests/test_export.py)

**BlockedBy:** []

### task-002: write the CSV

**Goal:** one sentence.

**Files**:
- `lib/csv.py`
- `tests/test_csv.py`

**Verify:** `pytest tests/test_csv.py`

**Acceptance criteria:**
- [ ] `pytest tests/test_csv.py` exits 0

**Repo:** `api`
**Model tier:** mechanical

### task-003: wire the flag

**Goal:** one sentence.

**Files:**
- `api/flags.py`

**Verify:** `pytest tests/test_flags.py`

**Acceptance criteria:**
- [ ] `pytest tests/test_flags.py` exits 0

## Test strategy

pytest.
MD

out="$(bash "$LIB" extract "$tmp/PLAN.md")"
check "three blocks yield three tasks" "3" "$(jq 'length' <<<"$out")"
check "id and subject from the heading" "task-001 add the endpoint" \
  "$(jq -r '.[0] | "\(.id) \(.subject)"' <<<"$out")"
check "files stripped of backticks" "api/export.py" "$(jq -r '.[0].files[0]' <<<"$out")"
check "read_first becomes readFirst" "api/routes.py:10-40" "$(jq -r '.[0].readFirst[0]' <<<"$out")"
check "verify command is the first backtick span" "pytest tests/test_export.py" \
  "$(jq -r '.[0].verifyCommand' <<<"$out")"
check "checked and unchecked criteria both count" "2" \
  "$(jq '.[0].acceptanceCriteria | length' <<<"$out")"
check "steps are not criteria" "0" \
  "$(jq '[.[0].acceptanceCriteria[] | select(startswith("Step"))] | length' <<<"$out")"
check "interfaces keep produces and drop none" '{"produces":"`GET /export` returning 202"}' \
  "$(jq -c '.[0].interfaces' <<<"$out")"
check "block BlockedBy [] wins" "[]" "$(jq -c '.[0].blockedBy' <<<"$out")"
check "colon-outside-bold marker parses" "2" "$(jq '.[1].files | length' <<<"$out")"
check "DAG table supplies blockedBy when the block has none" '["task-001","task-002"]' \
  "$(jq -c '.[2].blockedBy' <<<"$out")"
check "repo and model tier from optional lines" "api mechanical" \
  "$(jq -r '.[1] | "\(.repo) \(.modelTier)"' <<<"$out")"
check "absent optional lines are absent keys" "null null" \
  "$(jq -r '.[2] | "\(.repo) \(.readFirst)"' <<<"$out")"
rc=0; bash "$LINT" tasks - <<<"$out" >/dev/null 2>&1 || rc=$?
check "extracted tasks pass the tasks lint" "0" "$rc"

# The repo's real PLAN fixture round-trips through the lint too.
out="$(bash "$LIB" extract "$REPO_ROOT/tests/fixtures/real-PLAN.md")"
check "real PLAN fixture yields every block" "10" "$(jq 'length' <<<"$out")"
check "real PLAN fixture blockedBy from the block line" '["task-004","task-005","task-006","task-007"]' \
  "$(jq -c '.[7].blockedBy' <<<"$out")"
rc=0; bash "$LINT" tasks - <<<"$out" >/dev/null 2>&1 || rc=$?
check "real PLAN fixture passes the tasks lint" "0" "$rc"

# --- failure paths ---

printf '# Plan\n\n## Tasks\n\nnothing yet\n' > "$tmp/empty.md"
rc=0; out="$(bash "$LIB" extract "$tmp/empty.md" 2>&1)" || rc=$?
check "no blocks exits 1, never an empty array" "1" "$rc"
check "no blocks names the file" "1" "$(grep -c 'no .### task-NNN:. blocks' <<<"$out")"
rc=0; bash "$LIB" extract "$tmp/missing.md" >/dev/null 2>&1 || rc=$?
check "unreadable file exits 1" "1" "$rc"
rc=0; bash "$LIB" parse "$tmp/PLAN.md" >/dev/null 2>&1 || rc=$?
check "unknown subcommand exits 2" "2" "$rc"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
