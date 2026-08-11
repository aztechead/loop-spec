#!/usr/bin/env bash
# Unit tests for lib/model-tier.sh
set -euo pipefail
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/model-tier.sh"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }
mt() { bash "$SCRIPT" "$@"; }

[[ "$(mt model mechanical)" == "inherit" ]] && pass "mechanical -> inherit" || fail "mechanical -> inherit"
[[ "$(mt model standard)"   == "inherit" ]] && pass "standard -> inherit"   || fail "standard -> inherit"
[[ "$(mt model frontier)"   == "inherit" ]] && pass "frontier -> inherit"   || fail "frontier -> inherit"
[[ "$(mt model)"            == "inherit" ]] && pass "empty -> inherit"       || fail "empty -> inherit"
[[ "$(mt model garbage)"    == "inherit" ]] && pass "unknown -> inherit"     || fail "unknown -> inherit"

mt valid frontier  && pass "valid frontier" || fail "valid frontier"
mt valid mechanical && pass "valid mechanical" || fail "valid mechanical"
if mt valid nonsense; then fail "invalid rejected"; else pass "invalid rejected"; fi

echo ""; echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
