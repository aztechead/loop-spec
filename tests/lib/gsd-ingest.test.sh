#!/usr/bin/env bash
# Tests for lib/gsd-ingest.sh
set -euo pipefail

LIB="$(cd "$(dirname "$0")/../.." && pwd)/lib/gsd-ingest.sh"
PASS=0
FAIL=0

check() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"
    ((FAIL++)) || true
  fi
}

WORK="${TMPDIR:-/tmp}/loop-spec-gsd-ingest.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"
cd "$WORK"

# === patterns: phase-style path ===
rm -rf .planning docs
mkdir -p .planning/phases/my-feature
echo "pattern-content" > .planning/phases/my-feature/PATTERNS.md
got=$(bash "$LIB" patterns my-feature docs/loop-spec/features/my-feature/PATTERNS.md)
check "L: patterns INGESTED from .planning/phases/<slug>" "INGESTED .planning/phases/my-feature/PATTERNS.md" "$got"
target=$(cat docs/loop-spec/features/my-feature/PATTERNS.md)
echo "$target" | grep -q "pattern-content" && e=ok || e=bad
check "M: patterns target contains source content" "ok" "$e"

# === patterns: flat-style path fallback ===
rm -rf .planning docs
mkdir -p .planning/other-feat
echo "flat-pattern" > .planning/other-feat/PATTERNS.md
got=$(bash "$LIB" patterns other-feat docs/loop-spec/features/other-feat/PATTERNS.md)
check "N: patterns INGESTED from .planning/<slug>" "INGESTED .planning/other-feat/PATTERNS.md" "$got"

# === patterns: no GSD match ===
rm -rf .planning docs
got=$(bash "$LIB" patterns nope docs/loop-spec/features/nope/PATTERNS.md)
check "O: patterns NONE when no match" "NONE" "$got"

# === bad invocation ===
exit_code=0
bash "$LIB" patterns >/dev/null 2>&1 || exit_code=$?
check "P: patterns missing args rejected" "1" "$exit_code"

exit_code=0
bash "$LIB" bogus >/dev/null 2>&1 || exit_code=$?
check "Q: unknown subcommand rejected" "1" "$exit_code"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
