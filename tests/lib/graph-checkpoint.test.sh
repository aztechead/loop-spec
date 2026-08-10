#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/lib/graph/checkpoint.sh"
WORK="${TMPDIR:-/tmp}/loop-spec-graph-checkpoint.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/feat"
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

jq -n '{slug:"gdd-cp",schemaVersion:7,currentPhase:"execute"}' > "$WORK/feat/feature.json"

# latest empty
out="$(bash "$SCRIPT" latest --feature-dir "$WORK/feat")"
check "latest empty marker" "true" "$(jq -r '.empty // false' <<<"$out")"

# append
bash "$SCRIPT" append --feature-dir "$WORK/feat" --node execute \
  --edge 'chain:plan->execute' --effort system2
rec="$(bash "$SCRIPT" latest --feature-dir "$WORK/feat")"
check "latest not empty" "null" "$(jq -r '.empty // "null"' <<<"$rec")"
check "node set" "execute" "$(jq -r '.node' <<<"$rec")"
check "effort set" "system2" "$(jq -r '.effort' <<<"$rec")"
check "edge set" "chain:plan->execute" "$(jq -r '.edge' <<<"$rec")"
check "stateHash non-null" "false" "$(jq -r '.stateHash == null' <<<"$rec")"
check "gitSha non-null" "false" "$(jq -r '.gitSha == null or .gitSha == ""' <<<"$rec")"
check "ts non-null" "false" "$(jq -r '.ts == null or .ts == ""' <<<"$rec")"

first_line="$(cat "$WORK/feat/graph-checkpoints.jsonl")"
hash1="$(jq -r '.stateHash' <<<"$rec")"

# append-only: first record unchanged after second append
bash "$SCRIPT" append --feature-dir "$WORK/feat" --node verify \
  --edge 'chain:execute->verify' --effort system2
after_first="$(head -n 1 "$WORK/feat/graph-checkpoints.jsonl")"
check "append-only first record immutable" "$first_line" "$after_first"
lines="$(wc -l < "$WORK/feat/graph-checkpoints.jsonl" | tr -d ' ')"
check "two records" "2" "$lines"
check "latest is verify" "verify" "$(bash "$SCRIPT" latest --feature-dir "$WORK/feat" | jq -r '.node')"

# hash stability / change
bash "$ROOT/lib/feature-write.sh" set "$WORK/feat" currentPhase '"verify"'
bash "$SCRIPT" append --feature-dir "$WORK/feat" --node iterate \
  --edge 'chain:verify->iterate' --effort system2
hash2="$(bash "$SCRIPT" latest --feature-dir "$WORK/feat" | jq -r '.stateHash')"
check "hash changes when feature.json changes" "1" "$([[ "$hash1" != "$hash2" ]] && echo 1 || echo 0)"

# stable when unchanged
bash "$SCRIPT" append --feature-dir "$WORK/feat" --node iterate \
  --edge 'loop:iterate' --effort system2
hash3="$(bash "$SCRIPT" latest --feature-dir "$WORK/feat" | jq -r '.stateHash')"
check "hash stable when feature.json unchanged" "$hash2" "$hash3"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
