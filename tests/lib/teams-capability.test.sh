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

# Case D: flag=1 + unknown version -> implicit (modern default, degrades safely)
got=$(run "" CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1)
check "D: flag=1 + unknown version -> implicit" "implicit" "$got"

# Case E: LOOP_SPEC_TEAMS_MODE override wins over flag + version
got=$(env -u CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS LOOP_SPEC_TEAMS_MODE=explicit bash "$LIB" "2.1.181")
check "E: override -> explicit" "explicit" "$got"

got=$(env CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 LOOP_SPEC_TEAMS_MODE=none bash "$LIB" "2.1.181")
check "E2: override none beats flag=1" "none" "$got"

got=$(env CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 LOOP_SPEC_TEAMS_MODE=bogus bash "$LIB" "2.1.181")
check "E3: override bogus -> none (fail safe)" "none" "$got"

# Case F: pi harness -> none even with the flag exported and a modern version
# (teams are a Claude Code surface; under pi the Agent tool does not exist)
got=$(run "2.1.181" CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 LOOP_SPEC_HARNESS=pi)
check "F: pi harness + flag=1 -> none" "none" "$got"

got=$(run "2.1.181" CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 PI_CODING_AGENT_DIR=/x)
check "F2: pi env hint + flag=1 -> none" "none" "$got"

# LOOP_SPEC_TEAMS_MODE still wins over the harness gate (test escape hatch)
got=$(run "2.1.181" LOOP_SPEC_HARNESS=pi LOOP_SPEC_TEAMS_MODE=implicit)
check "F3: explicit mode override beats pi gate" "implicit" "$got"

# Case G: opencode harness -> none (task tool is one-shot only; no named
# teammates, no SendMessage -- same Claude-Code-surface gate as pi)
got=$(run "2.1.181" CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 LOOP_SPEC_HARNESS=opencode)
check "G: opencode harness + flag=1 -> none" "none" "$got"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
