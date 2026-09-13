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
# The physical path: on macOS $TMPDIR is under /var, a symlink to /private/var, and the
# script answers `git rev-parse --show-toplevel` paths (this case was red there).
REPO="$WORK/repo"; mkdir -p "$REPO"; WORK="$(cd "$WORK" && pwd -P)"; REPO="$WORK/repo"
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
 {"id":"task-003","subject":"third","files":["c.py"],"blockedBy":[],"verifyCommand":"jq -e . c.json && ! grep -E '(apply|\\bdestroy)' c.json","acceptanceCriteria":["c"]}
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
check "run: the toolchain is probed once for the briefs" "1" "$(grep -c '^jq: jq-' "$FD/dispatch/environment.txt")"
check "run: quoted pattern fragments are not probed as programs" "0" "$(grep -c 'apply\|\\b' "$FD/dispatch/environment.txt")"

# --- a planner-declared reverse edge wins over the synthetic one -------------------
# Built by hand rather than cycle-driver: my-feature is already the checkout's active
# feature, and cycle-driver refuses a second one in the same checkout.
FDR="$REPO/.loop-spec/features/reverse-edge"
mkdir -p "$FDR" "$REPO/docs/loop-spec/features/reverse-edge"
printf '# PLAN\n' > "$REPO/docs/loop-spec/features/reverse-edge/PLAN.md"
git -C "$REPO" branch -q feat/reverse-edge main
cat > "$FDR/feature.json" <<JSON
{"schemaVersion":7,"slug":"reverse-edge","currentPhase":"execute","artifacts":{},
 "pendingRemediationTasks":[],"fileConflictExcludeGlobs":[],"branch":"feat/reverse-edge",
 "workspace":null,"commands":{"prepare":"","test":"true","lint":"","typecheck":""}}
JSON
cat > "$FDR/tasks.json" <<'JSON'
[
 {"id":"task-001","subject":"first","files":["shared.py"],"blockedBy":["task-002"],"verifyCommand":"true","acceptanceCriteria":["a"]},
 {"id":"task-002","subject":"second","files":["shared.py"],"blockedBy":[],"verifyCommand":"true","acceptanceCriteria":["b"]}
]
JSON
bash "$REPO_ROOT/lib/feature-write.sh" set "$FDR" artifacts.tasks "\"$FDR/tasks.json\"" >/dev/null
bash "$REPO_ROOT/lib/feature-write.sh" set "$FDR" commands '{"prepare":"","test":"true","lint":"","typecheck":""}' >/dev/null
# LOOP_SPEC_TASK_BATCH_AUTO=0: the two tasks' blockedBy chain of local verify commands
# would otherwise collapse them into one dispatch entry, hiding the per-task blockedBy
# this test is checking.
out="$(LOOP_SPEC_TASK_BATCH_AUTO=0 bash "$SCRIPT" run --feature-dir "$FDR" 2>/dev/null)"
check "reverse edge: planner's declared blockedBy is kept" "true" "$(jq -r '.tasks[] | select(.id == "task-001") | .blockedBy | index("task-002") != null' <<<"$out")"
check "reverse edge: no synthetic edge is added in the opposite direction" "false" "$(jq -r '.tasks[] | select(.id == "task-002") | (.blockedBy | index("task-001") != null)' <<<"$out")"
check "reverse edge: task-002 has no syntheticBlockedBy" "null" "$(jq -r '.tasks[] | select(.id == "task-002") | .syntheticBlockedBy // null' <<<"$out")"
check "reverse edge: dag-width is not a cycle" "0" "$(jq -r '.stop' <<<"$out" | grep -c true)"

# --- remediation intake ------------------------------------------------------------
bash "$REPO_ROOT/lib/feature-write.sh" append "$FD" pendingRemediationTasks '{"id":"task-001+remediate-1","subject":"Fix: a"}' >/dev/null
bash "$REPO_ROOT/lib/feature-write.sh" append "$FD" pendingRemediationTasks '{"id":"task-001+remediate-2","subject":"Fix: b"}' >/dev/null
out="$(bash "$SCRIPT" run --feature-dir "$FD" 2>/dev/null)"
check "remediation: the task is registered in the sidecar" "1" "$(jq '[.[] | select(.id == "task-001+remediate-1")] | length' "$FD/tasks.json")"
check "remediation: it takes the project test command" "true" "$(jq -r '.[] | select(.id == "task-001+remediate-1") | .verifyCommand' "$FD/tasks.json")"
check "remediation: the pending array is cleared" "0" "$(jq '.pendingRemediationTasks | length' "$FD/feature.json")"
check "remediation: the count is reported" "2" "$(jq -r '.remediationRegistered' <<<"$out")"
check "remediation: both queued findings appear in dispatch" "2" "$(jq '[.tasks[] | select(.id | startswith("task-001+remediate-"))] | length' <<<"$out")"


