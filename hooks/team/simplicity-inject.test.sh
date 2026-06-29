#!/usr/bin/env bash
# Test suite for hooks/team/simplicity-inject.sh
#
# Simplicity mode is DEFAULT ON at level "full", self-scoped to loop-spec
# projects (a .loop-spec/ dir must exist). Polarity matches grill-inject:
# with .loop-spec present, absent conf => inject; ENABLED=0 or kill switch =>
# silent. LEVEL= in the conf selects the injected intensity line.
set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/simplicity-inject.sh"
TMPDIR_TEST="${TMPDIR:-/tmp}/simplicity-inject-test-$$"
mkdir -p "$TMPDIR_TEST"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0
FAIL=0

check_output() {
  local name="$1" expected_exit="$2" grep_pattern="$3"; shift 3
  local actual_exit=0 actual_output=""
  actual_output=$(env "$@" bash "$HOOK" 2>/dev/null) || actual_exit=$?
  local exit_ok=0 output_ok=0
  [[ "$actual_exit" -eq "$expected_exit" ]] && exit_ok=1
  printf '%s' "$actual_output" | grep -q "$grep_pattern" && output_ok=1
  if [[ "$exit_ok" -eq 1 && "$output_ok" -eq 1 ]]; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name"
    [[ "$exit_ok" -eq 0 ]] && echo "  expected exit $expected_exit, got $actual_exit"
    [[ "$output_ok" -eq 0 ]] && { echo "  no match: $grep_pattern"; echo "  output: $actual_output"; }
    ((FAIL++)) || true
  fi
}

check_no_pattern() {
  local name="$1" expected_exit="$2" absent_pattern="$3"; shift 3
  local actual_exit=0 actual_output=""
  actual_output=$(env "$@" bash "$HOOK" 2>/dev/null) || actual_exit=$?
  local exit_ok=0 output_ok=0
  [[ "$actual_exit" -eq "$expected_exit" ]] && exit_ok=1
  printf '%s' "$actual_output" | grep -q "$absent_pattern" || output_ok=1
  if [[ "$exit_ok" -eq 1 && "$output_ok" -eq 1 ]]; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name"; echo "  output: $actual_output"; ((FAIL++)) || true
  fi
}

check_valid_json() {
  local name="$1"; shift
  local out; out=$(env "$@" bash "$HOOK" 2>/dev/null) || true
  if printf '%s' "$out" | jq . >/dev/null 2>&1; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name (invalid JSON: $out)"; ((FAIL++)) || true
  fi
}

echo "=== simplicity-inject.sh tests ==="

# --- loop-spec project, no conf -> default ON at full ---
LS="$TMPDIR_TEST/proj"; mkdir -p "$LS/.loop-spec"
check_output "a: loop-spec project, absent conf -> hookSpecificOutput" 0 "hookSpecificOutput" CLAUDE_PROJECT_DIR="$LS"
check_output "b: default on -> SIMPLICITY MODE ACTIVE" 0 "SIMPLICITY MODE ACTIVE" CLAUDE_PROJECT_DIR="$LS"
check_output "c: default level is full" 0 "LEVEL full" CLAUDE_PROJECT_DIR="$LS"
check_valid_json "d: default on -> valid JSON" CLAUDE_PROJECT_DIR="$LS"

# --- self-scoping: NO .loop-spec dir -> silent ---
NOPROJ="$TMPDIR_TEST/noproj"; mkdir -p "$NOPROJ"
check_no_pattern "e: no .loop-spec dir -> silent" 0 "additionalContext" CLAUDE_PROJECT_DIR="$NOPROJ"

# --- ENABLED=1 + LEVEL=ultra -> injects ultra ---
ULT="$TMPDIR_TEST/ultra"; mkdir -p "$ULT/.loop-spec"; printf 'ENABLED=1\nLEVEL=ultra\n' > "$ULT/.loop-spec/simplicity.conf"
check_output "f: LEVEL=ultra -> ultra intensity" 0 "LEVEL ultra" CLAUDE_PROJECT_DIR="$ULT"

# --- LEVEL=lite -> injects lite ---
LITE="$TMPDIR_TEST/lite"; mkdir -p "$LITE/.loop-spec"; printf 'ENABLED=1\nLEVEL=lite\n' > "$LITE/.loop-spec/simplicity.conf"
check_output "g: LEVEL=lite -> lite intensity" 0 "LEVEL lite" CLAUDE_PROJECT_DIR="$LITE"

# --- garbage LEVEL -> falls back to full ---
BAD="$TMPDIR_TEST/bad"; mkdir -p "$BAD/.loop-spec"; printf 'ENABLED=1\nLEVEL=bogus\n' > "$BAD/.loop-spec/simplicity.conf"
check_output "h: garbage LEVEL -> full fallback" 0 "LEVEL full" CLAUDE_PROJECT_DIR="$BAD"

# --- ENABLED=0 -> silent ---
DIS="$TMPDIR_TEST/disabled"; mkdir -p "$DIS/.loop-spec"; printf 'ENABLED=0\n' > "$DIS/.loop-spec/simplicity.conf"
check_no_pattern "i: ENABLED=0 -> silent" 0 "additionalContext" CLAUDE_PROJECT_DIR="$DIS"

# --- kill switch -> silent even with .loop-spec + default ---
check_no_pattern "j: LOOP_SPEC_SIMPLICITY=0 -> silent" 0 "additionalContext" CLAUDE_PROJECT_DIR="$LS" LOOP_SPEC_SIMPLICITY=0

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
