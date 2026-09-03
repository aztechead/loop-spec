#!/usr/bin/env bash
# cycle-preflight.sh - The cycle's silent startup batch, in one deterministic call.
#
# Cycle Steps 0-2 + probes ("Startup is silent... batch their checks") are individually
# scripted (workspace.sh, teams-capability.sh,
# workflow-availability.sh, backlog.sh) but the orchestration between them was prose —
# five separate tool calls narrated by the model. This script IS the batch: one call,
# one JSON blob, and the only decision points left for the orchestrator are the ones
# that genuinely need judgment or a harness tool (resume choice, workspace repo
# confirmation, explicit-mode orphan probes via TaskList).
#
# Usage:
#   cycle-preflight.sh run [dir]
#       dir defaults to $PWD. Prints one JSON object:
#
#   {
#     workspace:  {mode, root, repos?, source?},        # workspace.sh detect (verbatim)
#     harness:    {name},                               # claude | opencode | adk | codex
#     profile:    {preset, source},                     # profile.sh resolve
#     store:      {name},                               # supervisor/store.sh describe
#     execution:  {entrypoint, headless},               # harness.sh entrypoint/headless
#     teams:      {mode, available},                    # teams-capability.sh
#     workflows:  {available},                          # workflow-availability.sh
#     backlog:    {count},
#     resume:     {candidates: [...], skipped: [...]},  # mechanical scan (below)
#     warnings:   [ ... ]                               # one line per anomaly
#   }
#
# Resume scan (the mechanical part of cycle Step 1): for each feature.json
# under <dir> and every registered feature worktree (git-ops.sh list-feature-worktrees,
# which finds them wherever lib/worktree-base.sh placed them) —
#   - parse feature.json, falling back to feature.json.bak on a parse failure
#     (parse_source records which); both unreadable -> skipped + warning
#   - skip currentPhase == "completed"; a ready DELIVER sidecar remains resumable
#     so completion finalization can recover after a crash
#   - skip schemaVersion != 7 -> skipped + the one-line warning the skill specifies
#   - currentTeamName != null -> candidate with needs_probe: true (liveness probing
#     needs the harness TaskList tool; the ORCHESTRATOR resolves it per
#     lib/cycle-driver.sh start, using teams.mode from this same blob)
#   - currentTeamName == null && age >= stalenessHours*3600 -> skipped (too stale)
#   - else -> candidate, sorted most-recently-updated first
#
# exit non-zero for that (a batch reporter that half-aborts is two contracts in one).
#
# Exit codes: 0 (report on stdout), 1 bad invocation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cmd="${1:-}"
[[ "$cmd" == "run" ]] || {
  echo "usage: cycle-preflight.sh run [dir]" >&2
  exit 1
}
dir="${2:-$PWD}"
[[ -d "$dir" ]] || { echo "cycle-preflight: no such directory: $dir" >&2; exit 1; }
# Breadcrumb BEFORE the clear. The clear erases the previous run's terminal
# pointer (a stale pointer would masquerade as this run's result), but preflight
# can still abort after it. Without an
# active-run.json in place first, that abort left NEITHER a terminal result NOR
# a recovery record, and cycle-reconcile.sh had nothing to reconcile: the exact
# "exit, no state" hole this file exists to prevent. The real `begin` later
# overwrites this with the actual title/slug and preserves startedAt.
bash "$SCRIPT_DIR/cycle-result.sh" begin --result-root "$dir" --cycle-type full \
  --title "(preflight)" --phase preflight \
  --autonomous "$([[ "${LOOP_SPEC_AUTONOMOUS:-}" == "1" ]] && echo true || echo false)" || true
bash "$SCRIPT_DIR/cycle-result.sh" clear --result-root "$dir"
bash "$SCRIPT_DIR/runtime-preflight.sh" check-jq

warnings=()

