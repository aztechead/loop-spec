#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/lib/security-signal.sh"
WORK="${TMPDIR:-/tmp}/loop-spec-security-signal.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"
PASS=0; FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

printf 'The service is authoritative for route data.\nAuthors update it.\n' > "$WORK/benign.md"
rc=0; bash "$SCRIPT" first "$WORK/benign.md" >/dev/null || rc=$?
check "authoritative is not auth" "1" "$rc"

printf 'Use auth middleware.\n' > "$WORK/auth.md"
out="$(bash "$SCRIPT" first "$WORK/auth.md")"
check "standalone auth matches" "$WORK/auth.md:1:term=auth" "$out"

printf 'Require OAuth2 and reject unauthorized callers.\n' > "$WORK/oauth.md"
out="$(bash "$SCRIPT" first "$WORK/oauth.md")"
check "OAuth and unauthorized remain security signals" "$WORK/oauth.md:1:term=auth protocol" "$out"

printf 'Require preauthorization before the operation.\n' > "$WORK/preauth.md"
out="$(bash "$SCRIPT" first "$WORK/preauth.md")"
check "authorization compounds remain covered" "$WORK/preauth.md:1:term=authorization" "$out"

printf 'Rotate the installation token before delivery.\n' > "$WORK/token.md"
out="$(bash "$SCRIPT" first "$WORK/benign.md" "$WORK/token.md")"
check "signal includes evidence location and term" "$WORK/token.md:1:term=token" "$out"

printf 'Delete the obsolete table in a migration.\n' > "$WORK/delete.md"
out="$(bash "$SCRIPT" first "$WORK/delete.md")"
check "destructive signal remains covered" "$WORK/delete.md:1:term=migration" "$out"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
