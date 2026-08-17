#!/usr/bin/env bash
# issue-intake.sh - Issue-to-PR glue: pick up labeled GitHub issues and drive
# each through `claude -p "/loop-spec:intake autonomous ..."`, then report the
# resulting PR or intentional no-change conclusion (from
# .loop-spec/last-result.json) back on the issue.
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
# The agent invocation runs from the CURRENT directory (the target repo root)
# via the harness's own headless CLI (lib/harness.sh cli):
#   claude:   claude -p "/loop-spec:intake autonomous <text>" $LOOP_SPEC_ISSUE_INTAKE_CLAUDE_FLAGS
#             (default flags: --permission-mode acceptEdits)
#   opencode: opencode run --format json "Load the intake skill (skill tool) and
#             run: autonomous <text>" (no auto-approval; ordinary in-project
#             build-agent edits remain allowed and sensitive asks fail closed)
#   adk:      adk run "$LOOP_SPEC_ADK_AGENT_DIR" "Load the loop-spec-intake skill
#             and run: autonomous <text>" --jsonl (the agent directory is written
#             by lib/adk-install.sh; unset means no mounted agent to dispatch to)
# The intake skill's own provenance rules apply — the issue text is
# restructured, never invented.
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

# Harness seam: spawn the harness's own headless CLI with its own skill-command
# prefix (claude: `claude -p "/loop-spec:intake ..."`; opencode: `opencode run
# --format json` with a prompt that loads the skill via the native skill tool;
# adk: `adk run <agent-dir> "<prompt>" --jsonl`). Permission modes are
# claude-only; OpenCode and ADK use their configured permissions without
# auto-approval. LOOP_SPEC_ISSUE_INTAKE_CLAUDE_FLAGS still overrides verbatim.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/runtime-preflight.sh" check-jq || exit 2
RESULT_ROOT="$(bash "$SCRIPT_DIR/cycle-result.sh" resolve-root "$PWD")" || exit 2
AGENT_CLI="$(bash "$SCRIPT_DIR/harness.sh" cli)"
if [[ "$AGENT_CLI" == "opencode" ]]; then
  AGENT_ARGS=(run --format json)
  INTAKE_CMD="Load the loop-spec-intake skill and run:"
  CLAUDE_FLAGS="${LOOP_SPEC_ISSUE_INTAKE_CLAUDE_FLAGS:-}"
elif [[ "$AGENT_CLI" == "adk" ]]; then
  # ADK dispatches at a mounted agent directory rather than a bare prompt, and
  # only lib/adk-install.sh knows where the caller mounted it. Absence is a
  # missing prerequisite, not a fallback to another harness's flags.
  [[ -n "${LOOP_SPEC_ADK_AGENT_DIR:-}" ]] || \
    _die2 "harness is adk but LOOP_SPEC_ADK_AGENT_DIR is unset (run: bash lib/adk-install.sh install --project <dir>)"
  [[ -d "${LOOP_SPEC_ADK_AGENT_DIR}" ]] || \
    _die2 "LOOP_SPEC_ADK_AGENT_DIR='${LOOP_SPEC_ADK_AGENT_DIR}' is not a directory"
  AGENT_ARGS=(run "${LOOP_SPEC_ADK_AGENT_DIR}")
  INTAKE_CMD="Load the loop-spec-intake skill and run:"
  CLAUDE_FLAGS="${LOOP_SPEC_ISSUE_INTAKE_CLAUDE_FLAGS:---jsonl}"
else
  AGENT_ARGS=(-p)
  INTAKE_CMD="/loop-spec:intake"
  CLAUDE_FLAGS="${LOOP_SPEC_ISSUE_INTAKE_CLAUDE_FLAGS:---permission-mode acceptEdits}"
