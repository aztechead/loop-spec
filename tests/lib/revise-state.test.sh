#!/usr/bin/env bash
# Tests for lib/revise-state.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$ROOT/lib/revise-state.sh"
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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/revise-state-test-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
git -C "$WORK" init -q
git -C "$WORK" -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm init
printf '(defproject demo "0.1.0")\n' > "$WORK/project.clj"

# Missing feature.json: skeleton, not a hand-built jq object.
out="$(bash "$LIB" ensure "$WORK" demo --branch feat/demo --base-branch main \
  --title "demo feature" --autonomous 1)"
check "create reports created=true" "true" "$(jq -r '.created' <<<"$out")"
check "create reports phase revise" "revise" "$(jq -r '.currentPhase' <<<"$out")"
check "create detects lein test" "lein test" "$(jq -r '.testCommand' <<<"$out")"
fj="$WORK/.loop-spec/features/demo/feature.json"
check "create writes schema 7" "7" "$(jq -r '.schemaVersion' "$fj")"
check "create sets currentPhase" "revise" "$(jq -r '.currentPhase' "$fj")"
check "create sets autonomous" "true" "$(jq -r '.autonomous' "$fj")"
check "create keeps iterate block" "10" "$(jq -r '.iterate.maxIterations' "$fj")"
check "create does not set reconstructed" "false" \
  "$(jq -r 'has("reconstructed")' "$fj")"

# Existing feature.json: flip phase, fill empty test command, do not clobber title.
printf '{"schemaVersion":7,"slug":"demo","feature_title":"keep me","currentPhase":"deliver","commands":{"test":""},"iterate":{"used":1,"maxIterations":10}}\n' \
  > "$fj"
out="$(bash "$LIB" ensure "$WORK" demo --branch feat/demo --autonomous 0)"
check "reuse reports created=false" "false" "$(jq -r '.created' <<<"$out")"
check "reuse sets phase revise" "revise" "$(jq -r '.currentPhase' "$fj")"
check "reuse fills empty test command" "lein test" "$(jq -r '.commands.test' "$fj")"
check "reuse preserves title" "keep me" "$(jq -r '.feature_title' "$fj")"
check "reuse preserves iterate.used" "1" "$(jq -r '.iterate.used' "$fj")"

# Existing test command is left alone.
bash "$ROOT/lib/feature-write.sh" set "$(dirname "$fj")" commands.test '"make test"'
out="$(bash "$LIB" ensure "$WORK" demo --branch feat/demo)"
check "reuse does not overwrite a set test command" "make test" \
  "$(jq -r '.commands.test' "$fj")"

rc=0
bash "$LIB" ensure "$WORK" 'bad slug' --branch feat/x >/dev/null 2>&1 || rc=$?
check "unsafe slug exits 2" "2" "$rc"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
