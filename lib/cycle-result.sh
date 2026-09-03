#!/usr/bin/env bash
# Machine-readable cycle result contract for headless/programmatic callers.
#
# OBSERVABILITY CONTRACT: this script must NEVER abort a cycle mid-run. Invocation
# and validation failures print a one-line warning to stderr and exit 0. A broken
# telemetry writer must not kill a 2-hour run.
#
# PUBLICATION EXCEPTION: failures to PUBLISH the authoritative pointer
# (.loop-spec/last-result.json) from write / write-terminal exit NON-ZERO and
# preserve active-run.json. At publication time the cycle's work is already done,
# so a loud exit cannot kill it -- but a silent one loses the run: exit 0 with no
# pointer is indistinguishable from success to a headless supervisor, and removing
# active-run.json on that path deletes the only state reconciliation can recover
# from. Exit 3 = the result could not be published; the recovery record remains.
#
# Usage:
#   cycle-result.sh clear [--result-root <root>]
#   cycle-result.sh begin --result-root <root> --cycle-type <full|micro|debug> --title <title>
#                         [--slug <slug>] [--branch <branch>] [--base-branch <branch>]
#                         [--feature-dir <absolute path>] [--phase <phase>]
#                         [--autonomous <true|false>]
#                         [--classification <json object>]
#   cycle-result.sh state [--result-root <root>]
#   cycle-result.sh resolve-root [<path>]
#   cycle-result.sh write <feature_dir> --status <completed|paused|escalated|terminal|failed>
#                        --summary <text> [--pr-url <url>] [--reason <text>]
#                        [--no-change-reason <already-satisfied>]
#                        [--outcome delivered]   alias for --status completed
#   cycle-result.sh write-terminal --result-root <root> --cycle-type <full|micro|debug|diagnostic>
#                        --status <status> --outcome <outcome> --title <title>
#                        --converged <true|false> --summary <text>
#                        [--no-change-reason <already-satisfied|diagnostic-only>]
#                        [compatibility/result fields...]
#     Full-cycle --outcome delivered is an alias for write --status completed
#     (DELIVER's own word); it is not a write-terminal success record.
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
#   "loopSpecVersion": "<version that produced this run, else \"unknown\">",
#   "slug": "...",
#   "status": "completed | paused | escalated | terminal",
#   "reason": "<--reason text or null>",
#   "summary": "<required concise terminal synthesis>",
#   "noChangeReason": "already-satisfied | diagnostic-only | null",
#   "phaseReached": "<logical phase, including delivery.json completion>",
#   "branch": "<.branch>",
#   "baseBranch": "<.baseBranch>",
#   "prUrl": "<--pr-url arg, else delivery.json/feature.json .prUrl, else null>",
#   "checkpointPrUrl": "<feature.json .checkpointPrUrl // null>",
#   "delivery": "<delivery.json, else feature.json .delivery, else null>",
#   "eligibleTargets": <delivery targets with an immutable retry binding>,
#   "implementationConverged": <true once the full cycle reached delivery,
#                               except local-preflight-only delivery failures>,
#   "converged": <true iff status==completed AND no warnings[] entry starts
#                 with "iterate-budget-spent:" or "iterate-terminal:", AND an
#                 explicit delivery block is ready-for-review (legacy state with
#                 no delivery block remains compatible)>,
#   "workDelivered": <true iff a non-checkpoint PR URL is present on the result
#                     or a delivery target — draft or ready. Independent of
#                     converged so a sign-off draft is not a gap>,
#   "outcome": <"delivered" when converged; "delivered-draft" when the sidecar
#               is a SHA-bound green draft with no iterate gaps; "completed-with-gaps"
#               for completed runs that did not deliver and are not a draft delivery>,
#   "retryable": <true for a SHA-bound delivery block>,
#   "retryPhase": <"deliver" for a SHA-bound delivery block, else null>,
#   "verifiedSha": <single-repo delivery targetSha, else null>,
#   "iterations": {"used": <.iterate.used // 0>, "max": <.iterate.maxIterations // null>},
#   "warnings": <.warnings // []>,
#   "autonomous": <.autonomous // false>,
#   "classification": "<persisted autonomous classifier decision, when present>",
#   "gatePlan": "<persisted compact gate plan, when present>",
#   "feature_title": "<.feature_title // .slug>",
#   "createdAt": "<.createdAt // null>",
#   "finishedAt": "<now ISO-8601 UTC>"
# }
#
# events.jsonl and result.json are local telemetry, deliberately not committed.
#
# `state` is the probe behind the route-exit contract: a run is armed (`begin`) before
# any protocol machinery starts and disarmed only by a published terminal result, so
# `active-run.json` present with no fresh pointer means a route was left without one.
# It prints ANSWER then REASON on one line and treats every unknown as `idle`, because
# a probe that cannot read the state must not strand a session:
#   published <reason>    a terminal result is the newest word on this root
#   unaccounted ageSeconds=<n> autonomous=<bool> <reason>
#                         a run was armed and never published its terminal result
#   idle <reason>         no loop-spec run is armed here
#
# Missing feature.json → one-line stderr warning, exit 0 (observability never aborts).
# Bad --status value → one-line stderr warning, exit 0, write nothing.
#
# Exit codes: writes always return 0 (observability never aborts); `clear` returns 1
# when it cannot safely remove the stale pointer so an entry point cannot reuse it.
set -uo pipefail

