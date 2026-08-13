#!/usr/bin/env bash
# Test suite for lib/duplication-scan.sh
#
# The probe's contract runs both ways: it must catch the copy-paste that rung 2
# of the ladder exists to prevent, and it must stay silent on the repetition a
# codebase legitimately contains. The negative cases below are the ones that
# make a clone detector unusable -- shared file headers, block terminators,
# generated regions, and blocks shorter than the window.
#
# NOTE: run the probe over this file and it reports its own fixtures. That is
# intended and must stay: a clone detector is tested with clones, so the paired
# fixtures below (helper/copy, nest-a/nest-b, live-a/live-b) are deliberately
# near-identical and de-duplicating them would delete the thing under test. The
# `check` helper is the separate case -- every suite in tests/ carries its own
# copy, so it is the house pattern here, and consolidating it is a repo-wide
# change rather than a drive-by inside this one.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROBE="$REPO_ROOT/lib/duplication-scan.sh"
WORK="${TMPDIR:-/tmp}/duplication-scan-test-$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

# Every case runs inside its own git repo: the probe compares targets against
# the tracked tree, so the corpus has to be the fixture and nothing else.
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

echo "=== duplication-scan.sh tests ==="

# --- a copy-paste is caught, against the tree the target never opened ---
fixture clone
cat > helper.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

resolve_ref() {
  local ref="$1"
  local name
  name="$(git rev-parse --abbrev-ref "$ref" 2>/dev/null)"
  if [[ -z "$name" || "$name" == "HEAD" ]]; then
    name="$(git rev-parse --short "$ref")"
  fi
  [[ -n "$name" ]] || name="unknown"
  printf '%s\n' "$name"
}
EOF
cat > copy.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

pick_ref() {
  local ref="$1"
  local name
  name="$(git rev-parse --abbrev-ref "$ref" 2>/dev/null)"
  if [[ -z "$name" || "$name" == "HEAD" ]]; then
    name="$(git rev-parse --short "$ref")"
  fi
  [[ -n "$name" ]] || name="unknown"
  printf '%s\n' "$name"
}
EOF
git add -A && git commit -qm base

check "a: a re-implemented helper is caught" 1 "duplicate=[0-9]+ lines" scan copy.sh
check "b: the finding names the file it already exists in" 1 "also at helper\.sh:[0-9]+-[0-9]+" scan copy.sh
check "c: the finding carries the target's line span" 1 "^copy\.sh:[0-9]+-[0-9]+:" scan copy.sh
check "d: findings are counted with the compared scope" 1 \
  "1 finding\(s\) targets=1 corpus=1 window=6/8" scan copy.sh
check "d2: a verbatim copy is labelled duplicate, not similar" 1 "duplicate=" scan copy.sh

# Both halves as targets is the review path (a diff that added both). The pair
# is one duplication, so it reports once rather than mirrored.
check "e: a pair reports once, not from both ends" 1 "1 finding\(s\)" scan copy.sh helper.sh

# --- the shape tier: copy-paste-then-rename, which is what actually ships ---
#
# The exact tier cannot see this and it is the single most common shape of
# duplication in generated code: same structure, every name changed. Caught by
# matching with the identifiers and literals removed, at a wider window.
fixture renamed
mkdir -p src
cat > src/users.ts <<'EOF'
import { db } from './db'

export async function fetchUser(id: string) {
  const started = Date.now()
  const row = await db.query('select * from users where id = $1', [id])
  if (!row) {
    logger.warn('user miss', { id, ms: Date.now() - started })
    return null
  }
  logger.info('user hit', { id, ms: Date.now() - started })
  return { id: row.id, name: row.name }
}
EOF
sed -e 's/users/orders/g' -e 's/fetchUser/fetchOrder/' -e "s/'user /'order /g" \
  -e 's/row.name/row.total/' src/users.ts > src/orders.ts
git add -A && git commit -qm base
check "f1: a renamed copy is caught" 1 "similar=[0-9]+ lines" scan src/orders.ts
check "f2: the renamed copy names its original" 1 "also at src/users\.ts" scan src/orders.ts

# Renaming is not the same as rewriting: different logic in the same language
# shares keywords and punctuation, and must not match on shape alone.
cat > src/totals.ts <<'EOF'
import { cache } from './cache'

export function summarise(rows: Row[]) {
  const totals = new Map<string, number>()
  for (const row of rows) {
    totals.set(row.sku, (totals.get(row.sku) ?? 0) + row.qty)
  }
  cache.set('totals', totals)
  return [...totals.entries()].sort((a, b) => b[1] - a[1])
}
EOF
git add -A && git commit -qm totals
check "f3: different logic is not a shape clone" 0 "duplication-scan: clean" scan src/totals.ts

# The tier is not brace-language specific: an indentation-structured language
# renames the same way, and the placeholder pass must survive losing the braces.
fixture renamed-py
cat > repo_users.py <<'EOF'
from .db import session


