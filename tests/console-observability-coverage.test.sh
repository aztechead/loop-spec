#!/usr/bin/env bash
# Console-observability coverage.
#
# A streamed log is the ONLY window into an unattended run. That contract used to be
# prose in report-style.md asking the model to print boundary lines, which had no test
# and in practice only EXECUTE and DISCUSS honoured; every other phase, and every
# non-phase event, was invisible. lib/events.sh emits those lines now, so this suite
# pins the couplings that keep them reaching an operator:
#   - the emitter still writes a console line for every event, on stderr
#   - EXECUTE still announces which task it is on, out of how many
#   - DELIVER still heartbeats through its required-checks wait
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0
FAIL=0

expect() { # expect <label> <file> <regex>
  local label="$1" f="$2" rx="$3"
  if [[ ! -f "$f" ]]; then
    echo "FAIL: $f missing"; FAIL=$((FAIL+1)); return
  fi
  if grep -qE "$rx" "$f"; then
    echo "PASS: $label"; PASS=$((PASS+1))
  else
    echo "FAIL: $label -- $f no longer matches /$rx/"; FAIL=$((FAIL+1))
  fi
}

# The emitter itself.
expect "events.sh has a console emitter" lib/events.sh '_console_line\(\)'
expect "console lines go to stderr, not the machine stdout contract" \
  lib/events.sh "printf '\[%s\] %s\\\\n'.*>&2"
expect "console emitter is invoked for every event" lib/events.sh '^ *_console_line "\$event"'
expect "console output has an operator kill switch" lib/events.sh 'LOOP_SPEC_CONSOLE_EVENTS'
expect "console stream is selectable for hosts that grade stderr as errors" \
  lib/events.sh 'LOOP_SPEC_CONSOLE_STREAM'
# pr-delivery's stdout is a single JSON document parsed whole by its caller, not a
# prefix-selectable marker stream, so its heartbeat must never follow the stdout mode.
expect "delivery heartbeat is pinned to stderr, whatever the stream setting" \
  lib/pr-delivery.sh 'does NOT honour'
expect "task_start is a documented canonical event" lib/events.sh 'task_start *- an EXECUTE task began'
expect "task_end is a documented canonical event" lib/events.sh 'task_end *- an EXECUTE task finished'

# EXECUTE task progress: every rung a lead can drive must announce its position.
expect "subagent rung emits task_start" skills/shared/execute-subagent.md 'task_start --phase execute'
expect "subagent rung emits task_end" skills/shared/execute-subagent.md 'task_end --phase execute'
expect "subagent rung counts against the whole DAG, not the wave" \
  skills/shared/execute-subagent.md 'total.*DAG, not the current wave|not the current wave'
expect "inline rung emits task_start" skills/shared/execute-inline.md 'task_start --phase execute'
expect "inline rung emits task_end" skills/shared/execute-inline.md 'task_end --phase execute'

# DELIVER's required-checks wait can run 900s; it must not do so silently.
expect "pr-delivery heartbeats during the checks wait" \
  lib/pr-delivery.sh '\[DELIVER\] waiting on required checks'
expect "delivery heartbeat honours the same kill switch" \
  lib/pr-delivery.sh 'LOOP_SPEC_CONSOLE_EVENTS'

# report-style.md must describe the mechanism, not ask the model to do its job.
expect "report-style documents the emitter" skills/shared/report-style.md 'lib/events\.sh.*print'
expect "report-style records the stderr/stdout split" skills/shared/report-style.md 'stdout is unchanged|stderr'

# Behavioural end-to-end: a real emit produces a real line on stderr.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/console-coverage-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
printf '{"slug":"demo"}' > "$TMP/feature.json"
line="$(bash lib/events.sh emit "$TMP" task_start --phase execute \
  --data '{"index":2,"total":5,"id":"task-002","subject":"demo"}' 2>&1 >/dev/null)"
if [[ "$line" == "[EXECUTE] task 2/5 start - task-002: demo" ]]; then
  echo "PASS: end-to-end task line renders as documented"; PASS=$((PASS+1))
else
  echo "FAIL: end-to-end task line wrong -- got '$line'"; FAIL=$((FAIL+1))
fi

# Telemetry must never abort a run, whatever it is handed.
rc=0
bash lib/events.sh emit "$TMP" task_start --phase execute --data 'not-json' >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]]; then
  echo "PASS: malformed task data still exits 0"; PASS=$((PASS+1))
else
  echo "FAIL: malformed task data exited $rc -- observability must never abort"; FAIL=$((FAIL+1))
fi

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "PASS: console observability reaches the operator on every path"
