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
out="$(bash "$SCRIPT" add --title "fix off-by-one" --criteria "loop stops at n" \
  --grounding "loop stops at n | repo: src/loop.py:42 | integration: tests/test_loop.py:18" \
  --verify "pytest tests/test_loop.py" --result pass)"
check "b: add prints added" "$([[ "$out" == "added" ]] && echo 1 || echo 0)"
check "c: ledger file created" "$([[ -f "$LEDGER" ]] && echo 1 || echo 0)"
check "d: header present" "$(grep -q '^# adhoc-ledger.md' "$LEDGER" && echo 1 || echo 0)"
check "e: entry heading has title" "$(grep -q '^## .* — fix off-by-one' "$LEDGER" && echo 1 || echo 0)"
check "f: criteria bullet present" "$(grep -qF -- '- criteria: loop stops at n' "$LEDGER" && echo 1 || echo 0)"
check "g: verify bullet has cmd and result" "$(grep -qF -- '- verify: `pytest tests/test_loop.py` → pass' "$LEDGER" && echo 1 || echo 0)"
check "g2: grounding bullet present" "$(grep -qF -- '- grounding: loop stops at n | repo: src/loop.py:42 | integration: tests/test_loop.py:18' "$LEDGER" && echo 1 || echo 0)"

# --- multiple criteria + notes ---
bash "$SCRIPT" add --title "rename helper" \
  --criteria "callers updated" --criteria "grep finds no old name" \
  --grounding "callers updated | repo: src/helper.sh:12 | integration: src/main.sh:8" \
  --grounding "old name absent | repo: src/helper.sh:12 | integration: tests/helper.test.sh:20" \
  --verify "bash tests/run-all.sh" --result partial --notes "one caller deferred" >/dev/null
check "h: second entry appended (2 headings)" "$([[ "$(grep -c '^## ' "$LEDGER")" -eq 2 ]] && echo 1 || echo 0)"
check "i: multiple criteria bullets" "$([[ "$(grep -cF -- '- criteria:' "$LEDGER")" -eq 3 ]] && echo 1 || echo 0)"
check "j: notes bullet present" "$(grep -qF -- '- notes: one caller deferred' "$LEDGER" && echo 1 || echo 0)"
check "k: header written once" "$([[ "$(grep -c '^# adhoc-ledger.md' "$LEDGER")" -eq 1 ]] && echo 1 || echo 0)"
check "k2: multiple grounding bullets" "$([[ "$(grep -cF -- '- grounding:' "$LEDGER")" -eq 3 ]] && echo 1 || echo 0)"

# --- --pr records the delivery PR; absent flag leaves no pr bullet ---
PR_LEDGER="$TMPDIR_TEST/.loop-spec/pr-ledger.md"
LOOP_SPEC_ADHOC_LEDGER="$PR_LEDGER" bash "$SCRIPT" add --title "pr-linked task" --criteria "c" \
  --grounding "c | repo: src/app.py:1 | integration: none - standalone" \
  --verify "true" --result pass --pr "https://github.com/o/r/pull/7" >/dev/null
check "h2: pr bullet present" "$(grep -qF -- '- pr: https://github.com/o/r/pull/7' "$PR_LEDGER" && echo 1 || echo 0)"
check "h3: entries without --pr carry no pr bullet" "$([[ "$(grep -cF -- '- pr: ' "$LEDGER")" -eq 0 ]] && echo 1 || echo 0)"

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
bash "$SCRIPT" add --title t --criteria "c" --verify "v" --result pass >/dev/null 2>&1; rc=$?
check "s2: pass without grounding exits 2" "$([[ "$rc" -eq 2 ]] && echo 1 || echo 0)"
bash "$SCRIPT" add --title t --criteria "c1" --criteria "c2" --grounding "g1" --verify "v" --result pass >/dev/null 2>&1; rc=$?
check "s3: pass requires one grounding per criterion" "$([[ "$rc" -eq 2 ]] && echo 1 || echo 0)"
bash "$SCRIPT" add --title t --criteria "c" --grounding "g" --verify "v" --result pass >/dev/null 2>&1; rc=$?
check "s3b: pass rejects malformed grounding" "$([[ "$rc" -eq 2 ]] && echo 1 || echo 0)"
bash "$SCRIPT" add --title t --criteria "c" --grounding "" --verify "v" --result pass >/dev/null 2>&1; rc=$?
check "s3c: pass rejects empty grounding" "$([[ "$rc" -eq 2 ]] && echo 1 || echo 0)"
bash "$SCRIPT" add --title t --criteria "c1" --criteria "c2" \
  --grounding "c1 | repo: src/a.py:1 | integration: tests/a.py:1" \
  --grounding "c1 | repo: src/a.py:1 | integration: tests/a.py:1" \
  --verify "v" --result pass >/dev/null 2>&1; rc=$?
check "s3d: pass rejects duplicate grounding for one criterion" "$([[ "$rc" -eq 2 ]] && echo 1 || echo 0)"
bash "$SCRIPT" add --title t --criteria "c1" \
  --grounding "other | repo: src/a.py:1 | integration: tests/a.py:1" \
  --verify "v" --result pass >/dev/null 2>&1; rc=$?
check "s3e: pass rejects grounding for an unknown criterion" "$([[ "$rc" -eq 2 ]] && echo 1 || echo 0)"
bash "$SCRIPT" add --title t --criteria "c" --verify "v" --result fail >/dev/null 2>&1; rc=$?
check "s4: fail may record without grounding" "$([[ "$rc" -eq 0 ]] && echo 1 || echo 0)"
bash "$SCRIPT" bogus >/dev/null 2>&1; rc=$?
check "t: unknown subcommand exits 2" "$([[ "$rc" -eq 2 ]] && echo 1 || echo 0)"

# --- valueless trailing flag gets the usage contract, not a set -u death ---
err="$(bash "$SCRIPT" add --title 2>&1 >/dev/null)"; rc=$?
check "u: trailing valueless flag exits 2" "$([[ "$rc" -eq 2 ]] && echo 1 || echo 0)"
check "v: error names the flag, not 'unbound variable'" "$(printf '%s' "$err" | grep -q -- '--title requires a value' && echo 1 || echo 0)"
bash "$SCRIPT" list --limit >/dev/null 2>&1; rc=$?
check "w: list --limit without value exits 2" "$([[ "$rc" -eq 2 ]] && echo 1 || echo 0)"

# --- usage prints from the heredoc ---
out="$(bash "$SCRIPT" -h)"
check "x: -h prints Usage" "$(printf '%s' "$out" | grep -q '^Usage:' && echo 1 || echo 0)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
