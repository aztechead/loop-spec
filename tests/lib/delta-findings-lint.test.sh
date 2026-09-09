#!/usr/bin/env bash
# Tests for lib/delta-findings-lint.sh -- only in-scope delta findings survive.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/lib/delta-findings-lint.sh"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then PASS=$((PASS+1)); echo "PASS: $name"
  else FAIL=$((FAIL+1)); echo "FAIL: $name (expected '$expected', got '$actual')"; fi
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/delta-findings-lint-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/delta.diff" <<'EOF'
--- a/PLAN.md
+++ b/PLAN.md
@@ -10,3 +10,4 @@
 ## Tasks
-- T1: add the export endpoint
+- T1: add the export endpoint behind the feature flag
+- T3: retry the upload   three times
 - T2: write the CSV
EOF

# --- keeps ---

out="$(printf 'DELTA-FINDINGS:\n1. unaddressed: item 2 - the retry budget is still unnamed\n' \
  | bash "$LIB" filter --diff "$tmp/delta.diff" - 2>/dev/null)"
check "unaddressed line survives, numbering stripped" \
  "unaddressed: item 2 - the retry budget is still unnamed" "$out"

out="$(printf -- '- introduced: "T3: retry the upload three times" [major] no backoff is named\n' \
  | bash "$LIB" filter --diff "$tmp/delta.diff" - 2>/dev/null)"
check "major introduced quoting an added line survives" \
  'introduced: "T3: retry the upload three times" [major] no backoff is named' "$out"

out="$(printf 'introduced: “T1: add the export endpoint behind the feature flag” [MAJOR] flag unnamed\n' \
  | bash "$LIB" filter --diff "$tmp/delta.diff" - 2>/dev/null | wc -l | tr -d ' ')"
check "curly quotes and an upper-case tag still match" "1" "$out"

# --- drops ---

err="$(printf 'introduced: "T2: write the CSV" [major] no schema\n' \
  | bash "$LIB" filter --diff "$tmp/delta.diff" - 2>&1 >/dev/null)"
check "introduced quoting unchanged text is dropped" "1" \
  "$(grep -c 'not-an-added-line' <<<"$err")"

err="$(printf 'introduced: "T3: retry the upload three times" [minor] wording\n' \
  | bash "$LIB" filter --diff "$tmp/delta.diff" - 2>&1 >/dev/null)"
check "minor introduced is dropped" "1" "$(grep -c ': minor$' <<<"$err")"

err="$(printf 'introduced: the retry task has no budget [major]\n' \
  | bash "$LIB" filter --diff "$tmp/delta.diff" - 2>&1 >/dev/null)"
check "introduced without a quote is dropped" "1" "$(grep -c 'no-quoted-line' <<<"$err")"

err="$(printf '3. [major] Gap: the plan never names the CSV delimiter\n' \
  | bash "$LIB" filter --diff "$tmp/delta.diff" - 2>&1 >/dev/null)"
check "a first-pass style finding is out of scope" "1" "$(grep -c 'out-of-scope' <<<"$err")"

# --- summary and headers ---

err="$(printf 'DELTA-FINDINGS:\nunaddressed: item 1\n\n[major] new gap\n' \
  | bash "$LIB" filter --diff "$tmp/delta.diff" - 2>&1 >/dev/null)"
check "summary counts kept and dropped, not headers or blanks" "1" \
  "$(grep -c 'delta-findings-lint: kept=1 dropped=1' <<<"$err")"

out="$(printf 'DELTA-VERIFIED: every item addressed\n' \
  | bash "$LIB" filter --diff "$tmp/delta.diff" - 2>/dev/null | wc -l | tr -d ' ')"
check "a verified reply yields no lines" "0" "$out"

printf 'unaddressed: item 1\n' > "$tmp/reply.txt"
out="$(bash "$LIB" filter --diff "$tmp/delta.diff" "$tmp/reply.txt" 2>/dev/null)"
check "reply from a file path" "unaddressed: item 1" "$out"

# --- failure paths ---

rc=0; printf 'unaddressed: x\n' | bash "$LIB" filter --diff "$tmp/missing.diff" - >/dev/null 2>&1 || rc=$?
check "unreadable diff exits 1" "1" "$rc"
rc=0; bash "$LIB" filter --diff "$tmp/delta.diff" "$tmp/missing.txt" >/dev/null 2>&1 || rc=$?
check "unreadable reply exits 1" "1" "$rc"
rc=0; bash "$LIB" filter "$tmp/delta.diff" >/dev/null 2>&1 || rc=$?
check "missing --diff exits 2" "2" "$rc"
rc=0; bash "$LIB" scan --diff "$tmp/delta.diff" - </dev/null >/dev/null 2>&1 || rc=$?
check "unknown subcommand exits 2" "2" "$rc"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
