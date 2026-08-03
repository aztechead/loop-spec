#!/usr/bin/env bash
# Behavioral tests for the /revise branch-reconciliation helper.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$ROOT/lib/revise-branch.sh"
PASS=0
FAIL=0
pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }
check() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1 (expected $2, got $3)"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/revise-branch-test-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
REMOTE="$WORK/remote.git"
git init -q --bare "$REMOTE"
SEED="$WORK/seed"
git clone -q "$REMOTE" "$SEED"
git -C "$SEED" config user.name test
git -C "$SEED" config user.email test@example.invalid
printf 'base\n' > "$SEED/app.txt"
git -C "$SEED" add app.txt
git -C "$SEED" commit -qm base
git -C "$SEED" push -q origin main
git -C "$REMOTE" symbolic-ref HEAD refs/heads/main
git -C "$SEED" checkout -qb feat/revise
printf 'feature\n' >> "$SEED/app.txt"
git -C "$SEED" commit -qam feature
git -C "$SEED" push -q -u origin feat/revise

# Local-ahead is the exact report: an unpushed commit whose remote is its ancestor.
LOCAL_AHEAD="$WORK/local-ahead"
git clone -q "$REMOTE" "$LOCAL_AHEAD"
git -C "$LOCAL_AHEAD" config user.name test
git -C "$LOCAL_AHEAD" config user.email test@example.invalid
git -C "$LOCAL_AHEAD" checkout -q -b feat/revise --track origin/feat/revise
printf 'local-only\n' >> "$LOCAL_AHEAD/app.txt"
git -C "$LOCAL_AHEAD" commit -qam local-only
git -C "$LOCAL_AHEAD" checkout -q main
out="$(bash "$LIB" prepare "$LOCAL_AHEAD" feat/revise 0)"
check "local-ahead is pushed without force" "pushed-local-ahead" "$(jq -r '.sync' <<<"$out")"
check "local-ahead checks out the PR branch" "feat/revise" "$(git -C "$LOCAL_AHEAD" branch --show-current)"
check "remote receives local fast-forward" "$(git -C "$LOCAL_AHEAD" rev-parse HEAD)" "$(git -C "$LOCAL_AHEAD" rev-parse origin/feat/revise)"

# A local branch behind origin is fast-forwarded after entering its execution root.
REMOTE_AHEAD="$WORK/remote-ahead"
git clone -q "$REMOTE" "$REMOTE_AHEAD"
git -C "$REMOTE_AHEAD" config user.name test
git -C "$REMOTE_AHEAD" config user.email test@example.invalid
git -C "$REMOTE_AHEAD" checkout -q feat/revise
printf 'remote-only\n' >> "$REMOTE_AHEAD/app.txt"
git -C "$REMOTE_AHEAD" commit -qam remote-only
git -C "$REMOTE_AHEAD" push -q origin feat/revise
BEHIND="$WORK/behind"
git clone -q "$REMOTE" "$BEHIND"
git -C "$BEHIND" config user.name test
git -C "$BEHIND" config user.email test@example.invalid
git -C "$BEHIND" checkout -q -b feat/revise "origin/feat/revise~1"
git -C "$BEHIND" checkout -q main
out="$(bash "$LIB" prepare "$BEHIND" feat/revise 0)"
check "remote-ahead fast-forwards safely" "fast-forwarded-remote" "$(jq -r '.sync' <<<"$out")"
check "fast-forward reaches remote head" "$(git -C "$BEHIND" rev-parse origin/feat/revise)" "$(git -C "$BEHIND" rev-parse HEAD)"

# Histories with commits on both sides remain an explicit abort and do not switch the
# caller's checkout before the decision is made.
DIVERGED="$WORK/diverged"
git clone -q "$REMOTE" "$DIVERGED"
git -C "$DIVERGED" config user.name test
git -C "$DIVERGED" config user.email test@example.invalid
git -C "$DIVERGED" checkout -q -b feat/revise "origin/feat/revise~1"
printf 'different-local\n' >> "$DIVERGED/app.txt"
git -C "$DIVERGED" commit -qam different-local
git -C "$DIVERGED" checkout -q main
rc=0
bash "$LIB" prepare "$DIVERGED" feat/revise 0 >/dev/null 2>&1 || rc=$?
check "true divergence aborts" "3" "$rc"
check "divergence leaves caller branch unchanged" "main" "$(git -C "$DIVERGED" branch --show-current)"

# Worktree mode does not force-reset the local branch and produces a distinct root.
WT_SOURCE="$WORK/worktree-source"
git clone -q "$REMOTE" "$WT_SOURCE"
git -C "$WT_SOURCE" config user.name test
git -C "$WT_SOURCE" config user.email test@example.invalid
WT_ROOT="$WORK/revision-worktree"
out="$(bash "$LIB" prepare "$WT_SOURCE" feat/revise 1 "$WT_ROOT")"
check "worktree mode reports requested root" "$WT_ROOT" "$(jq -r '.revisionRoot' <<<"$out")"
check "worktree mode checks out PR branch" "feat/revise" "$(git -C "$WT_ROOT" branch --show-current)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
