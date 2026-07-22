#!/usr/bin/env bash
# Test suite for hooks/team/stop-deflection-guard.sh
# Stop hook: block low-context deflection phrases.
# Usage: bash hooks/team/stop-deflection-guard.test.sh
set -euo pipefail

HOOK="$(dirname "$0")/stop-deflection-guard.sh"
TRACE_LOG="${TMPDIR:-/tmp}/claude-hooks-test-$$/deflection-trace.log"
export LOOP_SPEC_DEFLECTION_TRACE_LOG="$TRACE_LOG"

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

# Payload with usage field and a given last assistant text.
# usage_tokens: total token count to place in input_tokens
payload_with_usage() {
  local text="$1"
  local input_tokens="${2:-0}"
  printf '{"stop_reason":"end_turn","usage":{"input_tokens":%d,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"transcript":[{"role":"assistant","content":[{"type":"text","text":"%s"}]}]}' \
    "$input_tokens" "$text"
}

# Payload without a usage field (for fail-open test)
payload_no_usage() {
  local text="$1"
  printf '{"stop_reason":"end_turn","transcript":[{"role":"assistant","content":[{"type":"text","text":"%s"}]}]}' \
    "$text"
}

# Production Stop payload: transcript_path points at Claude Code JSONL, where
# assistant text and usage live under message.
payload_file_with_usage() {
  local text="$1"
  local input_tokens="${2:-0}"
  local transcript="$(dirname "$TRACE_LOG")/transcript-${RANDOM}-${RANDOM}.jsonl"
  printf '{"type":"assistant","message":{"usage":{"input_tokens":%d,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"%s"}]}}\n' \
    "$input_tokens" "$text" > "$transcript"
  printf '{"stop_reason":"end_turn","transcript_path":"%s"}' "$transcript"
}

mkdir -p "$(dirname "$TRACE_LOG")"

echo "=== stop-deflection-guard.sh tests ==="

# a: kill-switch: LOOP_SPEC_DEFLECTION_GUARD=0 -> exit 0 (even with deflection phrase + low usage)
check "a: kill-switch ALLOW" 0 \
  "$(payload_with_usage "We should start a fresh session for this." 5000)" \
  LOOP_SPEC_DEFLECTION_GUARD=0 \
  LOOP_SPEC_DEFLECTION_TRACE_LOG="$TRACE_LOG"

# b: fail-open: empty payload -> exit 0
check "b: fail-open empty payload ALLOW" 0 \
  ""

# c: fail-open: malformed JSON payload -> exit 0
check "c: fail-open malformed JSON ALLOW" 0 \
  "not-valid-json {"

# d: no deflection phrase: usage low but no phrase -> exit 0
check "d: no-deflection-phrase low-usage ALLOW" 0 \
  "$(payload_with_usage "Here is the analysis of the codebase you requested." 5000)"

# e: high-context: deflection phrase present but usage=180000 out of 200000 (90%) above 50% -> exit 0
check "e: high-context deflection phrase ALLOW" 0 \
  "$(payload_with_usage "context is full, we should start a fresh session." 180000)"

# f: deflection below threshold: phrase 'context is full' + usage=15000 (7.5%) below 50% -> exit 2
check "f: deflection below threshold DENY" 2 \
  "$(payload_with_usage "The context is full, I recommend starting a fresh session." 15000)"

# g: missing usage field: deflection phrase present but no usage in payload -> exit 0 (fail-open)
check "g: missing usage field fail-open ALLOW" 0 \
  "$(payload_no_usage "We should start a fresh session to continue this work.")"

# h: deflection phrase 'running low on context' + low usage -> exit 2
check "h: running-low-on-context phrase DENY" 2 \
  "$(payload_with_usage "I am running low on context and need a fresh session." 10000)"

# i: deflection phrase 'fresh session' + low usage -> exit 2
check "i: fresh-session phrase DENY" 2 \
  "$(payload_with_usage "Let us start a fresh session to tackle this cleanly." 5000)"

# i2: stop_hook_active guard: would-block payload but stop_hook_active=true -> exit 0
#     (must not re-block a Stop-hook continuation, per Claude Code docs)
check "i2: stop_hook_active continuation ALLOW (no re-block)" 0 \
  "$(printf '{"stop_hook_active":true,"stop_reason":"end_turn","usage":{"input_tokens":5000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"transcript":[{"role":"assistant","content":[{"type":"text","text":"Let us start a fresh session to tackle this cleanly."}]}]}')"

check "i3: production transcript_path payload DENY" 2 \
  "$(payload_file_with_usage "Let us start a fresh session to tackle this cleanly." 5000)"

# j: trace-log line written: after invocations, the log file must exist and contain a pipe-separated line
if [[ -f "$TRACE_LOG" ]]; then
  if grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T.*\|stop-deflection-guard\|' "$TRACE_LOG"; then
    echo "PASS: j: trace-log contains pipe-separated line"
    ((PASS++)) || true
  else
    echo "FAIL: j: trace-log exists but no pipe-separated line matching expected format"
    echo "  Log contents:"
    head -5 "$TRACE_LOG" | sed 's/^/  /'
    ((FAIL++)) || true
  fi
else
  echo "FAIL: j: trace-log file not written at $TRACE_LOG"
  ((FAIL++)) || true
fi

# Cleanup
rm -rf "$(dirname "$TRACE_LOG")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
