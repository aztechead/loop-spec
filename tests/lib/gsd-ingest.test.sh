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

# === codebase: no .planning/codebase ===
got=$(bash "$LIB" codebase)
check "A: codebase NONE when .planning/codebase missing" "NONE" "$got"

# === codebase: full GSD inventory present ===
mkdir -p .planning/codebase
echo "stack-content" > .planning/codebase/STACK.md
echo "integ-content" > .planning/codebase/INTEGRATIONS.md
echo "arch-content" > .planning/codebase/ARCHITECTURE.md
echo "struct-content" > .planning/codebase/STRUCTURE.md
echo "conv-content" > .planning/codebase/CONVENTIONS.md
echo "test-content" > .planning/codebase/TESTING.md
echo "concerns-content" > .planning/codebase/CONCERNS.md

out=$(bash "$LIB" codebase)
check "B: TECH ingested" "INGESTED TECH" "$(echo "$out" | grep TECH)"
check "C: ARCH ingested" "INGESTED ARCH" "$(echo "$out" | grep ARCH)"
check "D: QUALITY ingested" "INGESTED QUALITY" "$(echo "$out" | grep QUALITY)"
check "E: CONCERNS ingested" "INGESTED CONCERNS" "$(echo "$out" | grep CONCERNS)"

# Verify TECH.md contains both source contents
[[ -f docs/loop-spec/codebase/TECH.md ]] && tech=$(cat docs/loop-spec/codebase/TECH.md) || tech=""
echo "$tech" | grep -q "stack-content" && a=ok || a=bad
echo "$tech" | grep -q "integ-content" && b=ok || b=bad
check "F: TECH.md contains STACK content" "ok" "$a"
check "G: TECH.md contains INTEGRATIONS content" "ok" "$b"
echo "$tech" | grep -q "Imported from GSD" && c=ok || c=bad
check "H: TECH.md contains import header" "ok" "$c"

# === codebase: partial inventory (only one source for ARCH) ===
rm -rf docs .planning
mkdir -p .planning/codebase
echo "arch-only" > .planning/codebase/ARCHITECTURE.md  # no STRUCTURE.md
out=$(bash "$LIB" codebase)
check "I: TECH skipped (no source)" "SKIPPED TECH (no source)" "$(echo "$out" | grep TECH)"
check "J: ARCH ingested with single source" "INGESTED ARCH" "$(echo "$out" | grep ARCH)"
arch=$(cat docs/loop-spec/codebase/ARCH.md)
echo "$arch" | grep -q "arch-only" && d=ok || d=bad
check "K: ARCH.md contains the single source content" "ok" "$d"

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
