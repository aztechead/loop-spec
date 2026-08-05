#!/usr/bin/env bash
# Test suite for lib/comment-tells.sh
#
# The lint's contract runs both ways: it must catch the three tells, and it must
# stay quiet on the comments this repo deliberately writes. The negative cases
# below are the ones that made earlier drafts of the scanner unusable -- header
# blocks, section dividers, marker comments, usage docs, and why-comments that
# happen to reuse the nouns in the code beneath them.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LINT="$REPO_ROOT/lib/comment-tells.sh"
WORK="${TMPDIR:-/tmp}/comment-tells-test-$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

check() {
  local name="$1" want_exit="$2" pattern="$3"; shift 3
  local out rc
  out="$(bash "$LINT" "$@" 2>&1)"; rc=$?
  if [[ "$rc" -eq "$want_exit" ]] && grep -qE "$pattern" <<<"$out"; then
    echo "PASS: $name"; PASS=$((PASS+1))
  else
    echo "FAIL: $name (exit $rc, wanted $want_exit; looked for /$pattern/)"
    echo "$out" | sed 's/^/      /'
    FAIL=$((FAIL+1))
  fi
}

echo "=== comment-tells.sh tests ==="

# --- the three tells fire ---
cat > "$WORK/tells.py" <<'EOF'
import os


x = 1

# Previously this used a global cache
data = os.stat("f")

# Added error handling for the missing-file case
if not data:
    pass

# set the retry count to 3
retry_count = 3
EOF

check "a: changelog narration is caught" 1 "tell=changelog" scan "$WORK/tells.py"
check "b: diff narration is caught" 1 "tell=diff-narration" scan "$WORK/tells.py"
check "c: a comment echoing its next line is caught" 1 "tell=echoes-code" scan "$WORK/tells.py"
check "d: findings carry file and line" 1 "$WORK/tells.py:[0-9]+: tell=" scan "$WORK/tells.py"
check "e: findings are counted" 1 "comment-tells: 3 finding" scan "$WORK/tells.py"

# --- carve-outs stay quiet ---
cat > "$WORK/clean.sh" <<'EOF'
#!/usr/bin/env bash
# clean.sh - a purpose header, which this repo writes on every script.
# It explains what the file is for and how to call it.
#
# Usage:
#   clean.sh run <path>
set -euo pipefail

# --- section divider, the convention this repo's tests use ---
run() {
  # simplicity: one attempt, no retry ladder until a caller needs one
  # TODO: widen once the second consumer lands
  local path="$1"
  # Node 18 rejects this without the shim, so the import order matters
  source "$path"
}
EOF

check "f: a conventional file is clean" 0 "comment-tells: clean" scan "$WORK/clean.sh"

# --- the file header is exempt even when it reads like a tell ---
cat > "$WORK/header.py" <<'EOF'
# mod.py - Added in the rewrite; previously this lived in util.py.
# The header is where that history belongs.
import os
EOF
check "g: the leading header block is exempt" 0 "comment-tells: clean" scan "$WORK/header.py"

# --- a sentence inside a longer explanation is not a changelog entry ---
cat > "$WORK/block.py" <<'EOF'
import os

value = 1

# The events contract is a script now, not prose. It used to be a paragraph
# asking the model to print these lines, which meant every run formatted them
# differently and nothing downstream could parse the stream.
def emit(name):
    return os.environ.get(name)
EOF
check "h: a multi-line explanation is not a tell" 0 "comment-tells: clean" scan "$WORK/block.py"

# --- a doc comment above a definition is a docstring, not an echo ---
cat > "$WORK/docstring.js" <<'EOF'
const base = 1;

const other = 2;

// load user config
function loadUserConfig(path) {
  return path;
}
EOF
check "i: a comment above a definition is not an echo" 0 "comment-tells: clean" scan "$WORK/docstring.js"

# --- a label the code restates as a string literal is not an echo ---
cat > "$WORK/label.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

count=0

# case B: execute phase, failing lint denies the call
check_output "case B: execute phase, failing lint" 2
EOF
check "j: a label mirrored in a string literal is not an echo" 0 "comment-tells: clean" scan "$WORK/label.sh"

# --- comment syntax is per-language: `--` is prose in a shell string ---
cat > "$WORK/dashes.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

report() {
  echo "--- workspace -----------------------------------------------------"
  echo "--- previously configured -----------------------------------------"
}
EOF
check "k: SQL comment syntax is not applied to shell" 0 "comment-tells: clean" scan "$WORK/dashes.sh"

# --- markdown and data files carry no comment conventions ---
printf '# Previously\n\nAdded: notes about the old design.\n' > "$WORK/notes.md"
check "l: markdown is not scanned" 0 "comment-tells: clean" scan "$WORK/notes.md"

# --- hyphenated identifiers are prose, not an edit announcement ---
cat > "$WORK/hyphen.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

value=1

# new-mechanism: the marker debug stamps on a sibling it declined to fix
# fixed operating block, identical for single and workspace modes
emit "$value"
EOF
check "m: hyphenated markers are not diff narration" 0 "comment-tells: clean" scan "$WORK/hyphen.sh"

# --- diff mode reads only the added lines ---
GITREPO="$WORK/repo"
mkdir -p "$GITREPO"
(
  cd "$GITREPO"
  git init -q .
  git config user.email t@t.t
  git config user.name t
  printf 'import os\n\nvalue = 1\n' > mod.py
  git add -A && git commit -qm base
  printf 'import os\n\nvalue = 1\n\n# Previously this read from the env\nvalue = os.getpid()\n' > mod.py
  git add -A && git commit -qm change
)
(
  cd "$GITREPO"
  out="$(bash "$LINT" diff HEAD~1 HEAD 2>&1)"; rc=$?
  if [[ "$rc" -eq 1 ]] && grep -q "tell=changelog" <<<"$out" && grep -q "mod.py" <<<"$out"; then
    echo "PASS: n: diff mode catches a tell in added lines"
  else
    echo "FAIL: n: diff mode (exit $rc)"; echo "$out" | sed 's/^/      /'
    exit 1
  fi
) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

(
  cd "$GITREPO"
  out="$(bash "$LINT" diff HEAD HEAD 2>&1)"; rc=$?
  if [[ "$rc" -eq 0 ]] && grep -q "clean" <<<"$out"; then
    echo "PASS: o: diff mode is clean on an empty diff"
  else
    echo "FAIL: o: empty diff (exit $rc)"; echo "$out" | sed 's/^/      /'
    exit 1
  fi
) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# --- usage ---
check "p: bad mode exits 2" 2 "usage: comment-tells.sh" bogus "$WORK/clean.sh"
check "q: scan with no file exits 2" 2 "usage: comment-tells.sh scan" scan
check "r: unreadable file exits 2" 2 "cannot read" scan "$WORK/absent.py"

if [[ -x "$LINT" ]]; then
  echo "PASS: s: lint is executable"; PASS=$((PASS+1))
else
  echo "FAIL: s: lint is not executable"; FAIL=$((FAIL+1))
fi

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "PASS: comment-tells.sh catches the three tells and stays quiet on house conventions"
