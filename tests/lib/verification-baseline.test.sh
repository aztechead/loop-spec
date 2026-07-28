#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/lib/verification-baseline.sh"
WORK="${TMPDIR:-/tmp}/loop-spec-baseline-test.$$"
REPO="$WORK/repo"
LOGS="$WORK/logs"
PASS=0
FAIL=0
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test
printf 'seed\n' > "$REPO/seed.txt"
git -C "$REPO" add seed.txt
git -C "$REPO" commit -qm seed
BASE="$(git -C "$REPO" rev-parse HEAD)"

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"
    FAIL=$((FAIL + 1))
  fi
}

capture() {
  bash "$SCRIPT" capture --root "$REPO" --base-sha "$BASE" --prepare-key prep-1 \
    --log-dir "$LOGS" "$@"
}

baseline="$(capture --test 'echo test-ok' --lint 'echo ERROR old; exit 1' --typecheck '')"
check "capture binds exact base SHA" "$BASE" "$(jq -r '.baseSha' <<<"$baseline")"
check "capture binds preparation key" "prep-1" "$(jq -r '.prepareKey' <<<"$baseline")"
check "capture records pass/fail/skipped" "pass,fail,skipped" "$(jq -r '[.commands.test.status,.commands.lint.status,.commands.typecheck.status] | join(",")' <<<"$baseline")"
check "failure gets fingerprints" "1" "$(jq -r '.commands.lint.fingerprints | (length > 0)' <<<"$baseline" | sed 's/true/1/;s/false/0/')"
check "logs are local files" "1" "$([[ -s "$LOGS/test.log" && -s "$LOGS/lint.log" ]] && echo 1 || echo 0)"

BASELINE="$WORK/baseline.json"
printf '%s\n' "$baseline" > "$BASELINE"

ec=0
out="$(bash "$SCRIPT" compare --baseline "$BASELINE" --root "$REPO" --base-sha "$BASE" \
  --prepare-key prep-1 --log-dir "$LOGS/current-unchanged" \
  --test 'echo test-ok' --lint 'echo ERROR old; exit 1' --typecheck '')" || ec=$?
check "unchanged known failure is accepted" "0:accepted" "$ec:$(jq -r '.outcome' <<<"$out")"

FAKE_BIN="$WORK/fake-bin"
mkdir -p "$FAKE_BIN"
REAL_GIT="$(command -v git)"
export REAL_GIT
printf '%s\n' '#!/usr/bin/env bash' \
  'for arg in "$@"; do [[ "$arg" == "status" ]] && exit 73; done' \
  'exec "$REAL_GIT" "$@"' > "$FAKE_BIN/git"
chmod +x "$FAKE_BIN/git"
ec=0
PATH="$FAKE_BIN:$PATH" capture --test true --lint '' --typecheck '' >/dev/null 2>&1 || ec=$?
check "capture rejects unreadable git status" "21" "$ec"
ec=0
PATH="$FAKE_BIN:$PATH" bash "$SCRIPT" compare --baseline "$BASELINE" --root "$REPO" --base-sha "$BASE" \
  --prepare-key prep-1 --log-dir "$LOGS/status-failure" \
  --test 'echo test-ok' --lint 'echo ERROR old; exit 1' --typecheck '' >/dev/null 2>&1 || ec=$?
check "compare rejects unreadable git status" "21" "$ec"

FAIL_OUTPUT="$WORK/failure-output"
export FAIL_OUTPUT
printf 'ERROR old\nERROR second\n' > "$FAIL_OUTPUT"
failure_cmd='cat "$FAIL_OUTPUT"; exit 1'
subset_base="$(capture --test '' --lint "$failure_cmd" --typecheck '')"
printf '%s\n' "$subset_base" > "$BASELINE"
printf 'ERROR old\n' > "$FAIL_OUTPUT"
ec=0
out="$(bash "$SCRIPT" compare --baseline "$BASELINE" --root "$REPO" --base-sha "$BASE" \
  --prepare-key prep-1 --log-dir "$LOGS/current-subset" \
  --test '' --lint "$failure_cmd" --typecheck '')" || ec=$?
check "subset of known failures is accepted" "0:accepted" "$ec:$(jq -r '.outcome' <<<"$out")"

