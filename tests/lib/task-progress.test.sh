#!/usr/bin/env bash
# Tests for lib/task-progress.sh — done/remaining ids and mark-done persistence.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/lib/task-progress.sh"
WORK="${TMPDIR:-/tmp}/loop-spec-task-progress.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"
PASS=0; FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

cat > "$WORK/tasks.json" <<'EOF'
[
  {"id": "task-001", "brief": "one", "files": [], "blockedBy": [],
   "verifyCommand": "true", "acceptanceCriteria": ["ok"]},
  {"id": "task-002", "brief": "two", "files": [], "blockedBy": ["task-001"],
   "verifyCommand": "true", "acceptanceCriteria": ["ok"], "status": "done"},
  {"id": "task-003", "brief": "three", "files": [], "blockedBy": [],
   "verifyCommand": "true", "acceptanceCriteria": ["ok"], "status": "pending"}
]
EOF

check "no args is usage error" "2" "$(bash "$SCRIPT" >/dev/null 2>&1; echo $?)"
check "unknown subcommand is usage error" "2" "$(bash "$SCRIPT" list "$WORK/tasks.json" >/dev/null 2>&1; echo $?)"

done_ids="$(bash "$SCRIPT" done "$WORK/tasks.json")"
check "done lists only status=done" "task-002" "$done_ids"

remaining="$(bash "$SCRIPT" remaining "$WORK/tasks.json" | tr '\n' ' ')"
check "remaining is pending and unmarked" "task-001 task-003 " "$remaining"

bash "$SCRIPT" mark-done "$WORK/tasks.json" "task-001"
check "mark-done exits 0" "0" "$?"
check "marked id is now done" "task-001"$'\n'"task-002" "$(bash "$SCRIPT" done "$WORK/tasks.json")"
check "marked id leaves remaining" "task-003" "$(bash "$SCRIPT" remaining "$WORK/tasks.json")"
check "mark-done persisted status on the object" "done" \
  "$(jq -r '.[] | select(.id=="task-001") | .status' "$WORK/tasks.json")"

bash "$SCRIPT" mark-done "$WORK/tasks.json" "task-001"
check "mark-done is idempotent" "0" "$?"

rc=0; bash "$SCRIPT" mark-done "$WORK/tasks.json" "task-999" >/dev/null 2>&1 || rc=$?
check "unknown id is a finding" "1" "$rc"

rc=0; bash "$SCRIPT" done "$WORK/missing.json" >/dev/null 2>&1 || rc=$?
check "missing file is a finding" "1" "$rc"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