VALID_STATUSES="completed paused escalated terminal failed"
VALID_NO_CHANGE_REASONS="already-satisfied diagnostic-only"

_is_valid_status() {
  local s="$1"
  for v in $VALID_STATUSES; do
    [[ "$s" == "$v" ]] && return 0
  done
  return 1
}

_is_valid_no_change_reason() {
  local reason="$1"
  for valid in $VALID_NO_CHANGE_REASONS; do
    [[ "$reason" == "$valid" ]] && return 0
  done
  return 1
}

_is_nonblank() {
  jq -en --arg value "$1" '$value | test("\\S")' >/dev/null 2>&1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Stamped into every terminal result so a consumer can date the run against the
# version that produced it. Resolved once; never fails (degrades to "unknown").
loop_spec_version="$(bash "$SCRIPT_DIR/plugin-version.sh")"

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

# Feature dir a full-cycle --outcome delivered alias can hand to `write`.
# An interrupted pointer is often already published (reconcile ran first), so
# active-run.json may be gone; last-result.json.slug is the remaining handle.
_resolve_full_feature_dir() {
  local result_root="$1" slug="${2:-}" candidate="" d
  local active="$result_root/.loop-spec/active-run.json"
  local terminal="$result_root/.loop-spec/last-result.json"
  if [[ -f "$active" ]]; then
    candidate="$(jq -r '.featureDir // empty' "$active" 2>/dev/null || true)"
    if [[ -n "$candidate" && -f "$candidate/feature.json" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
    [[ -n "$slug" ]] || slug="$(jq -r '.slug // empty' "$active" 2>/dev/null || true)"
  fi
  if [[ -z "$slug" && -f "$terminal" ]]; then
    slug="$(jq -r '.slug // empty' "$terminal" 2>/dev/null || true)"
  fi
  if [[ -n "$slug" && -f "$result_root/.loop-spec/features/$slug/feature.json" ]]; then
    printf '%s' "$result_root/.loop-spec/features/$slug"
    return 0
  fi
  candidate=""
  for d in "$result_root/.loop-spec/features"/*/feature.json; do
    [[ -f "$d" ]] || continue
    if [[ -n "$candidate" ]]; then
      return 1
    fi
    candidate="$(dirname "$d")"
  done
  if [[ -n "$candidate" ]]; then
    printf '%s' "$candidate"
    return 0
  fi
  return 1
}

# Whether the route has already changed tracked files. Untracked paths are out of
# scope on purpose: a stray scratch file predating the run would otherwise block the
# mismatch record entirely, which loses the very result this contract is about.
# Committed work reads clean too, so the prose contract -- not this probe -- carries
# the rule; this only stops the cheapest version of laundering work as "did not fit".
_tree_unmodified() {
  local root="$1"
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  [[ -z "$(git -C "$root" status --porcelain --untracked-files=no 2>/dev/null)" ]]
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
  state)
    shift
    result_root="$PWD"
    if [[ "${1:-}" == "--result-root" && -n "${2:-}" ]]; then
      result_root="$2"
    fi
    result_root_abs="$(_resolve_result_root "$result_root" 2>/dev/null)" || {
      echo "idle unresolvable result root: $result_root"; exit 0; }
    if [[ -L "$result_root_abs/.loop-spec" ]]; then
      echo "idle refusing symlinked result directory: $result_root_abs/.loop-spec"; exit 0
    fi
    active_path="$result_root_abs/.loop-spec/active-run.json"
    if [[ ! -f "$active_path" ]]; then
      if [[ -f "$result_root_abs/.loop-spec/last-result.json" ]]; then
        echo "published terminal result present at $result_root_abs/.loop-spec/last-result.json"
      else
        echo "idle no armed run and no terminal result at $result_root_abs"
      fi
      exit 0
    fi
    # An armed run outlives its process, so the guard reading this needs to know how
    # long ago it was armed; an unparsable stamp reports 0 so a stale clock cannot
    # silently age a live run out of the contract.
    armed_age="$(python3 - "$active_path" <<'PY' 2>/dev/null || echo 0
import datetime, json, sys
try:
    with open(sys.argv[1]) as handle:
        record = json.load(handle)
    stamp = record.get("updatedAt") or record.get("startedAt") or ""
    armed = datetime.datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ")
    delta = (datetime.datetime.utcnow() - armed).total_seconds()
    print(max(0, int(delta)))
except Exception:
    print(0)
PY
)"
    [[ "$armed_age" =~ ^[0-9]+$ ]] || armed_age=0
    armed_type="$(jq -r '.cycleType // "unknown"' "$active_path" 2>/dev/null || echo unknown)"
    armed_phase="$(jq -r '.phase // "unknown"' "$active_path" 2>/dev/null || echo unknown)"
    armed_autonomous="$(jq -r 'if .autonomous == true then "true" else "false" end' \
      "$active_path" 2>/dev/null || echo false)"
    printf 'unaccounted ageSeconds=%s autonomous=%s %s run armed at phase %s never published a terminal result\n' \
      "$armed_age" "$armed_autonomous" "$armed_type" "$armed_phase"
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
  begin)
    shift
    result_root="" cycle_type="" title="" slug="" branch="" base_branch=""
    feature_dir="" phase="startup" autonomous="false" classification_raw=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --result-root) result_root="${2:-}"; shift 2 || true ;;
        --cycle-type) cycle_type="${2:-}"; shift 2 || true ;;
        --title) title="${2:-}"; shift 2 || true ;;
        --slug) slug="${2:-}"; shift 2 || true ;;
        --branch) branch="${2:-}"; shift 2 || true ;;
        --base-branch) base_branch="${2:-}"; shift 2 || true ;;
        --feature-dir) feature_dir="${2:-}"; shift 2 || true ;;
        --phase) phase="${2:-}"; shift 2 || true ;;
        --autonomous) autonomous="${2:-}"; shift 2 || true ;;
        --classification) classification_raw="${2:-}"; shift 2 || true ;;
        *) shift || true ;;
      esac
    done
    # Reduced routes arm the same record: the contract is per ROUTE, not per cycle type.
    case "$cycle_type" in full|micro|debug) ;; *) cycle_type="" ;; esac
    [[ -n "$result_root" && -n "$cycle_type" ]] || {
      echo "cycle-result.sh: begin requires --result-root and --cycle-type full|micro|debug" >&2
      exit 0
    }
    _is_nonblank "$title" || {
      echo "cycle-result.sh: begin requires a non-empty --title" >&2; exit 0; }
    [[ "$autonomous" == "true" || "$autonomous" == "false" ]] || autonomous="false"
    result_root_abs="$(_resolve_result_root "$result_root")" || {
      echo "cycle-result.sh: cannot resolve active result root: $result_root" >&2; exit 0; }
    _prepare_result_root "$result_root_abs" || {
      echo "cycle-result.sh: cannot prepare active result root: $result_root_abs" >&2; exit 0; }
    active_path="$result_root_abs/.loop-spec/active-run.json"
    started_at="$(jq -r '.startedAt // empty' "$active_path" 2>/dev/null || true)"
    [[ -n "$started_at" ]] || started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    existing_class="null"
    if [[ -f "$active_path" ]]; then
      existing_class="$(jq -c '.classification // null' "$active_path" 2>/dev/null || echo null)"
    fi
    classification_json="$existing_class"
    if [[ -n "$classification_raw" ]]; then
      jq -e 'type == "object"' >/dev/null 2>&1 <<<"$classification_raw" \
        && classification_json="$classification_raw"
    fi
    active_json="$(jq -cn --arg cycleType "$cycle_type" --arg title "$title" \
      --arg slug "$slug" --arg branch "$branch" --arg base "$base_branch" \
      --arg featureDir "$feature_dir" --arg phase "$phase" --arg startedAt "$started_at" \
      --arg updatedAt "$now" --argjson autonomous "$autonomous" \
      --argjson classification "$classification_json" \
      '{schema:1,cycleType:$cycleType,title:$title,
        slug:(if $slug == "" then null else $slug end),
        branch:(if $branch == "" then null else $branch end),
        baseBranch:(if $base == "" then null else $base end),
        featureDir:(if $featureDir == "" then null else $featureDir end),
        phase:$phase,autonomous:$autonomous,startedAt:$startedAt,updatedAt:$updatedAt,
        classification:$classification}')"
    _write_atomic "$active_json" "$active_path" || {
      echo "cycle-result.sh: failed to write $active_path" >&2; exit 0; }
    exit 0
    ;;
  write-terminal)
    shift
    result_root="" cycle_type="" status="" outcome="" slug="" title=""
    branch="" base_branch="" pr_url="" checkpoint_pr_url="" reason="" summary="" no_change_reason="" converged=""
    phase_reached=""
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
        --checkpoint-pr-url) checkpoint_pr_url="${2:-}"; shift 2 || true ;;
        --phase-reached) phase_reached="${2:-}"; shift 2 || true ;;
        --reason) reason="${2:-}"; shift 2 || true ;;
        --summary) summary="${2:-}"; shift 2 || true ;;
        --no-change-reason) no_change_reason="${2:-}"; shift 2 || true ;;
        --converged) converged="${2:-}"; shift 2 || true ;;
        --verification-status) verification_status="${2:-}"; shift 2 || true ;;
        --verification-command) verification_command="${2:-}"; shift 2 || true ;;
        --autonomous) autonomous="${2:-}"; shift 2 || true ;;
        --warnings-json) warnings_json="${2:-}"; shift 2 || true ;;
        *) shift || true ;;
      esac
    done
    # --outcome delivered is the DELIVER phase's word for a completed full cycle.
    # Agents reach for it; write-terminal used to hard-reject it (exit 0, write
    # nothing) and leave an interrupted pointer in place. Map it onto `write
    # --status completed` against the feature the run already has.
    if [[ "$outcome" == "delivered" ]]; then
      [[ -n "$cycle_type" ]] || cycle_type="full"
      if [[ "$cycle_type" == "full" ]]; then
        [[ -n "$result_root" ]] || {
          echo "cycle-result.sh: --outcome delivered requires --result-root" >&2; exit 3; }
        result_root_abs="$(_resolve_result_root "$result_root")" || {
          echo "cycle-result.sh: TERMINAL RESULT NOT PUBLISHED - cannot resolve result root: $result_root" >&2
          exit 3
        }
        feat_dir="$(_resolve_full_feature_dir "$result_root_abs" "$slug" || true)"
        if [[ -n "$feat_dir" && -f "$feat_dir/feature.json" ]]; then
          _is_nonblank "$summary" || summary="Cycle completed; PR delivered."
          write_args=(write "$feat_dir" --status completed --summary "$summary")
          [[ -z "$pr_url" ]] || write_args+=(--pr-url "$pr_url")
          [[ -z "$reason" ]] || write_args+=(--reason "$reason")
          LOOP_SPEC_RESULT_ROOT="$result_root_abs" bash "$0" "${write_args[@]}"
          exit $?
        fi
        echo "cycle-result.sh: --outcome delivered requires a readable feature.json (active-run.featureDir, --slug, or last-result.json slug); completed full cycles use 'cycle-result.sh write <feature_dir> --status completed --summary <text>'" >&2
        exit 3
      fi
    fi
    if [[ -z "$result_root" || -z "$cycle_type" || -z "$status" || -z "$outcome" || -z "$title" ]]; then
      echo "cycle-result.sh: write-terminal requires --result-root --cycle-type --status --outcome --title" >&2
      exit 0
    fi
    _is_nonblank "$summary" || {
      echo "cycle-result.sh: write-terminal requires a non-empty --summary" >&2; exit 0; }
    _is_valid_status "$status" || { echo "cycle-result.sh: invalid --status '$status'" >&2; exit 0; }
    [[ "$cycle_type" == "full" || "$cycle_type" == "micro" || "$cycle_type" == "debug" || "$cycle_type" == "diagnostic" ]] || {
      echo "cycle-result.sh: invalid --cycle-type '$cycle_type'" >&2; exit 0; }
    [[ "$converged" == "true" || "$converged" == "false" ]] || {
      echo "cycle-result.sh: --converged must be true or false" >&2; exit 0; }
    case "$verification_status" in passed|failed|not-run) ;; *)
      echo "cycle-result.sh: invalid --verification-status '$verification_status'" >&2; exit 0;; esac
    success_outcome="verified"
    allowed_outcomes="verified no-change-needed verification-failed delivery-blocked promoted-to-full"
    if [[ "$cycle_type" == "debug" ]]; then
      success_outcome="fixed"
      allowed_outcomes="fixed no-change-needed instrumented-and-waiting promoted-to-full verification-failed delivery-blocked"
    elif [[ "$cycle_type" == "diagnostic" ]]; then
      success_outcome=""
      allowed_outcomes="no-change-needed diagnostic-failed"
    elif [[ "$cycle_type" == "full" ]]; then
      success_outcome=""
      allowed_outcomes="infrastructure-failed interrupted"
    fi
    # Two endings belong to every route, not to one cycle type: the request was not
    # repository work, and the run stopped before it could finish. Both are honest
    # exits that publish a result. Declining a rebase/sync/conflict/re-review as
    # protocol-mismatch is the complementary failure -- the v3.0.1 freelance path
    # inverted. Leaving the route and finishing the work by hand publishes nothing
    # and reads as a failed run downstream.
    case " $allowed_outcomes " in
      *" interrupted "*) ;;
      *) allowed_outcomes="$allowed_outcomes interrupted" ;;
    esac
    allowed_outcomes="$allowed_outcomes protocol-mismatch"
    case " $allowed_outcomes " in *" $outcome "*) ;; *)
      if [[ "$cycle_type" == "full" ]]; then
        echo "cycle-result.sh: invalid full --outcome '$outcome'; completed full cycles use 'cycle-result.sh write <feature_dir> --status completed --summary <text>' (or write-terminal --outcome delivered, which is that alias). write-terminal failure outcomes: infrastructure-failed, interrupted, protocol-mismatch" >&2
        # A success-shaped invocation that we refused must not look like a
        # published run: exit 0 here is how a delivered PR was recorded as
        # interrupted when the agent used the DELIVER phase's own word.
        if [[ "$status" == "completed" || "$converged" == "true" || "$outcome" == "verified" ]]; then
          exit 3
        fi
      else
        echo "cycle-result.sh: invalid $cycle_type --outcome '$outcome'; accepted: $allowed_outcomes" >&2
      fi
      exit 0;; esac
    if [[ -n "$no_change_reason" ]] && ! _is_valid_no_change_reason "$no_change_reason"; then
      echo "cycle-result.sh: invalid --no-change-reason '$no_change_reason'" >&2
      exit 0
    fi
    if [[ "$outcome" == "no-change-needed" ]]; then
      [[ "$status" == "completed" && "$converged" == "true" && -z "$pr_url" && -n "$no_change_reason" ]] || {
        echo "cycle-result.sh: no-change-needed requires completed/converged without a PR and with --no-change-reason" >&2; exit 0; }
      if [[ "$cycle_type" == "diagnostic" && "$no_change_reason" != "diagnostic-only" ]]; then
        echo "cycle-result.sh: diagnostic no-change requires --no-change-reason diagnostic-only" >&2
        exit 0
      elif [[ "$cycle_type" == "diagnostic" && "$verification_status" != "not-run" ]]; then
        echo "cycle-result.sh: diagnostic no-change requires verification-status not-run" >&2
        exit 0
      elif [[ "$cycle_type" != "diagnostic" && "$no_change_reason" != "already-satisfied" ]]; then
        echo "cycle-result.sh: work-cycle no-change requires --no-change-reason already-satisfied" >&2
        exit 0
      elif [[ "$cycle_type" != "diagnostic" && "$verification_status" != "passed" ]]; then
        echo "cycle-result.sh: work-cycle no-change requires passed verification" >&2
        exit 0
      fi
    elif [[ -n "$no_change_reason" ]]; then
      echo "cycle-result.sh: --no-change-reason requires outcome no-change-needed" >&2
      exit 0
    elif [[ -n "$success_outcome" && "$outcome" == "$success_outcome" ]]; then
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
    elif [[ "$outcome" == "diagnostic-failed" && "$status" != "failed" ]]; then
      echo "cycle-result.sh: diagnostic-failed requires failed status" >&2
      exit 0
    elif [[ "$outcome" == "interrupted" && "$status" != "failed" ]]; then
      echo "cycle-result.sh: interrupted requires failed status" >&2
      exit 0
    elif [[ "$outcome" == "protocol-mismatch" ]]; then
      if [[ "$status" != "escalated" ]]; then
        echo "cycle-result.sh: protocol-mismatch requires escalated status" >&2
        exit 0
      elif ! _is_nonblank "$reason"; then
        echo "cycle-result.sh: protocol-mismatch requires a --reason naming the mismatch" >&2
        exit 0
      elif ! _tree_unmodified "$result_root"; then
        echo "cycle-result.sh: protocol-mismatch requires an unmodified working tree at $result_root; a route that already changed the repository must report what it did" >&2
        exit 0
      fi
    elif [[ "$cycle_type" == "full" && "$status" != "failed" ]]; then
      echo "cycle-result.sh: full terminal fallback requires failed status" >&2
      exit 0
    fi
    [[ "$autonomous" == "true" || "$autonomous" == "false" ]] || autonomous="false"
    jq -e 'type == "array"' <<<"$warnings_json" >/dev/null 2>&1 || warnings_json="[]"
    # Publication path: from here on, failure exits 3 (see header). Exiting 0 with
    # no pointer written is how an unattended run gets lost -- the supervisor reads
    # "success, no result", which looks identical to a dozen other causes.
    result_root_abs="$(_resolve_result_root "$result_root")" || {
      echo "cycle-result.sh: TERMINAL RESULT NOT PUBLISHED - cannot resolve result root: $result_root" >&2; exit 3; }
    _prepare_result_root "$result_root_abs" || {
      echo "cycle-result.sh: TERMINAL RESULT NOT PUBLISHED - cannot prepare result root: $result_root_abs" >&2; exit 3; }
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    active_context="$(jq -c '{classification:(.classification // .autonomousClassification // null), gatePlan:(.gatePlan // .autonomousGatePlan // (.classification.gatePlan // null) // (.autonomousClassification.gatePlan // null))}' \
      "$result_root_abs/.loop-spec/active-run.json" 2>/dev/null || printf '%s' '{}')"
    result_json="$(jq -cn --arg cycleType "$cycle_type" --arg status "$status" \
      --arg outcome "$outcome" --arg slug "$slug" --arg title "$title" \
      --arg branch "$branch" --arg base "$base_branch" --arg pr "$pr_url" \
      --arg checkpointPr "$checkpoint_pr_url" --arg phaseReached "$phase_reached" \
      --arg reason "$reason" --arg summary "$summary" --arg noChangeReason "$no_change_reason" \
      --arg verifyStatus "$verification_status" \
      --arg verifyCommand "$verification_command" --arg now "$now" \
      --argjson converged "$converged" --argjson autonomous "$autonomous" \
      --arg loopSpecVersion "$loop_spec_version" \
      --argjson warnings "$warnings_json" --argjson active "$active_context" '
      ($active.classification // null) as $classification |
      ($active.gatePlan // ($classification.gatePlan // null)) as $gatePlan |
      {schema:1,loopSpecVersion:$loopSpecVersion,
       cycleType:$cycleType,slug:(if $slug == "" then null else $slug end),
       status:$status,outcome:$outcome,reason:(if $reason == "" then null else $reason end),
       summary:$summary,
       noChangeReason:(if $noChangeReason == "" then null else $noChangeReason end),
       phaseReached:(if $phaseReached == "" then $cycleType else $phaseReached end),
       branch:(if $branch == "" then null else $branch end),
       baseBranch:(if $base == "" then null else $base end),
       prUrl:(if $pr == "" then null else $pr end),
       checkpointPrUrl:(if $checkpointPr == "" then null else $checkpointPr end),delivery:null,
       converged:$converged,
       workDelivered:($pr != "" and $pr != $checkpointPr),
       iterations:{used:0,max:null},warnings:$warnings,
       autonomous:$autonomous,feature_title:$title,createdAt:null,finishedAt:$now,
       verification:{status:$verifyStatus,command:(if $verifyCommand == "" then null else $verifyCommand end)}}
      + (if $classification == null then {} else {classification:$classification} end)
      + (if $gatePlan == null then {} else {gatePlan:$gatePlan} end)')" || {
      echo "cycle-result.sh: TERMINAL RESULT NOT PUBLISHED - failed to build terminal result" >&2; exit 3; }
    destination="$result_root_abs/.loop-spec/last-result.json"
    _write_atomic "$result_json" "$destination" || {
      echo "cycle-result.sh: TERMINAL RESULT NOT PUBLISHED - failed to write $destination" >&2; exit 3; }
    # Only after the pointer is durably published may the recovery record go: it is
    # the one artifact cycle-reconcile.sh can turn an interrupted run into a failed
    # terminal result with. Removing it before publication burned both.
    rm -f "$result_root_abs/.loop-spec/active-run.json" 2>/dev/null || true
    printf 'LOOP_SPEC_RESULT %s\n' "$result_json"
    jq -cn --argjson r "$result_json" '{ts:(now|todate), slug:$r.slug, event:"result", phase:null, data:$r}' \
      | bash "$SCRIPT_DIR/events.sh" sink
    exit 0
    ;;
  write)
    feature_dir="${2:-}"
    if [[ -z "$feature_dir" ]]; then
      echo "cycle-result.sh: bad invocation — usage: cycle-result.sh write <feature_dir> --status <status> --summary <text> [--pr-url <url>] [--reason <text>] [--no-change-reason <code>]" >&2
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
    summary=""
    no_change_reason=""
    outcome=""
    shift 2 || true
    while [[ $# -gt 0 ]]; do
      case "${1:-}" in
        --status)
          status="${2:-}"
          shift 2 || shift || true
          ;;
        --outcome)
          outcome="${2:-}"
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
        --summary)
          summary="${2:-}"
          shift 2 || shift || true
          ;;
        --no-change-reason)
          no_change_reason="${2:-}"
          shift 2 || shift || true
          ;;
        *)
          shift || true
          ;;
      esac
    done

    # Same alias write-terminal honours: DELIVER's outcome word is completed.
    case "$outcome" in
      delivered|completed) status="completed" ;;
      "" ) ;;
      *)
        echo "cycle-result.sh: write maps --outcome delivered to --status completed; got '$outcome'" >&2
        exit 0
        ;;
    esac

    # Validate status
    if [[ -z "$status" ]]; then
      echo "cycle-result.sh: --status is required" >&2
      exit 0
    fi
    if ! _is_valid_status "$status"; then
      echo "cycle-result.sh: invalid --status '$status'; must be one of: $VALID_STATUSES" >&2
      exit 0
    fi
    if [[ -n "$no_change_reason" && "$no_change_reason" != "already-satisfied" ]]; then
      echo "cycle-result.sh: full-cycle --no-change-reason must be already-satisfied" >&2
      exit 0
    fi
    if [[ -n "$no_change_reason" && "$status" != "completed" ]]; then
      echo "cycle-result.sh: full-cycle no-change requires --status completed" >&2
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
    # Fail-open: a gh miss must not block publishing the terminal result.
    if [[ "$status" == "completed" && -z "$no_change_reason" ]]; then
      bash "$SCRIPT_DIR/delivery-reconcile.sh" observe "$feature_dir" --accept-checkpoint \
        >/dev/null 2>&1 || true
    fi
    delivery_content="null"
    if [[ -f "$feature_dir/delivery.json" ]]; then
      delivery_content="$(jq -c . "$feature_dir/delivery.json" 2>/dev/null || echo null)"
    fi
    if [[ "$delivery_content" == "null" ]]; then
      delivery_content="$(jq -c '.delivery // null' <<<"$fj_content" 2>/dev/null || echo null)"
    fi
    # A delivered run must still publish when ITERATE left no summary. Reconcile
    # and --outcome delivered already fall back; refusing here is the hole that
    # makes a headless caller treat a delivered PR as a failed run.
    if ! _is_nonblank "$summary"; then
      iterate_summary="$(jq -r '.iterate.lastVerdict.summary // empty' <<<"$fj_content" 2>/dev/null || true)"
      if _is_nonblank "$iterate_summary"; then
        summary="$iterate_summary"
      elif [[ "$status" == "completed" ]] && jq -e '
          . != null and (
            (.nextPhase // "") == "completed" or
            (.status // "") == "ready-for-review" or
            (.status // "") == "delivered-draft")
        ' >/dev/null 2>&1 <<<"$delivery_content"; then
        summary="Cycle completed; PR delivered."
      else
        echo "cycle-result.sh: a non-empty --summary is required" >&2
        exit 0
      fi
    fi
    if [[ -n "$no_change_reason" ]] && ! jq -e '
      .iterate.lastVerdict.converged == true and
      .iterate.lastVerdict.deterministic_gate_passed == true and
      ((.warnings // []) |
        map(type == "string" and
          (startswith("iterate-budget-spent:") or startswith("iterate-terminal:"))) |
        any | not)
    ' \
      <<<"$fj_content" >/dev/null 2>&1; then
      echo "cycle-result.sh: already-satisfied requires clean deterministic ITERATE convergence" >&2
      exit 0
    fi
    if [[ -n "$no_change_reason" ]] && ! jq -e '
      . != null and .status == "no-changes" and
      ((.targets // []) | length > 0) and
      ((.targets // []) | all(
        (.errorCode == "no_commits" or .outcome == "skipped-no-commits") and
        ((.feedback.changesRequested // false) == false)))
    ' <<<"$delivery_content" >/dev/null 2>&1; then
      echo "cycle-result.sh: already-satisfied requires delivery no-commit evidence for every target" >&2
      exit 0
    fi

    # Build result.json with jq (never string-interpolate user text into JSON).
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    feature_dir_abs="$(cd "$feature_dir" 2>/dev/null && pwd)" || feature_dir_abs=""
    compact_root="${LOOP_SPEC_RESULT_ROOT:-}"
    if [[ -z "$compact_root" && -n "$feature_dir_abs" ]]; then
      compact_root="$(_resolve_result_root "$feature_dir_abs" 2>/dev/null || true)"
    elif [[ -n "$compact_root" ]]; then
      compact_root="$(_resolve_result_root "$compact_root" 2>/dev/null || true)"
    fi
    active_context="$(jq -c '{classification:(.classification // .autonomousClassification // null), gatePlan:(.gatePlan // .autonomousGatePlan // (.classification.gatePlan // null) // (.autonomousClassification.gatePlan // null))}' \
      "$compact_root/.loop-spec/active-run.json" 2>/dev/null || printf '%s' '{}')"

    # Feature state calls it autonomousClassification; terminal telemetry keeps
    # the established active-run name, classification, for one public shape.
    result_json="$(jq -cn \
      --arg now "$now" \
      --arg status "$status" \
      --arg pr_url_arg "$pr_url" \
      --arg reason_arg "$reason" \
      --arg summary_arg "$summary" \
      --arg no_change_reason_arg "$no_change_reason" \
      --arg loopSpecVersion "$loop_spec_version" \
      --argjson fj "$fj_content" \
      --argjson delivery "$delivery_content" \
      --argjson active "$active_context" \
      '
      # prUrl: explicit arg, successful delivery sidecar, tracked fallback.
      (if $pr_url_arg != "" then $pr_url_arg
       elif (($delivery.prUrl // "") != "") then $delivery.prUrl
       elif (($fj.prUrl // "") != "") then $fj.prUrl
       else null
       end) as $prUrl |
      # reason: --reason arg, or null
       (if $reason_arg != "" then $reason_arg else null end) as $reason |
       ($no_change_reason_arg != "") as $intentionalNoChange |
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
       ($fj.classification // $fj.autonomousClassification // $active.classification // null)
         as $classification |
       ($fj.gatePlan // $fj.autonomousGatePlan // ($classification.gatePlan // null) //
        $active.gatePlan // null) as $gatePlan |
         def local_delivery_error: ["repo_invalid","repo_root_mismatch","branch_mismatch",
           "git_status_failed","dirty_worktree","base_sha_missing","base_sha_invalid",
           "base_not_ancestor","no_commits","git_history_failed","local_artifact_policy_failed"];
         def delivery_target_eligible:
           . as $target |
           (($target.targetSha // "") != "") and
           ($target.bindingEligible == true or
             (($target | has("bindingEligible") | not) and
              ((local_delivery_error | index($target.errorCode // "")) == null)));
        # converged: clean goal verdict plus a successful explicit delivery when present.
         (if $delivery != null then $delivery else ($fj.delivery // null) end) as $deliveryRecord |
         ([$deliveryRecord.targets[]? | select(delivery_target_eligible)]) as $eligibleTargets |
         ([$deliveryRecord.targets[]?
           | select(.ok == false and (delivery_target_eligible | not))] | length > 0)
           as $hasLocalFailure |
         (($fj.currentPhase // "") == "deliver" or
          ($fj.currentPhase // "") == "completed" or
          ($delivery.nextPhase // "") == "completed") as $reachedDelivery |
         (($fj.currentPhase // "") == "deliver" and
          ($delivery.nextPhase // "") == "deliver") as $stoppedAtDelivery |
         ($stoppedAtDelivery and ($eligibleTargets | length) > 0 and ($hasLocalFailure | not)) as $deliveryBlocked |
         ($stoppedAtDelivery and (($eligibleTargets | length) == 0 or $hasLocalFailure)) as $localDeliveryEscalation |
          (if $intentionalNoChange then "completed"
           elif $deliveryBlocked then "failed"
           elif $localDeliveryEscalation then "escalated"
           else $status end) as $effectiveStatus |
         ($reachedDelivery and (($localDeliveryEscalation | not) or $intentionalNoChange))
            as $implementationConverged |
         (if ($fj.workspace // null) == null
          then ($eligibleTargets | first // null)
          else null end) as $primaryTarget |
        (($effectiveStatus == "completed") and
         ($feedbackBlocking | not) and
         ($warnings
          | map(startswith("iterate-budget-spent:") or startswith("iterate-terminal:"))
          | any | not) and
       (if $delivery != null then ((($delivery.status // "") == "ready-for-review") or $intentionalNoChange)
        else (($fj | has("delivery") | not) or (($fj.delivery.status // "") == "ready-for-review"))
        end)) as $converged |
        (($delivery.status // "") == "delivered-draft"
         or (($delivery.targets // [])
             | map(select(.outcome == "delivered-draft" and ((.prUrl // "") != "")))
             | length) > 0) as $draftRecord |
        (($effectiveStatus == "completed")
         and ($feedbackBlocking | not)
         and ($warnings
              | map(startswith("iterate-budget-spent:") or startswith("iterate-terminal:"))
              | any | not)
         and $draftRecord
         and ($converged | not)) as $draftDelivered |
        (($intentionalNoChange | not) and (
           ($prUrl != null and $prUrl != ($fj.checkpointPrUrl // ""))
           or (($delivery.status // "") == "ready-for-review")
           or (($delivery.status // "") == "delivered-draft")
           or (($delivery.targets // []) | any(
             ((.prUrl // "") != "")
             and ((.outcome // "") == "delivered" or (.outcome // "") == "delivered-draft")
           ))
        )) as $workDelivered |
      {
         schema: 1,
         loopSpecVersion: $loopSpecVersion,
         cycleType: "full",
         slug: $fj.slug,
          status: $effectiveStatus,
          outcome: (if $intentionalNoChange then "no-change-needed" elif $deliveryBlocked then "delivery-blocked" elif $converged then "delivered" elif $draftDelivered then "delivered-draft" elif $effectiveStatus == "completed" then "completed-with-gaps" else $effectiveStatus end),
          reason: $reason,
          summary: $summary_arg,
          noChangeReason: (if $intentionalNoChange then $no_change_reason_arg else null end),
          phaseReached: (if $effectiveStatus == "completed" and ((($delivery.status // "") == "ready-for-review") or (($delivery.status // "") == "delivered-draft") or $intentionalNoChange)
                         then "completed" else ($fj.currentPhase // null) end),
         branch: (if $primaryTarget != null then ($primaryTarget.branch // $fj.branch // null)
                  else ($fj.branch // null) end),
         baseBranch: ($fj.baseBranch // null),
          prUrl: (if $intentionalNoChange then null else $prUrl end),
         checkpointPrUrl: (if $intentionalNoChange then null else ($fj.checkpointPrUrl // null) end),
         delivery: $deliveryRecord,
         eligibleTargets: $eligibleTargets,
         implementationConverged: $implementationConverged,
         converged: $converged,
         workDelivered: $workDelivered,
         retryable: $deliveryBlocked,
         retryPhase: (if $deliveryBlocked then "deliver" else null end),
         verifiedSha: (if $primaryTarget != null then $primaryTarget.targetSha else null end),
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
           status: (if $reachedDelivery then "passed" else "not-run" end),
           command: ($fj.commands.test // null)
         }
      }
      + (if $classification == null then {} else {classification:$classification} end)
      + (if $gatePlan == null then {} else {gatePlan:$gatePlan} end)
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
      # Publication path (see header): the pointer either lands or this exits 3,
      # and active-run.json survives until it lands. The old shape removed the
      # recovery record even when the pointer write had just failed, leaving a
      # headless supervisor with neither a terminal result nor anything for
      # cycle-reconcile.sh to recover from -- exit 0 made it look finished.
      pointer_published=false
      if [[ -n "$loop_spec_dir" ]]; then
        if ! _prepare_result_root "$result_root" >/dev/null 2>&1; then
          echo "cycle-result.sh: RESULT POINTER NOT PUBLISHED - cannot safely prepare result root: $result_root" >&2
        elif ! _write_atomic "$result_json" "$loop_spec_dir/last-result.json"; then
          echo "cycle-result.sh: RESULT POINTER NOT PUBLISHED - failed to write last-result.json to $loop_spec_dir" >&2
        else
          pointer_published=true
          rm -f "$loop_spec_dir/active-run.json" 2>/dev/null || true
        fi
      else
        echo "cycle-result.sh: RESULT POINTER NOT PUBLISHED - cannot resolve .loop-spec dir" >&2
      fi
      if [[ "$pointer_published" != "true" ]]; then
        # result.json in the feature dir did land; say so, then fail loudly.
        printf 'LOOP_SPEC_RESULT %s\n' "$result_json"
        jq -cn --argjson r "$result_json" '{ts:(now|todate), slug:$r.slug, event:"result", phase:null, data:$r}' \
          | bash "$SCRIPT_DIR/events.sh" sink
        exit 3
      fi
    fi

    # Emit matching event via lib/events.sh so events.jsonl and result.json can't disagree.
    EVENTS_SH="$(dirname "${BASH_SOURCE[0]}")/events.sh"
    result_status="$(jq -r '.status' <<<"$result_json" 2>/dev/null || printf '%s' "$status")"
    bash "$EVENTS_SH" emit "$feature_dir" "$result_status" 2>/dev/null || true

    printf 'LOOP_SPEC_RESULT %s\n' "$result_json"
    jq -cn --argjson r "$result_json" '{ts:(now|todate), slug:$r.slug, event:"result", phase:null, data:$r}' \
      | bash "$SCRIPT_DIR/events.sh" sink

    exit 0
    ;;
  *)
    echo "cycle-result.sh: bad invocation — usage: cycle-result.sh write|write-terminal ..." >&2
    exit 0
    ;;
esac
