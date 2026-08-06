#!/usr/bin/env bash
# Tests for lib/map-trust.sh
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/lib/map-trust.sh"
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

contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name (no '$needle' in output)"; ((FAIL++)) || true
  fi
}

WORK="${TMPDIR:-/tmp}/loop-spec-map-trust.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/map"
cd "$WORK"

# Usage errors are loud, never a silent no-op.
rc=0; bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
check "A: no subcommand is a usage error" "2" "$rc"
rc=0; bash "$SCRIPT" mark map/ARCH.md trusted >/dev/null 2>&1 || rc=$?
check "B: unknown trust level is a usage error" "2" "$rc"
rc=0; bash "$SCRIPT" mark map/MISSING.md generated >/dev/null 2>&1 || rc=$?
check "C: marking a missing document is an error" "2" "$rc"
rc=0; bash "$SCRIPT" mark map/ARCH.md verified >/dev/null 2>&1 || rc=$?
check "D: verified without --by is a usage error" "2" "$rc"

printf '# ARCH\n\nModules and their edges.\n' > map/ARCH.md

# A doc with no frontmatter reads unmarked -- the migration state, never an error.
out="$(bash "$SCRIPT" read map/ARCH.md)"
contains "E: no frontmatter reads unmarked" "doc=map/ARCH.md trust=unmarked" "$out"
contains "F: read reports the split" "docs=1 verified=0 generated=0 unmarked=1" "$out"

# Marking generated creates the frontmatter block and keeps the body intact.
out="$(bash "$SCRIPT" mark map/ARCH.md generated)"
contains "G: mark reports what it wrote" "doc=map/ARCH.md trust=generated" "$out"
check "H: frontmatter opens the file" "---" "$(head -1 map/ARCH.md)"
contains "I: the body survives the mark" "Modules and their edges." "$(cat map/ARCH.md)"
out="$(bash "$SCRIPT" read map/ARCH.md)"
contains "J: generated reads back" "trust=generated verified_at=- verified_by=-" "$out"

# Promotion records who ratified and when.
out="$(bash "$SCRIPT" mark map/ARCH.md verified --by operator)"
contains "K: promotion reports itself" "trust=verified" "$out"
out="$(bash "$SCRIPT" read map/ARCH.md)"
contains "L: verified_by records the ratifier" "verified_by=operator" "$out"
check "M: verified_at is a date" "1" \
  "$(bash "$SCRIPT" read map/ARCH.md | grep -cE 'verified_at=[0-9]{4}-[0-9]{2}-[0-9]{2}')"

# Regeneration voids a ratification: the human confirmed the old prose, not the new.
bash "$SCRIPT" mark map/ARCH.md generated >/dev/null
out="$(bash "$SCRIPT" read map/ARCH.md)"
contains "N: re-marking generated drops the ratification" \
  "trust=generated verified_at=- verified_by=-" "$out"
check "O: no stale verified_by line survives" "0" "$(grep -c 'verified_by' map/ARCH.md)"

# Re-marking is idempotent on the block: one frontmatter, not one per mark.
bash "$SCRIPT" mark map/ARCH.md generated >/dev/null
check "P: exactly one frontmatter open+close pair" "2" "$(grep -cx -- '---' map/ARCH.md)"

# Foreign frontmatter keys are someone else's contract and survive untouched.
printf -- '---\nowner: platform\n---\n\n# TECH\n\nStack.\n' > map/TECH.md
bash "$SCRIPT" mark map/TECH.md generated >/dev/null
contains "Q: unmanaged keys survive a mark" "owner: platform" "$(cat map/TECH.md)"
out="$(bash "$SCRIPT" read map/TECH.md)"
contains "R: trust lands beside the unmanaged keys" "trust=generated" "$out"

# read with no paths walks the map directory.
out="$(LOOP_SPEC_MAP_DIR=map bash "$SCRIPT" read)"
contains "S: bare read covers the whole map dir" "docs=2" "$out"
rc=0; LOOP_SPEC_MAP_DIR=/nonexistent bash "$SCRIPT" read >/dev/null 2>&1 || rc=$?
check "T: a missing map dir is an error, not an empty pass" "2" "$rc"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
