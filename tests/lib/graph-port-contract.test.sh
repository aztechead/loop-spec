#!/usr/bin/env bash
# Conformance suite for handoff-port adapters. Pass adapter path as $1.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ADAPTER="${1:-$ROOT/lib/graph/port-local.sh}"
WORK="${TMPDIR:-/tmp}/loop-spec-port-contract.$$"
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

[[ -f "$ADAPTER" ]] || { echo "FAIL: missing adapter $ADAPTER"; exit 1; }
chmod +x "$ADAPTER" 2>/dev/null || true

export LOOP_SPEC_PORT_ROOT="$WORK/store"
rm -rf "$WORK/store"
mkdir -p "$WORK/store"

run() { bash "$ADAPTER" "$@"; }

# `complete` re-derives its expected hash from a live feature.json (defect: it
# used to compare two claimant-supplied strings, proving nothing). Give it a
# real fixture to hash instead of a fabricated "abc123" token.
mkdir -p "$WORK/feat"
printf '{"slug":"contract-fixture","schemaVersion":7}' > "$WORK/feat/feature.json"
state_hash="$(cksum <"$WORK/feat/feature.json" | awk '{print $1"-"$2}')"

# put/get round trip
jq -n --arg h "$state_hash" \
  '{id:"task-002",node:"execute.worker",stateHash:$h,verifyCommand:"true",baseSha:"deadbeef",inputs:{}}' \
  > "$WORK/bundle.json"
out="$(run put "$WORK/bundle.json")"
check "put shape" "id=task-002" "$out"
got="$(run get task-002)"
check "get matches" "$state_hash" "$(jq -r '.stateHash' <<<"$got")"

# list
ids="$(run list)"
echo "$ids" | grep -qx 'task-002'
check "list contains id" "0" "$?"

# claim exclusive
out="$(run claim task-002 alice 60)"
check_match_claim="$([[ "$out" == claimed=task-002* ]] && echo 1 || echo 0)"
check "claim succeeds" "1" "$check_match_claim"

rc=0
run claim task-002 bob 60 >/dev/null 2>&1 || rc=$?
check "double claim rejected" "1" "$rc"

# release then reclaim
run release task-002
out="$(run claim task-002 bob 1)"
check "reclaim after release" "1" "$([[ "$out" == claimed=task-002* ]] && echo 1 || echo 0)"

# lease expiry
sleep 2
out="$(run claim task-002 carol 60)"
check "claim after TTL" "1" "$([[ "$out" == claimed=task-002* ]] && echo 1 || echo 0)"

# complete with matching hash — result.json content is irrelevant to the
# check; only the bundle's stored stateHash vs a fresh hash of feature-dir's
# live feature.json is compared. A claimant that fabricates a stateHash in
# its result cannot make this pass (that was the defect).
cat > "$WORK/result.json" <<'EOF'
{"ok":true}
EOF
out="$(run complete task-002 "$WORK/result.json" "$WORK/feat")"
check "complete matching hash" "completed=task-002" "$out"

# stale complete: point complete at a feature-dir whose feature.json content
# has since diverged from what the bundle was cut from.
run put "$WORK/bundle.json" >/dev/null
run claim task-002 dave 60 >/dev/null
mkdir -p "$WORK/feat-stale"
printf '{"slug":"contract-fixture","schemaVersion":7,"currentPhase":"drifted"}' > "$WORK/feat-stale/feature.json"
rc=0
run complete task-002 "$WORK/result.json" "$WORK/feat-stale" >/dev/null 2>&1 || rc=$?
check "stale complete rejected" "1" "$rc"
[[ ! -f "$WORK/store/instances/task-002/result.json" ]]
check "stale left unmerged" "0" "$?"

# concurrent reclaimers: two claimants race an expired lease; exactly one wins
run put "$WORK/bundle.json" >/dev/null
run claim task-002 zero 1 >/dev/null
sleep 2
rc_a=0; rc_b=0
( run claim task-002 racer-a 60 >"$WORK/racer-a.out" 2>"$WORK/racer-a.err" ) &
pid_a=$!
( run claim task-002 racer-b 60 >"$WORK/racer-b.out" 2>"$WORK/racer-b.err" ) &
pid_b=$!
wait "$pid_a" || rc_a=$?
wait "$pid_b" || rc_b=$?
wins=0
[[ "$rc_a" -eq 0 ]] && wins=$((wins + 1))
[[ "$rc_b" -eq 0 ]] && wins=$((wins + 1))
check "exactly one concurrent reclaimer wins" "1" "$wins"
winner=""
[[ "$rc_a" -eq 0 ]] && winner="racer-a"
[[ "$rc_b" -eq 0 ]] && winner="racer-b"
stored_owner="$(jq -r '.owner' "$WORK/store/instances/task-002/claim.json")"
check "stored claim matches the winner" "$winner" "$stored_owner"

# dispatcher defaults
bash "$ROOT/lib/graph/port.sh" >/dev/null 2>&1 || rc=$?
check "port.sh no-arg exits 2" "2" "$rc"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
