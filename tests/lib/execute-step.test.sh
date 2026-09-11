#!/usr/bin/env bash
# Tests for lib/execute-step.sh (one EXECUTE task step per call).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STEP="$REPO_ROOT/lib/execute-step.sh"
PREP="$REPO_ROOT/lib/execute-prepare.sh"
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
WORK="${TMPDIR:-/tmp}"; WORK="${WORK%/}/execute-step-test.$$"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export LOOP_SPEC_TEAMS_MODE=none LOOP_SPEC_WORKFLOWS_AVAILABLE=0 LOOP_SPEC_CHECKPOINT_PR=0
unset LOOP_SPEC_AUTONOMOUS LOOP_SPEC_NON_INTERACTIVE

# new_feature NAME: a repo with an initialized feature, tasks.json, and PLAN.md; prints
# the feature dir. Callers set LOOP_SPEC_HARNESS/LOOP_SPEC_WORKTREES before calling.
new_feature() {
  local repo="$WORK/$1"; mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  printf 'print(1)\n' > "$repo/a.py"; git -C "$repo" add a.py; git -C "$repo" commit -q -m base
  (cd "$repo" && bash "$REPO_ROOT/lib/cycle-driver.sh" start --dir "$repo" -- my feature >/dev/null 2>&1
   bash "$REPO_ROOT/lib/cycle-driver.sh" init --dir "$repo" --slug my-feature --title "my feature" --style auto --profile standard --autonomous 1 >/dev/null 2>&1)
  local fd
  fd="$(find "$repo" -path '*/.loop-spec/features/my-feature' -type d | head -1)"
  local root; root="$(git -C "$fd" rev-parse --show-toplevel)"
  mkdir -p "$root/docs/loop-spec/features/my-feature"; printf '# PLAN\n' > "$root/docs/loop-spec/features/my-feature/PLAN.md"
  cat > "$fd/tasks.json" <<'JSON'
[{"id":"task-001","subject":"change a","files":["a.py"],"blockedBy":[],"verifyCommand":"python3 a.py","acceptanceCriteria":["a prints 2"]},
 {"id":"task-002","subject":"add b","files":["b.py"],"blockedBy":["task-001"],"verifyCommand":"true","acceptanceCriteria":["b exists"]}]
JSON
  bash "$REPO_ROOT/lib/feature-write.sh" set "$fd" artifacts.tasks "\"$fd/tasks.json\"" >/dev/null
  bash "$REPO_ROOT/lib/feature-write.sh" set "$fd" commands '{"prepare":"","test":"true","lint":"","typecheck":""}' >/dev/null
  git -C "$root" add -A >/dev/null 2>&1; git -C "$root" commit -q -m "chore: state" >/dev/null 2>&1
  printf '%s\n' "$fd"
}

# --- usage -------------------------------------------------------------------------
ec=0; bash "$STEP" >/dev/null 2>&1 || ec=$?
check "usage: no subcommand is a bad invocation" "2" "$ec"

# --- in-place mode (no worktrees) ----------------------------------------------------
export LOOP_SPEC_HARNESS=codex LOOP_SPEC_WORKTREES=0
FD="$(new_feature inplace)"; ROOT="$(git -C "$FD" rev-parse --show-toplevel)"
ec=0; bash "$STEP" dispatch --feature-dir "$FD" --task task-001 >/dev/null 2>&1 || ec=$?
check "dispatch: refuses before prepare ran" "2" "$ec"
bash "$PREP" run --feature-dir "$FD" >/dev/null 2>&1
ec=0; blocked="$(bash "$STEP" dispatch --feature-dir "$FD" --task task-002 2>/dev/null)" || ec=$?
check "dispatch: a blocked task is refused" "1" "$ec"
check "dispatch: the refusal names the blocker" "blocked" "$(jq -r '.reason' <<<"$blocked")"
check "dispatch: a refused task leaves no dispatch state" "0" "$([[ -f "$FD/dispatch/task-002.json" ]] && echo 1 || echo 0)"
out="$(bash "$STEP" dispatch --feature-dir "$FD" --task task-001)"
check "dispatch: packet is dispatchable" "true" "$(jq -r '.dispatchable' <<<"$out")"
check "dispatch: in-place mode has no worktree" "null" "$(jq -r '.worktreePath' <<<"$out")"
check "dispatch: base SHA is the feature HEAD" "$(git -C "$ROOT" rev-parse HEAD)" "$(jq -r '.taskBaseSha' <<<"$out")"
check "dispatch: the brief is written" "1" "$([[ -f "$(jq -r '.brief' <<<"$out")" ]] && echo 1 || echo 0)"
check "dispatch: the model is the role default" "inherit" "$(jq -r '.model' <<<"$out")"
check "dispatch: task_start was emitted" "1" "$(grep -c '"event":"task_start"' "$FD/events.jsonl")"
check "dispatch: progress index and total" "1/2" "$(jq -r '"\(.index)/\(.total)"' <<<"$out")"

