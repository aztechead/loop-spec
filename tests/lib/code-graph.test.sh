#!/usr/bin/env bash
# Tests for lib/code-graph.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/lib/code-graph.sh"
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

contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name (expected output to contain '$needle', got '$haystack')"; ((FAIL++)) || true
  fi
}

rc=0; bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
check "A: no subcommand is a usage error" "2" "$rc"
rc=0; bash "$SCRIPT" require >/dev/null 2>&1 || rc=$?
check "B: require without a job is a usage error" "2" "$rc"
rc=0; bash "$SCRIPT" require semantic >/dev/null 2>&1 || rc=$?
check "C: require with an unknown job is a usage error" "2" "$rc"

WORK="${TMPDIR:-/tmp}/loop-spec-code-graph.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"
cd "$WORK"

# ── No tools at all: every job degrades, nothing aborts ──────────────────────
rc=0; out="$(bash "$SCRIPT" layers)" || rc=$?
check "D: layers reports cleanly with no tools installed" "0" "$rc"
contains "E: structural degrades to grep" "structural=grep" "$out"
contains "F: the degraded answer says why" "no built graph" "$out"
contains "G: ripple has no substitute and says so" "ripple=none" "$out"
contains "H: the semantic layer is honestly absent" "semantic=none" "$out"

rc=0; bash "$SCRIPT" require structural >/dev/null 2>&1 || rc=$?
check "I: require structural fails when only grep is left" "1" "$rc"
rc=0; bash "$SCRIPT" require ripple >/dev/null 2>&1 || rc=$?
check "J: require ripple fails with no graph" "1" "$rc"

# ── A built graph answers both jobs, with the staleness caveat stated ────────
mkdir -p graphify-out
printf '{}' > graphify-out/graph.json
out="$(bash "$SCRIPT" structural)"
contains "K: graph.json answers structural" "structural=graphify" "$out"
contains "L: the graph answer names its staleness caveat" "only as current as its last refresh" "$out"

out="$(bash "$SCRIPT" ripple)"
contains "M: graph.json without the report cannot do hotspots" "GRAPH_REPORT.md missing" "$out"

printf '# report\n' > graphify-out/GRAPH_REPORT.md
out="$(bash "$SCRIPT" ripple)"
contains "N: the report answers ripple" "ripple=graphify" "$out"
contains "O: the ripple answer names what it provides" "god nodes" "$out"
rc=0; bash "$SCRIPT" require ripple >/dev/null 2>&1 || rc=$?
check "P: require ripple passes with a full graph" "0" "$rc"

# ── The operator override outranks the probe, in both directions ─────────────
out="$(LOOP_SPEC_STRUCTURAL_TOOL=graphify bash "$SCRIPT" structural)"
contains "U: an explicit tool wins over the probe" "structural=graphify" "$out"
contains "V: the override announces itself" "operator override" "$out"

out="$(LOOP_SPEC_STRUCTURAL_TOOL=grep bash "$SCRIPT" structural)"
contains "W: the override can also force the weakest tool" "structural=grep" "$out"

# An unknown override is ignored loudly rather than obeyed silently.
out="$(LOOP_SPEC_STRUCTURAL_TOOL=nonsense bash "$SCRIPT" structural 2>/dev/null)"
contains "X: an unknown override falls back to the probe" "structural=graphify" "$out"
err="$(LOOP_SPEC_STRUCTURAL_TOOL=nonsense bash "$SCRIPT" structural 2>&1 >/dev/null)"
contains "Y: the ignored override is reported on stderr" "ignoring unknown" "$err"

# ── The whole point: no layer is a hard gate ─────────────────────────────────
rm -rf graphify-out
rc=0; bash "$SCRIPT" layers >/dev/null 2>&1 || rc=$?
check "Z: reporting never fails, however little is installed" "0" "$rc"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
