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
#       -> prints the configured phase selector, or an empty line when unset.
#   bash lib/feature-init.sh phase-models
#       -> prints all persisted phase overrides as a JSON object (unset = null).
#   bash lib/feature-init.sh all-models
#       -> prints the unique selectors that startup must health-check.
#   bash lib/feature-init.sh validate
#       -> checks every phase and role selector once; prints nothing, exit 1 on a bad route.
#   bash lib/feature-init.sh agent-probe-models
#       -> prints only selectors accepted by Claude Agent({model:}); `inherit`
#          and full CLI IDs are omitted.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$(bash "$SCRIPT_DIR/harness.sh" detect)"

# Model routing defaults to the model that launched the session. Claude Code,
# OpenCode, and ADK define this inheritance behavior, so the cycle has no required
# provider, family, or model catalog. Claude role overrides may use Agent aliases;
# OpenCode/ADK native IDs: ADK dispatch_subagent consumes them for every role;
# OpenCode forwards only the implementer fleet --model flag.
INHERIT="inherit"

# validate_model_selector <variable-name> <value>
#
# Empty is accepted by callers as "not configured". Known aliases, `inherit`, and
# full IDs are accepted. A full ID must contain a separator (`-`, `/`, or `:`),
# which keeps a typo such as `bogus` from becoming a plausible route, and must
# START and END alphanumeric -- a dangling separator (`sonnet-`, `opus:`) is a
# truncated paste, not an ID, and must fail here rather than at the dispatch that
# consumes it.
validate_model_selector() {
  local var="$1"
  local val="$2"
  case "$val" in
    ""|inherit|sonnet|opus|haiku|fable)
      return 0
      ;;
    *)
      if [[ "$val" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*[A-Za-z0-9]$ && "$val" == *[-/:]* ]]; then
        return 0
      fi
      echo "feature-init: ${var}='${val}' is not a valid model selector." \
           "Use inherit, a Claude alias (sonnet | opus | haiku | fable)," \
           "or a full model ID." >&2
      return 1
      ;;
  esac
}

# validate_role_model_selector <role-suffix> <variable-name> <value>
#
# Role selectors eventually cross a subagent boundary. Claude's Agent tool accepts
# aliases only; a full CLI model ID cannot be forwarded there. OpenCode has no
# native per-role task parameter, so only the implementer fleet may carry an
# OpenCode provider/model ID. ADK's dispatch_subagent consumes a native id for
# every role. Reject unsupported pins here instead of silently dropping them
# at dispatch time.
validate_role_model_selector() {
  local role="$1"
  local var="$2"
  local val="$3"
  validate_model_selector "$var" "$val" || return 1
  if [[ "$HARNESS" == "claude" ]]; then
    case "$val" in
      ""|inherit|sonnet|opus|haiku|fable) return 0 ;;
    esac
    echo "feature-init: ${var}='${val}' cannot be passed to the Claude Agent tool." \
         "Use inherit or an Agent alias (sonnet | opus | haiku | fable)." >&2
    return 1
  fi

  [[ "$val" == "" || "$val" == "inherit" ]] && return 0
  case "$val" in
    sonnet|opus|haiku|fable)
      echo "feature-init: ${var}='${val}' is a Claude Agent alias, not a ${HARNESS} model ID." \
           "Use inherit or a harness-native model ID." >&2
      return 1
      ;;
  esac
  if [[ "$HARNESS" == "adk" ]]; then
    return 0
  fi
  [[ "$role" == "IMPLEMENTER" ]] && return 0

  echo "feature-init: ${var}='${val}' is not consumed by ${HARNESS} for role ${role}." \
       "Use inherit; configure native agents through the harness, or pin only" \
       "LOOP_SPEC_MODEL_<ROLE> with ROLE=IMPLEMENTER for the loop-fleet rung." >&2
  return 1
}

