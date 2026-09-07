#!/usr/bin/env bash
# Tests for lib/fixlist-route.sh -- who applies a finding: the lead, or the re-dispatched author.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/lib/fixlist-route.sh"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; ((FAIL++)) || true
  fi
}

# The live round-1 fix list: every item names a task and a field.
live='["[major] Missing dependency: task-005 is not blockedBy task-002, so it can capture a stale state.",
  "[major] task-003 hard-codes the real bucket settings with no reconciling ASSUMPTION verify.",
  "[minor] task-004 hardcoded ../../../../ depth is asserted as a fixed string."]'
out="$(bash "$LIB" route - <<<"$live")"
check "task-scoped findings route to the lead" "ANSWER=lead REASON=3 lead-editable, 0 for the author" "$(tail -1 <<<"$out")"
check "one line per finding" "3" "$(grep -c $'^lead\t' <<<"$out")"

# Grounding-section findings are the lead's too (it runs the probes).
out="$(bash "$LIB" route - <<<'["PLAN.md:374: ASSUMPTION verify command fails bash -n syntax check", "cite EVID-009 for the if_exists claim in ## Grounding"]')"
check "grounding findings route to the lead" "lead" "$(tail -1 <<<"$out" | sed 's/ANSWER=\([a-z]*\).*/\1/')"

# Structural findings go back to the author, even when they name a task.
out="$(bash "$LIB" route - <<<'["No task covers the README rewrite the SPEC requires; add a task.", "Split task-002 into the audit and the fixes: one verify cannot cover both."]')"
check "structural findings route to the author" "ANSWER=author REASON=0 lead-editable, 2 for the author" "$(tail -1 <<<"$out")"

# A mix is split, and the per-line routing says which is which.
out="$(bash "$LIB" route - <<<'["task-001 verify must anchor with ^", "The architecture section contradicts the SPEC decision on module layout."]')"
check "a mix answers split" "split" "$(tail -1 <<<"$out" | sed 's/ANSWER=\([a-z]*\).*/\1/')"
check "the architecture finding is the author's" "1" "$(grep -c $'^author\t2\t' <<<"$out")"

# Unplaceable prose fails safe to the author.
out="$(bash "$LIB" route - <<<'["This plan feels thin."]')"
check "an unplaceable finding goes to the author" "author" "$(tail -1 <<<"$out" | sed 's/ANSWER=\([a-z]*\).*/\1/')"

# Failure paths are loud.
ec=0; bash "$LIB" route - <<<'not json' >/dev/null 2>&1 || ec=$?
check "non-JSON input exits 2" "2" "$ec"
ec=0; bash "$LIB" route /nonexistent.json >/dev/null 2>&1 || ec=$?
check "missing file exits 2" "2" "$ec"
ec=0; bash "$LIB" >/dev/null 2>&1 || ec=$?
check "no arguments exits 2" "2" "$ec"

echo
echo "fixlist-route: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
