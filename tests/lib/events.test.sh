#!/usr/bin/env bash
# Tests for lib/events.sh
set -uo pipefail

LIB="$(cd "$(dirname "$0")/../.." && pwd)/lib/events.sh"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; ((FAIL++)) || true
  fi
}

WORK="${TMPDIR:-/tmp}/loop-spec-events.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/feat"

# Case A: emit creates events.jsonl and produces valid JSON
bash "$LIB" emit "$WORK/feat" phase_start >/dev/null 2>&1
check "A: events.jsonl created" "1" "$([[ -f "$WORK/feat/events.jsonl" ]] && echo 1 || echo 0)"
line1="$(cat "$WORK/feat/events.jsonl")"
check "A: line is valid JSON" "0" "$(echo "$line1" | jq . >/dev/null 2>&1; echo $?)"
check "A: event field correct" "phase_start" "$(echo "$line1" | jq -r '.event')"

# Case B: append — 2 emits produce 2 lines
bash "$LIB" emit "$WORK/feat" phase_end >/dev/null 2>&1
lc="$(wc -l < "$WORK/feat/events.jsonl" | tr -d ' ')"
check "B: two emits = two lines" "2" "$lc"

# Case C: --phase flag lands correctly
bash "$LIB" emit "$WORK/feat" phase_start --phase execute >/dev/null 2>&1
last="$(tail -1 "$WORK/feat/events.jsonl")"
check "C: phase field set" "execute" "$(echo "$last" | jq -r '.phase')"

# Case D: no --phase → phase is null
bash "$LIB" emit "$WORK/feat" completed >/dev/null 2>&1
last="$(tail -1 "$WORK/feat/events.jsonl")"
check "D: phase is null when omitted" "null" "$(echo "$last" | jq -r '.phase')"

# Case E: --data lands correctly
bash "$LIB" emit "$WORK/feat" phase_end --phase execute --data '{"next":"verify"}' >/dev/null 2>&1
last="$(tail -1 "$WORK/feat/events.jsonl")"
check "E: data.next field set" "verify" "$(echo "$last" | jq -r '.data.next')"

# Case F: invalid --data → data == {} and exit 0
ec=0
bash "$LIB" emit "$WORK/feat" gate_round --data 'not-json' >/dev/null 2>&1 || ec=$?
check "F: invalid --data exits 0" "0" "$ec"
last="$(tail -1 "$WORK/feat/events.jsonl")"
check "F: invalid --data writes data={}" "{}" "$(echo "$last" | jq -c '.data')"

# Case G: missing args → exit 0 with warning on stderr
ec=0
warn_out="$(bash "$LIB" emit 2>&1)" || ec=$?
check "G: missing args exits 0" "0" "$ec"
check "G: missing args prints warning" "1" "$([[ "$warn_out" == *"bad invocation"* ]] && echo 1 || echo 0)"

# Case H: missing args (no feature_dir) → exit 0
ec=0
bash "$LIB" emit >/dev/null 2>&1 || ec=$?
check "H: no args exits 0" "0" "$ec"

# Case I: slug read from feature.json when present
mkdir -p "$WORK/slug-feat"
jq -n '{"slug":"my-feature","schemaVersion":7}' > "$WORK/slug-feat/feature.json"
bash "$LIB" emit "$WORK/slug-feat" completed >/dev/null 2>&1
last="$(tail -1 "$WORK/slug-feat/events.jsonl")"
check "I: slug from feature.json" "my-feature" "$(echo "$last" | jq -r '.slug')"

# Case J: basename fallback when feature.json absent
mkdir -p "$WORK/fallback-dir"
bash "$LIB" emit "$WORK/fallback-dir" completed >/dev/null 2>&1
last="$(tail -1 "$WORK/fallback-dir/events.jsonl")"
check "J: slug fallback to basename" "fallback-dir" "$(echo "$last" | jq -r '.slug')"

# Case K: ts field is ISO-8601
last="$(tail -1 "$WORK/feat/events.jsonl")"
ts_ok="$(echo "$last" | jq -r '.ts' | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' && echo yes || echo no)"
check "K: ts is ISO-8601 UTC" "yes" "$ts_ok"

