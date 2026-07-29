#!/usr/bin/env bash
# Test suite for hooks/team/deferral-guard.sh
# Stop hook: block completion claims carrying self-authored deferred items.
# Usage: bash hooks/team/deferral-guard.test.sh
set -euo pipefail

HOOK="$(dirname "$0")/deferral-guard.sh"
TRACE_LOG="${TMPDIR:-/tmp}/claude-hooks-test-$$/deferral-trace.log"
export LOOP_SPEC_DEFERRAL_TRACE_LOG="$TRACE_LOG"

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

# i: stop_hook_active continuation -> exit 0 (no re-block)
check "i: stop_hook_active ALLOW" 0 \
  '{"stop_hook_active":true,"stop_reason":"end_turn","transcript":[{"role":"assistant","content":[{"type":"text","text":"Cycle complete. Deferred items: x."}]}]}'

# j: production transcript_path payload -> exit 2
check "j: production transcript_path DENY" 2 \
  "$(payload_file_with_text "Feature complete and shipped. Future work: better errors.")"

# k: no assistant text -> exit 0
check "k: no assistant text ALLOW" 0 '{"stop_reason":"end_turn","transcript":[]}'

# l: trace-log line written
if [[ -f "$TRACE_LOG" ]]; then
  if grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T.*\|deferral-guard\|' "$TRACE_LOG"; then
    echo "PASS: l: trace-log contains pipe-separated line"
    ((PASS++)) || true
  else
    echo "FAIL: l: trace-log exists but no matching line"
    head -5 "$TRACE_LOG" | sed 's/^/  /'
    ((FAIL++)) || true
  fi
else
  echo "FAIL: l: trace-log file not written at $TRACE_LOG"
  ((FAIL++)) || true
fi

rm -rf "$(dirname "$TRACE_LOG")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
