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

# put/get round trip
cat > "$WORK/bundle.json" <<'EOF'
{"id":"task-002","node":"execute.worker","stateHash":"abc123","verifyCommand":"true","baseSha":"deadbeef","inputs":{}}
EOF
out="$(run put "$WORK/bundle.json")"
check "put shape" "id=task-002" "$out"
got="$(run get task-002)"
check "get matches" "abc123" "$(jq -r '.stateHash' <<<"$got")"

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

# complete with matching hash
cat > "$WORK/result.json" <<'EOF'
{"stateHash":"abc123","ok":true}
EOF
out="$(run complete task-002 "$WORK/result.json")"
check "complete matching hash" "completed=task-002" "$out"

# stale complete
run put "$WORK/bundle.json" >/dev/null
run claim task-002 dave 60 >/dev/null
cat > "$WORK/stale.json" <<'EOF'
{"stateHash":"DIFFERENT","ok":true}
EOF
rc=0
run complete task-002 "$WORK/stale.json" >/dev/null 2>&1 || rc=$?
check "stale complete rejected" "1" "$rc"
[[ ! -f "$WORK/store/instances/task-002/result.json" ]] || [[ "$(jq -r '.stateHash' "$WORK/store/instances/task-002/result.json" 2>/dev/null)" != "DIFFERENT" ]]
check "stale left unmerged" "0" "$?"

# dispatcher defaults
bash "$ROOT/lib/graph/port.sh" >/dev/null 2>&1 || rc=$?
check "port.sh no-arg exits 2" "2" "$rc"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
