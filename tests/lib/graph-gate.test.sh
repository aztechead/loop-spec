#!/usr/bin/env bash
# Unit tests for lib/graph/gate.sh — the sole writer of currentGate/gateHistory.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/lib/graph/gate.sh"
WORK="${TMPDIR:-/tmp}/loop-spec-graph-gate.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/feature"
PASS=0; FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

feat() { jq -r "$1" "$WORK/feature/feature.json"; }

seed() {
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  bash "$ROOT/lib/feature-init.sh" skeleton --mode single \
    --slug gate-unit --now "$NOW" --style step --title "gate test" \
    --branch feat/gate-unit --base-sha deadbeef --base-branch main \
    --worktree "" --prepare "" --test "" --lint "" --typecheck "" \
    > "$WORK/feature/feature.json"
}

[[ -f "$SCRIPT" ]] || { echo "FAIL: missing $SCRIPT"; exit 1; }
seed

# --- the seeded gate carries every documented key ---------------------------
check "seed currentGate keys" "advocateName challengerName gate phase round startedAt" \
  "$(feat '.currentGate | keys | join(" ")')"

# --- open --------------------------------------------------------------------
bash "$SCRIPT" open --feature-dir "$WORK/feature" --phase plan --gate plan-critique \
  --challenger challenger-1 >/dev/null
check "open phase" "plan" "$(feat '.currentGate.phase')"
check "open gate" "plan-critique" "$(feat '.currentGate.gate')"
check "open round" "0" "$(feat '.currentGate.round')"
check "open challenger" "challenger-1" "$(feat '.currentGate.challengerName')"
check "open advocate stays null" "null" "$(feat '.currentGate.advocateName')"
check "open stamps startedAt" "0" \
  "$([[ "$(feat '.currentGate.startedAt')" =~ ^2[0-9]{3}- ]] && echo 0 || echo 1)"

# Opening a second gate over an open one is a caller bug, not a silent overwrite.
rc=0
bash "$SCRIPT" open --feature-dir "$WORK/feature" --phase discuss --gate spec-critique \
  --challenger challenger-1 >/dev/null 2>&1 || rc=$?
check "open over an open gate refused" "1" "$rc"
check "refused open left the gate alone" "plan" "$(feat '.currentGate.phase')"

# --- round -------------------------------------------------------------------
check "round prints the new round" "1" \
  "$(bash "$SCRIPT" round --feature-dir "$WORK/feature")"
check "round persisted" "1" "$(feat '.currentGate.round')"

# --- fail --------------------------------------------------------------------
bash "$SCRIPT" fail --feature-dir "$WORK/feature" --rounds 1 \
  --convergence single-critic --challenger-model opus \
  --findings '["tighten the disk minimum"]' >/dev/null
check "fail appended one entry" "1" "$(feat '.gateHistory | length')"
check "fail result" "fail" "$(feat '.gateHistory[0].result')"
check "fail attempt derived" "1" "$(feat '.gateHistory[0].attempt')"
check "fail carries phase" "plan" "$(feat '.gateHistory[0].phase')"
check "fail carries findings" "tighten the disk minimum" \
  "$(feat '.gateHistory[0].findingsAddressed[0]')"
check "fail keeps the gate open" "plan" "$(feat '.currentGate.phase')"
check "fail keeps the round" "1" "$(feat '.currentGate.round')"

# --- pass --------------------------------------------------------------------
bash "$SCRIPT" round --feature-dir "$WORK/feature" >/dev/null
bash "$SCRIPT" pass --feature-dir "$WORK/feature" --rounds 2 \
  --convergence delta-verified --challenger-model opus >/dev/null
check "pass appended a second entry" "2" "$(feat '.gateHistory | length')"
check "pass result" "pass" "$(feat '.gateHistory[1].result')"
check "pass attempt increments per phase+gate" "2" "$(feat '.gateHistory[1].attempt')"
check "pass findings empty" "0" "$(feat '.gateHistory[1].findingsAddressed | length')"

# The reset is an OBJECT, never null: graph/cycle.graph.json's plan.critique node
# declares currentGate in reads[], and lib/graph/state.sh assert-reads fails a null.
check "pass reset is an object" "object" "$(feat '.currentGate | type')"
check "pass reset phase" "null" "$(feat '.currentGate.phase')"
check "pass reset gate" "null" "$(feat '.currentGate.gate')"
check "pass reset round" "0" "$(feat '.currentGate.round')"
check "pass reset challenger" "null" "$(feat '.currentGate.challengerName')"
check "pass reset keeps every key" "advocateName challengerName gate phase round startedAt" \
  "$(feat '.currentGate | keys | join(" ")')"

