#!/usr/bin/env bash
# Test suite for lib/house-style.sh
#
# The probe's contract: it reports an ANSWER and the evidence behind it, it
# answers a not-yet-created file from that file's future neighbors, and it says
# "unknown" rather than inventing a convention nobody demonstrated.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROBE="$REPO_ROOT/lib/house-style.sh"
WORK="${TMPDIR:-/tmp}/house-style-test-$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

check() {
  local name="$1" want_exit="$2" pattern="$3"; shift 3
  local out rc
  out="$(bash "$PROBE" "$@" 2>&1)"; rc=$?
  if [[ "$rc" -eq "$want_exit" ]] && grep -qE "$pattern" <<<"$out"; then
    echo "PASS: $name"; PASS=$((PASS+1))
  else
    echo "FAIL: $name (exit $rc, wanted $want_exit; looked for /$pattern/)"
    echo "$out" | sed 's/^/      /'
    FAIL=$((FAIL+1))
  fi
}

echo "=== house-style.sh tests ==="

# --- a heavily commented, snake_case, 4-space Python module ---
mkdir -p "$WORK/heavy"
{
  echo "import os"
  for i in $(seq 1 12); do
    echo ""
    echo "# why this exists: reason number $i for the reader"
    echo "# a second line of the same explanation"
    echo "def read_thing_$i(path):"
    echo "    return os.stat(path)"
  done
} > "$WORK/heavy/mod.py"

check "a: heavy commenting is reported as heavy" 0 "comment_density=heavy" probe "$WORK/heavy/mod.py"
check "b: density carries its evidence" 0 "reason=[0-9]+/[0-9]+ comment lines" probe "$WORK/heavy/mod.py"
check "c: snake_case definitions detected" 0 "naming=snake_case" probe "$WORK/heavy/mod.py"
check "d: 4-space indent detected" 0 "indent=spaces:4" probe "$WORK/heavy/mod.py"
check "e: doc comments above definitions detected" 0 "doc_comments=yes" probe "$WORK/heavy/mod.py"

# --- a sparse, camelCase, 2-space TypeScript module ---
mkdir -p "$WORK/sparse"
{
  echo "export const base = 1"
  for i in $(seq 1 12); do
    echo "export function readThing$i(path: string) {"
    echo "  return path.length + $i"
    echo "}"
  done
} > "$WORK/sparse/mod.ts"

check "f: uncommented code is reported as sparse" 0 "comment_density=sparse" probe "$WORK/sparse/mod.ts"
check "g: camelCase definitions detected" 0 "naming=camelCase" probe "$WORK/sparse/mod.ts"
check "h: 2-space indent detected" 0 "indent=spaces:2" probe "$WORK/sparse/mod.ts"
check "i: absent doc comments detected" 0 "doc_comments=no" probe "$WORK/sparse/mod.ts"

# --- the seam that matters: a file that does not exist yet is answered by its
#     future neighbors, so a new file is written to look like the ones beside it.
check "j: missing target falls back to sibling files" 0 "comment_density=sparse" \
  probe "$WORK/sparse/brand-new.ts"
check "k: fallback names the files it sampled" 0 "sample=1 files: .*mod\.ts" \
  probe "$WORK/sparse/brand-new.ts"
check "l: only same-extension siblings are sampled" 0 "sample=1 files: .*mod\.py" \
  probe "$WORK/heavy/brand-new.py"

# --- tab-indented source ---
mkdir -p "$WORK/tabs"
{
  echo "package main"
  for i in $(seq 1 8); do
    printf 'func readThing%s() int {\n\treturn %s\n}\n' "$i" "$i"
  done
} > "$WORK/tabs/main.go"
check "m: tab indentation detected" 0 "indent=tabs" probe "$WORK/tabs/main.go"

# --- fail safe: no sample means unknown, never a guessed convention ---
check "n: unreachable target reports sample=none" 1 "sample=none" probe "$WORK/nope/nope.py"
check "o: unknown is explained, not silent" 1 "reason=no readable file or neighbor" \
  probe "$WORK/nope/nope.py"

# --- too little evidence yields unknown rather than a made-up answer ---
mkdir -p "$WORK/tiny"
printf 'x = 1\n' > "$WORK/tiny/a.py"
check "p: a near-empty sample with no neighbors reports unknown density" 0 "comment_density=unknown" \
  probe "$WORK/tiny/a.py"

# A file that exists but is three lines long demonstrates nothing -- the module
# around it demonstrates everything. This is the state right after an implementer
# creates a file and re-probes it, so shrugging there would waste the probe.
cp "$WORK/heavy/mod.py" "$WORK/tiny/rich.py"
check "q: a thin existing target widens to its neighbors" 0 "comment_density=heavy" \
  probe "$WORK/tiny/a.py"
check "r: widening names the neighbor it borrowed from" 0 "sample=2 files:.*rich\.py" \
  probe "$WORK/tiny/a.py"

# Widening is a fallback, never the default: a target with enough evidence of its
# own is answered by itself, so a file is never judged against its siblings' style.
check "s: a rich target is not widened" 0 "sample=1 files: .*mod\.py" \
  probe "$WORK/heavy/mod.py"

# --- a directory target samples the directory ---
check "t: directory target is sampled" 0 "sample=1 files" probe "$WORK/heavy"

# --- usage ---
check "u: bad invocation exits 2" 2 "usage: house-style.sh" bogus
check "v: probe with no path exits 2" 2 "usage: house-style.sh" probe

# --- the probe is executable and runs on this repo's own tree ---
if [[ -x "$PROBE" ]]; then
  echo "PASS: w: probe is executable"; PASS=$((PASS+1))
else
  echo "FAIL: w: probe is not executable"; FAIL=$((FAIL+1))
fi
check "x: probes this repo's own lib without error" 0 "sample=[0-9]+ files" \
  probe "$REPO_ROOT/lib/security-signal.sh"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "PASS: house-style.sh reports measured conventions and fails safe when unknown"
