#!/usr/bin/env bash
# Test suite for lib/failure-tells.sh
#
# The lint's contract runs both ways: it must catch the three ways code goes quiet on
# the person operating it, and it must stay quiet on the shapes that look identical and
# are deliberate -- a narrow exception type (the type IS the reason), a handler whose
# comment states why, an exit guarded by a command that reports its own failure, and a
# message that names the actual thing that broke.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LINT="$REPO_ROOT/lib/failure-tells.sh"
WORK="${TMPDIR:-/tmp}/failure-tells-test-$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

check() {
  local name="$1" want_exit="$2" pattern="$3"; shift 3
  local out rc
  out="$(cd "$WORK" && bash "$LINT" "$@" 2>&1)"; rc=$?
  if [[ "$rc" -eq "$want_exit" ]] && grep -qE "$pattern" <<<"$out"; then
    echo "PASS: $name"; PASS=$((PASS+1))
  else
    echo "FAIL: $name (exit $rc, wanted $want_exit; looked for /$pattern/)"
    echo "$out" | sed 's/^/      /'
    FAIL=$((FAIL+1))
  fi
}

echo "=== failure-tells.sh tests ==="

# --- python: the three tells fire ---
cat > "$WORK/bad.py" <<'EOF'
import sys


def quit_now():
    sys.exit(2)


def load(path):
    try:
        return open(path).read()
    except Exception:
        pass
    if not path:
        raise ValueError("invalid input")
    return None
EOF

check "a: a broad handler that does nothing is caught" 1 "tell=swallowed" scan bad.py
check "b: a message made only of synonyms for broken is caught" 1 \
  "tell=contextless-error: invalid input" scan bad.py
check "c: a non-zero exit with nothing said is caught" 1 "tell=silent-exit" scan bad.py
check "d: findings carry file and line" 1 "bad.py:[0-9]+: tell=" scan bad.py
check "e: the count names the files it read" 1 "failure-tells: 3 finding\(s\) \(1 file" scan bad.py

# --- python: the deliberate shapes stay quiet ---
cat > "$WORK/good.py" <<'EOF'
import sys


def load(path, timeout):
    try:
        return open(path).read()
    except FileNotFoundError:
        pass
    try:
        return open(path + ".bak").read()
    except Exception:
        # A backup that will not open is not worth reporting; the caller retries.
        pass
    if timeout < 0:
        raise ValueError("timeout must be a positive number of seconds")
    if not path:
        raise ValueError(f"no such file: {path}")
    print("load: nothing to read", file=sys.stderr)
    sys.exit(2)
EOF

check "f: a narrow type, a stated reason, a specific message, and a spoken exit stay quiet" 0 \
  "failure-tells: clean" scan good.py

# --- shell ---
cat > "$WORK/bad.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  exit 2
fi
echo "error" >&2
EOF

check "g: a bare non-zero exit in shell is caught" 1 "tell=silent-exit: exit 2" scan bad.sh
check "h: a shell message made only of synonyms is caught" 1 "tell=contextless-error: error" scan bad.sh

cat > "$WORK/good.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

