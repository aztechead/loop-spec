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
GF="$WORK/global/RULES.md"

# Pin BOTH layers so a developer's real ~/.loop-spec/RULES.md never leaks in.
r() { LOOP_SPEC_RULES_FILE="$RF" LOOP_SPEC_GLOBAL_RULES_FILE="$GF" bash "$SCRIPT" "$@"; }

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

# Case 9: whole-line idempotency - a rule that is a SUBSTRING of an existing rule
# must still be added (the old substring match silently swallowed it).
r add "never log secrets in production" >/dev/null
out="$(r add "never log secrets")"
[[ "$out" == "added" ]] && pass "substring-of-existing rule still added" || fail "substring-of-existing rule still added (got '$out')"
cnt=$(grep -Fc "never log secrets" "$RF")  # matches both lines
[[ "$cnt" -eq 2 ]] && pass "both distinct rules present" || fail "both distinct rules present (cnt=$cnt)"
# But an exact repeat of the longer rule is still deduped
out="$(r add "never log secrets in production")"
[[ "$out" == "exists" ]] && pass "exact repeat still deduped" || fail "exact repeat still deduped (got '$out')"

# ── Global layer ──────────────────────────────────────────────────────────────

# Case 10: add --global writes the global file, not the project file
out="$(r add --global "Never pass --no-verify to git commit")"
[[ "$out" == "added" ]] && pass "global add prints added" || fail "global add prints added (got '$out')"
grep -Fq "Never pass --no-verify" "$GF" && pass "global rule in global file" || fail "global rule in global file"
grep -Fq "Never pass --no-verify" "$RF" && fail "global rule NOT in project file" || pass "global rule NOT in project file"

# Case 11: global add is idempotent
out="$(r add --global "Never pass --no-verify to git commit")"
[[ "$out" == "exists" ]] && pass "global dup add -> exists" || fail "global dup add -> exists (got '$out')"

# Case 12: merged list = project rules + global rules
listout="$(r list)"
echo "$listout" | grep -Fq "Never pass --no-verify" && pass "merged list has global rule" || fail "merged list has global rule"
echo "$listout" | grep -Fq "Every migration must be reversible" && pass "merged list has project rule" || fail "merged list has project rule"

# Case 13: list --global shows only global
listout="$(r list --global)"
echo "$listout" | grep -Fq "Never pass --no-verify" && pass "global list has global rule" || fail "global list has global rule"
echo "$listout" | grep -Fq "Every migration" && fail "global list excludes project rules" || pass "global list excludes project rules"

# Case 14: render includes a Global rules section
rout="$(r render)"
echo "$rout" | grep -q "## Global rules" && pass "render has global section" || fail "render has global section"
echo "$rout" | grep -Fq "Never pass --no-verify" && pass "render includes global rule" || fail "render includes global rule"
echo "$rout" | grep -q "# RULES.md" && pass "render keeps project body" || fail "render keeps project body"

# Case 15: exact duplicate across layers is emitted once (project wins)
r add "Never pass --no-verify to git commit" >/dev/null   # same text, project layer
rout="$(r render)"
cnt=$(echo "$rout" | grep -Fc "Never pass --no-verify to git commit")
[[ "$cnt" -eq 1 ]] && pass "cross-layer duplicate deduped in render" || fail "cross-layer duplicate deduped in render (cnt=$cnt)"
cnt=$(r list | grep -Fc "Never pass --no-verify to git commit")
[[ "$cnt" -eq 1 ]] && pass "cross-layer duplicate deduped in list" || fail "cross-layer duplicate deduped in list (cnt=$cnt)"

# Case 16: global-only setup renders without a project file
RF2="$WORK/other/RULES.md"
rout="$(LOOP_SPEC_RULES_FILE="$RF2" LOOP_SPEC_GLOBAL_RULES_FILE="$GF" bash "$SCRIPT" render)"
echo "$rout" | grep -q "## Global rules" && pass "global-only render works" || fail "global-only render works"

# Case 17: path --global resolves the global file
[[ "$(r path --global)" == "$GF" ]] && pass "path --global resolves" || fail "path --global resolves"
[[ "$(r path)" == "$RF" ]] && pass "path default still project" || fail "path default still project"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
