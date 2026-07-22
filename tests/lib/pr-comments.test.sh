#!/usr/bin/env bash
# Tests for lib/pr-comments.sh (fixture mode — offline, no gh required)
set -uo pipefail

LIB="$(cd "$(dirname "$0")/../.." && pwd)/lib/pr-comments.sh"
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

WORK="${TMPDIR:-/tmp}/loop-spec-pr-comments.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

FIXTURE="$WORK/pr.json"
cat > "$FIXTURE" << 'EOF'
{
  "reviewComments": [
    {"id": 101, "path": "lib/a.sh", "line": 12, "user": {"login": "alice"},
     "body": "this leaks on error", "html_url": "https://x/pr/1#rc-101"},
    {"id": 102, "path": "lib/b.sh", "original_line": 30, "user": {"login": "bob"},
     "body": "nit: rename", "html_url": "https://x/pr/1#rc-102"},
    {"id": 103, "path": "lib/a.sh", "line": 40, "user": {"login": "alice"},
     "body": "already fixed thread", "html_url": "https://x/pr/1#rc-103"}
  ],
  "reviews": [
    {"id": 201, "user": {"login": "carol"}, "body": "Overall LGTM but see inline notes", "html_url": "https://x/pr/1#r-201"},
    {"id": 202, "user": {"login": "dave"}, "body": "", "html_url": "https://x/pr/1#r-202"}
  ],
  "issueComments": [
    {"id": 301, "user": {"login": "erin"}, "body": "can we also update the docs?", "html_url": "https://x/pr/1#ic-301"}
  ],
  "resolvedIds": [103]
}
EOF

# ── Case 1: normalize + resolved filtering ────────────────────────────────────
out="$(bash "$LIB" fetch --fixture "$FIXTURE")"
check "1: valid JSON array" "1" "$(jq -e 'type == "array"' >/dev/null 2>&1 <<<"$out" && echo 1 || echo 0)"
check "1: resolved thread filtered out" "0" "$(jq '[.[] | select(.id == 103)] | length' <<<"$out")"
check "1: empty review body dropped" "0" "$(jq '[.[] | select(.id == 202)] | length' <<<"$out")"
check "1: total items (2 rc + 1 review + 1 ic)" "4" "$(jq 'length' <<<"$out")"

# ── Case 2: field mapping ─────────────────────────────────────────────────────
check "2: review_comment kind" "review_comment" "$(jq -r '.[] | select(.id == 101) | .kind' <<<"$out")"
check "2: path mapped" "lib/a.sh" "$(jq -r '.[] | select(.id == 101) | .path' <<<"$out")"
check "2: line mapped" "12" "$(jq -r '.[] | select(.id == 101) | .line' <<<"$out")"
check "2: original_line fallback" "30" "$(jq -r '.[] | select(.id == 102) | .line' <<<"$out")"
check "2: author mapped" "alice" "$(jq -r '.[] | select(.id == 101) | .author' <<<"$out")"
check "2: review kind has null path" "null" "$(jq -r '.[] | select(.id == 201) | .path' <<<"$out")"
check "2: issue_comment kind" "issue_comment" "$(jq -r '.[] | select(.id == 301) | .kind' <<<"$out")"
check "2: unresolved default false" "false" "$(jq -r '.[] | select(.id == 101) | .resolved' <<<"$out")"

# ── Case 3: --include-resolved keeps the resolved thread ──────────────────────
out="$(bash "$LIB" fetch --fixture "$FIXTURE" --include-resolved)"
check "3: resolved thread included" "1" "$(jq '[.[] | select(.id == 103)] | length' <<<"$out")"
check "3: resolved flag true" "true" "$(jq -r '.[] | select(.id == 103) | .resolved' <<<"$out")"
check "3: total items" "5" "$(jq 'length' <<<"$out")"

# ── Case 4: bad invocations ───────────────────────────────────────────────────
ec=0; bash "$LIB" fetch >/dev/null 2>&1 || ec=$?
check "4: missing pr number exit 2" "2" "$ec"
ec=0; bash "$LIB" bogus >/dev/null 2>&1 || ec=$?
check "4: unknown subcommand exit 2" "2" "$ec"
ec=0; bash "$LIB" fetch --fixture "$WORK/nope.json" >/dev/null 2>&1 || ec=$?
check "4: missing fixture exit 1" "1" "$ec"
echo 'not json' > "$WORK/bad.json"
ec=0; bash "$LIB" fetch --fixture "$WORK/bad.json" >/dev/null 2>&1 || ec=$?
check "4: corrupt fixture exit 1" "1" "$ec"

# ── Case 5: empty fixture yields empty array ──────────────────────────────────
echo '{}' > "$WORK/empty.json"
out="$(bash "$LIB" fetch --fixture "$WORK/empty.json")"
check "5: empty object -> []" "0" "$(jq 'length' <<<"$out")"

# ── Case 6: summary — feedback check for terminal PR delivery ────────────────
SUMFIX="$WORK/pr-summary.json"
jq '. + {"reviewDecision": "CHANGES_REQUESTED", "reviewRequests": [{"login": "frank"}, {"slug": "core-team"}]}' \
  "$FIXTURE" > "$SUMFIX"
out="$(bash "$LIB" summary --fixture "$SUMFIX")"
check "6: valid JSON object" "1" "$(jq -e 'type == "object"' >/dev/null 2>&1 <<<"$out" && echo 1 || echo 0)"
check "6: reviewDecision surfaced" "CHANGES_REQUESTED" "$(jq -r '.reviewDecision' <<<"$out")"
check "6: changesRequested flag" "true" "$(jq -r '.changesRequested' <<<"$out")"
check "6: requested reviewers mapped (login + team slug)" '["frank","core-team"]' "$(jq -c '.requestedReviewers' <<<"$out")"
check "6: unresolved counts filtered items" "4" "$(jq '.unresolved' <<<"$out")"
check "6: items match fetch shape" "4" "$(jq '.items | length' <<<"$out")"
check "6: resolved thread excluded from items" "0" "$(jq '[.items[] | select(.id == 103)] | length' <<<"$out")"

# ── Case 7: summary on a quiet PR is clean ───────────────────────────────────
echo '{}' > "$WORK/quiet.json"
out="$(bash "$LIB" summary --fixture "$WORK/quiet.json")"
check "7: empty decision normalized to NONE" "NONE" "$(jq -r '.reviewDecision' <<<"$out")"
check "7: changesRequested false" "false" "$(jq -r '.changesRequested' <<<"$out")"
check "7: no requested reviewers" "0" "$(jq '.requestedReviewers | length' <<<"$out")"
check "7: zero unresolved" "0" "$(jq '.unresolved' <<<"$out")"

# ── Case 8: summary bad invocations mirror fetch's contract ──────────────────
ec=0; bash "$LIB" summary >/dev/null 2>&1 || ec=$?
check "8: summary without pr number exit 2" "2" "$ec"
ec=0; bash "$LIB" summary --fixture "$WORK/nope.json" >/dev/null 2>&1 || ec=$?
check "8: summary missing fixture exit 1" "1" "$ec"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
