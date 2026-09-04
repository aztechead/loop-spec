#!/usr/bin/env bash
# Behavioural checks for the parallel/selected test runner itself.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ALL="$ROOT/tests/run-all.sh"
PASS=0
FAIL=0

# The suite itself can be launched by run-all's selected profile. Nested runner
# checks must start from a clean environment or they inherit and recursively select us.
unset RUN_ALL_PROFILE RUN_ALL_ONLY_PATHS RUN_ALL_JOBS RUN_ALL_VERBOSE

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"
    FAIL=$((FAIL + 1))
  fi
}

rc=0
out="$(RUN_ALL_JOBS=0 bash "$RUN_ALL" 2>&1)" || rc=$?
check "zero workers is rejected before suites start" "2" "$rc"
check "invalid worker diagnostic is specific" "1" \
  "$(grep -c 'RUN_ALL_JOBS must be a positive integer' <<<"$out")"

rc=0
out="$(RUN_ALL_PROFILE=selected bash "$RUN_ALL" 2>&1)" || rc=$?
check "selected mode requires an explicit suite list" "2" "$rc"

out="$(RUN_ALL_PROFILE=selected \
  RUN_ALL_ONLY_PATHS=tests/design-coverage.test.sh \
  RUN_ALL_JOBS=2 bash "$RUN_ALL")"
check "selected mode runs its named suite" "1" \
  "$(grep -c '^PASS: tests/design-coverage ' <<<"$out")"
check "selected mode reports one passing suite" "1" \
  "$(grep -c '^Suites passed: 1$' <<<"$out")"
check "successful suite detail stays quiet by default" "0" \
  "$(grep -c '^Results:' <<<"$out")"

out="$(RUN_ALL_PROFILE=selected \
  RUN_ALL_ONLY_PATHS=tests/design-coverage.test.sh \
  RUN_ALL_VERBOSE=1 bash "$RUN_ALL")"
check "verbose mode includes successful suite detail" "1" \
  "$(grep -c '^Results:' <<<"$out")"

out="$(RUN_ALL_PROFILE=selected \
  RUN_ALL_ONLY_PATHS=tests/lib/bounded-run.test.sh \
  bash "$RUN_ALL")"
check "selected mode includes explicitly requested integration suites" "1" \
  "$(grep -c '^Suites passed: 1$' <<<"$out")"
check "selected integration suite executes" "1" \
  "$(grep -c '^PASS: lib/bounded-run ' <<<"$out")"

rc=0
out="$(RUN_ALL_PROFILE=selected RUN_ALL_ONLY_PATHS=tests/does-not-exist.test.sh bash "$RUN_ALL" 2>&1)" || rc=$?
check "unknown selected suite cannot report success" "2" "$rc"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
