#!/usr/bin/env bash
# Test suite for hooks/team/done-criteria.sh
# UserPromptSubmit hook: compound task detection.
# Usage: bash hooks/team/done-criteria.test.sh
set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/done-criteria.sh"

PASS=0
FAIL=0

# check_output <name> <needle> <payload> [env_var=value ...]
# Asserts hook exits 0 and stdout contains needle.
check_output() {
  local name="$1"
  local needle="$2"
  local payload="$3"
  shift 3
  local actual_exit=0
  local actual_stdout

  actual_stdout=$(printf '%s' "$payload" | env "$@" bash "$HOOK" 2>/dev/null) || actual_exit=$?

  if [[ "$actual_exit" -eq 0 ]] && echo "$actual_stdout" | grep -q "$needle"; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (exit=$actual_exit; needle='$needle' not found in: $actual_stdout)"
    ((FAIL++)) || true
  fi
}

# check_silent <name> <payload> [env_var=value ...]
# Asserts hook exits 0 and produces no stdout.
check_silent() {
  local name="$1"
  local payload="$2"
  shift 2
  local actual_exit=0
  local actual_stdout

  actual_stdout=$(printf '%s' "$payload" | env "$@" bash "$HOOK" 2>/dev/null) || actual_exit=$?

  if [[ "$actual_exit" -eq 0 ]] && [[ -z "$actual_stdout" ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (exit=$actual_exit; stdout='$actual_stdout')"
    ((FAIL++)) || true
  fi
}

echo "=== done-criteria.sh tests ==="

# 1. Numbered list trigger: prompt with "1. foo 2. bar" -> additionalContext injected
NUMBERED_PROMPT="Please do the following: 1. Create a new feature branch. 2. Implement the change. 3. Write tests."
NUMBERED_PAYLOAD=$(printf '{"prompt":"%s"}' "$NUMBERED_PROMPT")
check_output "1: numbered list trigger injects additionalContext" \
  "additionalContext" \
  "$NUMBERED_PAYLOAD"

# 2. Multi-verb "and" trigger: "create X and update Y" -> additionalContext injected
MULTVERB_PAYLOAD='{"prompt":"Please create the new config file and update the existing README to reference it, so users know about it."}'
check_output "2: multi-verb and trigger injects additionalContext" \
  "additionalContext" \
  "$MULTVERB_PAYLOAD"

# 3. Bullet list trigger: 2+ lines starting with "- " -> additionalContext injected
BULLET_PROMPT="Do these things:\n- Install the dependency\n- Run the migration script\n- Verify the output"
BULLET_PAYLOAD=$(printf '{"prompt":"%s"}' "$BULLET_PROMPT")
check_output "3: bullet list trigger injects additionalContext" \
  "additionalContext" \
  "$BULLET_PAYLOAD"

# 4. Kill switch: SUPER_SPEC_DONE_CRITERIA=0 -> exit 0, no output
check_silent "4: kill switch exits 0 silently" \
  "$NUMBERED_PAYLOAD" \
  SUPER_SPEC_DONE_CRITERIA=0

# 5. Fail-open: malformed JSON -> exit 0, no output
check_silent "5: fail-open on malformed JSON exits 0 silently" \
  "not valid json {{{"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
