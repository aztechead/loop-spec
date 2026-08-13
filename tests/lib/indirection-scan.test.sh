#!/usr/bin/env bash
# Test suite for lib/indirection-scan.sh
#
# The probe's contract runs both ways: it must catch the one-caller wrapper the
# ladder's rung 1 exists to prevent, and it must stay silent on the four things
# that look identical to a naive matcher -- decomposition (a long function with
# one caller), an exported symbol whose callers are elsewhere, dead code, and a
# helper that predates the diff.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROBE="$REPO_ROOT/lib/indirection-scan.sh"
WORK="${TMPDIR:-/tmp}/indirection-scan-test-$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

fixture() {
  local name="$1"
  rm -rf "${WORK:?}/$name"
  mkdir -p "$WORK/$name"
  cd "$WORK/$name" || exit 2
  git init -q .
  git config user.email t@t.t
  git config user.name t
}

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

echo "=== indirection-scan.sh tests ==="

# --- the wrapper with one caller ---
fixture wrapper
cat > checkout.js <<'EOF'
const { db } = require('./db')

function buildCartKey(cartId) {
  return `carts:${cartId}`
}

function checkout(cartId) {
  const row = db.get('carts', buildCartKey(cartId))
  if (!row) return null
  return row
}

module.exports = { checkout }
EOF
git add -A && git commit -qm base
check "a: a one-caller wrapper is caught" 1 "single-caller=buildCartKey" scan checkout.js
check "b: the finding carries the definition line" 1 "^checkout\.js:3:" scan checkout.js
check "c: the finding names the call site" 1 "called once at line 8" scan checkout.js
check "d: findings are counted with the body bound" 1 "1 finding\(s\) defs=[0-9]+ body<=5" scan checkout.js

# --- decomposition is not indirection ---
#
# A long function with one caller is what functions are FOR. Only the trivial
# pass-through is the smell, so the body bound is load-bearing.
fixture long
cat > report.js <<'EOF'
const { db } = require('./db')

function renderReport(rows) {
  const header = rows[0]
  const body = rows.slice(1)
  const widths = header.map((h) => h.length)
  const lines = []
  lines.push(header.join(' | '))
  lines.push(widths.map((w) => '-'.repeat(w)).join('-+-'))
  for (const row of body) {
    lines.push(row.join(' | '))
  }
  return lines.join('\n')
}

function main() {
  return renderReport(db.all('rows'))
}

module.exports = { main }
EOF
git add -A && git commit -qm base
check "e: a long single-caller function is decomposition, not a wrapper" 0 \
  "indirection-scan: clean" scan report.js

# --- an exported symbol has callers this probe cannot see ---
fixture exported
cat > api.js <<'EOF'
const { db } = require('./db')

export function loadOne(id) {
  return db.get('t', id)
}

function main() {
  return loadOne('x')
}

module.exports = { main }
EOF
git add -A && git commit -qm base
check "f: an exported one-caller symbol is not reported" 0 "indirection-scan: clean" scan api.js

fixture exported-py
cat > api.py <<'EOF'
__all__ = ["load_one"]


def load_one(key):
    return key


def main():
    return load_one("x")
EOF
git add -A && git commit -qm base
check "g: a python __all__ export is not reported" 0 "indirection-scan: clean" scan api.py

# Go spells "exported" with a capital, and the probe must read that rather than
# looking for a keyword that does not exist in the language.
fixture exported-go
cat > store.go <<'EOF'
package store

func LoadOne(id string) string {
	return id
}

func main() string {
	return LoadOne("x")
}
EOF
git add -A && git commit -qm base
check "h: a Go capitalised name is treated as exported" 0 "indirection-scan: clean" scan store.go

# --- zero callers is dead code, a different finding ---
fixture dead
cat > dead.js <<'EOF'
const { db } = require('./db')

function neverCalled(id) {
  return id
}

function main() {
  return db.all('rows')
}

module.exports = { main }
EOF
git add -A && git commit -qm base
check "i: an uncalled definition is not a single-caller finding" 0 \
  "indirection-scan: clean" scan dead.js

# --- two callers is reuse working ---
fixture reused
cat > reused.js <<'EOF'
const { db } = require('./db')

function keyFor(id) {
  return `k:${id}`
}

function readOne(id) {
  return db.get(keyFor(id))
}

function readTwo(id) {
  return db.peek(keyFor(id))
}

module.exports = { readOne, readTwo }
EOF
git add -A && git commit -qm base
check "j: a twice-called helper is reuse, not indirection" 0 "indirection-scan: clean" scan reused.js

