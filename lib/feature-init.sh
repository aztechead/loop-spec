#!/usr/bin/env bash
# Single source of truth for the schema-7 feature.json skeleton and the canonical
# models map. cycle Step 5 (state init) and Step 5.9 (resume normalization) both call
# this so the two can never drift -- that drift is what previously dropped iterateJudge
# from the normalized models map.
#
# Env overrides: LOOP_SPEC_MODEL_<ROLE> (SCREAMING_SNAKE of the JSON key, e.g.
# LOOP_SPEC_MODEL_PLANNER) lets an operator reroute any role to a different alias
# without editing this file. Because Step 5 AND Step 5.9 both call
# `feature-init.sh models`, overrides apply automatically to new features and to
# every resume normalization -- phase skills need no changes.
#
# Usage:
#   bash lib/feature-init.sh models
#       -> prints the canonical models map (JSON object). The ONE place model roles live.
#
#   bash lib/feature-init.sh skeleton --mode single \
#       --slug S --now ISO --style ST --title "ORIGINAL GOAL" \
#       --branch feat/S --base-sha SHA --base-branch BB --worktree PATH \
#       --test CMD --lint CMD --typecheck CMD
#       -> prints a complete single-repo schema-7 feature.json.
#
#   bash lib/feature-init.sh skeleton --mode workspace \
#       --slug S --now ISO --style ST \
#       --ws-root ROOT --repos REPOS_JSON
#       -> prints a complete workspace-mode schema-7 feature.json
#          (top-level branch/baseSha/baseBranch/worktreePath null; commands empty;
#           per-repo commands live in workspace.repos[].commands).
#
# Exit codes: 0 success; 1 bad invocation.
set -euo pipefail

# Harness model ALIASES, not pinned IDs. The modern Agent tool's `model` parameter
# is an alias enum (sonnet | opus | haiku | fable); a literal ID like claude-opus-4-8
# fails InputValidationError at dispatch. Aliases resolve to the harness's current
# model for that family, which is the supported targeting mechanism.
OPUS="opus"
SONNET="sonnet"

# resolve_role_model <ENV_SUFFIX> <default>
#
# Prints the resolved alias for a role. If LOOP_SPEC_MODEL_<ENV_SUFFIX> is set and
# non-empty it overrides the canonical default; if unset or empty the default is used.
#
# The value MUST be a harness alias enum (sonnet | opus | haiku | fable). Literal IDs
# like claude-opus-4-8 are rejected with a non-zero exit because the Agent tool's
# `model` param is an alias enum and fails InputValidationError on a literal ID.
resolve_role_model() {
  local env_suffix="$1"
  local default="$2"
  local var="LOOP_SPEC_MODEL_${env_suffix}"
  local val="${!var:-}"
  if [[ -z "$val" ]]; then
    echo "$default"
    return 0
  fi
  case "$val" in
    sonnet|opus|haiku|fable)
      echo "$val"
      ;;
    *)
      echo "feature-init: ${var}='${val}' is not a valid harness alias." \
           "Allowed: sonnet | opus | haiku | fable." \
           "Literal model IDs (e.g. claude-opus-4-8) are rejected because the Agent tool's" \
           "model param is an alias enum; literal IDs fail InputValidationError at dispatch." >&2
      exit 1
      ;;
  esac
}

# Canonical models map -- the only definition of which model each role uses.
# Mirrors skills/shared/model-matrix.md. When a role is added, add it HERE only.
# Per-role env overrides (LOOP_SPEC_MODEL_<ROLE>) are resolved here so they propagate
# automatically to every new feature and every Step 5.9 resume normalization.
#
# Each role is resolved into a local variable before the jq call so that a failed
# resolve_role_model (invalid env value) returns a non-zero exit from this function
# before jq ever runs. The pattern `local v; v=$(cmd) || return 1` is required
# because `local v=$(cmd)` masks the exit code (local is its own command).
canonical_models() {
  local v_specWriter v_planner v_advocate v_challenger v_specComplianceReviewer
  local v_iterateJudge v_codeReviewer v_implementer v_verifier v_mapper v_patternMapper

  v_specWriter=$(resolve_role_model SPEC_WRITER "$OPUS")                        || return 1
  v_planner=$(resolve_role_model PLANNER "$OPUS")                               || return 1
  v_advocate=$(resolve_role_model ADVOCATE "$SONNET")                           || return 1
  v_challenger=$(resolve_role_model CHALLENGER "$OPUS")                         || return 1
  v_specComplianceReviewer=$(resolve_role_model SPEC_COMPLIANCE_REVIEWER "$SONNET") || return 1
  v_iterateJudge=$(resolve_role_model ITERATE_JUDGE "$OPUS")                    || return 1
  v_codeReviewer=$(resolve_role_model CODE_REVIEWER "$OPUS")                    || return 1
  v_implementer=$(resolve_role_model IMPLEMENTER "$SONNET")                     || return 1
  v_verifier=$(resolve_role_model VERIFIER "$SONNET")                           || return 1
  v_mapper=$(resolve_role_model MAPPER "$SONNET")                               || return 1
  v_patternMapper=$(resolve_role_model PATTERN_MAPPER "$SONNET")                || return 1

  jq -n \
    --arg specWriter             "$v_specWriter" \
    --arg planner                "$v_planner" \
    --arg advocate               "$v_advocate" \
    --arg challenger             "$v_challenger" \
    --arg specComplianceReviewer "$v_specComplianceReviewer" \
    --arg iterateJudge           "$v_iterateJudge" \
    --arg codeReviewer           "$v_codeReviewer" \
    --arg implementer            "$v_implementer" \
    --arg verifier               "$v_verifier" \
    --arg mapper                 "$v_mapper" \
    --arg patternMapper          "$v_patternMapper" \
    '{
      specWriter: $specWriter,
      planner: $planner,
      advocate: $advocate,
      challenger: $challenger,
      specComplianceReviewer: $specComplianceReviewer,
      iterateJudge: $iterateJudge,
      codeReviewer: $codeReviewer,
      implementer: $implementer,
      verifier: $verifier,
      mapper: $mapper,
      patternMapper: $patternMapper
    }'
}

