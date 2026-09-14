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

# a replayed integrate (a resumed lead re-issuing the call) is not a second success
ec=0; out="$(bash "$STEP" integrate --feature-dir "$FD" --task task-001 2>/dev/null)" || ec=$?
check "integrate in place: a replayed call is commit-missing, not published again" "commit-missing:1" "$(jq -r '.blocked' <<<"$out"):$ec"

# a spent breaker blocks the task
ec=0; out="$(bash "$STEP" verdict --feature-dir "$FD" --task task-002 --verdict rework --attempt 6 2>/dev/null)" || ec=$?
check "verdict: the breaker blocks with retry-exhausted" "retry-exhausted" "$(jq -r '.reason' <<<"$out")"
ec=0; out="$(bash "$STEP" verdict --feature-dir "$FD" --task task-002 --verdict block 2>/dev/null)" || ec=$?
check "verdict block: spec-compliance-block" "spec-compliance-block" "$(jq -r '.reason' <<<"$out")"

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


# --- workspace mode: the task's repo is the git target, never the workspace root ---------
# A live 6.6.0 run recorded taskBaseSha="", refused package with "no recorded base SHA",
# and ran verify in `cd ''`: prepare.json carried featureRoot="" for a workspace feature.
export LOOP_SPEC_HARNESS=codex LOOP_SPEC_WORKTREES=0
WS="$WORK/ws"; mkdir -p "$WS"
for r in fe be svc/api; do
  mkdir -p "$WS/$r"; git -C "$WS/$r" init -q -b main
  git -C "$WS/$r" commit -q --allow-empty -m init
  printf 'print(1)\n' > "$WS/$r/a.py"; git -C "$WS/$r" add a.py; git -C "$WS/$r" commit -q -m base
done
(cd "$WS" && bash "$REPO_ROOT/lib/cycle-driver.sh" start --dir "$WS" -- my feature >/dev/null 2>&1
  bash "$REPO_ROOT/lib/cycle-driver.sh" init --dir "$WS" --slug my-feature --title "my feature" --style auto --profile standard --autonomous 1 \
    --repos '[{"name":"be","path":"be"},{"name":"fe","path":"fe"},{"name":"api","path":"svc/api"}]' >/dev/null 2>&1)
FDW="$WS/.loop-spec/features/my-feature"
mkdir -p "$WS/docs/loop-spec/features/my-feature"; printf '# PLAN\n' > "$WS/docs/loop-spec/features/my-feature/PLAN.md"
cat > "$FDW/tasks.json" <<'JSON'
[{"id":"task-001","subject":"change fe a","repo":"fe","files":["fe/a.py"],"blockedBy":[],"verifyCommand":"python3 a.py","acceptanceCriteria":["a prints 2"]},
 {"id":"task-002","subject":"change be a","repo":"be","files":["be/a.py"],"blockedBy":[],"verifyCommand":"true","acceptanceCriteria":["b prints 2"]},
 {"id":"task-003","subject":"no repo","files":["be/b.py"],"blockedBy":[],"verifyCommand":"true","acceptanceCriteria":["c"]},
 {"id":"task-004","subject":"unknown repo","repo":"web","files":["web/a.py"],"blockedBy":[],"verifyCommand":"true","acceptanceCriteria":["d"]},
 {"id":"task-005","subject":"change api a","repo":"api","files":["api/a.py"],"blockedBy":[],"verifyCommand":"true","acceptanceCriteria":["e"]},
 {"id":"task-006","subject":"cross-repo batch","repo":"fe","files":["fe/c.py","be/c.py"],"blockedBy":[],"verifyCommand":"true","acceptanceCriteria":["f"]}]
