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

# --- compare: the probe must name a deviation, not just describe a pool ---
#
# `probe` folds the target into its own sample, so a file breaking every
# convention around it reports as the convention: the deviation averages into its
# own baseline. `compare` holds the file out and answers the question the
# directive actually asks -- does this read like its neighbors?
CMP="$WORK/compare"
mkdir -p "$CMP/src"
cat > "$CMP/src/users.js" <<'EOF'
const { db } = require('./db')

function loadUser(id) {
  const row = db.get('users', id)
  if (!row) return null
  return { id: row.id, name: row.name }
}

function saveUser(user) {
  if (!user.id) return null
  db.put('users', user.id, user)
  return user
}

module.exports = { loadUser, saveUser }
EOF
cat > "$CMP/src/carts.js" <<'EOF'
const { db } = require('./db')

function loadCart(id) {
  const row = db.get('carts', id)
  if (!row) return null
  return { id: row.id, items: row.items }
}

function saveCart(cart) {
  if (!cart.id) return null
  db.put('carts', cart.id, cart)
  return cart
}

module.exports = { loadCart, saveCart }
EOF
# Correct, and nothing like its neighbours: ESM, 4-space, snake_case.
cat > "$CMP/src/orders.js" <<'EOF'
import { db } from "./db";

export function load_order(id) {
    const row = db.get("orders", id);
    if (!row) {
        return null;
    }
    return { id: row.id, total: row.total };
}
EOF

check "u1: a deviating file is caught" 1 "deviation=" compare "$CMP/src/orders.js"
check "u2: naming crossover is named with the offending identifier" 1 \
  "deviation=naming.*load_order" compare "$CMP/src/orders.js"
check "u3: indent deviation is measured both ways" 1 \
  "deviation=indent: file is spaces:4.*neighbors are spaces:2" compare "$CMP/src/orders.js"
check "u4: module system is measured" 1 "deviation=module_style.*esm.*commonjs" \
  compare "$CMP/src/orders.js"
check "u5: a conforming file stays silent" 0 "matches its neighbors" \
  compare "$CMP/src/carts.js"

# A single-word name is valid camelCase and valid snake_case alike, so it must
# never be reported -- this is the false positive that makes a naming lint noise.
cat > "$CMP/src/checkout.js" <<'EOF'
const { db } = require('./db')

function checkout(id) {
  const row = db.get('carts', id)
  if (!row) return null
  return row
}

module.exports = { checkout }
EOF
check "u6: a single-word name is not a naming deviation" 0 "matches its neighbors" \
  compare "$CMP/src/checkout.js"

# Conventions are language-scoped. Judging a .js file against the .sh files beside
# it reports camelCase as a deviation from snake_case -- two languages, not a
# violation.
cat > "$CMP/src/tool.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

run_tool() {
  local target="$1"
  printf '%s\n' "$target"
}

emit_report() {
  local path="$1"
  printf 'report %s\n' "$path"
}
EOF
check "u7: a baseline never mixes languages" 0 "matches its neighbors" \
  compare "$CMP/src/users.js"

# A shell heredoc or multi-line single-quoted string carries another language.
# Measuring the shell file's conventions from that text answers about jq or
# Python instead, and reports their naming as the shell file's.
cat > "$CMP/src/embed.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

emit_json() {
  local feats="$1"
  jq -cn --argjson feats "$feats" '
  def featsWithGap(g): [$feats[] | select(.gaps | index(g)) | .slug];
  {gaps: featsWithGap("plan")}'
}

read_config() {
  python3 - <<'PY'
def loadUserConfig(path):
    return open(path).read()
PY
}
EOF
check "u8: embedded languages do not set the shell file's conventions" 0 \
  "matches its neighbors" compare "$CMP/src/embed.sh"

# An apostrophe in an English comment is not a string delimiter. Counted as one it
# opens a quote that never closes, and the rest of the file is silently swallowed --
# which showed up as a 4-space indent finding on a 2-space file, measured from the
# only lines that survived.
cat > "$CMP/src/prose.sh" <<'EOF'
#!/usr/bin/env bash
# Why: the language's own tooling reports this, and it isn't worth duplicating.
# A second line with the author's apostrophe and the reader's expectations.
set -euo pipefail

emit_one() {
  local target="$1"
  printf '%s\n' "$target"
}

emit_two() {
  local target="$1"
  printf 'two %s\n' "$target"
}
EOF
check "u8b: an apostrophe in a comment does not swallow the file" 0 \
  "matches its neighbors" compare "$CMP/src/prose.sh"

# Nothing to compare against is an answer, not a finding.
mkdir -p "$CMP/lonely"
printf 'const a = 1\n' > "$CMP/lonely/only.js"
check "u9: no neighbour means no deviation claimed" 0 "baseline=0 files" \
  compare "$CMP/lonely/only.js"

# --- usage ---
check "u: bad invocation exits 2" 2 "usage: house-style.sh" bogus
check "v: probe with no path exits 2" 2 "usage: house-style.sh" probe
check "v2: compare with no path exits 2" 2 "usage: house-style.sh compare" compare
check "v3: compare of a missing file exits 2" 2 "no readable target" \
  compare "$CMP/src/absent.js"

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