# Case L: wrong subcommand → exit 0 with warning
ec=0
bash "$LIB" bogus >/dev/null 2>&1 || ec=$?
check "L: unknown subcommand exits 0" "0" "$ec"

# Case M: phase markers are greppable JSON and phase_end pairs to phase_start
# without requiring the caller to retain an attempt id.
mkdir -p "$WORK/markers"
start_out="$(bash "$LIB" emit "$WORK/markers" phase_start --phase execute)"
check "M: start marker prefix" "1" "$([[ "$start_out" == LOOP_SPEC_PHASE_START\ * ]] && echo 1 || echo 0)"
start_marker="${start_out#LOOP_SPEC_PHASE_START }"
check "M: start marker is JSON" "0" "$(jq . <<<"$start_marker" >/dev/null 2>&1; echo $?)"
attempt_id="$(jq -r '.attemptId' <<<"$start_marker")"
check "M: start attempt id present" "1" "$([[ -n "$attempt_id" && "$attempt_id" != null ]] && echo 1 || echo 0)"
check "M: start timestamp present" "true" "$(jq -r '.timestamp | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' <<<"$start_marker")"
end_out="$(bash "$LIB" emit "$WORK/markers" phase_end --phase execute --data '{"next":"verify"}')"
check "M: end marker prefix" "1" "$([[ "$end_out" == LOOP_SPEC_PHASE_END\ * ]] && echo 1 || echo 0)"
end_marker="${end_out#LOOP_SPEC_PHASE_END }"
check "M: end uses matching attempt" "$attempt_id" "$(jq -r '.attemptId' <<<"$end_marker")"
check "M: end elapsed is numeric" "number" "$(jq -r '.elapsedSeconds | type' <<<"$end_marker")"
check "M: end verdict advanced" "advanced" "$(jq -r '.verdict' <<<"$end_marker")"
check "M: end next exposed" "verify" "$(jq -r '.next' <<<"$end_marker")"
last="$(tail -1 "$WORK/markers/events.jsonl")"
check "M: JSONL keeps legacy data.next" "verify" "$(jq -r '.data.next' <<<"$last")"
check "M: JSONL includes matching attempt" "$attempt_id" "$(jq -r '.attemptId' <<<"$last")"

