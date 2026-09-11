#!/usr/bin/env bash
# Test suite for lib/portability-scan.sh
#
# Each bash-4/GNU-only rule gets one fixture line that must fire and, where the same
# construct has a portable spelling, one that must stay quiet -- `sed -i ''` next to
# bare `sed -i`, a template ending in XXXXXX next to one that does not. Also covered:
# the `python3 - <<'PY'` heredoc convention (scanned as python, not shell), a non-python
# heredoc (data, skipped), the `# portability:` escape, the timeout/flock lib/hooks-only
# warning, directory expansion, and the usage/exit-code contract.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LINT="$REPO_ROOT/lib/portability-scan.sh"
WORK="${TMPDIR:-/tmp}/portability-scan-test-$$"
mkdir -p "$WORK/lib"
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

echo "=== portability-scan.sh tests ==="

# --- bash >= 4 syntax fires ---
cat > "$WORK/bash4.sh" <<'EOF'
#!/usr/bin/env bash
mapfile -t arr < file.txt
readarray -t arr2 < file.txt
declare -A assoc
local -A assoc2
lower="${VAR,,}"
upper="${VAR^^}"
cmd1 |& cmd2
cmd3 &>> out.log
echo "${ARR[-1]}"
coproc mycoproc { sleep 1; }
read -i "default" -p "prompt: " ans
EOF
check "a: mapfile needs bash >= 4"        1 "tell=mapfile"            scan bash4.sh
check "b: readarray needs bash >= 4"      1 "tell=readarray"          scan bash4.sh
check "c: declare -A needs bash >= 4"     1 "tell=declare-assoc.*declare -A" scan bash4.sh
check "d: local -A needs bash >= 4"       1 "tell=declare-assoc.*local -A"   scan bash4.sh
check "e: \${var,,} needs bash >= 4"      1 "tell=case-modification.*,,"    scan bash4.sh
check "f: \${var^^} needs bash >= 4"      1 "tell=case-modification.*\^\^"  scan bash4.sh
check "g: |& needs bash >= 4"             1 "tell=pipe-amp"           scan bash4.sh
check "h: &>> needs bash >= 4"            1 "tell=append-both"        scan bash4.sh
check "i: a negative array index needs bash >= 4" 1 "tell=negative-index" scan bash4.sh
check "j: coproc needs bash >= 4"         1 "tell=coproc"             scan bash4.sh
check "k: read -i needs bash >= 4"        1 "tell=read-preload"       scan bash4.sh

printf '#!/usr/bin/env bash\nprintf -v out "%%s" "$1"\n' > "$WORK/printfv.sh"
check "m: printf -v (bash >= 3.1) is never flagged" 0 "portability-scan: clean" scan printfv.sh

# --- portable read loop instead of mapfile stays quiet ---
cat > "$WORK/portable-loop.sh" <<'EOF'
#!/usr/bin/env bash
while IFS= read -r line; do
  echo "$line"
done < file.txt
EOF
check "n: a plain while/read loop stays quiet" 0 "portability-scan: clean" scan portable-loop.sh

# --- GNU-only invocations fire; their portable spellings stay quiet ---
cat > "$WORK/gnu.sh" <<'EOF'
#!/usr/bin/env bash
target=$(readlink -f "$0")
r=$(realpath "$0")
sed -i 's/a/b/' file.txt
sed -r 's/(a)/\1/' file.txt
d=$(date -d "yesterday")
sz=$(stat -c %s file.txt)
grep -P '\d+' file.txt
sort -V versions.txt
cp --parents a/b/c dest/
find . -printf '%p\n'
xargs -d '\n' < file.txt
t1=$(mktemp /tmp/work)
t2=$(mktemp -t prefix --suffix=.txt)
EOF
check "o: readlink -f is GNU-only"   1 "tell=readlink-canonicalize" scan gnu.sh
check "p: realpath is GNU-only"      1 "tell=realpath:"             scan gnu.sh
check "q: sed -i with no suffix is GNU-only" 1 "tell=sed-inplace"   scan gnu.sh
check "r: sed -r is GNU-only"        1 "tell=sed-extended-r"        scan gnu.sh
check "s: date -d is GNU-only"       1 "tell=date-parse"            scan gnu.sh
check "t: stat -c is GNU-only"       1 "tell=stat-format"           scan gnu.sh
check "u: grep -P is GNU-only"       1 "tell=grep-perl"             scan gnu.sh
check "v: sort -V is GNU-only"       1 "tell=sort-version"          scan gnu.sh
check "w: cp --parents is GNU-only"  1 "tell=cp-parents"            scan gnu.sh
check "x: find -printf is GNU-only"  1 "tell=find-printf"           scan gnu.sh
check "y: xargs -d is GNU-only"      1 "tell=xargs-delim"           scan gnu.sh
check "z: mktemp with fewer than 3 trailing X's is flagged" 1 "tell=mktemp-template" scan gnu.sh
check "aa: mktemp -t combined with --suffix is flagged" 1 "tell=mktemp-suffix" scan gnu.sh

