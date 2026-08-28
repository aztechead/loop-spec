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

# Context: a boundary/non-goal mention is the change saying it will LEAVE the
# surface alone. It must not buy a second critic.
printf 'Rename the helper.\nDo NOT touch the auth middleware.\n' > "$WORK/boundary.md"
rc=0; bash "$SCRIPT" first "$WORK/boundary.md" >/dev/null 2>&1 || rc=$?
check "negated scope verb does not fire" "1" "$rc"

printf 'Bump the pinned version.\nThis must never modify the permissions table.\n' \
  > "$WORK/never.md"
rc=0; bash "$SCRIPT" first "$WORK/never.md" >/dev/null 2>&1 || rc=$?
check "must-never-modify does not fire" "1" "$rc"

printf 'Leave the credential store unchanged.\n' > "$WORK/unchanged.md"
rc=0; bash "$SCRIPT" first "$WORK/unchanged.md" >/dev/null 2>&1 || rc=$?
check "declared-unchanged surface does not fire" "1" "$rc"

printf '## Non-Goals\n\n- Rotating the OAuth2 credentials.\n\n## Approach\n\n- Bump a pin.\n' \
  > "$WORK/nongoal.md"
rc=0; bash "$SCRIPT" first "$WORK/nongoal.md" >/dev/null 2>&1 || rc=$?
check "non-goal section does not fire" "1" "$rc"

# The suppression is auditable: the no-signal answer still names what it skipped.
err="$(bash "$SCRIPT" first "$WORK/boundary.md" 2>&1 >/dev/null || true)"
check "suppression reports its reason" "1" \
  "$(grep -c 'negated scope verb' <<<"$err")"

# The section ends at the next heading of the same or a higher level.
printf '## Non-Goals\n\n- Nothing here.\n\n## Approach\n\nRotate the auth token.\n' \
  > "$WORK/nongoal-end.md"
out="$(bash "$SCRIPT" first "$WORK/nongoal-end.md")"
check "signal after the non-goal section still fires" "$WORK/nongoal-end.md:7:term=auth" "$out"

# A heading is scanned like any other line: `## Auth rework` is the loudest signal
# an artifact carries, and a non-goal heading only opens the suppressed section.
printf '## Auth rework\n\nDetails follow.\n' > "$WORK/heading.md"
out="$(bash "$SCRIPT" first "$WORK/heading.md")"
check "a security term in a heading still fires" "$WORK/heading.md:1:term=auth" "$out"

# The negation window is one clause: a negation in an earlier clause must not
# suppress a mention in the next.
printf 'Do not rename the helper, and rotate the OAuth2 secret.\n' > "$WORK/clause.md"
out="$(bash "$SCRIPT" first "$WORK/clause.md")"
check "a negation in an earlier clause does not suppress" \
  "$WORK/clause.md:1:term=auth protocol" "$out"

printf 'Do not rename the helper — rotate the OAuth2 secret.\n' > "$WORK/emdash.md"
out="$(bash "$SCRIPT" first "$WORK/emdash.md")"
check "an em-dash is a clause boundary" \
  "$WORK/emdash.md:1:term=auth protocol" "$out"

# Coordinating "and" without a comma is one clause: splitting on "and" would
# fire the second half of "do not touch the auth middleware and the permissions
# table". The advertised compound uses a comma (or an em-dash).
printf 'Do not rename the helper and rotate the OAuth2 secret.\n' > "$WORK/and.md"
rc=0; bash "$SCRIPT" first "$WORK/and.md" >/dev/null 2>&1 || rc=$?
check "a comma-less coordinating and is one clause" "1" "$rc"

# Narrow by design: a negated ACTION on a security surface is a requirement, not
# a boundary. Only verbs of CHANGE suppress.
printf 'The service must never log the credential.\n' > "$WORK/negated-action.md"
out="$(bash "$SCRIPT" first "$WORK/negated-action.md")"
check "negated action still fires" "$WORK/negated-action.md:1:term=credential" "$out"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