def load_user(user_id):
    started = time.monotonic()
    row = session.execute("select * from users where id = :i", {"i": user_id}).first()
    if row is None:
        log.warning("user missing", extra={"id": user_id})
        raise NotFound(user_id)
    log.info("user loaded", extra={"ms": time.monotonic() - started})
    return User(id=row.id, name=row.name)
EOF
sed -e 's/user/account/g' -e 's/User/Account/g' repo_users.py > repo_accounts.py
git add -A && git commit -qm base
check "f4: a renamed copy is caught in Python too" 1 "similar=[0-9]+ lines" scan repo_accounts.py

# --- a uniform table is not a clone of itself ---
#
# Rows that all share one shape match a shifted copy of themselves at every
# offset. Left in, tests/run-all.sh reports as a 151-line clone of itself.
fixture uniform
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  for n in $(seq 1 60); do
    printf 'run_suite "case_%s" "bash tests/case_%s.test.sh"\n' "$n" "$n"
  done
} > table.sh
git add -A && git commit -qm base
check "g1: a uniform table does not self-match" 0 "duplication-scan: clean" scan table.sh

# --- distinct code stays quiet ---
fixture distinct
cat > one.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

count_words() {
  local file="$1"
  wc -w < "$file"
}
EOF
cat > two.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

newest_tag() {
  git describe --tags --abbrev=0 2>/dev/null || printf 'none\n'
}
EOF
git add -A && git commit -qm base
check "f: unrelated files are clean" 0 "duplication-scan: clean" scan two.sh

# --- comments are not code: a shared header is not a clone ---
fixture headers
header='#!/usr/bin/env bash
# shared.sh - the purpose header this repo writes on every script.
#
# Usage:
#   shared.sh run <path>
#
# Exit codes:
#   0  ok
#   1  failure
#   2  usage error
set -euo pipefail
'
printf '%s\nalpha() { date +%%s; }\n' "$header" > head-a.sh
printf '%s\nbeta() { hostname; }\n' "$header" > head-b.sh
git add -A && git commit -qm base
check "g: an identical file header is not a clone" 0 "duplication-scan: clean" scan head-b.sh