# --- invalid intake must leave every queued task available for repair ---------------
for pending in '[{"id":"bad-verify","subject":"repair verification"}]' '[{"id":"bad-shape","subject":"repair shape","files":"a.py","verifyCommand":"true"}]' 'false' 'null' '[null]' '[{"id":"valid-prefix","subject":"keep this too","verifyCommand":"true"},{"id":"invalid-suffix","subject":"cannot verify"}]'; do
  bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" commands.test '""' >/dev/null
  bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" pendingRemediationTasks "$pending" >/dev/null
  before="$(cat "$FD/tasks.json")"
  ec=0; out="$(bash "$SCRIPT" run --feature-dir "$FD" 2>"$WORK/intake.err")" || ec=$?
  check "invalid remediation $pending: preparation stops" "1" "$ec"
  check "invalid remediation $pending: readable sidecar stays valid" "true" "$(jq -r '.sidecarOk' <<<"$out")"
  check "invalid remediation $pending: intake failure names its own error" "true" "$(jq '.remediationError | type == "string" and length > 0' <<<"$out")"
  check "invalid remediation $pending: dispatch is stopped" "true:0" "$(jq -r '(.stop | tostring) + ":" + (.tasks | length | tostring)' <<<"$out")"

  check "invalid remediation $pending: diagnostic identifies repair" "1" "$(grep -Ec 'verifyCommand|commands.test|files|pendingRemediationTasks|object' "$WORK/intake.err")"
  check "invalid remediation $pending: queue unchanged" "$(jq -c . <<<"$pending")" "$(jq -c '.pendingRemediationTasks' "$FD/feature.json")"
  check "invalid remediation $pending: sidecar unchanged" "$before" "$(cat "$FD/tasks.json")"
done
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" commands.test '"true"' >/dev/null
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" pendingRemediationTasks '[]' >/dev/null
saved_sidecar="$(cat "$FD/tasks.json")"
printf '{' > "$FD/tasks.json"
ec=0; out="$(bash "$SCRIPT" run --feature-dir "$FD" 2>/dev/null)" || ec=$?
check "malformed sidecar: failure is distinct from remediation intake" "false:null" "$(jq -r '(.sidecarOk | tostring) + ":" + (.remediationError | tostring)' <<<"$out")"
check "malformed sidecar: preparation stops" "1" "$ec"
printf '%s\n' "$saved_sidecar" > "$FD/tasks.json"

# --- recovery after publication must distinguish replay from recurrence -------------
python3 - "$REPO_ROOT" "$WORK" <<'PYREMEDIATION'
import json
from pathlib import Path
import subprocess
import sys
from unittest.mock import patch

root, work = map(Path, sys.argv[1:])
sys.path.insert(0, str(root / "lib"))
try:
    import execute_remediation as intake
except ImportError as exc:
    print("FAIL: remediation transaction module is unavailable: %s" % exc)
    sys.exit(1)

feature = work / "transaction"
feature.mkdir()
sidecar = feature / "tasks.json"
original = {"id":"original", "subject":"already published", "files":[], "blockedBy":[],
            "verifyCommand":"true", "acceptanceCriteria":["published"], "status":"done"}
queued = [{"id":"task-verify-code-review-1", "subject":"repair review"},
          {"id":"task-verify-marker-1", "subject":"repair marker"}]
def reset():
    sidecar.write_text(json.dumps([original]))
    (feature / "feature.json").write_text(json.dumps({"slug":"transaction", "commands":{"test":"true"},
        "pendingRemediationTasks":queued, "artifacts":{"tasks":str(sidecar)},
        "specApproval":{"digest":"unchanged"}, "warnings":["keep"]}))
def state():
    return json.loads((feature / "feature.json").read_text())
def writer(args):
    subprocess.run(["bash", str(root / "lib/feature-write.sh")] + args, check=True)
def failed_writer(args):
    raise OSError("injected acknowledgment failure")
def expect_failure(call, label):
    try:
        call()
    except (OSError, ValueError, subprocess.CalledProcessError):
        print("PASS: " + label)
    else:
        raise AssertionError(label)

