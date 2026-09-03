#!/usr/bin/env bash
# Conformance suite for state-store adapters. Pass the adapter path as $1; the
# tree runs it against lib/supervisor/store-local.sh and store-mirror.sh. An
# adapter that answers these is one the port may dispatch to
# (docs/loop-spec/supervisor-interface.md, "Port 1: state store").
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ADAPTER="${1:-$ROOT/lib/supervisor/store-local.sh}"
WORK="${TMPDIR:-/tmp}/loop-spec-store-contract.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/proj/.loop-spec/features/alpha" "$WORK/mirror"
PASS=0; FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

[[ -f "$ADAPTER" ]] || { echo "FAIL: missing adapter $ADAPTER"; exit 1; }
export LOOP_SPEC_STORE_DIR="$WORK/mirror"
export CLAUDE_PROJECT_DIR="$WORK/proj"
run() { bash "$ADAPTER" "$@"; }

feat="$WORK/proj/.loop-spec/features/alpha"
printf '{"slug":"alpha","schemaVersion":7}' > "$feat/feature.json"

# describe: one line, store=<name> first
line="$(run describe)"
check "describe shape" "store=" "${line:0:6}"
check "describe is one line" "1" "$(printf '%s\n' "$line" | wc -l | tr -d ' ')"

# persist: exit 0, names the slug
out="$(run persist "$feat" contract-test)"; ec=$?
check "persist exits 0" "0" "$ec"
check "persist names the slug" "persisted=alpha" "${out%% *}"

# list: the persisted slug is listed
check "list holds the slug" "alpha" "$(run list "$WORK/proj" | grep -x alpha)"

# open on a present working copy: exit 0, source=working-copy
out="$(run open "$feat")"; ec=$?
check "open present exits 0" "0" "$ec"
check "open present says working-copy" "opened=alpha source=working-copy" "$out"

# open is idempotent and leaves the working copy intact
run open "$feat" >/dev/null
check "open keeps feature.json" "alpha" "$(jq -r .slug "$feat/feature.json")"

# open after the working copy is gone: a store that holds it restores it, and the
# checkout adapter (which holds nothing but the checkout) reports it missing
rm -rf "$feat"
out="$(run open "$feat" 2>&1)"; ec=$?
if [[ -f "$feat/feature.json" ]]; then
  check "open restored the working copy" "opened=alpha source=mirror" "$out"
  check "restored feature.json intact" "alpha" "$(jq -r .slug "$feat/feature.json")"
else
  check "open on a missing slug exits non-zero" "1" "$(( ec != 0 ))"
fi

# open on a slug nobody holds: non-zero, loud
out="$(run open "$WORK/proj/.loop-spec/features/nobody" 2>&1)"; ec=$?
check "open unknown slug exits non-zero" "1" "$(( ec != 0 ))"
check "open unknown slug says so" "yes" "$(grep -qi 'nobody' <<<"$out" && echo yes || echo no)"

# bad invocations exit 2
ec=0; run persist "$feat" >/dev/null 2>&1 || ec=$?
check "persist without reason exits 2" "2" "$ec"
ec=0; run open >/dev/null 2>&1 || ec=$?
check "open without dir exits 2" "2" "$ec"
ec=0; run bogus >/dev/null 2>&1 || ec=$?
check "unknown op exits 2" "2" "$ec"

echo ""
echo "Results: $PASS passed, $FAIL failed ($(basename "$ADAPTER"))"
[[ "$FAIL" -eq 0 ]] || exit 1
