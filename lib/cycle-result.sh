#!/usr/bin/env bash
# Machine-readable cycle result contract for headless/programmatic callers.
#
# OBSERVABILITY CONTRACT: this script must NEVER abort a cycle. All internal
# failures print a one-line warning to stderr and exit 0. A broken telemetry
# writer must not kill a 2-hour run.
#
# Usage:
#   cycle-result.sh clear [--result-root <root>]
#   cycle-result.sh resolve-root [<path>]
#   cycle-result.sh write <feature_dir> --status <completed|paused|escalated|terminal|failed>
#                        [--pr-url <url>] [--reason <text>]
#   cycle-result.sh write-terminal --result-root <root> --cycle-type <micro|debug>
#                        --status <status> --outcome <outcome> --title <title>
#                        --converged <true|false> [compatibility/result fields...]
#
# Reads <feature_dir>/feature.json and writes <feature_dir>/result.json, then
# copies it to <feature_dir>/../../last-result.json (i.e., .loop-spec/last-result.json,
# since feature dirs live at .loop-spec/features/<slug>).
#
# Also emits a matching event via lib/events.sh (event = the status value) so
# events.jsonl and result.json can't disagree.
#
# result.json schema (schema version 1):
# {
#   "schema": 1,
#   "slug": "...",
#   "status": "completed | paused | escalated | terminal",
#   "reason": "<--reason text or null>",
#   "phaseReached": "<logical phase, including delivery.json completion>",
#   "branch": "<.branch>",
#   "baseBranch": "<.baseBranch>",
#   "prUrl": "<--pr-url arg, else delivery.json/feature.json .prUrl, else null>",
#   "checkpointPrUrl": "<feature.json .checkpointPrUrl // null>",
#   "delivery": "<delivery.json, else feature.json .delivery, else null>",
#   "converged": <true iff status==completed AND no warnings[] entry starts
#                 with "iterate-budget-spent:" or "iterate-terminal:", AND an
#                 explicit delivery block is ready-for-review (legacy state with
#                 no delivery block remains compatible)>,
#   "iterations": {"used": <.iterate.used // 0>, "max": <.iterate.maxIterations // null>},
#   "warnings": <.warnings // []>,
#   "autonomous": <.autonomous // false>,
#   "feature_title": "<.feature_title // .slug>",
#   "createdAt": "<.createdAt // null>",
#   "finishedAt": "<now ISO-8601 UTC>"
# }
#
# events.jsonl and result.json are local telemetry, deliberately not committed.
#
# Missing feature.json → one-line stderr warning, exit 0 (observability never aborts).
# Bad --status value → one-line stderr warning, exit 0, write nothing.
#
# Exit codes: writes always return 0 (observability never aborts); `clear` returns 1
# when it cannot safely remove the stale pointer so an entry point cannot reuse it.
set -uo pipefail

VALID_STATUSES="completed paused escalated terminal failed"

_is_valid_status() {
  local s="$1"
  for v in $VALID_STATUSES; do
    [[ "$s" == "$v" ]] && return 0
  done
  return 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_write_atomic() {
  local content="$1" destination="$2" tmp
  tmp="${destination}.tmp.$$"
  mkdir -p "$(dirname "$destination")" 2>/dev/null || return 1
  printf '%s\n' "$content" > "$tmp" 2>/dev/null || return 1
  mv "$tmp" "$destination" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

_prepare_result_root() {
  local root="$1"
  [[ ! -L "$root/.loop-spec" ]] || return 1
  mkdir -p "$root/.loop-spec" 2>/dev/null || return 1
  if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    bash "$SCRIPT_DIR/runtime-ignore.sh" ensure "$root" >/dev/null 2>&1 || return 1
  fi
}

_resolve_result_root() {
  local input="$1" abs first_worktree_line
  abs="$(cd "$input" 2>/dev/null && pwd -P)" || return 1
  if git -C "$abs" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    first_worktree_line="$(git -C "$abs" worktree list --porcelain 2>/dev/null | {
      IFS= read -r line || true
      printf '%s' "${line:-}"
    })"
    if [[ "$first_worktree_line" == worktree\ * ]]; then
      printf '%s\n' "${first_worktree_line#worktree }"
      return 0
    fi
  fi
  printf '%s\n' "$abs"
}

