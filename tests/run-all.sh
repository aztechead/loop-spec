#!/usr/bin/env bash
# Run every non-CC test suite (validators + hook + lib units + workflow syntax).
#
# Usage: bash tests/run-all.sh
# Exits 0 if all pass, 1 otherwise.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

TOTAL_PASS=0
TOTAL_FAIL=0

run_suite() {
  local name="$1"
  local cmd="$2"
  echo ""
  echo "=== $name ==="
  if bash -c "$cmd"; then
    : # individual suite already prints its own pass/fail line
  else
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    echo "SUITE FAILED: $name"
    return
  fi
  TOTAL_PASS=$((TOTAL_PASS + 1))
}

run_suite "validate-agents"           "bash tests/validate-agents.sh"
run_suite "validate-manifest"         "bash tests/validate-manifest.test.sh"
run_suite "validate-agents-frontmatter" "bash tests/validate-agents.test.sh"
run_suite "restrict-agent-paths"      "bash hooks/restrict-agent-paths.test.sh"
run_suite "lib/feature-write"         "bash tests/lib/feature-write.test.sh"
run_suite "lib/team-ops"              "bash tests/lib/team-ops.test.sh"
run_suite "lib/git-ops"               "bash tests/lib/git-ops.test.sh"
run_suite "lib/gsd-ingest"            "bash tests/lib/gsd-ingest.test.sh"
run_suite "hooks/team/teammate-idle"  "bash hooks/team/teammate-idle.test.sh"
run_suite "hooks/team/task-created"   "bash hooks/team/task-created.test.sh"
run_suite "hooks/team/task-completed" "bash hooks/team/task-completed.test.sh"
run_suite "hooks/team/post-task-complete-revalidate" "bash hooks/team/post-task-complete-revalidate.test.sh"
run_suite "hooks/team/stop-revalidate-user-gates" "bash hooks/team/stop-revalidate-user-gates.test.sh"
run_suite "hooks/team/pre-task-blockedby-enforce" "bash hooks/team/pre-task-blockedby-enforce.test.sh"
run_suite "hooks/team/stop-deflection-guard" "bash hooks/team/stop-deflection-guard.test.sh"
run_suite "lib/validate-task-metadata" "bash tests/lib/validate-task-metadata.test.sh"
run_suite "lib/decision-coverage"     "bash tests/lib/decision-coverage.test.sh"
run_suite "lib/plan-adherence"        "bash tests/lib/plan-adherence.test.sh"
run_suite "lib/detect-test-cmd"       "bash tests/lib/detect-test-cmd.test.sh"
run_suite "lib/workspace"          "bash tests/lib/workspace.test.sh"
run_suite "lib/fragility-scan"     "bash tests/lib/fragility-scan.test.sh"
run_suite "lib/quality-loop-state" "bash tests/lib/quality-loop-state.test.sh"
run_suite "hooks/team/strategy-rotation" "bash hooks/team/strategy-rotation.test.sh"
run_suite "hooks/team/budget-gate"    "bash hooks/team/budget-gate.test.sh"
run_suite "hooks/team/discipline-inject" "bash hooks/team/discipline-inject.test.sh"
run_suite "hooks/team/output-compressor" "bash hooks/team/output-compressor.test.sh"
run_suite "hooks/team/done-criteria"  "bash hooks/team/done-criteria.test.sh"
run_suite "hooks/team/session-end-learnings" "bash hooks/team/session-end-learnings.test.sh"
run_suite "lib/migrate-schema-v3-to-v4"   "bash tests/lib/migrate-schema-v3-to-v4.test.sh"
run_suite "lib/worktree-commit-check" "bash tests/lib/worktree-commit-check.test.sh"
run_suite "lib/workflow-availability" "bash tests/lib/workflow-availability.test.sh"
run_suite "lib/dag-width"             "bash tests/lib/dag-width.test.sh"
run_suite "lib/plan-to-loop"          "bash tests/lib/plan-to-loop.test.sh"
run_suite "skills/loop-runner"        "bash skills/loop-runner/tests/run_tests.sh"

# Workflow scripts need a node runtime to syntax-check. Run the workflows smoke
# only when node is resolvable; otherwise skip (do not fail the suite) since the
# rest of run-all is pure bash and must stay runnable on node-less environments.
if command -v node >/dev/null 2>&1 || [[ -x "$HOME/.nvm/versions/node/v22.14.0/bin/node" ]]; then
  run_suite "workflows/smoke" "bash tests/workflows/smoke.sh"
else
  echo ""
  echo "=== workflows/smoke ==="
  echo "SKIP: no node runtime found; skipping workflow syntax checks"
fi

echo ""
echo "=== Summary ==="
echo "Suites passed: $TOTAL_PASS"
echo "Suites failed: $TOTAL_FAIL"
[[ "$TOTAL_FAIL" -gt 0 ]] && exit 1 || exit 0