reset()
old = sidecar.read_bytes()
with patch("feature_write.os.replace", side_effect=OSError("injected replacement failure")):
    expect_failure(lambda: intake.register(feature, sidecar), "failed atomic publication is visible")
assert sidecar.read_bytes() == old and state()["pendingRemediationTasks"] == queued
print("PASS: failed publication preserves readable sidecar and entire queue")
expect_failure(lambda: intake.register(feature, sidecar, writer=failed_writer), "failed acknowledgment is visible")
assert state()["pendingRemediationTasks"] == queued
published = json.loads(sidecar.read_text())
assert len(published) == 3
published[1]["status"] = "done"
published[1]["retries"] = 2
sidecar.write_text(json.dumps(published))
assert intake.register(feature, sidecar) == 0
assert json.loads(sidecar.read_text()) == published
assert state()["pendingRemediationTasks"] == []
print("PASS: replay adds zero duplicates and preserves recorded progress")
writer(["set", str(feature), "pendingRemediationTasks", json.dumps(queued)])
assert intake.register(feature, sidecar) == 2
republished = json.loads(sidecar.read_text())
assert len(republished) == 5 and all(t.get("status") != "done" for t in republished[-2:])
assert len({t["id"] for t in republished}) == 5
print("PASS: completed fallback IDs recur as executable work")
reset()
collision = dict(queued[0], subject="different work sharing an ID")
writer(["set", str(feature), "pendingRemediationTasks", json.dumps([queued[0], collision])])
assert intake.register(feature, sidecar) == 2
assert [t["subject"] for t in json.loads(sidecar.read_text())[1:]] == ["repair review", "different work sharing an ID"]
print("PASS: ID collision retains both distinct findings")
reset()
late = {"id":"late", "subject":"arrived during publication"}
def concurrent_writer(args):
    writer(["append", str(feature), "pendingRemediationTasks", json.dumps(late)])
    writer(args)
assert intake.register(feature, sidecar, writer=concurrent_writer) == 2
assert state()["pendingRemediationTasks"] == [late]
assert state()["specApproval"] == {"digest":"unchanged"} and state()["warnings"] == ["keep"]
print("PASS: concurrent append survives acknowledgment with unrelated state intact")
reset()
expect_failure(lambda: intake.register(feature, sidecar, writer=failed_writer), "publication before crash leaves replay evidence")
writer(["append", str(feature), "pendingRemediationTasks", json.dumps(late)])
assert intake.register(feature, sidecar) == 1
assert len(json.loads(sidecar.read_text())) == 4 and state()["pendingRemediationTasks"] == []
print("PASS: appended work after failed acknowledgment does not duplicate the published prefix")
PYREMEDIATION
[[ $? == 0 ]] || FAIL=$((FAIL + 1))

# Store failure must not turn a durable sidecar into a ready response.
printf '#!/usr/bin/env bash\necho "injected store failure" >&2\nexit 2\n' > "$WORK/failing-store.sh"
chmod +x "$WORK/failing-store.sh"
bash "$REPO_ROOT/lib/feature-write.sh" append "$FD" pendingRemediationTasks '{"id":"store-failure","subject":"repair persisted work"}' >/dev/null
ec=0; out="$(LOOP_SPEC_STORE="$WORK/failing-store.sh" bash "$SCRIPT" run --feature-dir "$FD" 2>"$WORK/store.err")" || ec=$?
check "failed acknowledgment: store failure never reports ready" "1" "$ec"
check "failed acknowledgment: store failure diagnostic survives" "1" "$(grep -c 'store persist failed' "$WORK/store.err")"
check "failed acknowledgment: published work remains dispatchable" "1" "$(jq '[.[] | select(.id == "store-failure" and .status != "done")] | length' "$FD/tasks.json")"
ec=0; out="$(LOOP_SPEC_STORE="$WORK/failing-store.sh" bash "$SCRIPT" run --feature-dir "$FD" 2>"$WORK/store-retry.err")" || ec=$?
check "failed acknowledgment: retry remains blocked until store persistence succeeds" "1" "$ec"
ec=0; out="$(bash "$SCRIPT" run --feature-dir "$FD" 2>"$WORK/store-recovered.err")" || ec=$?
check "failed acknowledgment: successful store recovery makes preparation ready" "0" "$ec"
check "failed acknowledgment: recovered work is dispatched" "1" "$(jq '[.tasks[] | select(.id == "store-failure")] | length' <<<"$out")"