# --- a shell heredoc holds another language ---
#
# This repo's scripts carry whole Python programs and fixtures inside heredocs.
# Their definitions belong to that program, not to the shell file wrapping it.
fixture heredoc
cat > tool.sh <<'OUTER'
#!/usr/bin/env bash
set -euo pipefail

run() {
  python3 - <<'PY'
def only_here(path):
    return path
print(only_here("x"))
PY
}

run
run
OUTER
git add -A && git commit -qm base
check "k: definitions inside a heredoc are not the shell file's" 0 \
  "indirection-scan: clean" scan tool.sh

# --- an unmeasurable body is skipped rather than guessed ---
#
# An expression-bodied arrow has no brace to close on. Sized by its opening line
# a twenty-line string builder measures as nought lines and reports as a trivial
# wrapper, so it is answered "unknown" and skipped.
fixture arrow
cat > build.js <<'EOF'
const prefix = 'x'

const buildDirective = (dir) =>
  'LINE ONE of a long directive that goes on ' +
  'LINE TWO continuing the same string ' +
  'LINE THREE still going ' +
  'LINE FOUR and more ' +
  'LINE FIVE and more ' +
  'LINE SIX ending at last ' + dir

function main() {
  return buildDirective(prefix)
}

module.exports = { main }
EOF
git add -A && git commit -qm base
check "l: an unsizable arrow body is skipped, not called a wrapper" 0 \
  "indirection-scan: clean" scan build.js

# --- diff mode reports only what the change added ---
fixture diffmode
cat > app.js <<'EOF'
const { db } = require('./db')

function keyFor(id) {
  return `k:${id}`
}

function readOne(id) {
  return db.get(keyFor(id))
}

module.exports = { readOne }
EOF
git add -A && git commit -qm base
printf '\n// an unrelated edit\n' >> app.js
git add -A && git commit -qm touch
check "m: a wrapper predating the diff is not this diff's finding" 0 \
  "indirection-scan: clean" diff HEAD~1 HEAD
check "n: scan mode still reports the standing wrapper" 1 "single-caller=keyFor" scan app.js

cat > added.js <<'EOF'
const { db } = require('./db')

function newKeyFor(id) {
  return `n:${id}`
}

function readNew(id) {
  return db.get(newKeyFor(id))
}

module.exports = { readNew }
EOF
git add -A && git commit -qm add
check "o: a wrapper the diff added is caught" 1 "single-caller=newKeyFor" diff HEAD~1 HEAD
check "p: diff mode is clean on an empty diff" 0 "indirection-scan: clean" diff HEAD HEAD

# --- the body bound is the operator's ---
fixture bound
cat > wide.js <<'EOF'
const { db } = require('./db')

function midSized(id) {
  const a = db.get('a', id)
  const b = db.get('b', id)
  const c = db.get('c', id)
  const d = db.get('d', id)
  const e = db.get('e', id)
  const f = db.get('f', id)
  return [a, b, c, d, e, f]
}

function main() {
  return midSized('x')
}

module.exports = { main }
EOF
git add -A && git commit -qm base
check "q: a body over the bound is left alone" 0 "indirection-scan: clean" scan wide.js
out="$(LOOP_SPEC_INDIRECTION_MAX_BODY=9 bash "$PROBE" scan wide.js 2>&1)"; rc=$?
if [[ "$rc" -eq 1 ]] && grep -q "body<=9" <<<"$out"; then
  echo "PASS: r: the body bound is raisable"; PASS=$((PASS+1))
else
  echo "FAIL: r: the body-bound override did not take (exit $rc)"; echo "$out" | sed 's/^/      /'
  FAIL=$((FAIL+1))
fi
out="$(LOOP_SPEC_INDIRECTION_MAX_BODY=nonsense bash "$PROBE" scan wide.js 2>&1)"; rc=$?
if [[ "$rc" -eq 0 ]] && grep -q "body<=5" <<<"$out"; then
  echo "PASS: s: an unreadable bound falls back to the default"; PASS=$((PASS+1))
else
  echo "FAIL: s: bad override did not fall back (exit $rc)"; echo "$out" | sed 's/^/      /'
  FAIL=$((FAIL+1))
fi

# --- usage ---
cd "$WORK" || exit 2
check "t: bad mode exits 2" 2 "usage: indirection-scan.sh" bogus wide.js
check "u: scan with no file exits 2" 2 "usage: indirection-scan.sh scan" scan
check "v: scan of a missing file exits 2" 2 "cannot read" scan absent.js

if [[ -x "$PROBE" ]]; then
  echo "PASS: w: probe is executable"; PASS=$((PASS+1))
else
  echo "FAIL: w: probe is not executable"; FAIL=$((FAIL+1))
fi

cd "$REPO_ROOT" || exit 2
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "PASS: indirection-scan.sh catches one-caller wrappers and leaves decomposition alone"
