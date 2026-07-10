#!/usr/bin/env bash
# run-digest.sh - Persist a compact, COMMITTED digest of one cycle run so the
# retrospective corpus survives volatile environments (containers/CI agents
# that are spun up per run and destroyed). events.jsonl/result.json are local
# telemetry and die with the workspace; the digest is small, lives under
# docs/loop-spec/telemetry/runs/ (committed with the feature branch), and is
# what lib/retro.sh mines when the local telemetry is gone.
#
# OBSERVABILITY CONTRACT: this script must NEVER abort a cycle. All internal
# failures print a one-line warning to stderr and exit 0. Same contract as
# lib/events.sh and lib/cycle-result.sh.
#
# Usage:
#   run-digest.sh append <feature_dir> [--out-dir <dir>]
#
# Writes <out-dir>/{slug}.json (default out-dir:
# <project-root>/docs/loop-spec/telemetry/runs, where project root is resolved
# as the parent of the .loop-spec dir containing <feature_dir>). One file per
# slug, overwritten on re-run (latest run wins) — unique filenames keep
# parallel volatile agents conflict-free in git.
#
# Digest schema (version 2 — additive over 1; consumers read every field with
# defaults, so v1 digests in the corpus stay valid):
#   {"schema": 2, "slug": ..., "status": ..., "converged": true|false|null,
#    "iterations": {"used": N, "max": N|null},
#    "gaps": ["plan", ...],          # unique iterate_verdict gap types (never "none")
#    "gateCaps": ["spec-critique"],  # gates that hit round >= 2
#    "iterateRounds": N,             # iterate_verdict events (rounds to converge/stop)
#    "gateRoundsByGate": {"spec-critique": maxRound, ...},
#    "verifyFailureClasses": ["suite-regression", ...],  # unique verify_failure classes
#    "warnings": N, "finishedAt": "ISO-8601|null"}
# The three convergence fields (ROADMAP-3.0 B1) feed lib/tuning.sh via the
# lib/status.sh metrics contract.
set -uo pipefail

_skip() { echo "run-digest: $*" >&2; exit 0; }

cmd="${1:-}"
[[ "$cmd" == "append" ]] || _skip "unknown subcommand '${cmd:-}' (usage: run-digest.sh append <feature_dir> [--out-dir <dir>])"
feature_dir="${2:-}"
[[ -n "$feature_dir" ]] || _skip "missing <feature_dir>"
[[ -d "$feature_dir" ]] || _skip "feature dir not found: $feature_dir"

OUT_DIR=""
shift 2 || true
while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --out-dir) OUT_DIR="${2:-}"; shift 2 || shift || true ;;
    *) shift || true ;;
  esac
done

fj="{}"; rj="null"; events="[]"
[[ -f "$feature_dir/feature.json" ]] && fj="$(cat "$feature_dir/feature.json" 2>/dev/null || echo '{}')"
jq -e . >/dev/null 2>&1 <<<"$fj" || fj="{}"
[[ -f "$feature_dir/result.json" ]] && rj="$(cat "$feature_dir/result.json" 2>/dev/null || echo 'null')"
jq -e . >/dev/null 2>&1 <<<"$rj" || rj="null"
if [[ -f "$feature_dir/events.jsonl" ]]; then
  events="$(jq -cs 'map(select(type == "object"))' "$feature_dir/events.jsonl" 2>/dev/null || echo '[]')"
fi

slug="$(jq -r '.slug // empty' <<<"$fj")"
[[ -n "$slug" ]] || slug="$(basename "$feature_dir")"

if [[ -z "$OUT_DIR" ]]; then
  feature_dir_abs="$(cd "$feature_dir" 2>/dev/null && pwd)" || _skip "cannot resolve $feature_dir"
  # feature dirs live at <project>/.loop-spec/features/<slug>
  project_root="$(cd "$feature_dir_abs/../../.." 2>/dev/null && pwd)" || _skip "cannot resolve project root"
  OUT_DIR="$project_root/docs/loop-spec/telemetry/runs"
fi

mkdir -p "$OUT_DIR" 2>/dev/null || _skip "cannot create $OUT_DIR"

digest="$(jq -cn --arg slug "$slug" --argjson fj "$fj" --argjson rj "$rj" --argjson events "$events" '
  {
    schema: 2,
    slug: $slug,
    status: ($rj.status // null),
    converged: (if ($rj | type) == "object" and ($rj | has("converged")) then $rj.converged else null end),
    iterations: {
      used: ($rj.iterations.used // $fj.iterate.used // 0),
      max: ($rj.iterations.max // $fj.iterate.maxIterations // null)
    },
    gaps: ([$events[] | select(.event == "iterate_verdict") | .data.gap // empty
            | select(. != "" and . != "none")] | unique),
    gateCaps: ([$events[] | select(.event == "gate_round" and ((.data.round // 0) >= 2))
                | .data.gate // empty | select(. != "")] | unique),
    iterateRounds: ([$events[] | select(.event == "iterate_verdict")] | length),
    gateRoundsByGate: ([$events[] | select(.event == "gate_round")
                        | {gate: (.data.gate // "unknown"), round: (.data.round // 0)}]
                       | group_by(.gate)
                       | map({key: .[0].gate, value: (map(.round) | max)})
                       | from_entries),
    verifyFailureClasses: ([$events[] | select(.event == "verify_failure")
                            | .data.class // empty | select(. != "")] | unique),
    warnings: (($fj.warnings // []) | length),
    finishedAt: ($rj.finishedAt // null)
  }')" 2>/dev/null || _skip "failed to build digest for $slug"

printf '%s\n' "$digest" > "$OUT_DIR/$slug.json" 2>/dev/null \
  || _skip "cannot write $OUT_DIR/$slug.json"

echo "run-digest: wrote $OUT_DIR/$slug.json"
exit 0
