#!/usr/bin/env bash
# Test suite for hooks/team/grill-inject.sh
# Usage: bash hooks/team/grill-inject.test.sh
#
# Grill mode is DEFAULT ON, so the polarity is inverted vs discipline-inject:
# absent conf file => inject; ENABLED=0 or kill switch => silent.
set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/grill-inject.sh"
TMPDIR_TEST="${TMPDIR:-/tmp}/grill-inject-test-$$"
mkdir -p "$TMPDIR_TEST"

PASS=0
FAIL=0

check_output() {
  local name="$1"
  local expected_exit="$2"
  local grep_pattern="$3"
  shift 3
  local actual_exit=0
  local actual_output=""

  actual_output=$(env "$@" bash "$HOOK" 2>/dev/null) || actual_exit=$?

  local exit_ok=0
  local output_ok=0
  [[ "$actual_exit" -eq "$expected_exit" ]] && exit_ok=1
  printf '%s' "$actual_output" | grep -q "$grep_pattern" && output_ok=1

  if [[ "$exit_ok" -eq 1 && "$output_ok" -eq 1 ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    [[ "$exit_ok" -eq 0 ]] && echo "  expected exit $expected_exit, got $actual_exit"
    [[ "$output_ok" -eq 0 ]] && { echo "  output did not match pattern: $grep_pattern"; echo "  actual output: $actual_output"; }
    ((FAIL++)) || true
  fi
}

check_no_pattern() {
  local name="$1"
  local expected_exit="$2"
  local absent_pattern="$3"
  shift 3
  local actual_exit=0
  local actual_output=""

  actual_output=$(env "$@" bash "$HOOK" 2>/dev/null) || actual_exit=$?

  local exit_ok=0
  local output_ok=0
  [[ "$actual_exit" -eq "$expected_exit" ]] && exit_ok=1
  printf '%s' "$actual_output" | grep -q "$absent_pattern" || output_ok=1

  if [[ "$exit_ok" -eq 1 && "$output_ok" -eq 1 ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    [[ "$exit_ok" -eq 0 ]] && echo "  expected exit $expected_exit, got $actual_exit"
    [[ "$output_ok" -eq 0 ]] && { echo "  output unexpectedly matched: $absent_pattern"; echo "  actual output: $actual_output"; }
    ((FAIL++)) || true
  fi
}

echo "=== grill-inject.sh tests ==="

# --- Test: default ON (no conf file) -> injects ---
NO_CONF_DIR="$TMPDIR_TEST/noconf"
mkdir -p "$NO_CONF_DIR"

check_output "a: default on (absent conf) - outputs hookSpecificOutput" 0 \
  "hookSpecificOutput" \
  CLAUDE_PROJECT_DIR="$NO_CONF_DIR"

check_output "b: default on - GRILL MODE ACTIVE present" 0 \
  "GRILL MODE ACTIVE" \
  CLAUDE_PROJECT_DIR="$NO_CONF_DIR"

check_output "c: default on - additionalContext present" 0 \
  "additionalContext" \
  CLAUDE_PROJECT_DIR="$NO_CONF_DIR"

# --- Test: ENABLED=1 in conf -> still injects ---
ENABLED_DIR="$TMPDIR_TEST/enabled/.loop-spec"
mkdir -p "$ENABLED_DIR"
printf 'ENABLED=1\n' > "$ENABLED_DIR/grill.conf"

check_output "d: ENABLED=1 - injects" 0 \
  "GRILL MODE ACTIVE" \
  CLAUDE_PROJECT_DIR="$TMPDIR_TEST/enabled"

# --- Test: ENABLED=0 in conf -> silent ---
DISABLED_DIR="$TMPDIR_TEST/disabled/.loop-spec"
mkdir -p "$DISABLED_DIR"
printf 'ENABLED=0\n' > "$DISABLED_DIR/grill.conf"

check_no_pattern "e: ENABLED=0 - no additionalContext injected" 0 \
  "additionalContext" \
  CLAUDE_PROJECT_DIR="$TMPDIR_TEST/disabled"

# --- Test: kill switch -> silent even with default-on ---
check_no_pattern "f: kill switch LOOP_SPEC_GRILL=0 - no injection" 0 \
  "additionalContext" \
  CLAUDE_PROJECT_DIR="$NO_CONF_DIR" \
  LOOP_SPEC_GRILL=0

# Cleanup
rm -rf "$TMPDIR_TEST"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
