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
# Usage:
#   phase-entry.sh <spec|discuss|plan|execute|verify|iterate|deliver> --feature-dir DIR
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
# Exit 2 is a bad invocation.
#
# Ingress per phase (required files are FLAGged when absent; optional ones are listed
# only when present):
#   spec      fields slug feature_title execStyle greenfield autonomous artifacts.spec
#             optional spec-draft.md, spec-interview-transcript.md
#   discuss   fields slug feature_title execStyle autonomous iterate.feedback
#             currentGate; requires SPEC.md
#   plan      fields slug greenfield workspace iterate.feedback currentGate artifacts
#             models.planner models.challenger; requires SPEC.md; optional PATTERNS.md,
#             EVIDENCE.md
#   execute   fields slug branch baseSha commands workspace executionRootMode
#             worktreePath greenfield artifacts.tasks pendingRemediationTasks
#             models.implementer models.specComplianceReviewer; requires tasks.json,
#             PLAN.md; optional PATTERNS.md
#   verify    fields slug baseSha branch commands workspace artifacts.spec artifacts.plan
#             models.verifier models.codeReviewer; requires SPEC.md, PLAN.md
#   iterate   fields slug feature_title execStyle autonomous backlogEntryId iterate
#             artifacts models.iterateJudge; requires SPEC.md, VERIFICATION.md
#   deliver   fields slug branch baseBranch workspace artifacts; optional delivery.json
set -euo pipefail

phase="${1:-}"; shift || true
feature_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in --feature-dir) feature_dir="${2:-}"; shift 2 ;;
    *) echo "usage: phase-entry.sh <spec|discuss|plan|execute|verify|iterate|deliver> --feature-dir DIR" >&2; exit 2 ;;
  esac
done
case "$phase" in spec|discuss|plan|execute|verify|iterate|deliver) ;;
  *) echo "usage: phase-entry.sh <spec|discuss|plan|execute|verify|iterate|deliver> --feature-dir DIR" >&2; exit 2 ;;
esac
[[ -n "$feature_dir" && -f "$feature_dir/feature.json" ]] \
  || { echo "phase-entry: --feature-dir must hold a feature.json" >&2; exit 2; }
feature_dir="$(cd "$feature_dir" && pwd -P)"
fj="$feature_dir/feature.json"

slug="$(jq -r '.slug' "$fj")"
cp "$fj" "$feature_dir/.phase-entry.json"
ws_root="$(jq -r '.workspace.root // ""' "$fj")"
if [[ -n "$ws_root" ]]; then root="$ws_root"; else root="$(git -C "$feature_dir" rev-parse --show-toplevel)"; fi
docs="$root/docs/loop-spec/features/$slug"
flags=0

# fields KEY...: the packet is exactly these keys, dotted paths allowed, absent ones null.
fields() {
  local filter="" k
  for k in "$@"; do filter="$filter\"$k\": (.$k // null),"; done
  echo "fields=$(jq -c "{${filter%,}}" "$fj")"
}
# required WRITER PATH / optional PATH: list what exists; flag a required absence.
required() { if [[ -f "$2" ]]; then echo "read=$2"; else echo "FLAG [ingress] $2 missing: $1 did not write it"; flags=$((flags + 1)); fi; }
optional() { [[ -f "$1" ]] && echo "read=$1" || true; }

case "$phase" in
  spec)
    fields slug feature_title execStyle greenfield autonomous artifacts.spec
    optional "$feature_dir/spec-draft.md"
    optional "$feature_dir/spec-interview-transcript.md"
    ;;
  discuss)
    fields slug feature_title execStyle autonomous iterate.feedback currentGate
    required SPEC "$docs/SPEC.md"
    ;;
  plan)
    fields slug greenfield workspace iterate.feedback currentGate artifacts models.planner models.challenger
    required SPEC "$docs/SPEC.md"
    optional "$docs/PATTERNS.md"
    optional "$docs/EVIDENCE.md"
    ;;
  execute)
    fields slug branch baseSha commands workspace executionRootMode worktreePath greenfield \
      artifacts.tasks pendingRemediationTasks models.implementer models.specComplianceReviewer
    sidecar="$(jq -r '.artifacts.tasks // ""' "$fj")"
    required PLAN "${sidecar:-$feature_dir/tasks.json}"
    required PLAN "$docs/PLAN.md"
    optional "$docs/PATTERNS.md"
    ;;
  verify)
    fields slug baseSha branch commands workspace artifacts.spec artifacts.plan models.verifier models.codeReviewer
    required SPEC "$docs/SPEC.md"
    required PLAN "$docs/PLAN.md"
    ;;
  iterate)
    fields slug feature_title execStyle autonomous backlogEntryId iterate artifacts models.iterateJudge
    required SPEC "$docs/SPEC.md"
    required VERIFY "$docs/VERIFICATION.md"
    ;;
  deliver)
    fields slug branch baseBranch workspace artifacts
    optional "$feature_dir/delivery.json"
    ;;
esac

if (( flags == 0 )); then
  echo "phase-entry: ok ($phase)"
else
  echo "phase-entry: $flags flag(s) ($phase)"; exit 1
fi