# Phase selectors use the main CLI/fleet surface. Claude accepts aliases and full
# IDs there. OpenCode and ADK accept only their native IDs; silently treating a
# Claude alias as inheritance would violate an explicit operator route.
validate_phase_model_selector() {
  local var="$1"
  local val="$2"
  validate_model_selector "$var" "$val" || return 1
  if [[ "$HARNESS" != "claude" ]]; then
    case "$val" in
      sonnet|opus|haiku|fable)
        echo "feature-init: ${var}='${val}' is a Claude Agent alias, not a ${HARNESS} model ID." \
             "Use inherit or a harness-native selector." >&2
        return 1
        ;;
    esac
  fi
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
# Prints the configured phase selector. An empty line means the phase inherits
# the session model for its main context and the role defaults for its agents.
resolve_phase_model() {
  local phase="$1"
  local suffix var val
  suffix="$(phase_env_suffix "$phase")" || return 1
  var="LOOP_SPEC_PHASE_MODEL_${suffix}"
  val="${!var:-}"
  validate_phase_model_selector "$var" "$val" || return 1
  echo "$val"
}

# resolve_role_model <ENV_SUFFIX> <default>
#
# Prints the resolved selector for a role. If LOOP_SPEC_MODEL_<ENV_SUFFIX> is set and
# non-empty it overrides the canonical default; if unset or empty the default is used.
#
resolve_role_model() {
  local env_suffix="$1"
  local default="$2"
  local var="LOOP_SPEC_MODEL_${env_suffix}"
  local val="${!var:-}"
  if [[ -z "$val" ]]; then
    echo "$default"
    return 0
  fi
  validate_role_model_selector "$env_suffix" "$var" "$val" || return 1
  echo "$val"
}

# Effective models map -- the only definition of which model each role uses.
# Implements the authoritative precedence in skills/shared/model-matrix.md. When
# a role is added, add it HERE only. Task overrides remain dispatch-rung inputs;
# this function resolves the role environment over the phase/default selector.
#
# Each role is resolved into a local variable before the jq call so that a failed
# resolve_role_model (invalid env value) returns a non-zero exit from this function
# before jq ever runs. The pattern `local v; v=$(cmd) || return 1` is required
# because `local v=$(cmd)` masks the exit code (local is its own command).
canonical_models() {
  local phase="${1:-}"
  local phase_default=""
  local role_phase_default=""
  local v_specWriter v_planner v_advocate v_challenger v_specComplianceReviewer
  local v_iterateJudge v_codeReviewer v_implementer v_verifier v_patternMapper
  if [[ -n "$phase" ]]; then
    validate_phase "$phase" || return 1
    phase_default="$(resolve_phase_model "$phase")" || return 1
  fi

  # A Claude full ID belongs to the fresh CLI/SDK phase launcher. Agent cannot
  # accept it, so role agents omit their model field and inherit that main model.
  # Aliases remain safe to pass directly to both surfaces.
  role_phase_default="$phase_default"
  if [[ "$HARNESS" == "claude" ]]; then
    case "$phase_default" in
      ""|inherit|sonnet|opus|haiku|fable) ;;
      *) role_phase_default="$INHERIT" ;;
    esac
  fi

  v_specWriter=$(resolve_role_model SPEC_WRITER "${role_phase_default:-$INHERIT}")                           || return 1
  v_planner=$(resolve_role_model PLANNER "${role_phase_default:-$INHERIT}")                                  || return 1
  v_advocate=$(resolve_role_model ADVOCATE "${role_phase_default:-$INHERIT}")                                || return 1
  v_challenger=$(resolve_role_model CHALLENGER "${role_phase_default:-$INHERIT}")                            || return 1
  v_specComplianceReviewer=$(resolve_role_model SPEC_COMPLIANCE_REVIEWER "${role_phase_default:-$INHERIT}") || return 1
  v_iterateJudge=$(resolve_role_model ITERATE_JUDGE "${role_phase_default:-$INHERIT}")                       || return 1
  v_codeReviewer=$(resolve_role_model CODE_REVIEWER "${role_phase_default:-$INHERIT}")                       || return 1
  v_implementer=$(resolve_role_model IMPLEMENTER "${role_phase_default:-$INHERIT}")                          || return 1
  v_verifier=$(resolve_role_model VERIFIER "${role_phase_default:-$INHERIT}")                                || return 1
  v_patternMapper=$(resolve_role_model PATTERN_MAPPER "${role_phase_default:-$INHERIT}")                     || return 1

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
# reads stdout without checking $? a plausible-looking-but-short selector set — the
# exact silent fallback the startup health check is supposed to make impossible.
all_effective_models() {
  local phase maps map phase_models
  maps="$(canonical_models)" || return 1
  for phase in spec discuss plan execute verify iterate deliver; do
    map="$(canonical_models "$phase")" || return 1
    maps="${maps}"$'\n'"${map}"
  done
  phase_models="$(canonical_phase_models)" || return 1
  maps="${maps}"$'\n'"${phase_models}"
  printf '%s\n' "$maps" | jq -s '[.[] | .[] | select(. != null)] | unique'
}