resolve_root "$1" || exit 2
if [[ $# -lt 1 ]]; then
  echo "good.sh: expected one path argument" >&2
  exit 2
fi
# exit 3
EOF

check "i: a guarded exit, a spoken exit, and a commented-out exit stay quiet" 0 \
  "failure-tells: clean" scan good.sh

# --- js/ts ---
cat > "$WORK/bad.ts" <<'EOF'
export function load(path: string): string | null {
  try {
    return read(path);
  } catch {
  }
  try {
    return read(path + ".bak");
  } catch (e) {}
  throw new Error("something went wrong");
}
EOF

check "j: an empty catch block is caught" 1 "tell=swallowed" scan bad.ts
check "k: both empty-catch shapes are caught" 1 "failure-tells: 3 finding" scan bad.ts
check "l: a thrown message made only of synonyms is caught" 1 \
  "tell=contextless-error: something went wrong" scan bad.ts

cat > "$WORK/good.ts" <<'EOF'
export function load(path: string, id: string): string {
  try {
    return read(path);
  } catch (e) {
    // The cache is optional; a miss falls through to the source below.
  }
  try {
    return read(path + ".bak");
  } catch (e) {
    console.warn(`backup unreadable: ${path}`);
  }
  throw new Error(`no source found for ${id}`);
}
EOF

check "m: a stated reason, a logged handler, and an interpolated message stay quiet" 0 \
  "failure-tells: clean" scan good.ts

# --- quoted examples and inline comments are data, not executable exits ---
cat > "$WORK/quoted.py" <<'EOF'
note = "sys.exit(2)"
value = 1  # sys.exit(3)
example = 'raise ValueError("invalid input")'
EOF
cat > "$WORK/quoted.js" <<'EOF'
const note = "process.exit(2)";
const value = 1; // process.exit(3)
const example = 'throw new Error("invalid input")';
/* process.exit(4); */
EOF
cat > "$WORK/quoted.sh" <<'EOF'
note="then; exit 2"
value=1  # exit 3
cat <<'PAYLOAD'
exit 4
PAYLOAD
EOF
check "n: exit and error examples in strings or comments stay quiet" 0 \
  "failure-tells: clean" scan quoted.py quoted.js quoted.sh

cat > "$WORK/data-before-exit.py" <<'EOF'
note = "error"
sys.exit(2)
EOF
cat > "$WORK/data-before-exit.js" <<'EOF'
const note = "error";
process.exit(2);
EOF
cat > "$WORK/data-before-exit.sh" <<'EOF'
note="error"
exit 2
EOF
check "o: an error word stored as data does not speak for a real exit" 1 \
  "failure-tells: 3 finding" scan data-before-exit.py data-before-exit.js data-before-exit.sh

cat > "$WORK/quoted-heredoc.sh" <<'EOF'
# cat <<COMMENTED
note='<<QUOTED'
exit 2
EOF
check "p: a heredoc marker in a comment or string does not hide later code" 1 \
  "tell=silent-exit: exit 2" scan quoted-heredoc.sh

# --- scope ---
printf '# notes\n' > "$WORK/bad.py.md"
check "q: a language with no rules is skipped, not guessed at" 0 "1 skipped" scan bad.py.md
check "r: the skip is counted in the answer line" 1 "skipped \(no rules" scan bad.py bad.py.md

# --- diff mode reports only what the change introduced ---
(
  cd "$WORK" || exit 1
  git init -q . && git config user.email "test@example.com" && git config user.name "Test"
  git add bad.py good.py bad.sh good.sh bad.ts good.ts >/dev/null 2>&1
  git commit -qm "seed"
) >/dev/null 2>&1
BASE="$(cd "$WORK" && git rev-parse HEAD)"
printf '\n\ndef save(path):\n    try:\n        write(path)\n    except Exception:\n        pass\n' >> "$WORK/good.py"
(cd "$WORK" && git add good.py && git commit -qm "add a swallowed handler") >/dev/null 2>&1

check "s: diff mode flags the handler the change added" 1 "good.py:[0-9]+: tell=swallowed" diff "$BASE"
check "t: diff mode leaves the file's other lines alone" 1 "failure-tells: 1 finding" diff "$BASE"
check "u: an unchanged range is clean" 0 "failure-tells: clean" diff HEAD

# --- usage ---
check "v: bad mode exits 2" 2 "usage: failure-tells.sh" bogus bad.py
check "w: scan with no file exits 2" 2 "usage: failure-tells.sh scan" scan
check "x: an unreadable file exits 2" 2 "cannot read" scan absent.py

if [[ -x "$LINT" ]]; then
  echo "PASS: y: lint is executable"; PASS=$((PASS+1))
else
  echo "FAIL: y: lint is not executable"; FAIL=$((FAIL+1))
fi

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "PASS: failure-tells.sh catches the three silences and stays quiet on the deliberate shapes"