JSON
bash "$REPO_ROOT/lib/feature-write.sh" set "$FDW" artifacts.tasks "\"$FDW/tasks.json\"" >/dev/null
check "workspace fixture: the feature is a workspace feature" "workspace" "$(jq -r '.executionRootMode' "$FDW/feature.json")"
ec=0; bash "$PREP" run --feature-dir "$FDW" >/dev/null 2>&1 || ec=$?
check "workspace prepare: ready" "0" "$ec"
out="$(bash "$STEP" dispatch --feature-dir "$FDW" --task task-001)"
check "workspace dispatch: the packet root is the task's repo" "$WS/fe" "$(jq -r '.featureRoot' <<<"$out")"
check "workspace dispatch: base SHA is the repo HEAD" "$(git -C "$WS/fe" rev-parse HEAD)" "$(jq -r '.taskBaseSha' <<<"$out")"
check "workspace dispatch: no worktree" "null" "$(jq -r '.worktreePath' <<<"$out")"
ec=0; out="$(bash "$STEP" package --feature-dir "$FDW" --task task-001 --head "$(git -C "$WS/fe" rev-parse HEAD)" 2>/dev/null)" || ec=$?
check "workspace package: answers from the recorded base" "0" "$ec"
check "workspace package: the reviewer is pointed at the repo" "$WS/fe" "$(jq -r '.worktree' <<<"$out")"
printf 'print(2)\n' > "$WS/fe/a.py"
ec=0; out="$(bash "$STEP" integrate --feature-dir "$FDW" --task task-001 2>/dev/null)" || ec=$?
check "workspace integrate: verify ran in the repo and published" "true" "$(jq -r '.published' <<<"$out")"
check "workspace integrate: exit 0" "0" "$ec"
check "workspace integrate: the repo-prefixed file is committed in the repo" "1" "$(git -C "$WS/fe" log --oneline -1 feat/my-feature | grep -c 'change fe a')"
check "workspace integrate: the repo is clean after the commit" "" "$(git -C "$WS/fe" status --porcelain)"
check "workspace integrate: the other repo is untouched" "$(git -C "$WS/be" rev-parse HEAD)" "$(git -C "$WS/be" rev-parse feat/my-feature)"
check "workspace integrate: marked done" "task-001" "$(bash "$REPO_ROOT/lib/task-progress.sh" done "$FDW/tasks.json")"
check "workspace integrate: task_end merged" "1" "$(grep -c '"result":"merged"' "$FDW/events.jsonl")"
# The workspace implementer prompt commits in its repo itself (execute-subagent.md Step 4):
# published is HEAD past the recorded base, not a commit this call made.
bash "$STEP" dispatch --feature-dir "$FDW" --task task-002 >/dev/null
printf 'print(2)\n' > "$WS/be/a.py"; git -C "$WS/be" commit -qam "feat: NO_JIRA change be a"
ec=0; out="$(bash "$STEP" integrate --feature-dir "$FDW" --task task-002 2>/dev/null)" || ec=$?
check "workspace integrate: an implementer's own commit is published" "true" "$(jq -r '.published' <<<"$out")"
check "workspace integrate: the published sha is the implementer's commit" "$(git -C "$WS/be" rev-parse HEAD)" "$(jq -r '.sha' <<<"$out")"
ec=0; bash "$STEP" dispatch --feature-dir "$FDW" --task task-003 >/dev/null 2>&1 || ec=$?
check "workspace dispatch: a task with no repo is a bad invocation, not a root git call" "2" "$ec"
ec=0; bash "$STEP" dispatch --feature-dir "$FDW" --task task-004 >/dev/null 2>&1 || ec=$?
check "workspace dispatch: a repo the feature does not list is a bad invocation" "2" "$ec"
# files carry the repo NAME; the repo may live at a different PATH
out="$(bash "$STEP" dispatch --feature-dir "$FDW" --task task-005)"
check "workspace dispatch: the root is the repo's path, not its name" "$WS/svc/api" "$(jq -r '.featureRoot' <<<"$out")"
printf 'print(2)\n' > "$WS/svc/api/a.py"
ec=0; out="$(bash "$STEP" integrate --feature-dir "$FDW" --task task-005 2>/dev/null)" || ec=$?
check "workspace integrate: the name prefix is stripped when name and path differ" "true:" "$(jq -r '.published' <<<"$out"):$(git -C "$WS/svc/api" status --porcelain)"
# a batch collapsed across repos would stage half its files and publish the rest as done
bash "$STEP" dispatch --feature-dir "$FDW" --task task-006 >/dev/null
printf 'print(3)\n' > "$WS/fe/c.py"; printf 'print(3)\n' > "$WS/be/c.py"
ec=0; out="$(bash "$STEP" integrate --feature-dir "$FDW" --task task-006 2>/dev/null)" || ec=$?
check "workspace integrate: files naming another repo are refused before verify" "files-outside-repo:1" "$(jq -r '.blocked' <<<"$out"):$ec"
check "workspace integrate: the refusal names the foreign file" "be/c.py" "$(jq -r '.detail' <<<"$out" | grep -o 'be/c.py')"
check "workspace integrate: nothing was committed for the refused task" "0" "$(git -C "$WS/fe" log --oneline | grep -c 'cross-repo')"

