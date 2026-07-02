#!/usr/bin/env bash
# Tests for lib/autonomous-chain.sh (the autonomous continuation-chain predicate).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/lib/autonomous-chain.sh"
BACKLOG="$REPO_ROOT/lib/backlog.sh"
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

WORK="${TMPDIR:-/tmp}/autonomous-chain-test.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/feat"
export LOOP_SPEC_BACKLOG_FILE="$WORK/BACKLOG.md"
unset LOOP_SPEC_MAX_FEATURES 2>/dev/null || true

FEAT="$WORK/feat"

write_feature() {
  # write_feature <autonomous> <phase> <warnings_json>
  jq -n --argjson a "$1" --arg p "$2" --argjson w "$3" \
    '{autonomous: $a, currentPhase: $p, warnings: $w}' > "$FEAT/feature.json"
}

reason_of() { jq -r '.reason' <<<"$1"; }
chain_of()  { jq -r '.chain'  <<<"$1"; }

# bad invocation
ec=0; bash "$SCRIPT" should-chain "$WORK/nonexistent" >/dev/null 2>&1 || ec=$?
check "missing feature dir exits 1" "1" "$ec"
ec=0; bash "$SCRIPT" wrong-cmd "$FEAT" >/dev/null 2>&1 || ec=$?
check "unknown subcommand exits 1" "1" "$ec"

# not autonomous
write_feature false completed '["iterate-budget-spent: gap"]'
out="$(bash "$SCRIPT" should-chain "$FEAT")"
check "non-autonomous does not chain" "false" "$(chain_of "$out")"
check "non-autonomous reason" "not-autonomous" "$(reason_of "$out")"

# autonomous but paused/escalated (never chain past a failure)
write_feature true paused '["iterate-budget-spent: gap"]'
out="$(bash "$SCRIPT" should-chain "$FEAT")"
check "paused feature does not chain" "false" "$(chain_of "$out")"
check "paused reason" "feature-not-completed" "$(reason_of "$out")"

# completed but no budget-spent warnings
write_feature true completed '["some-other-warning: x"]'
out="$(bash "$SCRIPT" should-chain "$FEAT")"
check "no gaps reason" "no-budget-spent-gaps" "$(reason_of "$out")"

# gaps present but backlog empty
write_feature true completed '["iterate-budget-spent: csv gap"]'
out="$(bash "$SCRIPT" should-chain "$FEAT")"
check "empty backlog reason" "backlog-empty" "$(reason_of "$out")"

# happy path: gap queued, chain with the entry
gid="$(bash "$BACKLOG" gap-id "close the csv gap")"
bash "$BACKLOG" add feat-x iterate-gap "close the csv gap" --id "$gid" >/dev/null
out="$(bash "$SCRIPT" should-chain "$FEAT")"
check "chains when eligible" "true" "$(chain_of "$out")"
check "chain carries entry text" "close the csv gap" "$(jq -r '.entry.text' <<<"$out")"
check "chain carries entry id" "$gid" "$(jq -r '.entry.id' <<<"$out")"

# bound: completed >= LOOP_SPEC_MAX_FEATURES stops the chain
out="$(bash "$SCRIPT" should-chain "$FEAT" --completed 1)"
check "default max-features bound" "max-features-reached" "$(reason_of "$out")"
out="$(LOOP_SPEC_MAX_FEATURES=3 bash "$SCRIPT" should-chain "$FEAT" --completed 1)"
check "raised bound allows chain" "true" "$(chain_of "$out")"
out="$(LOOP_SPEC_MAX_FEATURES=3 bash "$SCRIPT" should-chain "$FEAT" --completed 3)"
check "raised bound still enforced" "max-features-reached" "$(reason_of "$out")"

# terminal id stops the chain
bash "$BACKLOG" terminal "$gid" "two budgets spent" >/dev/null
# backlog.sh add refuses to re-queue a terminal id (rung 5) …
check "terminal id not re-queued" "terminal" "$(bash "$BACKLOG" add feat-x iterate-gap "close the csv gap take 3" --id "$gid" 2>/dev/null)"
out="$(bash "$SCRIPT" should-chain "$FEAT")"
check "refused re-queue leaves backlog empty" "backlog-empty" "$(reason_of "$out")"
# … and if such an entry exists anyway (hand-edited file), the predicate still refuses:
printf -- '- [ ] (2026-01-01 feat-x iterate-gap id=%s) hand-edited resurrection\n' "$gid" >> "$(bash "$BACKLOG" path)"
out="$(bash "$SCRIPT" should-chain "$FEAT")"
check "terminal next entry does not chain" "false" "$(chain_of "$out")"
check "terminal reason" "next-entry-terminal" "$(reason_of "$out")"

# id-less next entry chains fine (nothing to terminal-match)
rm "$LOOP_SPEC_BACKLOG_FILE"
bash "$BACKLOG" add feat-y iterate-gap "an id-less gap" >/dev/null
out="$(bash "$SCRIPT" should-chain "$FEAT")"
check "id-less entry chains" "true" "$(chain_of "$out")"
check "id-less entry null id" "null" "$(jq -r '.entry.id' <<<"$out")"

# corrupted feature.json
echo "{ not json" > "$FEAT/feature.json"
ec=0; bash "$SCRIPT" should-chain "$FEAT" >/dev/null 2>&1 || ec=$?
check "invalid feature.json exits 1" "1" "$ec"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