# A real marker scan reuses its fallback ID on every VERIFY visit.
cp "$REPO_ROOT/tests/fixtures/remediation-marker.py.txt" "$REPO/stub.py"
git -C "$REPO" add stub.py; git -C "$REPO" commit -q -m "test: marker fixture"
for attempt in 1 2; do
  ec=0; scanned="$(bash "$REPO_ROOT/lib/verify-prepare.sh" run --feature-dir "$FD" 2>/dev/null)" || ec=$?
  check "marker recurrence $attempt: real VERIFY intake reports remediation" "remediate" "$(jq -r '.route' <<<"$scanned")"
  out="$(bash "$SCRIPT" run --feature-dir "$FD" 2>/dev/null)"
  check "marker recurrence $attempt: fallback task is executable" "1" "$(jq '[.tasks[] | select(.id | startswith("task-verify-marker-1"))] | length' <<<"$out")"
  marker_id="$(jq -r '.tasks[] | select(.id | startswith("task-verify-marker-1")) | .id' <<<"$out")"
  bash "$REPO_ROOT/lib/task-progress.sh" mark-done "$FD/tasks.json" "$marker_id" >/dev/null
done

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

# --- a failed artifact commit is this call's failure, never a stale HEAD --------------
git -C "$REPO" checkout -q feat/my-feature 2>/dev/null
mkdir -p "$REPO/docs/loop-spec/features/my-feature"; printf 'pending\n' >> "$REPO/docs/loop-spec/features/my-feature/PLAN.md"
mkdir -p "$REPO/.git/hooks"; printf '#!/bin/sh\nexit 1\n' > "$REPO/.git/hooks/pre-commit"; chmod +x "$REPO/.git/hooks/pre-commit"
ec=0; err="$(bash "$SCRIPT" run --feature-dir "$FD" 2>&1 >/dev/null)" || ec=$?
check "artifact commit refused by a hook: exit 2" "2" "$ec"
check "artifact commit refused by a hook: the failure is named" "1" "$(grep -c 'could not commit pending docs/loop-spec/features/my-feature artifacts' <<<"$err")"
check "artifact commit refused by a hook: nothing claims to be committed" "0" "$(grep -c artifactsCommitted <<<"$err")"
rm -f "$REPO/.git/hooks/pre-commit"; git -C "$REPO" checkout -q -- docs 2>/dev/null; git -C "$REPO" reset -q

echo ""
# --- workspace mode ---------------------------------------------------------------
# featureRoot used to be "" here, and every task step downstream ran git against it.
WS="$WORK/ws"; mkdir -p "$WS/fe"
git -C "$WS/fe" init -q -b main; git -C "$WS/fe" commit -q --allow-empty -m init
(cd "$WS" && bash "$REPO_ROOT/lib/cycle-driver.sh" start --dir "$WS" -- ws feature >/dev/null 2>&1
  bash "$REPO_ROOT/lib/cycle-driver.sh" init --dir "$WS" --slug ws-feature --title "ws feature" --style auto --profile standard --autonomous 1 \
    --repos '[{"name":"fe","path":"fe"}]' >/dev/null 2>&1)
FDW="$WS/.loop-spec/features/ws-feature"
mkdir -p "$WS/docs/loop-spec/features/ws-feature"; printf '# PLAN\n' > "$WS/docs/loop-spec/features/ws-feature/PLAN.md"
printf '[{"id":"task-001","subject":"first","repo":"fe","files":["fe/a.py"],"blockedBy":[],"verifyCommand":"true","acceptanceCriteria":["a"]}]\n' > "$FDW/tasks.json"
bash "$REPO_ROOT/lib/feature-write.sh" set "$FDW" artifacts.tasks "\"$FDW/tasks.json\"" >/dev/null
ec=0; out="$(bash "$SCRIPT" run --feature-dir "$FDW" 2>/dev/null)" || ec=$?
check "workspace: ready feature exits 0" "0" "$ec"
check "workspace: every repo is on the feature branch" "true" "$(jq -r '.branch.ok' <<<"$out")"
check "workspace: featureRoot is the workspace root" "$WS" "$(jq -r '.featureRoot' <<<"$out")"
check "workspace: the packet carries the repos for execute-step" "fe:fe" "$(jq -r '.workspace.repos[] | "\(.name):\(.path)"' <<<"$out")"
check "workspace: the rung is the one-shot subagent" "subagent" "$(jq -r '.rung.rung' <<<"$out")"
check "single: the packet has no workspace" "null" "$(jq -r '.workspace' "$FD/dispatch/prepare.json")"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
