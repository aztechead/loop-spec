#!/usr/bin/env bash
# Tests for lib/task-batch.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/lib/task-batch.sh"
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

WORK="${TMPDIR:-/tmp}/task-batch-test.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

cat > "$WORK/collapse.json" <<'EOF'
[
  {"id":"task-001","brief":"rename in a","files":["a.sh"],"blockedBy":[],
   "verifyCommand":"bash -n a.sh","acceptanceCriteria":["ok"],"batchGroup":"rename"},
  {"id":"task-002","brief":"rename in b","files":["b.sh"],"blockedBy":[],
   "verifyCommand":"bash -n a.sh","acceptanceCriteria":["ok"],"batchGroup":"rename"},
  {"id":"task-003","brief":"other","files":["c.sh"],"blockedBy":[],
   "verifyCommand":"true","acceptanceCriteria":["ok"]}
]
EOF
out=$(bash "$SCRIPT" collapse "$WORK/collapse.json")
check "collapse count" "2" "$(jq 'length' <<<"$out")"
check "keeps first id" "task-001" "$(jq -r '.[0].id' <<<"$out")"
check "unions files" "a.sh,b.sh" "$(jq -r '.[0].files | join(",")' <<<"$out")"
check "memberIds order" "task-001,task-002" "$(jq -r '.[0].memberIds | join(",")' <<<"$out")"
check "ungrouped passes through" "task-003" "$(jq -r '.[1].id' <<<"$out")"

cat > "$WORK/no-hint.json" <<'EOF'
[
  {"id":"task-001","files":["a.sh"],"blockedBy":[],"verifyCommand":"true","acceptanceCriteria":["ok"]},
  {"id":"task-002","files":["b.sh"],"blockedBy":[],"verifyCommand":"true","acceptanceCriteria":["ok"]}
]
EOF
out=$(bash "$SCRIPT" collapse "$WORK/no-hint.json")
check "no hint does not collapse" "2" "$(jq 'length' <<<"$out")"

cat > "$WORK/blocked.json" <<'EOF'
[
  {"id":"task-001","files":["a.sh"],"blockedBy":[],"verifyCommand":"true",
   "acceptanceCriteria":["ok"],"batchGroup":"g"},
  {"id":"task-002","files":["b.sh"],"blockedBy":["task-009"],"verifyCommand":"true",
   "acceptanceCriteria":["ok"],"batchGroup":"g"}
]
EOF
out=$(bash "$SCRIPT" collapse "$WORK/blocked.json")
check "blockedBy outside group does not collapse" "2" "$(jq 'length' <<<"$out")"

cat > "$WORK/verify.json" <<'EOF'
[
  {"id":"task-001","files":["a.sh"],"blockedBy":[],"verifyCommand":"bash -n a.sh",
   "acceptanceCriteria":["ok"],"batchGroup":"g"},
  {"id":"task-002","files":["b.sh"],"blockedBy":[],"verifyCommand":"bash -n b.sh",
   "acceptanceCriteria":["ok"],"batchGroup":"g"}
]
EOF
out=$(bash "$SCRIPT" collapse "$WORK/verify.json")
check "verifyCommand mismatch does not collapse" "2" "$(jq 'length' <<<"$out")"

cat > "$WORK/overlap.json" <<'EOF'
[
  {"id":"task-001","files":["shared.sh"],"blockedBy":[],"verifyCommand":"true",
   "acceptanceCriteria":["ok"],"batchGroup":"g"},
  {"id":"task-002","files":["shared.sh"],"blockedBy":[],"verifyCommand":"true",
   "acceptanceCriteria":["ok"],"batchGroup":"g"}
]
EOF
out=$(bash "$SCRIPT" collapse "$WORK/overlap.json")
check "overlapping files do not collapse" "2" "$(jq 'length' <<<"$out")"

ec=0; bash "$SCRIPT" >/dev/null 2>&1 || ec=$?
check "usage exits 2" "2" "$ec"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
