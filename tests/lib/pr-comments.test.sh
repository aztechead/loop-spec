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

# ── Case 8b: bot REVIEW / skip probe ─────────────────────────────────────────
BOTFIX="$WORK/bot-review.json"
cat > "$BOTFIX" << 'EOF'
{
  "reviewComments": [
    {"id": 401, "path": "src/a.clj", "line": 8, "user": {"login": "copilot-pull-request-reviewer[bot]"},
     "body": "this leaks the token", "html_url": "https://x/pr/1#rc-401"}
  ],
  "reviews": [
    {"id": 501, "user": {"login": "copilot-pull-request-reviewer[bot]"},
     "state": "CHANGES_REQUESTED", "body": "", "html_url": "https://x/pr/1#r-501"},
    {"id": 502, "user": {"login": "alice"}, "state": "APPROVED", "body": "LGTM", "html_url": "https://x/pr/1#r-502"},
    {"id": 503, "user": {"login": "loop-spec[bot]"}, "state": "COMMENTED",
     "body": "<!-- loop-spec:revise -->\n## loop-spec revise summary\n", "html_url": "https://x/pr/1#r-503"}
  ],
  "issueComments": [
    {"id": 601, "user": {"login": "dependabot[bot]"}, "body": "Dependabot is updating npm"},
    {"id": 602, "user": {"login": "github-actions[bot]"}, "body": "CI passed"},
    {"id": 603, "user": {"login": "custom-reviewer[bot]"}, "body": "please rename this helper"},
    {"id": 604, "user": {"login": "alice"}, "body": "can we also update the docs?"}
  ]
}
EOF
out="$(bash "$LIB" fetch --fixture "$BOTFIX")"
check "8b: empty CHANGES_REQUESTED from review bot is kept" "1" \
  "$(jq '[.[] | select(.id == 501 and .skip == false)] | length' <<<"$out")"
check "8b: review bot skipReason empty" "" \
  "$(jq -r '.[] | select(.id == 501) | .skipReason' <<<"$out")"
check "8b: inline review_comment from review bot is kept" "1" \
  "$(jq '[.[] | select(.id == 401 and .skip == false and .kind == "review_comment")] | length' <<<"$out")"
check "8b: bare LGTM is skipped" "bare-approval" \
  "$(jq -r '.[] | select(.id == 502) | .skipReason' <<<"$out")"
check "8b: self revise marker is skipped" "self-revise-comment" \
  "$(jq -r '.[] | select(.id == 503) | .skipReason' <<<"$out")"
check "8b: dependabot issue comment is noise" "noise-bot" \
  "$(jq -r '.[] | select(.id == 601) | .skipReason' <<<"$out")"
check "8b: github-actions issue comment is noise" "noise-bot" \
  "$(jq -r '.[] | select(.id == 602) | .skipReason' <<<"$out")"
check "8b: other bot issue comment skipped" "bot-issue-comment" \
  "$(jq -r '.[] | select(.id == 603) | .skipReason' <<<"$out")"
check "8b: human issue comment kept" "false" \
  "$(jq -r '.[] | select(.id == 604) | .skip' <<<"$out")"
out="$(LOOP_SPEC_REVIEW_BOT_ALLOWLIST='custom-reviewer[bot]' bash "$LIB" fetch --fixture "$BOTFIX")"
check "8b: allowlist keeps a bot issue comment" "false" \
  "$(jq -r '.[] | select(.id == 603) | .skip' <<<"$out")"
check "8b: allowlist does not unskip a self-revise comment" "self-revise-comment" \
  "$(jq -r '.[] | select(.id == 503) | .skipReason' <<<"$out")"
out="$(bash "$LIB" summary --fixture "$BOTFIX")"
check "8b: summary unresolved ignores skipped items" "3" "$(jq '.unresolved' <<<"$out")"

# ── Case 9: live API auth failure refreshes and retries exactly once ──────────
mkdir -p "$WORK/shims" "$WORK/repo"
TARGET_REPO="$(cd "$WORK/repo" && pwd -P)"
GH_LOG="$WORK/gh.log"
AUTH_MARKER="$WORK/auth-failed-once"
REFRESH_LOG="$WORK/refresh.log"
cat > "$WORK/shims/gh" <<'GH'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "${FAKE_GH_LOG:?}"
case "${1:-} ${2:-}" in
  "api repos/test/repo/pulls/7/comments")
    if [[ ! -f "${FAKE_AUTH_MARKER:?}" ]]; then
      : > "$FAKE_AUTH_MARKER"
      echo "HTTP 401: Bad credentials" >&2
      exit 1
    fi
    [[ "${GH_TOKEN:-}" == "comments-refreshed-token" ]] \
      || { echo "HTTP 403: stale credential" >&2; exit 1; }
    printf '[]\n'
    ;;
  "api repos/test/repo/pulls/7/reviews"|"api repos/test/repo/issues/7/comments")
    printf '[]\n'
    ;;
  "api graphql")
    printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}\n'
    ;;
  *)
    echo "fake gh: unhandled $*" >&2
    exit 1
    ;;
esac
GH
chmod +x "$WORK/shims/gh"

REFRESH_HOOK="$WORK/refresh-comments.sh"
cat > "$REFRESH_HOOK" <<'REFRESH'
#!/usr/bin/env bash
set -uo pipefail
printf '%s|%s|%s|%s\n' "$LOOP_SPEC_CREDENTIAL_REFRESH_STAGE" \
  "$LOOP_SPEC_CREDENTIAL_REFRESH_REASON" "$LOOP_SPEC_CREDENTIAL_REFRESH_HOST" "$PWD" \
  >> "${FAKE_REFRESH_LOG:?}"
if [[ "$LOOP_SPEC_CREDENTIAL_REFRESH_REASON" == "auth-retry" ]]; then
  printf '{"GH_TOKEN":"comments-refreshed-token"}\n'
else
  printf '{"GH_TOKEN":"comments-initial-token"}\n'
fi
REFRESH
chmod +x "$REFRESH_HOOK"

: > "$GH_LOG"; : > "$REFRESH_LOG"; rm -f "$AUTH_MARKER"
ec=0
out="$(cd "$WORK/repo" && PATH="$WORK/shims:$PATH" FAKE_GH_LOG="$GH_LOG" \
  FAKE_AUTH_MARKER="$AUTH_MARKER" FAKE_REFRESH_LOG="$REFRESH_LOG" \
  LOOP_SPEC_CREDENTIAL_REFRESH_CMD="$REFRESH_HOOK" bash "$LIB" fetch 7 --repo test/repo \
  2>"$WORK/live.err")" || ec=$?
check "9: comments auth refresh exit 0" "0" "$ec"
check "9: comments auth refresh result" "0" "$(jq 'length' <<<"$out")"
check "9: comments API attempted twice" "2" \
  "$(grep -c '^api repos/test/repo/pulls/7/comments ' "$GH_LOG" || true)"
check "9: comments auth refresh once" "1" \
  "$(grep -c '^github-api|auth-retry|github.com|' "$REFRESH_LOG" || true)"
check "9: comments hook target repo" "1" \
  "$([[ "$(grep -cF "github-api|pre-stage|github.com|$TARGET_REPO" "$REFRESH_LOG" || true)" -gt 0 ]] && echo 1 || echo 0)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
