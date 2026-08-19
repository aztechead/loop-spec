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

exit_code=0
LOOP_SPEC_WORKTREES=0 bash "$LIB" create-feature-worktree disabled "$base_sha" >/dev/null 2>&1 || exit_code=$?
check "K0: worktree opt-out rejects feature worktree creation" "1" "$exit_code"
[[ ! -e ".claude/worktrees/disabled" ]] && r=ok || r=bad
check "K1: worktree opt-out creates no directory" "ok" "$r"
exit_code=0
LOOP_SPEC_WORKTREES=invalid bash "$LIB" create-feature-worktree invalid "$base_sha" >/dev/null 2>&1 || exit_code=$?
check "K2: invalid worktree setting is rejected" "1" "$exit_code"

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

# A failed status probe is unknown state and must fail closed as dirty.
git -C "$CLEAN_REPO" checkout -- a
cp "$CLEAN_REPO/.git/index" "$CLEAN_REPO/.git/index.saved"
printf 'corrupt-index' > "$CLEAN_REPO/.git/index"
got=$(bash "$LIB" -C "$CLEAN_REPO" ensure-clean-or-stash 2>/dev/null)
check "W2: status failure reports dirty" "dirty" "$got"
mv "$CLEAN_REPO/.git/index.saved" "$CLEAN_REPO/.git/index"

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

# Attach an existing branch (named-PR adoption) instead of minting feat/{slug}.
exit_code=0
LOOP_SPEC_WORKTREES=0 bash "$LIB" -C "$CLEAN_REPO" \
  attach-feature-worktree no-wt feat/c-slug >/dev/null 2>&1 || exit_code=$?
check "AG: worktree opt-out rejects attach-feature-worktree" "1" "$exit_code"

exit_code=0
bash "$LIB" -C "$CLEAN_REPO" attach-feature-worktree missing feat/does-not-exist \
  >/dev/null 2>&1 || exit_code=$?
check "AH: attach-feature-worktree rejects a missing branch" "1" "$exit_code"

git -C "$CLEAN_REPO" branch feat/attach-me "$base_sha_clean"
got=$(bash "$LIB" -C "$CLEAN_REPO" attach-feature-worktree attach-me feat/attach-me)
check "AI: attach-feature-worktree prints the worktree path" \
  "${CLEAN_REPO}/.claude/worktrees/attach-me" "$got"
[[ -d "${CLEAN_REPO}/.claude/worktrees/attach-me" ]] && r=ok || r=bad
check "AI2: attach-feature-worktree creates the worktree dir" "ok" "$r"
git -C "$CLEAN_REPO" show-ref --verify --quiet refs/heads/feat/attach-me && r=ok || r=bad
check "AI3: attach-feature-worktree keeps the existing branch" "ok" "$r"

got=$(bash "$LIB" -C "$CLEAN_REPO" attach-feature-worktree attach-me feat/attach-me)
check "AJ: attach-feature-worktree reuses the checkout that already holds the branch" \
  "${CLEAN_REPO}/.claude/worktrees/attach-me" "$got"

orig_branch=$(git -C "$CLEAN_REPO" rev-parse --abbrev-ref HEAD)
git -C "$CLEAN_REPO" checkout -q -b feat/on-main "$base_sha_clean"
main_wt=$(git -C "$CLEAN_REPO" rev-parse --show-toplevel)
got=$(bash "$LIB" -C "$CLEAN_REPO" attach-feature-worktree on-main feat/on-main)
check "AK: attach-feature-worktree reuses the main worktree when it holds the branch" \
  "$main_wt" "$got"
got=$(bash "$LIB" -C "$CLEAN_REPO" checkout-path-for-branch feat/on-main)
check "AK2: checkout-path-for-branch names the main worktree" "$main_wt" "$got"
git -C "$CLEAN_REPO" checkout -q "$orig_branch"
got=$(bash "$LIB" -C "$CLEAN_REPO" checkout-path-for-branch feat/does-not-exist)
check "AK3: checkout-path-for-branch is empty when the branch is not checked out" "" "$got"

BARE="$OUTSIDE/bare-origin"
git init --bare -q "$BARE"
git -C "$CLEAN_REPO" remote add origin "$BARE"
git -C "$CLEAN_REPO" push -q origin HEAD:feat/from-origin
git -C "$CLEAN_REPO" fetch -q origin
git -C "$CLEAN_REPO" show-ref --verify --quiet refs/heads/feat/from-origin && \
  git -C "$CLEAN_REPO" branch -D feat/from-origin >/dev/null
