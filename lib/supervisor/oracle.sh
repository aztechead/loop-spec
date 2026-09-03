#!/usr/bin/env bash
# oracle.sh - Who answers an interview question on this run? One line, decided from state.
#
# Why: autonomous mode had one answer, self-answer, and an attached human had the
# other, the interview. An SDK or ADK supervisor sits between them: the run is
# autonomous, and something can still answer the harness's question tool (Claude
# Agent SDK canUseTool, ADK get_user_choice). This probe names that middle mode so a
# phase asks the supervisor first and self-answers only when nothing answers. It
# refines the self-answer path lib/phase-mode.sh already selected; it never selects
# a phase. Rules for the supervised path: skills/shared/autonomous-mode.md.
#
# Usage:
#   oracle.sh mode [--feature-dir DIR]
#     oracle=<human|supervisor|self> reason=<text>
#
#   human       the run is not autonomous: the interview path, unchanged
#   supervisor  autonomous and LOOP_SPEC_ORACLE=supervisor: ask through the native
#               question tool, then apply the supervised-path rules
#   self        autonomous, LOOP_SPEC_ORACLE unset or self: the self-answer rule
#
# Autonomy is read the way phase-mode.sh reads it: feature.json.autonomous or
# LOOP_SPEC_AUTONOMOUS=1. A profile file is applied first (lib/profile.sh env).
# Fail-safe: an unknown LOOP_SPEC_ORACLE value answers self with the reason naming
# it. An override can route answers to a supervisor; nothing here can make a run
# autonomous that was not.
#
# Exit: 0 with an answer, 2 bad invocation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${1:-}" == "mode" ]] || { echo "usage: oracle.sh mode [--feature-dir DIR]" >&2; exit 2; }
shift
feature_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature-dir) feature_dir="${2:-}"; [[ -n "$feature_dir" ]] || { echo "usage: oracle.sh mode [--feature-dir DIR]" >&2; exit 2; }; shift 2 ;;
    *) echo "usage: oracle.sh mode [--feature-dir DIR]" >&2; exit 2 ;;
  esac
done

# shellcheck disable=SC2046
eval $(bash "$SCRIPT_DIR/../profile.sh" env 2>/dev/null || true)

autonomous=false; why="not-autonomous"
if [[ "${LOOP_SPEC_AUTONOMOUS:-}" == "1" ]]; then
  autonomous=true; why="LOOP_SPEC_AUTONOMOUS=1"
elif [[ -n "$feature_dir" && -f "$feature_dir/feature.json" ]] \
  && [[ "$(jq -r '.autonomous // false' "$feature_dir/feature.json" 2>/dev/null)" == "true" ]]; then
  autonomous=true; why="feature.json.autonomous"
fi

if [[ "$autonomous" != true ]]; then
  echo "oracle=human reason=$why"
  exit 0
fi

case "${LOOP_SPEC_ORACLE:-}" in
  supervisor) echo "oracle=supervisor reason=LOOP_SPEC_ORACLE=supervisor,$why" ;;
  ""|self) echo "oracle=self reason=${LOOP_SPEC_ORACLE:-unset},$why" ;;
  *) echo "oracle=self reason=unknown-value:${LOOP_SPEC_ORACLE},$why" ;;
esac
