#!/usr/bin/env bash
# Tests for lib/execute-stop.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/lib/execute-stop.sh"
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

check "rm -rf is destructive" \
  "stop=true reason=destructive matched=rm -rf" \
  "$(bash "$SCRIPT" classify 'the task runs rm -rf /tmp/build')"

check "force-push is destructive" \
  "stop=true reason=destructive matched=force-push" \
  "$(bash "$SCRIPT" classify 'git push origin main --force')"

check "credentials is security" \
  "stop=true reason=security matched=credential" \
  "$(bash "$SCRIPT" classify 'this writes credentials to disk')"

check "git push is side-effect-outside" \
  "stop=true reason=side-effect-outside matched=push-origin" \
  "$(bash "$SCRIPT" classify 'then git push to origin')"

check "plan-broken override" \
  "stop=true reason=plan-broken matched=operator-override" \
  "$(bash "$SCRIPT" classify --plan-broken 'any text')"

check "file overlap is a ruling" \
  "stop=false reason=ruling matched=" \
  "$(bash "$SCRIPT" classify 'task-001 and task-002 share src/foo.sh')"

check "unknown text fails safe to ruling" \
  "stop=false reason=ruling matched=" \
  "$(bash "$SCRIPT" classify 'which error message wording should we use')"

ec=0; bash "$SCRIPT" >/dev/null 2>&1 || ec=$?
check "usage exits 2" "2" "$ec"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
