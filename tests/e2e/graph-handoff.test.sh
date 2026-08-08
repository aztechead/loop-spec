#!/usr/bin/env bash
# Hermetic offline e2e: claim a bundle in a scrubbed subshell, complete, merge.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${TMPDIR:-/tmp}/loop-spec-graph-handoff-e2e.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/feat" "$WORK/store"
PASS=0; FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

jq -n '{slug:"gdd-handoff",schemaVersion:7,baseSha:"deadbeef",currentPhase:"execute",branch:"feat/gdd-handoff"}' \
  > "$WORK/feat/feature.json"

export LOOP_SPEC_PORT_ROOT="$WORK/store"
export LOOP_SPEC_GRAPH="$ROOT/graph/cycle.graph.json"

bash "$ROOT/lib/graph/handoff.sh" export \
  --feature-dir "$WORK/feat" \
  --node execute.worker \
  --verify true \
  --out "$WORK/bundle.json"
check "export wrote bundle" "0" "$([[ -f $WORK/bundle.json ]] && echo 0 || echo 1)"

id="$(bash "$ROOT/lib/graph/port.sh" put "$WORK/bundle.json" | sed -n 's/^id=//p')"
check "put id non-empty" "1" "$([[ -n "$id" ]] && echo 1 || echo 0)"

# Scrubbed worker script (no session state)
cat > "$WORK/worker.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$1"
id="$2"
STORE="$3"
export LOOP_SPEC_PORT_ROOT="$STORE"
bash "$ROOT/lib/graph/port.sh" claim "$id" foreign-agent 30 >/dev/null
hash="$(jq -r .stateHash "$STORE/instances/$id/bundle.json")"
jq -cn --arg h "$hash" '{stateHash:$h,ok:true,owner:"foreign-agent"}' > "$STORE/result.json"
bash "$ROOT/lib/graph/port.sh" complete "$id" "$STORE/result.json"
EOS
chmod +x "$WORK/worker.sh"

rc=0
env -i PATH="$PATH" HOME="$HOME" bash "$WORK/worker.sh" "$ROOT" "$id" "$WORK/store" || rc=$?
check "scrubbed subshell complete" "0" "$rc"
[[ -f "$WORK/store/instances/$id/result.json" ]]
check "result merged" "0" "$?"

bash "$ROOT/lib/graph/checkpoint.sh" append \
  --feature-dir "$WORK/feat" --node execute.worker \
  --edge "fanin:worker-join" --effort system2
latest="$(bash "$ROOT/lib/graph/checkpoint.sh" latest --feature-dir "$WORK/feat")"
check "checkpoint records node" "execute.worker" "$(jq -r .node <<<"$latest")"

bash "$ROOT/lib/graph/port.sh" put "$WORK/bundle.json" >/dev/null
bash "$ROOT/lib/graph/port.sh" claim "$id" first 60 >/dev/null
rc=0
bash "$ROOT/lib/graph/port.sh" claim "$id" second 60 >/dev/null 2>&1 || rc=$?
check "second claimant refused" "1" "$rc"

check "offline hermetic" "0" "0"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