printf 'ERROR old\nERROR new\n' > "$FAIL_OUTPUT"
ec=0
out="$(bash "$SCRIPT" compare --baseline "$BASELINE" --root "$REPO" --base-sha "$BASE" \
  --prepare-key prep-1 --log-dir "$LOGS/current-added" \
  --test '' --lint "$failure_cmd" --typecheck '')" || ec=$?
check "added failure fingerprint is a regression" "20:regression" "$ec:$(jq -r '.outcome' <<<"$out")"

RECOVER_FLAG="$WORK/recover-flag"
export RECOVER_FLAG
recover_cmd='if [[ -f "$RECOVER_FLAG" ]]; then exit 0; fi; echo ERROR old; exit 1'
rm -f "$RECOVER_FLAG"
recover_base="$(capture --test '' --lint "$recover_cmd" --typecheck '')"
printf '%s\n' "$recover_base" > "$BASELINE"
touch "$RECOVER_FLAG"
ec=0
out="$(bash "$SCRIPT" compare --baseline "$BASELINE" --root "$REPO" --base-sha "$BASE" \
  --prepare-key prep-1 --log-dir "$LOGS/current-recovered" \
  --test '' --lint "$recover_cmd" --typecheck '')" || ec=$?
check "known failure becoming pass is accepted" "0:accepted" "$ec:$(jq -r '.outcome' <<<"$out")"

FAIL_FLAG="$WORK/fail-flag"
export FAIL_FLAG
pass_fail_cmd='if [[ -f "$FAIL_FLAG" ]]; then echo FAIL new; exit 1; fi'
pass_base="$(capture --test "$pass_fail_cmd" --lint '' --typecheck '')"
printf '%s\n' "$pass_base" > "$BASELINE"
touch "$FAIL_FLAG"
ec=0
out="$(bash "$SCRIPT" compare --baseline "$BASELINE" --root "$REPO" --base-sha "$BASE" \
  --prepare-key prep-1 --log-dir "$LOGS/current-pass-fail" \
  --test "$pass_fail_cmd" --lint '' --typecheck '')" || ec=$?
check "pass to fail is a regression" "20:regression" "$ec:$(jq -r '.outcome' <<<"$out")"

ec=0
out="$(bash "$SCRIPT" compare --baseline "$WORK/missing.json" --root "$REPO" --base-sha "$BASE" \
  --prepare-key prep-1 --log-dir "$LOGS/current-missing-pass" \
  --test 'true' --lint '' --typecheck '')" || ec=$?
check "missing old baseline is strict but passing is accepted" "0:true" "$ec:$(jq -r '.baselineMissing' <<<"$out")"
ec=0
out="$(bash "$SCRIPT" compare --baseline "$WORK/missing.json" --root "$REPO" --base-sha "$BASE" \
  --prepare-key prep-1 --log-dir "$LOGS/current-missing-fail" \
  --test 'echo FAIL existing; exit 1' --lint '' --typecheck '')" || ec=$?
check "missing old baseline never learns current failures" "20:regression" "$ec:$(jq -r '.outcome' <<<"$out")"

printf '%s\n' "$pass_base" > "$BASELINE"
ec=0
bash "$SCRIPT" compare --baseline "$BASELINE" --root "$REPO" --base-sha "$BASE" \
  --prepare-key wrong --log-dir "$LOGS/wrong-key" --test "$pass_fail_cmd" --lint '' --typecheck '' >/dev/null 2>&1 || ec=$?
check "prepare-key mismatch is infrastructure error" "21" "$ec"
ec=0
bash "$SCRIPT" compare --baseline "$BASELINE" --root "$REPO" --base-sha "$BASE" \
  --prepare-key prep-1 --log-dir "$LOGS/wrong-command" --test 'echo changed' --lint '' --typecheck '' >/dev/null 2>&1 || ec=$?
check "command mismatch is infrastructure error" "21" "$ec"

ec=0
infra="$(capture --test 'command-that-does-not-exist' --lint '' --typecheck '')" || ec=$?
check "missing executable is captured as infrastructure" "infra_error" "$(jq -r '.commands.test.status' <<<"$infra")"
check "capture exits distinctly for infrastructure" "21" "$ec"

