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

# Weak terms are ambiguous alone: one benign keyword never selects the heavy gate.
printf 'Rotate the installation token before delivery.\n' > "$WORK/token.md"
rc=0; bash "$SCRIPT" first "$WORK/benign.md" "$WORK/token.md" >/dev/null || rc=$?
check "single weak term (token) does not fire" "1" "$rc"

printf 'Track the token budget for the run.\n' > "$WORK/budget.md"
rc=0; bash "$SCRIPT" first "$WORK/token.md" "$WORK/budget.md" >/dev/null || rc=$?
check "same weak term twice does not fire" "1" "$rc"

# Two DISTINCT weak terms corroborate each other and fire with the evidence trail.
printf 'Delete the obsolete table in a migration.\n' > "$WORK/delete.md"
out="$(bash "$SCRIPT" first "$WORK/delete.md")"
check "corroborated destructive signal fires" \
  "$WORK/delete.md:1:term=migration (corroborated by: deletion)" "$out"

# A weak term plus a strong term: the strong term fires on its own.
printf 'The token is a credential.\n' > "$WORK/cred.md"
out="$(bash "$SCRIPT" first "$WORK/cred.md")"
check "strong term fires regardless of weak terms" "$WORK/cred.md:1:term=credential" "$out"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
