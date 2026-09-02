#!/usr/bin/env bash
# Tests for per-role and per-phase model routing in lib/feature-init.sh.
# Covers defaults, precedence, phase persistence/activation, invalid values, and
# empty-value fallback.
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

# --- Test 1: Default map has no model-family prerequisite ---
models="$(bash "$LIB" models)"
check "default: every role inherits" \
  "$(echo "$models" | jq -e '[.[]] | all(. == "inherit")' >/dev/null 2>&1 && echo 1 || echo 0)"
check "default: inherit-only route needs zero Agent probes" \
  "$([[ "$(bash "$LIB" agent-probe-models)" == "[]" ]] && echo 1 || echo 0)"

# --- Test 2: Env override applies to the targeted role; others are unchanged ---
overridden="$(LOOP_SPEC_MODEL_PLANNER=sonnet bash "$LIB" models)"
check "override: LOOP_SPEC_MODEL_PLANNER=sonnet -> planner == sonnet" \
  "$(echo "$overridden" | jq -e '.planner == "sonnet"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "override: other roles still inherit" \
  "$(echo "$overridden" | jq -e '.iterateJudge == "inherit" and .implementer == "inherit"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "override: explicit Agent alias is the only probe target" \
  "$([[ "$(LOOP_SPEC_MODEL_PLANNER=sonnet bash "$LIB" agent-probe-models)" == '["sonnet"]' ]] && echo 1 || echo 0)"

# --- Test 3: fable alias is accepted ---
fable_out="$(LOOP_SPEC_MODEL_ITERATE_JUDGE=fable bash "$LIB" models)"
check "fable accepted: LOOP_SPEC_MODEL_ITERATE_JUDGE=fable -> iterateJudge == fable" \
  "$(echo "$fable_out" | jq -e '.iterateJudge == "fable"' >/dev/null 2>&1 && echo 1 || echo 0)"

# --- Test 4: Role selectors match the surface that consumes them ---
role_full_exit=0
role_full_stderr="$(LOOP_SPEC_MODEL_ADVOCATE=claude-opus-4-8 \
  bash "$LIB" models 2>&1 1>/dev/null)" || role_full_exit=$?
check "Claude role full ID: rejected before the Agent boundary" \
  "$([[ "$role_full_exit" -ne 0 ]] && echo 1 || echo 0)"
check "Claude role full ID: error names the Agent surface" \
  "$([[ "$role_full_stderr" == *"Claude Agent tool"* ]] && echo 1 || echo 0)"
stderr_out="$(LOOP_SPEC_MODEL_ADVOCATE=bogus bash "$LIB" models 2>&1 1>/dev/null || true)"
invalid_exit=0
LOOP_SPEC_MODEL_ADVOCATE=bogus bash "$LIB" models >/dev/null 2>/dev/null || invalid_exit=$?
check "invalid value: unstructured selector exits non-zero" \
  "$([[ "$invalid_exit" -ne 0 ]] && echo 1 || echo 0)"
check "invalid value: stderr mentions the var name" \
  "$([[ "$stderr_out" == *"LOOP_SPEC_MODEL_ADVOCATE"* ]] && echo 1 || echo 0)"
# A dangling separator is a truncated paste, not a model ID. It must fail at
# validation, not at the dispatch that eventually consumes it.
for truncated in "sonnet-" "opus:" "anthropic/"; do
  trunc_exit=0
  LOOP_SPEC_MODEL_ADVOCATE="$truncated" bash "$LIB" models >/dev/null 2>/dev/null || trunc_exit=$?
  check "invalid value: '$truncated' (dangling separator) is rejected" \
    "$([[ "$trunc_exit" -ne 0 ]] && echo 1 || echo 0)"
done
check "OpenCode implementer native ID: accepted for loop-fleet" \
  "$(LOOP_SPEC_HARNESS=opencode LOOP_SPEC_MODEL_IMPLEMENTER=anthropic/claude-sonnet-4-5 \
    bash "$LIB" models | jq -e '.implementer == "anthropic/claude-sonnet-4-5"' \
    >/dev/null 2>&1 && echo 1 || echo 0)"
oc_role_exit=0
LOOP_SPEC_HARNESS=opencode LOOP_SPEC_MODEL_ADVOCATE=anthropic/claude-sonnet-4-5 \
  bash "$LIB" models >/dev/null 2>/dev/null || oc_role_exit=$?
check "OpenCode non-fleet native role ID: rejected when no dispatch consumes it" \
  "$([[ "$oc_role_exit" -ne 0 ]] && echo 1 || echo 0)"
adk_planner="$(LOOP_SPEC_HARNESS=adk LOOP_SPEC_MODEL_PLANNER=gemini-2.5-flash \
  bash "$LIB" models)"
check "ADK native planner ID: accepted for dispatch_subagent" \
  "$(echo "$adk_planner" | jq -e '.planner == "gemini-2.5-flash"' \
    >/dev/null 2>&1 && echo 1 || echo 0)"
adk_alias_exit=0
LOOP_SPEC_HARNESS=adk LOOP_SPEC_MODEL_PLANNER=sonnet \
  bash "$LIB" models >/dev/null 2>/dev/null || adk_alias_exit=$?
check "ADK role Claude alias: rejected instead of silently inheriting" \
  "$([[ "$adk_alias_exit" -ne 0 ]] && echo 1 || echo 0)"
oc_alias_exit=0
LOOP_SPEC_HARNESS=opencode LOOP_SPEC_MODEL_IMPLEMENTER=sonnet \
  bash "$LIB" models >/dev/null 2>/dev/null || oc_alias_exit=$?
check "OpenCode role Claude alias: rejected instead of silently inheriting" \
  "$([[ "$oc_alias_exit" -ne 0 ]] && echo 1 || echo 0)"

# --- Test 5: Empty value falls back to canonical default ---
empty_out="$(LOOP_SPEC_MODEL_PLANNER="" bash "$LIB" models)"
check "empty value: LOOP_SPEC_MODEL_PLANNER='' -> planner inherits" \
  "$(echo "$empty_out" | jq -e '.planner == "inherit"' >/dev/null 2>&1 && echo 1 || echo 0)"

# --- Test 6: A phase override becomes every role's default for that phase ---
plan_phase="$(LOOP_SPEC_PHASE_MODEL_PLAN=sonnet bash "$LIB" models --phase plan)"
check "phase override: PLAN routes planner to sonnet" \
  "$(echo "$plan_phase" | jq -e '.planner == "sonnet"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "phase override: PLAN routes challenger gate to sonnet" \
  "$(echo "$plan_phase" | jq -e '.challenger == "sonnet"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "phase override: PLAN routes advocate gate to sonnet" \
  "$(echo "$plan_phase" | jq -e '.advocate == "sonnet"' >/dev/null 2>&1 && echo 1 || echo 0)"

# --- Test 7: Explicit role is more specific than the phase default ---
precedence="$(LOOP_SPEC_PHASE_MODEL_VERIFY=sonnet LOOP_SPEC_MODEL_CODE_REVIEWER=opus \
  bash "$LIB" models --phase verify)"
check "precedence: explicit code-reviewer role beats VERIFY phase" \
  "$(echo "$precedence" | jq -e '.codeReviewer == "opus"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "precedence: VERIFY phase still routes verifier" \
  "$(echo "$precedence" | jq -e '.verifier == "sonnet"' >/dev/null 2>&1 && echo 1 || echo 0)"

# --- Test 8: Phase values are validated and exposed for SDK/CLI launchers ---
phase_models="$(LOOP_SPEC_PHASE_MODEL_SPEC=opus LOOP_SPEC_PHASE_MODEL_EXECUTE=sonnet \
  bash "$LIB" phase-models)"
check "phase map: configured SPEC persisted" \
  "$(echo "$phase_models" | jq -e '.spec == "opus"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "phase map: configured EXECUTE persisted" \
  "$(echo "$phase_models" | jq -e '.execute == "sonnet"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "phase map: unset DISCUSS is null" \
  "$(echo "$phase_models" | jq -e '.discuss == null' >/dev/null 2>&1 && echo 1 || echo 0)"
check "phase model: direct resolver supports SDK launcher" \
  "$([[ "$(LOOP_SPEC_PHASE_MODEL_VERIFY=opus bash "$LIB" phase-model verify)" == "opus" ]] && echo 1 || echo 0)"
all_models="$(LOOP_SPEC_PHASE_MODEL_EXECUTE=haiku LOOP_SPEC_MODEL_ITERATE_JUDGE=fable \
  bash "$LIB" all-models)"
check "health-check set: includes every phase and role selector" \
  "$(echo "$all_models" | jq -e \
    'sort == ["fable","haiku","inherit"]' >/dev/null 2>&1 && echo 1 || echo 0)"

phase_full_id="$(LOOP_SPEC_PHASE_MODEL_DISCUSS=claude-opus-4-8 \
  bash "$LIB" models --phase discuss)"
check "Claude phase full ID: role Agents inherit the fresh main model" \
  "$(echo "$phase_full_id" | jq -e '[.[]] | all(. == "inherit")' >/dev/null 2>&1 && echo 1 || echo 0)"
check "Claude phase full ID: launcher still receives the exact selector" \
  "$([[ "$(LOOP_SPEC_PHASE_MODEL_DISCUSS=claude-opus-4-8 \
    bash "$LIB" phase-model discuss)" == "claude-opus-4-8" ]] && echo 1 || echo 0)"
check "Claude phase full ID: startup selector set retains launcher value" \
  "$(LOOP_SPEC_PHASE_MODEL_DISCUSS=claude-opus-4-8 bash "$LIB" all-models \
    | jq -e 'index("claude-opus-4-8") != null and index("inherit") != null' \
    >/dev/null 2>&1 && echo 1 || echo 0)"
check "Claude phase full ID: never sent to the Agent probe" \
  "$([[ "$(LOOP_SPEC_PHASE_MODEL_DISCUSS=claude-opus-4-8 \
    bash "$LIB" agent-probe-models)" == "[]" ]] && echo 1 || echo 0)"
oc_phase_alias_exit=0
LOOP_SPEC_HARNESS=opencode LOOP_SPEC_PHASE_MODEL_EXECUTE=sonnet \
  bash "$LIB" models --phase execute >/dev/null 2>/dev/null || oc_phase_alias_exit=$?
check "OpenCode phase Claude alias: rejected instead of silently inheriting" \
  "$([[ "$oc_phase_alias_exit" -ne 0 ]] && echo 1 || echo 0)"
check "OpenCode phase native ID: retained for the fleet consumer" \
  "$(LOOP_SPEC_HARNESS=opencode LOOP_SPEC_PHASE_MODEL_EXECUTE=anthropic/claude-sonnet \
    bash "$LIB" models --phase execute \
    | jq -e '.implementer == "anthropic/claude-sonnet"' >/dev/null 2>&1 && echo 1 || echo 0)"
phase_stderr="$(LOOP_SPEC_PHASE_MODEL_DISCUSS=bogus \
  bash "$LIB" models --phase discuss 2>&1 1>/dev/null || true)"
phase_invalid_exit=0
LOOP_SPEC_PHASE_MODEL_DISCUSS=bogus \
  bash "$LIB" models --phase discuss >/dev/null 2>/dev/null || phase_invalid_exit=$?
check "invalid phase value: non-zero exit for unstructured selector" \
  "$([[ "$phase_invalid_exit" -ne 0 ]] && echo 1 || echo 0)"
check "invalid phase value: stderr names the phase var" \
  "$([[ "$phase_stderr" == *"LOOP_SPEC_PHASE_MODEL_DISCUSS"* ]] && echo 1 || echo 0)"

# --- Test 9: Activation atomically persists the exact map dispatches consume ---
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/feature"
printf '{"schemaVersion":7,"slug":"demo","models":{},"phaseModels":{}}\n' \
  > "$WORK/feature/feature.json"
LOOP_SPEC_PHASE_MODEL_EXECUTE=opus LOOP_SPEC_MODEL_IMPLEMENTER=sonnet \
  bash "$LIB" activate "$WORK/feature" execute
check "activate: phase map persisted" \
  "$(jq -e '.phaseModels.execute == "opus"' "$WORK/feature/feature.json" >/dev/null 2>&1 && echo 1 || echo 0)"
check "activate: role override persisted for actual implementer spawn" \
  "$(jq -e '.models.implementer == "sonnet"' "$WORK/feature/feature.json" >/dev/null 2>&1 && echo 1 || echo 0)"
check "activate: execute gate inherited phase model" \
  "$(jq -e '.models.specComplianceReviewer == "opus"' "$WORK/feature/feature.json" >/dev/null 2>&1 && echo 1 || echo 0)"

# --- Test 10: Unknown phases fail closed ---
unknown_exit=0
bash "$LIB" models --phase bogus >/dev/null 2>/dev/null || unknown_exit=$?
check "unknown phase: models command fails" \
  "$([[ "$unknown_exit" -ne 0 ]] && echo 1 || echo 0)"

# --- Test 10b: all-models emits NOTHING when any route is invalid ---
# The startup health check reads this on stdout. Printing the aliases that happened
# to resolve would hand a caller a short-but-plausible set -- the silent fallback the
# "no silent fallback" contract forbids.
allmodels_exit=0
allmodels_stdout="$(LOOP_SPEC_PHASE_MODEL_PLAN=bogus \
  bash "$LIB" all-models 2>/dev/null)" || allmodels_exit=$?
check "all-models: non-zero exit when a phase route is invalid" \
  "$([[ "$allmodels_exit" -ne 0 ]] && echo 1 || echo 0)"
check "all-models: no partial selector set on stdout for an invalid phase route" \
  "$([[ -z "$allmodels_stdout" ]] && echo 1 || echo 0)"
allrole_exit=0
allrole_stdout="$(LOOP_SPEC_MODEL_PLANNER=bogus \
  bash "$LIB" all-models 2>/dev/null)" || allrole_exit=$?
check "all-models: non-zero exit when a role route is invalid" \
  "$([[ "$allrole_exit" -ne 0 ]] && echo 1 || echo 0)"
check "all-models: no partial selector set on stdout for an invalid role route" \
  "$([[ -z "$allrole_stdout" ]] && echo 1 || echo 0)"

# --- Test 10c: validate is the startup route check, fork-free and answerless ---
# all-models resolves nine maps to compute a union nobody at startup reads; the
# driver only needs to know the selector set is legal. validate answers that alone.
validate_exit=0
bash "$LIB" validate >/dev/null 2>&1 || validate_exit=$?
check "validate: clean environment exits 0" \
  "$([[ "$validate_exit" -eq 0 ]] && echo 1 || echo 0)"
validate_phase_exit=0
LOOP_SPEC_PHASE_MODEL_PLAN=bogus bash "$LIB" validate >/dev/null 2>&1 || validate_phase_exit=$?
check "validate: invalid phase route exits non-zero" \
  "$([[ "$validate_phase_exit" -ne 0 ]] && echo 1 || echo 0)"
validate_role_exit=0
LOOP_SPEC_MODEL_PLANNER=bogus bash "$LIB" validate >/dev/null 2>&1 || validate_role_exit=$?
check "validate: invalid role route exits non-zero" \
  "$([[ "$validate_role_exit" -ne 0 ]] && echo 1 || echo 0)"
validate_stderr="$(LOOP_SPEC_MODEL_PLANNER=bogus bash "$LIB" validate 2>&1 1>/dev/null || true)"
check "validate: stderr names the offending var" \
  "$([[ "$validate_stderr" == *"LOOP_SPEC_MODEL_PLANNER"* ]] && echo 1 || echo 0)"
check "cycle boundary: startup validates routing through validate, not all-models" \
  "$(grep -Fq 'feature-init validate' "$REPO_ROOT/lib/cycle-driver.sh" \
    && ! grep -Fq 'feature-init all-models' "$REPO_ROOT/lib/cycle-driver.sh" \
    && echo 1 || echo 0)"

# --- Test 11: Instruction/SDK boundaries call the executable router ---
CYCLE="$REPO_ROOT/lib/cycle-driver.sh"
CLOUD="$REPO_ROOT/docs/loop-spec/cloud-run-autonomous.md"
check "cycle boundary: activation is mandatory before every phase skill" \
  "$([[ "$(grep -c 'feature-init activate' "$CYCLE")" -ge 1 ]] && echo 1 || echo 0)"
check "SDK controller: resolves model inside the per-phase query loop" \
  "$(grep -Fq 'phase = resumable_phase(ROOT)' "$CLOUD" \
    && grep -Fq 'query_overrides["model"] = value' "$CLOUD" \
    && echo 1 || echo 0)"
check "CLI controller: passes only an explicit phase selector to --model" \
  "$(grep -Fq '&& "$phase_model" != "inherit"' "$CLOUD" \
    && grep -Fq 'claude_args+=(--model "$phase_model")' "$CLOUD" \
    && echo 1 || echo 0)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
