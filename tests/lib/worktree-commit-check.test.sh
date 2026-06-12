#!/usr/bin/env bash
# Unit tests for lib/worktree-commit-check.sh and checkpoint.sh -C flag
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/worktree-commit-check.sh"
CHECKPOINT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/checkpoint.sh"
PASS=0
FAIL=0
pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

# Build a throwaway git repo with a base branch and configurable feature branch.
make_repo() {
  local dir; dir="$(mktemp -d)"
  git -C "$dir" init -q
  git -C "$dir" config user.email t@t.t
  git -C "$dir" config user.name t
  git -C "$dir" checkout -q -b main
  echo a > "$dir/a"; git -C "$dir" add -A; git -C "$dir" commit -q -m "base"
  echo "$dir"
}

run() { # run <dir> <base> <branch> -> sets RC
  RC=0
  ( cd "$1" && bash "$SCRIPT" "$2" "$3" ) >/dev/null 2>&1 || RC=$?
}

# 1: branch ahead by 1 -> exit 0
D=$(make_repo)
git -C "$D" checkout -q -b feat/x
git -C "$D" checkout -q -b task/1-x
echo b > "$D/b"; git -C "$D" add -A; git -C "$D" commit -q -m "work"
run "$D" feat/x task/1-x
[[ "$RC" -eq 0 ]] && pass "branch ahead by 1 -> 0" || fail "branch ahead by 1 -> 0 (got $RC)"
rm -rf "$D"

# 2: branch equal to base (no commits) -> exit 1
D=$(make_repo)
git -C "$D" checkout -q -b feat/x
git -C "$D" checkout -q -b task/1-x   # no new commit
run "$D" feat/x task/1-x
[[ "$RC" -eq 1 ]] && pass "no commits over base -> 1" || fail "no commits over base -> 1 (got $RC)"
rm -rf "$D"

# 3: branch ahead by 2 -> exit 0
D=$(make_repo)
git -C "$D" checkout -q -b feat/x
git -C "$D" checkout -q -b task/1-x
echo b > "$D/b"; git -C "$D" add -A; git -C "$D" commit -q -m "w1"
echo c > "$D/c"; git -C "$D" add -A; git -C "$D" commit -q -m "w2"
run "$D" feat/x task/1-x
[[ "$RC" -eq 0 ]] && pass "branch ahead by 2 -> 0" || fail "branch ahead by 2 -> 0 (got $RC)"
rm -rf "$D"

# 4: missing ref -> exit 2
D=$(make_repo)
run "$D" feat/nope task/nope
[[ "$RC" -eq 2 ]] && pass "missing ref -> 2" || fail "missing ref -> 2 (got $RC)"
rm -rf "$D"

# 5: wrong arg count -> exit 2
D=$(make_repo)
RC=0; ( cd "$D" && bash "$SCRIPT" only-one-arg ) >/dev/null 2>&1 || RC=$?
[[ "$RC" -eq 2 ]] && pass "wrong arg count -> 2" || fail "wrong arg count -> 2 (got $RC)"
rm -rf "$D"

# ---- -C flag tests for worktree-commit-check.sh ----

# 6: -C from outside the fixture repo, branch ahead by 1 -> exit 0
D=$(make_repo)
git -C "$D" checkout -q -b feat/y
git -C "$D" checkout -q -b task/2-y
echo d > "$D/d"; git -C "$D" add -A; git -C "$D" commit -q -m "work"
OUTSIDE="$(mktemp -d)"
RC=0
( cd "$OUTSIDE" && bash "$SCRIPT" -C "$D" feat/y task/2-y ) >/dev/null 2>&1 || RC=$?
[[ "$RC" -eq 0 ]] && pass "-C from outside repo, branch ahead -> 0" || fail "-C from outside repo, branch ahead -> 0 (got $RC)"
rm -rf "$D" "$OUTSIDE"

# 7: -C from outside repo, no commits over base -> exit 1
D=$(make_repo)
git -C "$D" checkout -q -b feat/y
git -C "$D" checkout -q -b task/2-y   # no new commit
OUTSIDE="$(mktemp -d)"
RC=0
( cd "$OUTSIDE" && bash "$SCRIPT" -C "$D" feat/y task/2-y ) >/dev/null 2>&1 || RC=$?
[[ "$RC" -eq 1 ]] && pass "-C from outside repo, no commits -> 1" || fail "-C from outside repo, no commits -> 1 (got $RC)"
rm -rf "$D" "$OUTSIDE"

# 8: -C from outside repo, missing refs -> exit 2
D=$(make_repo)
OUTSIDE="$(mktemp -d)"
RC=0
( cd "$OUTSIDE" && bash "$SCRIPT" -C "$D" feat/nope task/nope ) >/dev/null 2>&1 || RC=$?
[[ "$RC" -eq 2 ]] && pass "-C from outside repo, missing refs -> 2" || fail "-C from outside repo, missing refs -> 2 (got $RC)"
rm -rf "$D" "$OUTSIDE"

# ---- -C flag tests for checkpoint.sh ----

# 9: checkpoint tag -C from outside the fixture repo creates tag in target repo
D=$(make_repo)
OUTSIDE="$(mktemp -d)"
RC=0
( cd "$OUTSIDE" && bash "$CHECKPOINT" -C "$D" tag post-plan ) >/dev/null 2>&1 || RC=$?
if [[ "$RC" -eq 0 ]] && git -C "$D" tag | grep -q "loop-spec-checkpoint-post-plan-"; then
  pass "checkpoint tag -C creates tag in target repo"
else
  fail "checkpoint tag -C creates tag in target repo (rc=$RC)"
fi
rm -rf "$D" "$OUTSIDE"

# 10: checkpoint rollback -C restores target repo, file outside is untouched
D=$(make_repo)
# Tag after the initial commit, then modify an existing file in a second commit.
# Rollback to the tag restores the original content of the modified file.
git -C "$D" tag "loop-spec-checkpoint-pre-rollback-test"
echo "modified" > "$D/a"
git -C "$D" add -A
git -C "$D" commit -q -m "modify a"
OUTSIDE="$(mktemp -d)"
# Place a sentinel file outside the target repo that must not be touched
echo "sentinel" > "$OUTSIDE/sentinel.txt"
RC=0
( cd "$OUTSIDE" && LOOP_SPEC_ROLLBACK_CONFIRMED=1 bash "$CHECKPOINT" -C "$D" rollback "loop-spec-checkpoint-pre-rollback-test" ) >/dev/null 2>&1 || RC=$?
# Verify: rollback succeeded, target repo file is restored, sentinel outside is intact
if [[ "$RC" -eq 0 ]] \
    && [[ -f "$OUTSIDE/sentinel.txt" ]] \
    && [[ "$(cat "$OUTSIDE/sentinel.txt")" == "sentinel" ]] \
    && [[ "$(cat "$D/a")" == "a" ]]; then
  pass "checkpoint rollback -C: file outside target repo is untouched"
else
  fail "checkpoint rollback -C: file outside target repo is untouched (rc=$RC, sentinel=$(cat "$OUTSIDE/sentinel.txt" 2>/dev/null), a_content=$(cat "$D/a" 2>/dev/null))"
fi
rm -rf "$D" "$OUTSIDE"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
