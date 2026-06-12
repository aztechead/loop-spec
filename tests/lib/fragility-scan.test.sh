#!/usr/bin/env bash
# Unit tests for lib/fragility-scan.sh
#
# Standalone: exit 0 on all pass, exit 1 on any failure.
# Summary line printed at end.
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/fragility-scan.sh"
PASS=0
FAIL=0
pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

# ---------------------------------------------------------------------------
# Fixture repo builder
# ---------------------------------------------------------------------------
# Creates a deterministic fixture repo:
#   a.py  -- touched by 3 commits (commits 1, 2, 3)
#   b.py  -- touched by 1 fix: commit (commit 4)
#   c.py  -- added in commit 1, deleted in commit 5 (should be absent from output)
#
# All commits use controlled GIT_AUTHOR_DATE / GIT_COMMITTER_DATE so the
# recency component is deterministic regardless of when the test runs.
make_fixture_repo() {
  local dir; dir="$(mktemp -d)"

  git -c user.email=t@t -c user.name=t -C "$dir" init -q
  git -c user.email=t@t -c user.name=t -C "$dir" checkout -q -b main

  # Commit 1: add a.py and c.py only (b.py intentionally absent)  (2026-01-01)
  printf 'alpha\n' > "$dir/a.py"
  printf 'gamma\n' > "$dir/c.py"
  git -c user.email=t@t -c user.name=t -C "$dir" add a.py c.py
  GIT_AUTHOR_DATE="2026-01-01T00:00:00+00:00" \
  GIT_COMMITTER_DATE="2026-01-01T00:00:00+00:00" \
  git -c user.email=t@t -c user.name=t -C "$dir" \
    commit -q -m "feat: add initial files"

  # Commit 2: update a.py  (2026-02-01)
  printf 'alpha2\n' > "$dir/a.py"
  git -c user.email=t@t -c user.name=t -C "$dir" add a.py
  GIT_AUTHOR_DATE="2026-02-01T00:00:00+00:00" \
  GIT_COMMITTER_DATE="2026-02-01T00:00:00+00:00" \
  git -c user.email=t@t -c user.name=t -C "$dir" \
    commit -q -m "chore: update a.py"

  # Commit 3: update a.py again  (2026-03-01)
  printf 'alpha3\n' > "$dir/a.py"
  git -c user.email=t@t -c user.name=t -C "$dir" add a.py
  GIT_AUTHOR_DATE="2026-03-01T00:00:00+00:00" \
  GIT_COMMITTER_DATE="2026-03-01T00:00:00+00:00" \
  git -c user.email=t@t -c user.name=t -C "$dir" \
    commit -q -m "chore: update a.py again"

  # Commit 4: fix commit adding b.py for the first (and only) time  (2026-04-01)
  printf 'beta\n' > "$dir/b.py"
  git -c user.email=t@t -c user.name=t -C "$dir" add b.py
  GIT_AUTHOR_DATE="2026-04-01T00:00:00+00:00" \
  GIT_COMMITTER_DATE="2026-04-01T00:00:00+00:00" \
  git -c user.email=t@t -c user.name=t -C "$dir" \
    commit -q -m "fix: add beta logic"

  # Commit 5: delete c.py  (2026-05-01)
  git -c user.email=t@t -c user.name=t -C "$dir" rm -q c.py
  GIT_AUTHOR_DATE="2026-05-01T00:00:00+00:00" \
  GIT_COMMITTER_DATE="2026-05-01T00:00:00+00:00" \
  git -c user.email=t@t -c user.name=t -C "$dir" \
    commit -q -m "chore: remove c.py"

  echo "$dir"
}

FIXTURE="$(make_fixture_repo)"

# ---------------------------------------------------------------------------
# Test 1: output is valid JSON
# ---------------------------------------------------------------------------
OUT="$(bash "$SCRIPT" "$FIXTURE" 2>&1)"
if echo "$OUT" | jq . >/dev/null 2>&1; then
  pass "output is valid JSON"
else
  fail "output is valid JSON (got: $OUT)"
fi

# ---------------------------------------------------------------------------
# Test 2: a.py ranks first (3 commits > 1 commit)
# ---------------------------------------------------------------------------
FIRST="$(echo "$OUT" | jq -r '.files[0].path' 2>/dev/null || echo "")"
if [[ "$FIRST" == "a.py" ]]; then
  pass "a.py ranks first by churn"
else
  fail "a.py ranks first by churn (got: $FIRST)"
fi

# ---------------------------------------------------------------------------
# Test 3: c.py is absent (deleted file excluded via git ls-files)
# ---------------------------------------------------------------------------
C_PRESENT="$(echo "$OUT" | jq '[.files[].path] | index("c.py")' 2>/dev/null || echo "null")"
if [[ "$C_PRESENT" == "null" ]]; then
  pass "c.py absent from output (deleted file excluded)"
