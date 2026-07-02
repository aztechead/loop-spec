#!/usr/bin/env bash
# Tests for lib/evidence.sh -- append-only evidence ledger.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/lib/evidence.sh"
PASS=0
FAIL=0

check() {
  local name="$1" cond="$2"
  if [[ "$cond" == "1" ]]; then PASS=$((PASS+1)); echo "PASS: $name"
  else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi
}

WORK="${TMPDIR:-/tmp}/evidence-test.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

# ─── Case 1: first add creates ledger and returns EVID-001 ─────────────────
ledger1="$WORK/ev1.md"
ec=0; result=$(bash "$LIB" add "$ledger1" "first claim" "first cmd" "first output") || ec=$?
check "first add exits 0" "$([[ $ec -eq 0 ]] && echo 1 || echo 0)"
check "first add returns EVID-001" "$([[ "$result" == "EVID-001" ]] && echo 1 || echo 0)"
check "first add creates ledger file" "$([[ -f "$ledger1" ]] && echo 1 || echo 0)"
check "ledger has # Evidence ledger heading" "$(grep -q '^# Evidence ledger' "$ledger1" && echo 1 || echo 0)"
check "ledger has EVID-001 entry line" "$(grep -q '^- EVID-001 |' "$ledger1" && echo 1 || echo 0)"

# ─── Case 2: second distinct add returns EVID-002 ──────────────────────────
ec2=0; result2=$(bash "$LIB" add "$ledger1" "second claim" "second cmd" "second output") || ec2=$?
check "second add exits 0" "$([[ $ec2 -eq 0 ]] && echo 1 || echo 0)"
check "second add returns EVID-002" "$([[ "$result2" == "EVID-002" ]] && echo 1 || echo 0)"
count=$(grep -c '^- EVID-' "$ledger1" 2>/dev/null || echo 0)
check "ledger now has 2 EVID entries" "$([[ "$count" -eq 2 ]] && echo 1 || echo 0)"

# ─── Case 3: identical claim+command re-add returns EVID-001 without appending
ec3=0; result3=$(bash "$LIB" add "$ledger1" "first claim" "first cmd" "different output ignored") || ec3=$?
check "re-add same claim+cmd exits 0" "$([[ $ec3 -eq 0 ]] && echo 1 || echo 0)"
check "re-add same claim+cmd returns existing EVID-001" "$([[ "$result3" == "EVID-001" ]] && echo 1 || echo 0)"
count2=$(grep -c '^- EVID-' "$ledger1" 2>/dev/null || echo 0)
check "re-add does not append a new entry (still 2)" "$([[ "$count2" -eq 2 ]] && echo 1 || echo 0)"

# ─── Case 4: pipe sanitization (| -> /) ────────────────────────────────────
ledger4="$WORK/ev4.md"
bash "$LIB" add "$ledger4" "claim with | pipe" "cmd | grep x" "out | pipe" >/dev/null
check "| in claim stored as /" "$(grep -q 'claim: claim with / pipe' "$ledger4" && echo 1 || echo 0)"
check "| in cmd stored as /" "$(grep -q 'cmd: cmd / grep x' "$ledger4" && echo 1 || echo 0)"
check "| in output stored as /" "$(grep -q 'out: out / pipe' "$ledger4" && echo 1 || echo 0)"

# ─── Case 5: newline/tab sanitization ──────────────────────────────────────
ledger5="$WORK/ev5.md"
bash "$LIB" add "$ledger5" $'claim\nwith\nnewlines' $'cmd\twith\ttabs' "out" >/dev/null
check "newlines in claim replaced with space" "$(grep -q 'claim: claim with newlines' "$ledger5" && echo 1 || echo 0)"
check "tabs in cmd replaced with space" "$(grep -q 'cmd: cmd with tabs' "$ledger5" && echo 1 || echo 0)"

# ─── Case 6: 300-char output truncation ────────────────────────────────────
ledger6="$WORK/ev6.md"
long=""
for i in $(seq 1 305); do long="${long}x"; done
bash "$LIB" add "$ledger6" "long-output claim" "long-output cmd" "$long" >/dev/null
out_line=$(grep '^- EVID-001 |' "$ledger6")
out_part="${out_line#*| out: }"
expected_truncated="${long:0:300}…"
check "300-char truncation: output is 300 chars + …" "$([[ "$out_part" == "$expected_truncated" ]] && echo 1 || echo 0)"

# ─── Case 7: list on missing ledger exits 0 and prints nothing ─────────────
ec7=0; list_out=$(bash "$LIB" list "$WORK/nonexistent.md") || ec7=$?
check "list on missing ledger exits 0" "$([[ $ec7 -eq 0 ]] && echo 1 || echo 0)"
check "list on missing ledger is empty" "$([[ -z "$list_out" ]] && echo 1 || echo 0)"

# ─── Case 8: next-id correctness ───────────────────────────────────────────
ledger8="$WORK/ev8.md"
nid_empty=$(bash "$LIB" next-id "$WORK/nonexistent-nid.md")
check "next-id on missing ledger returns EVID-001" "$([[ "$nid_empty" == "EVID-001" ]] && echo 1 || echo 0)"
bash "$LIB" add "$ledger8" "c1" "cmd1" "o1" >/dev/null
nid_after1=$(bash "$LIB" next-id "$ledger8")
check "next-id after 1 entry returns EVID-002" "$([[ "$nid_after1" == "EVID-002" ]] && echo 1 || echo 0)"
bash "$LIB" add "$ledger8" "c2" "cmd2" "o2" >/dev/null
nid_after2=$(bash "$LIB" next-id "$ledger8")
check "next-id after 2 entries returns EVID-003" "$([[ "$nid_after2" == "EVID-003" ]] && echo 1 || echo 0)"

# ─── Case 9: missing args -> stderr + exit 1 ───────────────────────────────
bash "$LIB" add >/dev/null 2>&1
check "add with no args exits 1" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"
bash "$LIB" list >/dev/null 2>&1
check "list with no args exits 1" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"
bash "$LIB" next-id >/dev/null 2>&1
check "next-id with no args exits 1" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"
bash "$LIB" >/dev/null 2>&1
check "unknown subcommand exits 1" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
