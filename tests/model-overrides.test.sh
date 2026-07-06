#!/usr/bin/env bash
# Tests for per-role model override env vars in lib/feature-init.sh.
# Covers: default map values, env override application, fable alias acceptance,
# invalid value rejection, and empty-value fallback to default.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/lib/feature-init.sh"
PASS=0
FAIL=0

check() {
  local name="$1" cond="$2"
  if [[ "$cond" == "1" ]]; then PASS=$((PASS+1)); echo "PASS: $name"
  else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi
}

# --- Test 1: Default map includes new sonnet roles and unchanged opus roles ---
models="$(bash "$LIB" models)"
check "default: advocate == sonnet" \
  "$(echo "$models" | jq -e '.advocate == "sonnet"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "default: specComplianceReviewer == sonnet" \
  "$(echo "$models" | jq -e '.specComplianceReviewer == "sonnet"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "default: challenger == opus" \
  "$(echo "$models" | jq -e '.challenger == "opus"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "default: iterateJudge == opus" \
  "$(echo "$models" | jq -e '.iterateJudge == "opus"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "default: implementer == sonnet" \
  "$(echo "$models" | jq -e '.implementer == "sonnet"' >/dev/null 2>&1 && echo 1 || echo 0)"

# --- Test 2: Env override applies to the targeted role; others are unchanged ---
overridden="$(LOOP_SPEC_MODEL_PLANNER=sonnet bash "$LIB" models)"
check "override: LOOP_SPEC_MODEL_PLANNER=sonnet -> planner == sonnet" \
  "$(echo "$overridden" | jq -e '.planner == "sonnet"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "override: other roles unchanged (iterateJudge still opus)" \
  "$(echo "$overridden" | jq -e '.iterateJudge == "opus"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "override: other roles unchanged (implementer still sonnet)" \
  "$(echo "$overridden" | jq -e '.implementer == "sonnet"' >/dev/null 2>&1 && echo 1 || echo 0)"

# --- Test 3: fable alias is accepted ---
fable_out="$(LOOP_SPEC_MODEL_ITERATE_JUDGE=fable bash "$LIB" models)"
check "fable accepted: LOOP_SPEC_MODEL_ITERATE_JUDGE=fable -> iterateJudge == fable" \
  "$(echo "$fable_out" | jq -e '.iterateJudge == "fable"' >/dev/null 2>&1 && echo 1 || echo 0)"

# --- Test 4: Literal model ID fails with non-zero exit and names the var in stderr ---
stderr_out="$(LOOP_SPEC_MODEL_ADVOCATE=claude-opus-4-8 bash "$LIB" models 2>&1 1>/dev/null || true)"
invalid_exit=0
LOOP_SPEC_MODEL_ADVOCATE=claude-opus-4-8 bash "$LIB" models >/dev/null 2>/dev/null || invalid_exit=$?
check "invalid value: non-zero exit for literal model ID" \
  "$([[ "$invalid_exit" -ne 0 ]] && echo 1 || echo 0)"
check "invalid value: stderr mentions the var name" \
  "$([[ "$stderr_out" == *"LOOP_SPEC_MODEL_ADVOCATE"* ]] && echo 1 || echo 0)"

# --- Test 5: Empty value falls back to canonical default ---
empty_out="$(LOOP_SPEC_MODEL_PLANNER="" bash "$LIB" models)"
check "empty value: LOOP_SPEC_MODEL_PLANNER='' -> planner == opus (canonical default)" \
  "$(echo "$empty_out" | jq -e '.planner == "opus"' >/dev/null 2>&1 && echo 1 || echo 0)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