# validate_routing: every phase and role selector checked once, no subshells. This is
# what cycle startup needs; all_effective_models answers a different question (the
# union of selectors) at nine map resolutions, which cost two seconds of every start.
validate_routing() {
  local phase suffix var role
  for phase in spec discuss plan execute verify iterate deliver; do
    suffix="$(phase_env_suffix "$phase")"
    var="LOOP_SPEC_PHASE_MODEL_${suffix}"
    validate_phase_model_selector "$var" "${!var:-}" || return 1
  done
  for role in SPEC_WRITER PLANNER ADVOCATE CHALLENGER SPEC_COMPLIANCE_REVIEWER \
              ITERATE_JUDGE CODE_REVIEWER IMPLEMENTER VERIFIER PATTERN_MAPPER; do
    var="LOOP_SPEC_MODEL_${role}"
    [[ -z "${!var:-}" ]] || validate_role_model_selector "$role" "$var" "${!var}" || return 1
  done
}

agent_probe_models() {
  local selectors
  selectors="$(all_effective_models)" || return 1
  jq -c \
    '[.[] | select(. == "sonnet" or . == "opus" or . == "haiku" or . == "fable")]' \
    <<<"$selectors"
}

# Fixed operating block (iterate), identical for single and workspace modes.
# Critique delta rounds are bounded by graph/critique.graph.json (lib/graph/gate.sh
# next); every attempt still lands in gateHistory. The operator may lower or raise the
# cycle convergence ceiling here without changing loop-fleet limits.
fixed_blocks() {
  local max_iterations="${LOOP_SPEC_ITERATE_MAX_ITERATIONS:-10}"
  [[ "$max_iterations" =~ ^[1-9][0-9]*$ && "$max_iterations" -le 100 ]] || {
    echo "feature-init.sh: LOOP_SPEC_ITERATE_MAX_ITERATIONS must be an integer from 1 to 100" >&2
    return 2
  }
  jq -n --argjson max_iterations "$max_iterations" '{
    iterate: {
      maxIterations: $max_iterations,
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
  local models_json phase_models_json tier_blocks_json
  models_json="$(canonical_models spec)" || return 1
  phase_models_json="$(canonical_phase_models)" || return 1
  tier_blocks_json="$(fixed_blocks)" || return $?
  jq -n \
    --arg slug "$slug" --arg now "$now" --arg style "$style" \
    --arg title "$title" \
    --argjson models "$models_json" \
    --argjson phaseModels "$phase_models_json" \
    --argjson tierblocks "$tier_blocks_json" \
    '{
      schemaVersion: 7,
      slug: $slug,
      feature_title: (if $title == "" then $slug else $title end),
      createdAt: $now, updatedAt: $now,
      execStyle: $style,
      executionProfile: "standard",
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
        patternsSource: null
      },
      currentTeamName: null,
      currentTeammates: [],
      currentGate: {phase: null, gate: null, round: 0, advocateName: null,
                    challengerName: null, startedAt: null},
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
      verificationBaseline: null
    } + $tierblocks'
}

no_extra_args() {
  local sub="$1"; shift
  [[ $# -eq 1 ]] || { echo "usage: feature-init.sh $sub" >&2; exit 1; }
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
    no_extra_args phase-models "$@"
    canonical_phase_models
    ;;
  all-models)
    no_extra_args all-models "$@"
    all_effective_models
    ;;
  validate)
    no_extra_args validate "$@"
    validate_routing
    ;;
  agent-probe-models)
    no_extra_args agent-probe-models "$@"
    agent_probe_models
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
    echo "usage: feature-init.sh models [--phase PHASE] | phase-model PHASE | phase-models | all-models | validate | activate FEATURE_DIR PHASE | skeleton --mode single|workspace ..." >&2
    exit 1
    ;;
esac