# --- run profile / state store -----------------------------------------------
# The profile is project policy (docs/loop-spec/supervisor-interface.md); apply it
# here so every probe below and every env read in this process sees it, and report
# it so the run's first line says what policy it is under. A profile that does not
# validate is a warning, not an abort: the run continues on the environment alone.
profile_json='{"preset":"interactive","source":"default","env":{}}'
export LOOP_SPEC_PROFILE="${LOOP_SPEC_PROFILE:-$dir/.loop-spec/profile.json}"
if profile_findings="$(bash "$SCRIPT_DIR/profile.sh" validate 2>&1 >/dev/null)"; then
  profile_json="$(bash "$SCRIPT_DIR/profile.sh" resolve)"
  # shellcheck disable=SC2046
  eval $(bash "$SCRIPT_DIR/profile.sh" env)
else
  warnings+=("profile: ${profile_findings//$'\n'/; } — running on the environment alone")
fi
store_line="$(bash "$SCRIPT_DIR/supervisor/store.sh" describe 2>&1)" \
  || warnings+=("store: $store_line")
store_name="${store_line#store=}"; store_name="${store_name%% *}"

# --- workspace ---------------------------------------------------------------
ws_json="$(bash "$SCRIPT_DIR/workspace.sh" detect "$dir")"

# --- harness / teams / workflows ----------------------------------------------
harness="$(bash "$SCRIPT_DIR/harness.sh" detect)"
# Pass the answer down: both capability probes would otherwise re-spawn
# harness.sh detect internally (3 forks per preflight for one constant fact).
teams_mode="$(LOOP_SPEC_HARNESS="$harness" bash "$SCRIPT_DIR/teams-capability.sh")"
teams_available=true
[[ "$teams_mode" == "none" ]] && teams_available=false
wf_available="$(LOOP_SPEC_HARNESS="$harness" bash "$SCRIPT_DIR/workflow-availability.sh")"

# --- execution profile --------------------------------------------------------
# One deterministic answer to "is anyone there?", resolved once at startup so no
# phase has to re-derive it. A proven-headless entrypoint (claude -p, the Python
# or TypeScript Agent SDK) with neither autonomous mode nor LOOP_SPEC_NON_INTERACTIVE
# set means every AskUserQuestion site will block on a human who does not exist —
# warn at startup rather than stalling mid-phase.
entrypoint="$(bash "$SCRIPT_DIR/harness.sh" entrypoint)"
headless="$(bash "$SCRIPT_DIR/harness.sh" headless)"
if [[ "$headless" == "true" && "${LOOP_SPEC_AUTONOMOUS:-}" != "1" \
      && "${LOOP_SPEC_NON_INTERACTIVE:-}" != "1" ]]; then
  warnings+=("headless invocation (entrypoint ${entrypoint}) without autonomous mode or LOOP_SPEC_NON_INTERACTIVE=1: interactive questions have no one to answer them — prefer '/loop-spec:auto <description>' or the 'autonomous' token")
fi

# --- backlog -----------------------------------------------------------------
backlog_count="$(CLAUDE_PROJECT_DIR="$dir" bash "$SCRIPT_DIR/backlog.sh" count)"

# --- resume scan -------------------------------------------------------------
candidates="[]"
skipped="[]"
now="$(date +%s)"