# Fixed operating block (iterate), identical for single and workspace modes.
# Full-bore operation: gate retries are unbounded (attempts still land in gateHistory);
# iterate.maxIterations=10 — the convergence loop ceiling — is the ONLY bound the
# cycle respects.
fixed_blocks() {
  jq -n '{
    iterate: {
      maxIterations: 10,
      used: 0,
      confirmationUsed: false,
      lastVerdict: null,
      feedback: null,
      history: []
    }
  }'
}

# Common skeleton (everything except the mode-specific branch/worktree/workspace block
# and the commands field). $1=slug $2=now $3=style $4=title.
# feature_title is the IMMUTABLE original goal in the user's words -- the oracle the
# ITERATE judge scores against. It must survive every phase and resume untouched.
common_skeleton() {
  local slug="$1" now="$2" style="$3" title="$4"
  # Resolve models before the jq call: an invalid LOOP_SPEC_MODEL_<ROLE> must abort
  # with only the resolve error, not a trailing "invalid JSON" jq error from a failed
  # $(...) inside --argjson.
  local models_json
  models_json="$(canonical_models)" || return 1
  jq -n \
    --arg slug "$slug" --arg now "$now" --arg style "$style" \
    --arg title "$title" \
    --argjson models "$models_json" \
    --argjson tierblocks "$(fixed_blocks)" \
    '{
      schemaVersion: 7,
      slug: $slug,
      feature_title: (if $title == "" then $slug else $title end),
      createdAt: $now, updatedAt: $now,
      execStyle: $style,
      models: $models,
      currentPhase: "spec",
      currentPhaseStartedAt: null,
      completedPhases: [],
      artifacts: {
        specInterview: null,
        spec: null, patterns: null, plan: null, execution: null, verification: null,
        iteration: null,
        patternsSource: null,
        codebaseSource: {tech: null, arch: null, quality: null, concerns: null, domain: null}
      },
      currentTeamName: null,
      currentTeammates: [],
      currentGate: {round: 0, phase: null},
      mergeQueue: [],
      pendingRemediationTasks: [],
      fileConflictExcludeGlobs: [],
      gateHistory: [],
      stalenessHours: 48,
      warnings: [],
      bootstrapPendingDomains: []
    } + $tierblocks'
}

case "${1:-}" in
  models)
    canonical_models
    ;;
  skeleton)
    shift
    mode="" slug="" now="" style="" title=""
    branch="" base_sha="" base_branch="" worktree=""
    test_cmd="" lint_cmd="" typecheck_cmd=""
    ws_root="" repos_json="[]"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --mode)        mode="$2"; shift 2;;
        --slug)        slug="$2"; shift 2;;
        --title)       title="$2"; shift 2;;
        --now)         now="$2"; shift 2;;
        --style)       style="$2"; shift 2;;
        --branch)      branch="$2"; shift 2;;
        --base-sha)    base_sha="$2"; shift 2;;
        --base-branch) base_branch="$2"; shift 2;;
        --worktree)    worktree="$2"; shift 2;;
        --test)        test_cmd="$2"; shift 2;;
        --lint)        lint_cmd="$2"; shift 2;;
        --typecheck)   typecheck_cmd="$2"; shift 2;;
        --ws-root)     ws_root="$2"; shift 2;;
        --repos)       repos_json="$2"; shift 2;;
        *) echo "feature-init: unknown flag '$1'" >&2; exit 1;;
      esac
    done
    [[ -z "$slug" || -z "$now" || -z "$style" ]] && {
      echo "feature-init: --slug --now --style are required" >&2; exit 1; }

    base="$(common_skeleton "$slug" "$now" "$style" "$title")"

    case "$mode" in
      single)
        echo "$base" | jq \
          --arg branch "$branch" --arg sha "$base_sha" --arg bb "$base_branch" \
          --arg wt "$worktree" \
          --arg test "$test_cmd" --arg lint "$lint_cmd" --arg tc "$typecheck_cmd" \
          '. + {
            branch: $branch, baseSha: $sha, baseBranch: $bb, worktreePath: $wt,
            workspace: null,
            commands: {test: $test, lint: $lint, typecheck: $tc}
          }'
        ;;
      workspace)
        [[ -z "$ws_root" ]] && { echo "feature-init: --ws-root required in workspace mode" >&2; exit 1; }
        echo "$base" | jq \
          --arg wsroot "$ws_root" --argjson repos "$repos_json" \
          '. + {
            branch: null, baseSha: null, baseBranch: null, worktreePath: null,
            workspace: {root: $wsroot, repos: $repos},
            commands: {test: "", lint: "", typecheck: ""}
          }'
        ;;
      *)
        echo "feature-init: --mode must be 'single' or 'workspace'" >&2; exit 1;;
    esac
    ;;
  *)
    echo "usage: feature-init.sh models | skeleton --mode single|workspace ..." >&2
    exit 1
    ;;
esac