out="$(bash "$STEP" verdict --feature-dir "$FD" --task task-001 --verdict pass)"
check "verdict pass: integrate" "integrate" "$(jq -r '.action' <<<"$out")"
out="$(bash "$STEP" verdict --feature-dir "$FD" --task task-001 --verdict rework --attempt 1)"
check "verdict rework on a one-shot rung: a fresh dispatch reads the report" "oneshot" "$(jq -r '.action' <<<"$out")"
check "verdict rework: next attempt is counted" "2" "$(jq -r '.nextAttempt' <<<"$out")"
out="$(bash "$STEP" verdict --feature-dir "$FD" --task task-001 --verdict rework --attempt 4)"
check "verdict rework late: fresh upgrade" "fresh-upgrade" "$(jq -r '.action' <<<"$out")"

# the implementer edits a.py in place, then the lead integrates
printf 'print(2)\n' > "$ROOT/a.py"
ec=0; out="$(bash "$STEP" integrate --feature-dir "$FD" --task task-001 2>/dev/null)" || ec=$?
check "integrate in place: published" "true" "$(jq -r '.published' <<<"$out")"
check "integrate in place: exit 0" "0" "$ec"
check "integrate in place: the commit names the task" "1" "$(git -C "$ROOT" log --oneline -1 | grep -c 'change a')"
check "integrate in place: marked done" "task-001" "$(bash "$REPO_ROOT/lib/task-progress.sh" done "$FD/tasks.json")"
check "integrate in place: task_end merged" "1" "$(grep -c '"result":"merged"' "$FD/events.jsonl")"
check "integrate in place: verify log kept" "1" "$([[ -f "$FD/logs/verify-task-001.log" ]] && echo 1 || echo 0)"

# a task whose implementer changed nothing
bash "$STEP" dispatch --feature-dir "$FD" --task task-002 >/dev/null
ec=0; out="$(bash "$STEP" integrate --feature-dir "$FD" --task task-002 2>/dev/null)" || ec=$?
check "integrate: nothing committed is commit-missing" "commit-missing" "$(jq -r '.blocked' <<<"$out")"
check "integrate: a missing commit is a stop" "1" "$ec"
check "integrate: task_end failed" "1" "$(grep -c '"result":"failed"' "$FD/events.jsonl")"

# a spent breaker blocks the task
ec=0; out="$(bash "$STEP" verdict --feature-dir "$FD" --task task-002 --verdict rework --attempt 6 2>/dev/null)" || ec=$?
check "verdict: the breaker blocks with retry-exhausted" "retry-exhausted" "$(jq -r '.reason' <<<"$out")"
ec=0; out="$(bash "$STEP" verdict --feature-dir "$FD" --task task-002 --verdict block 2>/dev/null)" || ec=$?
check "verdict block: spec-compliance-block" "spec-compliance-block" "$(jq -r '.reason' <<<"$out")"

# --- backfill: an empty test command is filled after the first task, greenfield or not ---
# (two live runs shipped a placeholder README, were never flagged greenfield, and reached
# VERIFY with no test suite recorded).
export LOOP_SPEC_HARNESS=codex LOOP_SPEC_WORKTREES=0
FDB="$(new_feature backfill)"; ROOTB="$(git -C "$FDB" rev-parse --show-toplevel)"
bash "$REPO_ROOT/lib/feature-write.sh" set "$FDB" commands '{"prepare":"","test":"","lint":"","typecheck":""}' >/dev/null
bash "$PREP" run --feature-dir "$FDB" >/dev/null 2>&1
bash "$STEP" dispatch --feature-dir "$FDB" --task task-001 >/dev/null 2>&1
printf 'print(2)\n' > "$ROOTB/a.py"; printf '[project]\nname = "x"\nversion = "0"\nrequires-python = ">=3.8"\n' > "$ROOTB/pyproject.toml"
jq '.[0].files += ["pyproject.toml"]' "$FDB/tasks.json" > "$FDB/tasks.json.tmp" && mv "$FDB/tasks.json.tmp" "$FDB/tasks.json"
bash "$STEP" integrate --feature-dir "$FDB" --task task-001 >/dev/null 2>&1
check "integrate: an empty commands.test is filled after task-001 without a greenfield flag" ".venv/bin/python -m pytest" "$(jq -r '.commands.test' "$FDB/feature.json")"
check "integrate: an empty commands.prepare is filled the same way" "1" "$(jq -r '.commands.prepare' "$FDB/feature.json" | grep -c 'venv')"

