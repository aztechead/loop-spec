#!/usr/bin/env bash
# Tests for lib/issue-intake.sh (fixture + dry-run — offline, no gh/claude)
set -uo pipefail

LIB="$(cd "$(dirname "$0")/../.." && pwd)/lib/issue-intake.sh"
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

WORK="${TMPDIR:-/tmp}/loop-spec-issue-intake.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

FIXTURE="$WORK/issues.json"
cat > "$FIXTURE" << 'EOF'
[
  {"number": 10, "title": "Add rate limiting", "body": "Public API needs rate limits.", "labels": [{"name": "loop-spec"}]},
  {"number": 11, "title": "Already claimed", "body": "x", "labels": [{"name": "loop-spec"}, {"name": "loop-spec:in-progress"}]},
  {"number": 12, "title": "Already done", "body": "y", "labels": [{"name": "loop-spec"}, {"name": "loop-spec:done"}]},
  {"number": 13, "title": "Second eligible", "body": "z", "labels": [{"name": "loop-spec"}]}
]
EOF

# ── Case 1: dry-run plans only eligible issues, respects limit=1 ──────────────
out="$(bash "$LIB" run --fixture "$FIXTURE" --dry-run)"
check "1: plans issue 10" "1" "$(grep -c 'DRY-RUN issue #10' <<<"$out")"
check "1: limit 1 excludes issue 13" "0" "$(grep -c 'issue #13' <<<"$out")"
check "1: lifecycle-labeled 11 skipped" "0" "$(grep -c 'issue #11' <<<"$out")"
check "1: done-labeled 12 skipped" "0" "$(grep -c 'issue #12' <<<"$out")"
check "1: plan includes intake invocation" "1" "$(grep -c 'loop-spec:intake autonomous' <<<"$out")"
check "1: plan includes claim label step" "1" "$(grep -c 'add-label loop-spec:in-progress' <<<"$out")"
check "1: plan includes result contract read" "1" "$(grep -c 'last-result.json' <<<"$out")"

# ── Case 2: --limit 2 plans both eligible issues ──────────────────────────────
out="$(bash "$LIB" run --fixture "$FIXTURE" --dry-run --limit 2)"
check "2: plans issue 10" "1" "$(grep -c 'DRY-RUN issue #10' <<<"$out")"
check "2: plans issue 13" "1" "$(grep -c 'DRY-RUN issue #13' <<<"$out")"

# ── Case 3: all-claimed fixture → zero eligible, exit 0 ───────────────────────
cat > "$WORK/claimed.json" << 'EOF'
[{"number": 20, "title": "t", "body": "b", "labels": [{"name": "loop-spec"}, {"name": "loop-spec:failed"}]}]
EOF
ec=0
out="$(bash "$LIB" run --fixture "$WORK/claimed.json" --dry-run)" || ec=$?
check "3: exit 0" "0" "$ec"
check "3: reports none eligible" "1" "$(grep -c 'no eligible' <<<"$out")"

# ── Case 4: bad invocations ───────────────────────────────────────────────────
ec=0; bash "$LIB" bogus >/dev/null 2>&1 || ec=$?
check "4: unknown subcommand exit 2" "2" "$ec"
ec=0; bash "$LIB" run --fixture "$WORK/nope.json" --dry-run >/dev/null 2>&1 || ec=$?
check "4: missing fixture exit 2" "2" "$ec"
ec=0; bash "$LIB" run --fixture "$FIXTURE" --limit abc --dry-run >/dev/null 2>&1 || ec=$?
check "4: non-numeric limit exit 2" "2" "$ec"
echo 'not json' > "$WORK/bad.json"
ec=0; bash "$LIB" run --fixture "$WORK/bad.json" --dry-run >/dev/null 2>&1 || ec=$?
check "4: corrupt fixture exit 2" "2" "$ec"

# ── Case 5: custom claude flags surface in the dry-run plan ───────────────────
out="$(LOOP_SPEC_ISSUE_INTAKE_CLAUDE_FLAGS="--permission-mode plan" bash "$LIB" run --fixture "$FIXTURE" --dry-run)"
check "5: custom flags in plan" "1" "$(grep -c -- '--permission-mode plan' <<<"$out")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
