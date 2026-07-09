#!/usr/bin/env bash
# Test suite for lib/adhoc-ledger.sh
# Usage: bash tests/lib/adhoc-ledger.test.sh
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/lib/adhoc-ledger.sh"
TMPDIR_TEST="${TMPDIR:-/tmp}/adhoc-ledger-test-$$"
mkdir -p "$TMPDIR_TEST"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

LEDGER="$TMPDIR_TEST/.loop-spec/adhoc-ledger.md"
export LOOP_SPEC_ADHOC_LEDGER="$LEDGER"

PASS=0
FAIL=0

check() {
  local name="$1" cond="$2"
  if [[ "$cond" == "1" ]]; then PASS=$((PASS+1)); echo "PASS: $name"
  else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi
}

echo "=== adhoc-ledger.sh tests ==="

# --- path resolves to the override ---
out="$(bash "$SCRIPT" path)"
check "a: path honors LOOP_SPEC_ADHOC_LEDGER" "$([[ "$out" == "$LEDGER" ]] && echo 1 || echo 0)"

# --- add creates file with header and prints 'added' ---
out="$(bash "$SCRIPT" add --title "fix off-by-one" --criteria "loop stops at n" --verify "pytest tests/test_loop.py" --result pass)"
check "b: add prints added" "$([[ "$out" == "added" ]] && echo 1 || echo 0)"
check "c: ledger file created" "$([[ -f "$LEDGER" ]] && echo 1 || echo 0)"
check "d: header present" "$(grep -q '^# adhoc-ledger.md' "$LEDGER" && echo 1 || echo 0)"
check "e: entry heading has title" "$(grep -q '^## .* — fix off-by-one' "$LEDGER" && echo 1 || echo 0)"
check "f: criteria bullet present" "$(grep -qF -- '- criteria: loop stops at n' "$LEDGER" && echo 1 || echo 0)"
check "g: verify bullet has cmd and result" "$(grep -qF -- '- verify: `pytest tests/test_loop.py` → pass' "$LEDGER" && echo 1 || echo 0)"

# --- multiple criteria + notes ---
bash "$SCRIPT" add --title "rename helper" \
  --criteria "callers updated" --criteria "grep finds no old name" \
  --verify "bash tests/run-all.sh" --result partial --notes "one caller deferred" >/dev/null
check "h: second entry appended (2 headings)" "$([[ "$(grep -c '^## ' "$LEDGER")" -eq 2 ]] && echo 1 || echo 0)"
check "i: multiple criteria bullets" "$([[ "$(grep -cF -- '- criteria:' "$LEDGER")" -eq 3 ]] && echo 1 || echo 0)"
check "j: notes bullet present" "$(grep -qF -- '- notes: one caller deferred' "$LEDGER" && echo 1 || echo 0)"
check "k: header written once" "$([[ "$(grep -c '^# adhoc-ledger.md' "$LEDGER")" -eq 1 ]] && echo 1 || echo 0)"

# --- list shows headings, newest last, respects --limit ---
out="$(bash "$SCRIPT" list)"
check "l: list shows both entries" "$([[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 2 ]] && echo 1 || echo 0)"
check "m: list newest last" "$(printf '%s\n' "$out" | tail -1 | grep -q 'rename helper' && echo 1 || echo 0)"
out="$(bash "$SCRIPT" list --limit 1)"
check "n: --limit 1 shows one entry" "$([[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 1 ]] && echo 1 || echo 0)"

# --- list with no ledger file is silent success ---
out="$(LOOP_SPEC_ADHOC_LEDGER="$TMPDIR_TEST/nonexistent.md" bash "$SCRIPT" list)"; rc=$?
check "o: list without file exits 0 empty" "$([[ "$rc" -eq 0 && -z "$out" ]] && echo 1 || echo 0)"

# --- validation errors exit 2 ---
bash "$SCRIPT" add --criteria "c" --verify "v" --result pass >/dev/null 2>&1; rc=$?
check "p: missing --title exits 2" "$([[ "$rc" -eq 2 ]] && echo 1 || echo 0)"
bash "$SCRIPT" add --title t --criteria "c" --result pass >/dev/null 2>&1; rc=$?
check "q: missing --verify exits 2" "$([[ "$rc" -eq 2 ]] && echo 1 || echo 0)"
bash "$SCRIPT" add --title t --verify "v" --result pass >/dev/null 2>&1; rc=$?
check "r: missing --criteria exits 2" "$([[ "$rc" -eq 2 ]] && echo 1 || echo 0)"
bash "$SCRIPT" add --title t --criteria "c" --verify "v" --result maybe >/dev/null 2>&1; rc=$?
check "s: invalid --result exits 2" "$([[ "$rc" -eq 2 ]] && echo 1 || echo 0)"
bash "$SCRIPT" bogus >/dev/null 2>&1; rc=$?
check "t: unknown subcommand exits 2" "$([[ "$rc" -eq 2 ]] && echo 1 || echo 0)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
