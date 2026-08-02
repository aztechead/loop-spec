#!/usr/bin/env bash
# pr-comments.sh - Fetch and normalize GitHub PR review feedback into a stable
# JSON shape for /loop-spec:revise and the terminal PR feedback check
# (skills/shared/pr-feedback-check.md). Read-only; never mutates the PR.
#
# Usage:
#   pr-comments.sh fetch <pr-number> [--repo <owner/repo>] [--include-resolved]
#   pr-comments.sh fetch --fixture <file> [--include-resolved]
#   pr-comments.sh summary <pr-number> [--repo <owner/repo>]
#   pr-comments.sh summary --fixture <file>
#
# Output: a JSON array on stdout, one element per feedback item:
#   [{
#     "id":       <number|string>,      # comment/review database id
#     "kind":     "review_comment" | "review" | "issue_comment",
#     "path":     "<file path or null>",
#     "line":     <line number or null>,
#     "author":   "<login>",
#     "body":     "<markdown body>",
#     "resolved": true|false,           # review threads only; false when unknown
#     "url":      "<html url or null>"
#   }]
#
# `summary` wraps the same items in one feedback-check object (the shape every
# cycle type's terminal PR check consumes):
#   {"reviewDecision": "APPROVED|CHANGES_REQUESTED|REVIEW_REQUIRED|NONE",
#    "changesRequested": bool, "requestedReviewers": ["<login-or-team-slug>"],
#    "unresolved": <count of items>, "items": [...]}
# Live decision/requests come from `gh pr view --json reviewDecision,reviewRequests`;
# a failed metadata call degrades loudly to reviewDecision "NONE" on stderr.
# Fixture mode reads optional top-level "reviewDecision" / "reviewRequests" keys.
#
# Resolved detection: review-comment thread state comes from the GraphQL
# reviewThreads API. When that call fails (no auth scope, GHE, offline) the
# script degrades loudly: one stderr note, every thread treated as UNRESOLVED
# (never silently dropped). Resolved items are filtered out unless
# --include-resolved is passed.
#
# Fixture mode (--fixture) feeds the SAME normalize step from a file with shape:
#   {"reviewComments": [...], "reviews": [...], "issueComments": [...],
#    "resolvedIds": [<ids>]}
# so offline tests exercise exactly the jq the live path uses. Requires no gh.
#
# Exit codes: 0 ok; 1 fetch/parse failure; 2 bad invocation.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=credential-refresh.sh
. "$script_dir/credential-refresh.sh"
# shellcheck source=bounded-run.sh
. "$script_dir/bounded-run.sh"

# Every gh call below reaches the network; several are --paginate loops. Unbounded,
# any one of them can stall an unattended run indefinitely.
loop_spec_disable_interactive_prompts
_pr_comments_timeout="$(loop_spec_resolve_timeout "${LOOP_SPEC_GH_COMMAND_TIMEOUT_SECONDS:-}" 60)" \
  || _pr_comments_timeout=60

_die2() { echo "pr-comments.sh: $*" >&2; exit 2; }

cmd="${1:-}"
case "$cmd" in
  fetch|summary) ;;
  *) _die2 "unknown subcommand '${cmd:-}' (usage: pr-comments.sh fetch|summary <pr-number> [--repo <o/r>] [--include-resolved] | fetch|summary --fixture <file>)" ;;
esac
shift

PR=""
REPO=""
FIXTURE=""
INCLUDE_RESOLVED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 || shift ;;
    --fixture) FIXTURE="${2:-}"; shift 2 || shift ;;
    --include-resolved) INCLUDE_RESOLVED=1; shift ;;
    -*) _die2 "unknown flag '$1'" ;;
    *) PR="$1"; shift ;;
  esac
done

