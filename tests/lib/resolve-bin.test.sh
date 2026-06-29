#!/usr/bin/env bash
# Tests for lib/resolve-bin.sh -- resolves real executables past shell-function shims.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/lib/resolve-bin.sh"
PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

check() {
  local name="$1" cond="$2"
  if [[ "$cond" == "1" ]]; then PASS=$((PASS+1)); echo "PASS: $name"
  else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi
}

# 1. Project-local node_modules/.bin wins.
mkdir -p "$WORK/proj/node_modules/.bin"
printf '#!/bin/sh\necho local\n' > "$WORK/proj/node_modules/.bin/vitest"
chmod +x "$WORK/proj/node_modules/.bin/vitest"
out="$(bash "$LIB" vitest "$WORK/proj")"
check "project-local binary resolved" "$([[ "$out" == "$WORK/proj/node_modules/.bin/vitest" ]] && echo 1 || echo 0)"
check "project-local path is executable" "$([[ -x "$out" ]] && echo 1 || echo 0)"

# 2. Real executable on PATH (jq is a hard dep, guaranteed present).
out="$(bash "$LIB" jq "$WORK")"
check "PATH executable resolved (jq)" "$([[ -n "$out" && -x "$out" ]] && echo 1 || echo 0)"

# 3. A shell FUNCTION named like a tool must NOT satisfy resolution from PATH.
#    (type -P skips functions; resolve-bin uses type -P, so a function alone => not found.)
out="$(bash "$LIB" definitely-not-a-real-binary-xyz "$WORK" 2>/dev/null || true)"
check "unresolvable tool exits empty" "$([[ -z "$out" ]] && echo 1 || echo 0)"
bash "$LIB" definitely-not-a-real-binary-xyz "$WORK" >/dev/null 2>&1
check "unresolvable tool exits non-zero" "$([[ $? -ne 0 ]] && echo 1 || echo 0)"

# 4. Missing arg is an error.
bash "$LIB" >/dev/null 2>&1
check "missing tool arg exits non-zero" "$([[ $? -ne 0 ]] && echo 1 || echo 0)"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
