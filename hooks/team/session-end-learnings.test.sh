#!/usr/bin/env bash
# Test suite for hooks/team/session-end-learnings.sh
# Stop hook: JSONL learnings append with FIFO cap.
# Usage: bash hooks/team/session-end-learnings.test.sh
set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/session-end-learnings.sh"
TMPDIR_TEST="${TMPDIR:-/tmp}/session-end-learnings-test-$$"
mkdir -p "$TMPDIR_TEST"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

echo "=== session-end-learnings.sh tests ==="

# ---------------------------------------------------------------------------
# Test 1: append - running the hook once adds exactly 1 JSONL line.
# ---------------------------------------------------------------------------
TEST1_DIR="$TMPDIR_TEST/test1"
# The hook is scoped to projects that already use super-spec: .super-spec/ must
# pre-exist (the hook never creates it in arbitrary projects).
mkdir -p "$TEST1_DIR/.super-spec"

PAYLOAD='{"total_agent_calls":1,"errors":[],"workflow":"build"}'
printf '%s' "$PAYLOAD" | env CLAUDE_PROJECT_DIR="$TEST1_DIR" bash "$HOOK" 2>/dev/null

LEARNINGS_FILE="$TEST1_DIR/.super-spec/learnings.jsonl"
if [[ -f "$LEARNINGS_FILE" ]]; then
  LINE_COUNT=$(wc -l < "$LEARNINGS_FILE" | tr -d ' ')
  if [[ "$LINE_COUNT" -eq 1 ]]; then
    # Verify the line is valid JSON with required keys.
    LINE=$(head -1 "$LEARNINGS_FILE")
    if command -v python3 &>/dev/null; then
      KEYS_OK=$(python3 -c "
import json, sys
line = json.loads(sys.argv[1])
required = ['timestamp','sessionId','taskType','approach','outcome','lesson']
missing = [k for k in required if k not in line]
print('ok' if not missing else 'missing:' + ','.join(missing))
" "$LINE" 2>/dev/null || echo "parse-error")
      if [[ "$KEYS_OK" == "ok" ]]; then
        pass "1: append - file grows by 1 line with valid JSONL"
      else
        fail "1: append - JSONL key check failed: $KEYS_OK"
      fi
    else
      pass "1: append - file grew by 1 line (python3 unavailable, JSON content not verified)"
    fi
  else
    fail "1: append - expected 1 line, got $LINE_COUNT"
  fi
else
  fail "1: append - learnings.jsonl not created"
fi

# ---------------------------------------------------------------------------
# Test 2: cap at 50 - write 60 lines, verify final count is exactly 50.
# ---------------------------------------------------------------------------
TEST2_DIR="$TMPDIR_TEST/test2"
mkdir -p "$TEST2_DIR/.super-spec"

# Pre-populate with 60 lines.
LEARNINGS_FILE2="$TEST2_DIR/.super-spec/learnings.jsonl"
for i in $(seq 1 60); do
  printf '{"timestamp":"2026-01-01T00:00:00Z","sessionId":"seed-%d","taskType":"general","approach":"agents=0 task_type=general","outcome":"success","lesson":"session completed"}\n' "$i" >> "$LEARNINGS_FILE2"
done

# Run hook once more (adds 1 line -> 61 total, then trimmed to 50).
PAYLOAD2='{"total_agent_calls":0,"errors":[]}'
printf '%s' "$PAYLOAD2" | env CLAUDE_PROJECT_DIR="$TEST2_DIR" bash "$HOOK" 2>/dev/null

FINAL_COUNT=$(wc -l < "$LEARNINGS_FILE2" | tr -d ' ')
if [[ "$FINAL_COUNT" -eq 50 ]]; then
  pass "2: cap at 50 - file trimmed to 50 lines when over 50"
else
  fail "2: cap at 50 - expected 50 lines, got $FINAL_COUNT"
fi

# ---------------------------------------------------------------------------
# Test 3: kill switch - SUPER_SPEC_LEARNINGS=0 -> exit 0, file untouched.
# ---------------------------------------------------------------------------
TEST3_DIR="$TMPDIR_TEST/test3"
mkdir -p "$TEST3_DIR"
LEARNINGS_FILE3="$TEST3_DIR/.super-spec/learnings.jsonl"

PAYLOAD3='{"total_agent_calls":2,"errors":[]}'
printf '%s' "$PAYLOAD3" | env CLAUDE_PROJECT_DIR="$TEST3_DIR" SUPER_SPEC_LEARNINGS=0 bash "$HOOK" 2>/dev/null

if [[ ! -f "$LEARNINGS_FILE3" ]]; then
  pass "3: kill switch - file not created when SUPER_SPEC_LEARNINGS=0"
else
  fail "3: kill switch - file was written despite kill switch"
fi

# ---------------------------------------------------------------------------
# Test 3b: scope - project without .super-spec/ is never touched.
# ---------------------------------------------------------------------------
TEST3B_DIR="$TMPDIR_TEST/test3b"
mkdir -p "$TEST3B_DIR"

PAYLOAD3B='{"total_agent_calls":2,"errors":[]}'
printf '%s' "$PAYLOAD3B" | env CLAUDE_PROJECT_DIR="$TEST3B_DIR" bash "$HOOK" 2>/dev/null

if [[ ! -d "$TEST3B_DIR/.super-spec" ]]; then
  pass "3b: scope - .super-spec/ not created in non-super-spec project"
else
  fail "3b: scope - hook created .super-spec/ in a project that never used super-spec"
fi

# ---------------------------------------------------------------------------
# Test 4: heuristic lessons - >3 agents produces "parallel dispatch effective".
# ---------------------------------------------------------------------------
TEST4_DIR="$TMPDIR_TEST/test4"
mkdir -p "$TEST4_DIR/.super-spec"
LEARNINGS_FILE4="$TEST4_DIR/.super-spec/learnings.jsonl"

PAYLOAD4='{"total_agent_calls":5,"errors":[],"workflow":"build"}'
printf '%s' "$PAYLOAD4" | env CLAUDE_PROJECT_DIR="$TEST4_DIR" bash "$HOOK" 2>/dev/null

if [[ -f "$LEARNINGS_FILE4" ]]; then
  LINE4=$(head -1 "$LEARNINGS_FILE4")
  if printf '%s' "$LINE4" | grep -q "parallel dispatch effective"; then
    pass "4: heuristic lessons - >3 agents produces 'parallel dispatch effective'"
  else
    fail "4: heuristic lessons - lesson field did not contain expected text; got: $LINE4"
  fi
else
  fail "4: heuristic lessons - learnings.jsonl not created"
fi

# Cleanup.
rm -rf "$TMPDIR_TEST"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