# --- worktree mode (Claude harness, lead-created worktrees) -----------------------------
export LOOP_SPEC_HARNESS=claude LOOP_SPEC_WORKTREES=1
FD2="$(new_feature isolated)"; ROOT2="$(git -C "$FD2" rev-parse --show-toplevel)"
bash "$PREP" run --feature-dir "$FD2" >/dev/null 2>&1
if [[ "$(jq -r '.rung.subagentIsolation' "$FD2/dispatch/prepare.json")" == "lead-worktree" ]]; then
  out="$(bash "$STEP" dispatch --feature-dir "$FD2" --task task-001)"
  WT="$(jq -r '.worktreePath' <<<"$out")"
  check "dispatch worktree: a task worktree exists" "1" "$([[ -d "$WT" ]] && echo 1 || echo 0)"
  check "dispatch worktree: on the task branch" "task/task-001-my-feature" "$(git -C "$WT" branch --show-current)"
  printf 'print(2)\n' > "$WT/a.py"; git -C "$WT" add a.py; git -C "$WT" commit -q -m "feat: NO_JIRA change a"
  out="$(bash "$STEP" package --feature-dir "$FD2" --task task-001 --head "$(git -C "$WT" rev-parse HEAD)")"
  check "package: a review package is written" "1" "$([[ -f "$(jq -r '.package' <<<"$out")" ]] && echo 1 || echo 0)"
  check "package: names the task worktree for the reviewer" "$WT" "$(jq -r '.worktree' <<<"$out")"
  # dispatch modified the tracked feature.json; integrate must not refuse its own state.
  git -C "$ROOT2" add -f -- "$FD2/feature.json" >/dev/null 2>&1; git -C "$ROOT2" commit -q -m "track state" -- "$FD2/feature.json" >/dev/null 2>&1 || true
  jq '.touched = "by the driver"' "$FD2/feature.json" > "$FD2/feature.json.tmp" && mv "$FD2/feature.json.tmp" "$FD2/feature.json"
  printf '# Backlog\n' > "$ROOT2/.loop-spec/BACKLOG.md"
  ec=0; out="$(bash "$STEP" integrate --feature-dir "$FD2" --task task-001 2>/dev/null)" || ec=$?
  check "integrate worktree: published onto the feature branch" "true" "$(jq -r '.published' <<<"$out")"
  check "integrate worktree: no state commit lands on the branch (state lives on the ref)" "0" "$(git -C "$ROOT2" log --oneline | grep -c 'state @ execute')"
  check "integrate worktree: a new .loop-spec file is never dirt and never tracked" "0" "$(git -C "$ROOT2" ls-files .loop-spec/BACKLOG.md | grep -c BACKLOG)"
  check "integrate worktree: feature branch carries the commit" "1" "$(git -C "$ROOT2" log --oneline feat/my-feature | grep -c 'change a')"
  check "integrate worktree: marked done" "task-001" "$(bash "$REPO_ROOT/lib/task-progress.sh" done "$FD2/tasks.json")"
  # The implementer never commits; a task worktree left dirty is the driver's to commit
  # (a live session-rung run read zero-commit and the lead committed by hand).
  out="$(bash "$STEP" dispatch --feature-dir "$FD2" --task task-002)"
  WT2="$(jq -r '.worktreePath' <<<"$out")"
  printf 'print("b")\n' > "$WT2/b.py"
  ec=0; out="$(bash "$STEP" integrate --feature-dir "$FD2" --task task-002 2>/dev/null)" || ec=$?
  check "integrate worktree: an uncommitted task.files change is committed by the driver" "true" "$(jq -r '.published' <<<"$out")"
  check "integrate worktree: the driver's commit names the task" "1" "$(git -C "$ROOT2" log --oneline feat/my-feature | grep -c 'add b')"
else
  echo "SKIP: worktree mode not selected on this host ($(jq -r '.rung.reason' "$FD2/dispatch/prepare.json"))"
fi

