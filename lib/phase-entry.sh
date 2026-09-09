#!/usr/bin/env bash
# phase-entry.sh - One call names a phase's whole ingress: the feature.json fields it
# consumes and the files it must read, nothing else.
#
# Why: each phase skill opened with a prose list of inputs, and a session resuming after
# a handoff re-read feature.json whole, re-scanned the tree, and re-derived what the
# previous phase had already written. That churn is the cost of an imprecise ingress.
# This is the ingress, executable: the packet is the phase's reading list, and a missing
# required file is the previous phase's egress failure surfaced at the door instead of
# three tool calls later. phase-exit.sh is the matching egress.
#
# What a phase reads is DATA on its graph node: the `ingress` block of the phase's agent
# node in graph/cycle.graph.json (schema `phaseIngress`, contract
# skills/shared/graph-contract.md, Phase ingress and egress). This script is the loop
# over that block: `fields` is the packet, `required` files are FLAGged when absent
# (the flag names the phase that should have written each), `optional` files are listed
# only when present. Placeholders resolve here: {docs} {featureDir} {root} {slug} {spec}
# {tasks} {f:<dotted.key>}; lib/graph/validate.sh refuses any other. A graph copy is
# selected with LOOP_SPEC_GRAPH (tests/lib/graph-phases.test.sh).
#
# Usage:
#   phase-entry.sh <phase> --feature-dir DIR      (a phase id of lib/graph/phases.sh list)
#
# The call also copies feature.json to <DIR>/.phase-entry.json (ignored by the
# runtime ignore rules): phase-exit.sh diffs the file against it and names every key the
# phase changed outside its own allow-list, which is the egress half of this contract.
#
# Output:
#   fields=<compact JSON of the consumed feature.json keys>
#   read=<path>                one per existing file the phase reads, required or not
#   FLAG [ingress] <path> missing: <which phase should have written it>
#   phase-entry: ok (<phase>)          exit 0
#   phase-entry: <n> flag(s) (<phase>) exit 1
# Exit 2 is a bad invocation, including a phase whose node declares no ingress block.
set -euo pipefail

phase="${1:-}"; shift || true
feature_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in --feature-dir) feature_dir="${2:-}"; shift 2 ;;
    *) echo "usage: phase-entry.sh <phase> --feature-dir DIR" >&2; exit 2 ;;
  esac
done
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAPH="${LOOP_SPEC_GRAPH:-$SCRIPT_DIR/../graph/cycle.graph.json}"
bash "$SCRIPT_DIR/graph/phases.sh" validate "$phase" 2>/dev/null \
  || { echo "usage: phase-entry.sh <phase> --feature-dir DIR ($(bash "$SCRIPT_DIR/graph/phases.sh" validate "$phase" 2>&1))" >&2; exit 2; }
[[ -n "$feature_dir" && -f "$feature_dir/feature.json" ]] \
  || { echo "phase-entry: --feature-dir must hold a feature.json" >&2; exit 2; }
node="$(jq -c --arg p "$phase" '.nodes[] | select(.id == $p) | .ingress // empty' "$GRAPH" 2>/dev/null || true)"
[[ -n "$node" ]] \
  || { echo "phase-entry: the '$phase' node of $GRAPH declares no ingress block; nothing opens it here" >&2; exit 2; }
feature_dir="$(cd "$feature_dir" && pwd -P)"
fj="$feature_dir/feature.json"
fget() { bash "$SCRIPT_DIR/feature-read.sh" "$feature_dir" -r --filter "$1"; }

slug="$(fget '.slug')"
cp "$fj" "$feature_dir/.phase-entry.json"
ws_root="$(fget 'if (.workspace != null and (.workspace.mode // "") != "single") then .workspace.root else "" end')"
if [[ -n "$ws_root" ]]; then root="$ws_root"; else root="$(git -C "$feature_dir" rev-parse --show-toplevel)"; fi
docs="$root/docs/loop-spec/features/$slug"
spec="$(fget '.artifacts.spec // ""')"; [[ -n "$spec" ]] || spec="$docs/SPEC.md"
tasks="$(fget '.artifacts.tasks // ""')"; [[ -n "$tasks" ]] || tasks="$feature_dir/tasks.json"
flags=0

# {docs} resolves absolute,
# so a `read=` line opens from any cwd.
. "$SCRIPT_DIR/phase-placeholders.sh"
resolve() { loop_spec_resolve_phase_path "$1"; }
# fields KEY...: the packet is exactly these keys, dotted paths allowed, absent ones null.
fields() {
  local filter="" k
  for k in "$@"; do filter="$filter\"$k\": (.$k // null),"; done
  echo "fields=$(bash "$SCRIPT_DIR/feature-read.sh" "$feature_dir" -c --filter "{${filter%,}}")"
}
# required WRITER PATH / optional PATH: list what exists; flag a required absence.
required() { if [[ -f "$2" ]]; then echo "read=$2"; else echo "FLAG [ingress] $2 missing: $1 did not write it"; flags=$((flags + 1)); fi; }
optional() { [[ -f "$1" ]] && echo "read=$1" || true; }

keys=()
while IFS= read -r k; do keys+=("$k"); done < <(jq -r '.fields[]' <<<"$node")
fields ${keys[@]+"${keys[@]}"}
while IFS=$'\t' read -r writer path; do
  [[ -n "$writer" ]] || continue
  required "$writer" "$(resolve "$path")"
done < <(jq -r '.required[]? | [.writer, .path] | @tsv' <<<"$node")
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  optional "$(resolve "$path")"
done < <(jq -r '.optional[]?' <<<"$node")

if (( flags == 0 )); then
  echo "phase-entry: ok ($phase)"
else
  echo "phase-entry: $flags flag(s) ($phase)"; exit 1
fi
