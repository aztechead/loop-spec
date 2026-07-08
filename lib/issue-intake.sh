#!/usr/bin/env bash
# issue-intake.sh - Issue-to-PR glue: pick up labeled GitHub issues and drive
# each through `claude -p "/loop-spec:intake autonomous ..."`, then report the
# resulting PR (from .loop-spec/last-result.json) back on the issue.
#
# This is DELIBERATELY not a daemon and not a hook: it runs only when invoked
# (by you, a cron, /schedule, or the example GitHub Action in
# docs/examples/issue-to-pr.yml). Composition with a scheduler is documentation,
# not machinery.
#
# Usage:
#   issue-intake.sh run [--label loop-spec] [--limit 1] [--repo <owner/repo>]
#                       [--dry-run] [--fixture <file>]
#
#   --label    issues must carry this label to be picked up (default: loop-spec)
#   --limit    max issues processed this invocation (default: 1 — same bounded
#              posture as LOOP_SPEC_MAX_FEATURES for backlog drain)
#   --dry-run  print the planned actions, mutate nothing, invoke nothing
#   --fixture  read the issue list from a JSON file (gh issue list --json shape:
#              [{number,title,body,labels:[{name}]}]) instead of gh — offline tests
#
# Lifecycle labels (live mode): picked issues get `loop-spec:in-progress` before
# the run, then `loop-spec:done` or `loop-spec:failed` after; issues already
# carrying any lifecycle label are skipped, so re-runs never double-process.
#
# The claude invocation runs from the CURRENT directory (the target repo root)
# and is: claude -p "/loop-spec:intake autonomous <text>" $LOOP_SPEC_ISSUE_INTAKE_CLAUDE_FLAGS
# (default flags: --permission-mode acceptEdits). The intake skill's own
# provenance rules apply — the issue text is restructured, never invented.
#
# Exit codes: 0 = ran (possibly zero eligible issues); 1 = a processed issue
# failed; 2 = bad invocation / missing prerequisite.
set -uo pipefail

_die2() { echo "issue-intake.sh: $*" >&2; exit 2; }

cmd="${1:-}"
[[ "$cmd" == "run" ]] || _die2 "unknown subcommand '${cmd:-}' (usage: issue-intake.sh run [--label X] [--limit N] [--repo o/r] [--dry-run] [--fixture <file>])"
shift

LABEL="loop-spec"
LIMIT=1
REPO=""
DRY=0
FIXTURE=""
CLAUDE_FLAGS="${LOOP_SPEC_ISSUE_INTAKE_CLAUDE_FLAGS:---permission-mode acceptEdits}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label) LABEL="${2:-}"; shift 2 || shift ;;
    --limit) LIMIT="${2:-1}"; shift 2 || shift ;;
    --repo) REPO="${2:-}"; shift 2 || shift ;;
    --dry-run) DRY=1; shift ;;
    --fixture) FIXTURE="${2:-}"; shift 2 || shift ;;
    *) _die2 "unknown flag '$1'" ;;
  esac
done

[[ "$LIMIT" =~ ^[0-9]+$ ]] || _die2 "--limit must be a number (got '$LIMIT')"

# ── Load candidate issues ─────────────────────────────────────────────────────
if [[ -n "$FIXTURE" ]]; then
  [[ -f "$FIXTURE" ]] || { echo "issue-intake.sh: fixture not found: $FIXTURE" >&2; exit 2; }
  issues="$(jq -c . "$FIXTURE" 2>/dev/null)" || { echo "issue-intake.sh: fixture is not valid JSON" >&2; exit 2; }
else
  command -v gh >/dev/null 2>&1 || _die2 "'gh' not on PATH"
  command -v claude >/dev/null 2>&1 || { [[ "$DRY" == "1" ]] || _die2 "'claude' not on PATH"; }
  repo_args=()
  [[ -n "$REPO" ]] && repo_args=(--repo "$REPO")
  issues="$(gh issue list ${repo_args[@]+"${repo_args[@]}"} --label "$LABEL" --state open \
            --json number,title,body,labels --limit 50 2>/dev/null)" \
    || { echo "issue-intake.sh: gh issue list failed" >&2; exit 2; }
