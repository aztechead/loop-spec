#!/usr/bin/env bash
# Unit tests for lib/worktree-commit-check.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/worktree-commit-check.sh"
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
