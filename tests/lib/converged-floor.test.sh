#!/usr/bin/env bash
# Tests for lib/converged-floor.sh — convergence cannot be claimed over unverified scope.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/lib/converged-floor.sh"
PASS=0
FAIL=0

check() {
  local name="$1" cond="$2"
  if [[ "$cond" == "1" ]]; then PASS=$((PASS+1)); echo "PASS: $name"
  else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/converged-floor-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/SPEC.md" <<'EOF'
# Feature

## Success criteria

### Good Enough

- [ ] command exits 0
- [ ] output contains marker

### Exceptional

- [ ] blazing fast
EOF

cat > "$tmp/V.md" <<'EOF'
# Verification

## Repository grounding

- criterion: GE-001 | implementation: app.py:10 - exits 0 | integration: cli.py:3 - wired
- criterion: GE-002 | implementation: app.py:22 - marker | integration: none - single call site

## Acceptance criteria

| # | Criterion | Status | Evidence |
|---|-----------|--------|----------|
| 1 | command exits 0 | PASS | `run` -> 0 |
| 2 | output contains marker | PASS | `run` -> marker |
EOF

# Full coverage + all PASS -> floor holds.
bash "$LIB" "$tmp/SPEC.md" "$tmp/V.md" >/dev/null 2>&1
check "floor holds on full coverage (exit 0)" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"
out="$(bash "$LIB" "$tmp/SPEC.md" "$tmp/V.md" 2>/dev/null)"
check "answer line reports criteria count" "$(grep -q 'converged-floor: ok (2 criteria verified)' <<<"$out" && echo 1 || echo 0)"

# Exceptional criteria are NOT floored (only Good Enough gates).
check "exceptional not required" "$(grep -q 'GE-003' <<<"$out" && echo 0 || echo 1)"

# Missing grounding row -> violation naming the GE id.
grep -v 'GE-002' "$tmp/V.md" > "$tmp/V-missing.md"
out="$(bash "$LIB" "$tmp/SPEC.md" "$tmp/V-missing.md" 2>/dev/null)"; rc=$?
check "missing row vetoes convergence (exit 1)" "$([[ $rc -eq 1 ]] && echo 1 || echo 0)"
check "violation names the GE id" "$(grep -q 'FLOOR GE-002 has no grounding row' <<<"$out" && echo 1 || echo 0)"

# FAIL status in the acceptance table -> violation.
sed 's/| 2 | output contains marker | PASS |/| 2 | output contains marker | FAIL |/' "$tmp/V.md" > "$tmp/V-fail.md"
bash "$LIB" "$tmp/SPEC.md" "$tmp/V-fail.md" >/dev/null 2>&1
check "FAIL table row vetoes convergence" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"

# FAIL as a substring elsewhere (evidence text) does not veto.
sed 's/`run` -> marker/`run` -> no FAILURES seen/' "$tmp/V.md" > "$tmp/V-text.md"
bash "$LIB" "$tmp/SPEC.md" "$tmp/V-text.md" >/dev/null 2>&1
check "FAIL substring in evidence cell is not a status" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# Unreadable VERIFICATION.md with a Good Enough section -> fail closed.
bash "$LIB" "$tmp/SPEC.md" "$tmp/does-not-exist.md" >/dev/null 2>&1
check "missing VERIFICATION fails closed" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"

# No Good Enough section -> skipped (exit 0), consistent with criteria-coverage.
printf '# Feature\n\nno criteria here\n' > "$tmp/SPEC-none.md"
bash "$LIB" "$tmp/SPEC-none.md" "$tmp/does-not-exist.md" >/dev/null 2>&1
check "no Good Enough section skips" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# Missing spec -> fail-open skip (nothing to floor).
bash "$LIB" "$tmp/no-spec.md" "$tmp/V.md" >/dev/null 2>&1
check "missing spec skips" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# Bad invocation.
bash "$LIB" "$tmp/SPEC.md" >/dev/null 2>&1
check "missing args exit 2" "$([[ $? -eq 2 ]] && echo 1 || echo 0)"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