# --- block terminators are not code either ---
fixture structural
cat > nest-a.sh <<'EOF'
#!/usr/bin/env bash
walk_alpha() {
  if [[ -d a ]]; then
    for f in a/*; do
      if [[ -f "$f" ]]; then
        printf 'alpha %s\n' "$f"
      fi
    done
  fi
}
EOF
cat > nest-b.sh <<'EOF'
#!/usr/bin/env bash
walk_beta() {
  if [[ -d b ]]; then
    while read -r f; do
      if [[ -x "$f" ]]; then
        printf 'beta %s\n' "$f"
      fi
    done < list
  fi
}
EOF
git add -A && git commit -qm base
check "h: shared block terminators do not make a clone" 0 "duplication-scan: clean" scan nest-b.sh

# --- generated code has one source already ---
fixture generated
cat > gen-a.js <<'EOF'
// @generated by build.js - DO NOT EDIT
export const SCHEMA = {
  type: 'object',
  required: ['file', 'line', 'severity'],
  properties: {
    file: { type: 'string' },
    line: { type: 'number' },
    severity: { type: 'string' },
  },
}
EOF
sed 's/^export const SCHEMA/export const OTHER/' gen-a.js > gen-b.js
git add -A && git commit -qm base
check "i: a generated file is skipped whole" 0 "duplication-scan: clean" scan gen-b.js

fixture region
cat > mixed-a.js <<'EOF'
// mixed-a.js - hand written around an injected block.
export const meta = { name: 'alpha' }

// @inject:schemas
const SCHEMA = {
  type: 'object',
  required: ['file', 'line', 'severity'],
  properties: {
    file: { type: 'string' },
    line: { type: 'number' },
    severity: { type: 'string' },
  },
}
// @inject:end

export function alpha(value) {
  return SCHEMA.type + value
}
EOF
sed -e 's/mixed-a/mixed-b/' -e "s/'alpha'/'beta'/" -e 's/function alpha/function beta/' \
  mixed-a.js > mixed-b.js
git add -A && git commit -qm base
check "j: a marked generated region is skipped in place" 0 "duplication-scan: clean" scan mixed-b.js

# ...and the hand-written code around that region is still compared.
fixture region-live
cat > live-a.sh <<'EOF'
#!/usr/bin/env bash
# @inject:preamble
alpha_generated() {
  printf 'a\n'
}
# @inject:end

parse_args() {
  local dir=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir) dir="${2:-}"; shift 2 ;;
      *) exit 2 ;;
    esac
  done
  printf '%s\n' "$dir"
}
EOF
cat > live-b.sh <<'EOF'
#!/usr/bin/env bash
# @inject:preamble
beta_generated() {
  printf 'b\n'
}
# @inject:end

read_args() {
  local dir=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir) dir="${2:-}"; shift 2 ;;
      *) exit 2 ;;
    esac
  done
  printf '%s\n' "$dir"
}
EOF
git add -A && git commit -qm base
check "k: hand-written code beside a generated region is still compared" 1 \
  "also at live-a\.sh" scan live-b.sh

# --- a short repeat is idiom, not duplication ---
fixture short
cat > tiny-a.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
alpha() {
  local target="$1"
  [[ -f "$target" ]] || exit 1
  local size
  size="$(wc -c < "$target")"
  printf 'alpha %s\n' "$size"
}
EOF
cat > tiny-b.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
beta() {
  local target="$1"
  [[ -f "$target" ]] || exit 1
  local size
  size="$(wc -c < "$target")"
  printf 'beta %s\n' "$size"
}
EOF
git add -A && git commit -qm base
check "l: a repeat shorter than the window is not reported" 0 "duplication-scan: clean" scan tiny-b.sh

# The window is the operator's to move, and a narrower one sees the same block.
out="$(LOOP_SPEC_DUP_MIN_LINES=3 bash "$PROBE" scan tiny-b.sh 2>&1)"; rc=$?
if [[ "$rc" -eq 1 ]] && grep -q "window=3" <<<"$out" && grep -q "tiny-a.sh" <<<"$out"; then
  echo "PASS: m: LOOP_SPEC_DUP_MIN_LINES narrows the window"; PASS=$((PASS+1))
else
  echo "FAIL: m: the window override did not take (exit $rc)"; echo "$out" | sed 's/^/      /'
  FAIL=$((FAIL+1))
fi

# An unreadable override falls back rather than scanning with a window of one
# and reporting every line in the tree.
out="$(LOOP_SPEC_DUP_MIN_LINES=banana bash "$PROBE" scan tiny-b.sh 2>&1)"; rc=$?
if [[ "$rc" -eq 0 ]] && grep -q "window=6" <<<"$out"; then
  echo "PASS: n: an unreadable window override falls back to the default"; PASS=$((PASS+1))
else
  echo "FAIL: n: bad override did not fall back (exit $rc)"; echo "$out" | sed 's/^/      /'
  FAIL=$((FAIL+1))
fi

# --- diff mode reads the changed files ---
fixture diffmode
cat > base.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

emit_config() {
  local file="$1"
  local key="$2"
  local fallback="$3"
  local value
  value="$(grep -m1 -E "^${key}=" "$file" 2>/dev/null | cut -d= -f2 || true)"
  [[ -n "$value" ]] || value="$fallback"
  printf '%s\n' "$value"
}
EOF
git add -A && git commit -qm base
sed 's/emit_config/read_config/' base.sh > added.sh
git add -A && git commit -qm change
check "o: diff mode catches a clone among the changed files" 1 "also at base\.sh" diff HEAD~1 HEAD
check "p: diff mode is clean on an empty diff" 0 "duplication-scan: clean" diff HEAD HEAD

# Duplication the diff merely walked past belongs to the repository, not to this
# author. Touching an unrelated line of a file that already contains a clone
# must stay silent, or the one finding they can act on is buried.
printf '\n# a note that changes nothing else\n' >> added.sh
git add -A && git commit -qm unrelated
check "q: pre-existing duplication in a touched file is not this diff's finding" 0 \
  "duplication-scan: clean" diff HEAD~1 HEAD

# ...and scan mode, which asks about whole files, still sees it.
check "r: scan mode still reports the standing duplication" 1 "also at base\.sh" scan added.sh

# A path git reports but the worktree no longer has is ordinary in diff mode
# (a delete, a rename) and must not be read as a caller error.
git rm -q added.sh && git commit -qm remove
check "s: diff mode tolerates a deleted path" 0 "duplication-scan: clean" diff HEAD~1 HEAD

# --- prose is not code ---
fixture prose
doc='## Role

You review a diff for correctness, reuse, and legibility.
Report each finding with a file and a line.
Block on evidence, never on taste.
Keep the report short enough to read.
Cite the probe output you measured.
'
printf 'name: alpha\n%s' "$doc" > alpha.md
printf 'name: beta\n%s' "$doc" > beta.md
git add -A && git commit -qm base
check "t: markdown is not scanned" 0 "duplication-scan: clean" scan beta.md

# --- usage ---
cd "$WORK" || exit 2
check "u: bad mode exits 2" 2 "usage: duplication-scan.sh" bogus base.sh
check "v: scan with no file exits 2" 2 "usage: duplication-scan.sh scan" scan
check "w: scan of a missing file exits 2" 2 "cannot read" scan absent.sh

if [[ -x "$PROBE" ]]; then
  echo "PASS: x: probe is executable"; PASS=$((PASS+1))
else
  echo "FAIL: x: probe is not executable"; FAIL=$((FAIL+1))
fi

cd "$REPO_ROOT" || exit 2
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "PASS: duplication-scan.sh catches copy-paste and stays quiet on legitimate repetition"
