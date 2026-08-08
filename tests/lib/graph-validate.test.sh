#!/usr/bin/env bash
# Unit tests for lib/graph/validate.sh — schema + referential rules.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/lib/graph/validate.sh"
WORK="${TMPDIR:-/tmp}/loop-spec-graph-validate.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
PASS=0; FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

check_match() {
  local name="$1" pattern="$2" actual="$3"
  if [[ "$actual" =~ $pattern ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected match /$pattern/, got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

[[ -f "$SCRIPT" ]] || { echo "FAIL: missing $SCRIPT"; exit 1; }

# Stub probe executable inside repo so probe-path checks pass when referenced
# as a repo-relative path from fixtures that live under WORK — fixtures use
# lib/security-signal.sh which is already executable in-tree.
PROBE="lib/security-signal.sh"
[[ -x "$ROOT/$PROBE" ]] || chmod +x "$ROOT/$PROBE"

write_graph() {
  local path="$1"
  cat > "$path"
}

# --- bad invocation ---
rc=0
bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
check "no-arg exits 2" "2" "$rc"

rc=0
bash "$SCRIPT" "$WORK/missing.json" >/dev/null 2>&1 || rc=$?
check "missing file exits 2" "2" "$rc"

# --- accepting minimal graph ---
write_graph "$WORK/ok.json" <<EOF
{
  "entry": "a",
  "nodes": [
    {"id": "a", "kind": "function", "reads": [], "writes": ["currentPhase"], "effort": "system1", "body": "lib/dag-width.sh"},
    {"id": "b", "kind": "gate", "reads": ["currentPhase"], "writes": [], "effort": "system1"},
    {"id": "c", "kind": "agent", "reads": [], "writes": [], "effort": "system2"},
    {"id": "d", "kind": "agent", "reads": [], "writes": [], "effort": "system2"},
    {"id": "join", "kind": "function", "reads": [], "writes": [], "effort": "system1"}
  ],
  "edges": [
    {"from": "a", "to": "b", "kind": "chain"},
    {"from": "b", "to": "c", "kind": "route", "condition": {"probe": "$PROBE", "expects": "matched"}},
    {"from": "b", "to": "d", "kind": "fanout"},
    {"from": "c", "to": "join", "kind": "fanin", "join": "all"},
    {"from": "d", "to": "join", "kind": "fanin", "join": "all"},
    {"from": "join", "to": "a", "kind": "loop", "ceiling": 3, "strategy": "contain"}
  ]
}
EOF
out="$(bash "$SCRIPT" "$WORK/ok.json" 2>&1)" || true
rc=0; bash "$SCRIPT" "$WORK/ok.json" >/dev/null || rc=$?
check "valid graph exit 0" "0" "$rc"
check_match "valid graph answer" '^graph-validate: ok' "$(bash "$SCRIPT" "$WORK/ok.json" | tail -1)"

# --- free-text route condition ---
write_graph "$WORK/prose.json" <<EOF
{
  "entry": "a",
  "nodes": [
    {"id": "a", "kind": "function", "reads": [], "writes": [], "effort": "system1"},
    {"id": "b", "kind": "agent", "reads": [], "writes": [], "effort": "system2"}
  ],
  "edges": [
    {"from": "a", "to": "b", "kind": "route", "condition": "if it looks risky"}
  ]
}
EOF
rc=0; out="$(bash "$SCRIPT" "$WORK/prose.json" 2>&1)" || rc=$?
check "prose condition exit 1" "1" "$rc"
check_match "prose condition FLAG" 'FLAG .*:.*condition' "$out"

# --- missing probe executable ---
write_graph "$WORK/badprobe.json" <<EOF
{
  "entry": "a",
  "nodes": [
    {"id": "a", "kind": "function", "reads": [], "writes": [], "effort": "system1"},
    {"id": "b", "kind": "agent", "reads": [], "writes": [], "effort": "system2"}
  ],
  "edges": [
    {"from": "a", "to": "b", "kind": "route",
     "condition": {"probe": "lib/does-not-exist-probe.sh", "expects": "x"}}
  ]
}
EOF
rc=0; out="$(bash "$SCRIPT" "$WORK/badprobe.json" 2>&1)" || rc=$?
check "missing probe exit 1" "1" "$rc"
check_match "missing probe FLAG" 'FLAG .*:.*probe' "$out"

# --- undeclared endpoint ---
write_graph "$WORK/dangling.json" <<EOF
{
  "entry": "a",
  "nodes": [
    {"id": "a", "kind": "function", "reads": [], "writes": [], "effort": "system1"}
  ],
  "edges": [
    {"from": "a", "to": "ghost", "kind": "chain"}
  ]
}
EOF
rc=0; out="$(bash "$SCRIPT" "$WORK/dangling.json" 2>&1)" || rc=$?
check "undeclared node exit 1" "1" "$rc"
check_match "undeclared node FLAG" 'FLAG .*:.*ghost|undeclared' "$out"

# --- unreachable node ---
write_graph "$WORK/unreachable.json" <<EOF
{
  "entry": "a",
  "nodes": [
    {"id": "a", "kind": "function", "reads": [], "writes": [], "effort": "system1"},
    {"id": "orphan", "kind": "agent", "reads": [], "writes": [], "effort": "system2"}
  ],
  "edges": []
}
EOF
rc=0; out="$(bash "$SCRIPT" "$WORK/unreachable.json" 2>&1)" || rc=$?
check "unreachable exit 1" "1" "$rc"
check_match "unreachable FLAG" 'FLAG .*:.*unreachable|orphan' "$out"

# --- loop without ceiling ---
write_graph "$WORK/noloopceil.json" <<EOF
{
  "entry": "a",
  "nodes": [
    {"id": "a", "kind": "function", "reads": [], "writes": [], "effort": "system1"},
    {"id": "b", "kind": "agent", "reads": [], "writes": [], "effort": "system2"}
  ],
  "edges": [
    {"from": "a", "to": "b", "kind": "chain"},
    {"from": "b", "to": "a", "kind": "loop", "strategy": "unroll"}
  ]
}
EOF
rc=0; out="$(bash "$SCRIPT" "$WORK/noloopceil.json" 2>&1)" || rc=$?
check "loop without ceiling exit 1" "1" "$rc"
check_match "loop ceiling FLAG" 'FLAG .*:.*ceiling' "$out"

# --- fanin without join ---
write_graph "$WORK/nojoin.json" <<EOF
{
  "entry": "a",
  "nodes": [
    {"id": "a", "kind": "function", "reads": [], "writes": [], "effort": "system1"},
    {"id": "b", "kind": "agent", "reads": [], "writes": [], "effort": "system2"},
    {"id": "j", "kind": "function", "reads": [], "writes": [], "effort": "system1"}
  ],
  "edges": [
    {"from": "a", "to": "b", "kind": "fanout"},
    {"from": "b", "to": "j", "kind": "fanin"}
  ]
}
EOF
rc=0; out="$(bash "$SCRIPT" "$WORK/nojoin.json" 2>&1)" || rc=$?
check "fanin without join exit 1" "1" "$rc"
check_match "fanin join FLAG" 'FLAG .*:.*join' "$out"

# --- non-loop back-edge cycle (DAG violation) ---
write_graph "$WORK/cycle.json" <<EOF
{
  "entry": "a",
  "nodes": [
    {"id": "a", "kind": "function", "reads": [], "writes": [], "effort": "system1"},
    {"id": "b", "kind": "agent", "reads": [], "writes": [], "effort": "system2"}
  ],
  "edges": [
    {"from": "a", "to": "b", "kind": "chain"},
    {"from": "b", "to": "a", "kind": "chain"}
  ]
}
EOF
rc=0; out="$(bash "$SCRIPT" "$WORK/cycle.json" 2>&1)" || rc=$?
check "acyclic edge cycle exit 1" "1" "$rc"
check_match "cycle FLAG" 'FLAG .*:.*cycle|DAG' "$out"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
