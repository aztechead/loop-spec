#!/usr/bin/env bash
# Pins lib/graph/driver.py clean under `python3 -W error`: the module docstring's
# backtick escape (\`) and datetime.datetime.utcnow() both raised warnings on 3.12,
# the second scheduled to become a hard error. Also pins that no shipped Python
# under lib/, hooks/, extensions/ (heredocs in .sh included) reintroduces utcnow().
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
DRIVER="$REPO/lib/graph/driver.py"
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

# The escape class is repo-wide, so every shipped module compiles under -W error.
compile_out="$(find "$REPO/lib" "$REPO/hooks" "$REPO/extensions" -name '*.py' -print0 \
  | xargs -0 python3 -W error -c '
import sys
for path in sys.argv[1:]:
    with open(path) as f:
        compile(f.read(), path, "exec")
' 2>&1)"
check "every shipped .py compiles under -W error" "0:" "$?:$compile_out"
[[ -z "$compile_out" ]] || echo "  output: $compile_out"

# Embedded python in shell heredocs counts too (lib/cycle-result.sh had one).
utcnow_hits="$(grep -rl 'utcnow(' "$REPO/lib" "$REPO/hooks" "$REPO/extensions" \
  --include='*.py' --include='*.sh' 2>/dev/null || true)"
check "no shipped Python under lib/hooks/extensions uses utcnow()" "" "$utcnow_hits"

run_err="$(python3 -W error "$DRIVER" 2>&1 >/dev/null)"
run_exit=$?
check "driver.py with no args exits via usage (2)" "2" "$run_exit"
warn_hits="$(printf '%s\n' "$run_err" | grep -o '[A-Za-z]*[Ww]arning[A-Za-z]*' | grep -v '^warnings$' || true)"
check "no-args run emits no *Warning on stderr" "" "$warn_hits"

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
