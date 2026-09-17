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

# Version arguments remain accepted for compatibility, but bounded policy wins
# before capability detection can enable Workflow.
unset LOOP_SPEC_WORKFLOWS_AVAILABLE LOOP_SPEC_MAX_PARALLEL_SUBAGENTS \
  LOOP_SPEC_HARNESS PI_CODING_AGENT_DIR
check "A: exact minimum 2.1.154 stays bounded" "false" "$(LOOP_SPEC_MAX_PARALLEL_SUBAGENTS=2 bash "$LIB" 2.1.154)"
check "B: above minimum 2.1.159 stays bounded" "false" "$(LOOP_SPEC_MAX_PARALLEL_SUBAGENTS=2 bash "$LIB" 2.1.159)"
check "C: newer minor 2.2.0 stays bounded"     "false" "$(LOOP_SPEC_MAX_PARALLEL_SUBAGENTS=2 bash "$LIB" 2.2.0)"
check "D: newer major 3.0.0 stays bounded"     "false" "$(LOOP_SPEC_MAX_PARALLEL_SUBAGENTS=2 bash "$LIB" 3.0.0)"
check "E: just below 2.1.153 -> false"        "false" "$(bash "$LIB" 2.1.153)"
check "F: older minor 2.0.9 -> false"         "false" "$(bash "$LIB" 2.0.9)"
check "G: older major 1.9.9 -> false"         "false" "$(bash "$LIB" 1.9.9)"

# Positive overrides cannot bypass bounded one-shot dispatch.
check "H: positive override stays bounded" "false" "$(LOOP_SPEC_WORKFLOWS_AVAILABLE=1 LOOP_SPEC_MAX_PARALLEL_SUBAGENTS=2 bash "$LIB" 1.0.0)"
check "I: override=0 forces false" "false" "$(LOOP_SPEC_WORKFLOWS_AVAILABLE=0 bash "$LIB" 9.9.9)"

# Harness gates remain fail-safe even when a positive override is supplied.
check "J: adk harness -> false at any version" "false" "$(LOOP_SPEC_HARNESS=adk bash "$LIB" 9.9.9)"
set +e
LOOP_SPEC_HARNESS=pi bash "$LIB" 9.9.9 >/dev/null 2>&1
pi_rc=$?
set -e
check "J2: explicit retired harness propagates usage error" "2" "$pi_rc"
# A positive override must not claim a tool the harness does not ship.
check "K: positive override cannot beat the adk gate" "false" "$(LOOP_SPEC_HARNESS=adk LOOP_SPEC_WORKFLOWS_AVAILABLE=1 bash "$LIB" 9.9.9)"
check "K2: positive override cannot beat the opencode gate" "false" "$(LOOP_SPEC_HARNESS=opencode LOOP_SPEC_WORKFLOWS_AVAILABLE=1 bash "$LIB" 9.9.9)"
check "K3: negative override still honored on claude" "false" "$(LOOP_SPEC_HARNESS=claude LOOP_SPEC_WORKFLOWS_AVAILABLE=0 bash "$LIB" 9.9.9)"
check "K4: positive override stays bounded on claude" "false" "$(LOOP_SPEC_HARNESS=claude LOOP_SPEC_WORKFLOWS_AVAILABLE=1 LOOP_SPEC_MAX_PARALLEL_SUBAGENTS=2 bash "$LIB" 1.0.0)"

# OpenCode also remains on the bounded path.
check "L: opencode harness -> false at any version" "false" "$(LOOP_SPEC_HARNESS=opencode bash "$LIB" 9.9.9)"
check "M: explicit wider cap keeps workflow disabled" "false" \
  "$(LOOP_SPEC_WORKFLOWS_AVAILABLE=1 LOOP_SPEC_MAX_PARALLEL_SUBAGENTS=2 bash "$LIB" 9.9.9)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
