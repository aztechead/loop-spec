#!/usr/bin/env bash
# Unit tests for lib/output-digest.sh — bounded command output for a model's context.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/lib/output-digest.sh"
WORK="${TMPDIR:-/tmp}/loop-spec-output-digest.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"
PASS=0; FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

[[ -f "$SCRIPT" ]] || { echo "FAIL: missing $SCRIPT"; exit 1; }

# --- run: the full output is kept on disk, the digest is what reaches context ---
out="$(bash "$SCRIPT" run --log "$WORK/big.log" --label suite --max-lines 10 -- \
  bash -c 'for i in $(seq 1 400); do echo "line $i"; done')"
check "run exits 0 with the command" "0" "$?"
check "full output is complete on disk" "400" "$(wc -l < "$WORK/big.log" | tr -d ' ')"
check "digest is bounded" "1" \
  "$([[ "$(wc -l <<<"$out")" -le 14 ]] && echo 1 || echo 0)"
check "digest header names the label" "1" "$(grep -c '^suite: ' <<<"$out")"
check "digest header reports the true line count" "1" "$(grep -c 'lines=400' <<<"$out")"
check "digest header reports exit" "1" "$(grep -c 'exit=0' <<<"$out")"
check "digest names the full log" "0" \
  "$(grep -qF "$WORK/big.log" <<<"$out" && echo 0 || echo 1)"
check "digest keeps the head" "1" "$(grep -cx 'line 1' <<<"$out")"
check "digest keeps the tail" "1" "$(grep -cx 'line 400' <<<"$out")"
check "digest drops the middle" "0" "$(grep -cx 'line 200' <<<"$out" || true)"
check "digest says what it elided" "1" "$(grep -c 'lines elided' <<<"$out")"

# --- short output is passed through whole, with no elision marker ---
out="$(bash "$SCRIPT" run --log "$WORK/small.log" --label lint --max-lines 40 -- \
  bash -c 'echo one; echo two; echo three')"
check "short output keeps every line" "3" \
  "$(grep -cE '^(one|two|three)$' <<<"$out")"
check "short output has no elision marker" "0" "$(grep -c 'lines elided' <<<"$out" || true)"

# --- a failing command still fails: the digest never swallows an exit code ---
rc=0
out="$(bash "$SCRIPT" run --log "$WORK/fail.log" --label tests --max-lines 10 -- \
  bash -c 'echo boom; exit 3')" || rc=$?
check "the command's exit code propagates" "3" "$rc"
check "failure digest reports it" "1" "$(grep -c 'exit=3' <<<"$out")"
check "stderr is captured into the log too" "1" \
  "$(bash "$SCRIPT" run --log "$WORK/err.log" --label e -- \
      bash -c 'echo to-stderr >&2' >/dev/null 2>&1; grep -c 'to-stderr' "$WORK/err.log")"

# --- print: digests a log another runner already produced -------------------
seq 1 100 > "$WORK/existing.log"
out="$(bash "$SCRIPT" print --log "$WORK/existing.log" --label baseline --max-lines 6 --status 124)"
check "print reports the supplied status" "1" "$(grep -c 'exit=124' <<<"$out")"
check "print counts the log" "1" "$(grep -c 'lines=100' <<<"$out")"
check "print keeps the head" "1" "$(grep -cx '1' <<<"$out")"
check "print keeps the tail" "1" "$(grep -cx '100' <<<"$out")"

# --- an empty log is a determined empty result, not a failure ---------------
: > "$WORK/empty.log"
out="$(bash "$SCRIPT" print --log "$WORK/empty.log" --label quiet)"
check "empty log digests cleanly" "1" "$(grep -c 'lines=0' <<<"$out")"

# --- operator override ------------------------------------------------------
out="$(LOOP_SPEC_DIGEST_MAX_LINES=4 bash "$SCRIPT" print --log "$WORK/existing.log" --label o)"
check "LOOP_SPEC_DIGEST_MAX_LINES bounds the digest" "1" \
  "$([[ "$(wc -l <<<"$out")" -le 8 ]] && echo 1 || echo 0)"
check "an explicit --max-lines outranks the environment" "1" \
  "$(LOOP_SPEC_DIGEST_MAX_LINES=4 bash "$SCRIPT" print --log "$WORK/existing.log" \
      --label o --max-lines 50 | grep -cx '25')"

# --- invocation errors ------------------------------------------------------
rc=0; bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
check "no subcommand is a usage error" "2" "$rc"
rc=0; bash "$SCRIPT" bogus --log "$WORK/x.log" >/dev/null 2>&1 || rc=$?
check "unknown subcommand is a usage error" "2" "$rc"
rc=0; bash "$SCRIPT" run --label x -- true >/dev/null 2>&1 || rc=$?
check "run without --log is a usage error" "2" "$rc"
rc=0; bash "$SCRIPT" print --log "$WORK/no-such.log" >/dev/null 2>&1 || rc=$?
check "print of a missing log fails loudly" "1" "$rc"
rc=0; bash "$SCRIPT" run --log "$WORK/y.log" --max-lines zero -- true >/dev/null 2>&1 || rc=$?
check "a non-numeric --max-lines is a usage error" "2" "$rc"
rc=0; bash "$SCRIPT" run --log "$WORK/y.log" --max-lines 0 -- true >/dev/null 2>&1 || rc=$?
check "--max-lines 0 is refused (reads as 'no limit')" "2" "$rc"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