# --- the transition the field run got wrong ---------------------------------
# Clearing a gate that is not open is refused, so the "cleared it too early"
# sequence cannot reach feature.json at all.
rc=0
bash "$SCRIPT" pass --feature-dir "$WORK/feature" --rounds 1 \
  --convergence single-critic --challenger-model opus >/dev/null 2>&1 || rc=$?
check "pass with no open gate refused" "1" "$rc"
check "refused pass appended nothing" "2" "$(feat '.gateHistory | length')"

rc=0
bash "$SCRIPT" fail --feature-dir "$WORK/feature" --rounds 1 \
  --convergence single-critic --challenger-model opus >/dev/null 2>&1 || rc=$?
check "fail with no open gate refused" "1" "$rc"

rc=0
bash "$SCRIPT" round --feature-dir "$WORK/feature" >/dev/null 2>&1 || rc=$?
check "round with no open gate refused" "1" "$rc"

# --- attempt numbering is per phase+gate, not global -------------------------
bash "$SCRIPT" open --feature-dir "$WORK/feature" --phase discuss --gate spec-critique \
  --challenger challenger-1 >/dev/null
bash "$SCRIPT" round --feature-dir "$WORK/feature" >/dev/null
bash "$SCRIPT" pass --feature-dir "$WORK/feature" --rounds 1 \
  --convergence single-critic --challenger-model sonnet >/dev/null
check "discuss gate starts its own attempt count" "1" "$(feat '.gateHistory[2].attempt')"
check "discuss entry carries its gate" "spec-critique" "$(feat '.gateHistory[2].gate')"

# --- show --------------------------------------------------------------------
check "show with no open gate" "gate=none" \
  "$(bash "$SCRIPT" show --feature-dir "$WORK/feature")"
bash "$SCRIPT" open --feature-dir "$WORK/feature" --phase plan --gate plan-critique \
  --challenger challenger-1 >/dev/null
check "show with an open gate" "gate=plan-critique phase=plan round=0" \
  "$(bash "$SCRIPT" show --feature-dir "$WORK/feature")"

# --- invocation errors -------------------------------------------------------
rc=0; bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
check "no subcommand is a usage error" "2" "$rc"
rc=0; bash "$SCRIPT" bogus --feature-dir "$WORK/feature" >/dev/null 2>&1 || rc=$?
check "unknown subcommand is a usage error" "2" "$rc"
rc=0; bash "$SCRIPT" open --feature-dir "$WORK/nope" --phase plan --gate g >/dev/null 2>&1 || rc=$?
check "missing feature.json fails" "1" "$rc"

# --- feature-write refuses the direct path ----------------------------------
# gate.sh is the sole writer; the prose-driven raw write is what put a null in
# currentGate in the field.
rc=0
bash "$ROOT/lib/feature-write.sh" set "$WORK/feature" currentGate 'null' >/dev/null 2>&1 || rc=$?
check "raw set of currentGate refused" "1" "$rc"
check "refused raw set changed nothing" "plan" "$(feat '.currentGate.phase')"
rc=0
bash "$ROOT/lib/feature-write.sh" append "$WORK/feature" gateHistory '{"result":"pass"}' >/dev/null 2>&1 || rc=$?
check "raw append to gateHistory refused" "1" "$rc"
rc=0
bash "$ROOT/lib/feature-write.sh" set "$WORK/feature" currentGate.round '9' >/dev/null 2>&1 || rc=$?
check "raw set of a currentGate subkey refused" "1" "$rc"
# Every other key still writes normally.
rc=0
bash "$ROOT/lib/feature-write.sh" set "$WORK/feature" currentPhase '"verify"' >/dev/null 2>&1 || rc=$?
check "unrelated key still writable" "0" "$rc"

# --- next: the delta-round probe ---------------------------------------------
# The ceiling is read from graph/critique.graph.json, never restated: the test reads
# the same edge so a graph edit moves both sides.
CEILING="$(jq -r '[.edges[] | select(.kind == "loop" and .from == "critique.adjudicate" and .to == "critique.challenge")][0].ceiling' "$ROOT/graph/critique.graph.json")"
check "critique graph declares a positive delta ceiling" "1" "$([[ "$CEILING" =~ ^[1-9][0-9]*$ ]] && echo 1 || echo 0)"

