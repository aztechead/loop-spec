#!/usr/bin/env bash
# Single source of truth for the schema-7 feature.json skeleton and model routing.
# cycle Step 5 (state init) and the phase-entry activation step both call this so
# persisted routing and actual Agent dispatches cannot drift.
#
# Env overrides:
#   LOOP_SPEC_PHASE_MODEL_<PHASE> sets the default for every Agent launched in a
#   phase and for a fresh Claude Code / Agent SDK phase orchestrator.
#   LOOP_SPEC_MODEL_<ROLE> is the more-specific role override and wins when both
#   are set. Per-task model/modelTier metadata remains more specific still.
#
# Usage:
#   bash lib/feature-init.sh models [--phase PHASE]
#       -> prints the effective role map for PHASE.
#   bash lib/feature-init.sh phase-model PHASE
#       -> prints the configured phase alias, or an empty line when unset.
#   bash lib/feature-init.sh phase-models
#       -> prints all persisted phase overrides as a JSON object (unset = null).
#   bash lib/feature-init.sh all-models
#       -> prints the unique aliases that startup must health-check.
#   bash lib/feature-init.sh activate FEATURE_DIR PHASE
#       -> atomically writes the effective `.models` and `.phaseModels` maps before
#          the phase skill is invoked.
#
#   bash lib/feature-init.sh skeleton --mode single \
#       --slug S --now ISO --style ST --title "ORIGINAL GOAL" \
#       --branch feat/S --base-sha SHA --base-branch BB --worktree PATH \
#       --prepare CMD --test CMD --lint CMD --typecheck CMD
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

# validate_model_alias <variable-name> <value>
#
# Empty is accepted by callers as "not configured". Non-empty values must be a
# Claude Code Agent-tool alias. The main Claude Code CLI / Agent SDK accepts full
# IDs too, but phase values also feed subagent `model:` fields, whose contract is
# the alias enum; one portable value therefore has to satisfy the stricter surface.
validate_model_alias() {
  local var="$1"
  local val="$2"
  case "$val" in
    ""|sonnet|opus|haiku|fable)
      return 0
      ;;
    *)
      echo "feature-init: ${var}='${val}' is not a valid harness alias." \
           "Allowed: sonnet | opus | haiku | fable." \
           "Literal model IDs (e.g. claude-opus-4-8) are rejected because phase" \
           "models are also passed to the Agent tool's alias-only model parameter." >&2
      return 1
      ;;
  esac
}

validate_phase() {
  case "${1:-}" in
    spec|discuss|plan|execute|verify|iterate|deliver) return 0 ;;
    *)
      echo "feature-init: phase must be one of: spec | discuss | plan | execute | verify | iterate | deliver." >&2
      return 1
      ;;
  esac
}

phase_env_suffix() {
  case "$1" in
    spec) echo SPEC ;;
    discuss) echo DISCUSS ;;
    plan) echo PLAN ;;
    execute) echo EXECUTE ;;
    verify) echo VERIFY ;;
    iterate) echo ITERATE ;;
    deliver) echo DELIVER ;;
    *) validate_phase "$1"; return 1 ;;
  esac
}

# resolve_phase_model <phase>
#
# Prints the configured phase alias. An empty line means the phase inherits the
# session model for its main context and canonical role models for its Agents.
resolve_phase_model() {
  local phase="$1"
  local suffix var val
  suffix="$(phase_env_suffix "$phase")" || return 1
  var="LOOP_SPEC_PHASE_MODEL_${suffix}"
  val="${!var:-}"
  validate_model_alias "$var" "$val" || return 1
  echo "$val"
}

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
  validate_model_alias "$var" "$val" || return 1
  echo "$val"
}