fi

# Skip anything already claimed/processed by a prior run.
eligible="$(jq -c '[.[] | select(
  ([.labels[]?.name] | any(. == "loop-spec:in-progress" or . == "loop-spec:done" or . == "loop-spec:failed") | not)
)]' <<<"$issues")"

count="$(jq 'length' <<<"$eligible")"
if [[ "$count" == "0" ]]; then
  echo "issue-intake: no eligible open issues with label '$LABEL'"
  exit 0
fi

processed=0
failures=0

while IFS= read -r issue; do
  (( processed >= LIMIT )) && break
  processed=$((processed + 1))

  number="$(jq -r '.number' <<<"$issue")"
  title="$(jq -r '.title // ""' <<<"$issue")"
  body="$(jq -r '.body // ""' <<<"$issue")"

  intake_text="Issue #${number}: ${title}

${body}

Source: GitHub issue #${number}"

  if [[ "$DRY" == "1" ]]; then
    echo "DRY-RUN issue #${number}:"
    echo "  1. gh issue edit ${number} --add-label loop-spec:in-progress"
    echo "  2. claude -p \"/loop-spec:intake autonomous <issue #${number} text>\" ${CLAUDE_FLAGS}"
    echo "  3. read .loop-spec/last-result.json -> comment PR URL (or failure) on issue #${number}"
    echo "  4. gh issue edit ${number} --add-label loop-spec:done|loop-spec:failed --remove-label loop-spec:in-progress"
    continue
  fi

  repo_args=()
  [[ -n "$REPO" ]] && repo_args=(--repo "$REPO")

  echo "issue-intake: claiming issue #${number} (${title})"
  gh issue edit "$number" ${repo_args[@]+"${repo_args[@]}"} --add-label "loop-spec:in-progress" >/dev/null 2>&1 \
    || echo "issue-intake: WARN could not add in-progress label to #${number} (continuing)" >&2

  # shellcheck disable=SC2086  # CLAUDE_FLAGS is intentionally word-split
  claude -p "/loop-spec:intake autonomous ${intake_text}" $CLAUDE_FLAGS
  claude_ec=$?

  result_file=".loop-spec/last-result.json"
  status="unknown"; pr_url=""; slug=""
  if [[ -f "$result_file" ]]; then
    status="$(jq -r '.status // "unknown"' "$result_file" 2>/dev/null || echo unknown)"
    pr_url="$(jq -r '.prUrl // .checkpointPrUrl // empty' "$result_file" 2>/dev/null || true)"
    slug="$(jq -r '.slug // empty' "$result_file" 2>/dev/null || true)"
  fi

  if [[ "$claude_ec" -eq 0 && "$status" == "completed" && -n "$pr_url" ]]; then
    outcome_label="loop-spec:done"
    comment="loop-spec processed this issue autonomously.

- **PR:** ${pr_url}
- **Feature:** \`${slug}\`
- **Result:** ${status} (see \`.loop-spec/features/${slug}/result.json\` on the branch runner)

_Generated by lib/issue-intake.sh._"
  else
    outcome_label="loop-spec:failed"
    failures=$((failures + 1))
    comment="loop-spec attempted this issue autonomously and did NOT complete.

- **claude exit code:** ${claude_ec}
- **result status:** ${status}
- **checkpoint/PR:** ${pr_url:-none}

The run's telemetry (result.json / events.jsonl) lives on the machine that ran it.
_Generated by lib/issue-intake.sh._"
  fi

  gh issue comment "$number" ${repo_args[@]+"${repo_args[@]}"} --body "$comment" >/dev/null 2>&1 \
    || echo "issue-intake: WARN could not comment on #${number}" >&2
  gh issue edit "$number" ${repo_args[@]+"${repo_args[@]}"} \
    --add-label "$outcome_label" --remove-label "loop-spec:in-progress" >/dev/null 2>&1 \
    || echo "issue-intake: WARN could not update labels on #${number}" >&2

  echo "issue-intake: issue #${number} -> ${outcome_label} ${pr_url:+(${pr_url})}"
done < <(jq -c '.[]' <<<"$eligible")

[[ "$failures" -gt 0 ]] && exit 1 || exit 0
