#!/usr/bin/env bash
# Tests for lib/verify-prepare.sh (VERIFY's pre-team scans, one JSON answer).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/lib/verify-prepare.sh"
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
WORK="${TMPDIR:-/tmp}"; WORK="${WORK%/}/verify-prepare-test.$$"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export LOOP_SPEC_HARNESS=codex LOOP_SPEC_TEAMS_MODE=none LOOP_SPEC_WORKFLOWS_AVAILABLE=0 LOOP_SPEC_CHECKPOINT_PR=0 LOOP_SPEC_WORKTREES=0
unset LOOP_SPEC_AUTONOMOUS LOOP_SPEC_NON_INTERACTIVE
cd "$REPO"
bash "$REPO_ROOT/lib/cycle-driver.sh" start --dir "$REPO" -- my feature >/dev/null 2>&1
bash "$REPO_ROOT/lib/cycle-driver.sh" init --dir "$REPO" --slug my-feature --title "my feature" \
  --style auto --profile standard --autonomous 0 >/dev/null 2>&1
FD="$REPO/.loop-spec/features/my-feature"
DOCS="$REPO/docs/loop-spec/features/my-feature"; mkdir -p "$DOCS"
printf '# SPEC\n' > "$DOCS/SPEC.md"; printf '# PLAN\n' > "$DOCS/PLAN.md"
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" commands '{"prepare":"","test":"true","lint":"","typecheck":""}' >/dev/null
# The cycle's state commit keeps the tree clean for the validation baseline; stand in for it.
git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -q -m "chore: state" >/dev/null 2>&1

ec=0; bash "$SCRIPT" >/dev/null 2>&1 || ec=$?
check "usage: no subcommand is a bad invocation" "2" "$ec"

# --- clean branch ------------------------------------------------------------------
printf 'def f():\n    return 1\n' > "$REPO/app.py"
git -C "$REPO" add app.py; git -C "$REPO" commit -q -m "feat: app"
ec=0; out="$(bash "$SCRIPT" run --feature-dir "$FD" 2>/dev/null)" || ec=$?
check "clean: route is continue" "continue" "$(jq -r '.route' <<<"$out")"
check "clean: exit 0" "0" "$ec"
check "clean: the placeholder scan ran" "true" "$(jq -r '.placeholder.ran' <<<"$out")"
check "clean: no remediation tasks" "0" "$(jq '.remediationTasks | length' <<<"$out")"

# --- a placeholder in an added line ---------------------------------------------------
printf 'def g():\n    # TODO implement\n    raise NotImplementedError\n' > "$REPO/stub.py"
git -C "$REPO" add stub.py; git -C "$REPO" commit -q -m "feat: stub"
ec=0; out="$(bash "$SCRIPT" run --feature-dir "$FD" 2>/dev/null)" || ec=$?
check "marker: route is remediate" "remediate" "$(jq -r '.route' <<<"$out")"
check "marker: class is marker" "marker" "$(jq -r '.class' <<<"$out")"
check "marker: exit 1" "1" "$ec"
check "marker: one task per signal lands in pendingRemediationTasks" "$(jq '.remediationTasks | length' <<<"$out")" "$(jq '.pendingRemediationTasks | length' "$FD/feature.json")"
check "marker: tasks carry the project test command" "true" "$(jq -r '.pendingRemediationTasks[0].verifyCommand' "$FD/feature.json")"
check "marker: the acceptance gate recorded a fail" "fail" "$(jq -r '[.gateHistory[] | select(.phase == "verify" and .gate == "acceptance")][-1].result' "$FD/feature.json")"
check "marker: a verify_failure event was emitted" "1" "$(grep -c '"event":"verify_failure"' "$FD/events.jsonl")"

# --- a suite regression names the failure it added ----------------------------------------
# The implementer cannot see what counts as a regression unless the task carries the line.
git -C "$REPO" rm -q stub.py; git -C "$REPO" commit -q -m "chore: drop stub"
new_failure='FAILED tests/test_new.py::test_b - AssertionError'
red_test="echo '$new_failure'; exit 1"
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" commands "$(jq -cn --arg t "$red_test" '{prepare:"",test:$t,lint:"",typecheck:""}')" >/dev/null
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" verificationBaseline "$(jq -cn \
  --arg base "$(jq -r '.baseSha' "$FD/feature.json")" --arg t "$red_test" \
  '{schemaVersion:1,baseSha:$base,prepareKey:"",commands:{
     test:{command:$t,status:"fail",exitCode:1,fingerprints:[]},
     lint:{command:"",status:"skipped",exitCode:null,fingerprints:[]},
     typecheck:{command:"",status:"skipped",exitCode:null,fingerprints:[]}}}')" >/dev/null
out="$(bash "$SCRIPT" run --feature-dir "$FD" 2>/dev/null)"
check "suite-regression: the task names the added failure line" \
  "suite-regression:this failure no longer appears: $new_failure" \
  "$(jq -r '"\(.class):\(.remediationTasks[0].acceptanceCriteria[-1])"' <<<"$out")"

# --- no baseline: the failing command and its lines are the criteria ------------------
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" verificationBaseline null >/dev/null
out="$(bash "$SCRIPT" run --feature-dir "$FD" 2>/dev/null)"
check "no baseline: the task names the failing command" "true" \
  "$(jq -r --arg c "\`$red_test\` exits 0" '.remediationTasks[0].acceptanceCriteria | index($c) != null' <<<"$out")"
check "no baseline: the task names the failing line" "true" \
  "$(jq -r --arg c "this failure no longer appears: $new_failure" '.remediationTasks[0].acceptanceCriteria | index($c) != null' <<<"$out")"

# --- a repeat call on the same clean tree replays instead of re-running -----------------
fails="$(jq '[.gateHistory[] | select(.phase == "verify" and .result == "fail")] | length' "$FD/feature.json")"
queued="$(jq '.pendingRemediationTasks | length' "$FD/feature.json")"
ec=0; again="$(bash "$SCRIPT" run --feature-dir "$FD" 2>/dev/null)" || ec=$?
check "replay: the answer is marked cached" "true" "$(jq -r '.cached' <<<"$again")"
check "replay: the route and exit are the stored ones" "remediate:1" "$(jq -r '.route' <<<"$again"):$ec"
check "replay: no second acceptance fail" "$fails" "$(jq '[.gateHistory[] | select(.phase == "verify" and .result == "fail")] | length' "$FD/feature.json")"
check "replay: no duplicate task" "$queued" "$(jq '.pendingRemediationTasks | length' "$FD/feature.json")"
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" pendingRemediationTasks '[]' >/dev/null
bash "$SCRIPT" run --feature-dir "$FD" >/dev/null 2>&1
check "replay: a consumed task is queued again" "task-verify-suite-1" "$(jq -r '.pendingRemediationTasks[0].id' "$FD/feature.json")"
git -C "$REPO" commit -q --allow-empty -m "chore: new head"
check "replay: a new HEAD re-runs" "false" "$(bash "$SCRIPT" run --feature-dir "$FD" 2>/dev/null | jq -r '.cached')"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
python3 "$REPO_ROOT/tests/lib/verify-dispatch.test.py"
