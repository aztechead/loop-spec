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

# An empty Status cell (the oneshot skeleton before `verification run` observes the
# command) is a criterion nobody ran: a veto, never a pass (port audit 4, item 2).
sed 's/| 2 | output contains marker | PASS |/| 2 | output contains marker |  |/' "$tmp/V.md" > "$tmp/V-empty.md"
bash "$LIB" "$tmp/SPEC.md" "$tmp/V-empty.md" >/dev/null 2>&1
check "an empty Status cell vetoes convergence" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"
# The driver's own FAIL row shape: `| GE-002 | ... | FAIL | `cmd` -> exit 1 |`.
sed 's/| 2 | output contains marker | PASS | `run` -> marker |/| GE-002 | output contains marker | FAIL | `run` -> exit 1 |/' "$tmp/V.md" > "$tmp/V-driver-fail.md"
bash "$LIB" "$tmp/SPEC.md" "$tmp/V-driver-fail.md" >/dev/null 2>&1
check "a driver-written FAIL row (exit code evidence) vetoes convergence" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"
# FAIL as a substring elsewhere (evidence text) does not veto.
sed 's/`run` -> marker/`run` -> no FAILURES seen/' "$tmp/V.md" > "$tmp/V-text.md"
bash "$LIB" "$tmp/SPEC.md" "$tmp/V-text.md" >/dev/null 2>&1
check "FAIL substring in evidence cell is not a status" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# Unreadable VERIFICATION.md with a Good Enough section -> fail closed.
bash "$LIB" "$tmp/SPEC.md" "$tmp/does-not-exist.md" >/dev/null 2>&1
check "missing VERIFICATION fails closed" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"

# A missing contract cannot justify convergence.
printf '# Feature\n\nno criteria here\n' > "$tmp/SPEC-none.md"
bash "$LIB" "$tmp/SPEC-none.md" "$tmp/does-not-exist.md" >/dev/null 2>&1
check "no Good Enough section fails closed" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"

# Missing spec -> fail-open skip (nothing to floor).
bash "$LIB" "$tmp/no-spec.md" "$tmp/V.md" >/dev/null 2>&1
check "missing spec fails closed" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"

for status in PENDING SKIP UNKNOWN; do
  sed "s/| 2 | output contains marker | PASS |/| 2 | output contains marker | $status |/" "$tmp/V.md" > "$tmp/V-pending.md"
  bash "$LIB" "$tmp/SPEC.md" "$tmp/V-pending.md" >/dev/null 2>&1
  check "$status acceptance cannot converge" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"
done
grep -v '^| 2 |' "$tmp/V.md" > "$tmp/V-no-result.md"
bash "$LIB" "$tmp/SPEC.md" "$tmp/V-no-result.md" >/dev/null 2>&1
check "grounding without an acceptance result cannot converge" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"

# The verifier's real table shape (6.3.0 fastapi runs): a Result column after the verify
# command, PASS with a parenthetical, an escaped pipe inside a cell, and GE ids as keys.
cat > "$tmp/V-wide.md" <<'EOF'
# Verification

## Repository grounding

- criterion: GE-001 | implementation: app.py:10 - exits 0 | integration: cli.py:3 - wired
- criterion: GE-002 | implementation: app.py:22 - marker | integration: none - single call site

## Acceptance criteria

| # | Criterion | Verify command | Result |
| --- | --- | --- | --- |
| GE-001 | command exits 0 | `run \| grep -c ok` | PASS (12 passed) |
| GE-002 | output contains marker | `run` | **PASS** |
EOF
out="$(bash "$LIB" "$tmp/SPEC.md" "$tmp/V-wide.md" 2>/dev/null)"; rc=$?
check "Result column found by header, PASS prefix and escaped pipe read (exit 0)" "$([[ $rc -eq 0 ]] && echo 1 || echo 0)"
check "wide table answer line" "$(grep -q 'converged-floor: ok (2 criteria verified)' <<<"$out" && echo 1 || echo 0)"
sed 's/| PASS (12 passed) |/| FAIL (1 failed) |/' "$tmp/V-wide.md" > "$tmp/V-wide-fail.md"
out="$(bash "$LIB" "$tmp/SPEC.md" "$tmp/V-wide-fail.md" 2>/dev/null)"; rc=$?
check "FAIL prefix in the Result column vetoes" "$([[ $rc -eq 1 ]] && echo 1 || echo 0)"
check "FAIL veto names the row key" "$(grep -q 'FLOOR acceptance table row still FAIL: GE-001' <<<"$out" && echo 1 || echo 0)"
# lib/iterate-judged.sh routes a floor veto to VERIFY or EXECUTE by this literal; the
# two files share it and neither may drift alone (port audit 1, F10).
check "the judge reads the same literal the floor emits" "$([[ "$(grep -c "still FAIL" "$REPO_ROOT/lib/iterate-judged.sh")" -ge 1 && "$(grep -c "row still FAIL" "$REPO_ROOT/lib/converged-floor.sh")" -ge 1 ]] && echo 1 || echo 0)"
printf '| GE-002 | dup | `run` | PASS |\n' >> "$tmp/V-wide.md"
out="$(bash "$LIB" "$tmp/SPEC.md" "$tmp/V-wide.md" 2>/dev/null)"
check "duplicate rows for one criterion veto with the count" "$(grep -q 'FLOOR GE-002 acceptance result is duplicate (2 acceptance rows' <<<"$out" && echo 1 || echo 0)"

