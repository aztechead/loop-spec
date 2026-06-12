#!/usr/bin/env bash
# Unit tests for lib/workspace.sh
# Run: bash tests/lib/workspace.test.sh  (from repo root, or standalone)
# Exit 0 on all pass, 1 if any fail.
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/workspace.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

# Helper: make a minimal git repo at <dir> with one commit.
make_git_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email "t@t"
  git -C "$dir" config user.name "t"
  echo "init" > "$dir/README"
  git -C "$dir" add README
  git -C "$dir" commit -q -m "init"
}

# ============================================================
# Case: single -- detect from a nested subdir inside one repo
# ============================================================
{
  D="$(mktemp -d)"
  trap "rm -rf '$D'" EXIT

  make_git_repo "$D"
  mkdir -p "$D/sub/deep"

  result="$(bash "$SCRIPT" detect "$D/sub/deep")"

  mode="$(printf '%s' "$result" | jq -r '.mode')"
  root="$(printf '%s' "$result" | jq -r '.root')"

  # Resolve symlinks in D so the comparison works on macOS where
  # mktemp returns /var/... but git rev-parse returns /private/var/...
  D_real="$(cd "$D" && pwd -P)"

  [[ "$mode" == "single" ]] && pass "single: mode is 'single'" || fail "single: mode is 'single' (got '$mode')"
  [[ "$root" == "$D_real" ]] && pass "single: root is repo toplevel" || fail "single: root is repo toplevel (got '$root', expected '$D_real')"

  # JSON must be parseable by jq
  printf '%s' "$result" | jq . >/dev/null 2>&1 && pass "single: output is valid JSON" || fail "single: output is valid JSON"

  rm -rf "$D"
  trap - EXIT
}

# ============================================================
# Case: discover -- 2 child repos + 1 plain dir + 1 hidden dir
# ============================================================
{
  D="$(mktemp -d)"
  trap "rm -rf '$D'" EXIT

  # Two child git repos.
  make_git_repo "$D/backend"
  make_git_repo "$D/frontend"

  # One plain (non-git) directory.
  mkdir -p "$D/docs"
  echo "plain" > "$D/docs/notes.txt"

  # One hidden dir (should be skipped).
  mkdir -p "$D/.hidden"
  make_git_repo "$D/.hidden"

  result="$(bash "$SCRIPT" detect "$D")"
  mode="$(printf '%s' "$result" | jq -r '.mode')"
  source="$(printf '%s' "$result" | jq -r '.source')"
  names="$(printf '%s' "$result" | jq -r '[.repos[].name] | join(",")')"
  root="$(printf '%s' "$result" | jq -r '.root')"

  [[ "$mode" == "workspace" ]] && pass "discover: mode is 'workspace'" || fail "discover: mode is 'workspace' (got '$mode')"
  [[ "$source" == "discovered" ]] && pass "discover: source is 'discovered'" || fail "discover: source is 'discovered' (got '$source')"
  [[ "$root" == "$D" ]] && pass "discover: root matches invocation dir" || fail "discover: root matches invocation dir (got '$root')"
  [[ "$names" == "backend,frontend" ]] && pass "discover: repos sorted by name, hidden skipped" || fail "discover: repos sorted by name, hidden skipped (got '$names')"

  # Must not contain docs (plain dir).
  has_docs="$(printf '%s' "$result" | jq -r '[.repos[].name] | index("docs")')"
  [[ "$has_docs" == "null" ]] && pass "discover: plain dir excluded" || fail "discover: plain dir excluded (docs present)"

  # Must not contain .hidden.
  has_hidden="$(printf '%s' "$result" | jq -r '[.repos[].name] | index(".hidden")')"
  [[ "$has_hidden" == "null" ]] && pass "discover: hidden dir excluded" || fail "discover: hidden dir excluded (.hidden present)"

  # list-repos output.
  list="$(bash "$SCRIPT" list-repos "$D")"
  echo "$list" | grep -qF "backend	backend" && pass "list-repos: backend line present" || fail "list-repos: backend line present"
  echo "$list" | grep -qF "frontend	frontend" && pass "list-repos: frontend line present" || fail "list-repos: frontend line present"

  printf '%s' "$result" | jq . >/dev/null 2>&1 && pass "discover: output is valid JSON" || fail "discover: output is valid JSON"

  rm -rf "$D"
  trap - EXIT
}

