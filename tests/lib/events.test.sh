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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
