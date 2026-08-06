#!/usr/bin/env bash
# Tests for lib/verification-gap-scan.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/lib/verification-gap-scan.sh"
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
    echo "FAIL: $name (expected output to contain '$needle', got '$haystack')"; ((FAIL++)) || true
  fi
}

absent() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name (expected output NOT to contain '$needle', got '$haystack')"; ((FAIL++)) || true
  fi
}

rc=0; bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
check "A: no ref is a usage error" "2" "$rc"

WORK="${TMPDIR:-/tmp}/loop-spec-vgap.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"
cd "$WORK"
git init -q
git config user.email t@example.com
git config user.name Test
mkdir -p src tests
printf 'placeholder\n' > src/app.js
printf 'placeholder\n' > tests/app.test.js
git add -A
git commit -qm base
BASE="$(git rev-parse HEAD)"

cat > src/app.js <<'EOF'
export function computeDiscount(order) {
  return order.total * 0.1;
}
export function silentlyAdded(order) {
  return order.total;
}
EOF
cat > tests/app.test.js <<'EOF'
import { computeDiscount } from '../src/app.js';
test('computeDiscount', () => { expect(computeDiscount({total: 10})).toBe(1); });
EOF
git add -A
git commit -qm change

out="$(bash "$SCRIPT" "$BASE" HEAD)"
contains "B: symbol named by a test reports covered=yes" \
  "symbol=computeDiscount path=src/app.js covered=yes" "$out"
contains "C: covered answer cites the test file that names it" "tests/app.test.js" "$out"
contains "D: symbol no test names reports covered=no" \
  "symbol=silentlyAdded path=src/app.js covered=no" "$out"
contains "E: uncovered answer reports the corpus it searched" "named by 0 of 1 test files" "$out"
contains "F: summary counts the uncovered symbols" "scanned=2 uncovered=1" "$out"

# A test added by this same diff is the evidence that closes the gap, so the
# corpus must be the post-change tree.
git checkout -q -b withtest "$BASE"
cat > src/app.js <<'EOF'
export function freshSymbol(order) {
  return order.total;
}
EOF
cat > tests/app.test.js <<'EOF'
import { freshSymbol } from '../src/app.js';
test('freshSymbol', () => { expect(freshSymbol({total: 1})).toBe(1); });
EOF
git add -A
git commit -qm both
out="$(bash "$SCRIPT" "$BASE" HEAD)"
contains "G: a test added in the same change counts as coverage" \
  "symbol=freshSymbol path=src/app.js covered=yes" "$out"

# Definitions inside the test tree are not the subject of the question.
git checkout -q -b testonly "$BASE"
cat > tests/app.test.js <<'EOF'
function helperDefinedInTest() { return 1; }
test('x', () => { expect(helperDefinedInTest()).toBe(1); });
EOF
git add -A
git commit -qm testonly
rc=0; out="$(bash "$SCRIPT" "$BASE" HEAD)" || rc=$?
check "H: a change touching only tests has nothing to answer" "1" "$rc"
absent "I: test-tree definitions are not scanned" "helperDefinedInTest" "$out"
contains "J: the empty answer explains itself" "no definition changed in a non-test file" "$out"

# Bash function definitions are in scope -- this plugin's own code is bash.
git checkout -q -b bashy "$BASE"
mkdir -p lib
cat > lib/tool.sh <<'EOF'
resolve_target() {
  echo "$1"
}
EOF
git add -A
git commit -qm bashy
out="$(bash "$SCRIPT" "$BASE" HEAD)"
contains "K: bash function definitions are extracted" "symbol=resolve_target path=lib/tool.sh" "$out"

# Names shared across half a codebase answer nothing; they are skipped by design.
git checkout -q -b noisy "$BASE"
cat > src/app.js <<'EOF'
export function main() { return 1; }
export function run() { return 2; }
EOF
git add -A
git commit -qm noisy
rc=0; out="$(bash "$SCRIPT" "$BASE" HEAD)" || rc=$?
check "L: ubiquitous names are not reported as symbols" "1" "$rc"

# Regression: running the probe on its own diff answered covered=yes for `read`
# and `report` purely because unrelated tests use the words.
git checkout -q -b generic "$BASE"
cat > src/app.js <<'EOF'
export function read(path) { return path; }
export function report(finding) { return finding; }
EOF
git add -A
git commit -qm generic
rc=0; out="$(bash "$SCRIPT" "$BASE" HEAD)" || rc=$?
check "L2: word-like generic names are skipped too" "1" "$rc"
absent "L3: no coverage verdict is invented for a generic name" "covered=yes" "$out"

# A pure edit with no definition change is a distinct, non-crashing answer.
git checkout -q -b prose "$BASE"
printf 'just prose\n' > src/app.js
git add -A
git commit -qm prose
rc=0; out="$(bash "$SCRIPT" "$BASE" HEAD)" || rc=$?
check "M: no definition changed exits 1" "1" "$rc"

rc=0; bash "$SCRIPT" no-such-ref HEAD >/dev/null 2>&1 || rc=$?
check "N: unknown ref exits 2" "2" "$rc"

# A miss against a truncated corpus is not evidence of absence. The scan must say
# unknown rather than hand the reviewer a finding the search never earned.
git checkout -q -b bigcorpus "$BASE"
mkdir -p tests/many
for i in $(seq 1 12); do printf 'placeholder %s\n' "$i" > "tests/many/t$i.test.js"; done
cat > src/app.js <<'EOF'
export function needleSymbol(order) { return order; }
EOF
git add -A
git commit -qm bigcorpus
out="$(LOOP_SPEC_VGAP_MAX_FILES=3 bash "$SCRIPT" "$BASE" HEAD)"
contains "O: a miss against a truncated corpus is unknown, not no" \
  "symbol=needleSymbol path=src/app.js covered=unknown" "$out"
contains "P: the unknown answer says the search was partial" "absence not established" "$out"
contains "Q: the summary reports the truncation" "(truncated from" "$out"
absent "R: a truncated search never claims covered=no" "covered=no" "$out"

# Untruncated, the same change answers definitively.
out="$(bash "$SCRIPT" "$BASE" HEAD)"
contains "S: a full corpus answers covered=no" "symbol=needleSymbol path=src/app.js covered=no" "$out"
absent "T: a full corpus reports no truncation" "truncated from" "$out"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