# Effective models map -- the only definition of which model each role uses.
# Mirrors skills/shared/model-matrix.md. When a role is added, add it HERE only.
# Precedence is task override (consumed by the dispatch rung), explicit role env,
# explicit phase env, then the canonical role default.
#
# Each role is resolved into a local variable before the jq call so that a failed
# resolve_role_model (invalid env value) returns a non-zero exit from this function
# before jq ever runs. The pattern `local v; v=$(cmd) || return 1` is required
# because `local v=$(cmd)` masks the exit code (local is its own command).
canonical_models() {
  local phase="${1:-}"
  local phase_default=""
  local v_specWriter v_planner v_advocate v_challenger v_specComplianceReviewer
  local v_iterateJudge v_codeReviewer v_implementer v_verifier v_mapper v_patternMapper

  if [[ -n "$phase" ]]; then
    validate_phase "$phase" || return 1
    phase_default="$(resolve_phase_model "$phase")" || return 1
  fi

  v_specWriter=$(resolve_role_model SPEC_WRITER "${phase_default:-$OPUS}")                        || return 1
  v_planner=$(resolve_role_model PLANNER "${phase_default:-$OPUS}")                               || return 1
  v_advocate=$(resolve_role_model ADVOCATE "${phase_default:-$SONNET}")                           || return 1
  v_challenger=$(resolve_role_model CHALLENGER "${phase_default:-$OPUS}")                         || return 1
  v_specComplianceReviewer=$(resolve_role_model SPEC_COMPLIANCE_REVIEWER "${phase_default:-$SONNET}") || return 1
  v_iterateJudge=$(resolve_role_model ITERATE_JUDGE "${phase_default:-$OPUS}")                    || return 1
  v_codeReviewer=$(resolve_role_model CODE_REVIEWER "${phase_default:-$OPUS}")                    || return 1
  v_implementer=$(resolve_role_model IMPLEMENTER "${phase_default:-$SONNET}")                     || return 1
  v_verifier=$(resolve_role_model VERIFIER "${phase_default:-$SONNET}")                           || return 1
  v_mapper=$(resolve_role_model MAPPER "${phase_default:-$SONNET}")                               || return 1
  v_patternMapper=$(resolve_role_model PATTERN_MAPPER "${phase_default:-$SONNET}")                || return 1

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

canonical_phase_models() {
  local spec discuss plan execute verify iterate deliver
  spec="$(resolve_phase_model spec)" || return 1
  discuss="$(resolve_phase_model discuss)" || return 1
  plan="$(resolve_phase_model plan)" || return 1
  execute="$(resolve_phase_model execute)" || return 1
  verify="$(resolve_phase_model verify)" || return 1
  iterate="$(resolve_phase_model iterate)" || return 1
  deliver="$(resolve_phase_model deliver)" || return 1

  jq -n \
    --arg spec "$spec" --arg discuss "$discuss" --arg plan "$plan" \
    --arg execute "$execute" --arg verify "$verify" --arg iterate "$iterate" \
    --arg deliver "$deliver" \
    '{
      spec: (if $spec == "" then null else $spec end),
      discuss: (if $discuss == "" then null else $discuss end),
      plan: (if $plan == "" then null else $plan end),
      execute: (if $execute == "" then null else $execute end),
      verify: (if $verify == "" then null else $verify end),
      iterate: (if $iterate == "" then null else $iterate end),
      deliver: (if $deliver == "" then null else $deliver end)
    }'
}

# Every map is resolved BEFORE anything is printed. A brace-group pipeline would
# emit the maps that resolved successfully and then fail, handing a caller that
# reads stdout without checking $? a plausible-looking-but-short alias set — the
# exact silent fallback the startup health check is supposed to make impossible.
all_effective_models() {
  local phase maps map
  maps="$(canonical_models)" || return 1
  for phase in spec discuss plan execute verify iterate deliver; do
    map="$(canonical_models "$phase")" || return 1
    maps="${maps}"$'\n'"${map}"
  done
  printf '%s\n' "$maps" | jq -s '[.[] | .[]] | unique'
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
  local models_json phase_models_json
  models_json="$(canonical_models spec)" || return 1
  phase_models_json="$(canonical_phase_models)" || return 1
  jq -n \
    --arg slug "$slug" --arg now "$now" --arg style "$style" \
    --arg title "$title" \
    --argjson models "$models_json" \
    --argjson phaseModels "$phase_models_json" \
    --argjson tierblocks "$(fixed_blocks)" \
    '{
      schemaVersion: 7,
      slug: $slug,
      feature_title: (if $title == "" then $slug else $title end),
      createdAt: $now, updatedAt: $now,
      execStyle: $style,
      phaseHandoff: false,
      models: $models,
      phaseModels: $phaseModels,
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
      prUrl: null,
      checkpointPrUrl: null,
      delivery: {
        status: "pending",
        attemptedAt: null,
        finishedAt: null,
        nextPhase: null,
        ciRemediationAttempts: 0,
        ciRemediationLimit: 2,
        targets: []
      },
      warnings: [],
      bootstrapPendingDomains: [],
      verificationBaseline: null
    } + $tierblocks'
}

