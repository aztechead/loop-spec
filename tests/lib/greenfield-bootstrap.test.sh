#!/usr/bin/env bash
# Tests for lib/greenfield-bootstrap.sh (greenfield mechanics + backfill invariant).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/lib/greenfield-bootstrap.sh"
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

WORK="${TMPDIR:-/tmp}"; WORK="${WORK%/}/greenfield-test.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

# bad invocation
ec=0; bash "$SCRIPT" >/dev/null 2>&1 || ec=$?
check "no subcommand exits 1" "1" "$ec"
ec=0; bash "$SCRIPT" bootstrap "$WORK/nonexistent" >/dev/null 2>&1 || ec=$?
check "missing dir exits 1" "1" "$ec"

# bootstrap in an empty dir
mkdir -p "$WORK/empty"
echo "keep me" > "$WORK/empty/notes.txt"
out="$(bash "$SCRIPT" bootstrap "$WORK/empty")"
check "bootstrapped flag" "true" "$(jq -r '.bootstrapped' <<<"$out")"
check "repo initialized" "yes" "$([[ -d "$WORK/empty/.git" ]] && echo yes || echo no)"
check "root commit exists" "1" "$(git -C "$WORK/empty" rev-list --count HEAD)"
check "root commit message" "chore: init repo (loop-spec greenfield)" "$(git -C "$WORK/empty" log -1 --format=%s)"
# pre-existing untracked files stay untracked (never bulk-added)
check "untracked file untouched" "?? notes.txt" "$(git -C "$WORK/empty" status --porcelain)"

# refusal: existing repo (mode single)
ec=0; bash "$SCRIPT" bootstrap "$WORK/empty" >/dev/null 2>&1 || ec=$?
check "existing repo refused with 4" "4" "$ec"
msg="$(bash "$SCRIPT" bootstrap "$WORK/empty" 2>&1 || true)"
check "refusal names the rule" "yes" "$(grep -q 'greenfield is for empty directories' <<<"$msg" && echo yes || echo no)"

# refusal: workspace mode (child repos discovered)
mkdir -p "$WORK/ws/childrepo"
git -C "$WORK/ws/childrepo" init -q
ec=0; bash "$SCRIPT" bootstrap "$WORK/ws" >/dev/null 2>&1 || ec=$?
check "workspace refused with 5" "5" "$ec"

# backfill-check
FEAT="$WORK/feat"; mkdir -p "$FEAT"
ec=0; bash "$SCRIPT" backfill-check "$WORK/nonexistent" >/dev/null 2>&1 || ec=$?
check "missing feature.json exits 1" "1" "$ec"

jq -n '{greenfield: false, commands: {test: ""}}' > "$FEAT/feature.json"
ec=0; bash "$SCRIPT" backfill-check "$FEAT" >/dev/null || ec=$?
check "non-greenfield passes" "0" "$ec"

jq -n '{greenfield: true, commands: {test: ""}}' > "$FEAT/feature.json"
ec=0; bash "$SCRIPT" backfill-check "$FEAT" >/dev/null 2>&1 || ec=$?
check "greenfield empty test fails 3" "3" "$ec"

jq -n '{greenfield: true, commands: {}}' > "$FEAT/feature.json"
ec=0; bash "$SCRIPT" backfill-check "$FEAT" >/dev/null 2>&1 || ec=$?
check "greenfield missing commands fails 3" "3" "$ec"

jq -n '{greenfield: true, commands: {test: "npm test"}}' > "$FEAT/feature.json"
ec=0; out="$(bash "$SCRIPT" backfill-check "$FEAT")" || ec=$?
check "backfilled greenfield passes" "0" "$ec"
check "backfilled message names cmd" "ok: greenfield backfilled (test: npm test)" "$out"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
