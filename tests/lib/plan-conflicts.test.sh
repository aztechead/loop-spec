#!/usr/bin/env bash
# Tests for lib/plan-conflicts.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/lib/plan-conflicts.sh"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; ((FAIL++)) || true
  fi
}

WORK="${TMPDIR:-/tmp}/plan-conflicts-test.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

cat > "$WORK/overlap.json" <<'EOF'
[
  {"id":"task-001","files":["a.sh","shared.sh"],"blockedBy":[],"verifyCommand":"true",
   "acceptanceCriteria":["ok"]},
  {"id":"task-002","files":["b.sh","shared.sh"],"blockedBy":[],"verifyCommand":"true",
   "acceptanceCriteria":["ok"]}
]
EOF
out=$(bash "$SCRIPT" table "$WORK/overlap.json")
check "overlap rows" "1" "$(jq '.rows' <<<"$out")"
check "overlap reason" "conflicts" "$(jq -r '.reason' <<<"$out")"
check "overlap pair files" "shared.sh" "$(jq -r '.pairs[0].files | join(",")' <<<"$out")"

cat > "$WORK/iface.json" <<'EOF'
[
  {"id":"task-001","files":["a.sh"],"blockedBy":[],"verifyCommand":"true",
   "acceptanceCriteria":["ok"],"interfaces":{"consumes":"Foo","produces":"none"}},
  {"id":"task-002","files":["b.sh"],"blockedBy":[],"verifyCommand":"true",
   "acceptanceCriteria":["ok"],"interfaces":{"consumes":"none","produces":"Bar"}}
]
EOF
out=$(bash "$SCRIPT" table "$WORK/iface.json")
check "missing producer rows" "1" "$(jq '.rows' <<<"$out")"
check "missing producer names consume" "task-001" "$(jq -r '.interfaces[0].task' <<<"$out")"

cat > "$WORK/clean.json" <<'EOF'
[
  {"id":"task-001","files":["a.sh"],"blockedBy":[],"verifyCommand":"true",
   "acceptanceCriteria":["ok"],"interfaces":{"consumes":"none","produces":"Foo"}},
  {"id":"task-002","files":["b.sh"],"blockedBy":[],"verifyCommand":"true",
   "acceptanceCriteria":["ok"],"interfaces":{"consumes":"Foo","produces":"none"}}
]
EOF
out=$(bash "$SCRIPT" table "$WORK/clean.json")
check "clean table rows" "0" "$(jq '.rows' <<<"$out")"
check "clean reason" "clean" "$(jq -r '.reason' <<<"$out")"

ec=0; bash "$SCRIPT" >/dev/null 2>&1 || ec=$?
check "usage exits 2" "2" "$ec"

echo ""

# edges: a consumes/goal mention of another task becomes a blockedBy edge, written back;
# a mention that would close a cycle writes nothing.
cat > "$WORK/edges.json" <<'EOF'
[
  {"id":"task-001","files":["a"],"blockedBy":[],"verifyCommand":"true","acceptanceCriteria":["a"],"interfaces":{"consumes":"none","produces":"root.hcl"}},
  {"id":"task-002","files":["b"],"blockedBy":[],"verifyCommand":"true","acceptanceCriteria":["b"],"interfaces":{"consumes":"task-001's root.hcl constraints","produces":"none"}},
  {"id":"task-003","files":["c"],"blockedBy":["task-002"],"verifyCommand":"true","acceptanceCriteria":["c"],"goal":"describe the unit task-002 audited and task-003 itself"}
]
EOF
out="$(bash "$SCRIPT" edges "$WORK/edges.json")"
check "edges: consumes mention adds the edge" "1" "$(grep -c '^edge task-002 -> task-001$' <<<"$out")"
check "edges: existing edge and self-mention add nothing" "1" "$(grep -c '1 edge(s) inferred' <<<"$out")"
check "edges: tasks.json is written back" "task-001" "$(jq -r '.[1].blockedBy | join(",")' "$WORK/edges.json")"
cat > "$WORK/cycle.json" <<'EOF'
[
  {"id":"task-001","files":["a"],"blockedBy":["task-002"],"verifyCommand":"true","acceptanceCriteria":["a"]},
  {"id":"task-002","files":["b"],"blockedBy":[],"verifyCommand":"true","acceptanceCriteria":["b"],"goal":"needs task-001"}
]
EOF
before="$(cat "$WORK/cycle.json")"; ec=0; bash "$SCRIPT" edges "$WORK/cycle.json" >/dev/null 2>&1 || ec=$?
check "edges: a cycle is refused" "1" "$ec"
check "edges: nothing written on refusal" "1" "$([[ "$before" == "$(cat "$WORK/cycle.json")" ]] && echo 1 || echo 0)"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
