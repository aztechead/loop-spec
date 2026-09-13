#!/usr/bin/env bash
# Shared opening for a phase's exit-gate script (lib/plan-exit-gate.sh,
# lib/execute-exit-gate.sh, lib/oneshot-exit-gate.sh).
#
# Source this file with the feature directory as its argument (set `gate_usage` first
# when the gate takes a subcommand). It validates the argument, then sets what every
# gate reads:
#
#   feature_dir  absolute       fj        feature.json path      slug
#   ws_root      workspace root, empty in single-repo mode
#   root         the repository root, or the workspace root (and the cwd from here on)
#   docs         docs/loop-spec/features/<slug>, relative to root
#   fget FILTER  a raw jq read of feature.json      lib NAME ARGS  runs lib/NAME.sh
#   flag TEXT    prints `FLAG TEXT`, counts it in $flags
#   run_gate LABEL CMD...  runs a bundled lint and relays its findings as FLAG [LABEL]
#
# It exists because the three gates opened with the same twenty lines and phase-exit.sh
# lists them as data (graph/cycle.graph.json egress.gates), so the fourth gate a graph
# adds should cost its checks and nothing else. A gate ends with
# `(( flags == 0 )) || exit 1`.
#
# Every caller (plan-exit-gate.sh, execute-exit-gate.sh, oneshot-exit-gate.sh) runs
# under `set -euo pipefail`; this line matches it so sourcing never changes the
# caller's mode underneath it.
set -euo pipefail
[[ -n "${1:-}" && -f "$1/feature.json" ]] || { echo "usage: $(basename "$0") ${gate_usage:-<feature-dir>}" >&2; exit 2; }
feature_dir="$(cd "$1" && pwd -P)"
fj="$feature_dir/feature.json"
fget() { bash "$SCRIPT_DIR/feature-read.sh" "$feature_dir" -r --filter "$1"; }
lib() { bash "$SCRIPT_DIR/$1.sh" "${@:2}"; }
slug="$(fget '.slug')"
ws_root="$(fget 'if (.workspace != null and (.workspace.mode // "") != "single") then .workspace.root else "" end')"
if [[ -n "$ws_root" ]]; then root="$ws_root"; else root="$(git -C "$feature_dir" rev-parse --show-toplevel)"; fi
cd "$root"
docs="docs/loop-spec/features/$slug"
flags=0
flag() { echo "FLAG $*"; flags=$((flags + 1)); }
run_gate() {
  local label="$1"; shift
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  if (( rc != 0 )); then
    printf '%s\n' "$out" | grep -E '^(FLAG|FLOOR)|^[^ ]|^ +- ' | sed "s/^/FLAG [$label] /" || true
    flags=$((flags + 1))
  fi
}
