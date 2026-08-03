#!/usr/bin/env bash
# Pin the skill-to-library Graphify lifecycle: refresh, localize, and workspace parity.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }
contains() {
  local file="$1" text="$2" label="$3"
  if grep -Fq -- "$text" "$ROOT/$file"; then pass "$label"; else fail "$label"; fi
}
absent() {
  local file="$1" text="$2" label="$3"
  if grep -Fq -- "$text" "$ROOT/$file"; then fail "$label"; else pass "$label"; fi
}

contains skills/shared/graphify-lifecycle.md 'Skill({skill: "graphify", args: arguments})' "Claude invokes external Graphify skill"
contains skills/shared/graphify-lifecycle.md 'skill({name: "graphify"})' "OpenCode invokes external Graphify skill"
contains skills/shared/graphify-lifecycle.md 'discovered external `graphify` skill' "pi resolves external Graphify skill"
contains skills/shared/graphify-lifecycle.md '"." for a missing graph' "missing graph uses full assistant build"
contains skills/shared/graphify-lifecycle.md '". --update" for a usable but stale graph' "existing graph uses semantic update"
contains skills/shared/graphify-lifecycle.md 'freshness = bash "$graphify_lib" freshness "$repo"' "matching source snapshot bypasses assistant refresh"
contains skills/shared/graphify-lifecycle.md 'bash "$graphify_lib" stamp "$repo"' "assistant refresh records source provenance"
contains skills/shared/graphify-lifecycle.md 'never ask a follow-up question' "embedded Graphify never pauses cycle"
contains skills/shared/graphify-lifecycle.md '"$graphify_lib" validate "$repo"' "assistant output is validated"
contains skills/shared/graphify-lifecycle.md '"$graphify_lib" localize "$repo"' "assistant output stays local"
contains skills/shared/graphify-lifecycle.md 'Do not stage or commit `graphify-out/` on a feature branch' "feature PR graph exclusion is explicit"
contains skills/shared/graphify-lifecycle.md 'graph-maintenance checkout' "out-of-band graph refresh is documented"
contains skills/shared/graphify-lifecycle.md '"$graphify_lib" publish "$repo"' "maintenance publishing is explicit"
absent skills/shared/graphify-lifecycle.md 'git -C "$repo" commit -m "$commit_message"' "feature lifecycle never commits graph output"
contains skills/cycle/SKILL.md 'skills/shared/graphify-lifecycle.md' "cycle delegates graph refresh"
contains skills/map-codebase/SKILL.md 'skills/shared/graphify-lifecycle.md' "map-codebase delegates graph refresh"
absent skills/cycle/SKILL.md 'graphify-preflight.sh" build' "cycle has no CLI graph build"
absent skills/map-codebase/SKILL.md 'graphify-preflight.sh" build' "map-codebase has no CLI graph build"
absent lib/graphify-preflight.sh '"$GRAPHIFY_BIN" update' "preflight has no CLI graph build"
contains skills/cycle/SKILL.md 'refresh only when stale' "cycle distinguishes a fresh graph from stale graph"
contains skills/map-codebase/SKILL.md 'lib/map-refresh.sh' "map-codebase decides stale domains before Graphify"
contains skills/map-codebase/SKILL.md '.workspace.repos // []' "map-codebase honors selected workspace repos"
absent skills/verify/SKILL.md 'graphify-preflight.sh" build .' "verify does not duplicate map refresh"
contains skills/verify/references/workspace-mode.md 'map-codebase skill detects workspace mode' "workspace delegates per-repo refresh"
absent skills/verify/references/workspace-mode.md 'skipping graphify update' "workspace does not skip graph refresh"
contains skills/cycle/SKILL.md 'Workspace resumes apply the same decision' "workspace resumes apply graph freshness per repository"
contains agents/planner.md '--graph "<repo>/graphify-out/graph.json"' "planner selects workspace graph"
contains agents/pattern-mapper.md '--graph "<repo>/graphify-out/graph.json"' "pattern mapper selects workspace graph"
contains README.md 'Graphify-Labs/graphify' "README links current Graphify organization"
contains README.md 'graphify-out/cache/' "README documents cache commit policy"
contains README.md 'graphify install --platform pi' "README registers Graphify for pi"
contains README.md 'graphify install --platform opencode' "README registers Graphify for OpenCode"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
