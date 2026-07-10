#!/usr/bin/env bash
# watch.sh - Bounded post-merge watch (ROADMAP-3.0 C2): after a cycle PR
# merges, did reality agree? Two questions, both computed from git/CI facts,
# never self-reports:
#   1. Did the default branch stay green for the watch window after the merge?
#   2. Did anyone push fixup commits touching the feature's files inside the
#      window? (ANY post-merge touch of just-shipped files counts — a fix is a
#      fix whether a human or a later loop authored it; the merge wasn't clean.)
#
# The verdict is appended to the feature's COMMITTED run digest
# (docs/loop-spec/telemetry/runs/{slug}.json, lib/run-digest.sh) as a `watch`
# object — this is the raw signal the trust governor (lib/trust.sh) consumes
# via the metrics contract (postMergeFixRate, watchWindowClean). Read-only
# beyond that: a dirty watch NEVER reopens a cycle by itself — it queues a
# `watch-regression` backlog entry (lib/backlog.sh), which the sentinel may
# pick up. The loops compose instead of coupling.
#
# NOT a daemon: run it from a cron/CI recipe after the window elapses
# (docs/loop-spec/sentinel.md). Re-runs overwrite `watch` — latest wins.
#
# Usage:
#   watch.sh run --slug <slug> [--branch <feature-branch>] [--repo <o/r>]
#                [--window-hours <n=24>] [--digests <dir>] [--repo-dir <dir=.>]
#                [--default-branch <name>]
#                [--fixture-pr <file>] [--fixture-runs <file>] [--now <epoch>]
#
#   --branch defaults to the digest's `branch` field, else "feat/<slug>".
#   --fixture-pr: JSON object {number, url, mergedAt, mergeCommit, files: [..]}
#     (live mode assembles the same from `gh pr list/view`). --fixture-runs:
#     `gh run list --json conclusion,status,createdAt` shaped array.
#
# watch object schema (version 1):
#   {"schema": 1, "checkedAt": ISO, "windowHours": N, "prNumber": N,
#    "prUrl": str|null, "mergedAt": ISO, "branchGreen": true|false|null,
#    "humanFixCommits": N|null, "clean": true|false|null}
#   branchGreen: null = no completed CI runs in the window (unknowable — a
#   repo without CI can never prove green; consumers fail closed on null).
#   clean: true only when branchGreen == true AND humanFixCommits == 0.
#
# Exit codes: 0 ran (verdict recorded, or nothing to watch yet),
#             2 bad invocation / missing digest / unreadable inputs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKLOG="$SCRIPT_DIR/backlog.sh"

_die2() { echo "watch.sh: $*" >&2; exit 2; }

cmd="${1:-}"
[[ "$cmd" == "run" ]] || _die2 "unknown subcommand '${cmd:-}' (usage: watch.sh run --slug <slug> ...)"
shift

SLUG=""; BRANCH=""; REPO=""; WINDOW_H=24
DIGESTS=""; REPO_DIR="."; DEFAULT_BRANCH=""
FIXTURE_PR=""; FIXTURE_RUNS=""; NOW=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --slug) SLUG="${2:-}"; shift 2 || shift ;;
    --branch) BRANCH="${2:-}"; shift 2 || shift ;;
    --repo) REPO="${2:-}"; shift 2 || shift ;;
    --window-hours) WINDOW_H="${2:-24}"; shift 2 || shift ;;
    --digests) DIGESTS="${2:-}"; shift 2 || shift ;;
    --repo-dir) REPO_DIR="${2:-.}"; shift 2 || shift ;;
    --default-branch) DEFAULT_BRANCH="${2:-}"; shift 2 || shift ;;
    --fixture-pr) FIXTURE_PR="${2:-}"; shift 2 || shift ;;
    --fixture-runs) FIXTURE_RUNS="${2:-}"; shift 2 || shift ;;
    --now) NOW="${2:-}"; shift 2 || shift ;;
    *) _die2 "unknown flag '$1'" ;;
  esac
done
[[ -n "$SLUG" ]] || _die2 "--slug is required"
[[ "$WINDOW_H" =~ ^[0-9]+$ ]] || _die2 "--window-hours must be a number (got '$WINDOW_H')"
[[ -z "$NOW" || "$NOW" =~ ^[0-9]+$ ]] || _die2 "--now must be a unix epoch (got '$NOW')"
NOW="${NOW:-$(date -u +%s)}"