fi

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
  command -v "$AGENT_CLI" >/dev/null 2>&1 || { [[ "$DRY" == "1" ]] || _die2 "'$AGENT_CLI' not on PATH"; }
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
    echo "  2. ${AGENT_CLI} ${AGENT_ARGS[*]} \"${INTAKE_CMD} autonomous <issue #${number} text>\" ${CLAUDE_FLAGS}"
    echo "  3. read .loop-spec/last-result.json -> comment PR URL, no-change conclusion, or failure on issue #${number}"
    echo "  4. gh issue edit ${number} --add-label loop-spec:done|loop-spec:failed --remove-label loop-spec:in-progress"
    continue
  fi

  repo_args=()
  [[ -n "$REPO" ]] && repo_args=(--repo "$REPO")

  echo "issue-intake: claiming issue #${number} (${title})"
  gh issue edit "$number" ${repo_args[@]+"${repo_args[@]}"} --add-label "loop-spec:in-progress" >/dev/null 2>&1 \
    || echo "issue-intake: WARN could not add in-progress label to #${number} (continuing)" >&2

  # A failed invocation must not inherit a prior issue's successful pointer.
  result_file="$RESULT_ROOT/.loop-spec/last-result.json"
  result_is_current=0
  if bash "$SCRIPT_DIR/cycle-result.sh" clear --result-root "$RESULT_ROOT"; then
    result_is_current=1
    # shellcheck disable=SC2086  # CLAUDE_FLAGS is intentionally word-split
    "$AGENT_CLI" "${AGENT_ARGS[@]}" "${INTAKE_CMD} autonomous ${intake_text}" $CLAUDE_FLAGS
    claude_ec=$?
  else
    echo "issue-intake: cannot safely clear the prior terminal result" >&2
    claude_ec=2
  fi

  schema=""; cycle_type=""; status="unknown"; outcome=""; pr_url=""; checkpoint_pr_url=""
  slug=""; summary=""; no_change_reason=""; converged="false"; verification_status=""
  if [[ "$result_is_current" -eq 1 && -f "$result_file" ]]; then
    schema="$(jq -r '.schema // empty' "$result_file" 2>/dev/null || true)"
    cycle_type="$(jq -r '.cycleType // empty' "$result_file" 2>/dev/null || true)"
    status="$(jq -r '.status // "unknown"' "$result_file" 2>/dev/null || echo unknown)"
    outcome="$(jq -r '.outcome // empty' "$result_file" 2>/dev/null || true)"
    pr_url="$(jq -r '.prUrl // empty' "$result_file" 2>/dev/null || true)"
    checkpoint_pr_url="$(jq -r '.checkpointPrUrl // empty' "$result_file" 2>/dev/null || true)"
    slug="$(jq -r '.slug // empty' "$result_file" 2>/dev/null || true)"
    summary="$(jq -r '.summary // empty' "$result_file" 2>/dev/null || true)"
    no_change_reason="$(jq -r '.noChangeReason // empty' "$result_file" 2>/dev/null || true)"
    converged="$(jq -r '.converged // false' "$result_file" 2>/dev/null || echo false)"
    verification_status="$(jq -r '.verification.status // empty' "$result_file" 2>/dev/null || true)"
  fi

  work_cycle=0
  [[ "$cycle_type" == "full" || "$cycle_type" == "micro" || "$cycle_type" == "debug" ]] \
    && work_cycle=1
  expected_success_outcome=""
  case "$cycle_type" in
    full) expected_success_outcome="delivered" ;;
    micro) expected_success_outcome="verified" ;;
    debug) expected_success_outcome="fixed" ;;
  esac
  intentional_no_change=0
  if [[ "$schema" == "1" && "$work_cycle" -eq 1 && "$status" == "completed" &&
        "$outcome" == "no-change-needed" && "$no_change_reason" == "already-satisfied" &&
        "$converged" == "true" && "$verification_status" == "passed" &&
        -n "${summary//[[:space:]]/}" && -z "$pr_url" && -z "$checkpoint_pr_url" ]]; then
    intentional_no_change=1
  fi

  if [[ "$claude_ec" -eq 0 && "$schema" == "1" && "$work_cycle" -eq 1 &&
        "$status" == "completed" && "$converged" == "true" &&
        "$verification_status" == "passed" && "$outcome" == "$expected_success_outcome" &&
        -n "$pr_url" ]]; then
    outcome_label="loop-spec:done"
    comment="loop-spec processed this issue autonomously.

- **PR:** ${pr_url}
- **Feature:** \`${slug}\`
- **Summary:** ${summary:-not recorded by this loop-spec version}
- **Result:** ${status} (see \`.loop-spec/features/${slug}/result.json\` on the branch runner)

_Generated by lib/issue-intake.sh._"
  elif [[ "$claude_ec" -eq 0 && "$intentional_no_change" -eq 1 ]]; then
    outcome_label="loop-spec:done"
    comment="loop-spec processed this issue autonomously without an implementation PR.

- **Conclusion:** ${summary}
- **No-change reason:** \`${no_change_reason}\`
- **Feature:** \`${slug}\`
- **Result:** ${status} / ${outcome}

_Generated by lib/issue-intake.sh._"
  else
    outcome_label="loop-spec:failed"
    failures=$((failures + 1))
    comment="loop-spec attempted this issue autonomously and did NOT complete.

- **claude exit code:** ${claude_ec}
- **result status:** ${status}
- **summary:** ${summary:-none}
- **PR:** ${pr_url:-none}
- **checkpoint PR:** ${checkpoint_pr_url:-none}

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