else
  fail "c.py absent from output (deleted file excluded) -- got index $C_PRESENT"
fi

# ---------------------------------------------------------------------------
# Test 4: a.py has 3 commits, b.py has 1 commit + 1 bugfixCommit
# ---------------------------------------------------------------------------
A_COMMITS="$(echo "$OUT" | jq '.files[] | select(.path=="a.py") | .commits' 2>/dev/null || echo "")"
B_COMMITS="$(echo "$OUT" | jq '.files[] | select(.path=="b.py") | .commits' 2>/dev/null || echo "")"
B_BUGFIX="$(echo "$OUT" | jq '.files[] | select(.path=="b.py") | .bugfixCommits' 2>/dev/null || echo "")"

if [[ "$A_COMMITS" == "3" ]]; then
  pass "a.py has 3 commits"
else
  fail "a.py has 3 commits (got: $A_COMMITS)"
fi

if [[ "$B_COMMITS" == "1" ]]; then
  pass "b.py has 1 commit"
else
  fail "b.py has 1 commit (got: $B_COMMITS)"
fi

if [[ "$B_BUGFIX" == "1" ]]; then
  pass "b.py has 1 bugfixCommit"
else
  fail "b.py has 1 bugfixCommit (got: $B_BUGFIX)"
fi

# ---------------------------------------------------------------------------
# Test 5: deterministic across two runs (byte-equal after dropping generatedAt)
# ---------------------------------------------------------------------------
RUN1="$(bash "$SCRIPT" "$FIXTURE" 2>/dev/null | jq 'del(.generatedAt)')"
RUN2="$(bash "$SCRIPT" "$FIXTURE" 2>/dev/null | jq 'del(.generatedAt)')"
if [[ "$RUN1" == "$RUN2" ]]; then
  pass "deterministic: two runs byte-equal after deleting generatedAt"
else
  fail "deterministic: two runs differ after deleting generatedAt"
fi

# ---------------------------------------------------------------------------
# Test 6: exit 1 on a non-repo directory
# ---------------------------------------------------------------------------
NONREPO="$(mktemp -d)"
RC=0
bash "$SCRIPT" "$NONREPO" >/dev/null 2>&1 || RC=$?
if [[ "$RC" -eq 1 ]]; then
  pass "exit 1 on non-repo path"
else
  fail "exit 1 on non-repo path (got: $RC)"
fi
rm -rf "$NONREPO"

# ---------------------------------------------------------------------------
# Test 7: --top limits output count
# ---------------------------------------------------------------------------
TOP_OUT="$(bash "$SCRIPT" "$FIXTURE" --top 1 2>/dev/null)"
COUNT="$(echo "$TOP_OUT" | jq '.files | length' 2>/dev/null || echo "")"
if [[ "$COUNT" -eq 1 ]]; then
  pass "--top 1 limits output to 1 file"
else
  fail "--top 1 limits output to 1 file (got count: $COUNT)"
fi

# ---------------------------------------------------------------------------
# Test 8: empty history -> files: []
# ---------------------------------------------------------------------------
EMPTY_REPO="$(mktemp -d)"
git -c user.email=t@t -c user.name=t -C "$EMPTY_REPO" init -q
git -c user.email=t@t -c user.name=t -C "$EMPTY_REPO" checkout -q -b main
EMPTY_OUT="$(bash "$SCRIPT" "$EMPTY_REPO" 2>/dev/null)"
EMPTY_FILES="$(echo "$EMPTY_OUT" | jq '.files | length' 2>/dev/null || echo "")"
if [[ "$EMPTY_FILES" -eq 0 ]]; then
  pass "empty history -> files: []"
else
  fail "empty history -> files: [] (got length: $EMPTY_FILES)"
fi
rm -rf "$EMPTY_REPO"

# ---------------------------------------------------------------------------
# Test 9: --since filters to relevant window
# ---------------------------------------------------------------------------
SINCE_OUT="$(bash "$SCRIPT" "$FIXTURE" --since "2026-04-01" 2>/dev/null)"
WINDOW_VAL="$(echo "$SINCE_OUT" | jq -r '.window' 2>/dev/null || echo "")"
if [[ "$WINDOW_VAL" == "2026-04-01" ]]; then
  pass "--since sets window field correctly"
else
  fail "--since sets window field correctly (got: $WINDOW_VAL)"
fi

# ---------------------------------------------------------------------------
# Cleanup + summary
# ---------------------------------------------------------------------------
rm -rf "$FIXTURE"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
