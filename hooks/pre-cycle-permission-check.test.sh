#!/usr/bin/env bash
# Test suite for pre-cycle-permission-check.sh
# Tests the notice the hook prints when the Workflow tool is off for this session.
# Usage: bash hooks/pre-cycle-permission-check.test.sh
set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/pre-cycle-permission-check.sh"
PASS=0
FAIL=0

check() {
  local name="$1"
  local expected_exit="$2"
  local actual_exit="$3"

  if [[ "$actual_exit" -eq "$expected_exit" ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected exit $expected_exit, got $actual_exit)"
    ((FAIL++)) || true
  fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# No .loop-spec/runtime.json: silent, exit 0.
mkdir -p "$WORK/no-runtime"
out="$(cd "$WORK/no-runtime" && bash "$HOOK")"
ec=$?
check "no runtime.json: exit 0" 0 "$ec"
if [[ -z "$out" ]]; then
  echo "PASS: no runtime.json: no output"; ((PASS++)) || true
else
  echo "FAIL: no runtime.json: no output (got '$out')"; ((FAIL++)) || true
fi

# workflowsAvailable=true: silent.
mkdir -p "$WORK/available/.loop-spec"
echo '{"workflowsAvailable":true,"teamsMode":"none"}' > "$WORK/available/.loop-spec/runtime.json"
out="$(cd "$WORK/available" && bash "$HOOK")"
ec=$?
check "workflowsAvailable=true: exit 0" 0 "$ec"
if [[ -z "$out" ]]; then
  echo "PASS: workflowsAvailable=true: no output"; ((PASS++)) || true
else
  echo "FAIL: workflowsAvailable=true: no output (got '$out')"; ((FAIL++)) || true
fi

# workflowsAvailable=false, teamsMode=none: names the one-shot subagent fallback, not the
# old TeamCreate/permissions/env-var text.
mkdir -p "$WORK/none/.loop-spec"
echo '{"workflowsAvailable":false,"teamsMode":"none"}' > "$WORK/none/.loop-spec/runtime.json"
out="$(cd "$WORK/none" && bash "$HOOK")"
if [[ "$out" == *"bounded one-shot subagent waves"* ]]; then
  echo "PASS: teamsMode none: names the one-shot fallback"; ((PASS++)) || true
else
  echo "FAIL: teamsMode none: names the one-shot fallback (got '$out')"; ((FAIL++)) || true
fi
if [[ "$out" != *"TeamCreate"* ]]; then
  echo "PASS: teamsMode none: no TeamCreate"; ((PASS++)) || true
else
  echo "FAIL: teamsMode none: no TeamCreate (got '$out')"; ((FAIL++)) || true
fi
if [[ "$out" != *"/permissions"* ]]; then
  echo "PASS: teamsMode none: no /permissions"; ((PASS++)) || true
else
  echo "FAIL: teamsMode none: no /permissions (got '$out')"; ((FAIL++)) || true
fi
if [[ "$out" != *"CLAUDE_CODE_DISABLE_WORKFLOWS"* ]]; then
  echo "PASS: teamsMode none: no CLAUDE_CODE_DISABLE_WORKFLOWS"; ((PASS++)) || true
else
  echo "FAIL: teamsMode none: no CLAUDE_CODE_DISABLE_WORKFLOWS (got '$out')"; ((FAIL++)) || true
fi

# workflowsAvailable=false, teamsMode=implicit: names the agent-teams fallback.
mkdir -p "$WORK/implicit/.loop-spec"
echo '{"workflowsAvailable":false,"teamsMode":"implicit"}' > "$WORK/implicit/.loop-spec/runtime.json"
out="$(cd "$WORK/implicit" && bash "$HOOK")"
if [[ "$out" == *"agent teams"* ]]; then
  echo "PASS: teamsMode implicit: names the agent-teams fallback"; ((PASS++)) || true
else
  echo "FAIL: teamsMode implicit: names the agent-teams fallback (got '$out')"; ((FAIL++)) || true
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
