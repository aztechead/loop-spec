#!/usr/bin/env bash
# Unit tests for lib/pr-feedback.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/lib/pr-feedback.sh"
PASS=0
FAIL=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then echo "PASS: $name"; ((PASS++)) || true
  else echo "FAIL: $name (expected '$expected', got '$actual')"; ((FAIL++)) || true; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo '{"reviewDecision":"APPROVED"}' > "$WORK/clean.json"

out="$(bash "$SCRIPT" check --fixture "$WORK/clean.json")"
check "local mode completes" "complete" "$(jq -r '.observationStatus' <<<"$out")"
check "local owner" "loop-spec" "$(jq -r '.owner' <<<"$out")"
check "local decision retained" "APPROVED" "$(jq -r '.reviewDecision' <<<"$out")"

out="$(LOOP_SPEC_PR_FEEDBACK_MODE=external LOOP_SPEC_PR_FEEDBACK_OWNER=coder-service \
  bash "$SCRIPT" check 42)"
check "external mode delegates" "delegated" "$(jq -r '.observationStatus' <<<"$out")"
check "external owner recorded" "coder-service" "$(jq -r '.owner' <<<"$out")"
check "external never claims clean" "null" "$(jq -r '.reviewDecision' <<<"$out")"

out="$(bash "$SCRIPT" check --fixture "$WORK/missing.json")"
check "failed observation degrades" "degraded" "$(jq -r '.observationStatus' <<<"$out")"
check "degraded never claims clean" "null" "$(jq -r '.reviewDecision' <<<"$out")"

rc=0
LOOP_SPEC_PR_FEEDBACK_MODE=off bash "$SCRIPT" check 42 >/dev/null 2>&1 || rc=$?
check "unsupported off mode rejected" "2" "$rc"

jq -n '{targets:[{name:"demo",prNumber:42}]}' > "$WORK/delivery.json"
feedback='{"schema":1,"observationStatus":"delegated","owner":"coder-service"}'
bash "$SCRIPT" record "$WORK/delivery.json" demo "$feedback"
check "record persists observation" "delegated" "$(jq -r '.targets[0].feedback.observationStatus' "$WORK/delivery.json")"
check "record persists owner" "coder-service" "$(jq -r '.targets[0].feedback.owner' "$WORK/delivery.json")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