cat > "$WORK/portable.sh" <<'EOF'
#!/usr/bin/env bash
sed -i '' 's/a/b/' file.txt
sed -i.bak 's/a/b/' file.txt
sed -E 's/(a)/\1/' file.txt
t=$(mktemp "${TMPDIR:-/tmp}/loop-spec-good-XXXXXX")
EOF
check "ab: sed -i '' is the portable BSD-compatible spelling" 0 "portability-scan: clean" \
  scan portable.sh
check "ac: sed -i.bak (attached suffix) is portable"          0 "portability-scan: clean" \
  scan portable.sh
check "ad: an mktemp template ending in XXXXXX is portable"   0 "portability-scan: clean" \
  scan portable.sh

# --- a command retried under a different flag in a `||` chain is a deliberate
# GNU/BSD split, not a bug -- flagging it would teach people to ignore this probe ---
cat > "$WORK/fallback.sh" <<'EOF'
#!/usr/bin/env bash
age=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
EOF
check "ae: a stat -c/-f OR-fallback for both platforms stays quiet" 0 \
  "portability-scan: clean" scan fallback.sh

# --- xargs's own flags only, never the utility's it execs ---
cat > "$WORK/xargs-utility.sh" <<'EOF'
#!/usr/bin/env bash
git tag | xargs -r git tag -d
EOF
check "af: a -d meant for the utility xargs execs is not xargs's own flag" 0 \
  "portability-scan: clean" scan xargs-utility.sh

# --- the # portability: <reason> escape suppresses same-line findings only ---
cat > "$WORK/marker.sh" <<'EOF'
#!/usr/bin/env bash
target=$(readlink -f "$0")  # portability: needed here, tracked in ISSUE-1
target2=$(readlink -f "$0")
EOF
check "ag: a same-line portability marker suppresses only that line's finding" 1 \
  "1 finding" scan marker.sh
check "ah: the unmarked line still fires" 1 "marker.sh:3: tell=readlink-canonicalize" scan marker.sh
marker_out="$(cd "$WORK" && bash "$LINT" scan marker.sh 2>&1)"
if ! grep -q "marker.sh:2:" <<<"$marker_out"; then
  echo "PASS: ai: the marker line itself never appears"; PASS=$((PASS+1))
else
  echo "FAIL: ai: the marker line itself never appears"
  echo "$marker_out" | sed 's/^/      /'
  FAIL=$((FAIL+1))
fi

# --- python: each stdlib-newer-than-3.7 feature fires; the 3.7-safe spelling is quiet ---
cat > "$WORK/py.py" <<'EOF'
import os
import signal


def load(a, b, /, c):
    if (n := len(a)) > 0:
        return n
    match c:
        case 1:
            return 1
        case _:
            return 0


def f(s):
    return s.removeprefix("x").removesuffix("y")


merged = {"a": 1} | {"b": 2}
affinity = os.sched_getaffinity(0)
sig = signal.SIGRTMIN + 1
name = "value"
print(f"{name=}")
EOF
check "aj: the walrus operator needs python >= 3.8"        1 "tell=walrus"          scan py.py
check "ak: a match statement needs python >= 3.10"         1 "tell=match-stmt"      scan py.py
check "al: str.removeprefix needs python >= 3.9"           1 "tell=removeprefix"    scan py.py
check "am: str.removesuffix needs python >= 3.9"           1 "tell=removesuffix"    scan py.py
check "an: dict | dict merge needs python >= 3.9"          1 "tell=dict-merge"      scan py.py
check "ao: a positional-only / parameter needs python >= 3.8" 1 "tell=positional-only" scan py.py
check "ap: os.sched_* is Linux-only"                        1 "tell=sched-affinity"  scan py.py
check "aq: signal.SIGRTMIN is Linux-only"                   1 "tell=sigrtmin"        scan py.py
check "ar: the f-string {expr=} specifier needs python >= 3.8" 1 "tell=fstring-debug" scan py.py

