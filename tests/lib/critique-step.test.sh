#!/usr/bin/env bash
# Tests for lib/critique-step.sh -- the critique gate's bookkeeping, one step per call.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STEP="$ROOT/lib/critique-step.sh"
WORK="${TMPDIR:-/tmp}/loop-spec-critique-step.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/feature" "$WORK/docs"
PASS=0; FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then echo "PASS: $name"; PASS=$((PASS + 1))
  else echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1)); fi
}
feat() { jq -r "$1" "$WORK/feature/feature.json"; }
FD="$WORK/feature"; ART="$WORK/docs/PLAN.md"

bash "$ROOT/lib/feature-init.sh" skeleton --mode single \
  --slug step-unit --now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --style auto --title "step test" \
  --branch feat/step-unit --base-sha deadbeef --base-branch main \
  --worktree "" --prepare "" --test "" --lint "" --typecheck "" > "$FD/feature.json"
printf '# Plan\n\n## Tasks\n\n- T1: add the endpoint\n- T2: write the CSV\n' > "$ART"

# --- open ---
rc=0; bash "$STEP" findings --feature-dir "$FD" --reply - <<<"FINDINGS:" >/dev/null 2>&1 || rc=$?
check "findings before open exits 1" "1" "$rc"
out="$(bash "$STEP" open --feature-dir "$FD" --phase plan --gate plan-critique --artifact "$ART")"
check "open records the gate" "plan-critique" "$(feat '.currentGate.gate')"
check "open answers the absolute artifact path" "$ART" "$(jq -r '.artifact' <<<"$out")"
check "open writes the state sidecar" "1" "$([[ -f "$FD/gate-logs/plan-critique-state.json" ]] && echo 1 || echo 0)"

# --- findings ---
out="$(printf 'FINDINGS:\n1. [major] Gap: no retry budget\n\n2. [minor] wording in T2\n' \
  | bash "$STEP" findings --feature-dir "$FD" --reply -)"
check "findings counts round 1" "1" "$(feat '.currentGate.round')"
check "findings verdict" "findings" "$(jq -r '.verdict' <<<"$out")"
check "findings lines skip the header and blanks" "2" "$(jq '.lines | length' <<<"$out")"
check "findings gate-log written" "1" "$(grep -c 'Round 1 (single-critic)' "$FD/gate-logs/plan-critique-round-1.md")"
check "findings emits gate_round" "1" "$(grep -c '"gate_round"' "$FD/events.jsonl")"

# --- fail -> rerun (ceiling 1 leaves one delta round) ---
out="$(printf '[major] Gap: no retry budget\n' | bash "$STEP" fail --feature-dir "$FD" --fix-list -)"
check "fail answers rerun inside the ceiling" "rerun" "$(jq -r '.answer' <<<"$out")"
check "fail numbers the fix-list for the author" "1. [major] Gap: no retry budget" "$(jq -r '.fixList' <<<"$out")"
check "fail snapshots the artifact" "1" "$([[ -f "$FD/gate-logs/PLAN.pre-revision.md" ]] && echo 1 || echo 0)"
check "fail records the entry with the items verbatim" "[major] Gap: no retry budget" \
  "$(feat '.gateHistory[-1].findingsAddressed[0]')"
check "fail keeps the gate open" "plan-critique" "$(feat '.currentGate.gate')"

# --- revised ---
printf '# Plan\n\n## Tasks\n\n- T1: add the endpoint with a retry budget of 3\n- T2: write the CSV\n' > "$ART"
out="$(bash "$STEP" revised --feature-dir "$FD")"
check "revised sees the change" "true" "$(jq -r '.changed' <<<"$out")"
check "revised carries the diff" "1" "$(jq -r '.diff' <<<"$out" | grep -c '^+- T1: add the endpoint with a retry budget of 3')"
check "revised repeats the fix-list" "1. [major] Gap: no retry budget" "$(jq -r '.fixList' <<<"$out")"
check "revised writes the diff file" "1" "$([[ -s "$FD/gate-logs/plan-critique-delta.diff" ]] && echo 1 || echo 0)"