DIGESTS="${DIGESTS:-${CLAUDE_PROJECT_DIR:-.}/docs/loop-spec/telemetry/runs}"
DIGEST_FILE="$DIGESTS/$SLUG.json"
[[ -f "$DIGEST_FILE" ]] || _die2 "no run digest for '$SLUG' at $DIGEST_FILE — nothing to watch"
digest="$(jq -c . "$DIGEST_FILE" 2>/dev/null)" || _die2 "digest is not valid JSON: $DIGEST_FILE"

BRANCH="${BRANCH:-$(jq -r '.branch // empty' <<<"$digest")}"
BRANCH="${BRANCH:-feat/$SLUG}"

repo_args=()
[[ -n "$REPO" ]] && repo_args=(--repo "$REPO")

# ── The merged PR (fixture seam mirrors the gh shapes) ────────────────────────
if [[ -n "$FIXTURE_PR" ]]; then
  [[ -f "$FIXTURE_PR" ]] || _die2 "fixture not found: $FIXTURE_PR"
  pr="$(jq -c . "$FIXTURE_PR" 2>/dev/null)" || _die2 "fixture is not valid JSON: $FIXTURE_PR"
else
  command -v gh >/dev/null 2>&1 || _die2 "'gh' not on PATH (post-merge watch needs it; use fixtures offline)"
  pr="$(gh pr list ${repo_args[@]+"${repo_args[@]}"} --head "$BRANCH" --state merged \
        --json number,url,mergedAt,mergeCommit --limit 1 2>/dev/null | jq -c '.[0] // null')" \
    || _die2 "gh pr list failed"
  if [[ "$pr" != "null" ]]; then
    pr_number="$(jq -r '.number' <<<"$pr")"
    files="$(gh pr view "$pr_number" ${repo_args[@]+"${repo_args[@]}"} --json files \
             --jq '[.files[].path]' 2>/dev/null || echo '[]')"
    pr="$(jq -c --argjson files "$files" '{number, url, mergedAt,
          mergeCommit: (.mergeCommit.oid // null), files: $files}' <<<"$pr")"
  fi
fi

merged_at="$(jq -r '.mergedAt // empty' <<<"${pr:-null}" 2>/dev/null || true)"
if [[ "$pr" == "null" || -z "$merged_at" ]]; then
  echo "watch: no merged PR for branch '$BRANCH' ($SLUG) — nothing to watch yet"
  exit 0
fi

merged_epoch="$(jq -rn --arg t "$merged_at" '$t | fromdateiso8601' 2>/dev/null)" \
  || _die2 "unparseable mergedAt '$merged_at'"
window_end=$(( merged_epoch + WINDOW_H * 3600 ))
if (( NOW < window_end )); then
  echo "watch: NOTE window still open ($(( (window_end - NOW) / 60 ))m remaining) — verdict is provisional; re-run after it closes (latest wins)"
fi

# ── Signal 1: default branch green in the window? ─────────────────────────────
if [[ -n "$FIXTURE_RUNS" ]]; then
  [[ -f "$FIXTURE_RUNS" ]] || _die2 "fixture not found: $FIXTURE_RUNS"
  runs="$(jq -c . "$FIXTURE_RUNS" 2>/dev/null)" || _die2 "fixture is not valid JSON: $FIXTURE_RUNS"
else
  if [[ -z "$DEFAULT_BRANCH" ]]; then
    DEFAULT_BRANCH="$(git -C "$REPO_DIR" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
    DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
  fi
  runs="$(gh run list ${repo_args[@]+"${repo_args[@]}"} --branch "$DEFAULT_BRANCH" \
          --json conclusion,status,createdAt --limit 50 2>/dev/null || echo '[]')"
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$runs" || runs="[]"
fi

branch_green="$(jq -c --argjson start "$merged_epoch" --argjson end "$window_end" '
  [.[] | select(.status == "completed"
                and ((try (.createdAt | fromdateiso8601) catch null) as $t
                     | $t != null and $t >= $start and $t <= $end))]
  | if any(.conclusion == "failure") then false
    elif any(.conclusion == "success") then true
    else null end' <<<"$runs")"

# ── Signal 2: post-merge commits touching the feature's files? ────────────────
merge_oid="$(jq -r '.mergeCommit // empty' <<<"$pr")"
fix_commits="null"
if [[ -n "$merge_oid" ]] && git -C "$REPO_DIR" rev-parse --verify --quiet "${merge_oid}^{commit}" >/dev/null 2>&1; then
  if [[ -z "$DEFAULT_BRANCH" ]]; then
    DEFAULT_BRANCH="$(git -C "$REPO_DIR" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
    DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
  fi
  tip="$DEFAULT_BRANCH"
  git -C "$REPO_DIR" rev-parse --verify --quiet "$tip" >/dev/null 2>&1 || tip="HEAD"
  # Pathspecs from the PR's file list bound the count to the feature's surface;
  # --until bounds it to the window. An unresolvable file list degrades to
  # all-paths (over-counts, never under-counts — fail closed).
  pathspec=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && pathspec+=("$f")
  done < <(jq -r '.files[]? // empty' <<<"$pr")
  until_iso="$(jq -rn --argjson e "$window_end" '$e | todate')"
  rl_args=(--count --no-merges --until="$until_iso" "${merge_oid}..${tip}")
  if [[ "${#pathspec[@]}" -gt 0 ]]; then rl_args+=(-- "${pathspec[@]}"); fi
  fix_commits="$(git -C "$REPO_DIR" rev-list "${rl_args[@]}" 2>/dev/null)" || fix_commits="null"
  [[ "$fix_commits" =~ ^[0-9]+$ ]] || fix_commits="null"
fi

# ── Verdict + digest append ───────────────────────────────────────────────────
watch="$(jq -cn \
  --argjson now "$NOW" --argjson windowHours "$WINDOW_H" \
  --argjson pr "$pr" --arg mergedAt "$merged_at" \
  --argjson branchGreen "$branch_green" --argjson fix "$fix_commits" '
  {
    schema: 1,
    checkedAt: ($now | todate),
    windowHours: $windowHours,
    prNumber: ($pr.number // null),
    prUrl: ($pr.url // null),
    mergedAt: $mergedAt,
    branchGreen: $branchGreen,
    humanFixCommits: $fix,
    clean: (if $branchGreen == true and $fix == 0 then true
            elif $branchGreen == false or ($fix != null and $fix > 0) then false
            else null end)
  }')"

tmp="$DIGEST_FILE.tmp"
jq -c --argjson w "$watch" '. + {watch: $w}' <<<"$digest" > "$tmp" || _die2 "could not update digest"
mv "$tmp" "$DIGEST_FILE"

clean="$(jq -r '.clean' <<<"$watch")"
echo "watch: $SLUG branchGreen=$(jq -r '.branchGreen' <<<"$watch") fixCommits=$(jq -r '.humanFixCommits' <<<"$watch") clean=$clean -> recorded in $DIGEST_FILE"

# A dirty window queues work for the sentinel; it never reopens a cycle here.
# Dedupe on a deterministic gap-id (slug + PR), not the text — the verdict
# details in the text may differ between re-runs of the same dirty window.
if [[ "$clean" == "false" ]]; then
  pr_number="$(jq -r '.prNumber' <<<"$watch")"
  gid="$(bash "$BACKLOG" gap-id "watch-regression $SLUG pr $pr_number" 2>/dev/null || true)"
  text="post-merge watch found regressions after merging '$SLUG' (PR #$pr_number): branchGreen=$(jq -r '.branchGreen' <<<"$watch"), fixup commits touching its files=$(jq -r '.humanFixCommits' <<<"$watch") — investigate the merge"
  id_args=()
  [[ -n "$gid" ]] && id_args=(--id "$gid")
  bash "$BACKLOG" add "$SLUG" watch-regression "$text" ${id_args[@]+"${id_args[@]}"} >/dev/null 2>&1 \
    || echo "watch: WARN could not queue backlog entry for dirty window" >&2
  echo "watch: dirty window -> queued watch-regression backlog entry for the sentinel"
fi
exit 0
