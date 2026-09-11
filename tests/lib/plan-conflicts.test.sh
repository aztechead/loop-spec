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

# edges: a consumes/goal mention of another task becomes a blockedBy edge in the
# PRINTED array; a mention that would close a cycle prints nothing. `edges` is
# print-only (a security hardening pass moved the write into cycle-driver.sh's own
# `plan tasks` publish_artifact call, under its held token) -- it must never touch
# the file on disk, registered tasks.json or not.
cat > "$WORK/edges.json" <<'EOF'
[
  {"id":"task-001","files":["a"],"blockedBy":[],"verifyCommand":"true","acceptanceCriteria":["a"],"interfaces":{"consumes":"none","produces":"root.hcl"}},
  {"id":"task-002","files":["b"],"blockedBy":[],"verifyCommand":"true","acceptanceCriteria":["b"],"interfaces":{"consumes":"task-001's root.hcl constraints","produces":"none"}},
  {"id":"task-003","files":["c"],"blockedBy":["task-002"],"verifyCommand":"true","acceptanceCriteria":["c"],"goal":"describe the unit task-002 audited and task-003 itself"}
]
EOF
before_edges="$(cat "$WORK/edges.json")"
before_edges_mtime="$(stat -c '%Y' "$WORK/edges.json" 2>/dev/null || stat -f '%m' "$WORK/edges.json")"
out="$(bash "$SCRIPT" edges "$WORK/edges.json" 2>"$WORK/edges.err")"
check "edges: consumes mention adds the edge" "1" "$(grep -c '^edge task-002 -> task-001$' "$WORK/edges.err")"
check "edges: existing edge and self-mention add nothing" "1" "$(grep -c '1 edge(s) inferred' "$WORK/edges.err")"
check "edges: stdout is the updated array" "task-001" "$(jq -r '.[1].blockedBy | join(",")' <<<"$out")"
check "edges: the file on disk is untouched byte-for-byte" "1" "$([[ "$before_edges" == "$(cat "$WORK/edges.json")" ]] && echo 1 || echo 0)"
after_edges_mtime="$(stat -c '%Y' "$WORK/edges.json" 2>/dev/null || stat -f '%m' "$WORK/edges.json")"
check "edges: the file's mtime never advances (never opened for write)" "$before_edges_mtime" "$after_edges_mtime"

cat > "$WORK/cycle.json" <<'EOF'
[
  {"id":"task-001","files":["a"],"blockedBy":["task-002"],"verifyCommand":"true","acceptanceCriteria":["a"]},
  {"id":"task-002","files":["b"],"blockedBy":[],"verifyCommand":"true","acceptanceCriteria":["b"],"goal":"needs task-001"}
]
EOF
before="$(cat "$WORK/cycle.json")"; ec=0; edges_cycle_out="$(bash "$SCRIPT" edges "$WORK/cycle.json" 2>/dev/null)" || ec=$?
check "edges: a cycle is refused" "1" "$ec"
check "edges: nothing printed on refusal" "" "$edges_cycle_out"
check "edges: nothing written on refusal" "1" "$([[ "$before" == "$(cat "$WORK/cycle.json")" ]] && echo 1 || echo 0)"

# A registered tasks.json (a real feature's, not a scratch file) must never be written
# by `edges` either -- the whole point of moving the write into the driver's publish.
REG_WORK="${TMPDIR:-/tmp}/plan-conflicts-registered-test.$$"
mkdir -p "$REG_WORK/.loop-spec/features/rt"
REG_FD="$REG_WORK/.loop-spec/features/rt"
cp "$WORK/edges.json" "$REG_FD/tasks.json"
printf '{"schemaVersion":7,"slug":"rt","artifacts":{}}' > "$REG_FD/feature.json"
before_reg="$(cat "$REG_FD/tasks.json")"
bash "$SCRIPT" edges "$REG_FD/tasks.json" >/dev/null 2>&1
check "edges: a registered feature's tasks.json is never written in place" "1" \
  "$([[ "$before_reg" == "$(cat "$REG_FD/tasks.json")" ]] && echo 1 || echo 0)"
rm -rf "$REG_WORK"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
