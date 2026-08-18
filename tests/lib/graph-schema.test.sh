#!/usr/bin/env bash
# Assert graph/schema.json declares the GDD vocabulary and closed shapes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCHEMA="$ROOT/graph/schema.json"
PASS=0; FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

check_rc() {
  local name="$1" expected="$2" cmd="$3"
  local rc=0
  bash -c "$cmd" >/dev/null 2>&1 || rc=$?
  check "$name" "$expected" "$rc"
}

[[ -f "$SCHEMA" ]] || { echo "FAIL: schema missing at $SCHEMA"; exit 1; }

jq -e . "$SCHEMA" >/dev/null
check "schema parses as JSON" "0" "$?"

node_enum="$(jq -c '(.definitions.node.properties.kind.enum | sort)' "$SCHEMA")"
check "node kind enum" '["agent","function","gate","human","subgraph"]' "$node_enum"

edge_enum="$(jq -c '(.definitions.edge.properties.kind.enum | sort)' "$SCHEMA")"
check "edge kind enum" '["chain","fanin","fanout","loop","route"]' "$edge_enum"

cond_req="$(jq -c '(.definitions.routeCondition.required | sort)' "$SCHEMA")"
check "route condition requires probe+args+expects" '["args","expects","probe"]' "$cond_req"

cond_add="$(jq -r '.definitions.routeCondition.additionalProperties' "$SCHEMA")"
check "route condition closed" "false" "$cond_add"

expects_pattern="$(jq -r '.definitions.routeCondition.properties.expects.pattern' "$SCHEMA")"
check_rc "expects pattern rejects '|' alternation" "1" \
  "printf '%s' 'style=step|interactive' | grep -qE '$expects_pattern'"

# admit reuses the routeCondition shape; routeDefault is an optional node id
admit_ref="$(jq -r '.definitions.node.properties.admit["$ref"] // empty' "$SCHEMA")"
check "human admit reuses routeCondition shape" "#/definitions/routeCondition" "$admit_ref"

route_default_type="$(jq -r '.definitions.node.properties.routeDefault.type // empty' "$SCHEMA")"
check "routeDefault is a string node id" "string" "$route_default_type"

# bodyArgs is a string vector; optionalReads draws from the same key space as reads.
body_args_items="$(jq -r '.definitions.node.properties.bodyArgs.items.type // empty' "$SCHEMA")"
check "bodyArgs is an array of strings" "string" "$body_args_items"
optional_ref="$(jq -r '.definitions.node.properties.optionalReads.items["$ref"] // empty' "$SCHEMA")"
check "optionalReads draws from the stateKey enum" "#/definitions/stateKey" "$optional_ref"
check "schema does not declare skippable" "false" \
  "$(jq -r '.definitions.node.properties | has("skippable")' "$SCHEMA")"
route_args_desc="$(jq -r '.definitions.routeCondition.properties.args.description' "$SCHEMA")"
check "route args document the same placeholder set as bodyArgs" "1" \
  "$(grep -c '{featureRepoRoot}' <<<"$route_args_desc")"

ceiling_type="$(jq -r '
  .definitions.edge.properties.ceiling.type
  // .definitions.loopEdge.properties.ceiling.type
  // empty
' "$SCHEMA")"
check "loop ceiling is number" "number" "$ceiling_type"

strategy_enum="$(jq -c '
  (.definitions.edge.properties.strategy.enum
   // .definitions.loopEdge.properties.strategy.enum
   // []) | sort
' "$SCHEMA")"
check "loop strategy enum" '["contain","unroll"]' "$strategy_enum"

# When kind is loop, ceiling+strategy are required via allOf (loopEdge is the closed shape)
loop_required="$(jq -c '
  [.definitions.edge.allOf[]? | select(.if.properties.kind.const=="loop") | .then.required[]?]
  | unique | sort
' "$SCHEMA")"
check "loop requires ceiling+strategy" '["ceiling","strategy"]' "$loop_required"

# State key space subset of feature-state-schema v7 listing
state_keys="$(jq -r '.definitions.stateKey.enum[]' "$SCHEMA" | sort)"
doc="$ROOT/skills/shared/feature-state-schema.md"
missing=0
while IFS= read -r key; do
  [[ -z "$key" ]] && continue
  if ! grep -qE "\"${key}\"" "$doc"; then
    echo "FAIL: state key '$key' absent from feature-state-schema.md"
    missing=1
  fi
done <<<"$state_keys"
check "state keys subset of schema v7 doc" "0" "$missing"

# Unknown node kind is rejected against the enum (stdlib check; full validate is task-002)
unknown_rc=0
python3 - "$SCHEMA" <<'PY' || unknown_rc=$?
import json, sys
schema = json.load(open(sys.argv[1]))
allowed = set(schema["definitions"]["node"]["properties"]["kind"]["enum"])
graph = {
  "nodes": [{"id": "x", "kind": "wizard", "reads": [], "writes": [], "effort": "system2"}],
  "edges": [],
}
bad = [n for n in graph["nodes"] if n["kind"] not in allowed]
sys.exit(0 if bad else 1)
PY
check "unknown node kind fails validation" "0" "$unknown_rc"

# No executable content / templating
if [[ -x "$SCHEMA" ]]; then
  check "schema not executable" "0" "1"
else
  check "schema not executable" "0" "0"
fi
if grep -qE '^\#!/|\{\{' "$SCHEMA"; then
  check "schema has no shebang/templating" "0" "1"
else
  check "schema has no shebang/templating" "0" "0"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
