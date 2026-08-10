#!/usr/bin/env bash
# Node-stamped trace wrapper over lib/events.sh.
#
# Adds node, edge, probe, probeReason, and effort to every emitted event so the
# executed graph is reconstructable from events.jsonl alone. Inherits the
# observability contract: a telemetry failure prints one warning to stderr and
# exits 0.
#
# Usage:
#   trace.sh emit <feature_dir> <event> [--phase PHASE] [--data JSON]
#     --node ID --edge EDGE --probe PATH --probe-reason TEXT --effort MODE
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
EVENTS="${LOOP_SPEC_EVENTS:-$REPO_ROOT/lib/events.sh}"

_warn() { echo "graph/trace.sh: warning: $*" >&2; exit 0; }

[[ "${1:-}" == "emit" ]] || _warn "bad invocation — usage: trace.sh emit <feature_dir> <event> ..."

feature_dir="${2:-}"
event="${3:-}"
[[ -n "$feature_dir" && -n "$event" ]] || _warn "missing feature_dir or event"

phase_args=()
data_val="{}"
node=""
edge=""
probe=""
probe_reason=""
effort=""

shift 3 || true
while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --phase) phase_args=(--phase "${2:-}"); shift 2 || shift || true ;;
    --data) data_val="${2:-}"; shift 2 || shift || true ;;
    --node) node="${2:-}"; shift 2 || shift || true ;;
    --edge) edge="${2:-}"; shift 2 || shift || true ;;
    --probe) probe="${2:-}"; shift 2 || shift || true ;;
    --probe-reason) probe_reason="${2:-}"; shift 2 || shift || true ;;
    --effort) effort="${2:-}"; shift 2 || shift || true ;;
    *) shift || true ;;
  esac
done

# Delegate to events.sh — never abort if it fails.
if ! bash "$EVENTS" emit "$feature_dir" "$event" "${phase_args[@]}" --data "$data_val" >/dev/null 2>"${TMPDIR:-/tmp}/graph-trace-events.err.$$"; then
  err="$(cat "${TMPDIR:-/tmp}/graph-trace-events.err.$$" 2>/dev/null || true)"
  rm -f "${TMPDIR:-/tmp}/graph-trace-events.err.$$"
  _warn "events writer failed${err:+: $err}"
fi
rm -f "${TMPDIR:-/tmp}/graph-trace-events.err.$$"

events_file="$feature_dir/events.jsonl"
[[ -f "$events_file" ]] || _warn "events.jsonl missing after emit"

# Stamp top-level graph fields onto the last record.
if ! python3 - "$events_file" "$node" "$edge" "$probe" "$probe_reason" "$effort" <<'PY'
import json, sys
path, node, edge, probe, reason, effort = sys.argv[1:7]
try:
    with open(path, "r", encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    if not lines:
        sys.exit(1)
    rec = json.loads(lines[-1])
    rec["node"] = node if node != "" else None
    rec["edge"] = edge if edge != "" else None
    rec["probe"] = probe if probe != "" else None
    rec["probeReason"] = reason if reason != "" else None
    rec["effort"] = effort if effort != "" else None
    lines[-1] = json.dumps(rec, separators=(",", ":"))
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
except Exception:
    sys.exit(1)
PY
then
  _warn "failed to stamp graph fields onto events.jsonl"
fi

exit 0
