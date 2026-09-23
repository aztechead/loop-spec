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

# A PID or an ephemeral port left as a bare decimal is different every run; scrubbing
# them keeps an already-failing baseline from reporting a fresh "added fingerprint"
# regression on identical code (a live 6.6.5 run hit this twice).
PORT_OUTPUT="$WORK/port-output"
export PORT_OUTPUT
printf 'FAILED test_x - ConnectionRefusedError: [Errno 111] pid 48213 port 51877\n' > "$PORT_OUTPUT"
port_cmd='cat "$PORT_OUTPUT"; exit 1'
port_base="$(capture --test "$port_cmd" --lint '' --typecheck '')"
printf '%s\n' "$port_base" > "$BASELINE"
printf 'FAILED test_x - ConnectionRefusedError: [Errno 111] pid 91027 port 60441\n' > "$PORT_OUTPUT"
ec=0
out="$(bash "$SCRIPT" compare --baseline "$BASELINE" --root "$REPO" --base-sha "$BASE" \
  --prepare-key prep-1 --log-dir "$LOGS/current-pid-port" \
  --test "$port_cmd" --lint '' --typecheck '')" || ec=$?
check "a failure line that only differs by PID/port digits is not a regression" "0:accepted" "$ec:$(jq -r '.outcome' <<<"$out")"
check "the PID/port command itself carries no regression flag" "false" "$(jq -r '.commands.test.regression' <<<"$out")"
# The scrub is narrow: a failure that differs only in a count, an assertion value, or a
# status is a different failure and still adds a fingerprint.
printf 'FAILED test_y - AssertionError: expected 2, got 3 (Error 404)\n' > "$PORT_OUTPUT"
count_base="$(capture --test "$port_cmd" --lint '' --typecheck '')"
printf '%s\n' "$count_base" > "$BASELINE"
printf 'FAILED test_y - AssertionError: expected 2, got 4 (Error 500)\n' > "$PORT_OUTPUT"
ec=0
out="$(bash "$SCRIPT" compare --baseline "$BASELINE" --root "$REPO" --base-sha "$BASE" \
  --prepare-key prep-1 --log-dir "$LOGS/current-count" \
  --test "$port_cmd" --lint '' --typecheck '')" || ec=$?
check "a failure line that differs in a count or a status is still a regression" "20:regression" "$ec:$(jq -r '.outcome' <<<"$out")"

# A red base whose failures the feature never touched: the summary's pass count moves
# with every added test and must not read as a new failure (6.9.0 run).
PYTEST_OUTPUT="$WORK/pytest-output"
export PYTEST_OUTPUT
pytest_cmd='cat "$PYTEST_OUTPUT"; exit 1'
old_failure='FAILED tests/test_old.py::test_a - AssertionError'
pytest_compare() {
  printf '%s\n' "$old_failure" "$1" > "$PYTEST_OUTPUT"
  capture --test "$pytest_cmd" --lint '' --typecheck '' > "$BASELINE"
  printf '%s\n' "$old_failure" "$2" > "$PYTEST_OUTPUT"
  ec=0
  out="$(bash "$SCRIPT" compare --baseline "$BASELINE" --root "$REPO" --base-sha "$BASE" \
    --prepare-key prep-1 --log-dir "$LOGS/pytest-$3" \
    --test "$pytest_cmd" --lint '' --typecheck '')" || ec=$?
}
pytest_compare '===== 87 failed, 2571 passed, 29 skipped, 1 warning in 75.20s (0:01:15) =====' \
  '===== 87 failed, 2611 passed, 29 skipped, 1 warning in 76.10s (0:01:16) =====' bordered
check "a pytest summary whose pass count grew is not a regression" "0:accepted" "$ec:$(jq -r '.outcome' <<<"$out")"
pytest_compare '87 failed, 2571 passed in 1.0s' '87 failed, 2611 passed in 1.1s' quiet
check "a pytest -q summary whose pass count grew is not a regression" "0:accepted" "$ec:$(jq -r '.outcome' <<<"$out")"
pytest_compare '' 'tests/test_api.py::test_status[error] PASSED [ 50%]' verbose
check "a -v PASSED line naming error is not a failure" "0:accepted" "$ec:$(jq -r '.outcome' <<<"$out")"
pytest_compare '' 'FAILED tests/test_new.py::test_b - AssertionError' new-failure
check "a new FAILED line is a regression that names the line" \
  '20:["FAILED tests/test_new.py::test_b - AssertionError"]' "$ec:$(jq -c '.commands.test.addedLines' <<<"$out")"
printf '%s\n' '===== 3 failed, 10 passed in 1.00s =====' > "$PYTEST_OUTPUT"
check "a log that is only a summary still yields a fingerprint that is not the summary" \
  '["<no failure output>"]' "$(capture --test "$pytest_cmd" --lint '' --typecheck '' | jq -c '[.commands.test.fingerprintLines[]]')"

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

# The cycle's own docs are not candidate dirt; any other uncommitted file still is.
rm -f "$FAIL_FLAG"
printf '%s\n' "$pass_base" > "$BASELINE"
mkdir -p "$REPO/docs/loop-spec/features/x"
printf '| GE-001 | it | PASS |\n' > "$REPO/docs/loop-spec/features/x/VERIFICATION.md"
mkdir -p "$REPO/.loop-spec/features/x"; printf '{"slug":"x"}\n' > "$REPO/.loop-spec/features/x/feature.json"
ec=0
out="$(bash "$SCRIPT" compare --baseline "$BASELINE" --root "$REPO" --base-sha "$BASE" \
  --prepare-key prep-1 --log-dir "$LOGS/docs-dirty" --test "$pass_fail_cmd" --lint '' --typecheck '')" || ec=$?
check "an uncommitted docs/loop-spec artifact or .loop-spec state file is not candidate dirt" "0:accepted" "$ec:$(jq -r '.outcome' <<<"$out")"
printf 'stray\n' > "$REPO/stray.txt"
ec=0
bash "$SCRIPT" compare --baseline "$BASELINE" --root "$REPO" --base-sha "$BASE" \
  --prepare-key prep-1 --log-dir "$LOGS/code-dirty" --test "$pass_fail_cmd" --lint '' --typecheck '' >/dev/null 2>&1 || ec=$?
check "an uncommitted file outside docs/loop-spec is still candidate dirt" "21" "$ec"
rm -rf "$REPO/stray.txt" "$REPO/docs" "$REPO/.loop-spec"

# The plugin's own state under .loop-spec never counts as dirt for the baseline.
git -C "$REPO" checkout -q "$BASE" 2>/dev/null
mkdir -p "$REPO/.loop-spec/features/x"; printf '{"phase":"verify"}\n' > "$REPO/.loop-spec/features/x/feature.json"
ec=0; capture --test 'true' --lint '' --typecheck '' >/dev/null 2>&1 || ec=$?
check "capture ignores .loop-spec state as dirt" "0" "$ec"
rm -rf "$REPO/.loop-spec"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