# Case N: verdict derivation is fixed and deterministic.
bash "$LIB" emit "$WORK/markers" phase_start --phase iterate >/dev/null
rewind_out="$(bash "$LIB" emit "$WORK/markers" phase_end --phase iterate --data '{"next":"execute"}')"
check "N: rewind verdict" "rewind" "$(jq -r '.verdict' <<<"${rewind_out#LOOP_SPEC_PHASE_END }")"
bash "$LIB" emit "$WORK/markers" phase_start --phase deliver >/dev/null
blocked_out="$(bash "$LIB" emit "$WORK/markers" phase_end --phase deliver --data '{"next":"deliver"}')"
check "N: blocked verdict" "blocked" "$(jq -r '.verdict' <<<"${blocked_out#LOOP_SPEC_PHASE_END }")"
bash "$LIB" emit "$WORK/markers" phase_start --phase deliver >/dev/null
completed_out="$(bash "$LIB" emit "$WORK/markers" phase_end --phase deliver --data '{"next":"completed"}')"
check "N: completed verdict" "completed" "$(jq -r '.verdict' <<<"${completed_out#LOOP_SPEC_PHASE_END }")"

# Case O: generic events retain the original shape and print no phase marker.
generic_out="$(bash "$LIB" emit "$WORK/markers" gate_round --phase verify --data '{"round":2}')"
check "O: generic event has no stdout marker" "" "$generic_out"
last="$(tail -1 "$WORK/markers/events.jsonl")"
check "O: generic event keys unchanged" '["data","event","phase","slug","ts"]' \
  "$(jq -c 'keys | sort' <<<"$last")"

# Case P: every event prints ONE greppable operator line on stderr.
#
# This is the only window into a long unattended run. It used to be prose in
# report-style.md asking the model to print these, so in practice only EXECUTE and
# DISCUSS ever did, and non-phase events reached no console at all. It is a mechanism
# now, so it gets pinned like one.
mkdir -p "$WORK/console"
con() { bash "$LIB" emit "$WORK/console" "$@" 2>&1 >/dev/null; }

check "P: phase_start line" "[SPEC] start" "$(con phase_start --phase spec)"
check "P: gate_round line" "[DISCUSS] gate critique round 2 - escalated" \
  "$(con gate_round --phase discuss --data '{"gate":"critique","round":2,"result":"escalated"}')"
check "P: dispatch line" "[PLAN] dispatch planner [opus, team]" \
  "$(con dispatch --phase plan --data '{"role":"planner","model":"opus","rung":"team"}')"
check "P: verify_failure line" "[VERIFY] FAILURE: code-review" \
  "$(con verify_failure --phase verify --data '{"class":"code-review"}')"
check "P: iterate_verdict line" "[ITERATE] verdict: converged" \
  "$(con iterate_verdict --phase iterate --data '{"verdict":"converged"}')"
check "P: checkpoint_pr line" "[DELIVER] checkpoint PR https://x/pr/9" \
  "$(con checkpoint_pr --phase deliver --data '{"url":"https://x/pr/9"}')"
check "P: phaseless event still tagged" "[LOOP-SPEC] completed" "$(con completed)"

# Case Q: EXECUTE task progress. The longest phase used to report only "[EXECUTE]
# start", so a streamed log could not distinguish task 1 of 6 from task 5 of 6, nor
# progress from a stall.
check "Q: task_start reports position out of total" \
  "[EXECUTE] task 2/5 start - task-002: Add airline column" \
  "$(con task_start --phase execute --data '{"index":2,"total":5,"id":"task-002","subject":"Add airline column"}')"
check "Q: task_end reports the outcome" \
  "[EXECUTE] task 2/5 done - task-002 [merged]" \
  "$(con task_end --phase execute --data '{"index":2,"total":5,"id":"task-002","result":"merged"}')"
check "Q: a failed task is visible as such" \
  "[EXECUTE] task 3/5 done - task-003 [failed]" \
  "$(con task_end --phase execute --data '{"index":3,"total":5,"id":"task-003","result":"failed"}')"
check "Q: counts alone are enough" "[EXECUTE] task 1/4 start" \
  "$(con task_start --phase execute --data '{"index":1,"total":4}')"
check "Q: missing counts still produce a usable line" "[EXECUTE] task start - task-009" \
  "$(con task_start --phase execute --data '{"id":"task-009"}')"
check "Q: task events stay off stdout" "" \
  "$(bash "$LIB" emit "$WORK/console" task_start --phase execute --data '{"index":1,"total":2}' 2>/dev/null)"
check "Q: task events are recorded in the ledger" "task_start" \
  "$(bash "$LIB" emit "$WORK/console" task_start --phase execute --data '{"index":1,"total":2}' >/dev/null 2>&1
     tail -1 "$WORK/console/events.jsonl" | jq -r '.event')"

# phase_end carries the elapsed time and verdict the operator needs.
bash "$LIB" emit "$WORK/console" phase_start --phase execute >/dev/null 2>&1
end_line="$(con phase_end --phase execute --data '{"next":"verify"}')"
check "P: phase_end reports elapsed + verdict + next" "1" \
  "$([[ "$end_line" == "[EXECUTE] done ("*"s) - advanced -> verify" ]] && echo 1 || echo 0)"

# Exactly one line per event -- a noisy console is one nobody reads.
check "P: one line per event" "1" \
  "$(con dispatch --phase plan --data '{"role":"x"}' | wc -l | tr -d ' ')"

# The machine contract on stdout must be untouched by any of this.
stdout_only="$(bash "$LIB" emit "$WORK/console" phase_start --phase verify 2>/dev/null)"
check "P: stdout still starts with the marker" "1" \
  "$([[ "$stdout_only" == LOOP_SPEC_PHASE_START\ * ]] && echo 1 || echo 0)"
check "P: stdout marker is still parseable JSON" "0" \
  "$(jq . <<<"${stdout_only#LOOP_SPEC_PHASE_START }" >/dev/null 2>&1; echo $?)"
check "P: generic event still prints no stdout" "" \
  "$(bash "$LIB" emit "$WORK/console" gate_round --phase verify --data '{"round":1}' 2>/dev/null)"

# Stream selection. Cloud Run assigns stderr ERROR severity, so an operator may want
# routine progress on stdout instead. That is contract-affecting, hence opt-in.
check "P: stdout mode moves the console line to stdout" "[SPEC] start" \
  "$(LOOP_SPEC_CONSOLE_STREAM=stdout bash "$LIB" emit "$WORK/console" phase_start --phase spec 2>/dev/null | tail -1)"
check "P: stdout mode leaves nothing on stderr" "" \
  "$(LOOP_SPEC_CONSOLE_STREAM=stdout bash "$LIB" emit "$WORK/console" phase_start --phase spec 2>&1 >/dev/null)"
# In stdout mode the marker must still come FIRST and stay prefix-selectable, which is
# how a robust consumer reads it. A naive whole-stdout jq is what breaks here.
stdout_mode="$(LOOP_SPEC_CONSOLE_STREAM=stdout bash "$LIB" emit "$WORK/console" phase_start --phase plan 2>/dev/null)"
check "P: stdout mode keeps the marker on the first line" "1" \
  "$([[ "$(head -1 <<<"$stdout_mode")" == LOOP_SPEC_PHASE_START\ * ]] && echo 1 || echo 0)"
check "P: stdout mode marker stays parseable when prefix-selected" "plan" \
  "$(grep '^LOOP_SPEC_PHASE_START ' <<<"$stdout_mode" | sed 's/^LOOP_SPEC_PHASE_START //' | jq -r '.phase')"
check "P: an unknown stream value falls back to stderr" "[SPEC] start" \
  "$(LOOP_SPEC_CONSOLE_STREAM=carrier-pigeon bash "$LIB" emit "$WORK/console" phase_start --phase spec 2>&1 >/dev/null)"
check "P: default is still stderr" "" \
  "$(env -u CLOUD_RUN_JOB -u K_SERVICE bash "$LIB" emit "$WORK/console" gate_round --phase spec --data '{"round":1}' 2>/dev/null)"

# Cloud Run stamps CLOUD_RUN_JOB (jobs) / K_SERVICE (services) into every container.
# It grades stderr as ERROR severity, so on the platform's own evidence the lines move
# to stdout -- a probe, not a judgment. The operator override still outranks it.
check "P: Cloud Run job stamp routes console to stdout" "[SPEC] start" \
  "$(CLOUD_RUN_JOB=coder bash "$LIB" emit "$WORK/console" phase_start --phase spec 2>/dev/null | tail -1)"
check "P: Cloud Run service stamp routes console to stdout" "[SPEC] start" \
  "$(K_SERVICE=api bash "$LIB" emit "$WORK/console" phase_start --phase spec 2>/dev/null | tail -1)"
check "P: explicit stderr override outranks the Cloud Run stamp" "[SPEC] start" \
  "$(CLOUD_RUN_JOB=coder LOOP_SPEC_CONSOLE_STREAM=stderr bash "$LIB" emit "$WORK/console" phase_start --phase spec 2>&1 >/dev/null)"

# Kill switch, per the repo's probe contract: an operator override outranks it.
check "P: LOOP_SPEC_CONSOLE_EVENTS=0 silences the console" "" \
  "$(LOOP_SPEC_CONSOLE_EVENTS=0 bash "$LIB" emit "$WORK/console" phase_start --phase spec 2>&1 >/dev/null)"
check "P: kill switch does not affect the JSONL ledger" "1" \
  "$(LOOP_SPEC_CONSOLE_EVENTS=0 bash "$LIB" emit "$WORK/console" gate_round --phase spec >/dev/null 2>&1
     tail -1 "$WORK/console/events.jsonl" | jq -r 'if .event == "gate_round" then 1 else 0 end')"

# Malformed data must not break the line or the run -- telemetry never aborts.
check "P: missing data fields degrade gracefully" "[VERIFY] FAILURE: unclassified" \
  "$(con verify_failure --phase verify --data '{}')"
check "P: malformed data does not break the line" "[PLAN] dispatch agent" \
  "$(con dispatch --phase plan --data 'not-json' 2>/dev/null | tail -1)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
