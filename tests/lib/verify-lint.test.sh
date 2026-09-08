#!/usr/bin/env bash
# Tests for lib/verify-lint.sh -- verify shapes that cannot prove a task are flagged before the critique.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/lib/verify-lint.sh"
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

lint() { bash "$LIB" - <<<"$1" 2>/dev/null; }
rc() { bash "$LIB" - <<<"$1" >/dev/null 2>&1; echo $?; }

# The three live shapes from the round-4 critique.
absence='[{"id":"task-002","files":["org.hcl"],"verifyCommand":"! grep -rnE \"(plan-all|apply-all)\" org.hcl && ! grep -q TERRAGRUNT_ org.hcl"}]'
check "absence-only verify is flagged" "1" "$(lint "$absence" | grep -c '^FLAG task-002: absence-only')"
selfrep='[{"id":"task-005","files":["docs/PLAN_RUN_EVIDENCE.md"],"verifyCommand":"grep -qE \"(No changes\\\\.|invalid_rapt)\" docs/PLAN_RUN_EVIDENCE.md && ! grep -c \"terragrunt apply\" docs/PLAN_RUN_EVIDENCE.md"}]'
check "status grepped from a note the task writes is flagged" "1" "$(lint "$selfrep" | grep -c '^FLAG task-005: self-reported')"
plan='[{"id":"task-004","files":["unit/terragrunt.hcl"],"verifyCommand":"cd unit && terragrunt plan -no-color"}]'
check "a plan with no outcome assertion is flagged" "1" "$(lint "$plan" | grep -c '^FLAG task-004: plan-outcome')"
check "findings exit 1" "1" "$(rc "$plan")"

# Honest verifies pass.
good='[{"id":"task-001","files":["root.hcl"],"verifyCommand":"terragrunt hcl format --check --file root.hcl && grep -E \"^terraform_version_constraint\" root.hcl"},
  {"id":"task-002","files":["org.hcl"],"verifyCommand":"! grep -q apply-all org.hcl && grep -q include org.hcl"},
  {"id":"task-004","files":["unit/terragrunt.hcl"],"verifyCommand":"cd unit && terragrunt plan -no-color 2>&1 | grep -qF \"No changes.\""},
  {"id":"task-006","files":["README.md"],"verifyCommand":"grep -q \"^## CFT/FAST alignment\" README.md"},
  {"id":"task-007","files":["a.py"],"verifyCommand":"python3 -m pytest tests/test_a.py"}]'
check "presence beside a negation, an asserted plan, a README heading, and a test all pass" "0" "$(rc "$good")"
check "clean input prints ok" "1" "$(lint "$good" | grep -c '^verify-lint: ok')"

# A note grep that is not a status is not self-reported (the README task is the deliverable).
readme='[{"id":"task-006","files":["README.md"],"verifyCommand":"grep -c \"^## Follow-up\" README.md"}]'
check "a heading grep on a doc deliverable passes" "0" "$(rc "$readme")"

# Failure paths are loud.
check "non-JSON exits 2" "2" "$(rc 'not json')"
ec=0; bash "$LIB" >/dev/null 2>&1 || ec=$?
check "no arguments exits 2" "2" "$ec"
ec=0; bash "$LIB" /nonexistent.json >/dev/null 2>&1 || ec=$?
check "missing file exits 2" "2" "$ec"

echo
echo "verify-lint: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
