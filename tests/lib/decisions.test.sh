#!/usr/bin/env bash
# Tests for lib/decisions.sh (durable assumed-decision record).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/lib/decisions.sh"
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

WORK="${TMPDIR:-/tmp}"; WORK="${WORK%/}/decisions-test.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"
STAGING="$WORK/staging"
FEATURE="$WORK/feature"

# empty state
check "count on empty dir is 0" "0" "$(bash "$SCRIPT" count "$STAGING")"
check "list on empty dir silent" "" "$(bash "$SCRIPT" list "$STAGING")"
check "render on empty dir silent" "" "$(bash "$SCRIPT" render "$STAGING")"

# bad invocation
ec=0; bash "$SCRIPT" add "$STAGING" cycle >/dev/null 2>&1 || ec=$?
check "add with missing args exits 1" "1" "$ec"
ec=0; bash "$SCRIPT" bogus >/dev/null 2>&1 || ec=$?
check "unknown subcommand exits 1" "1" "$ec"

# add creates dir + appends
check "first add" "recorded" "$(bash "$SCRIPT" add "$STAGING" cycle "Which repos participate?" "all discovered" "autonomous default: take all")"
check "second add" "recorded" "$(bash "$SCRIPT" add "$STAGING" cycle "Test command?" "npm test" "trusted detection")"
check "count is 2" "2" "$(bash "$SCRIPT" count "$STAGING")"

# JSONL well-formed, fields intact
line1="$(bash "$SCRIPT" list "$STAGING" | head -1)"
check "phase field" "cycle" "$(jq -r '.phase' <<<"$line1")"
check "question field" "Which repos participate?" "$(jq -r '.question' <<<"$line1")"
check "answer field" "all discovered" "$(jq -r '.answer' <<<"$line1")"
check "ts is ISO" "yes" "$(jq -r '.ts' <<<"$line1" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' && echo yes || echo no)"

# render produces the SPEC.md list lines
r="$(bash "$SCRIPT" render "$STAGING" | head -1)"
check "render format" "- **Which repos participate?** → all discovered — autonomous default: take all" "$r"
check "render line count" "2" "$(bash "$SCRIPT" render "$STAGING" | wc -l | tr -d ' ')"

# special characters survive the JSON round-trip
bash "$SCRIPT" add "$STAGING" spec 'Use "quotes" & <tags>?' 'yes — with $vars' 'tricky / punctuation' >/dev/null
check "special chars intact" 'Use "quotes" & <tags>?' "$(bash "$SCRIPT" list "$STAGING" | tail -1 | jq -r '.question')"

# migrate: staging -> feature, staging removed, append not overwrite
bash "$SCRIPT" add "$FEATURE" spec "Prior decision?" "kept" "already in feature" >/dev/null
check "migrate" "migrated" "$(bash "$SCRIPT" migrate "$STAGING" "$FEATURE")"
check "feature has all decisions" "4" "$(bash "$SCRIPT" count "$FEATURE")"
check "staging file gone" "0" "$(bash "$SCRIPT" count "$STAGING")"
check "migrate again is no-op" "nothing to migrate" "$(bash "$SCRIPT" migrate "$STAGING" "$FEATURE")"
check "feature order: pre-existing first" "Prior decision?" "$(bash "$SCRIPT" list "$FEATURE" | head -1 | jq -r '.question')"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
