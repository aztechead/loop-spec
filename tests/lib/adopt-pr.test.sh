#!/usr/bin/env bash
# Tests for lib/adopt-pr.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/lib/adopt-pr.sh"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; ((FAIL++)) || true
  fi
}

WORK="${TMPDIR:-/tmp}/loop-spec-adopt-pr.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

git init -q "$WORK/repo"
git -C "$WORK/repo" config user.email t@t
git -C "$WORK/repo" config user.name t
echo x > "$WORK/repo/a"
git -C "$WORK/repo" add a
git -C "$WORK/repo" commit -q -m init
git -C "$WORK/repo" checkout -q -b feat/sync
echo y > "$WORK/repo/b"
git -C "$WORK/repo" add b
git -C "$WORK/repo" commit -q -m sync
git init --bare -q "$WORK/bare"
git -C "$WORK/repo" remote add origin "$WORK/bare"
git -C "$WORK/repo" push -q origin feat/sync >/dev/null 2>&1 || \
  git -C "$WORK/repo" push -q origin HEAD:feat/sync

PLAIN="$WORK/not-a-repo"
mkdir -p "$PLAIN"
NO_ORIGIN="$WORK/no-origin"
git init -q "$NO_ORIGIN"
git -C "$NO_ORIGIN" config user.email t@t
git -C "$NO_ORIGIN" config user.name t
git -C "$NO_ORIGIN" commit --allow-empty -qm init

SHIMS="$WORK/shims"
mkdir -p "$SHIMS"
cat > "$SHIMS/gh" << 'GHSHIM'
#!/usr/bin/env bash
[[ -z "${SHIM_GH_CALL_LOG:-}" ]] || printf '%s\n' "$*" >> "$SHIM_GH_CALL_LOG"
if [[ "${1:-}" != "pr" || "${2:-}" != "view" ]]; then
  echo "unexpected: $*" >&2
  exit 1
fi
shift 2
ref=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) shift 2 || true ;;
    --*) shift ;;
    *) ref="$1"; shift ;;
  esac
done
if [[ "${SHIM_GH_FAIL:-0}" == "1" ]]; then
  echo "boom" >&2
  exit 1
fi
if [[ "${SHIM_GH_MALFORMED:-0}" == "1" ]]; then
  echo 'not-json'
  exit 0
fi
if [[ -n "${SHIM_GH_EXPECT_REF:-}" && "$ref" != "$SHIM_GH_EXPECT_REF" ]]; then
  echo "expected ref ${SHIM_GH_EXPECT_REF}, got '$ref'" >&2
  exit 1
fi
jq -nc \
  --argjson number "${SHIM_GH_NUMBER:-114}" \
  --arg url "${SHIM_GH_URL:-https://github.com/test/repo/pull/114}" \
  --arg head "${SHIM_GH_HEAD:-feat/sync}" \
  --arg base "${SHIM_GH_BASE:-main}" \
  --arg state "${SHIM_GH_STATE:-OPEN}" \
  --argjson cross "${SHIM_GH_CROSS:-false}" \
  '{number:$number,url:$url,headRefName:$head,baseRefName:$base,
    state:$state,isCrossRepository:$cross}'
GHSHIM
chmod +x "$SHIMS/gh"

resolve() {
  local request="$1"
  PATH="$SHIMS:$PATH" bash "$LIB" resolve --repo "$WORK/repo" --request "$request"
}

rc=0
bash "$LIB" >/dev/null 2>&1 || rc=$?
check "no subcommand is a bad invocation" "2" "$rc"
rc=0
bash "$LIB" resolve >/dev/null 2>&1 || rc=$?
check "resolve without args is a bad invocation" "2" "$rc"

got="$(bash "$LIB" resolve --repo "$PLAIN" --request "PR #114")"
check "plain directory is not a git repository" "false" "$(jq -r '.adopt' <<<"$got")"
check "plain directory names the reason" "not a git repository" "$(jq -r '.reason' <<<"$got")"

got="$(bash "$LIB" resolve --repo "$WORK/repo" --request "fix the tests")"
check "unnamed request does not adopt" "false" "$(jq -r '.adopt' <<<"$got")"
check "unnamed request names the reason" "request does not name an existing PR" \
  "$(jq -r '.reason' <<<"$got")"