# ============================================================
# Case: pin -- workspace.json subset wins even when parent is a git repo
# ============================================================
{
  D="$(mktemp -d)"
  trap "rm -rf '$D'" EXIT

  # Make the parent itself a git repo.
  make_git_repo "$D"

  # Two child repos.
  make_git_repo "$D/alpha"
  make_git_repo "$D/beta"
  make_git_repo "$D/gamma"

  # Pin only alpha and beta.
  mkdir -p "$D/.loop-spec"
  cat > "$D/.loop-spec/workspace.json" <<'JSON'
{
  "schemaVersion": 1,
  "repos": [
    {"name": "alpha", "path": "alpha"},
    {"name": "beta",  "path": "beta"}
  ]
}
JSON

  result="$(bash "$SCRIPT" detect "$D")"
  mode="$(printf '%s' "$result" | jq -r '.mode')"
  source="$(printf '%s' "$result" | jq -r '.source')"
  names="$(printf '%s' "$result" | jq -r '[.repos[].name] | join(",")')"

  # Pin wins over single-mode detection.
  [[ "$mode" == "workspace" ]] && pass "pin: mode is 'workspace' (not single)" || fail "pin: mode is 'workspace' (not single) (got '$mode')"
  [[ "$source" == "config" ]] && pass "pin: source is 'config'" || fail "pin: source is 'config' (got '$source')"
  [[ "$names" == "alpha,beta" ]] && pass "pin: only pinned repos in result" || fail "pin: only pinned repos in result (got '$names')"

  # Repo not in pin (gamma) must be absent.
  has_gamma="$(printf '%s' "$result" | jq -r '[.repos[].name] | index("gamma")')"
  [[ "$has_gamma" == "null" ]] && pass "pin: unpinned repo excluded" || fail "pin: unpinned repo excluded (gamma present)"

  printf '%s' "$result" | jq . >/dev/null 2>&1 && pass "pin: output is valid JSON" || fail "pin: output is valid JSON"

  # Extra test: missing schemaVersion is tolerated.
  cat > "$D/.loop-spec/workspace.json" <<'JSON'
{
  "repos": [
    {"name": "alpha", "path": "alpha"}
  ]
}
JSON
  result2="$(bash "$SCRIPT" detect "$D")"
  mode2="$(printf '%s' "$result2" | jq -r '.mode')"
  [[ "$mode2" == "workspace" ]] && pass "pin: missing schemaVersion tolerated" || fail "pin: missing schemaVersion tolerated (got '$mode2')"

  # Extra test: unknown extra fields are tolerated.
  cat > "$D/.loop-spec/workspace.json" <<'JSON'
{
  "schemaVersion": 1,
  "unknownField": "ignored",
  "repos": [
    {"name": "alpha", "path": "alpha", "extraKey": "extraVal"}
  ]
}
JSON
  result3="$(bash "$SCRIPT" detect "$D")"
  mode3="$(printf '%s' "$result3" | jq -r '.mode')"
  [[ "$mode3" == "workspace" ]] && pass "pin: unknown extra fields tolerated" || fail "pin: unknown extra fields tolerated (got '$mode3')"

  rm -rf "$D"
  trap - EXIT
}

# ============================================================
# Case: pin-invalid -- various invalid workspace.json configs
# ============================================================
{
  D="$(mktemp -d)"
  trap "rm -rf '$D'" EXIT
  make_git_repo "$D/valid-repo"
  mkdir -p "$D/.loop-spec"

  # Sub-case: nonexistent path -> exit 1.
  cat > "$D/.loop-spec/workspace.json" <<'JSON'
{
  "repos": [
    {"name": "missing", "path": "does-not-exist"}
  ]
}
JSON
  rc=0
  bash "$SCRIPT" detect "$D" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 1 ]] && pass "pin-invalid: nonexistent path -> exit 1" || fail "pin-invalid: nonexistent path -> exit 1 (got rc=$rc)"

  # Sub-case: duplicate repo names -> exit 1.
  cat > "$D/.loop-spec/workspace.json" <<JSON
{
  "repos": [
    {"name": "valid-repo", "path": "valid-repo"},
    {"name": "valid-repo", "path": "valid-repo"}
  ]
}
JSON
  rc=0
  bash "$SCRIPT" detect "$D" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 1 ]] && pass "pin-invalid: duplicate repo names -> exit 1" || fail "pin-invalid: duplicate repo names -> exit 1 (got rc=$rc)"

  # Sub-case: path exists as dir but is not a git repo -> exit 1.
  mkdir -p "$D/not-a-repo"
  cat > "$D/.loop-spec/workspace.json" <<'JSON'
{
  "repos": [
    {"name": "not-a-repo", "path": "not-a-repo"}
  ]
}
JSON
  rc=0
  bash "$SCRIPT" detect "$D" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 1 ]] && pass "pin-invalid: non-git dir -> exit 1" || fail "pin-invalid: non-git dir -> exit 1 (got rc=$rc)"

  rm -rf "$D"
  trap - EXIT
}

