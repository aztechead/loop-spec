#!/usr/bin/env bash
# Tests for lib/review-trail.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/lib/review-trail.sh"
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

contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected output to contain '$needle', got '$haystack')"
    ((FAIL++)) || true
  fi
}

absent() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected output NOT to contain '$needle', got '$haystack')"
    ((FAIL++)) || true
  fi
}

# Usage guards need no repo.
rc=0; bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
check "A: no subcommand is a usage error" "2" "$rc"
rc=0; bash "$SCRIPT" bogus main >/dev/null 2>&1 || rc=$?
check "B: unknown subcommand is a usage error" "2" "$rc"

WORK="${TMPDIR:-/tmp}/loop-spec-review-trail.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"
cd "$WORK"
git init -q
git config user.email t@example.com
git config user.name Test
mkdir -p src tests docs
printf 'line\n%.0s' {1..40} > src/app.js
printf 'base\n' > tests/app.test.js
printf 'base\n' > docs/guide.md
git add -A
git commit -qm base
BASE="$(git rev-parse HEAD)"

# A mixed change: source plus its test plus a doc.
printf 'changed\n' >> src/app.js
printf 'more\n' >> tests/app.test.js
printf 'more\n' >> docs/guide.md
git add -A
git commit -qm change

out="$(bash "$SCRIPT" surface "$BASE" HEAD)"
contains "C: source file classified core" "role=core path=src/app.js" "$out"
contains "D: test file classified peripheral" "role=peripheral path=tests/app.test.js" "$out"
contains "E: doc classified peripheral" "role=peripheral path=docs/guide.md" "$out"
contains "F: anchor points at the first added line" "path=src/app.js anchor=41" "$out"
contains "G: summary counts both roles" "surface=3 core=1 peripheral=2" "$out"

# Core files sort ahead of peripherals so the caller reads the change first.
first_role="$(printf '%s\n' "$out" | head -1 | sed 's/ .*//')"
check "H: core sorts first" "role=core" "$first_role"

# A clean trail: every core file has a stop, framing is short, peripherals last.
cat > TRAIL.md <<'EOF'
## Suggested review order

**Behavior change**

- entry point for the new branch
  `src/app.js:41`

**Peripherals**

- covers the new branch
  `tests/app.test.js:2`
- records the flag
  `docs/guide.md:2`
EOF
rc=0; out="$(bash "$SCRIPT" lint TRAIL.md "$BASE" HEAD)" || rc=$?
check "I: complete trail lints clean" "0" "$rc"
contains "J: lint reports what it checked" "stops=3 core_files=1 findings=0" "$out"

# Dropping the only core stop must fail: a guide that omits the change is worse
# than none, because it reads as complete.
cat > MISSING.md <<'EOF'
- covers the new branch
  `tests/app.test.js:2`
EOF
rc=0; out="$(bash "$SCRIPT" lint MISSING.md "$BASE" HEAD)" || rc=$?
check "K: uncovered core file fails the lint" "1" "$rc"
contains "L: uncovered finding names the file" "finding=uncovered path=src/app.js" "$out"

# Ordering is the product: peripherals before the last core stop defeat the trail.
cat > ORDER.md <<'EOF'
- covers the new branch
  `tests/app.test.js:2`
- entry point
  `src/app.js:41`
- records the flag
  `docs/guide.md:2`
EOF
rc=0; out="$(bash "$SCRIPT" lint ORDER.md "$BASE" HEAD)" || rc=$?
check "M: peripheral before core fails the lint" "1" "$rc"
contains "N: ordering finding names the early stop" "finding=peripheral-early path=tests/app.test.js:2" "$out"
absent "O: peripheral after the last core stop is not flagged" "peripheral-early path=docs/guide.md" "$out"

# Stops must resolve: a path outside the diff and a line past EOF are both facts.
cat > BOGUS.md <<'EOF'
- entry point
  `src/app.js:41`
- stale reference
  `src/gone.js:3`
- past the end
  `src/app.js:9999`
EOF
rc=0; out="$(bash "$SCRIPT" lint BOGUS.md "$BASE" HEAD)" || rc=$?
check "P: unresolvable stops fail the lint" "1" "$rc"
contains "Q: path outside the change is reported" "finding=unknown-path path=src/gone.js" "$out"
contains "R: anchor past EOF is reported" "finding=bad-anchor path=src/app.js:9999" "$out"

# Framing is capped so a stop stays scannable.
cat > LONG.md <<'EOF'
- this framing runs on well past the point where a reviewer scanning the list would still call it a single glanceable phrase
  `src/app.js:41`
EOF
rc=0; out="$(bash "$SCRIPT" lint LONG.md "$BASE" HEAD)" || rc=$?
check "S: over-long framing fails the lint" "1" "$rc"
contains "T: framing finding reports the measured length" "finding=long-framing path=src/app.js:41" "$out"

cat > EMPTY.md <<'EOF'
No stops here at all.
EOF
rc=0; out="$(bash "$SCRIPT" lint EMPTY.md "$BASE" HEAD)" || rc=$?
check "U: trail with no stops fails the lint" "1" "$rc"
contains "V: empty finding is explicit" "finding=empty" "$out"

# A markdown-only repo (this plugin is one) must not read as an empty change.
git checkout -q -b docsonly "$BASE"
printf 'more\n' >> docs/guide.md
git add -A
git commit -qm docs
out="$(bash "$SCRIPT" surface "$BASE" HEAD)"
contains "W: all-peripheral change withholds the classification" \
  "classification withheld" "$out"
contains "X: withheld classification promotes the files to core" "role=core path=docs/guide.md" "$out"

# No change at all is a distinct, non-crashing answer.
rc=0; out="$(bash "$SCRIPT" surface HEAD HEAD)" || rc=$?
check "Y: empty diff exits 1" "1" "$rc"
contains "Z: empty diff explains itself" "surface=0 reason=no changed file" "$out"

# A rename must not read as a deleted file plus an uncovered new one.
git checkout -q -b renamed "$BASE"
git mv src/app.js src/renamed.js
git commit -qm rename
out="$(bash "$SCRIPT" surface "$BASE" HEAD)"
contains "AA: rename records the post-image path" "path=src/renamed.js" "$out"

# A cross-directory rename carries `{old => new}` braces in numstat; the post-image
# path must survive that, or the moved file reads as uncovered.
git checkout -q -b moved "$BASE"
mkdir -p src/nested
git mv src/app.js src/nested/app.js
git commit -qm crossdir
out="$(bash "$SCRIPT" surface "$BASE" HEAD)"
contains "AD: cross-directory rename resolves to the post-image path" \
  "path=src/nested/app.js" "$out"
absent "AE: the brace form never leaks into a path" "{" "$out"

# An unreadable trail is an operator error, not a finding.
rc=0; bash "$SCRIPT" lint /nonexistent/trail.md "$BASE" HEAD >/dev/null 2>&1 || rc=$?
check "AB: unreadable trail exits 2" "2" "$rc"

# A bad ref is a git failure, never a silent clean pass.
rc=0; bash "$SCRIPT" surface no-such-ref HEAD >/dev/null 2>&1 || rc=$?
check "AC: unknown ref exits 2" "2" "$rc"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
