#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/lib/feature-validation.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
assert_eq() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1 (got '$2', want '$3')"; }

repo="$TMP/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name Test
printf 'base\n' > "$repo/app.txt"
git -C "$repo" add app.txt
git -C "$repo" commit -qm base
base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb feat/demo
mkdir -p "$repo/.loop-spec/features/demo"

write_feature() {
  local baseline="$1" test_cmd="$2"
  mkdir -p "$repo/.loop-spec/features/demo"
  jq -n --arg base "$base" --arg test "$test_cmd" --argjson baseline "$baseline" '{
    schemaVersion:7,slug:"demo",branch:"feat/demo",baseSha:$base,workspace:null,
    commands:{prepare:"",test:$test,lint:"",typecheck:""},verificationBaseline:$baseline
  }' > "$repo/.loop-spec/features/demo/feature.json"
  git -C "$repo" add -f .loop-spec/features/demo/feature.json
  git -C "$repo" commit -qm state
}

passing="$(jq -n --arg base "$base" '{schemaVersion:1,baseSha:$base,prepareKey:"",commands:{test:{command:"true",status:"pass",exitCode:0,fingerprints:[]},lint:{command:"",status:"skipped",exitCode:null,fingerprints:[]},typecheck:{command:"",status:"skipped",exitCode:null,fingerprints:[]}}}')"
write_feature "$passing" true
out="$(bash "$SCRIPT" compare "$repo/.loop-spec/features/demo")"; rc=$?
assert_eq "accepted candidate exits zero" "$rc" 0
assert_eq "accepted aggregate outcome" "$(jq -r '.outcome' <<<"$out")" accepted

git -C "$repo" reset --hard -q "$base"
git -C "$repo" checkout -B feat/demo -q
failing_base="$(jq -n --arg base "$base" '{schemaVersion:1,baseSha:$base,prepareKey:"",commands:{test:{command:"false",status:"fail",exitCode:1,fingerprints:["known"]},lint:{command:"",status:"skipped",exitCode:null,fingerprints:[]},typecheck:{command:"",status:"skipped",exitCode:null,fingerprints:[]}}}')"
write_feature "$failing_base" false
out="$(bash "$SCRIPT" compare "$repo/.loop-spec/features/demo" 2>/dev/null)"; rc=$?
assert_eq "changed failure fingerprint is regression" "$rc" 20
assert_eq "regression aggregate outcome" "$(jq -r '.outcome' <<<"$out")" regression

git -C "$repo" reset --hard -q "$base"
git -C "$repo" checkout -B feat/demo -q
write_feature null false
out="$(bash "$SCRIPT" compare "$repo/.loop-spec/features/demo" 2>/dev/null)"; rc=$?
assert_eq "missing baseline stays strict" "$rc" 20

workspace="$TMP/workspace"
mkdir -p "$workspace/.loop-spec/features/empty"
jq -n '{schemaVersion:7,slug:"empty",workspace:{root:"/tmp",repos:[]}}' \
  > "$workspace/.loop-spec/features/empty/feature.json"
out="$(bash "$SCRIPT" compare "$workspace/.loop-spec/features/empty" 2>/dev/null)"; rc=$?
assert_eq "empty workspace is rejected" "$rc" 2

git -C "$repo" checkout -qb wrong-branch
out="$(bash "$SCRIPT" compare "$repo/.loop-spec/features/demo" 2>/dev/null)"; rc=$?
assert_eq "recorded branch mismatch is infrastructure" "$rc" 21
assert_eq "branch mismatch is not accepted" "$(jq -r '.outcome' <<<"$out")" infra_error

candidate="$(git -C "$repo" rev-parse HEAD)"
out="$(LOOP_SPEC_INTEGRATION_CANDIDATE="$candidate" bash "$SCRIPT" compare \
  "$repo/.loop-spec/features/demo" 2>/dev/null)"; rc=$?
assert_eq "exact integration candidate may use a task branch" "$rc" 20
assert_eq "task candidate still runs strict comparison" "$(jq -r '.outcome' <<<"$out")" regression

wrong_candidate="$(printf '0%.0s' {1..40})"
out="$(LOOP_SPEC_INTEGRATION_CANDIDATE="$wrong_candidate" bash "$SCRIPT" compare \
  "$repo/.loop-spec/features/demo" 2>/dev/null)"; rc=$?
assert_eq "wrong integration candidate is infrastructure" "$rc" 21

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