echo ""
# --- run: the session rung's launch is the driver's ---------------------------------
# A stub CLI and profile stand in for the harness binary; the runner records the prompt.
SBIN="$WORK/sbin"; SPROF="$WORK/sprofiles"; mkdir -p "$SBIN" "$SPROF"
cat > "$SBIN/codex" <<'SH'
#!/usr/bin/env bash
{ printf '%s\n' "$@"; echo "cwd=$(pwd -P)"; } > "${FAKE_ARGS_OUT:-/dev/null}"
echo '{"ok":true}'
SH
chmod +x "$SBIN/codex"
printf 'name = "codex"\nbinary = "codex"\nlaunch_args = ["exec", "--json"]\nguarded_args = []\nbypass_args = []\nmodel_flag = "--model"\nprompt_template = "{prompt}"\n' > "$SPROF/codex.toml"
FDS="$(LOOP_SPEC_HARNESS=codex LOOP_SPEC_WORKTREES=1 new_feature session)"
ROOTS="$(git -C "$FDS" rev-parse --show-toplevel)"
sess() { env PATH="$SBIN:$PATH" LOOP_SPEC_HARNESS=codex LOOP_SPEC_SESSION_LAYER=1 LOOP_SPEC_SESSION_PROFILES="$SPROF" LOOP_SPEC_WORKTREES=1 FAKE_ARGS_OUT="$WORK/args" "$@"; }
sess bash "$REPO_ROOT/lib/execute-prepare.sh" run --feature-dir "$FDS" >/dev/null 2>&1
check "run: prepare selected the session rung" "session" "$(jq -r '.rung.rung' "$FDS/dispatch/prepare.json")"
disp="$(sess bash "$STEP" dispatch --feature-dir "$FDS" --task task-001)"
WT1="$(jq -r '.worktreePath' <<<"$disp")"
check "run: the session rung isolates the task in a lead-created worktree" "1" "$([[ -d "$WT1" ]] && echo 1 || echo 0)"
ec=0; out="$(sess bash "$STEP" run --feature-dir "$FDS" --task task-001 --role implementer 2>&1)" || ec=$?
check "run implementer: the session completed" "completed" "$(jq -r '.status' <<<"$out")"
check "run implementer: exit 0" "0" "$ec"
check "run implementer: the prompt is one line and the paths" "1" "$(grep -c "^Implement the task in $FDS/dispatch/task-001.brief.md. The spec is .*. Write your report to $FDS/dispatch/task-001.report.md.$" "$FDS/dispatch/task-001.implementer.md")"
check "run implementer: the CLI received the profile's launch line" "exec --json" "$(sed -n '1,2p' "$WORK/args" | paste -sd' ' -)"
check "run implementer: the log lands under the feature's dispatch dir" "$FDS/dispatch/sessions" "$(dirname "$(jq -r '.stdout' <<<"$out")")"
check "run implementer: the session ran in the task worktree" "1" "$(grep -c "^cwd=$(cd "$WT1" && pwd -P)$" "$WORK/args" 2>/dev/null || echo 0)"
check "run: an unknown role is a bad invocation" "2" "$(sess bash "$STEP" run --feature-dir "$FDS" --task task-001 --role judge >/dev/null 2>&1; echo $?)"
check "run reviewer: refused before package" "2" "$(sess bash "$STEP" run --feature-dir "$FDS" --task task-001 --role reviewer >/dev/null 2>&1; echo $?)"
printf 'print(2)\n' > "$WT1/a.py"; git -C "$WT1" commit -qam "task-001"
sess bash "$STEP" package --feature-dir "$FDS" --task task-001 --head "$(git -C "$WT1" rev-parse HEAD)" >/dev/null
ec=0; out="$(sess bash "$STEP" run --feature-dir "$FDS" --task task-001 --role reviewer 2>&1)" || ec=$?
check "run reviewer: the session completed" "completed" "$(jq -r '.status' <<<"$out")"
check "run reviewer: the prompt names the package and the verdict path" "1" "$(grep -c '^Review the package in .* against the spec .*\. Write your verdict to .*task-001.report.md.$' "$FDS/dispatch/task-001.reviewer.md")"
check "run: a failing session is exit 1 with status failed" "failed:1" "$(printf '#!/usr/bin/env bash\nexit 3\n' > "$SBIN/codex"; ec=0; o="$(sess bash "$STEP" run --feature-dir "$FDS" --task task-001 --role implementer 2>/dev/null)" || ec=$?; echo "$(jq -r '.status' <<<"$o"):$ec")"
check "run: on another rung the answer is in-harness" "in-harness" "$(jq '.rung.rung = "subagent"' "$FDS/dispatch/prepare.json" > "$WORK/p.json" && mv "$WORK/p.json" "$FDS/dispatch/prepare.json"; sess bash "$STEP" run --feature-dir "$FDS" --task task-001 --role implementer | jq -r '.action')"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
