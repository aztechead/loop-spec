#!/usr/bin/env bash
# The phase vocabulary is the graph's (lib/graph/phases.sh). Three scripts still spell
# out a subset of it by hand: the phases lib/phase-mode.sh answers for, the phases the
# driver's phase-begin asks it about and runs a prepare script for, and the phases
# hooks/team/placeholder-question-guard.sh treats as late or as the lead's own. A phase
# renamed or removed on the graph would leave a literal behind that no probe reads, so
# this pin reads every literal subset back against the graph
# (port audit 1, F9).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PASS=0; FAIL=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then echo "PASS: $name"; PASS=$((PASS+1))
  else echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL+1)); fi
}
phases="$(bash lib/graph/phases.sh list)"
not_phases() { # names on stdin that the graph does not list
  while IFS= read -r n; do [[ -n "$n" ]] && ! grep -qxF "$n" <<<"$phases" && echo "$n"; done | paste -sd' '
}

driver_sets="$(grep -oE 'phase in \("[a-z", ]+"\)' lib/graph/driver.py | grep -oE '"[a-z]+"' | tr -d '"' | sort -u)"
check "the driver names at least one literal phase subset (the scan still sees them)" "1" "$([[ -n "$driver_sets" ]] && echo 1 || echo 0)"
check "every phase the driver's literal subsets name is on the graph" "" "$(not_phases <<<"$driver_sets")"

mode_set="$(grep -oE '^case "\$phase" in [a-z|]+\)' lib/phase-mode.sh | grep -oE '[a-z]+(\|[a-z]+)*\)' | tr -d ')' | tr '|' '\n')"
check "phase-mode.sh answers for at least one phase" "1" "$([[ -n "$mode_set" ]] && echo 1 || echo 0)"
check "every phase phase-mode.sh answers for is on the graph" "" "$(not_phases <<<"$mode_set")"
check "the driver asks phase-mode.sh only about phases it answers for" "" "$(comm -23 <(grep -oE 'phase in \("spec"[^)]*\)' lib/graph/driver.py | grep -oE '"[a-z]+"' | tr -d '"' | sort -u) <(sort -u <<<"$mode_set") | paste -sd' ')"

guard_sets="$(grep -oE '\{"[a-z]+"(, "[a-z]+")*\}' hooks/team/placeholder-question-guard.sh | grep -oE '"[a-z]+"' | tr -d '"' | sort -u | grep -vx cycle)"
check "the placeholder guard names at least one literal phase subset" "1" "$([[ -n "$guard_sets" ]] && echo 1 || echo 0)"
check "every phase the placeholder guard names is on the graph" "" "$(not_phases <<<"$guard_sets")"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
