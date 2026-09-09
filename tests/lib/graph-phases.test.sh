#!/usr/bin/env bash
# Tests for lib/graph/phases.sh: the phase vocabulary is the graph's, and adding a phase
# to a graph is one edit every consumer of the vocabulary sees.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/lib/graph/phases.sh"
PASS=0; FAIL=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then echo "PASS: $name"; PASS=$((PASS+1))
  else echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL+1)); fi
}
WORK="$(mktemp -d "${TMPDIR:-/tmp}/graph-phases-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

check "list: the shipped graph's seven phases in order" "spec discuss plan execute verify iterate deliver" "$(bash "$LIB" list | paste -sd' ')"
check "regex: an alternation" "spec|discuss|plan|execute|verify|iterate|deliver" "$(bash "$LIB" regex)"
check "validate: a phase exits 0" "0" "$(bash "$LIB" validate verify >/dev/null 2>&1; echo $?)"
check "validate: a gate node is not a phase" "1" "$(bash "$LIB" validate verify.acceptance >/dev/null 2>&1; echo $?)"
check "validate: the message names the phases" "1" "$(bash "$LIB" validate nope 2>&1 | grep -c 'phase must be one of: spec | discuss')"
check "suffix: uppercased id" "DELIVER" "$(bash "$LIB" suffix deliver)"
check "bad invocation exits 2" "2" "$(bash "$LIB" bogus >/dev/null 2>&1; echo $?)"
check "unreadable graph exits 2" "2" "$(bash "$LIB" list --graph "$WORK/none.json" >/dev/null 2>&1; echo $?)"

# Adding a phase is one graph edit: every consumer reads the copy through LOOP_SPEC_GRAPH.
jq '.nodes += [{"id":"triage","label":"Triage the report","kind":"agent","reads":["slug"],"writes":["artifacts","currentPhase"],"effort":"system1","body":"skills/triage/SKILL.md"}]' \
  "$ROOT/graph/cycle.graph.json" > "$WORK/graph.json"
check "a graph copy with a new phase lists it" "1" "$(bash "$LIB" list --graph "$WORK/graph.json" | grep -cx triage)"
check "LOOP_SPEC_GRAPH selects the copy for every caller" "1" "$(LOOP_SPEC_GRAPH="$WORK/graph.json" bash "$LIB" list | grep -cx triage)"
check "feature-init validates the new phase from the copy" "0" \
  "$(LOOP_SPEC_GRAPH="$WORK/graph.json" bash "$ROOT/lib/feature-init.sh" phase-model triage >/dev/null 2>&1; echo $?)"
check "feature-init resolves LOOP_SPEC_PHASE_MODEL_TRIAGE for it" "sonnet" \
  "$(LOOP_SPEC_GRAPH="$WORK/graph.json" LOOP_SPEC_HARNESS=claude LOOP_SPEC_PHASE_MODEL_TRIAGE=sonnet bash "$ROOT/lib/feature-init.sh" phase-model triage 2>/dev/null)"
check "feature-init refuses it against the shipped graph" "1" \
  "$(bash "$ROOT/lib/feature-init.sh" phase-model triage >/dev/null 2>&1; echo $?)"
check "the hooks' alternation carries it" "1" \
  "$(LOOP_SPEC_GRAPH="$WORK/graph.json" bash "$LIB" regex | grep -c '|triage')"
check "the engine keeps no literal phase list (tests/lib/graph-run.test.sh proves the derived one)" "0" \
  "$(grep -c '"spec", "discuss", "plan"' "$ROOT/lib/graph/engine.py")"
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
