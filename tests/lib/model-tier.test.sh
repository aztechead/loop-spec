#!/usr/bin/env bash
# Unit tests for lib/model-tier.sh
set -euo pipefail
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/model-tier.sh"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }
mt() { bash "$SCRIPT" "$@"; }

[[ "$(mt model mechanical)" == "sonnet" ]] && pass "mechanical -> sonnet" || fail "mechanical -> sonnet"
[[ "$(mt model standard)"   == "sonnet" ]] && pass "standard -> sonnet"   || fail "standard -> sonnet"
[[ "$(mt model frontier)"   == "opus"   ]] && pass "frontier -> opus"     || fail "frontier -> opus"
[[ "$(mt model)"            == "sonnet" ]] && pass "empty -> standard"    || fail "empty -> standard"
[[ "$(mt model garbage)"    == "sonnet" ]] && pass "unknown -> standard"  || fail "unknown -> standard"

mt valid frontier  && pass "valid frontier" || fail "valid frontier"
mt valid mechanical && pass "valid mechanical" || fail "valid mechanical"
if mt valid nonsense; then fail "invalid rejected"; else pass "invalid rejected"; fi

echo ""; echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