case "${1:-}" in
  models)
    shift
    phase=""
    if [[ $# -gt 0 ]]; then
      [[ "${1:-}" == "--phase" && $# -eq 2 ]] || {
        echo "usage: feature-init.sh models [--phase PHASE]" >&2
        exit 1
      }
      phase="$2"
    fi
    canonical_models "$phase"
    ;;
  phase-model)
    [[ $# -eq 2 ]] || {
      echo "usage: feature-init.sh phase-model PHASE" >&2
      exit 1
    }
    resolve_phase_model "$2"
    ;;
  phase-models)
    [[ $# -eq 1 ]] || {
      echo "usage: feature-init.sh phase-models" >&2
      exit 1
    }
    canonical_phase_models
    ;;
  all-models)
    [[ $# -eq 1 ]] || {
      echo "usage: feature-init.sh all-models" >&2
      exit 1
    }
    all_effective_models
    ;;
  activate)
    [[ $# -eq 3 ]] || {
      echo "usage: feature-init.sh activate FEATURE_DIR PHASE" >&2
      exit 1
    }
    feature_dir="$2"
    phase="$3"
    [[ -f "$feature_dir/feature.json" ]] || {
      echo "feature-init: feature.json not found in '$feature_dir'." >&2
      exit 1
    }
    effective_models="$(canonical_models "$phase")" || exit 1
    effective_phases="$(canonical_phase_models)" || exit 1
    updated_json="$(jq \
      --argjson models "$effective_models" \
      --argjson phaseModels "$effective_phases" \
      '.models = ((.models // {}) * $models) | .phaseModels = $phaseModels' \
      "$feature_dir/feature.json")" || exit 1
    bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-write.sh" \
      "$feature_dir" "$updated_json"
    ;;
  skeleton)
    shift
    mode="" slug="" now="" style="" title=""
    branch="" base_sha="" base_branch="" worktree=""
    prepare_cmd="" test_cmd="" lint_cmd="" typecheck_cmd=""
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
        --prepare)     prepare_cmd="$2"; shift 2;;
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
          --arg prepare "$prepare_cmd" --arg test "$test_cmd" --arg lint "$lint_cmd" --arg tc "$typecheck_cmd" \
          '. + {
            branch: $branch, baseSha: $sha, baseBranch: $bb,
            worktreePath: (if $wt == "" then null else $wt end),
            executionRootMode: (if $wt == "" then "in-place" else "worktree" end),
            workspace: null,
            commands: {prepare: $prepare, test: $test, lint: $lint, typecheck: $tc}
          }'
        ;;
      workspace)
        [[ -z "$ws_root" ]] && { echo "feature-init: --ws-root required in workspace mode" >&2; exit 1; }
        echo "$base" | jq \
          --arg wsroot "$ws_root" --argjson repos "$repos_json" \
          '. + {
            branch: null, baseSha: null, baseBranch: null, worktreePath: null,
            executionRootMode: "workspace",
            workspace: {
              root: $wsroot,
              repos: ($repos | map(
                (.commands // {}) as $c
                | .commands = ($c * {
                    prepare: ($c.prepare // ""), test: ($c.test // ""),
                    lint: ($c.lint // ""), typecheck: ($c.typecheck // "")
                  })
                | .verificationBaseline = (.verificationBaseline // null)
              ))
            },
            commands: {prepare: "", test: "", lint: "", typecheck: ""}
          }'
        ;;
      *)
        echo "feature-init: --mode must be 'single' or 'workspace'" >&2; exit 1;;
    esac
    ;;
  *)
    echo "usage: feature-init.sh models [--phase PHASE] | phase-model PHASE | phase-models | all-models | activate FEATURE_DIR PHASE | skeleton --mode single|workspace ..." >&2
    exit 1
    ;;
esac
