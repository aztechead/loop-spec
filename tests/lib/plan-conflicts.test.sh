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
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