# Shared normalize: input = the combined raw object, output = the stable array.
_normalize() {
  jq -c --argjson include_resolved "$INCLUDE_RESOLVED" '
    (.resolvedIds // []) as $resolved |
    (
      ((.reviewComments // []) | map(.id as $id | {
        id: $id,
        kind: "review_comment",
        path: (.path // null),
        line: (.line // .original_line // null),
        author: (.user.login // "unknown"),
        body: (.body // ""),
        resolved: (($resolved | index($id)) != null),
        url: (.html_url // null)
      }))
      +
      ((.reviews // []) | map(select((.body // "") != "")) | map({
        id: .id,
        kind: "review",
        path: null,
        line: null,
        author: (.user.login // "unknown"),
        body: (.body // ""),
        resolved: false,
        url: (.html_url // null)
      }))
      +
      ((.issueComments // []) | map({
        id: .id,
        kind: "issue_comment",
        path: null,
        line: null,
        author: (.user.login // "unknown"),
        body: (.body // ""),
        resolved: false,
        url: (.html_url // null)
      }))
    )
    | map(select(($include_resolved == 1) or (.resolved | not)))
  '
}

# _summarize <items-json> <meta-json>: compose the terminal feedback-check object.
# meta carries {reviewDecision, reviewRequests, metadataStatus} from gh pr view or the fixture.
_summarize() {
  jq -cn --argjson items "$1" --argjson meta "$2" '
    (($meta.reviewDecision // "") | if . == "" then "NONE" else . end) as $decision |
    {
      reviewDecision: $decision,
      metadataStatus: ($meta.metadataStatus // "complete"),
      changesRequested: ($decision == "CHANGES_REQUESTED"),
      requestedReviewers: [($meta.reviewRequests // [])[] | (.login // .name // .slug // "unknown")],
      unresolved: ($items | length),
      items: $items
    }
  '
}

if [[ -n "$FIXTURE" ]]; then
  [[ -f "$FIXTURE" ]] || { echo "pr-comments.sh: fixture file not found: $FIXTURE" >&2; exit 1; }
  items="$(_normalize < "$FIXTURE")" || { echo "pr-comments.sh: fixture is not valid JSON" >&2; exit 1; }
  if [[ "$cmd" == "summary" ]]; then
    meta="$(jq -c '{reviewDecision: (.reviewDecision // ""), reviewRequests: (.reviewRequests // []), metadataStatus:"complete"}' "$FIXTURE")" \
      || { echo "pr-comments.sh: fixture is not valid JSON" >&2; exit 1; }
    _summarize "$items" "$meta"
  else
    printf '%s\n' "$items"
  fi
  exit 0
fi

[[ -n "$PR" ]] || _die2 "missing <pr-number>"
command -v gh >/dev/null 2>&1 || { echo "pr-comments.sh: 'gh' not on PATH" >&2; exit 1; }

repo_dir="$(pwd -P)"
credential_host="${GH_HOST:-github.com}"
auth_tmp="$(mktemp -d "${TMPDIR:-/tmp}/loop-spec-pr-comments-XXXXXX")" \
  || { echo "pr-comments.sh: cannot allocate temporary files" >&2; exit 1; }
trap 'rm -rf "$auth_tmp"' EXIT

_run_gh_once() {
  local stdout_file="$1" stderr_file="$2"
  shift 2
  loop_spec_run_bounded "$_pr_comments_timeout" "$stdout_file" "$stderr_file" "$@"
}

_run_gh() {
  local stage="$1" stdout_file="$2" stderr_file="$3"
  shift 3
  loop_spec_run_authenticated "$repo_dir" "$stage" "$credential_host" \
    "$stdout_file" "$stderr_file" _run_gh_once "$stdout_file" "$stderr_file" "$@"
}

_die_auth() {
  jq -cn --arg code "$LOOP_SPEC_AUTH_ERROR_CODE" \
    --arg error "$LOOP_SPEC_AUTH_ERROR_MESSAGE" \
    --arg host "$credential_host" \
    '{schema:1,ok:false,errorCode:$code,error:$error,host:$host}' >&2
  exit 1
}

gh_out="$auth_tmp/gh.out"
gh_err="$auth_tmp/gh.err"

if [[ -z "$REPO" ]]; then
  resolve_rc=0
  _run_gh "github-repo" "$gh_out" "$gh_err" gh repo view --json nameWithOwner \
    || resolve_rc=$?
  [[ -z "$LOOP_SPEC_AUTH_ERROR_CODE" ]] || _die_auth
  [[ "$resolve_rc" -eq 0 ]] \
    || { echo "pr-comments.sh: cannot resolve repo (pass --repo <owner/repo>)" >&2; exit 1; }
  REPO="$(jq -r '.nameWithOwner // empty' "$gh_out" 2>/dev/null)"
  [[ -n "$REPO" ]] \
    || { echo "pr-comments.sh: cannot resolve repo (pass --repo <owner/repo>)" >&2; exit 1; }
fi
OWNER="${REPO%%/*}"
NAME="${REPO##*/}"

fetch_rc=0
_run_gh "github-api" "$gh_out" "$gh_err" gh api "repos/$REPO/pulls/$PR/comments" --paginate \
  || fetch_rc=$?
[[ -z "$LOOP_SPEC_AUTH_ERROR_CODE" ]] || _die_auth
[[ "$fetch_rc" -eq 0 ]] || { echo "pr-comments.sh: failed to fetch review comments for $REPO#$PR" >&2; exit 1; }
review_comments="$(jq -cs 'add // []' "$gh_out")" \
  || { echo "pr-comments.sh: failed to parse review comments for $REPO#$PR" >&2; exit 1; }

fetch_rc=0
_run_gh "github-api" "$gh_out" "$gh_err" gh api "repos/$REPO/pulls/$PR/reviews" --paginate \
  || fetch_rc=$?
[[ -z "$LOOP_SPEC_AUTH_ERROR_CODE" ]] || _die_auth
[[ "$fetch_rc" -eq 0 ]] || { echo "pr-comments.sh: failed to fetch reviews for $REPO#$PR" >&2; exit 1; }
reviews="$(jq -cs 'add // []' "$gh_out")" \
  || { echo "pr-comments.sh: failed to parse reviews for $REPO#$PR" >&2; exit 1; }

fetch_rc=0
_run_gh "github-api" "$gh_out" "$gh_err" gh api "repos/$REPO/issues/$PR/comments" --paginate \
  || fetch_rc=$?
[[ -z "$LOOP_SPEC_AUTH_ERROR_CODE" ]] || _die_auth
[[ "$fetch_rc" -eq 0 ]] || { echo "pr-comments.sh: failed to fetch issue comments for $REPO#$PR" >&2; exit 1; }
issue_comments="$(jq -cs 'add // []' "$gh_out")" \
  || { echo "pr-comments.sh: failed to parse issue comments for $REPO#$PR" >&2; exit 1; }

# Resolved thread ids via GraphQL; degrade loudly to "all unresolved" on failure.
resolved_ids="[]"
gql_rc=0
_run_gh "github-api" "$gh_out" "$gh_err" gh api graphql \
  -f query='query($owner:String!,$name:String!,$pr:Int!){
    repository(owner:$owner,name:$name){
      pullRequest(number:$pr){
        reviewThreads(first:100){
          nodes{ isResolved comments(first:100){ nodes{ databaseId } } }
        }
      }
    }
  }' -F owner="$OWNER" -F name="$NAME" -F pr="$PR" || gql_rc=$?
[[ -z "$LOOP_SPEC_AUTH_ERROR_CODE" ]] || _die_auth
gql_out=""
[[ "$gql_rc" -ne 0 ]] || gql_out="$(<"$gh_out")"
if [[ -n "$gql_out" ]]; then
  resolved_ids="$(jq -c '[.data.repository.pullRequest.reviewThreads.nodes[]?
    | select(.isResolved) | .comments.nodes[]?.databaseId] // []' <<<"$gql_out" 2>/dev/null || echo '[]')"
else
  echo "pr-comments.sh: reviewThreads GraphQL unavailable — treating every thread as unresolved" >&2
fi

items="$(jq -cn \
  --argjson reviewComments "$review_comments" \
  --argjson reviews "$reviews" \
  --argjson issueComments "$issue_comments" \
  --argjson resolvedIds "$resolved_ids" \
  '{reviewComments: $reviewComments, reviews: $reviews,
    issueComments: $issueComments, resolvedIds: $resolvedIds}' | _normalize)"

if [[ "$cmd" == "summary" ]]; then
  # Review decision + requested reviewers; degrade loudly, never silently.
  meta_rc=0
  _run_gh "github-pr" "$gh_out" "$gh_err" gh pr view "$PR" --repo "$REPO" \
    --json reviewDecision,reviewRequests || meta_rc=$?
  [[ -z "$LOOP_SPEC_AUTH_ERROR_CODE" ]] || _die_auth
  meta=""
  if [[ "$meta_rc" -eq 0 ]]; then
    meta="$(jq -c '{reviewDecision: (.reviewDecision // ""), reviewRequests: (.reviewRequests // []), metadataStatus:"complete"}' "$gh_out" 2>/dev/null)" \
      || meta=""
  fi
  if [[ -z "$meta" ]]; then
    echo "pr-comments.sh: gh pr view metadata unavailable — reporting reviewDecision NONE" >&2
    meta='{"reviewDecision":"","reviewRequests":[],"metadataStatus":"degraded"}'
  fi
  _summarize "$items" "$meta"
else
  printf '%s\n' "$items"
fi
