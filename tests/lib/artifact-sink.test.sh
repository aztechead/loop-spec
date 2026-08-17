#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/lib/artifact-sink.sh"
PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

git -C "$WORK" init -q -b main
git -C "$WORK" -c user.name=Test -c user.email=test@example.com commit --allow-empty -qm base
base="$(git -C "$WORK" rev-parse HEAD)"
git -C "$WORK" checkout -qb feat/demo
feature="$WORK/.loop-spec/features/demo"
docs="$WORK/docs/loop-spec/features/demo"
mkdir -p "$feature" "$docs"
printf '# Spec\n' > "$docs/SPEC.md"
jq -n --arg base "$base" '{schemaVersion:7,slug:"demo",baseSha:$base,currentPhase:"deliver",
  artifacts:{spec:"docs/loop-spec/features/demo/SPEC.md"}}' > "$feature/feature.json"
git -C "$WORK" add .
git -C "$WORK" -c user.name=Test -c user.email=test@example.com commit -qm artifacts

check "default keeps artifacts inline" "inline" \
  "$(bash "$LIB" store "$feature" "$WORK")"
check "default leaves source artifact" "1" "$([[ -f "$docs/SPEC.md" ]] && echo 1 || echo 0)"

store="$WORK-store"
result="$(LOOP_SPEC_ARTIFACTS_IN_PR=0 LOOP_SPEC_ARTIFACT_DIR="$store" \
  bash "$LIB" store "$feature" "$WORK")"
destination="${result#stored:}"
check "store mode reports destination" "1" "$([[ "$result" == stored:* ]] && echo 1 || echo 0)"
check "artifact copied to store" "1" "$([[ -f "$destination/artifacts/SPEC.md" ]] && echo 1 || echo 0)"
check "feature state copied to store" "1" "$([[ -f "$destination/state/feature.json" ]] && echo 1 || echo 0)"
check "manifest records source head" "1" \
  "$(jq -e '.artifactsInPr == false and (.sourceHead | length > 0)' "$destination/manifest.json" >/dev/null && echo 1 || echo 0)"
check "source artifacts removed from candidate" "0" "$([[ -e "$docs/SPEC.md" ]] && echo 1 || echo 0)"
check "feature records store mode" "store" "$(jq -r '.artifactSink.mode' "$feature/feature.json")"
check "artifact deletion is staged" "1" \
  "$(git -C "$WORK" diff --cached --name-only | grep -qx 'docs/loop-spec/features/demo/SPEC.md' && echo 1 || echo 0)"
check "store retry is idempotent" "$result" \
  "$(LOOP_SPEC_ARTIFACTS_IN_PR=0 LOOP_SPEC_ARTIFACT_DIR="$store" \
    bash "$LIB" store "$feature" "$WORK")"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
