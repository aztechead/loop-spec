#!/usr/bin/env bash
# Test suite for hooks/team/discipline-inject.sh
# Usage: bash hooks/team/discipline-inject.test.sh
set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/discipline-inject.sh"
TMPDIR_TEST="${TMPDIR:-/tmp}/discipline-inject-test-$$"
mkdir -p "$TMPDIR_TEST"

PASS=0
FAIL=0

check() {
  local name="$1"
  local expected_exit="$2"
  shift 2
  local actual_exit=0
  local actual_output=""

  actual_output=$(env "$@" bash "$HOOK" 2>/dev/null) || actual_exit=$?

  if [[ "$actual_exit" -eq "$expected_exit" ]]; then
    echo "PASS: $name (exit $actual_exit)"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected exit $expected_exit, got $actual_exit)"
    ((FAIL++)) || true
  fi
  printf '%s' "$actual_output"
}

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

  if [[ "$actual_exit" -eq "$expected_exit" ]]; then
    exit_ok=1
  fi

  if printf '%s' "$actual_output" | grep -q "$grep_pattern"; then
    output_ok=1
  fi

  if [[ "$exit_ok" -eq 1 && "$output_ok" -eq 1 ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    if [[ "$exit_ok" -eq 0 ]]; then
      echo "  expected exit $expected_exit, got $actual_exit"
    fi
    if [[ "$output_ok" -eq 0 ]]; then
      echo "  output did not match pattern: $grep_pattern"
      echo "  actual output: $actual_output"
    fi
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

  if [[ "$actual_exit" -eq "$expected_exit" ]]; then
    exit_ok=1
  fi

  if ! printf '%s' "$actual_output" | grep -q "$absent_pattern"; then
    output_ok=1
  fi

  if [[ "$exit_ok" -eq 1 && "$output_ok" -eq 1 ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    if [[ "$exit_ok" -eq 0 ]]; then
      echo "  expected exit $expected_exit, got $actual_exit"
    fi
    if [[ "$output_ok" -eq 0 ]]; then
      echo "  output unexpectedly matched pattern: $absent_pattern"
      echo "  actual output: $actual_output"
    fi
    ((FAIL++)) || true
  fi
}

echo "=== discipline-inject.sh tests ==="

# --- Test: enabled inject ---
# conf file present with ENABLED=1 -> outputs additionalContext with all 5 gates
CONF_DIR="$TMPDIR_TEST/enabled/.loop-spec"
mkdir -p "$CONF_DIR"
printf 'ENABLED=1\n' > "$CONF_DIR/discipline.conf"

check_output "a: enabled inject - outputs hookSpecificOutput" 0 \
  "hookSpecificOutput" \
  CLAUDE_PROJECT_DIR="$TMPDIR_TEST/enabled"

check_output "b: enabled inject - additionalContext present" 0 \
  "additionalContext" \
  CLAUDE_PROJECT_DIR="$TMPDIR_TEST/enabled"

check_output "c: enabled inject - brainstorm-before-coding gate present" 0 \
  "brainstorm-before-coding" \
  CLAUDE_PROJECT_DIR="$TMPDIR_TEST/enabled"

check_output "d: enabled inject - all 5 gates (verification-before-claims)" 0 \
  "verification-before-claims" \
  CLAUDE_PROJECT_DIR="$TMPDIR_TEST/enabled"

check_output "e: enabled inject - investigation-before-fixes gate present" 0 \
  "investigation-before-fixes" \
  CLAUDE_PROJECT_DIR="$TMPDIR_TEST/enabled"

check_output "f: enabled inject - decision-gate present" 0 \
  "decision-gate" \
  CLAUDE_PROJECT_DIR="$TMPDIR_TEST/enabled"

check_output "g: enabled inject - intent-gate present" 0 \
  "intent-gate" \
  CLAUDE_PROJECT_DIR="$TMPDIR_TEST/enabled"

# --- Test: kill switch ---
# LOOP_SPEC_DISCIPLINE=0 -> exits 0 with no additionalContext
check_no_pattern "h: kill switch - no additionalContext injected" 0 \
  "additionalContext" \
  CLAUDE_PROJECT_DIR="$TMPDIR_TEST/enabled" \
  LOOP_SPEC_DISCIPLINE=0

# --- Test: file absent ---
# No conf file -> exits 0 with no additionalContext
NO_CONF_DIR="$TMPDIR_TEST/noconf"
mkdir -p "$NO_CONF_DIR"

check_no_pattern "i: file absent - no additionalContext injected" 0 \
  "additionalContext" \
  CLAUDE_PROJECT_DIR="$NO_CONF_DIR"

# --- Test: ENABLED=0 in conf file ---
DISABLED_DIR="$TMPDIR_TEST/disabled/.loop-spec"
mkdir -p "$DISABLED_DIR"
printf 'ENABLED=0\n' > "$DISABLED_DIR/discipline.conf"

check_no_pattern "j: ENABLED=0 in conf - no additionalContext injected" 0 \
  "additionalContext" \
  CLAUDE_PROJECT_DIR="$TMPDIR_TEST/disabled"

# Cleanup
rm -rf "$TMPDIR_TEST"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
