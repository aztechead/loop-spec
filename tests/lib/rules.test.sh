#!/usr/bin/env bash
# Unit tests for lib/rules.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/rules.sh"
PASS=0
FAIL=0
pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
RF="$WORK/RULES.md"

r() { LOOP_SPEC_RULES_FILE="$RF" bash "$SCRIPT" "$@"; }

# Case 1: render empty before any rules -> no output, exit 0
out="$(r render)"; rc=$?
[[ -z "$out" && "$rc" -eq 0 ]] && pass "render empty -> silent" || fail "render empty -> silent (got '$out' rc=$rc)"

# Case 2: add a rule -> "added", file created, bullet present
out="$(r add "Never widen a type to make it compile")"
[[ "$out" == "added" ]] && pass "add prints added" || fail "add prints added (got '$out')"
grep -Fq "Never widen a type to make it compile" "$RF" && pass "rule persisted" || fail "rule persisted"
grep -q "## Rules" "$RF" && pass "header written" || fail "header written"

# Case 3: idempotent add -> "exists", not duplicated
out="$(r add "Never widen a type to make it compile")"
[[ "$out" == "exists" ]] && pass "dup add -> exists" || fail "dup add -> exists (got '$out')"
count=$(grep -Fc "Never widen a type to make it compile" "$RF")
[[ "$count" -eq 1 ]] && pass "no duplicate line" || fail "no duplicate line (count=$count)"

# Case 4: add with deterministic --check records the command
r add "Every migration must be reversible" --check "make migrate-check" >/dev/null
grep -Fq 'check: `make migrate-check`' "$RF" && pass "deterministic check recorded" || fail "deterministic check recorded"

# Case 5: list emits rule text only, no bullet prefix
listout="$(r list)"
echo "$listout" | grep -Fq "Every migration must be reversible" && pass "list shows rule" || fail "list shows rule"
echo "$listout" | grep -q '^- \[' && fail "list stripped prefix" || pass "list stripped prefix"

# Case 6: render now emits the full file
rout="$(r render)"
echo "$rout" | grep -q "# RULES.md" && pass "render emits body" || fail "render emits body"

# Case 7: empty add rejected
if r add "" >/dev/null 2>&1; then fail "empty add rejected"; else pass "empty add rejected"; fi

# Case 8: path prints resolved file
[[ "$(r path)" == "$RF" ]] && pass "path resolves" || fail "path resolves"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
