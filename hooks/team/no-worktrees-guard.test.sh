#!/usr/bin/env bash
# Tests for hooks/team/no-worktrees-guard.sh.
set -euo pipefail

HOOK="$(dirname "$0")/no-worktrees-guard.sh"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" payload="$3"
  shift 3
  local actual=0
  printf '%s' "$payload" | env "$@" bash "$HOOK" >/dev/null 2>&1 || actual=$?
  if [[ "$actual" -eq "$expected" ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected exit $expected, got $actual)"
    ((FAIL++)) || true
  fi
}

PROJECT="${TMPDIR:-/tmp}/no-worktrees-guard-test-$$"
trap 'rm -rf "$PROJECT"' EXIT
mkdir -p "$PROJECT/.loop-spec"

ADD='{"tool_name":"Bash","tool_input":{"command":"git worktree add /tmp/task -b task/x feat/x"}}'
ADD_C='{"tool_name":"Bash","tool_input":{"command":"git -C /repo worktree add /tmp/task -b task/x feat/x"}}'
HELPER='{"tool_name":"Bash","tool_input":{"command":"bash lib/git-ops.sh create-feature-worktree x abc"}}'
ENTER='{"tool_name":"EnterWorktree","tool_input":{"path":"/tmp/task"}}'
LIST='{"tool_name":"Bash","tool_input":{"command":"git worktree list --porcelain"}}'
TEST='{"tool_name":"Bash","tool_input":{"command":"pytest -q"}}'

check "disabled flag leaves worktree add available" 0 "$ADD" \
  CLAUDE_PROJECT_DIR="$PROJECT" LOOP_SPEC_WORKTREES=1
check "raw worktree add denied" 2 "$ADD" \
  CLAUDE_PROJECT_DIR="$PROJECT" LOOP_SPEC_WORKTREES=0
check "git -C worktree add denied" 2 "$ADD_C" \
  CLAUDE_PROJECT_DIR="$PROJECT" LOOP_SPEC_WORKTREES=0
check "feature helper denied" 2 "$HELPER" \
  CLAUDE_PROJECT_DIR="$PROJECT" LOOP_SPEC_WORKTREES=0
check "EnterWorktree denied" 2 "$ENTER" \
  CLAUDE_PROJECT_DIR="$PROJECT" LOOP_SPEC_WORKTREES=0
check "read-only worktree list allowed" 0 "$LIST" \
  CLAUDE_PROJECT_DIR="$PROJECT" LOOP_SPEC_WORKTREES=0
check "unrelated Bash allowed" 0 "$TEST" \
  CLAUDE_PROJECT_DIR="$PROJECT" LOOP_SPEC_WORKTREES=0
check "malformed payload fails open" 0 "not json" \
  CLAUDE_PROJECT_DIR="$PROJECT" LOOP_SPEC_WORKTREES=0
check "invalid setting fails closed" 2 "$TEST" \
  CLAUDE_PROJECT_DIR="$PROJECT" LOOP_SPEC_WORKTREES=invalid

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
