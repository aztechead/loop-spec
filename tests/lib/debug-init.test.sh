#!/usr/bin/env bash
# Tests for lib/debug-init.sh (debug skill Step 0 mechanics).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/lib/debug-init.sh"
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

field() { jq -r ".$2" <<<"$1"; }

WORK="${TMPDIR:-/tmp}"; WORK="${WORK%/}/debug-init-test.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/repo"
REPO="$WORK/repo"

git -C "$REPO" init -q -b main
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "init"

# bad invocation
ec=0; bash "$SCRIPT" init --dir "$REPO" -- >/dev/null 2>&1 || ec=$?
check "empty symptom exits 1" "1" "$ec"
ec=0; bash "$SCRIPT" init --dir "$WORK" -- "some bug" >/dev/null 2>&1 || ec=$?
check "non-repo exits 1" "1" "$ec"
mkdir -p "$WORK/norepo-commits"; git -C "$WORK/norepo-commits" init -q -b main
ec=0; msg="$(bash "$SCRIPT" init --dir "$WORK/norepo-commits" -- "some bug" 2>&1)" || ec=$?
check "zero-commit repo exits 1" "1" "$ec"
check "zero-commit message friendly" "yes" "$(grep -q 'no commits' <<<"$msg" && echo yes || echo no)"

# happy path from the default branch
out="$(cd "$REPO" && bash "$SCRIPT" init -- "login sometimes hangs after session timeout on retry")"
check "slug from first 6 words" "login-sometimes-hangs-after-session-timeout" "$(field "$out" slug)"
check "bug dir created" "yes" "$([[ -d "$REPO/docs/loop-spec/debug/login-sometimes-hangs-after-session-timeout" ]] && echo yes || echo no)"
check "fix branch created" "fix/login-sometimes-hangs-after-session-timeout" "$(field "$out" branch)"
check "branch action created" "created" "$(field "$out" branch_action)"
check "now on fix branch" "fix/login-sometimes-hangs-after-session-timeout" "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
check "sha captured" "$(git -C "$REPO" rev-parse --short HEAD)" "$(field "$out" sha_before)"
check "clean tree" "false" "$(field "$out" dirty)"
check "no test cmd in bare repo" "" "$(field "$out" test_cmd)"
check "not autonomous" "false" "$(field "$out" autonomous)"

# tokens stripped from the slug; autonomous surfaced
git -C "$REPO" checkout -q main
out="$(cd "$REPO" && bash "$SCRIPT" init -- "autonomous style:step csv export drops header row")"
check "tokens out of slug" "csv-export-drops-header-row" "$(field "$out" slug)"
check "autonomous surfaced" "true" "$(field "$out" autonomous)"
check "style surfaced" "step" "$(field "$out" style)"

# on an existing work branch: kept, not switched; dirty reported not decided
git -C "$REPO" checkout -q -b feature/other
echo x > "$REPO/junk.txt"
out="$(cd "$REPO" && bash "$SCRIPT" init -- "flaky timeout in payment tests")"
check "work branch kept" "feature/other" "$(field "$out" branch)"
check "branch action kept" "kept" "$(field "$out" branch_action)"
check "dirty reported" "true" "$(field "$out" dirty)"
rm "$REPO/junk.txt"

# existing fix branch: switch, not create
git -C "$REPO" checkout -q main
out="$(cd "$REPO" && bash "$SCRIPT" init -- "csv export drops header row")"
check "existing fix branch switched" "switched" "$(field "$out" branch_action)"

# test command: env pin wins, then detection
git -C "$REPO" checkout -q main
out="$(cd "$REPO" && LOOP_SPEC_CMD_TEST="make check" bash "$SCRIPT" init -- "another bug entirely here")"
check "env test cmd wins" "make check" "$(field "$out" test_cmd)"
echo '{}' > "$REPO/package.json"
git -C "$REPO" checkout -q main
out="$(cd "$REPO" && bash "$SCRIPT" init -- "yet another different bug report")"
check "detected test cmd" "npm test" "$(field "$out" test_cmd)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