scan_feature_root() {
  local root="$1" source="$2" branch_hint="${3:-}"
  local features_dir="$root/.loop-spec/features"
  local fj fslug parse_source doc schema phase team updated_at staleness_hours
  local result_file delivery_file result_doc delivery_doc
  local updated_epoch age needs_probe candidate_branch worktree_abs
  [[ -d "$features_dir" ]] || return 0

  for fj in "$features_dir"/*/feature.json; do
    [[ -f "$fj" ]] || continue
    fslug="$(basename "$(dirname "$fj")")"
    parse_source="feature.json"
    doc=""
    if ! doc="$(jq -c . "$fj" 2>/dev/null)"; then
      if [[ -f "$fj.bak" ]] && doc="$(jq -c . "$fj.bak" 2>/dev/null)"; then
        parse_source="feature.json.bak"
        warnings+=("feature ${fslug}: feature.json unparseable; recovered from .bak")
      else
        skipped="$(jq -c --arg slug "$fslug" --arg why "unparseable" '. + [{slug: $slug, why: $why}]' <<<"$skipped")"
        warnings+=("feature ${fslug}: feature.json and .bak both unparseable; skipping")
        continue
      fi
    fi

    schema="$(jq -r '.schemaVersion // 0' <<<"$doc")"
    phase="$(jq -r '.currentPhase // ""' <<<"$doc")"

    [[ "$phase" == "completed" ]] && continue
    if [[ "$schema" != "7" ]]; then
      skipped="$(jq -c --arg slug "$fslug" --arg why "schema-version" '. + [{slug: $slug, why: $why}]' <<<"$skipped")"
      warnings+=("feature ${fslug}: unsupported schemaVersion ${schema} (schema 7 only); skipping")
      continue
    fi
    if [[ "$phase" == "deliver" ]]; then
      result_file="$(dirname "$fj")/result.json"
      delivery_file="$(dirname "$fj")/delivery.json"
      if [[ -f "$result_file" && -f "$delivery_file" ]]; then
        result_doc="$(jq -c . "$result_file" 2>/dev/null || echo null)"
        delivery_doc="$(jq -c . "$delivery_file" 2>/dev/null || echo null)"
        if jq -en --arg slug "$fslug" --argjson result "$result_doc" --argjson delivery "$delivery_doc" '
          $result.schema == 1 and
          $result.cycleType == "full" and
          $result.slug == $slug and
          $result.status == "completed" and
          $result.outcome == "no-change-needed" and
          $result.noChangeReason == "already-satisfied" and
          $result.converged == true and
          ($result.summary | type == "string" and test("\\S")) and
          $result.prUrl == null and
          $result.checkpointPrUrl == null and
          $result.verification.status == "passed" and
          $result.delivery.status == "no-changes" and
          $result.delivery.nextPhase == "deliver" and
          (($result.delivery.targets // []) | length > 0) and
          (($result.delivery.targets // []) |
            all(.errorCode == "no_commits" or .outcome == "skipped-no-commits")) and
          $delivery.status == "no-changes" and
          $delivery.nextPhase == "deliver" and
          (($delivery.targets // []) | length > 0) and
          (($delivery.targets // []) |
            all(.errorCode == "no_commits" or .outcome == "skipped-no-commits")) and
          (($result.delivery.attemptedAt // "") != "") and
          $result.delivery.attemptedAt == $delivery.attemptedAt
        ' >/dev/null 2>&1; then
          continue
        fi
      fi
    fi
    team="$(jq -r '.currentTeamName // ""' <<<"$doc")"
    updated_at="$(jq -r '.updatedAt // ""' <<<"$doc")"
    staleness_hours="$(jq -r '.stalenessHours // 48' <<<"$doc")"

    updated_epoch=0
    if [[ -n "$updated_at" ]]; then
      updated_epoch="$(python3 -c '
import sys
from datetime import datetime, timezone

s = sys.argv[1]
dt = None
try:
    # 3.7+
    dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
except (AttributeError, ValueError):
    # 3.6 fallback (no fromisoformat): the schema writes UTC Z-timestamps
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S.%fZ"):
        try:
            dt = datetime.strptime(s, fmt).replace(tzinfo=timezone.utc)
            break
        except ValueError:
            pass
print(int(dt.timestamp()) if dt else 0)
' "$updated_at")"
    fi
    age=$((now - updated_epoch))

    needs_probe=false
    if [[ -n "$team" ]]; then
      needs_probe=true
    elif [[ "$updated_epoch" -eq 0 || "$age" -ge $((staleness_hours * 3600)) ]]; then
      skipped="$(jq -c --arg slug "$fslug" --arg why "stale" '. + [{slug: $slug, why: $why}]' <<<"$skipped")"
      continue
    fi

    candidates="$(jq -c \
      --arg slug "$fslug" --arg phase "$phase" --arg updatedAt "$updated_at" \
      --arg team "$team" --argjson probe "$needs_probe" --argjson age "$age" \
      --arg src "$parse_source" --arg source "$source" --arg root "$root" \
      --arg jsonPath "$fj" --arg branchHint "$branch_hint" \
      --arg currentTeamsMode "$teams_mode" \
      --argjson f "$doc" \
      '. + [{slug: $slug, currentPhase: $phase, updatedAt: $updatedAt, age_seconds: $age,
              currentTeamName: (if $team == "" then null else $team end),
              needs_probe: $probe, parse_source: $src,
              source: $source, featureRoot: $root, featureJsonPath: $jsonPath,
              worktreeAbs: (if $source == "worktree" then $root else null end),
              branch: (if $branchHint != "" then $branchHint else ($f.branch // null) end),
              worktreePath: ($f.worktreePath // null),
              workspace: ($f.workspace // null),
              teamsMode: $currentTeamsMode}]' <<<"$candidates")"
  done
}

dir_abs="$(cd "$dir" && pwd)"
# A store other than the checkout may hold a slug the working copy lacks (a fresh
# container resuming a run): open each one before the scan parses the directory.
while IFS= read -r store_slug; do
  [[ -n "$store_slug" ]] || continue
  [[ -f "$dir_abs/.loop-spec/features/$store_slug/feature.json" ]] && continue
  open_line="$(bash "$SCRIPT_DIR/supervisor/store.sh" open "$dir_abs/.loop-spec/features/$store_slug" 2>&1)" \
    || warnings+=("store: open $store_slug failed: $open_line")
done < <(bash "$SCRIPT_DIR/supervisor/store.sh" list "$dir_abs" 2>/dev/null || true)
scan_feature_root "$dir_abs" "invocation" ""

# Single-repo feature state is created inside its registered feature worktree,
# not in the control checkout. Enumerate those worktrees from git rather than
# assuming the invoking checkout contains every in-flight feature.
if git -C "$dir_abs" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  while IFS=$'\t' read -r wt_path wt_branch; do
    [[ -n "$wt_path" && -d "$wt_path" ]] || continue
    [[ "$wt_path" == "$dir_abs" ]] && continue
    scan_feature_root "$wt_path" "worktree" "$wt_branch"
  done < <(bash "$SCRIPT_DIR/git-ops.sh" -C "$dir_abs" list-feature-worktrees 2>/dev/null || true)
fi

# A feature may be visible from both the invocation root and a worktree. Keep
# the freshest copy, preferring the live worktree on an exact timestamp tie.
candidates="$(jq -c '
  sort_by([.slug, .age_seconds, (if .source == "worktree" then 0 else 1 end)])
  | group_by(.slug) | map(.[0]) | sort_by(.age_seconds)
' <<<"$candidates")"

warnings_json="[]"
if [[ "${#warnings[@]}" -gt 0 ]]; then
  warnings_json="$(printf '%s\n' "${warnings[@]}" | jq -R . | jq -cs .)"
fi

jq -cn \
  --argjson workspace "$ws_json" \
  --arg harness "$harness" \
  --arg entrypoint "$entrypoint" \
  --argjson headless "$headless" \
  --arg teams_mode "$teams_mode" \
  --argjson teams_available "$teams_available" \
  --argjson wf "$wf_available" \
  --argjson backlog "$backlog_count" \
  --argjson candidates "$candidates" \
  --argjson skipped "$skipped" \
  --argjson warnings "$warnings_json" \
  --argjson profile "$profile_json" \
  --arg store "$store_name" \
  '{workspace: $workspace,
    harness: {name: $harness},
    profile: {preset: $profile.preset, source: $profile.source},
    store: {name: $store},
    execution: {entrypoint: $entrypoint, headless: $headless},
    teams: {mode: $teams_mode, available: $teams_available},
    workflows: {available: $wf},
    backlog: {count: $backlog},
    resume: {candidates: $candidates, skipped: $skipped},
    warnings: $warnings}'
