#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/lib/project-commands.sh"
PASS=0
FAIL=0

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1))
    echo "PASS: $label"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $label (expected '$expected', got '$actual')"
  fi
}

run_resolve() {
  env -u LOOP_SPEC_CMD_PREPARE -u LOOP_SPEC_CMD_TEST \
    -u LOOP_SPEC_CMD_LINT -u LOOP_SPEC_CMD_TYPECHECK \
    "$@" bash "$SCRIPT" resolve \
      --prepare "detected prepare" \
      --test "detected test" \
      --lint "detected lint" \
      --typecheck "detected typecheck"
}

out="$(run_resolve)"
check "detected prepare retained" "detected prepare" "$(jq -r '.prepare' <<<"$out")"
check "detected test retained" "detected test" "$(jq -r '.test' <<<"$out")"
check "detected lint retained" "detected lint" "$(jq -r '.lint' <<<"$out")"
check "detected typecheck retained" "detected typecheck" "$(jq -r '.typecheck' <<<"$out")"

out="$(run_resolve \
  LOOP_SPEC_CMD_PREPARE="pinned prepare" \
  LOOP_SPEC_CMD_TEST="pinned test" \
  LOOP_SPEC_CMD_LINT="pinned lint" \
  LOOP_SPEC_CMD_TYPECHECK="pinned typecheck")"
check "prepare override wins" "pinned prepare" "$(jq -r '.prepare' <<<"$out")"
check "test override wins" "pinned test" "$(jq -r '.test' <<<"$out")"
check "lint override wins" "pinned lint" "$(jq -r '.lint' <<<"$out")"
check "typecheck override wins" "pinned typecheck" "$(jq -r '.typecheck' <<<"$out")"

out="$(run_resolve \
  LOOP_SPEC_CMD_PREPARE= \
  LOOP_SPEC_CMD_TEST= \
  LOOP_SPEC_CMD_LINT= \
  LOOP_SPEC_CMD_TYPECHECK=)"
check "empty prepare disables" "" "$(jq -r '.prepare' <<<"$out")"
check "empty test disables" "" "$(jq -r '.test' <<<"$out")"
check "empty lint disables" "" "$(jq -r '.lint' <<<"$out")"
check "empty typecheck disables" "" "$(jq -r '.typecheck' <<<"$out")"

rc=0
bash "$SCRIPT" resolve --prepare p --test t --lint l >/dev/null 2>&1 || rc=$?
check "missing slot rejected" "2" "$rc"

rc=0
bash "$SCRIPT" resolve --prepare p --test t --lint l --typecheck y --bogus z >/dev/null 2>&1 || rc=$?
check "unknown argument rejected" "2" "$rc"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
