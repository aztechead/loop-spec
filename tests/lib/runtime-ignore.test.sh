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

for policy in root managed; do
  policy_repo="$WORK/$policy"
  git init -q "$policy_repo"
  git -C "$policy_repo" config core.excludesFile /dev/null
  : > "$policy_repo/.git/info/exclude"
  if [[ "$policy" == root ]]; then
    cp "$ROOT/.gitignore" "$policy_repo/.gitignore"
  else
    bash "$SCRIPT" ensure "$policy_repo"
  fi
  mkdir -p "$policy_repo/.loop-spec/sessions/run" "$policy_repo/.loop-spec/features/demo" "$policy_repo/lib"
  for path in .loop-spec/sessions/run/state.json .loop-spec/launcher-result.json \
    .loop-spec/launcher.lock .loop-spec/features/demo/feature.json .loop-spec/features/demo/PROGRESS.md; do
    touch "$policy_repo/$path"
    check "$policy policy ignores $path" "ignored" \
      "$(git -C "$policy_repo" check-ignore -q "$path" && echo ignored || echo not-ignored)"
  done
  for path in lib/cycle-result.sh .loop-spec/RULES.md; do
    touch "$policy_repo/$path"
    check "$policy policy keeps $path visible" "not-ignored" \
      "$(git -C "$policy_repo" check-ignore -q "$path" && echo ignored || echo not-ignored)"
  done
done

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
  "$WORK/.loop-spec/active-run.json" \
  "$WORK/.loop-spec/last-result.json" \
  "$WORK/.loop-spec/results/run.json" \
  "$WORK/.loop-spec/decisions-staging/decisions.jsonl" \
  "$WORK/graphify-out/cache/deadbeef.json" \
  "$WORK/graphify-out/cost.json" \
  "$WORK/graphify-out/graph.json"

check "feature state is ignored (it lives on refs/loop-spec/state/<slug>)" "ignored" \
  "$(git -C "$WORK" check-ignore -q .loop-spec/features/demo/feature.json && echo ignored || echo not-ignored)"
check "progress is ignored" "ignored" \
  "$(git -C "$WORK" check-ignore -q .loop-spec/features/demo/PROGRESS.md && echo ignored || echo not-ignored)"
# A checkout from before 6.4 carries the negations the driver used to need; ensure removes them.
EXC="$WORK/.git/info/exclude"
printf '!/.loop-spec/features/*/feature.json\n!/.loop-spec/features/*/PROGRESS.md\n' >> "$EXC"
bash "$SCRIPT" ensure "$WORK" >/dev/null
check "ensure removes the legacy state negations" "0" "$(grep -c 'features/\*/feature.json\|features/\*/PROGRESS.md' "$EXC")"
for path in \
  .loop-spec/features/demo/delivery.json \
  .loop-spec/features/demo/events.jsonl \
  .loop-spec/features/demo/gate-logs/round.json \
  .loop-spec/runtime.json \
  .loop-spec/active-run.json \
  .loop-spec/last-result.json \
  .loop-spec/results/run.json \
  .loop-spec/decisions-staging/decisions.jsonl \
  graphify-out/cache/deadbeef.json \
  graphify-out/cost.json \
  graphify-out/graph.json; do
  check "$path ignored" "ignored" \
    "$(git -C "$WORK" check-ignore -q "$path" && echo ignored || echo not-ignored)"
done

# The profile is written untracked by a supervisor (docs/loop-spec/supervisor-interface.md);
# left unignored it made cycle-driver init refuse every fresh checkout as dirty.
touch "$WORK/.loop-spec/profile.json"
check ".loop-spec/profile.json ignored" "ignored" \
  "$(git -C "$WORK" check-ignore -q .loop-spec/profile.json && echo ignored || echo not-ignored)"
touch "$WORK/.loop-spec/invocation-stamp.json"
check ".loop-spec/invocation-stamp.json ignored" "ignored" \
  "$(git -C "$WORK" check-ignore -q .loop-spec/invocation-stamp.json && echo ignored || echo not-ignored)"

# /revise must reuse feature-shaped runtime state without allowing it to enter a
# remediation commit, even in repositories that historically tracked it.
git -C "$WORK" add -f .loop-spec/features/demo/feature.json .loop-spec/features/demo/PROGRESS.md
git -C "$WORK" commit -qm "legacy feature state"
printf 'changed\n' >> "$WORK/.loop-spec/features/demo/feature.json"
printf 'changed\n' >> "$WORK/.loop-spec/features/demo/PROGRESS.md"
bash "$SCRIPT" revise-state "$WORK" demo
check "revise state hides historical tracked feature.json" "clean" \
  "$(git -C "$WORK" status --porcelain -- .loop-spec/features/demo/feature.json | grep -q . && echo dirty || echo clean)"
check "revise state hides historical tracked progress" "clean" \
  "$(git -C "$WORK" status --porcelain -- .loop-spec/features/demo/PROGRESS.md | grep -q . && echo dirty || echo clean)"
touch "$WORK/.loop-spec/features/demo/events.jsonl"
check "revise state ignores new runtime entries" "ignored" \
  "$(git -C "$WORK" check-ignore -q .loop-spec/features/demo/events.jsonl && echo ignored || echo not-ignored)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
