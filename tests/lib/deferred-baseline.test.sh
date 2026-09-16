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
HEAD_BEFORE="$(git -C "$REPO" rev-parse HEAD)"; DIRTY_BEFORE="$(git -C "$REPO" status --porcelain)"
bash "$ROOT/lib/deferred-baseline.sh" run "$REPO/.loop-spec/features/demo" >/dev/null 2>&1
[[ "$(wc -c < "$COUNTER")" -eq 1 ]]
[[ "$(jq -r '.verificationBaseline.commands.test.status' "$REPO/.loop-spec/features/demo/feature.json")" == pass ]]
[[ "$(jq -r '.verificationBaseline.baseSha' "$REPO/.loop-spec/features/demo/feature.json")" == "$BASE" ]]
[[ "$(jq -r '.verificationBaselineAttempted' "$REPO/.loop-spec/features/demo/feature.json")" == true ]]
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$HEAD_BEFORE" && "$(git -C "$REPO" status --porcelain)" == "$DIRTY_BEFORE" ]]
bash "$ROOT/lib/deferred-baseline.sh" run "$REPO/.loop-spec/features/demo" >/dev/null 2>&1
[[ "$(wc -c < "$COUNTER")" -eq 1 ]]
echo "PASS: exact base, side effect once, reentry skip, and checkout preservation"

# An existing baseline is retained even when its attempt marker is absent.
OLD_SINGLE='{"baseSha":"sentinel","commands":{"test":{"status":"fail"}},"sentinel":"keep"}'
bash "$ROOT/lib/feature-write.sh" set "$REPO/.loop-spec/features/demo" verificationBaseline "$OLD_SINGLE" >/dev/null
bash "$ROOT/lib/feature-write.sh" set "$REPO/.loop-spec/features/demo" verificationBaselineAttempted false >/dev/null
bash "$ROOT/lib/deferred-baseline.sh" run "$REPO/.loop-spec/features/demo" >/dev/null 2>&1
[[ "$(jq -c '.verificationBaseline' "$REPO/.loop-spec/features/demo/feature.json")" == "$OLD_SINGLE" ]]
echo "PASS: existing baseline is preserved"

# Unchanged known-red output is accepted by the real VERIFY comparison after cleanup.
jq '.verificationBaseline=null | .verificationBaselineAttempted=false | .commands.test="echo ERROR old; exit 1"' "$REPO/.loop-spec/features/demo/feature.json" > "$WORK/known.json"
mv "$WORK/known.json" "$REPO/.loop-spec/features/demo/feature.json"
bash "$ROOT/lib/deferred-baseline.sh" run "$REPO/.loop-spec/features/demo" >/dev/null 2>&1
rc=0; bash "$ROOT/lib/feature-validation.sh" compare "$REPO/.loop-spec/features/demo" >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 0 ]]
LOGDIR="$(git -C "$REPO" rev-parse --git-path "loop-spec/validation/demo/base/single")"; [[ "$LOGDIR" == /* ]] || LOGDIR="$REPO/$LOGDIR"
[[ -f "$LOGDIR/test.log" ]]
echo "PASS: unchanged known-red baseline is accepted and logs survive cleanup"

# A failed capture is nonterminal and still records one durable attempt.
FAILREPO="$WORK/fail"; git clone -q "$REPO" "$FAILREPO"; mkdir -p "$FAILREPO/.loop-spec/features/fail"; git -C "$FAILREPO" config user.email test@example.com; git -C "$FAILREPO" config user.name test
FAILBASE="$(git -C "$FAILREPO" rev-list --max-parents=0 HEAD)"
jq --arg b "$FAILBASE" '.slug="fail" | .baseSha=$b | .branch="main" | .verificationBaseline=null | .verificationBaselineAttempted=false | .commands.prepare="false"' "$REPO/.loop-spec/features/demo/feature.json" > "$FAILREPO/.loop-spec/features/fail/feature.json"
bash "$ROOT/lib/deferred-baseline.sh" run "$FAILREPO/.loop-spec/features/fail" >/dev/null 2>&1
[[ "$(jq -r '.verificationBaseline' "$FAILREPO/.loop-spec/features/fail/feature.json")" == null ]]
[[ "$(jq -r '.verificationBaselineAttempted' "$FAILREPO/.loop-spec/features/fail/feature.json")" == true ]]
[[ ! -f "$FAILREPO/.loop-spec/last-result.json" ]]
[[ "$(git -C "$FAILREPO" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]]
bash "$ROOT/lib/deferred-baseline.sh" run "$FAILREPO/.loop-spec/features/fail" >/dev/null 2>&1
[[ "$(git -C "$FAILREPO" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]]
echo "PASS: failed capture remains null, nonterminal, cleaned up, and nonrepeating"

# Workspace root is orchestration-only; each child repository owns its baseline.
WS="$WORK/workspace"; mkdir -p "$WS/.loop-spec/features/ws" "$WS/one" "$WS/two"
for child in one two; do git -C "$WS/$child" init -q -b main; git -C "$WS/$child" config user.email test@example.com; git -C "$WS/$child" config user.name test; printf '%s\n' base > "$WS/$child/app"; git -C "$WS/$child" add app; git -C "$WS/$child" commit -qm base; done
B1="$(git -C "$WS/one" rev-parse HEAD)"; B2="$(git -C "$WS/two" rev-parse HEAD)"; printf 'changed\n' > "$WS/two/app"
OLD='{"baseSha":"old","commands":{"test":{"status":"fail"}},"sentinel":"preserve"}'
jq -n --arg root "$WS" --arg b1 "$B1" --arg b2 "$B2" --argjson old "$OLD" '{schemaVersion:7,slug:"ws",greenfield:false,verificationBaselineOptIn:true,verificationBaselineAttempted:false,workspace:{root:$root,repos:[{name:"one",path:"one",baseSha:$b1,commands:{prepare:"",test:"true",lint:"",typecheck:""},verificationBaseline:$old},{name:"two",path:"two",baseSha:$b2,commands:{prepare:"",test:"test \"$(cat app)\" = base",lint:"",typecheck:""},verificationBaseline:null}]}}' > "$WS/.loop-spec/features/ws/feature.json"
bash "$ROOT/lib/deferred-baseline.sh" run "$WS/.loop-spec/features/ws" >/dev/null 2>&1
[[ "$(jq -c '.workspace.repos[0].verificationBaseline' "$WS/.loop-spec/features/ws/feature.json")" == "$OLD" ]]
[[ "$(jq -r '.workspace.repos[1].verificationBaseline.commands.test.status' "$WS/.loop-spec/features/ws/feature.json")" == pass ]]
[[ "$(git -C "$WS/one" worktree list --porcelain | grep -c '^worktree ')" -eq 1 && "$(git -C "$WS/two" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]]
echo "PASS: workspace preserves existing repo baseline and captures the other repo"
echo "Results: 5 passed, 0 failed"
