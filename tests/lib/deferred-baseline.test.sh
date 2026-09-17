#!/usr/bin/env bash
# Behavioral coverage for the deferred exact-base baseline capture.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${TMPDIR:-/tmp}/deferred-baseline-test.$$"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO/.loop-spec/features/demo"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email test@example.com; git -C "$REPO" config user.name test
printf 'base\n' > "$REPO/app.txt"; git -C "$REPO" add app.txt; git -C "$REPO" commit -qm base
BASE="$(git -C "$REPO" rev-parse HEAD)"; printf 'feature\n' > "$REPO/app.txt"
git -C "$REPO" add app.txt; git -C "$REPO" commit -qm feature
COUNTER="$WORK/count"; : > "$COUNTER"
cat > "$REPO/.loop-spec/features/demo/feature.json" <<JSON
{"schemaVersion":7,"slug":"demo","baseSha":"$BASE","branch":"main","greenfield":false,
 "verificationBaselineOptIn":true,"verificationBaselineAttempted":false,"verificationBaseline":null,
 "commands":{"prepare":"","test":"printf x >> '$COUNTER'; test \"\$(cat app.txt)\" = base","lint":"","typecheck":""},
 "workspace":null,"artifacts":{"tasks":"$REPO/.loop-spec/features/demo/tasks.json"},"pendingRemediationTasks":[],"fileConflictExcludeGlobs":[]}
JSON
printf '[]\n' > "$REPO/.loop-spec/features/demo/tasks.json"
# Worktree policy skips are fail-closed and retryable for explicit, boolean, and
# malformed values; unset and 1 retain normal capture behavior below.
for policy in 0 true invalid; do
  policy_err="$WORK/policy-$policy.err"
  rc=0; LOOP_SPEC_WORKTREES="$policy" bash "$ROOT/lib/deferred-baseline.sh" run "$REPO/.loop-spec/features/demo" 2>"$policy_err" || rc=$?
  [[ "$rc" -eq 0 ]] || { echo "ASSERTION FAILED policy $policy exit" >&2; exit 1; }
  [[ "$(jq -r '.verificationBaselineAttempted' "$REPO/.loop-spec/features/demo/feature.json")" == false ]] || { echo "ASSERTION FAILED policy $policy retryable" >&2; exit 1; }
  [[ "$(grep -c 'deferred baseline skipped' "$policy_err")" -eq 1 ]] || { echo "ASSERTION FAILED policy $policy notice" >&2; exit 1; }
done
[[ "$(wc -c < "$COUNTER")" -eq 0 ]] || { echo "ASSERTION FAILED policy capture side effect" >&2; exit 1; }
[[ "$(jq -r '.verificationBaseline' "$REPO/.loop-spec/features/demo/feature.json")" == null ]] || { echo "ASSERTION FAILED policy baseline" >&2; exit 1; }
export LOOP_SPEC_WORKTREES=1

HEAD_BEFORE="$(git -C "$REPO" rev-parse HEAD)"; DIRTY_BEFORE="$(git -C "$REPO" status --porcelain)"
env -u LOOP_SPEC_WORKTREES bash "$ROOT/lib/deferred-baseline.sh" run "$REPO/.loop-spec/features/demo" >/dev/null 2>&1
[[ "$(wc -c < "$COUNTER")" -eq 1 ]] || { echo "ASSERTION FAILED line 22" >&2; exit 1; }
[[ "$(jq -r '.verificationBaseline.commands.test.status' "$REPO/.loop-spec/features/demo/feature.json")" == pass ]] || { echo "ASSERTION FAILED line 23" >&2; exit 1; }
[[ "$(jq -r '.verificationBaseline.baseSha' "$REPO/.loop-spec/features/demo/feature.json")" == "$BASE" ]] || { echo "ASSERTION FAILED line 24" >&2; exit 1; }
[[ "$(jq -r '.verificationBaselineAttempted' "$REPO/.loop-spec/features/demo/feature.json")" == true ]] || { echo "ASSERTION FAILED line 25" >&2; exit 1; }
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$HEAD_BEFORE" && "$(git -C "$REPO" status --porcelain)" == "$DIRTY_BEFORE" ]] || { echo "ASSERTION FAILED line 26" >&2; exit 1; }
bash "$ROOT/lib/deferred-baseline.sh" run "$REPO/.loop-spec/features/demo" >/dev/null 2>&1
[[ "$(wc -c < "$COUNTER")" -eq 1 ]] || { echo "ASSERTION FAILED line 28" >&2; exit 1; }
echo "PASS: exact base, side effect once, reentry skip, and checkout preservation"