cat > "$WORK/py-good.py" <<'EOF'
"""A docstring mentioning walrus := and match statements as prose, not code."""
import sys


def load(a, b, c):
    n = len(a)
    if n > 0:
        return n
    return 0


x = sys.argv[1]
result = x == "match"
print("value=%s" % x)
EOF
check "as: a docstring example does not seed a finding" 0 "portability-scan: clean" \
  scan py-good.py

printf 'import re\nm = re.match("x", "y")\nif m:\n    pass\n' > "$WORK/re-match.py"
check "at: re.match(...) is not a match statement" 0 "portability-scan: clean" scan re-match.py

# --- a shell script's own python3 heredoc is scanned under the PYTHON rules ---
cat > "$WORK/embed.sh" <<'EOF'
#!/usr/bin/env bash
result="$(python3 - "$1" <<'PY'
import sys
d = {"a": 1} | {"b": 2}
print(sys.argv[1], d)
PY
)"
EOF
check "av: a python3 heredoc is scanned as python" 1 "tell=dict-merge" scan embed.sh

# --- any OTHER heredoc is data and is never scanned, even if it spells a bad command ---
cat > "$WORK/data-heredoc.sh" <<'EOF'
#!/usr/bin/env bash
cat <<'EOF2'
mapfile is mentioned here, and so is sed -i and readlink -f, as plain text.
EOF2
jq -n <<'JQ'
{"note": "declare -A is not a jq keyword either"}
JQ
EOF
check "aw: a non-python heredoc body is data, never scanned" 0 "portability-scan: clean" \
  scan data-heredoc.sh

# --- timeout/flock: warning severity, lib/hooks only, and only when unguarded ---
mkdir -p "$WORK/lib" "$WORK/notshipped"
printf '#!/usr/bin/env bash\ntimeout 5 curl example.com\nflock /tmp/l echo hi\n' \
  > "$WORK/lib/warn.sh"
check "ax: an unguarded timeout in lib/ is a warning" 1 \
  "tell=timeout-no-fallback severity=warning" scan lib/warn.sh
check "ay: an unguarded flock in lib/ is a warning" 1 \
  "tell=flock-no-fallback severity=warning" scan lib/warn.sh
check "az: the warning still counts toward the finding total" 1 "2 finding" scan lib/warn.sh

printf '#!/usr/bin/env bash\nif command -v timeout >/dev/null 2>&1; then\n  timeout 5 curl x\nfi\n' \
  > "$WORK/lib/guarded.sh"
check "ba: a command -v timeout guard silences the warning" 0 "portability-scan: clean" \
  scan lib/guarded.sh

printf '#!/usr/bin/env bash\ntimeout 5 curl example.com\n' > "$WORK/notshipped/warn.sh"
check "bb: the same unguarded timeout outside lib/hooks is not reported" 0 \
  "portability-scan: clean" scan notshipped/warn.sh

# --- directory expansion ---
check "bc: a directory argument expands to every .sh/.py file under it" 1 \
  "tell=timeout-no-fallback" scan lib
mkdir -p "$WORK/empty"
check "bd: an empty directory is clean, not an error" 0 "portability-scan: clean \(0 file" \
  scan empty

# --- scope: a file with no rules for its language is skipped, not guessed at ---
printf '# notes\n' > "$WORK/notes.md"
check "be: an unrelated extension is skipped, not scanned" 0 "1 skipped" scan notes.md

# --- usage / exit codes ---
check "bf: no subcommand exits 2"      2 "usage: portability-scan.sh" bogus
check "bg: scan with no target exits 2" 2 "usage: portability-scan.sh scan" scan
check "bh: an unreadable named file exits 2" 2 "cannot read" scan absent.sh

if [[ -x "$LINT" ]]; then
  echo "PASS: bi: the launcher is executable"; PASS=$((PASS+1))
else
  echo "FAIL: bi: the launcher is not executable"; FAIL=$((FAIL+1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
