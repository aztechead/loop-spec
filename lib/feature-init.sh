#!/usr/bin/env bash
# Single source of truth for the schema-7 feature.json skeleton and the canonical
# models map. cycle Step 5 (state init) and Step 5.9 (resume normalization) both call
# this so the two can never drift -- that drift is what previously dropped iterateJudge
# from the normalized models map.
#
# Usage:
#   bash lib/feature-init.sh models
#       -> prints the canonical models map (JSON object). The ONE place model roles live.
#
#   bash lib/feature-init.sh skeleton --mode single \
#       --slug S --now ISO --tier T --style ST \
#       --branch feat/S --base-sha SHA --base-branch BB --worktree PATH \
#       --test CMD --lint CMD --typecheck CMD
#       -> prints a complete single-repo schema-7 feature.json.
#
#   bash lib/feature-init.sh skeleton --mode workspace \
#       --slug S --now ISO --tier T --style ST \
#       --ws-root ROOT --repos REPOS_JSON
#       -> prints a complete workspace-mode schema-7 feature.json
#          (top-level branch/baseSha/baseBranch/worktreePath null; commands empty;
#           per-repo commands live in workspace.repos[].commands).
#
# Exit codes: 0 success; 1 bad invocation.
set -euo pipefail

OPUS="claude-opus-4-8"
SONNET="claude-sonnet-4-6"

# Canonical models map -- the only definition of which model each role uses.
# Mirrors skills/shared/model-matrix.md. When a role is added, add it HERE only.
canonical_models() {
  jq -n --arg o "$OPUS" --arg s "$SONNET" '{
    specWriter:$o, planner:$o, advocate:$o, challenger:$o, specComplianceReviewer:$o,
    iterateJudge:$o,
    implementer:$s, codeReviewer:$s, verifier:$s, mapper:$s, patternMapper:$s
  }'
}

# Tier-derived blocks (retryBudget + iterate), identical for single and workspace modes.
# Emitted as a JSON object merged into the skeleton.
tier_blocks() {
  local tier="$1"
  jq -n --arg tier "$tier" '{
    retryBudget: {
      perGate: (if $tier == "quick" then 1 elif $tier == "balanced" then 2 else 3 end),
      perPhase: {
        spec:    (if $tier == "quick" then 1 elif $tier == "balanced" then 2 else 3 end),
        discuss: (if $tier == "quick" then 1 elif $tier == "balanced" then 2 else 3 end),
        plan:    (if $tier == "quick" then 1 elif $tier == "balanced" then 3 else 4 end),
        execute: null,
        verify:  (if $tier == "quick" then 2 elif $tier == "balanced" then 3 else 4 end),
        iterate: (if $tier == "quick" then 1 elif $tier == "balanced" then 2 else 3 end)
      },
      global: (if $tier == "quick" then 10 elif $tier == "balanced" then 20 else 30 end),
      globalUsed: 0,
      perGateUsed: {},
      perPhaseUsed: {spec: 0, discuss: 0, plan: 0, execute: 0, verify: 0, iterate: 0}
    },
    iterate: {
      maxIterations: (if $tier == "quick" then 1 elif $tier == "balanced" then 2 else 3 end),
      used: 0,
      lastVerdict: null,
      feedback: null,
      history: []
    }
  }'
}

# Common skeleton (everything except the mode-specific branch/worktree/workspace block
# and the commands field). $1=slug $2=now $3=tier $4=style.
common_skeleton() {
  local slug="$1" now="$2" tier="$3" style="$4"
  jq -n \
    --arg slug "$slug" --arg now "$now" --arg tier "$tier" --arg style "$style" \
    --argjson models "$(canonical_models)" \
    --argjson tierblocks "$(tier_blocks "$tier")" \
    '{
      schemaVersion: 7,
      slug: $slug,
      createdAt: $now, updatedAt: $now,
      tier: $tier, execStyle: $style,
      models: $models,
      currentPhase: "spec",
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
    mode="" slug="" now="" tier="" style=""
    branch="" base_sha="" base_branch="" worktree=""
    test_cmd="" lint_cmd="" typecheck_cmd=""
    ws_root="" repos_json="[]"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --mode)        mode="$2"; shift 2;;
        --slug)        slug="$2"; shift 2;;
        --now)         now="$2"; shift 2;;
        --tier)        tier="$2"; shift 2;;
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
    [[ -z "$slug" || -z "$now" || -z "$tier" || -z "$style" ]] && {
      echo "feature-init: --slug --now --tier --style are required" >&2; exit 1; }

    base="$(common_skeleton "$slug" "$now" "$tier" "$style")"

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