# ============================================================
# Case: none -- directory that is neither a repo nor parent of repos
# ============================================================
{
  D="$(mktemp -d)"
  trap "rm -rf '$D'" EXIT

  # Plain dir with some files but no .git and no child git repos.
  mkdir -p "$D/notgit"
  echo "data" > "$D/notgit/file.txt"

  result="$(bash "$SCRIPT" detect "$D")"
  mode="$(printf '%s' "$result" | jq -r '.mode')"

  [[ "$mode" == "none" ]] && pass "none: mode is 'none'" || fail "none: mode is 'none' (got '$mode')"

  printf '%s' "$result" | jq . >/dev/null 2>&1 && pass "none: output is valid JSON" || fail "none: output is valid JSON"

  # list-repos must exit 1 in none mode.
  rc=0
  bash "$SCRIPT" list-repos "$D" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 1 ]] && pass "none: list-repos exits 1" || fail "none: list-repos exits 1 (got rc=$rc)"

  rm -rf "$D"
  trap - EXIT
}

# ============================================================
# Case: resolve -- map file paths to owning repo name
# ============================================================
{
  D="$(mktemp -d)"
  trap "rm -rf '$D'" EXIT

  make_git_repo "$D/frontend"
  make_git_repo "$D/backend"

  # Nested sub-repo to test longest prefix.
  make_git_repo "$D/backend-extra"

  # resolve-repo with workspace-relative path (inside frontend).
  name="$(bash "$SCRIPT" resolve-repo "$D" "frontend/src/app.ts")"
  [[ "$name" == "frontend" ]] && pass "resolve: relative path in frontend -> 'frontend'" || fail "resolve: relative path in frontend -> 'frontend' (got '$name')"

  # resolve-repo with workspace-relative path (inside backend).
  name="$(bash "$SCRIPT" resolve-repo "$D" "backend/cmd/main.go")"
  [[ "$name" == "backend" ]] && pass "resolve: relative path in backend -> 'backend'" || fail "resolve: relative path in backend -> 'backend' (got '$name')"

  # resolve-repo with absolute path.
  name="$(bash "$SCRIPT" resolve-repo "$D" "$D/frontend/pkg/util.py")"
  [[ "$name" == "frontend" ]] && pass "resolve: absolute path in frontend -> 'frontend'" || fail "resolve: absolute path in frontend -> 'frontend' (got '$name')"

  # resolve-repo with path outside all repos -> empty output.
  name="$(bash "$SCRIPT" resolve-repo "$D" "other/file.txt")"
  [[ -z "$name" ]] && pass "resolve: path outside repos -> empty" || fail "resolve: path outside repos -> empty (got '$name')"

  # resolve-repo with absolute path outside all repos -> empty output.
  name="$(bash "$SCRIPT" resolve-repo "$D" "/tmp/unrelated/file.txt")"
  [[ -z "$name" ]] && pass "resolve: absolute path outside repos -> empty" || fail "resolve: absolute path outside repos -> empty (got '$name')"

  # resolve-repo longest prefix: backend-extra vs backend.
  name="$(bash "$SCRIPT" resolve-repo "$D" "backend-extra/src/x.py")"
  [[ "$name" == "backend-extra" ]] && pass "resolve: longest prefix match (backend-extra wins)" || fail "resolve: longest prefix match (got '$name', expected 'backend-extra')"

  rm -rf "$D"
  trap - EXIT
}

# ============================================================
# Case: bad invocation
# ============================================================
{
  rc=0
  bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 1 ]] && pass "bad invocation: no args -> exit 1" || fail "bad invocation: no args -> exit 1 (got rc=$rc)"

  rc=0
  bash "$SCRIPT" bogus-cmd >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 1 ]] && pass "bad invocation: unknown cmd -> exit 1" || fail "bad invocation: unknown cmd -> exit 1 (got rc=$rc)"

  rc=0
  bash "$SCRIPT" resolve-repo >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 1 ]] && pass "bad invocation: resolve-repo missing args -> exit 1" || fail "bad invocation: resolve-repo missing args -> exit 1 (got rc=$rc)"
}

# ============================================================
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
