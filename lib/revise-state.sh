#!/usr/bin/env bash
# Ensure /loop-spec:revise has a schema-7 feature.json without the model
# reconstructing one. Fresh clones lose gitignored runtime state; EXECUTE's
# append path still needs the file. This helper either reuses the existing
# record (phase → revise, test command filled if empty) or writes a skeleton.
#
# Usage:
#   revise-state.sh ensure <revision_root> <slug> \
#     [--branch B] [--base-branch BB] [--base-sha SHA] [--title T] \
#     [--autonomous 0|1]
#
# Always runs runtime-ignore.sh revise-state first so the record cannot enter
# a remediation commit. Missing feature.json requires --branch.
#
# Output: one JSON object {featureDir, created, testCommand, currentPhase}.
# Exit: 0 ok; 2 bad invocation/precondition.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

die() { echo "revise-state: $*" >&2; exit 2; }

[[ "${1:-}" == "ensure" ]] || die "usage: revise-state.sh ensure <revision_root> <slug> [--branch B] [--base-branch BB] [--base-sha SHA] [--title T] [--autonomous 0|1]"
shift
[[ $# -ge 2 ]] || die "ensure requires <revision_root> <slug>"
revision_root="$1"
slug="$2"
shift 2

branch=""
base_branch=""
base_sha=""
title=""
autonomous="0"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch) branch="${2:-}"; shift 2 || shift ;;
    --base-branch) base_branch="${2:-}"; shift 2 || shift ;;
    --base-sha) base_sha="${2:-}"; shift 2 || shift ;;
    --title) title="${2:-}"; shift 2 || shift ;;
    --autonomous) autonomous="${2:-}"; shift 2 || shift ;;
    *) die "unknown flag '$1'" ;;
  esac
done

[[ "$slug" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "slug must be a safe identifier"
orig_root="$revision_root"
revision_root="$(git -C "$revision_root" rev-parse --show-toplevel 2>/dev/null)" \
  || die "not a git repository: $orig_root"
case "$autonomous" in 0|1) ;; *) die "--autonomous must be 0 or 1" ;; esac

bash "$SCRIPT_DIR/runtime-ignore.sh" revise-state "$revision_root" "$slug"

fdir="$revision_root/.loop-spec/features/$slug"
mkdir -p "$fdir"
created=false
fj="$fdir/feature.json"

resolve_test_cmd() {
  if [[ "${LOOP_SPEC_CMD_TEST+x}" == "x" ]]; then
    printf '%s' "$LOOP_SPEC_CMD_TEST"
  else
    bash "$SCRIPT_DIR/detect-test-cmd.sh" "$revision_root"
  fi
}

if [[ -f "$fj" ]]; then
  bash "$SCRIPT_DIR/feature-write.sh" set "$fdir" currentPhase '"revise"'
  existing_test="$(jq -r '.commands.test // ""' "$fj")"
  if [[ -z "$existing_test" ]]; then
    test_cmd="$(resolve_test_cmd)"
    bash "$SCRIPT_DIR/feature-write.sh" set "$fdir" commands.test "$(jq -cn --arg t "$test_cmd" '$t')"
  else
    test_cmd="$existing_test"
  fi
  if [[ "$autonomous" == "1" ]]; then
    bash "$SCRIPT_DIR/feature-write.sh" set "$fdir" autonomous true
  fi
else
  [[ -n "$branch" ]] || die "missing feature.json requires --branch"
  test_cmd="$(resolve_test_cmd)"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [[ -n "$title" ]] || title="$slug"
  skeleton="$(bash "$SCRIPT_DIR/feature-init.sh" skeleton --mode single \
    --slug "$slug" --now "$now" --style auto --title "$title" \
    --branch "$branch" --base-sha "$base_sha" --base-branch "$base_branch" \
    --test "$test_cmd")" || die "feature-init skeleton failed"
  auto_json=false
  [[ "$autonomous" == "1" ]] && auto_json=true
  skeleton="$(jq --argjson auto "$auto_json" \
    '.currentPhase = "revise" | .autonomous = $auto' <<<"$skeleton")"
  bash "$SCRIPT_DIR/feature-write.sh" "$fdir" "$skeleton"
  created=true
fi

jq -cn --arg dir "$fdir" --argjson created "$created" --arg test "$test_cmd" \
  '{featureDir:$dir,created:$created,testCommand:$test,currentPhase:"revise"}'
