#!/usr/bin/env bash
# Tests for lib/git-ops.sh
set -euo pipefail

LIB="$(cd "$(dirname "$0")/../.." && pwd)/lib/git-ops.sh"
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

# slugify cases (no git context required)
got=$(bash "$LIB" slugify "Add Subtract Function")
check "A: slugify basic" "add-subtract-function" "$got"

got=$(bash "$LIB" slugify "Foo!! Bar??  Baz")
check "B: slugify with punctuation + double spaces" "foo-bar-baz" "$got"

got=$(bash "$LIB" slugify "  ---trim me---  ")
check "C: slugify trims leading/trailing dashes" "trim-me" "$got"

got=$(bash "$LIB" slugify "MIXED Case 123")
check "D: slugify lowercases + keeps digits" "mixed-case-123" "$got"

# Git-context cases (use temp repo)
WORK="${TMPDIR:-/tmp}/loop-spec-git-ops.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"
cd "$WORK"
git init -q
git config user.email t@t
git config user.name t
echo x > a
git add a
git commit -q -m init

# detect-base-branch with no origin → fallback "main"
got=$(bash "$LIB" detect-base-branch)
check "E: detect-base-branch fallback 'main' when no origin" "main" "$got"

# ensure-clean-or-stash on clean tree
got=$(bash "$LIB" ensure-clean-or-stash)
check "F: ensure-clean-or-stash reports clean" "clean" "$got"

# ensure-clean-or-stash on dirty tree
echo y > a
got=$(bash "$LIB" ensure-clean-or-stash)
check "G: ensure-clean-or-stash reports dirty" "dirty" "$got"

