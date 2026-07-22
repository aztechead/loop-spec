#!/usr/bin/env bash
# Unit tests for lib/runtime-ignore.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/lib/runtime-ignore.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }
check() {
  local name="$1" expected="$2" actual="$3"
  [[ "$actual" == "$expected" ]] && pass "$name" || fail "$name (expected $expected, got $actual)"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
git -C "$WORK" init -q
git -C "$WORK" -c user.name=Test -c user.email=test@example.com commit --allow-empty -qm init

bash "$SCRIPT" ensure "$WORK"
exclude="$(git -C "$WORK" rev-parse --git-path info/exclude)"
[[ "$exclude" == /* ]] || exclude="$WORK/$exclude"
before="$(git hash-object "$exclude")"
bash "$SCRIPT" ensure "$WORK"
after="$(git hash-object "$exclude")"
check "ensure is byte-idempotent" "$before" "$after"

mkdir -p "$WORK/.loop-spec/features/demo/gate-logs" \
  "$WORK/.loop-spec/decisions-staging" "$WORK/.loop-spec/results" \
  "$WORK/graphify-out/cache"
touch "$WORK/.loop-spec/features/demo/feature.json" \
  "$WORK/.loop-spec/features/demo/PROGRESS.md" \
  "$WORK/.loop-spec/features/demo/delivery.json" \
  "$WORK/.loop-spec/features/demo/events.jsonl" \
  "$WORK/.loop-spec/features/demo/gate-logs/round.json" \
  "$WORK/.loop-spec/runtime.json" \
  "$WORK/.loop-spec/last-result.json" \
  "$WORK/.loop-spec/results/run.json" \
  "$WORK/.loop-spec/decisions-staging/decisions.jsonl" \
  "$WORK/graphify-out/cache/deadbeef.json" \
  "$WORK/graphify-out/cost.json"

check "feature state remains trackable" "not-ignored" \
  "$(git -C "$WORK" check-ignore -q .loop-spec/features/demo/feature.json && echo ignored || echo not-ignored)"
check "progress remains trackable" "not-ignored" \
  "$(git -C "$WORK" check-ignore -q .loop-spec/features/demo/PROGRESS.md && echo ignored || echo not-ignored)"
for path in \
  .loop-spec/features/demo/delivery.json \
  .loop-spec/features/demo/events.jsonl \
  .loop-spec/features/demo/gate-logs/round.json \
  .loop-spec/runtime.json \
  .loop-spec/last-result.json \
  .loop-spec/results/run.json \
  .loop-spec/decisions-staging/decisions.jsonl \
  graphify-out/cache/deadbeef.json \
  graphify-out/cost.json; do
  check "$path ignored" "ignored" \
    "$(git -C "$WORK" check-ignore -q "$path" && echo ignored || echo not-ignored)"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
