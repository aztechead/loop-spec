#!/usr/bin/env bash
# Unit tests for lib/model-tier.sh
set -euo pipefail
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/model-tier.sh"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }
mt() { bash "$SCRIPT" "$@"; }

[[ "$(mt model mechanical --harness claude)"   == "haiku"   ]] && pass "mechanical+claude -> haiku"   || fail "mechanical+claude -> haiku"
[[ "$(mt model mechanical --harness opencode)" == "inherit" ]] && pass "mechanical+opencode -> inherit" || fail "mechanical+opencode -> inherit"
[[ "$(mt model mechanical --harness adk)"      == "inherit" ]] && pass "mechanical+adk -> inherit"    || fail "mechanical+adk -> inherit"
[[ "$(mt model mechanical --harness codex)"    == "inherit" ]] && pass "mechanical+codex -> inherit"  || fail "mechanical+codex -> inherit"
[[ "$(mt model standard --harness claude)"     == "inherit" ]] && pass "standard+claude -> inherit"   || fail "standard+claude -> inherit"
[[ "$(mt model frontier --harness claude)"     == "inherit" ]] && pass "frontier+claude -> inherit"   || fail "frontier+claude -> inherit"
[[ "$(mt model --harness claude)"              == "inherit" ]] && pass "empty -> inherit"             || fail "empty -> inherit"
[[ "$(mt model garbage --harness claude)"      == "inherit" ]] && pass "unknown -> inherit"           || fail "unknown -> inherit"

[[ "$(mt upgrade haiku --harness claude)"      == "sonnet"  ]] && pass "upgrade haiku+claude -> sonnet" || fail "upgrade haiku+claude -> sonnet"
[[ "$(mt upgrade inherit --harness claude)"    == "inherit" ]] && pass "upgrade inherit stays inherit"  || fail "upgrade inherit stays inherit"
[[ "$(mt upgrade haiku --harness opencode)"    == "haiku"   ]] && pass "upgrade haiku+opencode stays"   || fail "upgrade haiku+opencode stays"

mt valid frontier  && pass "valid frontier" || fail "valid frontier"
mt valid mechanical && pass "valid mechanical" || fail "valid mechanical"
if mt valid nonsense; then fail "invalid rejected"; else pass "invalid rejected"; fi

echo ""; echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