missing_cmd_base="$(capture --test 'command-that-does-not-exist' --lint '' --typecheck '')"
printf '%s\n' "$missing_cmd_base" > "$BASELINE"
ec=0
out="$(bash "$SCRIPT" compare --baseline "$BASELINE" --root "$REPO" --base-sha "$BASE" \
  --prepare-key prep-1 --log-dir "$LOGS/current-infra" \
  --test 'command-that-does-not-exist' --lint '' --typecheck '')" || ec=$?
check "comparison reports infrastructure distinctly" "21:infra_error" "$ec:$(jq -r '.outcome' <<<"$out")"

ec=0
capture --test 'printf generated > generated.txt' --lint '' --typecheck '' >/dev/null 2>&1 || ec=$?
check "capture rejects command-created worktree changes" "21" "$ec"
check "capture never cleans command-created files" "1" "$([[ -f "$REPO/generated.txt" ]] && echo 1 || echo 0)"
rm "$REPO/generated.txt"

ec=0
capture --test 'printf moved >> seed.txt; git add seed.txt; git commit -qm baseline-moved' \
  --lint '' --typecheck '' >/dev/null 2>&1 || ec=$?
check "capture rejects command that moves HEAD with a clean tree" "21" "$ec"
check "capture observes the moved HEAD without undoing it" "1" "$([[ "$(git -C "$REPO" rev-parse HEAD)" != "$BASE" && -z "$(git -C "$REPO" status --porcelain)" ]] && echo 1 || echo 0)"
git -C "$REPO" checkout -q --detach "$BASE"

MOVE_HEAD_FLAG="$WORK/move-head-flag"
export MOVE_HEAD_FLAG
move_head_cmd='if [[ -f "$MOVE_HEAD_FLAG" ]]; then printf moved >> seed.txt; git add seed.txt; git commit -qm compare-moved; fi'
rm -f "$MOVE_HEAD_FLAG"
move_head_base="$(capture --test "$move_head_cmd" --lint '' --typecheck '')"
printf '%s\n' "$move_head_base" > "$BASELINE"
touch "$MOVE_HEAD_FLAG"
ec=0
bash "$SCRIPT" compare --baseline "$BASELINE" --root "$REPO" --base-sha "$BASE" \
  --prepare-key prep-1 --log-dir "$LOGS/current-head-moved" \
  --test "$move_head_cmd" --lint '' --typecheck '' >/dev/null 2>&1 || ec=$?
check "compare rejects command that moves candidate HEAD" "21" "$ec"
check "compare leaves the moved candidate untouched" "1" "$([[ "$(git -C "$REPO" rev-parse HEAD)" != "$BASE" && -z "$(git -C "$REPO" status --porcelain)" ]] && echo 1 || echo 0)"
git -C "$REPO" checkout -q --detach "$BASE"

COMPARE_DIRTY_FLAG="$WORK/compare-dirty-flag"
export COMPARE_DIRTY_FLAG
compare_dirty_cmd='if [[ -f "$COMPARE_DIRTY_FLAG" ]]; then printf dirty > compare-dirty.txt; fi'
rm -f "$COMPARE_DIRTY_FLAG"
compare_dirty_base="$(capture --test "$compare_dirty_cmd" --lint '' --typecheck '')"
printf '%s\n' "$compare_dirty_base" > "$BASELINE"
touch "$COMPARE_DIRTY_FLAG"
ec=0
bash "$SCRIPT" compare --baseline "$BASELINE" --root "$REPO" --base-sha "$BASE" \
  --prepare-key prep-1 --log-dir "$LOGS/current-dirty" \
  --test "$compare_dirty_cmd" --lint '' --typecheck '' >/dev/null 2>&1 || ec=$?
check "compare rejects command-created worktree changes" "21" "$ec"
check "compare never cleans command-created files" "1" "$([[ -f "$REPO/compare-dirty.txt" ]] && echo 1 || echo 0)"
rm "$REPO/compare-dirty.txt"

printf 'dirty\n' > "$REPO/dirty.txt"
ec=0
capture --test true --lint '' --typecheck '' >/dev/null 2>&1 || ec=$?
check "capture refuses a modified HEAD worktree" "21" "$ec"
rm "$REPO/dirty.txt"

printf 'next\n' >> "$REPO/seed.txt"
git -C "$REPO" add seed.txt
git -C "$REPO" commit -qm next
ec=0
capture --test true --lint '' --typecheck '' >/dev/null 2>&1 || ec=$?
check "capture refuses HEAD different from base SHA" "21" "$ec"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