BIN="$WORK/bin"
mkdir -p "$BIN"
ln -s "$(command -v git)" "$BIN/git"
ln -s "$(python3 -c 'import sys; print(sys.executable)')" "$BIN/python3"
ln -s "$(command -v jq)" "$BIN/jq"
ln -s "$(command -v dirname)" "$BIN/dirname"
ln -s "$(command -v bash)" "$BIN/bash"
got="$(PATH="$BIN" "$(command -v bash)" "$LIB" resolve --repo "$WORK/repo" --request "PR #114")"
check "missing gh does not adopt" "false" "$(jq -r '.adopt' <<<"$got")"
check "missing gh names the reason" "gh is not on PATH" "$(jq -r '.reason' <<<"$got")"

got="$(PATH="$SHIMS:$PATH" bash "$LIB" resolve --repo "$NO_ORIGIN" --request "PR #114")"
check "missing origin does not adopt" "false" "$(jq -r '.adopt' <<<"$got")"
check "missing origin names the reason" "origin remote is required" \
  "$(jq -r '.reason' <<<"$got")"

export SHIM_GH_CALL_LOG="$WORK/gh.log"
rm -f "$SHIM_GH_CALL_LOG"
got="$(resolve "PR #114")"
check "PR #N adopts an open same-repo PR" "true" "$(jq -r '.adopt' <<<"$got")"
check "PR #N records the number" "114" "$(jq -r '.number' <<<"$got")"
check "PR #N records the head branch" "feat/sync" "$(jq -r '.branch' <<<"$got")"
check "PR #N records the base branch" "main" "$(jq -r '.baseBranch' <<<"$got")"
check "PR #N records the url" "https://github.com/test/repo/pull/114" \
  "$(jq -r '.url' <<<"$got")"
grep -q 'pr view' "$SHIM_GH_CALL_LOG" && r=ok || r=bad
check "PR #N invoked gh pr view" "ok" "$r"
if grep -q -- '--head' "$SHIM_GH_CALL_LOG"; then r=bad; else r=ok; fi
check "gh pr view is not passed --head" "ok" "$r"

got="$(SHIM_GH_EXPECT_REF=42 SHIM_GH_NUMBER=42 resolve "https://github.com/org/repo/pull/42 extra")"
check "a GitHub pull URL extracts the number" "42" "$(jq -r '.number' <<<"$got")"
check "a GitHub pull URL adopts" "true" "$(jq -r '.adopt' <<<"$got")"

got="$(SHIM_GH_EXPECT_REF=7 SHIM_GH_NUMBER=7 resolve "please review pull request 7")"
check "pull request N adopts" "true" "$(jq -r '.adopt' <<<"$got")"

export SHIM_GH_EXPECT_REF=feat/sync
got="$(resolve "re-review this PR")"
check "deictic this PR adopts HEAD's PR" "true" "$(jq -r '.adopt' <<<"$got")"
got="$(resolve "sync the open PR")"
check "deictic the open PR adopts HEAD's PR" "true" "$(jq -r '.adopt' <<<"$got")"
unset SHIM_GH_EXPECT_REF

got="$(SHIM_GH_STATE=CLOSED resolve "PR #114")"
check "a closed PR is not adopted" "false" "$(jq -r '.adopt' <<<"$got")"
check "a closed PR names the state" "PR state is CLOSED, not OPEN" \
  "$(jq -r '.reason' <<<"$got")"

got="$(SHIM_GH_CROSS=true resolve "PR #114")"
check "a fork head is not adopted" "false" "$(jq -r '.adopt' <<<"$got")"
check "a fork head names the reason" \
  "PR head is a fork; refusing to adopt a cross-repository branch" \
  "$(jq -r '.reason' <<<"$got")"

got="$(SHIM_GH_FAIL=1 resolve "PR #114")"
check "gh failure does not adopt" "false" "$(jq -r '.adopt' <<<"$got")"

got="$(SHIM_GH_MALFORMED=1 resolve "PR #114")"
check "malformed gh JSON does not adopt" "false" "$(jq -r '.adopt' <<<"$got")"

# Invocation cwd is not the repo; LOOP_SPEC_BOUNDED_RUN_CWD must still reach it.
got="$(cd "$PLAIN" && PATH="$SHIMS:$PATH" bash "$LIB" resolve \
  --repo "$WORK/repo" --request "PR #114")"
check "resolve from another cwd still adopts" "true" "$(jq -r '.adopt' <<<"$got")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