# --shape: VERIFY's exit checks the grammar only; FAIL and N/A are readable results.
sed 's/| PASS (12 passed) |/| FAIL (1 failed) |/; s/| \*\*PASS\*\* |/| N\/A - no marker on this platform |/' "$tmp/V-wide.md" | grep -v '| dup |' > "$tmp/V-shape.md"
out="$(bash "$LIB" --shape "$tmp/SPEC.md" "$tmp/V-shape.md" 2>/dev/null)"; rc=$?
check "--shape accepts FAIL and N/A rows (exit 0)" "$([[ $rc -eq 0 ]] && echo 1 || echo 0)"
check "--shape answer line" "$(grep -q 'converged-floor: shape ok (2 criteria)' <<<"$out" && echo 1 || echo 0)"
sed 's/| FAIL (1 failed) |/| passed |/' "$tmp/V-shape.md" > "$tmp/V-shape-bad.md"
out="$(bash "$LIB" --shape "$tmp/SPEC.md" "$tmp/V-shape-bad.md" 2>/dev/null)"; rc=$?
check "--shape rejects a status cell that does not begin with PASS/FAIL/N/A" "$([[ $rc -eq 1 ]] && echo 1 || echo 0)"
check "--shape names the unreadable cell" "$(grep -q "FLOOR GE-001 acceptance result is unreadable (status cell 'passed' must begin with PASS, FAIL, BLOCKED, or N/A)" <<<"$out" && echo 1 || echo 0)"
grep -v '^| GE-002' "$tmp/V-shape.md" > "$tmp/V-shape-missing.md"
out="$(bash "$LIB" --shape "$tmp/SPEC.md" "$tmp/V-shape-missing.md" 2>/dev/null)"; rc=$?
check "--shape rejects a criterion with no row" "$([[ $rc -eq 1 ]] && echo 1 || echo 0)"
check "--shape names the missing key" "$(grep -q 'FLOOR GE-002 acceptance result is missing (no acceptance row keyed GE-002 or 2)' <<<"$out" && echo 1 || echo 0)"
grep -v 'criterion: GE-002' "$tmp/V-shape.md" > "$tmp/V-shape-ungrounded.md"
bash "$LIB" --shape "$tmp/SPEC.md" "$tmp/V-shape-ungrounded.md" >/dev/null 2>&1
check "--shape leaves grounding rows to verification-grounding-lint (exit 0)" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# Bad invocation.
bash "$LIB" "$tmp/SPEC.md" >/dev/null 2>&1
check "missing args exit 2" "$([[ $? -eq 2 ]] && echo 1 || echo 0)"


# BLOCKED is a status that cannot converge; PASS whose evidence says the check never
# ran is the live relabeling this floor now refuses.
sed 's/| 2 | output contains marker | PASS | `run` -> marker |/| 2 | output contains marker | BLOCKED | `run` -> gcloud reauth needed |/' "$tmp/V.md" > "$tmp/V-blocked.md"
out="$(bash "$LIB" "$tmp/SPEC.md" "$tmp/V-blocked.md" 2>/dev/null)"; rc=$?
check "BLOCKED row vetoes convergence" "$([[ $rc -eq 1 ]] && echo 1 || echo 0)"
check "BLOCKED row names the operator" "$(grep -q 'BLOCKED (an operator must clear it' <<<"$out" && echo 1 || echo 0)"
sed 's/| 2 | output contains marker | PASS | `run` -> marker |/| 2 | output contains marker | PASS | plan invocation is blocked-not-failed by the reauth lock, an explicit SPEC allowance |/' "$tmp/V.md" > "$tmp/V-relabeled.md"
out="$(bash "$LIB" "$tmp/SPEC.md" "$tmp/V-relabeled.md" 2>/dev/null)"; rc=$?
check "PASS with blocked evidence vetoes convergence" "$([[ $rc -eq 1 ]] && echo 1 || echo 0)"
check "PASS with blocked evidence says to mark it BLOCKED" "$(grep -q 'mark it BLOCKED' <<<"$out" && echo 1 || echo 0)"
sed 's/| 2 | output contains marker | PASS | `run` -> marker |/| 2 | output contains marker | PASS | `run` -> marker; the unblocked path is covered too |/' "$tmp/V.md" > "$tmp/V-word.md"
bash "$LIB" "$tmp/SPEC.md" "$tmp/V-word.md" >/dev/null 2>&1
check "the word unblocked in evidence is not a blocked check" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