case "${1:-}" in
  resolve-root)
    shift
    _resolve_result_root "${1:-$PWD}" || {
      echo "cycle-result.sh: cannot resolve result root: ${1:-$PWD}" >&2
      exit 1
    }
    exit 0
    ;;
  clear)
    shift
    result_root="$PWD"
    if [[ "${1:-}" == "--result-root" && -n "${2:-}" ]]; then
      result_root="$2"
    fi
    result_root_abs="$(_resolve_result_root "$result_root")" || {
      echo "cycle-result.sh: cannot resolve result root for stale-pointer clearing: $result_root" >&2
      exit 1
    }
    if [[ -L "$result_root_abs/.loop-spec" ]]; then
      echo "cycle-result.sh: refusing symlinked result directory: $result_root_abs/.loop-spec" >&2
      exit 1
    fi
    rm -f "$result_root_abs/.loop-spec/last-result.json" || {
      echo "cycle-result.sh: cannot clear stale result pointer: $result_root_abs/.loop-spec/last-result.json" >&2
      exit 1
    }
    exit 0
    ;;
  write-terminal)
    shift
    result_root="" cycle_type="" status="" outcome="" slug="" title=""
    branch="" base_branch="" pr_url="" reason="" converged=""
    verification_status="not-run" verification_command="" autonomous="false"
    warnings_json="[]"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --result-root) result_root="${2:-}"; shift 2 || true ;;
        --cycle-type) cycle_type="${2:-}"; shift 2 || true ;;
        --status) status="${2:-}"; shift 2 || true ;;
        --outcome) outcome="${2:-}"; shift 2 || true ;;
        --slug) slug="${2:-}"; shift 2 || true ;;
        --title) title="${2:-}"; shift 2 || true ;;
        --branch) branch="${2:-}"; shift 2 || true ;;
        --base-branch) base_branch="${2:-}"; shift 2 || true ;;
        --pr-url) pr_url="${2:-}"; shift 2 || true ;;
        --reason) reason="${2:-}"; shift 2 || true ;;
        --converged) converged="${2:-}"; shift 2 || true ;;
        --verification-status) verification_status="${2:-}"; shift 2 || true ;;
        --verification-command) verification_command="${2:-}"; shift 2 || true ;;
        --autonomous) autonomous="${2:-}"; shift 2 || true ;;
        --warnings-json) warnings_json="${2:-}"; shift 2 || true ;;
        *) shift || true ;;
      esac
    done
    if [[ -z "$result_root" || -z "$cycle_type" || -z "$status" || -z "$outcome" || -z "$title" ]]; then
      echo "cycle-result.sh: write-terminal requires --result-root --cycle-type --status --outcome --title" >&2
      exit 0
    fi
    _is_valid_status "$status" || { echo "cycle-result.sh: invalid --status '$status'" >&2; exit 0; }
    [[ "$cycle_type" == "micro" || "$cycle_type" == "debug" ]] || {
      echo "cycle-result.sh: invalid --cycle-type '$cycle_type'" >&2; exit 0; }
    [[ "$converged" == "true" || "$converged" == "false" ]] || {
      echo "cycle-result.sh: --converged must be true or false" >&2; exit 0; }
    case "$verification_status" in passed|failed|not-run) ;; *)
      echo "cycle-result.sh: invalid --verification-status '$verification_status'" >&2; exit 0;; esac
    success_outcome="verified"
    allowed_outcomes="verified verification-failed delivery-blocked promoted-to-full"
    if [[ "$cycle_type" == "debug" ]]; then
      success_outcome="fixed"
      allowed_outcomes="fixed instrumented-and-waiting promoted-to-full verification-failed delivery-blocked"
    fi
    case " $allowed_outcomes " in *" $outcome "*) ;; *)
      echo "cycle-result.sh: invalid $cycle_type --outcome '$outcome'" >&2; exit 0;; esac
    if [[ "$outcome" == "$success_outcome" ]]; then
      [[ "$status" == "completed" && "$converged" == "true" &&
         "$verification_status" == "passed" && -n "$pr_url" ]] || {
        echo "cycle-result.sh: successful outcome requires completed/passed/converged with a PR" >&2; exit 0; }
    elif [[ "$status" == "completed" || "$converged" == "true" ]]; then
      echo "cycle-result.sh: non-success outcome cannot be completed or converged" >&2
      exit 0
    elif [[ "$outcome" == "promoted-to-full" && "$status" != "escalated" ]]; then
      echo "cycle-result.sh: promoted-to-full requires escalated status" >&2
      exit 0
    elif [[ "$outcome" == "verification-failed" &&
            ( "$status" != "failed" || "$verification_status" != "failed" ) ]]; then
      echo "cycle-result.sh: verification-failed requires failed status and verification" >&2
      exit 0
    elif [[ "$outcome" == "delivery-blocked" &&
            ( "$status" != "failed" || "$verification_status" != "passed" ) ]]; then
      echo "cycle-result.sh: delivery-blocked requires failed status after passed verification" >&2
      exit 0
    elif [[ "$outcome" == "instrumented-and-waiting" &&
            ( "$status" != "failed" || "$verification_status" != "not-run" ) ]]; then
      echo "cycle-result.sh: instrumented-and-waiting requires failed status without verification" >&2
      exit 0
    fi
    [[ "$autonomous" == "true" || "$autonomous" == "false" ]] || autonomous="false"
    jq -e 'type == "array"' <<<"$warnings_json" >/dev/null 2>&1 || warnings_json="[]"
    result_root_abs="$(_resolve_result_root "$result_root")" || {
      echo "cycle-result.sh: cannot resolve result root: $result_root" >&2; exit 0; }
    _prepare_result_root "$result_root_abs" || {
      echo "cycle-result.sh: cannot prepare result root: $result_root_abs" >&2; exit 0; }
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    result_json="$(jq -cn --arg cycleType "$cycle_type" --arg status "$status" \
      --arg outcome "$outcome" --arg slug "$slug" --arg title "$title" \
      --arg branch "$branch" --arg base "$base_branch" --arg pr "$pr_url" \
      --arg reason "$reason" --arg verifyStatus "$verification_status" \
      --arg verifyCommand "$verification_command" --arg now "$now" \
      --argjson converged "$converged" --argjson autonomous "$autonomous" \
      --argjson warnings "$warnings_json" '
      {schema:1,cycleType:$cycleType,slug:(if $slug == "" then null else $slug end),
       status:$status,outcome:$outcome,reason:(if $reason == "" then null else $reason end),
       phaseReached:$cycleType,branch:(if $branch == "" then null else $branch end),
       baseBranch:(if $base == "" then null else $base end),
       prUrl:(if $pr == "" then null else $pr end),checkpointPrUrl:null,delivery:null,
       converged:$converged,iterations:{used:0,max:null},warnings:$warnings,
       autonomous:$autonomous,feature_title:$title,createdAt:null,finishedAt:$now,
       verification:{status:$verifyStatus,command:(if $verifyCommand == "" then null else $verifyCommand end)}}')" || {
      echo "cycle-result.sh: failed to build terminal result" >&2; exit 0; }
    destination="$result_root_abs/.loop-spec/last-result.json"
    _write_atomic "$result_json" "$destination" || {
      echo "cycle-result.sh: failed to write $destination" >&2; exit 0; }
    printf 'LOOP_SPEC_RESULT %s\n' "$result_json"
    exit 0
    ;;
  write)
    feature_dir="${2:-}"
    if [[ -z "$feature_dir" ]]; then
      echo "cycle-result.sh: bad invocation — usage: cycle-result.sh write <feature_dir> --status <status> [--pr-url <url>] [--reason <text>]" >&2
      exit 0
    fi
    features_dir="$(dirname "$feature_dir")"
    loop_spec_path="$(dirname "$features_dir")"
    if [[ -L "$feature_dir" || -L "$features_dir" || -L "$loop_spec_path" ]]; then
      echo "cycle-result.sh: refusing symlinked feature-state path: $feature_dir" >&2
      exit 0
    fi

    # Parse remaining flags
    status=""
    pr_url=""
    reason=""
    shift 2 || true
    while [[ $# -gt 0 ]]; do
      case "${1:-}" in
        --status)
          status="${2:-}"
          shift 2 || shift || true
          ;;
        --pr-url)
          pr_url="${2:-}"
          shift 2 || shift || true
          ;;
        --reason)
          reason="${2:-}"
          shift 2 || shift || true
          ;;
        *)
          shift || true
          ;;
      esac
    done

    # Validate status
    if [[ -z "$status" ]]; then
      echo "cycle-result.sh: --status is required" >&2
      exit 0
    fi
    if ! _is_valid_status "$status"; then
      echo "cycle-result.sh: invalid --status '$status'; must be one of: $VALID_STATUSES" >&2
      exit 0
    fi

    # Load feature.json
    fj="$feature_dir/feature.json"
    if [[ ! -f "$fj" ]]; then
      echo "cycle-result.sh: feature.json not found in $feature_dir" >&2
      exit 0
    fi

    fj_content="$(cat "$fj" 2>/dev/null)" || {
      echo "cycle-result.sh: cannot read $fj" >&2
      exit 0
    }
    delivery_content="null"
    if [[ -f "$feature_dir/delivery.json" ]]; then
      delivery_content="$(jq -c . "$feature_dir/delivery.json" 2>/dev/null || echo null)"
    fi

    # Build result.json with jq (never string-interpolate user text into JSON).
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    result_json="$(jq -cn \
      --arg now "$now" \
      --arg status "$status" \
      --arg pr_url_arg "$pr_url" \
      --arg reason_arg "$reason" \
      --argjson fj "$fj_content" \
      --argjson delivery "$delivery_content" \
      '
      # prUrl: explicit arg, successful delivery sidecar, tracked fallback.
      (if $pr_url_arg != "" then $pr_url_arg
       elif (($delivery.prUrl // "") != "") then $delivery.prUrl
       elif (($fj.prUrl // "") != "") then $fj.prUrl
       else null
       end) as $prUrl |
      # reason: --reason arg, or null
      (if $reason_arg != "" then $reason_arg else null end) as $reason |
       ($fj.warnings // []) as $stateWarnings |
       ([$delivery.targets[]?
          | select((.feedback.changesRequested // false) == true)
          | "pr-feedback-changes-requested:\(.name)"]
        + [$delivery.targets[]?
          | select((.feedback.observationStatus // "complete") == "degraded")
          | "pr-feedback-degraded:\(.name)"]
        | unique) as $feedbackWarnings |
       ([$delivery.targets[]?
          | select((.feedback.changesRequested // false) == true)] | length > 0) as $feedbackBlocking |
       ($stateWarnings + $feedbackWarnings) as $warnings |
       # converged: clean goal verdict plus a successful explicit delivery when present.
       (($status == "completed") and
        ($feedbackBlocking | not) and
        ($warnings
         | map(startswith("iterate-budget-spent:") or startswith("iterate-terminal:"))
         | any | not) and
       (if $delivery != null then (($delivery.status // "") == "ready-for-review")
        else (($fj | has("delivery") | not) or (($fj.delivery.status // "") == "ready-for-review"))
        end)) as $converged |
      {
        schema: 1,
        cycleType: "full",
        slug: $fj.slug,
        status: $status,
        outcome: (if $converged then "delivered" elif $status == "completed" then "completed-with-gaps" else $status end),
        reason: $reason,
        phaseReached: (if $status == "completed" and (($delivery.status // "") == "ready-for-review")
                       then "completed" else ($fj.currentPhase // null) end),
        branch: ($fj.branch // null),
        baseBranch: ($fj.baseBranch // null),
        prUrl: $prUrl,
        checkpointPrUrl: ($fj.checkpointPrUrl // null),
        delivery: (if $delivery != null then $delivery else ($fj.delivery // null) end),
        converged: $converged,
        iterations: {
          used: ($fj.iterate.used // 0),
          max: ($fj.iterate.maxIterations // null)
        },
         warnings: $warnings,
        autonomous: ($fj.autonomous // false),
        feature_title: ($fj.feature_title // $fj.slug),
        createdAt: ($fj.createdAt // null),
        finishedAt: $now,
        verification: {
          status: (if $status == "completed" then "passed" else "not-run" end),
          command: ($fj.commands.test // null)
        }
      }
      ')" 2>/dev/null || {
      echo "cycle-result.sh: failed to build result.json from feature.json in $feature_dir" >&2
      exit 0
    }

    # Write result.json to feature dir
    _write_atomic "$result_json" "$feature_dir/result.json" || {
      echo "cycle-result.sh: failed to write result.json to $feature_dir" >&2
      exit 0
    }

    # Copy to the stable control-root pointer. An explicit root wins; otherwise Git's
    # worktree list identifies the control checkout without persisting machine paths.
    feature_dir_abs="$(cd "$feature_dir" 2>/dev/null && pwd)" || feature_dir_abs=""
    if [[ -n "$feature_dir_abs" ]]; then
      result_root="${LOOP_SPEC_RESULT_ROOT:-}"
      if [[ -n "$result_root" ]]; then
        result_root="$(_resolve_result_root "$result_root")" || result_root=""
        loop_spec_dir="${result_root:+$result_root/.loop-spec}"
      else
        main_worktree=""
        if first_worktree_line="$(git -C "$feature_dir_abs" worktree list --porcelain 2>/dev/null | { IFS= read -r line; printf '%s' "$line"; })" \
          && [[ "$first_worktree_line" == worktree\ * ]]; then
          main_worktree="${first_worktree_line#worktree }"
        fi
        if [[ -n "$main_worktree" ]]; then
          result_root="$main_worktree"
          loop_spec_dir="$result_root/.loop-spec"
        else
          loop_spec_dir="$(cd "$feature_dir_abs/../.." 2>/dev/null && pwd)" || loop_spec_dir=""
          result_root="$(dirname "$loop_spec_dir")"
        fi
      fi
      if [[ -n "$loop_spec_dir" ]]; then
        if ! _prepare_result_root "$result_root" >/dev/null 2>&1; then
          echo "cycle-result.sh: cannot safely prepare result root: $result_root" >&2
        elif ! _write_atomic "$result_json" "$loop_spec_dir/last-result.json"; then
          echo "cycle-result.sh: failed to write last-result.json to $loop_spec_dir" >&2
        fi
      else
        echo "cycle-result.sh: cannot resolve .loop-spec dir; last-result.json not written" >&2
      fi
    fi

    # Emit matching event via lib/events.sh so events.jsonl and result.json can't disagree.
    EVENTS_SH="$(dirname "${BASH_SOURCE[0]}")/events.sh"
    bash "$EVENTS_SH" emit "$feature_dir" "$status" 2>/dev/null || true

    printf 'LOOP_SPEC_RESULT %s\n' "$result_json"

    exit 0
    ;;
  *)
    echo "cycle-result.sh: bad invocation — usage: cycle-result.sh write|write-terminal ..." >&2
    exit 0
    ;;
esac
