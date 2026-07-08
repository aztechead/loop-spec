#!/usr/bin/env bash
# Run every non-CC test suite (validators + hook + lib units + workflow syntax).
#
# Usage: bash tests/run-all.sh [--e2e]
#   --e2e  additionally run tests/e2e/run-e2e.sh (LIVE: real claude -p cycle,
#          costs tokens and minutes; the default suite stays offline)
# Exits 0 if all pass, 1 otherwise.
set -euo pipefail

RUN_E2E=0
for arg in "$@"; do
  case "$arg" in
    --e2e) RUN_E2E=1 ;;
    *) echo "run-all.sh: unknown flag '$arg' (supported: --e2e)" >&2; exit 2 ;;
  esac
done

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
run_suite "lib/teams-capability"      "bash tests/lib/teams-capability.test.sh"
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
run_suite "lib/criteria-coverage"     "bash tests/lib/criteria-coverage.test.sh"
run_suite "lib/skill-references"      "bash tests/lib/skill-references.test.sh"
run_suite "lib/harness-call-shapes"   "bash tests/lib/harness-call-shapes.test.sh"
run_suite "lib/test-tamper-scan"      "bash tests/lib/test-tamper-scan.test.sh"
run_suite "lib/backlog"               "bash tests/lib/backlog.test.sh"
run_suite "lib/autonomous-chain"      "bash tests/lib/autonomous-chain.test.sh"
run_suite "lib/parse-invocation"      "bash tests/lib/parse-invocation.test.sh"
run_suite "lib/decisions"             "bash tests/lib/decisions.test.sh"
run_suite "lib/debug-init"            "bash tests/lib/debug-init.test.sh"
run_suite "lib/greenfield-bootstrap"  "bash tests/lib/greenfield-bootstrap.test.sh"
run_suite "lib/cycle-preflight"       "bash tests/lib/cycle-preflight.test.sh"
run_suite "lib/plan-adherence"        "bash tests/lib/plan-adherence.test.sh"
run_suite "lib/detect-test-cmd"       "bash tests/lib/detect-test-cmd.test.sh"
run_suite "lib/workspace"          "bash tests/lib/workspace.test.sh"
run_suite "lib/fragility-scan"     "bash tests/lib/fragility-scan.test.sh"
run_suite "lib/quality-loop-state" "bash tests/lib/quality-loop-state.test.sh"
run_suite "hooks/team/strategy-rotation" "bash hooks/team/strategy-rotation.test.sh"
run_suite "hooks/team/discipline-inject" "bash hooks/team/discipline-inject.test.sh"
run_suite "hooks/team/grill-inject"   "bash hooks/team/grill-inject.test.sh"
run_suite "hooks/team/simplicity-inject" "bash hooks/team/simplicity-inject.test.sh"
run_suite "hooks/team/rules-inject"   "bash hooks/team/rules-inject.test.sh"
run_suite "lib/rules"                 "bash tests/lib/rules.test.sh"
run_suite "lib/workflow-config"       "bash tests/lib/workflow-config.test.sh"
run_suite "lib/model-tier"            "bash tests/lib/model-tier.test.sh"
run_suite "lib/graphify-preflight"    "bash tests/lib/graphify-preflight.test.sh"
run_suite "hooks/team/done-criteria"  "bash hooks/team/done-criteria.test.sh"
run_suite "hooks/team/session-end-learnings" "bash hooks/team/session-end-learnings.test.sh"
run_suite "lib/worktree-commit-check" "bash tests/lib/worktree-commit-check.test.sh"
run_suite "lib/ralph-remediation"    "bash lib/ralph-remediation.test.sh"
run_suite "lib/pause-snapshot"        "bash lib/pause-snapshot.test.sh"
run_suite "lib/regression-scan"       "bash tests/lib/regression-scan.test.sh"
run_suite "lib/feature-init"          "bash tests/lib/feature-init.test.sh"
run_suite "lib/model-overrides"       "bash tests/model-overrides.test.sh"
run_suite "lib/resolve-bin"           "bash tests/lib/resolve-bin.test.sh"
run_suite "lib/acceptance-lint"       "bash tests/lib/acceptance-lint.test.sh"
run_suite "lib/evidence"              "bash tests/lib/evidence.test.sh"
run_suite "lib/grounding-lint"        "bash tests/lib/grounding-lint.test.sh"
run_suite "lib/events"                "bash tests/lib/events.test.sh"
run_suite "lib/cycle-result"          "bash tests/lib/cycle-result.test.sh"
run_suite "lib/checkpoint-pr"         "bash tests/lib/checkpoint-pr.test.sh"
run_suite "lib/status"                "bash tests/lib/status.test.sh"
run_suite "lib/pr-comments"           "bash tests/lib/pr-comments.test.sh"
run_suite "lib/issue-intake"          "bash tests/lib/issue-intake.test.sh"
run_suite "lib/retro"                 "bash tests/lib/retro.test.sh"
run_suite "lib/run-digest"            "bash tests/lib/run-digest.test.sh"
run_suite "tests/all-tests-registered" "bash tests/all-tests-registered.test.sh"
run_suite "tests/ponytail-coverage"   "bash tests/ponytail-coverage.test.sh"
run_suite "tests/design-coverage"     "bash tests/design-coverage.test.sh"
run_suite "tests/dispatch-events-coverage" "bash tests/dispatch-events-coverage.test.sh"
run_suite "tests/execution-discipline-coverage" "bash tests/execution-discipline-coverage.test.sh"
run_suite "tests/contract-strings"    "bash tests/contract-strings.test.sh"
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

if [[ "$RUN_E2E" == "1" ]]; then
  run_suite "tests/e2e (LIVE)" "bash tests/e2e/run-e2e.sh"
fi

echo ""
echo "=== Summary ==="
echo "Suites passed: $TOTAL_PASS"
echo "Suites failed: $TOTAL_FAIL"
[[ "$TOTAL_FAIL" -gt 0 ]] && exit 1 || exit 0
