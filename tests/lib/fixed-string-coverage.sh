#!/usr/bin/env bash
set -uo pipefail

COVERAGE_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
cd "$COVERAGE_TEST_DIR/.."
PASS=0
FAIL=0

check_fixed_strings() {
  local entry file needle
  for entry in "$@"; do
    file="${entry%%	*}"
    needle="${entry#*	}"
    if [[ -f "$file" ]] && grep -qF -e "$needle" "$file"; then
      PASS=$((PASS+1)); echo "PASS: $file contains '$needle'"
    else
      FAIL=$((FAIL+1)); echo "FAIL: $file missing '$needle'"
    fi
  done
}

finish_fixed_string_coverage() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  [[ "$FAIL" -eq 0 ]] || exit 1
}