got=$(bash "$LIB" -C "$CLEAN_REPO" attach-feature-worktree from-origin feat/from-origin)
check "AL: attach-feature-worktree creates a local branch from origin" \
  "${CLEAN_REPO}/.claude/worktrees/from-origin" "$got"
git -C "$CLEAN_REPO" show-ref --verify --quiet refs/heads/feat/from-origin && r=ok || r=bad
check "AL2: the origin-only attach created the local branch" "ok" "$r"

# ---------------------------------------------------------------------------
# fast-forward-to-origin: an adopted PR head must not be worked on while stale
# ---------------------------------------------------------------------------
FF_BARE="$OUTSIDE/ff-bare"
git init --bare -q "$FF_BARE"
FF_A="$OUTSIDE/ff-a"
git init -q "$FF_A"
git -C "$FF_A" config user.email t@t
git -C "$FF_A" config user.name t
echo one > "$FF_A/f"
git -C "$FF_A" add f
git -C "$FF_A" commit -q -m one
git -C "$FF_A" branch -M pr/head
git -C "$FF_A" remote add origin "$FF_BARE"
git -C "$FF_A" push -q origin pr/head
git -C "$FF_BARE" symbolic-ref HEAD refs/heads/pr/head
old_head=$(git -C "$FF_A" rev-parse HEAD)

FF_B="$OUTSIDE/ff-b"
git clone -q "$FF_BARE" "$FF_B"
git -C "$FF_B" config user.email t@t
git -C "$FF_B" config user.name t

got=$(bash "$LIB" -C "$WORK" fast-forward-to-origin main 2>/dev/null)
check "AM: fast-forward-to-origin is unavailable with no origin remote" "unavailable" "$got"

got=$(bash "$LIB" -C "$FF_B" fast-forward-to-origin pr/nope 2>/dev/null)
check "AN: fast-forward-to-origin is unavailable when origin has no such branch" \
  "unavailable" "$got"

got=$(bash "$LIB" -C "$FF_B" fast-forward-to-origin pr/head 2>/dev/null)
check "AO: fast-forward-to-origin is already-current when local matches origin" \
  "already-current" "$got"

# origin moves ahead; the clone's checked-out branch is now stale.
echo two > "$FF_A/f"
git -C "$FF_A" commit -q -am two
git -C "$FF_A" push -q origin pr/head
new_head=$(git -C "$FF_A" rev-parse HEAD)

got=$(bash "$LIB" -C "$FF_B" fast-forward-to-origin pr/head 2>/dev/null)
check "AP: fast-forward-to-origin syncs a checked-out branch that is behind" "synced" "$got"
check "AP2: the checkout is at origin's head" "$new_head" "$(git -C "$FF_B" rev-parse HEAD)"

got=$(bash "$LIB" -C "$FF_B" fast-forward-to-origin pr/other 2>/dev/null)
check "AQ: fast-forward-to-origin is unavailable when there is no local branch" \
  "unavailable" "$got"

# Not checked out: the ref moves by update-ref rather than by a merge.
git -C "$FF_B" checkout -q -b parking
git -C "$FF_B" branch -f pr/head "$old_head"
got=$(bash "$LIB" -C "$FF_B" fast-forward-to-origin pr/head 2>/dev/null)
check "AR: fast-forward-to-origin syncs a branch that is not checked out" "synced" "$got"
check "AR2: refs/heads/pr/head moved to origin's head" \
  "$new_head" "$(git -C "$FF_B" rev-parse refs/heads/pr/head)"

# Local commits origin does not have are work, not staleness: never discarded.
git -C "$FF_B" branch -f pr/head "$old_head"
git -C "$FF_B" checkout -q pr/head
echo local > "$FF_B/g"
git -C "$FF_B" add g
git -C "$FF_B" commit -q -m local
diverged_head=$(git -C "$FF_B" rev-parse HEAD)
got=$(bash "$LIB" -C "$FF_B" fast-forward-to-origin pr/head 2>/dev/null)
check "AS: fast-forward-to-origin reports diverged" "diverged" "$got"
check "AS2: the diverged local head is left alone" \
  "$diverged_head" "$(git -C "$FF_B" rev-parse refs/heads/pr/head)"

# A checkout git refuses to move is "blocked", not a silent stale success.
git -C "$FF_B" reset -q --hard "$old_head"
echo uncommitted > "$FF_B/f"
got=$(bash "$LIB" -C "$FF_B" fast-forward-to-origin pr/head 2>/dev/null)
check "AT: fast-forward-to-origin reports blocked when the checkout refuses" "blocked" "$got"
check "AT2: the blocked checkout keeps its own head" \
  "$old_head" "$(git -C "$FF_B" rev-parse HEAD)"