# current-sha returns 7-char short sha
got=$(bash "$LIB" current-sha)
[[ ${#got} -ge 7 && ${#got} -le 12 ]] && short=ok || short=bad
check "H: current-sha returns short sha (7-12 chars)" "ok" "$short"

# --- Feature worktree subcommands (create-feature-worktree, list-feature-worktrees) ---
base_sha=$(git rev-parse HEAD)

got=$(bash "$LIB" create-feature-worktree my-slug "$base_sha")
check "K: create-feature-worktree prints relative path" ".claude/worktrees/my-slug" "$got"

[[ -d ".claude/worktrees/my-slug" ]] && r=ok || r=bad
check "L: create-feature-worktree creates the worktree dir" "ok" "$r"

git show-ref --verify --quiet refs/heads/feat/my-slug && r=ok || r=bad
check "M: create-feature-worktree creates branch feat/my-slug" "ok" "$r"

exit_code=0
bash "$LIB" create-feature-worktree my-slug "$base_sha" >/dev/null 2>&1 || exit_code=$?
check "N: create-feature-worktree rejects existing worktree path (exit 1)" "1" "$exit_code"

git branch feat/pre-existing "$base_sha"
exit_code=0
bash "$LIB" create-feature-worktree pre-existing "$base_sha" >/dev/null 2>&1 || exit_code=$?
check "O: create-feature-worktree rejects existing branch (exit 1)" "1" "$exit_code"

exit_code=0
bash "$LIB" create-feature-worktree >/dev/null 2>&1 || exit_code=$?
check "P: create-feature-worktree rejects missing args (exit 1)" "1" "$exit_code"

list=$(bash "$LIB" list-feature-worktrees)
echo "$list" | grep -q "feat/my-slug" && r=ok || r=bad
check "Q: list-feature-worktrees lists the created worktree" "ok" "$r"

printf '%s' "$list" | grep -q "$(printf '\t')" && r=ok || r=bad
check "R: list-feature-worktrees output is tab-separated" "ok" "$r"

echo "$list" | grep -qF "$WORK$(printf '\t')" && r=bad || r=ok
check "S: list-feature-worktrees excludes the main worktree" "ok" "$r"

# Bad invocation
exit_code=0
bash "$LIB" bogus >/dev/null 2>&1 || exit_code=$?
check "I: bad subcommand rejected (exit 1)" "1" "$exit_code"

# Empty slugify input rejected
exit_code=0
bash "$LIB" slugify "" >/dev/null 2>&1 || exit_code=$?
check "J: empty slugify input rejected (exit 1)" "1" "$exit_code"

# ---------------------------------------------------------------------------
# -C <path> cases: run from an unrelated cwd (use a temp dir outside WORK)
# ---------------------------------------------------------------------------
OUTSIDE="${TMPDIR:-/tmp}/loop-spec-git-ops-outside.$$"
mkdir -p "$OUTSIDE"
trap 'rm -rf "$WORK" "$OUTSIDE"' EXIT
# Return to the outside dir so every -C call must carry the path explicitly
cd "$OUTSIDE"

# T: detect-base-branch via -C (no origin -> fallback main)
got=$(bash "$LIB" -C "$WORK" detect-base-branch)
check "T: -C detect-base-branch fallback 'main' (from outside cwd)" "main" "$got"

# U: current-sha via -C
got=$(bash "$LIB" -C "$WORK" current-sha)
[[ ${#got} -ge 7 && ${#got} -le 12 ]] && short=ok || short=bad
check "U: -C current-sha returns short sha (from outside cwd)" "ok" "$short"

# V: ensure-clean-or-stash via -C (the fixture repo has uncommitted changes from test G;
#    reset it to a known clean state first)
# The main worktree at WORK has a dirty a file from test G; create a fresh clean repo for -C clean test
CLEAN_REPO="${TMPDIR:-/tmp}/loop-spec-git-ops-clean.$$"
mkdir -p "$CLEAN_REPO"
git -C "$CLEAN_REPO" init -q
git -C "$CLEAN_REPO" config user.email t@t
git -C "$CLEAN_REPO" config user.name t
echo x > "$CLEAN_REPO/a"
git -C "$CLEAN_REPO" add a
git -C "$CLEAN_REPO" commit -q -m init
trap 'rm -rf "$WORK" "$OUTSIDE" "$CLEAN_REPO"' EXIT

got=$(bash "$LIB" -C "$CLEAN_REPO" ensure-clean-or-stash)
check "V: -C ensure-clean-or-stash reports clean (from outside cwd)" "clean" "$got"

# Startup-owned local cache files do not make their own clean-base guard fail.
mkdir -p "$CLEAN_REPO/.loop-spec/decisions-staging"
echo '{}' > "$CLEAN_REPO/.loop-spec/runtime.json"
echo '{}' > "$CLEAN_REPO/.loop-spec/decisions-staging/decisions.jsonl"
got=$(bash "$LIB" -C "$CLEAN_REPO" ensure-clean-or-stash)
check "V2: startup runtime files are ignored by clean guard" "clean" "$got"

# W: ensure-clean-or-stash dirty via -C
echo y > "$CLEAN_REPO/a"
got=$(bash "$LIB" -C "$CLEAN_REPO" ensure-clean-or-stash)
check "W: -C ensure-clean-or-stash reports dirty (from outside cwd)" "dirty" "$got"

# X: create-feature-worktree via -C prints absolute path inside the target repo
base_sha_clean=$(git -C "$CLEAN_REPO" rev-parse HEAD)
# Reset the dirty file first so create-feature-worktree works
git -C "$CLEAN_REPO" checkout -- a
got=$(bash "$LIB" -C "$CLEAN_REPO" create-feature-worktree c-slug "$base_sha_clean")
expected_wt="${CLEAN_REPO}/.claude/worktrees/c-slug"
check "X: -C create-feature-worktree prints absolute path" "$expected_wt" "$got"

[[ -d "$expected_wt" ]] && r=ok || r=bad
check "Y: -C create-feature-worktree creates the worktree dir at absolute path" "ok" "$r"

git -C "$CLEAN_REPO" show-ref --verify --quiet refs/heads/feat/c-slug && r=ok || r=bad
check "Z: -C create-feature-worktree creates branch feat/c-slug" "ok" "$r"

# AA: list-feature-worktrees via -C lists the worktree created above
list_c=$(bash "$LIB" -C "$CLEAN_REPO" list-feature-worktrees)
echo "$list_c" | grep -q "feat/c-slug" && r=ok || r=bad
check "AA: -C list-feature-worktrees lists the worktree created with -C (from outside cwd)" "ok" "$r"

# AB: -C missing path argument exits 1
exit_code=0
bash "$LIB" -C >/dev/null 2>&1 || exit_code=$?
check "AB: -C with no path argument exits 1" "1" "$exit_code"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
