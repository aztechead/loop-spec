#!/usr/bin/env bash
# Offline unit suite for lib/graph/validate.sh — the schema and referential
# validator over a declared workflow graph. One accepting case, one rejection
# per rule (probe-shaped route conditions, probe existence, edge endpoints,
# reachability, loop ceilings, fanin joins, non-loop DAG-ness), plus the
# invocation contract (exit 2 on missing/unreadable args).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/lib/graph/validate.sh"
WORK="${TMPDIR:-/tmp}/loop-spec-graph-validate.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"
PASS=0; FAIL=0

check() {
  local name="$1" expected_rc="$2"; shift 2
  local rc=0 out
  out="$(bash "$SCRIPT" "$@" 2>&1)" || rc=$?
  if [[ "$rc" == "$expected_rc" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected rc=$expected_rc, got rc=$rc)"; echo "$out" | sed 's/^/    /'
    FAIL=$((FAIL + 1))
  fi
}

check_output() {
  local name="$1" pattern="$2"; shift 2
  local out
  out="$(bash "$SCRIPT" "$@" 2>&1 || true)"
  if grep -qF "$pattern" <<<"$out"; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (output missing '$pattern')"; echo "$out" | sed 's/^/    /'
    FAIL=$((FAIL + 1))
  fi
}

# --- invocation ---
check "no args is usage error" 2
check "missing graph file is a bad-invocation error, never 0" 2 "$WORK/does-not-exist.json"

# --- accepting case ---
# Probe paths resolve against the repo root; lib/security-signal.sh is a real
# executable probe already in the tree.
cat > "$WORK/good.json" <<'EOF'
{
  "id": "demo",
  "entry": "start",
  "nodes": [
    {"id": "start",  "kind": "agent",    "reads": [],       "writes": ["slug"],      "effort": "system2"},
    {"id": "branch", "kind": "gate",     "reads": ["slug"], "writes": [],            "effort": "system2"},
    {"id": "work",   "kind": "agent",    "reads": ["slug"], "writes": ["artifacts"], "effort": "system2"},
    {"id": "merge",  "kind": "function", "reads": [],       "writes": [],            "effort": "system1"},
    {"id": "done",   "kind": "human",    "reads": [],       "writes": [],            "effort": "system2"}
  ],
  "edges": [
    {"from": "start",  "to": "branch", "kind": "chain"},
    {"from": "branch", "to": "work",   "kind": "route", "condition": {"probe": "lib/security-signal.sh", "expects": "yes"}},
    {"from": "branch", "to": "merge",  "kind": "fanout"},
    {"from": "work",   "to": "merge",  "kind": "fanin", "join": "all"},
    {"from": "merge",  "to": "done",   "kind": "chain"},
    {"from": "done",   "to": "work",   "kind": "loop",  "ceiling": 3, "strategy": "unroll"}
  ]
}
EOF
check "valid graph passes" 0 "$WORK/good.json"
check_output "valid graph prints the ok answer line" "graph-validate: ok" "$WORK/good.json"

# --- rule 1: route condition must be a {probe, expects} object ---
jq '.edges[1].condition = "escalate if this looks security-relevant"' \
  "$WORK/good.json" > "$WORK/prose-condition.json"
check "free-text route condition flags" 1 "$WORK/prose-condition.json"
check_output "prose condition names the required shape" "{probe, expects}" "$WORK/prose-condition.json"
check_output "prose condition emits a FLAG line" "FLAG " "$WORK/prose-condition.json"

jq 'del(.edges[1].condition)' "$WORK/good.json" > "$WORK/no-condition.json"
check "route edge without a condition flags" 1 "$WORK/no-condition.json"

# --- rule 2: route probe must exist and be executable in the tree ---
jq '.edges[1].condition.probe = "lib/does-not-exist.sh"' \
  "$WORK/good.json" > "$WORK/probe-missing.json"
check "nonexistent probe path flags" 1 "$WORK/probe-missing.json"
check_output "missing probe is named" "lib/does-not-exist.sh" "$WORK/probe-missing.json"

jq '.edges[1].condition.probe = "README.md"' "$WORK/good.json" > "$WORK/probe-noexec.json"
check "non-executable probe flags" 1 "$WORK/probe-noexec.json"
check_output "non-executable probe is named" "not executable" "$WORK/probe-noexec.json"

# --- rule 3: edge endpoints must name declared nodes ---
jq '.edges[0].to = "ghost"' "$WORK/good.json" > "$WORK/unknown-to.json"
check "edge to an undeclared node flags" 1 "$WORK/unknown-to.json"
check_output "undeclared endpoint is named" "ghost" "$WORK/unknown-to.json"

jq '.edges[0].from = "phantom"' "$WORK/good.json" > "$WORK/unknown-from.json"
check "edge from an undeclared node flags" 1 "$WORK/unknown-from.json"

# --- rule 4: every node reachable from an entry node ---
jq '.nodes += [{"id": "island", "kind": "agent", "reads": [], "writes": [], "effort": "system2"}]' \
  "$WORK/good.json" > "$WORK/unreachable.json"
check "node unreachable from entry flags" 1 "$WORK/unreachable.json"
check_output "unreachable node is named" "island" "$WORK/unreachable.json"

# --- rule 5: loop edge must carry a numeric ceiling ---
jq 'del(.edges[5].ceiling)' "$WORK/good.json" > "$WORK/loop-no-ceiling.json"
check "loop edge without a ceiling flags" 1 "$WORK/loop-no-ceiling.json"

jq '.edges[5].ceiling = "three"' "$WORK/good.json" > "$WORK/loop-string-ceiling.json"
check "loop edge with a non-numeric ceiling flags" 1 "$WORK/loop-string-ceiling.json"

# --- rule 6: fanin must name a join rule ---
jq 'del(.edges[3].join)' "$WORK/good.json" > "$WORK/fanin-no-join.json"
check "fanin edge without a join rule flags" 1 "$WORK/fanin-no-join.json"

# --- rule 7: chain/route/fanout/fanin edges must form a DAG ---
# A literal back-edge among the acyclic kinds is a cycle...
cat > "$WORK/back-edge.json" <<'EOF'
{
  "id": "cyc",
  "entry": "a",
  "nodes": [
    {"id": "a", "kind": "agent", "reads": [], "writes": [], "effort": "system2"},
    {"id": "b", "kind": "agent", "reads": [], "writes": [], "effort": "system2"}
  ],
  "edges": [
    {"from": "a", "to": "b", "kind": "chain"},
    {"from": "b", "to": "a", "kind": "chain"}
  ]
}
EOF
check "non-loop back-edge cycle flags" 1 "$WORK/back-edge.json"
check_output "cycle flag names the involved edge kinds" "chain/route/fanout/fanin" "$WORK/back-edge.json"

# ...but the same shape declared as a bounded loop edge is legal iteration.
jq '.edges[1] = {"from": "b", "to": "a", "kind": "loop", "ceiling": 2, "strategy": "contain"}' \
  "$WORK/back-edge.json" > "$WORK/loop-back-edge.json"
check "bounded loop back-edge passes (loop excluded from DAG check)" 0 "$WORK/loop-back-edge.json"

# --- schema enforcement beyond the rules above ---
printf 'not json' > "$WORK/bad.json"
check "unparseable graph flags, never exits 0" 1 "$WORK/bad.json"

jq '.nodes[0].kind = "wizard"' "$WORK/good.json" > "$WORK/unknown-kind.json"
check "unknown node kind flags" 1 "$WORK/unknown-kind.json"

jq '.entry = "nowhere"' "$WORK/good.json" > "$WORK/bad-entry.json"
check "entry naming an undeclared node flags" 1 "$WORK/bad-entry.json"

# --- answer line shape on rejection ---
check_output "rejection prints the flag-count answer line" "flag(s)" "$WORK/prose-condition.json"

# --- skippable gate without licensing probe ---
cat > "$WORK/badskip.json" <<'EOFSKIP'
{
  "entry": "g",
  "nodes": [
    {"id": "g", "kind": "gate", "reads": [], "writes": [], "effort": "system1", "skippable": {}}
  ],
  "edges": []
}
EOFSKIP
check "skippable without probe exit 1" 1 "$WORK/badskip.json"
check_output "skippable without probe FLAG" "skippable" "$WORK/badskip.json"

# --- delivery-authorizing node with system1 ---
cat > "$WORK/baddel.json" <<'EOFDEL'
{
  "entry": "d",
  "nodes": [
    {"id": "d", "kind": "agent", "reads": [], "writes": [], "effort": "system1", "authorizesDelivery": true}
  ],
  "edges": []
}
EOFDEL
check "delivery system1 exit 1" 1 "$WORK/baddel.json"
check_output "delivery system1 FLAG" "system1" "$WORK/baddel.json"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
