#!/usr/bin/env bash
# Graph engine — sequences declared workflow graphs.
#
# Usage:
#   run.sh [--dry-run] [--resume] --feature-dir DIR <graph.json>
#   run.sh --step [--resume] --feature-dir DIR <graph.json>
#
# --dry-run   traverse without dispatching node bodies or writing state; print
#             node/edge/kind/label per line, structural only.
# --resume    resolve the start node per docs/loop-spec/features/gdd/REMEDIATION-CONTRACT.md
#             sec 5 (pause record -> checkpoint ledger -> feature.json.currentPhase
#             pre-3.0 compat -> graph entry) instead of always starting at entry.
# --step      process at most one node and print its JSON dispatch descriptor to
#             stdout: {node, label, kind, body, effort, nextEdge, terminal, paused}.
#             Implies --resume (a step always continues from wherever the last
#             step/pause/checkpoint left off — see resolve_start() below). An
#             `agent` node's `nextEdge` is always null: its outgoing route may
#             depend on state the caller's dispatch has not written yet, so
#             routing is resolved lazily by the FOLLOWING --step call via
#             checkpoint-successor resolution, never guessed here on stale state.
#             `function`/`gate`/`subgraph` node bodies ARE dispatched in-process
#             during --step, exactly as they are without it. Entering or leaving
#             a working-phase node (spec..deliver) also emits phase_start /
#             phase_end on stderr — never on stdout, which this mode reserves
#             for the descriptor.
#
# Exit codes:
#   0  completed traversal, or --step returned a descriptor (check "terminal")
#   4  paused at a human node (resumable)
#   1  validation / runtime failure (assert-reads violation, gate body failure,
#      nested subgraph failure)
#   2  bad invocation
#   5  a node had route edges and none was satisfied, with no routeDefault
#      (REMEDIATION-CONTRACT.md sec 3) — never a silent chain fallthrough.
#
# harness-neutral: never branches on harness; node bodies may via lib/harness.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DRY_RUN=0
RESUME=0
STEP=0
FEATURE_DIR=""
GRAPH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --resume) RESUME=1; shift ;;
    --step) STEP=1; shift ;;
    --feature-dir) FEATURE_DIR="${2:-}"; shift 2 ;;
    -*)
      echo "usage: run.sh [--dry-run] [--resume] [--step] --feature-dir DIR <graph.json>" >&2
      exit 2
      ;;
    *)
      GRAPH="$1"; shift
      ;;
  esac
done

[[ -n "$GRAPH" ]] || {
  echo "usage: run.sh [--dry-run] [--resume] [--step] --feature-dir DIR <graph.json>" >&2
  exit 2
}
[[ -f "$GRAPH" ]] || { echo "run.sh: graph not found: $GRAPH" >&2; exit 2; }

if [[ -z "$FEATURE_DIR" ]]; then
  echo "run.sh: --feature-dir DIR is required" >&2
  exit 2
fi

# --step always continues from the last resolved position — there is no such
# thing as a fresh --step invocation.
[[ "$STEP" == "1" ]] && RESUME=1

# Validate first
if ! bash "$SCRIPT_DIR/validate.sh" "$GRAPH" >/dev/null; then
  echo "run.sh: graph failed validation: $GRAPH" >&2
  bash "$SCRIPT_DIR/validate.sh" "$GRAPH" >&2 || true
  exit 1
fi

# Absolutized before any probe runs: route/admit probes execute with
# cwd=repoRoot (contract sec 1), so a --feature-dir relative to the caller's
# own cwd must be resolved before that cwd changes underneath it.
mkdir -p "$FEATURE_DIR"
FEATURE_DIR="$(cd "$FEATURE_DIR" && pwd)"

exec python3 "$SCRIPT_DIR/engine.py" \
  "$GRAPH" "$FEATURE_DIR" "$DRY_RUN" "$RESUME" "$STEP" "$REPO_ROOT" "$SCRIPT_DIR"
