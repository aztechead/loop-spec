#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/lib/resource-bounds.sh"
check() { [[ "$2" == "$3" ]] || { echo "FAIL: $1 (expected $2, got $3)"; exit 1; }; echo "PASS: $1"; }

check "default resolve is serial and not explicit" '{"maxParallelImplementers":1,"maxParallelSubagents":1,"explicit":false}' \
  "$(env -u LOOP_SPEC_MAX_PARALLEL_IMPLEMENTERS -u LOOP_SPEC_MAX_PARALLEL_SUBAGENTS bash "$LIB" resolve)"
check "default env exports nothing" '' \
  "$(env -u LOOP_SPEC_MAX_PARALLEL_IMPLEMENTERS -u LOOP_SPEC_MAX_PARALLEL_SUBAGENTS bash "$LIB" env)"
check "env exports an operator's bounds, validated" \
  $'export LOOP_SPEC_MAX_PARALLEL_IMPLEMENTERS=2\nexport LOOP_SPEC_MAX_PARALLEL_SUBAGENTS=4' \
  "$(LOOP_SPEC_MAX_PARALLEL_SUBAGENTS=4 LOOP_SPEC_MAX_PARALLEL_IMPLEMENTERS=2 bash "$LIB" env)"
check "subagent override propagates" '4' "$(env -u LOOP_SPEC_MAX_PARALLEL_IMPLEMENTERS LOOP_SPEC_MAX_PARALLEL_SUBAGENTS=4 bash "$LIB" get implementers)"
check "implementer override wins" '2' "$(LOOP_SPEC_MAX_PARALLEL_SUBAGENTS=4 LOOP_SPEC_MAX_PARALLEL_IMPLEMENTERS=2 bash "$LIB" get implementers)"
check "implementer-only bound is not clamped by default subagent one" '3:3' \
  "$(env -u LOOP_SPEC_MAX_PARALLEL_SUBAGENTS LOOP_SPEC_MAX_PARALLEL_IMPLEMENTERS=3 bash "$LIB" resolve | jq -r '(.maxParallelSubagents | tostring) + ":" + (.maxParallelImplementers | tostring)')"
profile_file="$(mktemp)"
trap 'rm -f "$profile_file"' EXIT
printf '%s\n' '{"preset":"interactive","env":{"LOOP_SPEC_MAX_PARALLEL_SUBAGENTS":"3"}}' > "$profile_file"
profile_cap="$(env -u LOOP_SPEC_MAX_PARALLEL_SUBAGENTS -u LOOP_SPEC_MAX_PARALLEL_IMPLEMENTERS \
  LOOP_SPEC_PROFILE="$profile_file" bash -c "cd '$ROOT'; eval \"\$(bash lib/profile.sh env)\"; bash lib/resource-bounds.sh resolve" )"
check "profile cap reaches resource resolver" '{"maxParallelImplementers":3,"maxParallelSubagents":3,"explicit":true}' "$profile_cap"
set +e
LOOP_SPEC_MAX_PARALLEL_SUBAGENTS=0 bash "$LIB" resolve >/dev/null 2>&1
rc=$?
set -e
check "zero override rejected" '2' "$rc"
check "no-worktrees clamps subagent cap" '1' \
  "$(LOOP_SPEC_WORKTREES=0 LOOP_SPEC_MAX_PARALLEL_SUBAGENTS=4 bash "$LIB" get subagents)"
check "no-worktrees clamps implementer cap" '1' \
  "$(LOOP_SPEC_WORKTREES=0 LOOP_SPEC_MAX_PARALLEL_SUBAGENTS=4 LOOP_SPEC_MAX_PARALLEL_IMPLEMENTERS=3 bash "$LIB" get implementers)"
echo "Results: resource bounds passed"
