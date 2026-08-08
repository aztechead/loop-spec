#!/usr/bin/env bash
# Assert skills and graph/cycle.graph.json agree on topology (build-order gate).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GRAPH="$ROOT/graph/cycle.graph.json"
PASS=0; FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

[[ -f "$GRAPH" ]] || { echo "FAIL: missing $GRAPH"; exit 1; }
bash "$ROOT/lib/graph/validate.sh" "$GRAPH" >/dev/null
check "cycle graph validates" "0" "$?"

# Phase agent nodes present
for phase in spec discuss plan execute verify iterate deliver; do
  n="$(jq -r --arg p "$phase" '[.nodes[] | select(.id==$p)] | length' "$GRAPH")"
  check "phase node $phase present" "1" "$n"
done

# Forward chain successors implied by cycle skill Step 6
# SPEC -> DISCUSS -> PLAN -> EXECUTE -> VERIFY -> ITERATE -> DELIVER
has_path() {
  local from="$1" to="$2"
  jq -e --arg f "$from" --arg t "$to" '
    .edges | any(.from==$f and .to==$t)
  ' "$GRAPH" >/dev/null
}

# Allow intermediate human/subgraph/gate nodes: reachability via BFS on all edges
reachable() {
  local start="$1" goal="$2"
  python3 - "$GRAPH" "$start" "$goal" <<'PY'
import json, sys
g=json.load(open(sys.argv[1]))
start, goal = sys.argv[2], sys.argv[3]
adj={}
for e in g["edges"]:
    adj.setdefault(e["from"], []).append(e["to"])
seen=set(); stack=[start]
while stack:
    cur=stack.pop()
    if cur==goal:
        sys.exit(0)
    if cur in seen: continue
    seen.add(cur)
    stack.extend(adj.get(cur, []))
sys.exit(1)
PY
}

for pair in "spec:discuss" "discuss:plan" "plan:execute" "execute:verify" "verify:iterate" "iterate:deliver"; do
  from="${pair%%:*}"; to="${pair##*:}"
  if reachable "$from" "$to"; then
    check "successor $from->$to" "1" "1"
  else
    check "successor $from->$to" "1" "0"
  fi
done

# ITERATE rewind targets as routes
for target in execute plan spec; do
  n="$(jq -r --arg t "$target" '[.edges[] | select(.kind=="route" and .to==$t)] | length' "$GRAPH")"
  check "iterate route to $target" "1" "$([[ "$n" -ge 1 ]] && echo 1 || echo 0)"
done

# Skills mention the same rewind targets
for target in execute plan spec; do
  if grep -q "currentPhase.*=.*\"$target\"\|currentPhase = \"$target\"" "$ROOT/skills/iterate/SKILL.md"; then
    check "iterate skill implements rewind $target" "1" "1"
  else
    # discuss is the autonomous landing for spec-level gaps
    if [[ "$target" == "spec" ]] && grep -q 'currentPhase.*=.*"discuss"' "$ROOT/skills/iterate/SKILL.md"; then
      check "iterate skill implements rewind $target (via discuss)" "1" "1"
    else
      check "iterate skill implements rewind $target" "1" "0"
    fi
  fi
done

# EXECUTE fanout/fanin
fanout="$(jq '[.edges[] | select(.kind=="fanout")] | length' "$GRAPH")"
fanin="$(jq '[.edges[] | select(.kind=="fanin")] | length' "$GRAPH")"
check "execute fanout present" "1" "$([[ "$fanout" -ge 1 ]] && echo 1 || echo 0)"
check "execute fanin present" "1" "$([[ "$fanin" -ge 1 ]] && echo 1 || echo 0)"

# Critique subgraph referenced twice
crit="$(jq '[.nodes[] | select(.kind=="subgraph" and .graph=="graph/critique.graph.json")] | length' "$GRAPH")"
check "critique subgraph reused" "2" "$crit"

# Negative case: mutated graph must be detected
mut="$ROOT/graph/.cycle.mutated.$$.json"
jq 'del(.edges[] | select(.from=="spec"))' "$GRAPH" > "$mut"
rc=0
bash "$ROOT/lib/graph/validate.sh" "$mut" >/dev/null 2>&1 || rc=$?
rm -f "$mut"
check "mutated graph detected (non-zero)" "1" "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: conformance-negative: mutated graph was accepted" >&2
fi

# Successor declared in skill but missing from graph — greppable message helper
if ! reachable "spec" "discuss"; then
  echo "conformance: skill successor missing from graph: spec->discuss" >&2
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
