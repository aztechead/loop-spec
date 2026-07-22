#!/usr/bin/env bash
# cycle-preflight.sh - The cycle's silent startup batch, in one deterministic call.
#
# Cycle Steps 0-2 + probes ("Startup is silent... batch their checks") are individually
# scripted (workspace.sh, teams-capability.sh, graphify-preflight.sh,
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
#     harness:    {name},                               # claude | pi | opencode
#     teams:      {mode, available},                    # teams-capability.sh
#     workflows:  {available},                          # workflow-availability.sh
#     graphify:   {ok, required, graph},                # check + graph-status
#     backlog:    {count},
#     resume:     {candidates: [...], skipped: [...]},  # mechanical scan (below)
#     warnings:   [ ... ]                               # one line per anomaly
#   }
#
# Resume scan (the mechanical part of cycle Step 1): for each feature.json
# under <dir> and every registered .claude/worktrees/* worktree —
#   - parse feature.json, falling back to feature.json.bak on a parse failure
#     (parse_source records which); both unreadable -> skipped + warning
#   - skip currentPhase == "completed"; a ready DELIVER sidecar remains resumable
#     so completion finalization can recover after a crash
#   - skip schemaVersion != 7 -> skipped + the one-line warning the skill specifies
#   - currentTeamName != null -> candidate with needs_probe: true (liveness probing
#     needs the harness TaskList tool; the ORCHESTRATOR resolves it per
#     cycle-resume-escalation.md, using teams.mode from this same blob)
#   - currentTeamName == null && age >= stalenessHours*3600 -> skipped (too stale)
#   - else -> candidate, sorted most-recently-updated first
#
# The graphify hard-gate VERDICT stays with the caller: graphify.ok == false &&
# graphify.required == true -> abort per the skill. This script reports; it does not
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
bash "$SCRIPT_DIR/cycle-result.sh" clear --result-root "$dir"
bash "$SCRIPT_DIR/runtime-preflight.sh" check-jq

warnings=()

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

# --- graphify ----------------------------------------------------------------
graphify_required=true
[[ "${LOOP_SPEC_REQUIRE_GRAPHIFY:-1}" == "0" ]] && graphify_required=false
graphify_ok=true
bash "$SCRIPT_DIR/graphify-preflight.sh" check >/dev/null 2>&1 || graphify_ok=false
graph_status="$(bash "$SCRIPT_DIR/graphify-preflight.sh" graph-status "$dir")"

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
  --arg teams_mode "$teams_mode" \
  --argjson teams_available "$teams_available" \
  --argjson wf "$wf_available" \
  --argjson g_ok "$graphify_ok" \
  --argjson g_req "$graphify_required" \
  --arg g_status "$graph_status" \
  --argjson backlog "$backlog_count" \
  --argjson candidates "$candidates" \
  --argjson skipped "$skipped" \
  --argjson warnings "$warnings_json" \
  '{workspace: $workspace,
    harness: {name: $harness},
    teams: {mode: $teams_mode, available: $teams_available},
    workflows: {available: $wf},
    graphify: {ok: $g_ok, required: $g_req, graph: $g_status},
    backlog: {count: $backlog},
    resume: {candidates: $candidates, skipped: $skipped},
    warnings: $warnings}'
