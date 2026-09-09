#!/usr/bin/env bash
# lib/ralph-remediation.sh <feature-dir>
#
# Remediation loop harness for HARD-GATE failures in skills/verify/SKILL.md.
#
# Reads pendingRemediationTasks[] from <feature-dir>/feature.json. If the task
# count exceeds LOOP_SPEC_RALPH_THRESHOLD (default 3) the script exits 0
# immediately; the caller routes to the full EXECUTE team. At or below
# threshold, runs a loop up to MAX_ITERATIONS (5), echoing the dispatch
# instruction for each task and checking for <promise>COMPLETE</promise> in
# feature.json updates after each iteration.
#
# Exit codes:
#   0  threshold exceeded (caller handles) OR all tasks completed
#   1  max iterations reached without all tasks completing
#   2  bad invocation (missing feature-dir or feature.json)
#
# Logs each iteration to ${TMPDIR:-/tmp}/ralph-remediation-<slug>.log
# No sleep between iterations (per SPEC).
# No emoji in log output.
set -euo pipefail

MAX_ITERATIONS=5
RALPH_THRESHOLD="${LOOP_SPEC_RALPH_THRESHOLD:-3}"
if [[ ! "$RALPH_THRESHOLD" =~ ^[1-9][0-9]*$ ]]; then
  echo "ralph-remediation: LOOP_SPEC_RALPH_THRESHOLD must be a positive integer" >&2
  exit 2
fi

usage() {
  echo "usage: ralph-remediation.sh <feature-dir>" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

FEATURE_DIR="$1"
FEATURE_JSON="$FEATURE_DIR/feature.json"
FEATURE_READ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-read.sh"

if [[ ! -f "$FEATURE_JSON" ]]; then
  echo "ralph-remediation: feature.json not found at $FEATURE_JSON" >&2
  exit 2
fi

# Reads go through the typed reader (orchestrator-port-plan.md, WP3).
read -r SLUG TASK_COUNT <<< "$(bash "$FEATURE_READ" "$FEATURE_DIR" -r --filter '"\(.slug // "unknown") \(.pendingRemediationTasks // [] | length)"')"

LOG_FILE="${TMPDIR:-/tmp}/ralph-remediation-${SLUG}.log"

log() {
  printf '%s\n' "$*" >> "$LOG_FILE"
}

log "ralph-remediation start slug=${SLUG} tasks=${TASK_COUNT} threshold=${RALPH_THRESHOLD} $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Empty task list: nothing to do
if [[ "$TASK_COUNT" -eq 0 ]]; then
  log "ralph-remediation no pending tasks, exiting 0"
  exit 0
fi

# Above threshold: caller handles via full EXECUTE team
if [[ "$TASK_COUNT" -gt "$RALPH_THRESHOLD" ]]; then
  log "ralph-remediation task count ${TASK_COUNT} exceeds threshold ${RALPH_THRESHOLD}, deferring to EXECUTE team"
  exit 0
fi

# At or below threshold: run remediation loop (max MAX_ITERATIONS iterations)
log "ralph-remediation starting loop max=${MAX_ITERATIONS} iterations for ${TASK_COUNT} task(s)"

for i in $(seq 1 $MAX_ITERATIONS); do
  log "ralph-remediation iteration ${i} of ${MAX_ITERATIONS}"

  # Read current tasks for this iteration (may have been updated by caller)
  TASKS_JSON=$(bash "$FEATURE_READ" "$FEATURE_DIR" pendingRemediationTasks --default "[]")

  CURRENT_COUNT=$(bash "$FEATURE_READ" "$FEATURE_DIR" -r --filter '"\(.slug // "unknown") \(.pendingRemediationTasks // [] | length)"')

  if echo "$UPDATES_TEXT" | grep -q "<promise>COMPLETE</promise>"; then
    log "ralph-remediation COMPLETE signal detected at iteration ${i}, exiting 0"
    exit 0
  fi

  log "ralph-remediation iteration ${i} complete, no COMPLETE signal yet"
done

log "ralph-remediation max iterations (${MAX_ITERATIONS}) reached without COMPLETE signal, exiting 1"
exit 1
