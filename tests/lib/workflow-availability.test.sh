#!/usr/bin/env bash
# Tests for lib/workflow-availability.sh
set -euo pipefail

LIB="$(cd "$(dirname "$0")/../.." && pwd)/lib/workflow-availability.sh"
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

# Version gating (explicit version arg; unset override + harness signals so the
# detection path runs even when this suite itself executes under pi)
unset LOOP_SPEC_WORKFLOWS_AVAILABLE LOOP_SPEC_HARNESS PI_CODING_AGENT_DIR
check "A: exact minimum 2.1.154 -> true"      "true"  "$(bash "$LIB" 2.1.154)"
check "B: above minimum 2.1.159 -> true"      "true"  "$(bash "$LIB" 2.1.159)"
check "C: newer minor 2.2.0 -> true"          "true"  "$(bash "$LIB" 2.2.0)"
check "D: newer major 3.0.0 -> true"          "true"  "$(bash "$LIB" 3.0.0)"
check "E: just below 2.1.153 -> false"        "false" "$(bash "$LIB" 2.1.153)"
check "F: older minor 2.0.9 -> false"         "false" "$(bash "$LIB" 2.0.9)"
check "G: older major 1.9.9 -> false"         "false" "$(bash "$LIB" 1.9.9)"

# Override takes precedence over version
check "H: override=1 forces true"  "true"  "$(LOOP_SPEC_WORKFLOWS_AVAILABLE=1 bash "$LIB" 1.0.0)"
check "I: override=0 forces false" "false" "$(LOOP_SPEC_WORKFLOWS_AVAILABLE=0 bash "$LIB" 9.9.9)"

# pi harness gate: Workflow is a Claude Code tool; never available under pi
check "J: pi harness -> false at any version" "false" "$(LOOP_SPEC_HARNESS=pi bash "$LIB" 9.9.9)"
check "K: explicit override beats pi gate" "true" "$(LOOP_SPEC_HARNESS=pi LOOP_SPEC_WORKFLOWS_AVAILABLE=1 bash "$LIB" 9.9.9)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
