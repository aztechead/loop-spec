#!/usr/bin/env bash
# Test suite for hooks/team/deferral-guard.sh
# Stop hook: block completion claims carrying self-authored deferred items.
# Usage: bash hooks/team/deferral-guard.test.sh
set -euo pipefail

HOOK="$(dirname "$0")/deferral-guard.sh"
TEST_ROOT="${TMPDIR:-/tmp}/claude-hooks-test-$$"
TRACE_LOG="$TEST_ROOT/deferral-trace.log"
STATE_DIR="$TEST_ROOT/deferral-state"
export LOOP_SPEC_DEFERRAL_TRACE_LOG="$TRACE_LOG"
export LOOP_SPEC_DEFERRAL_STATE_DIR="$STATE_DIR"

PASS=0
FAIL=0

check() {
  local name="$1"
  local expected_exit="$2"
  local payload="$3"
  shift 3
  local actual_exit=0

  if [[ $# -gt 0 ]]; then
    echo "$payload" | env "$@" bash "$HOOK" >/dev/null 2>&1 || actual_exit=$?
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

payload_with_text() {
  local text="$1"
  printf '{"stop_reason":"end_turn","transcript":[{"role":"assistant","content":[{"type":"text","text":"%s"}]}]}' \
    "$text"
}

# Production Stop payload: transcript_path points at Claude Code JSONL.
payload_file_with_text() {
  local text="$1"
  local transcript="$(dirname "$TRACE_LOG")/transcript-${RANDOM}-${RANDOM}.jsonl"
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s"}]}}\n' \
    "$text" > "$transcript"
  printf '{"stop_reason":"end_turn","transcript_path":"%s"}' "$transcript"
}

mkdir -p "$(dirname "$TRACE_LOG")"

echo "=== deferral-guard.sh tests ==="

# a: kill-switch -> exit 0 even on a would-block payload
check "a: kill-switch ALLOW" 0 \
  "$(payload_with_text "Cycle complete. Deferred items: flaky test cleanup.")" \
  LOOP_SPEC_DEFERRAL_GUARD=0 \
  LOOP_SPEC_DEFERRAL_TRACE_LOG="$TRACE_LOG"

# b: fail-open: empty payload -> exit 0
check "b: fail-open empty payload ALLOW" 0 ""

# c: fail-open: malformed JSON -> exit 0
check "c: fail-open malformed JSON ALLOW" 0 "not-valid-json {"

# d: the canonical sin: completion claim + "Deferred items:" -> exit 2
check "d: completion + deferred items DENY" 2 \
  "$(payload_with_text "Cycle complete. Deferred items: tighten validation.")"

# e: completion claim + follow-ups -> exit 2
check "e: completion + follow-ups DENY" 2 \
  "$(payload_with_text "All acceptance criteria pass. Follow-ups: add caching in a later PR.")"

# f: clean completion claim -> exit 0
check "f: clean completion ALLOW" 0 \
  "$(payload_with_text "Converged. PR opened and ready for review. All acceptance criteria pass.")"

# g: deferral language WITHOUT a completion claim (design conversation) -> exit 0
check "g: design discussion of scope ALLOW" 0 \
  "$(payload_with_text "We could defer the caching question until the interview settles boundaries. Thoughts?")"

# h: gate-marked deferral in a completion report -> exit 0 (rule-driven, not self-authored)
check "h: gate-marked deferral ALLOW" 0 \
  "$(payload_with_text "Cycle complete. iterate-budget-spent: gap X recorded to backlog after the iteration limit.")"

# i: stop_hook_active is not a bypass for a direct violation.
check "i: stop_hook_active direct violation DENY" 2 \
  '{"stop_hook_active":true,"stop_reason":"end_turn","transcript":[{"role":"assistant","content":[{"type":"text","text":"Cycle complete. Deferred items: x."}]}]}'

# j: production transcript_path payload -> exit 2
check "j: production transcript_path DENY" 2 \
  "$(payload_file_with_text "Feature complete and shipped. Future work: better errors.")"

# k: no assistant text -> exit 0
check "k: no assistant text ALLOW" 0 '{"stop_reason":"end_turn","transcript":[]}'

# l-o: a denial is transcript-scoped. A wording-only retry remains blocked, and
# even fabricated tool history is insufficient without a material repo change.
REMEDIATION_REPO="$TEST_ROOT/remediation-repo"
REMEDIATION_TRANSCRIPT="$TEST_ROOT/remediation.jsonl"
mkdir -p "$REMEDIATION_REPO/.loop-spec"
git -C "$REMEDIATION_REPO" init -q -b main
git -C "$REMEDIATION_REPO" config user.name "Deferral Guard Test"
git -C "$REMEDIATION_REPO" config user.email "deferral-guard@example.invalid"
printf 'base\n' > "$REMEDIATION_REPO/app.txt"
git -C "$REMEDIATION_REPO" add app.txt
git -C "$REMEDIATION_REPO" commit -qm "base"

printf '%s\n' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"Cycle complete. Follow-up: tighten validation."}]}}' \
  > "$REMEDIATION_TRANSCRIPT"
REMEDIATION_PAYLOAD="$(printf '{"stop_reason":"end_turn","transcript_path":"%s"}' "$REMEDIATION_TRANSCRIPT")"
ACTIVE_REMEDIATION_PAYLOAD="$(printf '{"stop_hook_active":true,"stop_reason":"end_turn","transcript_path":"%s"}' "$REMEDIATION_TRANSCRIPT")"

check "l: first denial records obligation" 2 "$REMEDIATION_PAYLOAD" \
  CLAUDE_PROJECT_DIR="$REMEDIATION_REPO"

printf '%s\n' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"Cycle complete. All acceptance criteria pass."}]}}' \
  >> "$REMEDIATION_TRANSCRIPT"
check "m: wording-only retry stays DENY" 2 "$ACTIVE_REMEDIATION_PAYLOAD" \
  CLAUDE_PROJECT_DIR="$REMEDIATION_REPO"

printf '%s\n' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"app.txt"}}]}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"pytest -q"}}]}}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"Cycle complete.\nResolved scope: validation — app.txt; pytest passed."}]}}' \
  >> "$REMEDIATION_TRANSCRIPT"
check "n: claimed tools without repo change stay DENY" 2 "$ACTIVE_REMEDIATION_PAYLOAD" \
  CLAUDE_PROJECT_DIR="$REMEDIATION_REPO"

printf 'implemented\n' >> "$REMEDIATION_REPO/app.txt"
printf '%s\n' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"app.txt"}}]}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bash tests/validation.test.sh"}}]}}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"Cycle complete.\nResolved scope: validation — app.txt; validation test passed."}]}}' \
  >> "$REMEDIATION_TRANSCRIPT"
check "o: changed repo plus ordered verification clears obligation" 0 "$ACTIVE_REMEDIATION_PAYLOAD" \
  CLAUDE_PROJECT_DIR="$REMEDIATION_REPO"

# p: trace-log line written
if [[ -f "$TRACE_LOG" ]]; then
  if grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T.*\|deferral-guard\|' "$TRACE_LOG"; then
    echo "PASS: p: trace-log contains pipe-separated line"
    ((PASS++)) || true
  else
    echo "FAIL: p: trace-log exists but no matching line"
    head -5 "$TRACE_LOG" | sed 's/^/  /'
    ((FAIL++)) || true
  fi
else
  echo "FAIL: p: trace-log file not written at $TRACE_LOG"
  ((FAIL++)) || true
fi

rm -rf "$TEST_ROOT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