seed
rc=0; bash "$SCRIPT" next --feature-dir "$WORK/feature" >/dev/null 2>&1 || rc=$?
check "next with no open gate refused" "1" "$rc"

bash "$SCRIPT" open --feature-dir "$WORK/feature" --phase plan --gate plan-critique >/dev/null
bash "$SCRIPT" round --feature-dir "$WORK/feature" >/dev/null
bash "$SCRIPT" fail --feature-dir "$WORK/feature" --rounds 1 --convergence single-critic \
  --challenger-model opus --findings '["task-002 has no verify command"]' >/dev/null
check "next after the single-critic round reruns" \
  "ANSWER=rerun REASON=0 of $CEILING delta rounds spent" \
  "$(bash "$SCRIPT" next --feature-dir "$WORK/feature")"

# Walk delta rounds up to the ceiling; every round inside it reruns.
spent=0
while (( spent < CEILING - 1 )); do
  bash "$SCRIPT" round --feature-dir "$WORK/feature" >/dev/null
  bash "$SCRIPT" fail --feature-dir "$WORK/feature" --rounds 2 --convergence single-critic \
    --challenger-model opus --findings "[\"delta finding $spent\"]" >/dev/null
  spent=$((spent + 1))
done
check "next inside the ceiling reruns" "ANSWER=rerun" \
  "$(bash "$SCRIPT" next --feature-dir "$WORK/feature" | cut -d' ' -f1)"
bash "$SCRIPT" round --feature-dir "$WORK/feature" >/dev/null
bash "$SCRIPT" fail --feature-dir "$WORK/feature" --rounds 3 --convergence single-critic \
  --challenger-model opus --findings '["yet another new finding"]' >/dev/null
check "next at the ceiling closes with the graph cited" \
  "ANSWER=close REASON=ceiling: $CEILING of $CEILING delta rounds spent (graph/critique.graph.json)" \
  "$(bash "$SCRIPT" next --feature-dir "$WORK/feature")"

# One failed round per findings list, on a freshly opened plan gate.
open_with_fails() {
  local findings
  seed
  bash "$SCRIPT" open --feature-dir "$WORK/feature" --phase plan --gate plan-critique >/dev/null
  for findings in "$@"; do
    bash "$SCRIPT" round --feature-dir "$WORK/feature" >/dev/null
    bash "$SCRIPT" fail --feature-dir "$WORK/feature" --rounds 1 --convergence single-critic \
      --challenger-model opus --findings "$findings" >/dev/null
  done
}

# Deadlock: a raised ceiling still closes when one finding survives two delta rounds.
open_with_fails '["stale finding"]' '["stale finding","fresh one"]' '["stale finding"]'
check "raised ceiling closes on a finding that survived two delta rounds" \
  "ANSWER=close REASON=deadlock: finding survived two consecutive delta rounds: stale finding" \
  "$(LOOP_SPEC_CRITIQUE_ROUNDS=9 bash "$SCRIPT" next --feature-dir "$WORK/feature")"

# Two delta rounds with disjoint findings are progress, not a deadlock.
open_with_fails '["a"]' '["b"]' '["c"]'
check "raised ceiling reruns while every round's findings are new" \
  "ANSWER=rerun REASON=2 of 9 delta rounds spent" \
  "$(LOOP_SPEC_CRITIQUE_ROUNDS=9 bash "$SCRIPT" next --feature-dir "$WORK/feature")"

# The operator override: 0 restores unbounded retries, garbage is refused loudly.
check "LOOP_SPEC_CRITIQUE_ROUNDS=0 never closes" \
  "ANSWER=rerun REASON=LOOP_SPEC_CRITIQUE_ROUNDS=0 (unbounded by operator)" \
  "$(LOOP_SPEC_CRITIQUE_ROUNDS=0 bash "$SCRIPT" next --feature-dir "$WORK/feature")"
rc=0; LOOP_SPEC_CRITIQUE_ROUNDS=lots bash "$SCRIPT" next --feature-dir "$WORK/feature" >/dev/null 2>&1 || rc=$?
check "malformed LOOP_SPEC_CRITIQUE_ROUNDS is a configuration error" "2" "$rc"
check "next never writes" "3" "$(feat '.gateHistory | length')"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
