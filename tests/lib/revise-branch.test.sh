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
# `main` explicitly, not whatever init.defaultBranch happens to be on this machine:
# git still defaults to `master` when the config is unset, so every `push origin main`
# below failed with "src refspec main does not match any" on an unconfigured host.
git init -q --bare -b main "$REMOTE"
SEED="$WORK/seed"
git clone -q "$REMOTE" "$SEED"
git -C "$SEED" symbolic-ref HEAD refs/heads/main
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
check "worktree mode isolation is worktree" "worktree" "$(jq -r '.isolation' <<<"$out")"
check "worktree mode owned is true" "true" "$(jq -r '.owned' <<<"$out")"

# Branch already checked out in the source repo: go in-place, do not worktree-add.
INPLACE="$WORK/already-checked-out"
git clone -q "$REMOTE" "$INPLACE"
git -C "$INPLACE" config user.name test
git -C "$INPLACE" config user.email test@example.invalid
git -C "$INPLACE" checkout -q feat/revise
INPLACE_ROOT="$WORK/should-not-be-created"
out="$(bash "$LIB" prepare "$INPLACE" feat/revise 1 "$INPLACE_ROOT")"
check "already-checked-out uses the source root" "$(cd "$INPLACE" && pwd -P)" "$(jq -r '.revisionRoot' <<<"$out")"
check "already-checked-out isolation is in-place" "in-place" "$(jq -r '.isolation' <<<"$out")"
check "already-checked-out is not owned" "false" "$(jq -r '.owned' <<<"$out")"
check "already-checked-out does not create the requested worktree" "0" \
  "$([[ -e "$INPLACE_ROOT" ]] && echo 1 || echo 0)"

# Branch already checked out in another worktree: reuse that path, do not add.
REUSE_SRC="$WORK/reuse-source"
git clone -q "$REMOTE" "$REUSE_SRC"
git -C "$REUSE_SRC" config user.name test
git -C "$REUSE_SRC" config user.email test@example.invalid
REUSE_EXISTING="$WORK/existing-feat-worktree"
git -C "$REUSE_SRC" worktree add -q "$REUSE_EXISTING" feat/revise
REUSE_REQUESTED="$WORK/reuse-should-not-create"
out="$(bash "$LIB" prepare "$REUSE_SRC" feat/revise 1 "$REUSE_REQUESTED")"
check "reused worktree reports that path" "$(cd "$REUSE_EXISTING" && pwd -P)" "$(jq -r '.revisionRoot' <<<"$out")"
check "reused worktree isolation is worktree" "worktree" "$(jq -r '.isolation' <<<"$out")"
check "reused worktree is not owned" "false" "$(jq -r '.owned' <<<"$out")"
check "reused worktree does not create a second path" "0" \
  "$([[ -e "$REUSE_REQUESTED" ]] && echo 1 || echo 0)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
