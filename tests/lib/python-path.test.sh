#!/usr/bin/env bash
# Tests for lib/python-path.sh: a pyenv shim resolves to the interpreter's directory,
# anything else prints nothing, and the probe never exits non-zero.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO/lib/python-path.sh"
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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/loop-spec-python-path.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/.pyenv/shims" "$WORK/real" "$WORK/bin" "$WORK/plain" "$WORK/tmp"
printf '#!/bin/sh\nexit 0\n' > "$WORK/.pyenv/shims/python3"
printf '#!/bin/sh\nexit 0\n' > "$WORK/real/python3"
printf '#!/bin/sh\nexit 0\n' > "$WORK/plain/python3"
# A pyenv that answers `which python3` with the real interpreter, and one that cannot.
printf '#!/bin/sh\n[ "$1 $2" = "which python3" ] && echo "%s/real/python3"\n' "$WORK" > "$WORK/bin/pyenv"
chmod +x "$WORK/.pyenv/shims/python3" "$WORK/real/python3" "$WORK/plain/python3" "$WORK/bin/pyenv"
CORE="/usr/bin:/bin"

out="$(TMPDIR="$WORK/tmp" PATH="$WORK/.pyenv/shims:$WORK/bin:$CORE" bash "$LIB")"
check "pyenv shim: prints a private directory" "$WORK/tmp/loop-spec-python-$(id -u)" "$out"
check "pyenv shim: that directory links only python3 to the real interpreter" "python3 -> $WORK/real/python3" \
  "$(ls "$out" | paste -sd' ' -) -> $(readlink "$out/python3")"
err="$(TMPDIR="$WORK/tmp" PATH="$WORK/.pyenv/shims:$WORK/bin:$CORE" bash "$LIB" --explain 2>&1 >/dev/null)"
check "pyenv shim: --explain names the shim and the link" "1" "$(grep -c "ANSWER=$WORK/tmp/loop-spec-python-$(id -u) REASON=pyenv shim at $WORK/.pyenv/shims/python3; pyenv which -> $WORK/real/python3, linked" <<<"$err")"

out="$(PATH="$WORK/.pyenv/shims:$CORE" bash "$LIB"; echo "rc=$?")"
check "pyenv shim without pyenv: prints nothing, exit 0" "rc=0" "$out"

printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/pyenv"
out="$(PATH="$WORK/.pyenv/shims:$WORK/bin:$CORE" bash "$LIB"; echo "rc=$?")"
check "pyenv that cannot answer: prints nothing, exit 0" "rc=0" "$out"

out="$(PATH="$WORK/plain:$CORE" bash "$LIB"; echo "rc=$?")"
check "a plain python3: prints nothing, exit 0" "rc=0" "$out"
err="$(PATH="$WORK/plain:$CORE" bash "$LIB" --explain 2>&1 >/dev/null)"
check "a plain python3: --explain says it is not a shim" "1" "$(grep -c "ANSWER=none REASON=$WORK/plain/python3 is not a version-manager shim" <<<"$err")"

out="$(PATH="$WORK/nothing:$CORE" bash "$LIB"; echo "rc=$?")"
check "no python3: prints nothing, exit 0" "rc=0" "$out"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
