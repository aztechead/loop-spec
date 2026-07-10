#!/usr/bin/env bash
# inject-test-lib.sh - shared assertion helpers for the SessionStart inject-hook
# test suites (micro/grill/simplicity). Source this after setting:
#   HOOK  - absolute path to the hook under test
#   PASS  - integer pass counter (the helpers increment it)
#   FAIL  - integer fail counter (the helpers increment it)
# Not a test suite itself (not *.test.sh); tests/all-tests-registered.test.sh
# intentionally does not require it in run-all.sh.

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
