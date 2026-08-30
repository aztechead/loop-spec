#!/usr/bin/env bash
# Tests for lib/cycle-profile.sh -- selects the full or the lightened gate ladder.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/lib/cycle-profile.sh"
WORK="${TMPDIR:-/tmp}/loop-spec-cycle-profile.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"
PASS=0; FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

# A low-risk maintenance classification: the shape lib/task-route.sh normalizes.
LOW_RISK='{"route":"full","taskKind":"maintenance","confidence":0.9,"estimatedFiles":2,
  "reviewableEstimatedFiles":2,"criteriaCount":2,"ambiguity":"low",
  "introducesSeam":false,"introducesDependency":true,"introducesNewDependency":false,
  "updatesDependencyVersion":true,"changesInterface":false,"securitySensitive":false,
  "dataMigration":false,"multiRepo":false,"destructive":false,"reason":"bump a pin"}'

COMPACT_GATE_PLAN='{
  "specInterview":{"run":false,"reason":"bounded requirements are grounded"},
  "discuss":{"run":false,"reason":"no unresolved product decision"},
  "specCritique":{"run":false,"reason":"scope is deliberately bounded"},
  "planCritique":{"run":true,"reason":"review the compact plan"},
  "repositoryValidation":{"run":true,"reason":"validate repository state"},
  "placeholderScan":{"run":true,"reason":"scan artifacts for placeholders"},
  "tamperScan":{"run":true,"reason":"verify compact run artifacts"},
  "acceptance":{"run":true,"reason":"run acceptance evidence"},
  "codeReview":{"run":true,"reason":"review implementation"},
  "iterate":{"run":true,"reason":"judge the final result"}
}'
COMPACT="$(jq -cn --argjson gate_plan "$COMPACT_GATE_PLAN" '{route: "compact", candidateRoute: "compact", taskKind: "refactor", confidence: 0.8, estimatedFiles: 12, reviewableEstimatedFiles: 12, criteriaCount: 6, ambiguity: "medium", introducesSeam: false, introducesDependency: false, introducesNewDependency: false, updatesDependencyVersion: false, changesInterface: false, securitySensitive: false, dataMigration: false, multiRepo: false, destructive: false, workingTreeConflict: false, gatePlan: $gate_plan, reason: "bounded refactor"}')"

profile() { sed -E 's/^profile=([a-z]+).*/\1/'; }
select_with() { printf '%s' "$1" | bash "$SCRIPT" select -; }

# --- invocation contract ---
rc=0; bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
check "no subcommand is a bad invocation" "2" "$rc"
rc=0; bash "$SCRIPT" bogus >/dev/null 2>&1 || rc=$?
check "an unknown subcommand is a bad invocation" "2" "$rc"
check "--answers enumerates the answer space" "profile=compact profile=maintenance profile=standard" \
  "$(bash "$SCRIPT" --answers | tr '\n' ' ' | sed 's/ $//')"

# --- the lightened profile is earned by evidence ---
check "a low-risk maintenance classification selects maintenance" "maintenance" \
  "$(select_with "$LOW_RISK" | profile)"
check "the maintenance answer carries its reason" "1" \
  "$(select_with "$LOW_RISK" | grep -c 'reason=taskKind=maintenance')"

# Compact is selected only from the durable normalized route and its typed gate plan.
check "a validated compact classification selects compact" "compact" \
  "$(select_with "$COMPACT" | profile)"
check "compact accepts a classifier-selected security change" "compact" \
  "$(printf '%s' "$COMPACT" | jq -c '.securitySensitive = true' | bash "$SCRIPT" select - | profile)"
check "compact evidence without a gate plan stays standard" "standard" \
  "$(printf '%s' "$COMPACT" | jq -c 'del(.gatePlan)' | bash "$SCRIPT" select - | profile)"
check "compact evidence with a blank gate reason stays standard" "standard" \
  "$(printf '%s' "$COMPACT" | jq -c '.gatePlan.acceptance.reason = " "' | bash "$SCRIPT" select - | profile)"
check "compact evidence with an undeclared gate field stays standard" "standard" \
  "$(printf '%s' "$COMPACT" | jq -c '.gatePlan.acceptance.extra = true' | bash "$SCRIPT" select - | profile)"
check "compact evidence with a newline reason stays standard" "standard" \
  "$(printf '%s' "$COMPACT" | jq -c '.gatePlan.acceptance.reason = "line one\nline two"' | bash "$SCRIPT" select - | profile)"
check "compact evidence with an oversized gate reason stays standard" "standard" \
  "$(printf '%s' "$COMPACT" | jq -c '.gatePlan.acceptance.reason = ("x" * 241)' | bash "$SCRIPT" select - | profile)"
check "compact cannot run spec critique after skipping discuss" "standard" \
  "$(printf '%s' "$COMPACT" | jq -c '.gatePlan.specCritique.run = true' | bash "$SCRIPT" select - | profile)"
check "compact evidence beyond its file bound stays standard" "standard" \
  "$(printf '%s' "$COMPACT" | jq -c '.reviewableEstimatedFiles = 13' | bash "$SCRIPT" select - | profile)"
check "compact evidence with high ambiguity stays standard" "standard" \
  "$(printf '%s' "$COMPACT" | jq -c '.ambiguity = "high"' | bash "$SCRIPT" select - | profile)"