# --- artifactsCommitted: a phase artifact stranded uncommitted gets committed before dispatch ---
export LOOP_SPEC_HARNESS=codex LOOP_SPEC_WORKTREES=0
FD="$(new_feature artifacts)"; ROOT="$(git -C "$FD" rev-parse --show-toplevel)"
echo "pending" >> "$ROOT/docs/loop-spec/features/my-feature/PLAN.md"
prep_out="$(bash "$PREP" run --feature-dir "$FD")"
sha="$(jq -r '.artifactsCommitted' <<<"$prep_out")"
check "artifactsCommitted: a stranded phase artifact gets a commit sha" "40" "${#sha}"
check "artifactsCommitted: the working tree is clean after prepare" "" \
  "$(git -C "$ROOT" status --porcelain -- docs/loop-spec/features/my-feature)"

# --- add-files: widens a task's write scope, refuses once integrated -----------------
export LOOP_SPEC_HARNESS=codex LOOP_SPEC_WORKTREES=0
FDA="$(new_feature addfiles)"; ROOTA="$(git -C "$FDA" rev-parse --show-toplevel)"
bash "$PREP" run --feature-dir "$FDA" >/dev/null
bash "$STEP" dispatch --feature-dir "$FDA" --task task-001 >/dev/null
out="$(bash "$STEP" add-files --feature-dir "$FDA" --task task-001 c.py)"
check "add-files: reports the widened file list" "a.py c.py" "$(jq -r '.files | join(" ")' <<<"$out")"
check "add-files: sidecar carries the new file" "a.py c.py" \
  "$(jq -r '.[] | select(.id=="task-001") | .files | join(" ")' "$FDA/tasks.json")"
check "add-files: tasks-collapsed.json carries the new file" "a.py c.py" \
  "$(jq -r '.[] | select(.id=="task-001") | .files | join(" ")' "$FDA/dispatch/tasks-collapsed.json")"
check "add-files: prepare.json carries the new file" "a.py c.py" \
  "$(jq -r '.tasks[] | select(.id=="task-001") | .files | join(" ")' "$FDA/dispatch/prepare.json")"
ec=0; bash "$STEP" add-files --feature-dir "$FDA" --task task-001 /etc/passwd >/dev/null 2>&1 || ec=$?
check "add-files: an absolute path is a bad invocation" "2" "$ec"
ec=0; bash "$STEP" add-files --feature-dir "$FDA" --task task-001 ../escape.py >/dev/null 2>&1 || ec=$?
check "add-files: a path that escapes the repo is a bad invocation" "2" "$ec"
printf 'x\n' > "$ROOTA/c.py"
bash "$STEP" integrate --feature-dir "$FDA" --task task-001 >/dev/null
ec=0; bash "$STEP" add-files --feature-dir "$FDA" --task task-001 d.py >/dev/null 2>&1 || ec=$?
check "add-files: refuses a task task-progress.sh already marked done" "1" "$ec"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
