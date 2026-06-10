#!/usr/bin/env bash
# Tests for lib/team-ops.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO/lib/team-ops.sh"
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

# shellcheck source=/dev/null
source "$LIB"

# Case A: team_name_for_phase
got=$(team_name_for_phase discuss foo)
check "A: team_name_for_phase discuss foo" "loop-spec-discuss-foo" "$got"

got=$(team_name_for_phase implement my-feature)
check "A2: team_name_for_phase implement my-feature" "loop-spec-implement-my-feature" "$got"

# Case B: assert_team_env exits 0 when env var set to 1
exit_code=0
CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 bash -c "source \"$LIB\" && assert_team_env" >/dev/null 2>&1 || exit_code=$?
check "B: assert_team_env exits 0 when env var set" "0" "$exit_code"

# Case C: assert_team_env exits 2 when env var unset
exit_code=0
err_msg=""
err_msg=$(env -u CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS bash -c "source \"$LIB\" && assert_team_env" 2>&1) || exit_code=$?
check "C: assert_team_env exits 2 when env var unset" "2" "$exit_code"
[[ "$err_msg" == *"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"* ]] && msg_ok=yes || msg_ok=no
check "C: assert_team_env error message mentions env var" "yes" "$msg_ok"

# Case D: assert_team_env exits 2 when env var set to something other than 1
exit_code=0
CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=0 bash -c "source \"$LIB\" && assert_team_env" >/dev/null 2>&1 || exit_code=$?
check "D: assert_team_env exits 2 when env var set to 0" "2" "$exit_code"

# Case E: feature_json_path
got=$(feature_json_path foo)
check "E: feature_json_path foo" ".loop-spec/features/foo/feature.json" "$got"

got=$(feature_json_path my-feature)
check "E2: feature_json_path my-feature" ".loop-spec/features/my-feature/feature.json" "$got"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
