#!/usr/bin/env bash
# Tests for hooks/team/no-worktrees-guard.sh.
set -euo pipefail

# Absolute: the out-of-scope cases below run the hook from a different directory.
HOOK="$(cd "$(dirname "$0")" && pwd)/no-worktrees-guard.sh"
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
AGENT_ISO='{"tool_name":"Agent","tool_input":{"description":"impl","prompt":"do it","isolation":"worktree"}}'
AGENT_REMOTE='{"tool_name":"Agent","tool_input":{"description":"impl","prompt":"do it","isolation":"remote"}}'
AGENT_PLAIN='{"tool_name":"Agent","tool_input":{"description":"impl","prompt":"do it","model":"sonnet"}}'
HELPER_ABS='{"tool_name":"Bash","tool_input":{"command":"bash \"/plugin/lib/git-ops.sh\" -C /repo create-feature-worktree x abc"}}'
HELPER_BARE='{"tool_name":"Bash","tool_input":{"command":"cd /repo && create-feature-worktree x abc"}}'
GREP='{"tool_name":"Bash","tool_input":{"command":"rg -n create-feature-worktree lib/"}}'
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
check "feature helper denied through an absolute plugin path" 2 "$HELPER_ABS" \
  CLAUDE_PROJECT_DIR="$PROJECT" LOOP_SPEC_WORKTREES=0
check "bare feature helper invocation denied" 2 "$HELPER_BARE" \
  CLAUDE_PROJECT_DIR="$PROJECT" LOOP_SPEC_WORKTREES=0
check "read-only search for the helper name allowed" 0 "$GREP" \
  CLAUDE_PROJECT_DIR="$PROJECT" LOOP_SPEC_WORKTREES=0
check "EnterWorktree denied" 2 "$ENTER" \
  CLAUDE_PROJECT_DIR="$PROJECT" LOOP_SPEC_WORKTREES=0
# Claude Code's third worktree entry point: "Applies to --worktree, EnterWorktree,
# and agent isolation." isolation:"worktree" creates one without EnterWorktree or git.
check "Agent isolation:worktree denied" 2 "$AGENT_ISO" \
  CLAUDE_PROJECT_DIR="$PROJECT" LOOP_SPEC_WORKTREES=0
check "Agent isolation:remote allowed (creates no local worktree)" 0 "$AGENT_REMOTE" \
  CLAUDE_PROJECT_DIR="$PROJECT" LOOP_SPEC_WORKTREES=0
check "ordinary Agent dispatch allowed" 0 "$AGENT_PLAIN" \
  CLAUDE_PROJECT_DIR="$PROJECT" LOOP_SPEC_WORKTREES=0
check "Agent isolation:worktree allowed when worktrees are enabled" 0 "$AGENT_ISO" \
  CLAUDE_PROJECT_DIR="$PROJECT" LOOP_SPEC_WORKTREES=1
check "read-only worktree list allowed" 0 "$LIST" \
  CLAUDE_PROJECT_DIR="$PROJECT" LOOP_SPEC_WORKTREES=0
check "unrelated Bash allowed" 0 "$TEST" \
  CLAUDE_PROJECT_DIR="$PROJECT" LOOP_SPEC_WORKTREES=0
check "malformed payload fails open" 0 "not json" \
  CLAUDE_PROJECT_DIR="$PROJECT" LOOP_SPEC_WORKTREES=0
# An invalid value is a misconfiguration, not an authorization: it resolves to the
# restrictive mode (0) so worktree creation is still denied, but it must NOT take the
# whole tool surface down with it. Before this, one stray `LOOP_SPEC_WORKTREES=true`
# denied every Bash call in every project and the session could not diagnose itself.
check "invalid setting still denies worktree creation" 2 "$ADD" \
  CLAUDE_PROJECT_DIR="$PROJECT" LOOP_SPEC_WORKTREES=invalid
check "invalid setting does not block unrelated Bash" 0 "$TEST" \
  CLAUDE_PROJECT_DIR="$PROJECT" LOOP_SPEC_WORKTREES=invalid
check "boolean-typo setting does not block unrelated Bash" 0 "$TEST" \
  CLAUDE_PROJECT_DIR="$PROJECT" LOOP_SPEC_WORKTREES=true

# Blast radius: a project with no .loop-spec/ must never be affected by this setting,
# valid or not. The scope check runs before the value check for exactly this reason.
# The hook consults BOTH CLAUDE_PROJECT_DIR and $PWD, so a genuine out-of-scope check
# has to leave this repository -- running from the loop-spec checkout keeps it in scope.
check_outside() {
  local name="$1" expected="$2" payload="$3"
  shift 3
  local outside actual=0
  outside="$(mktemp -d "${TMPDIR:-/tmp}/no-worktrees-guard-outside-XXXXXX")"
  printf '%s' "$payload" \
    | (cd "$outside" && env CLAUDE_PROJECT_DIR="$outside" "$@" bash "$HOOK") >/dev/null 2>&1 \
    || actual=$?
  rm -rf "$outside"
  if [[ "$actual" -eq "$expected" ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected exit $expected, got $actual)"
    ((FAIL++)) || true
  fi
}

check_outside "invalid setting is inert outside a loop-spec project" 0 "$TEST" \
  LOOP_SPEC_WORKTREES=true
check_outside "worktree add outside a loop-spec project is not this hook's business" 0 "$ADD" \
  LOOP_SPEC_WORKTREES=invalid
check_outside "worktrees=0 outside a loop-spec project stays inert" 0 "$ADD" \
  LOOP_SPEC_WORKTREES=0

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
