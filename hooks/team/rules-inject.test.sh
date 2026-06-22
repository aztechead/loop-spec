#!/usr/bin/env bash
# Test suite for hooks/team/rules-inject.sh
set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/rules-inject.sh"
RULES_LIB="$(cd "$(dirname "$0")/../.." && pwd)/lib/rules.sh"
TMP="${TMPDIR:-/tmp}/rules-inject-test-$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ck_has() {
  local name="$1" pat="$2"; shift 2
  local out; out=$(env "$@" bash "$HOOK" 2>/dev/null) || true
  if printf '%s' "$out" | grep -q "$pat"; then echo "PASS: $name"; ((PASS++)) || true
  else echo "FAIL: $name (missing '$pat' in: $out)"; ((FAIL++)) || true; fi
}
ck_absent() {
  local name="$1" pat="$2"; shift 2
  local out; out=$(env "$@" bash "$HOOK" 2>/dev/null) || true
  if printf '%s' "$out" | grep -q "$pat"; then echo "FAIL: $name (unexpected '$pat')"; ((FAIL++)) || true
  else echo "PASS: $name"; ((PASS++)) || true; fi
}

echo "=== rules-inject.sh tests ==="

# Non-loop-spec project -> silent
NOPROJ="$TMP/noproj"; mkdir -p "$NOPROJ"
ck_absent "a: no .loop-spec dir -> silent" "additionalContext" CLAUDE_PROJECT_DIR="$NOPROJ"

# loop-spec project but no rules -> silent
EMPTY="$TMP/empty/.loop-spec"; mkdir -p "$EMPTY"
ck_absent "b: loop-spec project, no rules -> silent" "additionalContext" CLAUDE_PROJECT_DIR="$TMP/empty"

# Add a rule, then inject -> directive carries the rule
WITH="$TMP/with"; mkdir -p "$WITH/.loop-spec"
CLAUDE_PROJECT_DIR="$WITH" bash "$RULES_LIB" add "Never skip the failing test" >/dev/null
ck_has "c: with rules -> injects directive" "SELF-LEARNING RULES ACTIVE" CLAUDE_PROJECT_DIR="$WITH"
ck_has "d: with rules -> rule text present" "Never skip the failing test" CLAUDE_PROJECT_DIR="$WITH"
ck_has "e: with rules -> additionalContext present" "additionalContext" CLAUDE_PROJECT_DIR="$WITH"

# Kill switch
ck_absent "f: kill switch LOOP_SPEC_RULES=0 -> silent" "additionalContext" \
  CLAUDE_PROJECT_DIR="$WITH" LOOP_SPEC_RULES=0

# JSON validity with adversarial RULES.md content: tab, double-quote, backslash,
# control char. The hand-rolled sed escaper produced invalid JSON here; jq does not.
ADV="$TMP/adv"; mkdir -p "$ADV/.loop-spec"
CLAUDE_PROJECT_DIR="$ADV" bash "$RULES_LIB" add 'a normal rule' >/dev/null
printf -- '- [ ] use\ttabs and "quotes" and a back\\slash in a rule\n' >> "$ADV/.loop-spec/RULES.md"
adv_out=$(CLAUDE_PROJECT_DIR="$ADV" bash "$HOOK" 2>/dev/null) || true
if printf '%s' "$adv_out" | jq . >/dev/null 2>&1; then
  echo "PASS: g: adversarial RULES.md -> valid JSON"; ((PASS++)) || true
else
  echo "FAIL: g: adversarial RULES.md -> INVALID JSON: $adv_out"; ((FAIL++)) || true
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
