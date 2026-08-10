#!/usr/bin/env bash
# Answer, per node, how hard to think: system1 (throughput) or system2 (deliberation).
#
# Deterministic inputs only — no model judgment. Any unresolvable input yields
# system2 (fail safe toward deliberation). Explicit operator overrides outrank
# the computed answer in both directions; more-specific forms win:
#   LOOP_SPEC_EFFORT_NODE > LOOP_SPEC_EFFORT_PHASE > LOOP_SPEC_EFFORT
#
# Usage:
#   effort-probe.sh --node-kind KIND --security-signal SIGNAL --width N \
#     --changed-files N --task-count N --attempt N --authorizes-delivery BOOL \
#     [--phase PHASE] [--node-id ID]
#
# Output (one line): mode=(system1|system2) reason=<text>
# Exit: 0 on well-formed invocation; 2 on bad usage.
set -euo pipefail

usage() {
  echo "usage: effort-probe.sh --node-kind KIND --security-signal SIGNAL --width N --changed-files N --task-count N --attempt N --authorizes-delivery BOOL [--phase PHASE] [--node-id ID]" >&2
  exit 2
}

node_kind=""
security_signal=""
width=""
changed_files=""
task_count=""
attempt=""
authorizes_delivery=""
phase=""
node_id=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node-kind) node_kind="${2:-}"; shift 2 ;;
    --security-signal) security_signal="${2:-}"; shift 2 ;;
    --width) width="${2:-}"; shift 2 ;;
    --changed-files) changed_files="${2:-}"; shift 2 ;;
    --task-count) task_count="${2:-}"; shift 2 ;;
    --attempt) attempt="${2:-}"; shift 2 ;;
    --authorizes-delivery) authorizes_delivery="${2:-}"; shift 2 ;;
    --phase) phase="${2:-}"; shift 2 ;;
    --node-id) node_id="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$node_kind" && -n "$security_signal" && -n "$width" \
   && -n "$changed_files" && -n "$task_count" && -n "$attempt" \
   && -n "$authorizes_delivery" ]] || usage

emit() {
  echo "mode=$1 reason=$2"
  exit 0
}

# Operator overrides — most specific wins.
if [[ -n "${LOOP_SPEC_EFFORT_NODE:-}" ]]; then
  case "${LOOP_SPEC_EFFORT_NODE}" in
    system1|system2) emit "$LOOP_SPEC_EFFORT_NODE" "override:node:${LOOP_SPEC_EFFORT_NODE}" ;;
    *) emit system2 "override:node:invalid" ;;
  esac
fi
if [[ -n "${LOOP_SPEC_EFFORT_PHASE:-}" ]]; then
  case "${LOOP_SPEC_EFFORT_PHASE}" in
    system1|system2) emit "$LOOP_SPEC_EFFORT_PHASE" "override:phase:${LOOP_SPEC_EFFORT_PHASE}" ;;
    *) emit system2 "override:phase:invalid" ;;
  esac
fi
if [[ -n "${LOOP_SPEC_EFFORT:-}" ]]; then
  case "${LOOP_SPEC_EFFORT}" in
    system1|system2) emit "$LOOP_SPEC_EFFORT" "override:global:${LOOP_SPEC_EFFORT}" ;;
    *) emit system2 "override:global:invalid" ;;
  esac
fi

# Unresolvable inputs -> system2
[[ "$width" =~ ^[0-9]+$ ]] || emit system2 "unresolved:width"
[[ "$changed_files" =~ ^[0-9]+$ ]] || emit system2 "unresolved:changed-files"
[[ "$task_count" =~ ^[0-9]+$ ]] || emit system2 "unresolved:task-count"
[[ "$attempt" =~ ^[0-9]+$ ]] || emit system2 "unresolved:attempt"
case "$authorizes_delivery" in
  true|false) ;;
  *) emit system2 "unresolved:authorizes-delivery" ;;
esac
case "$node_kind" in
  agent|function|gate|human|subgraph) ;;
  *) emit system2 "unresolved:node-kind" ;;
esac

# Delivery-authorizing nodes always deliberate.
if [[ "$authorizes_delivery" == "true" ]]; then
  emit system2 "delivery-authorizing-node"
fi

# Security signal present (anything other than none/empty).
if [[ "$security_signal" != "none" && -n "$security_signal" ]]; then
  emit system2 "security-signal:${security_signal}"
fi

# Retries: prior attempt means previous try failed or was contested.
if (( attempt >= 1 )); then
  emit system2 "attempt:${attempt}"
fi

# Structural size thresholds — habitual small work stays system1.
if (( width >= 3 )); then
  emit system2 "width:${width}"
fi
if (( changed_files >= 8 )); then
  emit system2 "changed-files:${changed_files}"
fi
if (( task_count >= 4 )); then
  emit system2 "task-count:${task_count}"
fi

# Agent/human/subgraph default to system2 unless trivially small (already checked).
case "$node_kind" in
  function|gate)
    emit system1 "small-${node_kind}"
    ;;
  *)
    # Small agent/human/subgraph with no other signal still deliberates once
    # unless truly tiny: width 1, one file, one task, attempt 0.
    if (( width <= 1 && changed_files <= 2 && task_count <= 2 )); then
      emit system1 "small-${node_kind}"
    fi
    emit system2 "node-kind:${node_kind}"
    ;;
esac