# An existing baseline is retained even when its attempt marker is absent.
OLD_SINGLE='{"baseSha":"sentinel","commands":{"test":{"status":"fail"}},"sentinel":"keep"}'
bash "$ROOT/lib/feature-write.sh" set "$REPO/.loop-spec/features/demo" verificationBaseline "$OLD_SINGLE" >/dev/null
bash "$ROOT/lib/feature-write.sh" set "$REPO/.loop-spec/features/demo" verificationBaselineAttempted false >/dev/null
bash "$ROOT/lib/deferred-baseline.sh" run "$REPO/.loop-spec/features/demo" >/dev/null 2>&1
[[ "$(jq -c '.verificationBaseline' "$REPO/.loop-spec/features/demo/feature.json")" == "$OLD_SINGLE" ]] || { echo "ASSERTION FAILED line 36" >&2; exit 1; }
echo "PASS: existing baseline is preserved"

# Unchanged known-red output is accepted by the real VERIFY comparison after cleanup.
jq '.verificationBaseline=null | .verificationBaselineAttempted=false | .commands.test="echo ERROR old; exit 1"' "$REPO/.loop-spec/features/demo/feature.json" > "$WORK/known.json"
mv "$WORK/known.json" "$REPO/.loop-spec/features/demo/feature.json"
bash "$ROOT/lib/deferred-baseline.sh" run "$REPO/.loop-spec/features/demo" >/dev/null 2>&1
rc=0; bash "$ROOT/lib/feature-validation.sh" compare "$REPO/.loop-spec/features/demo" >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 0 ]] || { echo "ASSERTION FAILED line 44" >&2; exit 1; }
LOGDIR="$(git -C "$REPO" rev-parse --git-path "loop-spec/validation/demo/base/single")"; [[ "$LOGDIR" == /* ]] || LOGDIR="$REPO/$LOGDIR"
[[ -f "$LOGDIR/test.log" ]] || { echo "ASSERTION FAILED line 46" >&2; exit 1; }
echo "PASS: unchanged known-red baseline is accepted and logs survive cleanup"

# A failed capture is nonterminal and still records one durable attempt.
FAILREPO="$WORK/fail"; git clone -q "$REPO" "$FAILREPO"; mkdir -p "$FAILREPO/.loop-spec/features/fail"; git -C "$FAILREPO" config user.email test@example.com; git -C "$FAILREPO" config user.name test
FAILBASE="$(git -C "$FAILREPO" rev-list --max-parents=0 HEAD)"
jq --arg b "$FAILBASE" '.slug="fail" | .baseSha=$b | .branch="main" | .verificationBaseline=null | .verificationBaselineAttempted=false | .commands.prepare="false"' "$REPO/.loop-spec/features/demo/feature.json" > "$FAILREPO/.loop-spec/features/fail/feature.json"
bash "$ROOT/lib/deferred-baseline.sh" run "$FAILREPO/.loop-spec/features/fail" >/dev/null 2>&1
[[ "$(jq -r '.verificationBaseline' "$FAILREPO/.loop-spec/features/fail/feature.json")" == null ]] || { echo "ASSERTION FAILED line 54" >&2; exit 1; }
[[ "$(jq -r '.verificationBaselineAttempted' "$FAILREPO/.loop-spec/features/fail/feature.json")" == true ]] || { echo "ASSERTION FAILED line 55" >&2; exit 1; }
[[ ! -f "$FAILREPO/.loop-spec/last-result.json" ]] || { echo "ASSERTION FAILED line 56" >&2; exit 1; }
[[ "$(git -C "$FAILREPO" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]] || { echo "ASSERTION FAILED line 57" >&2; exit 1; }
bash "$ROOT/lib/deferred-baseline.sh" run "$FAILREPO/.loop-spec/features/fail" >/dev/null 2>&1
[[ "$(git -C "$FAILREPO" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]] || { echo "ASSERTION FAILED line 59" >&2; exit 1; }
echo "PASS: failed capture remains null, nonterminal, cleaned up, and nonrepeating"

# An interrupted prepare is retryable. Synchronize on a marker from the exact-base
# child, then terminate only that invocation's process group before it publishes.
INT="$WORK/interrupted"; git clone -q "$REPO" "$INT"; mkdir -p "$INT/.loop-spec/features/int"
git -C "$INT" config user.email test@example.com; git -C "$INT" config user.name test
INTBASE="$(git -C "$INT" rev-list --max-parents=0 HEAD)"; INTMARKER="$WORK/prepare.started"
jq --arg b "$INTBASE" --arg m "$INTMARKER" \
  '.slug="int" | .baseSha=$b | .branch="main" | .verificationBaseline=null |
   .verificationBaselineAttempted=false | .commands.prepare=("touch " + $m + "; while :; do sleep 1; done") |
   .commands.test="test \"$(cat app.txt)\" = base"' \
  "$REPO/.loop-spec/features/demo/feature.json" > "$INT/.loop-spec/features/int/feature.json"
[[ "$(jq -r '.verificationBaselineAttempted' "$INT/.loop-spec/features/int/feature.json")" == false ]] || { echo "ASSERTION FAILED line 72" >&2; exit 1; }
[[ "$(jq -r '.verificationBaseline' "$INT/.loop-spec/features/int/feature.json")" == null ]] || { echo "ASSERTION FAILED line 73" >&2; exit 1; }
INT_HELPER="$WORK/interrupt-helper.py"
python3 - "$INT_HELPER" <<'PY'
import sys
from pathlib import Path
Path(sys.argv[1]).write_text("""import os, signal, subprocess, sys, time
feature, script, marker = sys.argv[1:]
p = subprocess.Popen(["bash", script, "run", feature], start_new_session=True,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
deadline = time.monotonic() + 10
while not os.path.exists(marker) and time.monotonic() < deadline:
    if p.poll() is not None:
        raise SystemExit(3)
    time.sleep(0.02)
if not os.path.exists(marker):
    os.killpg(p.pid, signal.SIGKILL)
    p.wait()
    raise SystemExit(4)
os.killpg(p.pid, signal.SIGTERM)
try:
    p.wait(timeout=5)
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL)
    p.wait()
""")
PY
python3 "$INT_HELPER" "$INT/.loop-spec/features/int" "$ROOT/lib/deferred-baseline.sh" "$INTMARKER"
[[ "$(jq -r '.verificationBaselineAttempted' "$INT/.loop-spec/features/int/feature.json")" == false ]] || { echo "ASSERTION FAILED line 100" >&2; exit 1; }
[[ "$(jq -r '.verificationBaseline' "$INT/.loop-spec/features/int/feature.json")" == null ]] || { echo "ASSERTION FAILED line 101" >&2; exit 1; }
bash "$ROOT/lib/feature-write.sh" set "$INT/.loop-spec/features/int" commands.prepare '""' >/dev/null
bash "$ROOT/lib/deferred-baseline.sh" run "$INT/.loop-spec/features/int" >/dev/null 2>&1
[[ "$(jq -r '.verificationBaselineAttempted' "$INT/.loop-spec/features/int/feature.json")" == true ]] || { echo "ASSERTION FAILED line 104" >&2; exit 1; }
[[ "$(jq -r '.verificationBaseline.baseSha' "$INT/.loop-spec/features/int/feature.json")" == "$INTBASE" ]] || { echo "ASSERTION FAILED line 105" >&2; exit 1; }
[[ "$(jq -r '.verificationBaseline.commands.test.status' "$INT/.loop-spec/features/int/feature.json")" == pass ]] || { echo "ASSERTION FAILED line 106" >&2; exit 1; }
echo "PASS: interrupted prepare remains retryable and resumes at exact base"

# Workspace root is orchestration-only; each child repository owns its baseline.
WS="$WORK/workspace"; mkdir -p "$WS/.loop-spec/features/ws" "$WS/one" "$WS/two"
for child in one two; do git -C "$WS/$child" init -q -b main; git -C "$WS/$child" config user.email test@example.com; git -C "$WS/$child" config user.name test; printf '%s\n' base > "$WS/$child/app"; git -C "$WS/$child" add app; git -C "$WS/$child" commit -qm base; done
B1="$(git -C "$WS/one" rev-parse HEAD)"; B2="$(git -C "$WS/two" rev-parse HEAD)"; printf 'changed\n' > "$WS/two/app"
OLD='{"baseSha":"old","commands":{"test":{"status":"fail"}},"sentinel":"preserve"}'
jq -n --arg root "$WS" --arg b1 "$B1" --arg b2 "$B2" --argjson old "$OLD" '{schemaVersion:7,slug:"ws",greenfield:false,verificationBaselineOptIn:true,verificationBaselineAttempted:false,workspace:{root:$root,repos:[{name:"one",path:"one",baseSha:$b1,commands:{prepare:"",test:"true",lint:"",typecheck:""},verificationBaseline:$old},{name:"two",path:"two",baseSha:$b2,commands:{prepare:"",test:"test \"$(cat app)\" = base",lint:"",typecheck:""},verificationBaseline:null}]}}' > "$WS/.loop-spec/features/ws/feature.json"
bash "$ROOT/lib/deferred-baseline.sh" run "$WS/.loop-spec/features/ws" >/dev/null 2>&1
[[ "$(jq -c '.workspace.repos[0].verificationBaseline' "$WS/.loop-spec/features/ws/feature.json")" == "$OLD" ]] || { echo "ASSERTION FAILED line 116" >&2; exit 1; }
[[ "$(jq -r '.workspace.repos[1].verificationBaseline.commands.test.status' "$WS/.loop-spec/features/ws/feature.json")" == pass ]] || { echo "ASSERTION FAILED line 117" >&2; exit 1; }
[[ "$(git -C "$WS/one" worktree list --porcelain | grep -c '^worktree ')" -eq 1 && "$(git -C "$WS/two" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]] || { echo "ASSERTION FAILED line 118" >&2; git -C "$WS/one" worktree list >&2; git -C "$WS/two" worktree list >&2; exit 1; }
echo "PASS: workspace preserves existing repo baseline and captures the other repo"

# Workspace results are durable per repository when a later repository is interrupted.
WSI="$WORK/workspace-interrupted"; mkdir -p "$WSI/.loop-spec/features/ws" "$WSI"
git clone -q "$WS/one" "$WSI/one"; git clone -q "$WS/two" "$WSI/two"
W1I="$(git -C "$WSI/one" rev-parse HEAD)"; W2I="$(git -C "$WSI/two" rev-parse HEAD)"; WIMARKER="$WORK/workspace.prepare.started"
jq -n --arg root "$WSI" --arg b1 "$W1I" --arg b2 "$W2I" --arg m "$WIMARKER" \
  '{schemaVersion:7,slug:"ws",greenfield:false,verificationBaselineOptIn:true,verificationBaselineAttempted:false,
    verificationBaseline:null,workspace:{root:$root,repos:[
      {name:"one",path:"one",baseSha:$b1,commands:{prepare:"",test:"true",lint:"",typecheck:""},verificationBaseline:null},
      {name:"two",path:"two",baseSha:$b2,commands:{prepare:("touch " + $m + "; while :; do sleep 1; done"),test:"true",lint:"",typecheck:""},verificationBaseline:null}]}}' \
  > "$WSI/.loop-spec/features/ws/feature.json"
python3 "$INT_HELPER" "$WSI/.loop-spec/features/ws" "$ROOT/lib/deferred-baseline.sh" "$WIMARKER"
[[ "$(jq -r '.verificationBaselineAttempted' "$WSI/.loop-spec/features/ws/feature.json")" == false ]] || { echo "ASSERTION FAILED line 132" >&2; exit 1; }
[[ "$(jq -r '.workspace.repos[0].verificationBaseline | type' "$WSI/.loop-spec/features/ws/feature.json")" == object ]] || { echo "ASSERTION FAILED line 133" >&2; exit 1; }
[[ "$(jq -r '.workspace.repos[1].verificationBaseline' "$WSI/.loop-spec/features/ws/feature.json")" == null ]] || { echo "ASSERTION FAILED line 134" >&2; exit 1; }
ONE_SAVED="$(jq -c '.workspace.repos[0].verificationBaseline' "$WSI/.loop-spec/features/ws/feature.json")"
bash "$ROOT/lib/feature-write.sh" set "$WSI/.loop-spec/features/ws" workspace.repos \
  "$(jq -c '.workspace.repos | map(if .name == "two" then .commands.prepare = "" else . end)' "$WSI/.loop-spec/features/ws/feature.json")" >/dev/null
bash "$ROOT/lib/deferred-baseline.sh" run "$WSI/.loop-spec/features/ws" >/dev/null 2>&1
[[ "$(jq -c '.workspace.repos[0].verificationBaseline' "$WSI/.loop-spec/features/ws/feature.json")" == "$ONE_SAVED" ]] || { echo "ASSERTION FAILED line 139" >&2; exit 1; }
[[ "$(jq -r '.workspace.repos[1].verificationBaseline | type' "$WSI/.loop-spec/features/ws/feature.json")" == object ]] || { echo "ASSERTION FAILED line 140" >&2; exit 1; }
echo "PASS: workspace interruption preserves repo1 and resumes repo2"

# A handled preparation failure also cleans its exact-base checkout on the early path.
WSF="$WORK/workspace-failure"; mkdir -p "$WSF/.loop-spec/features/ws"
git clone -q "$WS/one" "$WSF/one"; git clone -q "$WS/two" "$WSF/two"
WF1="$(git -C "$WSF/one" rev-parse HEAD)"; WF2="$(git -C "$WSF/two" rev-parse HEAD)"
jq -n --arg root "$WSF" --arg b1 "$WF1" --arg b2 "$WF2" \
  '{schemaVersion:7,slug:"ws",greenfield:false,verificationBaselineOptIn:true,verificationBaselineAttempted:false,
    verificationBaseline:null,workspace:{root:$root,repos:[
      {name:"one",path:"one",baseSha:$b1,commands:{prepare:"",test:"true",lint:"",typecheck:""},verificationBaseline:null},
      {name:"two",path:"two",baseSha:$b2,commands:{prepare:"false",test:"true",lint:"",typecheck:""},verificationBaseline:null}]}}' \
  > "$WSF/.loop-spec/features/ws/feature.json"
bash "$ROOT/lib/deferred-baseline.sh" run "$WSF/.loop-spec/features/ws" >/dev/null 2>&1
[[ "$(jq -r '.verificationBaselineAttempted' "$WSF/.loop-spec/features/ws/feature.json")" == true ]] || { echo "ASSERTION FAILED handled workspace marker" >&2; exit 1; }
[[ "$(git -C "$WSF/one" worktree list --porcelain | grep -c '^worktree ')" -eq 1 && "$(git -C "$WSF/two" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]] || { echo "ASSERTION FAILED handled workspace cleanup" >&2; exit 1; }
echo "PASS: workspace handled preparation failure cleans checkout"
echo "Results: 8 passed, 0 failed"
