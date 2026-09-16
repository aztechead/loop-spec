#!/usr/bin/env bash
# design-budget.sh - Resolve the bounded design-phase budget from route evidence.
#
# The classifier's file and acceptance-criteria estimates are the only size signals
# available before PLAN writes tasks. Missing or malformed estimates keep the existing
# 60 minute ceiling; valid estimates get a ten minute base plus two minutes per file
# and one minute per criterion, capped at 60. The allowance is cumulative across the
# design phases, so a handoff cannot reset it.
# This is guidance for proactive phase sizing and a shared answer for the driver's
# after-return boundary. It never skips a gate or claims that a phase was preempted.
#
# Usage: design-budget.sh --feature-dir DIR --phase PHASE
# Output: budget=<minutes> elapsed=<minutes> remaining=<minutes> exhausted=<bool> budgetReason=<text>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "usage: design-budget.sh --feature-dir DIR --phase spec|discuss|plan" >&2
  exit 2
}

feature_dir=""; phase=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature-dir) feature_dir="${2:-}"; shift 2 || usage ;;
    --phase) phase="${2:-}"; shift 2 || usage ;;
    *) usage ;;
  esac
done
[[ -n "$feature_dir" && -f "$feature_dir/feature.json" ]] || usage
case "$phase" in spec|discuss|plan) ;; *) usage ;; esac
exec python3 "$SCRIPT_DIR/design_budget.py" "$feature_dir" "$phase"