check "invalid compact evidence never falls through to maintenance" "standard" \
  "$(printf '%s' "$COMPACT" | jq -c '.taskKind = "maintenance"' | bash "$SCRIPT" select - | profile)"

# --- every disqualifier, one case each ---
for pair in \
  'securitySensitive=true|a security-sensitive change' \
  'introducesSeam=true|a new seam' \
  'changesInterface=true|an interface change' \
  'dataMigration=true|a data migration' \
  'multiRepo=true|a multi-repo change' \
  'destructive=true|a destructive change' \
  'introducesNewDependency=true|a new dependency edge'
do
  mutation="${pair%%|*}"; label="${pair#*|}"
  key="${mutation%%=*}"
  got="$(printf '%s' "$LOW_RISK" | jq -c --arg k "$key" '.[$k] = true' | bash "$SCRIPT" select - | profile)"
  check "$label stays on the standard ladder" "standard" "$got"
done

check "a non-maintenance task kind stays standard" "standard" \
  "$(printf '%s' "$LOW_RISK" | jq -c '.taskKind = "feature"' | bash "$SCRIPT" select - | profile)"
check "medium ambiguity stays standard" "standard" \
  "$(printf '%s' "$LOW_RISK" | jq -c '.ambiguity = "medium"' | bash "$SCRIPT" select - | profile)"
check "low confidence stays standard" "standard" \
  "$(printf '%s' "$LOW_RISK" | jq -c '.confidence = 0.5' | bash "$SCRIPT" select - | profile)"
check "scope beyond the file bound stays standard" "standard" \
  "$(printf '%s' "$LOW_RISK" | jq -c '.reviewableEstimatedFiles = 9' | bash "$SCRIPT" select - | profile)"
check "scope beyond the criteria bound stays standard" "standard" \
  "$(printf '%s' "$LOW_RISK" | jq -c '.criteriaCount = 8' | bash "$SCRIPT" select - | profile)"

# docs and config are maintenance-shaped too.
for kind in docs config; do
  check "taskKind=$kind is maintenance-shaped" "maintenance" \
    "$(printf '%s' "$LOW_RISK" | jq -c --arg k "$kind" '.taskKind = $k' | bash "$SCRIPT" select - | profile)"
done

# --- unknown is risk: an absent flag never reads as cleared ---
check "an absent risk flag stays standard" "standard" \
  "$(printf '%s' "$LOW_RISK" | jq -c 'del(.securitySensitive)' | bash "$SCRIPT" select - | profile)"
check "an absent file count stays standard" "standard" \
  "$(printf '%s' "$LOW_RISK" | jq -c 'del(.reviewableEstimatedFiles, .estimatedFiles)' | bash "$SCRIPT" select - | profile)"

# An older classification without the dependency split falls back to introducesDependency.
check "the pre-split dependency flag is still honored" "standard" \
  "$(printf '%s' "$LOW_RISK" | jq -c 'del(.introducesNewDependency) | .introducesDependency = true' \
     | bash "$SCRIPT" select - | profile)"

# --- no evidence is not a licence ---
check "no classification stays standard" "standard" "$(bash "$SCRIPT" select | profile)"
check "an empty classification stays standard" "standard" "$(printf '' | bash "$SCRIPT" select - | profile)"
check "a non-JSON classification stays standard" "standard" \
  "$(printf 'not json' | bash "$SCRIPT" select - | profile)"
check "a JSON array is not a classification" "standard" \
  "$(printf '[]' | bash "$SCRIPT" select - | profile)"
check "a missing classification file stays standard" "standard" \
  "$(bash "$SCRIPT" select "$WORK/absent.json" | profile)"

# A classification on disk is read the same way as one on stdin.
printf '%s' "$LOW_RISK" > "$WORK/classification.json"
check "a classification file selects maintenance" "maintenance" \
  "$(bash "$SCRIPT" select "$WORK/classification.json" | profile)"

# --- the operator override outranks the probe, in both directions ---
check "an explicit maintenance override wins over no evidence" "maintenance" \
  "$(LOOP_SPEC_CYCLE_PROFILE=maintenance bash "$SCRIPT" select | profile)"
check "an explicit standard override wins over a qualifying classification" "standard" \
  "$(printf '%s' "$LOW_RISK" | LOOP_SPEC_CYCLE_PROFILE=standard bash "$SCRIPT" select - | profile)"
check "an explicit compact override without evidence fails safe" "standard" \
  "$(LOOP_SPEC_CYCLE_PROFILE=compact bash "$SCRIPT" select | profile)"
check "an explicit compact override accepts normalized compact evidence" "compact" \
  "$(printf '%s' "$COMPACT" | LOOP_SPEC_CYCLE_PROFILE=compact bash "$SCRIPT" select - | profile)"
check "an invalid override fails safe to standard" "standard" \
  "$(LOOP_SPEC_CYCLE_PROFILE=yes bash "$SCRIPT" select | profile)"
check "the invalid override says what is wrong" "1" \
  "$(LOOP_SPEC_CYCLE_PROFILE=yes bash "$SCRIPT" select | grep -c 'must be compact, maintenance, standard, or auto')"
check "auto defers to the classification" "maintenance" \
  "$(printf '%s' "$LOW_RISK" | LOOP_SPEC_CYCLE_PROFILE=auto bash "$SCRIPT" select - | profile)"

# Every answer carries a reason; a bare answer is not auditable.
check "every answer names a reason" "1" \
  "$(select_with "$LOW_RISK" | grep -c ' reason=..*')"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
