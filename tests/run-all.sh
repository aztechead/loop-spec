#!/usr/bin/env bash
# Run every non-CC test suite (validators + hook + lib units + workflow syntax).
#
# Usage: bash tests/run-all.sh [--e2e]
#   --e2e  additionally run tests/e2e/run-e2e.sh (LIVE: real claude -p cycle,
#          costs tokens and minutes; the default suite stays offline)
#
# Offline suites run concurrently. RUN_ALL_JOBS overrides the default worker count;
# RUN_ALL_VERBOSE=1 prints successful suite logs instead of only their answer lines.
# tests/run-unit.sh selects only the suites coupled to the current worktree diff.
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
TOTAL_SKIP=0
SUITE_SEQUENCE=0
SUITE_NAMES=()
SUITE_PIDS=()
SUITE_LOGS=()
SUITE_RESULTS=()
SUITE_REPORTED=()
SUITE_BATCH=0

RUN_ALL_PROFILE="${RUN_ALL_PROFILE:-full}"
case "$RUN_ALL_PROFILE" in
  full|selected) ;;
  *) echo "run-all.sh: RUN_ALL_PROFILE must be full or selected" >&2; exit 2 ;;
esac
RUN_ALL_ONLY_PATHS="${RUN_ALL_ONLY_PATHS:-}"
if [[ "$RUN_ALL_PROFILE" == "selected" && -z "$RUN_ALL_ONLY_PATHS" ]]; then
  echo "run-all.sh: selected profile requires RUN_ALL_ONLY_PATHS" >&2
  exit 2
fi

RUN_ALL_VERBOSE="${RUN_ALL_VERBOSE:-0}"
case "$RUN_ALL_VERBOSE" in
  0|1) ;;
  *) echo "run-all.sh: RUN_ALL_VERBOSE must be 0 or 1" >&2; exit 2 ;;
esac

default_jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
[[ "$default_jobs" =~ ^[1-9][0-9]*$ ]] || default_jobs=4
(( default_jobs > 8 )) && default_jobs=8
RUN_ALL_JOBS="${RUN_ALL_JOBS:-$default_jobs}"
[[ "$RUN_ALL_JOBS" =~ ^[1-9][0-9]*$ ]] \
  || { echo "run-all.sh: RUN_ALL_JOBS must be a positive integer" >&2; exit 2; }
(( RUN_ALL_JOBS <= 32 )) \
  || { echo "run-all.sh: RUN_ALL_JOBS must be 32 or less" >&2; exit 2; }

RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/loop-spec-run-all-XXXXXX")"
cleanup() {
  local pid
  if (( SUITE_BATCH > 0 )); then
    for pid in "${SUITE_PIDS[@]}"; do
      kill "$pid" 2>/dev/null || true
    done
  fi
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

wait_for_slot() {
  local running
  while :; do
    report_finished_suites
    running="$(jobs -pr | wc -l | tr -d ' ')"
    (( running < RUN_ALL_JOBS )) && return
    sleep 0.05
  done
}

run_suite() {
  local name="$1"
  local cmd="$2"
  local tier="${3:-unit}"
  local index log result selected_path selected=false
  if [[ "$RUN_ALL_PROFILE" == "selected" ]]; then
    while IFS= read -r selected_path; do
      if [[ -n "$selected_path" && " $cmd " == *" $selected_path"* ]]; then
        selected=true
        break
      fi
    done <<< "$RUN_ALL_ONLY_PATHS"
  fi
  if [[ "$RUN_ALL_PROFILE" == "selected" && "$selected" != "true" ]]; then
    TOTAL_SKIP=$((TOTAL_SKIP + 1))
    return
  fi
  if [[ "$RUN_ALL_PROFILE" == "selected" && "$tier" == "integration" ]]; then
    TOTAL_SKIP=$((TOTAL_SKIP + 1))
    return
  fi

  wait_for_slot
  index="$SUITE_BATCH"
  log="$RUN_DIR/suite-$SUITE_SEQUENCE.log"
  result="$RUN_DIR/suite-$SUITE_SEQUENCE.result"
  SUITE_NAMES[$index]="$name"
  SUITE_LOGS[$index]="$log"
  SUITE_RESULTS[$index]="$result"
  SUITE_REPORTED[$index]=0
  SUITE_SEQUENCE=$((SUITE_SEQUENCE + 1))
  SUITE_BATCH=$((SUITE_BATCH + 1))

  (
    started="$SECONDS"
    if bash -c "$cmd" >"$log" 2>&1; then
      rc=0
    else
      rc=$?
    fi
    printf '%s %s\n' "$rc" "$((SECONDS - started))" >"$result.tmp"
    mv "$result.tmp" "$result"
  ) &
  SUITE_PIDS[$index]=$!
}

report_finished_suites() {
  local index rc duration
  for ((index = 0; index < SUITE_BATCH; index++)); do
    [[ "${SUITE_REPORTED[$index]}" == "0" ]] || continue
    [[ -r "${SUITE_RESULTS[$index]}" ]] || continue
    rc=1
    duration="unknown"
    read -r rc duration < "${SUITE_RESULTS[$index]}"
    SUITE_REPORTED[$index]=1
    if [[ "$rc" == "0" ]]; then
      TOTAL_PASS=$((TOTAL_PASS + 1))
      if [[ "$RUN_ALL_VERBOSE" == "1" ]]; then
        echo ""
        echo "=== ${SUITE_NAMES[$index]} ==="
        cat "${SUITE_LOGS[$index]}"
      fi
      echo "PASS: ${SUITE_NAMES[$index]} (${duration}s)"
    else
      TOTAL_FAIL=$((TOTAL_FAIL + 1))
      echo ""
      echo "=== ${SUITE_NAMES[$index]} ==="
      cat "${SUITE_LOGS[$index]}" 2>/dev/null || true
      echo "SUITE FAILED: ${SUITE_NAMES[$index]} (${duration}s)"
    fi
  done
}

flush_suites() {
  local pid
  (( SUITE_BATCH > 0 )) || return 0
  for pid in "${SUITE_PIDS[@]}"; do
    wait "$pid" || true
  done
  report_finished_suites
  SUITE_NAMES=()
  SUITE_PIDS=()
  SUITE_LOGS=()
  SUITE_RESULTS=()
  SUITE_REPORTED=()
  SUITE_BATCH=0
}

run_suite_serial() {
  flush_suites
  run_suite "$@"
  flush_suites
}

echo "run-all: profile=$RUN_ALL_PROFILE jobs=$RUN_ALL_JOBS"

run_suite "validate-agents"           "bash tests/validate-agents.sh"
run_suite "validate-manifest"         "bash tests/validate-manifest.test.sh"
run_suite "adk-harness-coverage"      "bash tests/adk-harness-coverage.test.sh"
run_suite "adk-extension"             "bash tests/adk-extension.test.sh"
run_suite "session-start-hook-parity" "bash tests/session-start-hook-parity.test.sh"
run_suite "cycle-worktree-policy"     "bash tests/cycle-worktree-policy.test.sh"
run_suite "graph-conformance"         "bash tests/graph-conformance.test.sh"
run_suite "graph-docs-coverage"       "bash tests/graph-docs-coverage.test.sh"
run_suite "lib/graph-schema"          "bash tests/lib/graph-schema.test.sh"
run_suite "lib/graph-validate"        "bash tests/lib/graph-validate.test.sh"
run_suite "lib/graph-probes"      "bash tests/lib/graph-probes.test.sh"
run_suite "lib/graph-state"           "bash tests/lib/graph-state.test.sh"
run_suite "lib/graph-checkpoint"      "bash tests/lib/graph-checkpoint.test.sh"
run_suite "lib/graph-trace"           "bash tests/lib/graph-trace.test.sh"
run_suite "lib/graph-run"             "bash tests/lib/graph-run.test.sh" integration
run_suite "lib/graph-gate-dispatch"    "bash tests/lib/graph-gate-dispatch.test.sh"
run_suite "lib/effort-probe"          "bash tests/lib/effort-probe.test.sh"
run_suite "lib/conflict-monitor"      "bash tests/lib/conflict-monitor.test.sh"
run_suite "lib/graph-port-contract"   "bash tests/lib/graph-port-contract.test.sh" integration
run_suite "e2e/graph-handoff"        "bash tests/e2e/graph-handoff.test.sh" integration
run_suite "e2e/foreign-claimant-app" "bash tests/e2e/foreign-claimant-app.test.sh" integration
run_suite "opencode-plugin"           "bash tests/opencode-plugin.test.sh"
run_suite "opencode-harness-coverage" "bash tests/opencode-harness-coverage.test.sh"
run_suite "lib/opencode-install"      "bash tests/lib/opencode-install.test.sh" integration
run_suite "validate-agents-frontmatter" "bash tests/validate-agents.test.sh"
run_suite "restrict-agent-paths"      "bash hooks/restrict-agent-paths.test.sh"
run_suite "hooks/team/no-worktrees-guard" "bash hooks/team/no-worktrees-guard.test.sh"
run_suite "hooks/team/phase-handoff-guard" "bash hooks/team/phase-handoff-guard.test.sh"
run_suite "lib/feature-write"         "bash tests/lib/feature-write.test.sh"
run_suite "lib/team-ops"              "bash tests/lib/team-ops.test.sh"
run_suite "lib/teams-capability"      "bash tests/lib/teams-capability.test.sh"
run_suite "lib/bounded-run"           "bash tests/lib/bounded-run.test.sh" integration
run_suite "lib/harness"               "bash tests/lib/harness.test.sh"
run_suite "lib/plugin-version"        "bash tests/lib/plugin-version.test.sh"
run_suite "lib/bump-version"          "bash tests/lib/bump-version.test.sh"
run_suite "lib/execute-rung"          "bash tests/lib/execute-rung.test.sh"
run_suite "lib/security-signal"       "bash tests/lib/security-signal.test.sh"
run_suite "lib/cycle-profile"         "bash tests/lib/cycle-profile.test.sh"
run_suite "lib/surface"               "bash tests/lib/surface.test.sh"
run_suite "lib/house-style"           "bash tests/lib/house-style.test.sh"
run_suite "lib/comment-tells"         "bash tests/lib/comment-tells.test.sh"
run_suite "lib/duplication-scan"      "bash tests/lib/duplication-scan.test.sh"
run_suite "lib/indirection-scan"      "bash tests/lib/indirection-scan.test.sh"
run_suite "lib/failure-tells"         "bash tests/lib/failure-tells.test.sh"
run_suite "lib/doc-tells"             "bash tests/lib/doc-tells.test.sh"
run_suite "lib/plain-language-lint"   "bash tests/lib/plain-language-lint.test.sh"
run_suite "lib/review-trail"          "bash tests/lib/review-trail.test.sh"
run_suite "lib/verification-gap-scan" "bash tests/lib/verification-gap-scan.test.sh"
run_suite "lib/extension-points"      "bash tests/lib/extension-points.test.sh"
run_suite "lib/map-audit"             "bash tests/lib/map-audit.test.sh"
run_suite "lib/map-trust"             "bash tests/lib/map-trust.test.sh"
run_suite "lib/map-index-prune"       "bash tests/lib/map-index-prune.test.sh"
run_suite "lib/git-ops"               "bash tests/lib/git-ops.test.sh"
run_suite "lib/worktree-base"         "bash tests/lib/worktree-base.test.sh"
run_suite "lib/runtime-ignore"         "bash tests/lib/runtime-ignore.test.sh"
run_suite "lib/owned-gitignore"        "bash tests/lib/owned-gitignore.test.sh"
run_suite "lib/runtime-preflight"      "bash tests/lib/runtime-preflight.test.sh"
run_suite "lib/gsd-ingest"            "bash tests/lib/gsd-ingest.test.sh"
run_suite "hooks/team/teammate-idle"  "bash hooks/team/teammate-idle.test.sh"
run_suite "hooks/team/task-created"   "bash hooks/team/task-created.test.sh"
run_suite "hooks/team/task-completed" "bash hooks/team/task-completed.test.sh"
run_suite "hooks/team/post-task-complete-revalidate" "bash hooks/team/post-task-complete-revalidate.test.sh"
run_suite "hooks/team/stop-revalidate-user-gates" "bash hooks/team/stop-revalidate-user-gates.test.sh"
run_suite "hooks/team/pre-task-blockedby-enforce" "bash hooks/team/pre-task-blockedby-enforce.test.sh"
run_suite "hooks/team/stop-deflection-guard" "bash hooks/team/stop-deflection-guard.test.sh"
run_suite "hooks/team/adhoc-verify-guard" "bash hooks/team/adhoc-verify-guard.test.sh"
run_suite "hooks/team/deferral-guard"     "bash hooks/team/deferral-guard.test.sh"
run_suite "hooks/team/route-terminal-guard" "bash hooks/team/route-terminal-guard.test.sh"
run_suite "lib/deferral-lint"             "bash tests/lib/deferral-lint.test.sh"
run_suite "lib/validate-task-metadata" "bash tests/lib/validate-task-metadata.test.sh"
run_suite "lib/decision-coverage"     "bash tests/lib/decision-coverage.test.sh"
run_suite "lib/criteria-coverage"     "bash tests/lib/criteria-coverage.test.sh"
run_suite "lib/skill-references"      "bash tests/lib/skill-references.test.sh"
run_suite "lib/harness-call-shapes"   "bash tests/lib/harness-call-shapes.test.sh"
run_suite "lib/test-tamper-scan"      "bash tests/lib/test-tamper-scan.test.sh"
run_suite "lib/placeholder-scan"      "bash tests/lib/placeholder-scan.test.sh"
run_suite "lib/converged-floor"       "bash tests/lib/converged-floor.test.sh"
run_suite "lib/backlog"               "bash tests/lib/backlog.test.sh"
run_suite "lib/autonomous-chain"      "bash tests/lib/autonomous-chain.test.sh"
run_suite "lib/parse-invocation"      "bash tests/lib/parse-invocation.test.sh"
run_suite "lib/decisions"             "bash tests/lib/decisions.test.sh"
run_suite "lib/debug-init"            "bash tests/lib/debug-init.test.sh"
run_suite "lib/greenfield-bootstrap"  "bash tests/lib/greenfield-bootstrap.test.sh"
run_suite "lib/cycle-preflight"       "bash tests/lib/cycle-preflight.test.sh" integration
run_suite "lib/plan-adherence"        "bash tests/lib/plan-adherence.test.sh"
run_suite "lib/detect-test-cmd"       "bash tests/lib/detect-test-cmd.test.sh"
run_suite "lib/workspace"          "bash tests/lib/workspace.test.sh"
run_suite "lib/fragility-scan"     "bash tests/lib/fragility-scan.test.sh"
run_suite "lib/quality-loop-state" "bash tests/lib/quality-loop-state.test.sh"
run_suite "hooks/team/strategy-rotation" "bash hooks/team/strategy-rotation.test.sh"
run_suite "hooks/team/discipline-inject" "bash hooks/team/discipline-inject.test.sh"
run_suite "hooks/team/grill-inject"   "bash hooks/team/grill-inject.test.sh"
run_suite "hooks/team/simplicity-inject" "bash hooks/team/simplicity-inject.test.sh"
run_suite "hooks/team/human-code-inject" "bash hooks/team/human-code-inject.test.sh"
run_suite "hooks/team/rules-inject"   "bash hooks/team/rules-inject.test.sh"
run_suite "hooks/team/micro-inject"   "bash hooks/team/micro-inject.test.sh"
run_suite "lib/adhoc-ledger"          "bash tests/lib/adhoc-ledger.test.sh"
run_suite "lib/rules"                 "bash tests/lib/rules.test.sh"
run_suite "lib/workflow-config"       "bash tests/lib/workflow-config.test.sh"
run_suite "lib/model-tier"            "bash tests/lib/model-tier.test.sh"
run_suite "lib/task-route"            "bash tests/lib/task-route.test.sh"
run_suite "lib/map-refresh"           "bash tests/lib/map-refresh.test.sh"
run_suite "lib/map-policy"            "bash tests/lib/map-policy.test.sh"
run_suite "lib/state-commit-policy"   "bash tests/lib/state-commit-policy.test.sh"
run_suite "hooks/team/done-criteria"  "bash hooks/team/done-criteria.test.sh"
run_suite "hooks/team/session-end-learnings" "bash hooks/team/session-end-learnings.test.sh"
run_suite "lib/worktree-commit-check" "bash tests/lib/worktree-commit-check.test.sh"
run_suite "lib/integrate-task"        "bash tests/lib/integrate-task.test.sh"
run_suite "lib/ralph-remediation"    "bash lib/ralph-remediation.test.sh"
run_suite "lib/pause-snapshot"        "bash lib/pause-snapshot.test.sh"
run_suite "lib/regression-scan"       "bash tests/lib/regression-scan.test.sh"
run_suite "lib/feature-init"          "bash tests/lib/feature-init.test.sh"
run_suite "lib/run-with-watchdog"     "bash tests/lib/run-with-watchdog.test.sh" integration
run_suite "lib/prepare-environment"   "bash tests/lib/prepare-environment.test.sh" integration
run_suite "lib/project-commands"      "bash tests/lib/project-commands.test.sh"
run_suite "lib/verification-baseline" "bash tests/lib/verification-baseline.test.sh" integration
run_suite "lib/feature-validation"    "bash tests/lib/feature-validation.test.sh"
run_suite "lib/model-overrides"       "bash tests/model-overrides.test.sh"
run_suite "lib/resolve-bin"           "bash tests/lib/resolve-bin.test.sh"
run_suite "lib/acceptance-lint"       "bash tests/lib/acceptance-lint.test.sh"
run_suite "lib/artifact-lint"         "bash tests/lib/artifact-lint.test.sh"
run_suite "lib/artifact-sink"         "bash tests/lib/artifact-sink.test.sh"
run_suite "lib/evidence"              "bash tests/lib/evidence.test.sh"
run_suite "lib/grounding-lint"        "bash tests/lib/grounding-lint.test.sh"
run_suite "lib/verification-grounding-lint" "bash tests/lib/verification-grounding-lint.test.sh"
run_suite "lib/events"                "bash tests/lib/events.test.sh"
run_suite "lib/cycle-result"          "bash tests/lib/cycle-result.test.sh"
run_suite "lib/checkpoint-pr"         "bash tests/lib/checkpoint-pr.test.sh"
run_suite "lib/pr-delivery"           "bash tests/lib/pr-delivery.test.sh" integration
run_suite "lib/deliver"               "bash tests/lib/deliver.test.sh" integration
run_suite "lib/status"                "bash tests/lib/status.test.sh"
run_suite "lib/pr-comments"           "bash tests/lib/pr-comments.test.sh"
run_suite "lib/pr-feedback"           "bash tests/lib/pr-feedback.test.sh"
run_suite "lib/pr-body"               "bash tests/lib/pr-body.test.sh"
run_suite "lib/revise-branch"         "bash tests/lib/revise-branch.test.sh"
run_suite "lib/revise-state"          "bash tests/lib/revise-state.test.sh"
run_suite "lib/issue-intake"          "bash tests/lib/issue-intake.test.sh"
run_suite "lib/retro"                 "bash tests/lib/retro.test.sh"
run_suite "lib/run-digest"            "bash tests/lib/run-digest.test.sh" integration
run_suite "lib/sentinel-sources"      "bash tests/lib/sentinel-sources.test.sh"
run_suite "lib/sentinel-triage"       "bash tests/lib/sentinel-triage.test.sh"
run_suite "lib/sentinel-run"          "bash tests/lib/sentinel-run.test.sh"
run_suite "lib/watch"                 "bash tests/lib/watch.test.sh"
run_suite "lib/trust"                 "bash tests/lib/trust.test.sh"
run_suite "lib/tuning"                "bash tests/lib/tuning.test.sh"
run_suite "lib/verify-live"           "bash tests/lib/verify-live.test.sh" integration
run_suite "tests/all-tests-registered" "bash tests/all-tests-registered.test.sh"
run_suite "tests/run-all"             "bash tests/run-all.test.sh"
run_suite "tests/ponytail-coverage"   "bash tests/ponytail-coverage.test.sh"
run_suite "tests/design-coverage"     "bash tests/design-coverage.test.sh"
run_suite "tests/human-code-coverage" "bash tests/human-code-coverage.test.sh"
run_suite "tests/human-docs-coverage" "bash tests/human-docs-coverage.test.sh"
run_suite "tests/plain-language-coverage" "bash tests/plain-language-coverage.test.sh"
run_suite "tests/bmad-import-coverage" "bash tests/bmad-import-coverage.test.sh"
run_suite "tests/pr-feedback-coverage" "bash tests/pr-feedback-coverage.test.sh"
run_suite "tests/revise-safety-coverage" "bash tests/revise-safety-coverage.test.sh"
run_suite "tests/terminal-result-coverage" "bash tests/terminal-result-coverage.test.sh"
run_suite "tests/autonomous-routing-coverage" "bash tests/autonomous-routing-coverage.test.sh"
run_suite "tests/dispatch-events-coverage" "bash tests/dispatch-events-coverage.test.sh"
run_suite "tests/console-observability-coverage" "bash tests/console-observability-coverage.test.sh"
run_suite "tests/execution-discipline-coverage" "bash tests/execution-discipline-coverage.test.sh"
run_suite "tests/execution-validation-coverage" "bash tests/execution-validation-coverage.test.sh"
run_suite "tests/verification-grounding-coverage" "bash tests/verification-grounding-coverage.test.sh"
run_suite "tests/configuration-coverage" "bash tests/configuration-coverage.test.sh"
run_suite "tests/contract-strings"    "bash tests/contract-strings.test.sh"
run_suite "tests/delivery-phase-coverage" "bash tests/delivery-phase-coverage.test.sh"
run_suite "tests/prepare-resolution-coverage" "bash tests/prepare-resolution-coverage.test.sh"
run_suite "workflows/acceptance-verify" "bash tests/workflows/acceptance-verify.test.sh"
run_suite "lib/workflow-availability" "bash tests/lib/workflow-availability.test.sh"
run_suite "lib/dag-width"             "bash tests/lib/dag-width.test.sh"
run_suite "lib/task-progress"         "bash tests/lib/task-progress.test.sh"
run_suite "lib/plan-to-loop"          "bash tests/lib/plan-to-loop.test.sh"
run_suite "skills/loop-runner"        "bash skills/loop-runner/tests/run_tests.sh" integration

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

flush_suites

if [[ "$RUN_E2E" == "1" ]]; then
  run_suite_serial "tests/e2e (LIVE)" "bash tests/e2e/run-e2e.sh" integration
  run_suite_serial "tests/e2e sentinel (LIVE)" "bash tests/e2e/run-e2e-sentinel.sh" integration
fi

echo ""
echo "=== Summary ==="
echo "Suites passed: $TOTAL_PASS"
echo "Suites failed: $TOTAL_FAIL"
echo "Suites skipped: $TOTAL_SKIP"
[[ "$TOTAL_FAIL" -gt 0 ]] && exit 1 || exit 0