exit_code=0
bash "$LIB" -C "$FF_B" fast-forward-to-origin >/dev/null 2>&1 || exit_code=$?
check "AU: fast-forward-to-origin with no branch exits 1" "1" "$exit_code"

# AB: -C missing path argument exits 1
exit_code=0
bash "$LIB" -C >/dev/null 2>&1 || exit_code=$?
check "AB: -C with no path argument exits 1" "1" "$exit_code"

# ---------------------------------------------------------------------------
# Worktree location: operator override, discovery, and failure cleanup
# ---------------------------------------------------------------------------
ALT="${TMPDIR:-/tmp}/loop-spec-git-ops-alt.$$"
trap 'chmod -R u+rwX "$ALT" 2>/dev/null; rm -rf "$WORK" "$OUTSIDE" "$CLEAN_REPO" "$ALT"' EXIT
mkdir -p "$ALT"
ALT="$(cd "$ALT" && pwd -P)"

got=$(LOOP_SPEC_WORKTREE_DIR="$ALT/wt" bash "$LIB" -C "$CLEAN_REPO" create-feature-worktree o-slug "$base_sha_clean")
check "AC: LOOP_SPEC_WORKTREE_DIR relocates the feature worktree out of the repo" \
  "$ALT/wt/features/o-slug" "$got"
[[ -d "$ALT/wt/features/o-slug" ]] && r=ok || r=bad
check "AC2: the relocated worktree exists on disk" "ok" "$r"
git -C "$CLEAN_REPO" show-ref --verify --quiet refs/heads/feat/o-slug && r=ok || r=bad
check "AC3: the relocated worktree still gets branch feat/o-slug" "ok" "$r"

list_o=$(bash "$LIB" -C "$CLEAN_REPO" list-feature-worktrees)
echo "$list_o" | grep -q "feat/o-slug" && r=ok || r=bad
check "AD: list-feature-worktrees discovers an out-of-repo feature worktree" "ok" "$r"
echo "$list_o" | grep -q "feat/c-slug" && r=ok || r=bad
check "AD2: in-repo worktrees stay discoverable alongside relocated ones" "ok" "$r"

# A failed checkout must not strand a partial worktree or an orphan branch.
exit_code=0
bash "$LIB" -C "$CLEAN_REPO" create-feature-worktree fail-slug deadbeefdeadbeef >/dev/null 2>&1 || exit_code=$?
check "AE: create-feature-worktree fails on an unresolvable base (exit 1)" "1" "$exit_code"
[[ -e "$CLEAN_REPO/.claude/worktrees/fail-slug" ]] && r=bad || r=ok
check "AE2: a failed create leaves no partial worktree behind" "ok" "$r"
git -C "$CLEAN_REPO" show-ref --verify --quiet refs/heads/feat/fail-slug && r=bad || r=ok
check "AE3: a failed create leaves no orphan branch behind" "ok" "$r"

if [[ "$(id -u)" == "0" ]]; then
  echo "SKIP: AF unwritable-base diagnostic (running as root)"
else
  # No candidate base can hold the checkout: refuse with an actionable message
  # instead of letting git die on a bare permission error.
  BOX="$ALT/box"
  mkdir -p "$BOX/repo"
  git -C "$BOX/repo" init -q
  git -C "$BOX/repo" config user.email t@t
  git -C "$BOX/repo" config user.name t
  mkdir -p "$BOX/repo/.claude/commands"
  echo "# setup" > "$BOX/repo/.claude/commands/setup.md"
  git -C "$BOX/repo" add .claude/commands/setup.md
  git -C "$BOX/repo" commit -q -m init
  box_sha=$(git -C "$BOX/repo" rev-parse HEAD)
  chmod 500 "$BOX/repo/.claude"
  chmod 500 "$BOX"
  exit_code=0
  err=$(HOME="$BOX" bash "$LIB" -C "$BOX/repo" create-feature-worktree boxed "$box_sha" 2>&1 >/dev/null) || exit_code=$?
  chmod 700 "$BOX"
  check "AF: create-feature-worktree refuses when no base is writable (exit 1)" "1" "$exit_code"
  grep -q "LOOP_SPEC_WORKTREE_DIR" <<<"$err" && r=ok || r=missing
  check "AF2: the refusal names the operator escape hatch" "ok" "$r"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
