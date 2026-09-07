#!/usr/bin/env bash
# Tests for lib/execute-prepare.sh (EXECUTE's pre-dispatch bookkeeping, one JSON answer).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/lib/execute-prepare.sh"
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
WORK="${TMPDIR:-/tmp}"; WORK="${WORK%/}/execute-prepare-test.$$"
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
mkdir -p "$REPO/docs/loop-spec/features/my-feature"
printf '# PLAN\n' > "$REPO/docs/loop-spec/features/my-feature/PLAN.md"
cat > "$FD/tasks.json" <<'JSON'
[
 {"id":"task-001","subject":"first","files":["a.py"],"blockedBy":[],"verifyCommand":"true","acceptanceCriteria":["a"]},
 {"id":"task-002","subject":"second","files":["a.py","b.py"],"blockedBy":[],"verifyCommand":"true","acceptanceCriteria":["b"]},
 {"id":"task-003","subject":"third","files":["c.py"],"blockedBy":[],"verifyCommand":"true","acceptanceCriteria":["c"]}
]
JSON
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" artifacts.tasks "\"$FD/tasks.json\"" >/dev/null
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" commands '{"prepare":"","test":"true","lint":"","typecheck":""}' >/dev/null

# --- usage -------------------------------------------------------------------------
ec=0; bash "$SCRIPT" >/dev/null 2>&1 || ec=$?
check "usage: no subcommand is a bad invocation" "2" "$ec"

# --- a ready feature ---------------------------------------------------------------
ec=0; out="$(bash "$SCRIPT" run --feature-dir "$FD" 2>/dev/null)" || ec=$?
check "run: ready feature exits 0" "0" "$ec"
check "run: branch check passes" "true" "$(jq -r '.branch.ok' <<<"$out")"
check "run: three tasks to dispatch" "3" "$(jq '.tasks | length' <<<"$out")"
check "run: overlapping files add a synthetic edge, lower id first" "task-001" "$(jq -r '.tasks[] | select(.id == "task-002") | .syntheticBlockedBy[0]' <<<"$out")"
check "run: width counts the serialized pair once" "2" "$(jq -r '.width' <<<"$out")"
check "run: the rung is selected" "1" "$(jq -r '.rung.rung | length > 0' <<<"$out" | grep -c true)"
check "run: retries cap is read" "6" "$(jq -r '.maxRetries' <<<"$out")"
check "run: conflict rows are rulings, not stops" "false" "$(jq -r '.stop' <<<"$out")"
check "run: rulings are recorded as decisions" "1" "$(grep -c '"kind":"ruling"' "$FD/decisions.jsonl" 2>/dev/null || echo 0)"
check "run: dispatch files are written" "2" "$(ls "$FD/dispatch" | grep -cE 'conflict-table.json|tasks-collapsed.json')"

# --- remediation intake ------------------------------------------------------------
bash "$REPO_ROOT/lib/feature-write.sh" append "$FD" pendingRemediationTasks '{"id":"task-001+remediate-1","subject":"Fix: a"}' >/dev/null
out="$(bash "$SCRIPT" run --feature-dir "$FD" 2>/dev/null)"
check "remediation: the task is registered in the sidecar" "1" "$(jq '[.[] | select(.id == "task-001+remediate-1")] | length' "$FD/tasks.json")"
check "remediation: it takes the project test command" "true" "$(jq -r '.[] | select(.id == "task-001+remediate-1") | .verifyCommand' "$FD/tasks.json")"
check "remediation: the pending array is cleared" "0" "$(jq '.pendingRemediationTasks | length' "$FD/feature.json")"
check "remediation: the count is reported" "1" "$(jq -r '.remediationRegistered' <<<"$out")"

# --- progress ----------------------------------------------------------------------
bash "$REPO_ROOT/lib/task-progress.sh" mark-done "$FD/tasks.json" task-001 >/dev/null
out="$(bash "$SCRIPT" run --feature-dir "$FD" 2>/dev/null)"
check "progress: done ids are reported" "task-001" "$(jq -r '.done[0]' <<<"$out")"
check "progress: a done task leaves the dispatch list" "0" "$(jq '[.tasks[] | select(.id == "task-001")] | length' <<<"$out")"
check "progress: a done blocker is pruned from blockedBy" "0" "$(jq '.tasks[] | select(.id == "task-002") | .blockedBy | length' <<<"$out")"

# --- branch mismatch ---------------------------------------------------------------
git -C "$REPO" checkout -q -b elsewhere 2>/dev/null
ec=0; out="$(bash "$SCRIPT" run --feature-dir "$FD" 2>/dev/null)" || ec=$?
check "branch: a wrong checkout is not ready" "1" "$ec"
check "branch: the mismatch is named" "elsewhere" "$(jq -r '.branch.actual' <<<"$out")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