# --- delta with survivors: unaddressed kept, out-of-scope dropped, FLAG added ---
printf 'FLAG [feasibility] task-002 has no verifyCommand\n' > "$WORK/flags.txt"
out="$(printf 'DELTA-FINDINGS:\n1. unaddressed: 1 - the budget is named but never enforced\n2. [major] Gap: T2 has no schema\n' \
  | bash "$STEP" delta --feature-dir "$FD" --reply - --flags "$WORK/flags.txt")"
check "delta counts round 2" "2" "$(jq -r '.round' <<<"$out")"
check "delta is not verified with survivors" "false" "$(jq -r '.verified' <<<"$out")"
check "delta keeps the unaddressed line and the FLAG, drops the first-pass finding" "2" "$(jq '.survivors | length' <<<"$out")"
check "delta survivors carry the FLAG line" "1" "$(jq -r '.survivors[]' <<<"$out" | grep -c '^FLAG \[feasibility\]')"
check "delta gate-log carries the DROP line" "1" "$(grep -c 'out-of-scope' "$FD/gate-logs/plan-critique-round-2.md")"
check "delta with survivors keeps the gate open" "plan-critique" "$(feat '.currentGate.gate')"

# --- fail -> close at the ceiling ---
out="$(jq -r '.survivors[]' <<<"$out" | bash "$STEP" fail --feature-dir "$FD" --fix-list -)"
check "second fail closes at the ceiling" "close" "$(jq -r '.answer' <<<"$out")"
check "close names the ceiling" "1" "$(jq -r '.reason' <<<"$out" | grep -c 'ceiling')"
check "close writes the residue file" "1" "$(grep -c '^- unaddressed: 1' "$FD/gate-logs/plan-critique-residue.md")"
check "close appends the cap-reached pass entry" "cap-reached" "$(feat '.gateHistory[-1].convergence')"
check "close resets the gate" "null" "$(feat '.currentGate.phase')"

# --- a clean delta passes by itself ---
bash "$STEP" open --feature-dir "$FD" --phase plan --gate plan-critique --artifact "$ART" >/dev/null
printf 'FINDINGS:\n1. [major] Gap: no schema\n' | bash "$STEP" findings --feature-dir "$FD" --reply - >/dev/null
printf '[major] Gap: no schema\n' | bash "$STEP" fail --feature-dir "$FD" --fix-list - >/dev/null
printf '# Plan\n\n## Tasks\n\n- T1: add the endpoint with a retry budget of 3\n- T2: write the CSV with the schema in lib/schema.py\n' > "$ART"
bash "$STEP" revised --feature-dir "$FD" >/dev/null
out="$(printf 'DELTA-VERIFIED: both addressed\n' | bash "$STEP" delta --feature-dir "$FD" --reply -)"
check "verified delta answers verified" "true" "$(jq -r '.verified' <<<"$out")"
check "verified delta appends the delta-verified pass entry" "delta-verified" "$(feat '.gateHistory[-1].convergence')"
check "verified delta closes the gate" "null" "$(feat '.currentGate.phase')"

# --- no findings, no flags: pass ---
bash "$STEP" open --feature-dir "$FD" --phase plan --gate plan-critique --artifact "$ART" >/dev/null
out="$(printf 'NO-FINDINGS: the plan is complete\n' | bash "$STEP" findings --feature-dir "$FD" --reply -)"
check "no-findings verdict" "no-findings" "$(jq -r '.verdict' <<<"$out")"
rc=0; printf '\n' | bash "$STEP" fail --feature-dir "$FD" --fix-list - >/dev/null 2>&1 || rc=$?
check "fail with an empty fix-list is refused" "1" "$rc"
out="$(bash "$STEP" pass --feature-dir "$FD")"
check "pass records single-critic" "single-critic" "$(feat '.gateHistory[-1].convergence')"
check "pass closes the gate" "null" "$(feat '.currentGate.phase')"

# --- bad invocation ---
rc=0; bash "$STEP" open --feature-dir "$FD" --phase plan >/dev/null 2>&1 || rc=$?
check "open without a gate and artifact exits 2" "2" "$rc"
rc=0; bash "$STEP" bogus --feature-dir "$FD" >/dev/null 2>&1 || rc=$?
check "unknown step exits 2" "2" "$rc"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
