#!/usr/bin/env bash
# Interrupted dispatch and failed checkpoint publication must not advance the graph.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/graph-recovery.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/agent" "$WORK/gate" "$WORK/checkpoint"
PASS=0; FAIL=0
check() {
  if [[ "$2" == "$3" ]]; then
    echo "PASS: $1"; PASS=$((PASS + 1))
  else
    echo "FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL + 1))
  fi
}
printf '{"slug":"recovery","currentPhase":"work"}\n' > "$WORK/agent/feature.json"
cp "$WORK/agent/feature.json" "$WORK/gate/feature.json"
cp "$WORK/agent/feature.json" "$WORK/checkpoint/feature.json"
cat > "$WORK/agent.json" <<'EOF'
{"entry":"work","nodes":[
 {"id":"work","kind":"agent","reads":[],"writes":[],"effort":"system1","body":"worker"},
 {"id":"end","kind":"function","reads":[],"writes":[],"effort":"system1"}],
 "edges":[{"from":"work","to":"end","kind":"chain"}]}
EOF
run() { bash "$ROOT/lib/graph/run.sh" --step --feature-dir "$WORK/$1" "${@:2}"; }
first="$(run agent "$WORK/agent.json")"
second="$(run agent "$WORK/agent.json")"
check "unacknowledged agent is replayed" work "$(jq -r .node <<<"$second")"
rc=0
run agent --completed-node end "$WORK/agent.json" >/dev/null 2>&1 || rc=$?
check "wrong completion identity is rejected" 1 "$rc"
rc=0
finished="$(run agent --completed-node work "$WORK/agent.json" 2>/dev/null)" || rc=$?
check "acknowledged agent advances" end "$(jq -r .node <<<"$finished")"

cat > "$WORK/fail.sh" <<'EOF'
#!/usr/bin/env bash
echo 'fixture: gate rejected' >&2
exit 1
EOF
jq --arg body "$WORK/fail.sh" '.nodes[0].kind="gate" | .nodes[0].body=$body' "$WORK/agent.json" > "$WORK/gate.json"
rc=0; run gate "$WORK/gate.json" >/dev/null 2>&1 || rc=$?
check "gate initially fails" 1 "$rc"
rc=0; run gate "$WORK/gate.json" >/dev/null 2>&1 || rc=$?
check "resuming a failed gate cannot skip it" 1 "$rc"

mkdir "$WORK/checkpoint/graph-checkpoints.jsonl"
rc=0; run checkpoint "$WORK/agent.json" >/dev/null 2>&1 || rc=$?
check "checkpoint failure prevents dispatch" 1 "$rc"

mkdir "$WORK/loop"
cp "$WORK/agent/feature.json" "$WORK/loop/feature.json"
jq '.edges=[{"from":"work","to":"work","kind":"loop","ceiling":2,"strategy":"unroll"}] | .nodes=[.nodes[0]]' \
  "$WORK/agent.json" > "$WORK/loop.json"
run loop "$WORK/loop.json" >/dev/null
run loop --completed-node work "$WORK/loop.json" >/dev/null
run loop --completed-node work "$WORK/loop.json" >/dev/null
last="$(run loop --completed-node work "$WORK/loop.json")"
check "loop ceiling survives separate step processes" true "$(jq -r .terminal <<<"$last")"

mkdir "$WORK/routed-loop"
cp "$WORK/agent/feature.json" "$WORK/routed-loop/feature.json"
jq --arg probe "$ROOT/lib/graph/probes/exec-style.sh" \
  '.edges += [{"from":"work","to":"work","kind":"route","condition":{"probe":$probe,"args":["--feature-dir","{featureDir}"],"expects":"style=auto"}}]' \
  "$WORK/loop.json" > "$WORK/routed-loop.json"
bash "$ROOT/lib/feature-write.sh" set "$WORK/routed-loop" execStyle '"auto"'
run routed-loop "$WORK/routed-loop.json" >/dev/null
run routed-loop --completed-node work "$WORK/routed-loop.json" >/dev/null
run routed-loop --completed-node work "$WORK/routed-loop.json" >/dev/null
rc=0; run routed-loop --completed-node work "$WORK/routed-loop.json" >/dev/null 2>&1 || rc=$?
check "a matching route cannot bypass its loop ceiling" 5 "$rc"

jq '.nodes[0].kind="function"' "$WORK/gate.json" > "$WORK/function.json"
mkdir "$WORK/function"
cp "$WORK/agent/feature.json" "$WORK/function/feature.json"
rc=0; run function "$WORK/function.json" >/dev/null 2>&1 || rc=$?
check "failed function cannot admit its successor" 1 "$rc"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
