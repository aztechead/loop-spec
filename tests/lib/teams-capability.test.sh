#!/usr/bin/env bash
# Tests for lib/teams-capability.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO/lib/teams-capability.sh"
PASS=0
FAIL=0

check() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"
    ((FAIL++)) || true
  fi
}

# run <expected> <version-arg-or-empty> [env assignments...]
# Invokes the lib in a clean env so a real exported flag can't leak in.
run() {
  local version="$1"; shift
  env -u CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS -u LOOP_SPEC_TEAMS_MODE \
      -u LOOP_SPEC_MAX_PARALLEL_SUBAGENTS \
      -u LOOP_SPEC_HARNESS -u PI_CODING_AGENT_DIR -u CLAUDECODE "$@" \
    bash "$LIB" $version
}

# Case A: flag unset -> none, at any version
got=$(run "2.1.181")
check "A: flag unset -> none" "none" "$got"

got=$(run "2.0.0" CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=0)
check "A2: flag=0 -> none" "none" "$got"

# Case B: flag=1 + modern CC (>= 2.1.178) -> implicit
got=$(run "2.1.178" CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1)
check "B: flag=1 + 2.1.178 (boundary) -> implicit" "implicit" "$got"

got=$(run "2.1.181" CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1)
check "B2: flag=1 + 2.1.181 -> implicit" "implicit" "$got"

got=$(run "2.2.0" CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1)
check "B3: flag=1 + 2.2.0 -> implicit" "implicit" "$got"

# Case C: flag=1 + legacy CC (< 2.1.178) -> explicit
got=$(run "2.1.177" CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1)
check "C: flag=1 + 2.1.177 -> explicit" "explicit" "$got"

got=$(run "2.1.40" CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1)
check "C2: flag=1 + 2.1.40 -> explicit" "explicit" "$got"

# Case D: flag=1 + unknown version -> none (safe universal fallback)
got=$(run "unknown" CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1)
check "D: flag=1 + unknown version -> none" "none" "$got"

# Case E: LOOP_SPEC_TEAMS_MODE override wins over flag + version
got=$(env -u CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS LOOP_SPEC_TEAMS_MODE=explicit bash "$LIB" "2.1.181")
check "E: override -> explicit" "explicit" "$got"

got=$(env CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 LOOP_SPEC_TEAMS_MODE=none bash "$LIB" "2.1.181")
check "E2: override none beats flag=1" "none" "$got"

got=$(env CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 LOOP_SPEC_TEAMS_MODE=bogus bash "$LIB" "2.1.181")
check "E3: override bogus -> none (fail safe)" "none" "$got"

# Case F: adk harness -> none even with the flag exported and a modern version
# (named, addressable teammates are a Claude Code surface; ADK's AgentTool
# returns a result to its caller and nothing more)
got=$(run "2.1.181" CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 LOOP_SPEC_HARNESS=adk)
check "F: adk harness + flag=1 -> none" "none" "$got"

# The retired pi env hint must no longer gate anything: a Claude Code user with a
# stale PI_CODING_AGENT_DIR in their environment would otherwise lose teams for a
# harness that no longer exists.
got=$(run "2.1.181" CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 PI_CODING_AGENT_DIR=/x)
check "F2: retired pi env hint no longer suppresses teams" "implicit" "$got"

# An override may turn a capability OFF anywhere, but it must not conjure one the
# harness does not have. ADK has no named teammates at all, so `implicit` there is a state
# that cannot exist: it used to answer "implicit" and route EXECUTE onto a team rung
# whose every spawn throws. Absence of a surface is a fact; only a negative override
# is honored past the harness gate.
got=$(run "2.1.181" LOOP_SPEC_HARNESS=adk LOOP_SPEC_TEAMS_MODE=implicit)
check "F3: positive mode override cannot beat the adk gate" "none" "$got"
got=$(run "2.1.181" LOOP_SPEC_HARNESS=opencode LOOP_SPEC_TEAMS_MODE=explicit)
check "F4: positive mode override cannot beat the opencode gate" "none" "$got"
# The escape hatch is still there for anyone who needs one: assert the harness, then
# the mode. That names the claim being made instead of smuggling it through the mode.
got=$(run "2.1.181" LOOP_SPEC_HARNESS=claude LOOP_SPEC_TEAMS_MODE=implicit)
check "F5: harness assertion + mode override still forces the mode" "implicit" "$got"

# Case G: opencode harness -> none (resumable tasks have no named teammates,
# peer messaging, or shared task list -- same Claude-Code-surface gate as ADK)
got=$(run "2.1.181" CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 LOOP_SPEC_HARNESS=opencode)
check "G: opencode harness + flag=1 -> none" "none" "$got"

# An explicit global cap selects enforceable one-shot waves, even if teams were
# otherwise available or explicitly requested.
got=$(run "2.1.181" CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 \
  LOOP_SPEC_MAX_PARALLEL_SUBAGENTS=1)
check "H: global subagent cap disables teams" "none" "$got"
got=$(run "2.1.181" LOOP_SPEC_TEAMS_MODE=implicit \
  LOOP_SPEC_MAX_PARALLEL_SUBAGENTS=2)
check "H2: cap beats explicit team mode" "none" "$got"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
