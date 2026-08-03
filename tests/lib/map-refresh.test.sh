#!/usr/bin/env bash
# Behavioral coverage for the deterministic map-refresh no-op decision.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/lib/map-refresh.sh"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }
check() {
  local name="$1" expected="$2" actual="$3"
  [[ "$actual" == "$expected" ]] && pass "$name" || fail "$name (expected '$expected', got '$actual')"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.name Test
git -C "$REPO" config user.email test@example.com
mkdir -p "$REPO/.loop-spec/codebase" "$REPO/docs/loop-spec/codebase" "$REPO/src"
for file in TECH.md ARCH.md QUALITY.md CONCERNS.md DOMAIN.md; do
  printf '# %s\n' "$file" > "$REPO/docs/loop-spec/codebase/$file"
done
printf '%s\n' '{"files":{"src/app.js":["tech","arch"],"test/app.test.js":["quality"]}}' \
  > "$REPO/.loop-spec/codebase/index.json"
printf 'export const value = 1\n' > "$REPO/src/app.js"
mkdir -p "$REPO/test"
printf 'test\n' > "$REPO/test/app.test.js"
git -C "$REPO" add .
git -C "$REPO" commit -qm base
BASE="$(git -C "$REPO" rev-parse HEAD)"

decision() { bash "$SCRIPT" decide "$REPO" "$BASE" "$@"; }

out="$(decision)"
check "unchanged complete map skips work" false "$(jq -r '.refresh' <<<"$out")"
check "unchanged map has stable reason" no-map-relevant-changes "$(jq -r '.reason' <<<"$out")"

mkdir -p "$REPO/docs/loop-spec/features/demo"
printf '# Progress\n' > "$REPO/docs/loop-spec/features/demo/PROGRESS.md"
git -C "$REPO" add docs/loop-spec/features/demo/PROGRESS.md
git -C "$REPO" commit -qm state
out="$(decision)"
check "feature runtime artifact does not refresh maps" false "$(jq -r '.refresh' <<<"$out")"

printf 'export const value = 2\n' > "$REPO/src/app.js"
git -C "$REPO" add src/app.js
git -C "$REPO" commit -qm source-change
out="$(decision)"
check "mapped source change refreshes" true "$(jq -r '.refresh' <<<"$out")"
check "mapped source selects indexed domains" '["arch","tech"]' "$(jq -c '.domains | sort' <<<"$out")"

printf 'export const newValue = 3\n' > "$REPO/src/new.js"
git -C "$REPO" add src/new.js
git -C "$REPO" commit -qm new-source
out="$(decision)"
check "unknown source change refreshes" true "$(jq -r '.refresh' <<<"$out")"
check "unknown source conservatively refreshes architecture" true \
  "$(jq -e '.domains | index("arch") != null' <<<"$out" >/dev/null && echo true || echo false)"

printf 'export const empty = true\n' > "$REPO/src/empty.js"
printf '%s\n' "$(jq '.files["src/empty.js"] = []' "$REPO/.loop-spec/codebase/index.json")" > "$REPO/.loop-spec/codebase/index.json"
git -C "$REPO" add src/empty.js .loop-spec/codebase/index.json
git -C "$REPO" commit -qm empty-index-entry
out="$(decision)"
check "empty index entry does not suppress a source refresh" true "$(jq -r '.refresh' <<<"$out")"
check "empty index entry conservatively refreshes architecture" true \
  "$(jq -e '.domains | index("arch") != null' <<<"$out" >/dev/null && echo true || echo false)"

out="$(decision --mode full)"
check "full request never uses no-op path" true "$(jq -r '.refresh' <<<"$out")"
check "full request includes all domains" '["arch","concerns","domain","quality","tech"]' \
  "$(jq -c '.domains | sort' <<<"$out")"

out="$(decision --domains tech,quality)"
check "explicit domain request refreshes" true "$(jq -r '.refresh' <<<"$out")"
check "explicit domain request is exact" '["quality","tech"]' "$(jq -c '.domains | sort' <<<"$out")"

rm "$REPO/docs/loop-spec/codebase/QUALITY.md"
out="$(decision)"
check "partial map never takes no-op path" true "$(jq -r '.refresh' <<<"$out")"
check "partial map refreshes all required artifacts" '["arch","concerns","domain","quality","tech"]' \
  "$(jq -c '.domains | sort' <<<"$out")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
