#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/lib/owned-gitignore.sh"
WORK="${TMPDIR:-/tmp}/loop-spec-owned-ignore.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"
git -C "$WORK" init -q -b main
git -C "$WORK" config user.email test@example.com
git -C "$WORK" config user.name test
printf 'base\n' > "$WORK/base"
git -C "$WORK" add base
git -C "$WORK" commit -q -m base
PASS=0; FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

rc=0; bash "$SCRIPT" check "$WORK" || rc=$?
check "missing ignore is clean" "0" "$rc"

printf '!/.loop-spec/features/*/PROGRESS.md\n' > "$WORK/.gitignore"
rc=0; bash "$SCRIPT" check "$WORK" || rc=$?
check "untracked owned policy accepted" "0" "$rc"

printf 'human-content\n' >> "$WORK/.gitignore"
rc=0; bash "$SCRIPT" check "$WORK" || rc=$?
check "untracked mixed content rejected" "1" "$rc"

printf 'base-pattern\n' > "$WORK/.gitignore"
git -C "$WORK" add .gitignore
git -C "$WORK" commit -q -m ignore
printf '!/.loop-spec/RULES.md\n' >> "$WORK/.gitignore"
git -C "$WORK" add .gitignore
rc=0; bash "$SCRIPT" check "$WORK" || rc=$?
check "staged owned addition accepted" "0" "$rc"

printf 'human-content\n' >> "$WORK/.gitignore"
rc=0; bash "$SCRIPT" check "$WORK" || rc=$?
check "mixed staged and unstaged dirt rejected" "1" "$rc"

git -C "$WORK" restore --staged --worktree .gitignore
chmod +x "$WORK/.gitignore"
rc=0; bash "$SCRIPT" check "$WORK" || rc=$?
check "file mode change rejected" "1" "$rc"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
