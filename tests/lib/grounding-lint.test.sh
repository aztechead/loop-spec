#!/usr/bin/env bash
# Tests for lib/grounding-lint.sh -- validates ## Grounding sections.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/lib/grounding-lint.sh"
PASS=0
FAIL=0

check() {
  local name="$1" cond="$2"
  if [[ "$cond" == "1" ]]; then PASS=$((PASS+1)); echo "PASS: $name"
  else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi
}

WORK="${TMPDIR:-/tmp}/grounding-lint-test.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

# ─── Helper: run lint and capture exit code safely ─────────────────────────
lint_exit() {
  bash "$LIB" "$@" >/dev/null 2>&1
  printf '%s' "$?"
}
lint_stdout() {
  bash "$LIB" "$@" 2>/dev/null || true
}

# ─── Fixture 1: plain - none ────────────────────────────────────────────────
cat > "$WORK/plain-none.md" <<'EOF'
# Test artifact

## Grounding

- none
EOF
check "plain '- none' exits 0" "$([[ "$(lint_exit "$WORK/plain-none.md")" == "0" ]] && echo 1 || echo 0)"

# ─── Fixture 2: template block (byte-identical to pinned template) ───────────
# This is the exact block from the pinned interface — must exit 0.
cat > "$WORK/template-block.md" <<'EOF'
# Test artifact

## Grounding

<!-- Probe-before-assert (skills/shared/grounding-protocol.md): every load-bearing
     fact about an external system (dataset, API, service, infra) must cite an
     EVIDENCE.md entry (EVID-NNN) or be an explicit ASSUMPTION with a verify probe.
     Keep the single `- none` line if nothing external is load-bearing. -->
- none
EOF
check "template block (4-line comment + - none) exits 0" \
  "$([[ "$(lint_exit "$WORK/template-block.md")" == "0" ]] && echo 1 || echo 0)"

# ─── Fixture 3: ASSUMPTION with | inside the verify command ─────────────────
cat > "$WORK/assumption-pipe.md" <<'EOF'
# Test artifact

## Grounding

- ASSUMPTION: the table has a date column | verify: psql -c '\d mytable' | grep date
EOF
check "ASSUMPTION with | in verify command exits 0" \
  "$([[ "$(lint_exit "$WORK/assumption-pipe.md")" == "0" ]] && echo 1 || echo 0)"

# ─── Fixture 4: resolved EVID ref + well-formed ASSUMPTION ──────────────────
ledger4="$WORK/EVIDENCE-4.md"
cat > "$ledger4" <<'EOF'
# Evidence ledger
- EVID-001 | 2026-07-02T12:00:00Z | claim: dataset partitioned by day | cmd: bq show proj:ds.t | out: partitionField: date
EOF
cat > "$WORK/evid-resolved.md" <<'EOF'
# Test artifact

Uses EVID-001 for the partition claim.

## Grounding

- EVID-001: dataset partitioned by date column (see ledger)
- ASSUMPTION: the dataset exists in US region | verify: gcloud config get-value compute/region
EOF
check "EVID ref resolved in ledger + ASSUMPTION exits 0" \
  "$([[ "$(lint_exit "$WORK/evid-resolved.md" "$ledger4")" == "0" ]] && echo 1 || echo 0)"

# ─── Fixture 5: UNVERIFIED outside ## Grounding section -> exit 0 ───────────
cat > "$WORK/unverified-outside.md" <<'EOF'
# Test artifact

The value UNVERIFIED appears in the body but NOT inside the grounding section.
This must not be flagged.

## Grounding

- none

## Next steps

Still UNVERIFIED in post-section prose.
EOF
check "whole-word UNVERIFIED outside section does not flag (exits 0)" \
  "$([[ "$(lint_exit "$WORK/unverified-outside.md")" == "0" ]] && echo 1 || echo 0)"

# ─── Fixture 6: missing ## Grounding section -> FLAG :0: + exit 1 ───────────
cat > "$WORK/missing-section.md" <<'EOF'
# Test artifact

## Goals

Some goals here.

## Out of scope

Stuff out of scope.
EOF
ec=$(lint_exit "$WORK/missing-section.md")
check "missing section exits 1" "$([[ "$ec" == "1" ]] && echo 1 || echo 0)"
out6=$(lint_stdout "$WORK/missing-section.md")
check "missing section FLAG uses line 0" "$(echo "$out6" | grep -q 'FLAG.*:0:' && echo 1 || echo 0)"

# ─── Fixture 7: malformed bullet -> FLAG + exit 1 ───────────────────────────
cat > "$WORK/malformed.md" <<'EOF'
# Test artifact

## Grounding

- this is not a valid grounding bullet format
EOF
ec7=$(lint_exit "$WORK/malformed.md")
check "malformed bullet exits 1" "$([[ "$ec7" == "1" ]] && echo 1 || echo 0)"
out7=$(lint_stdout "$WORK/malformed.md")
check "malformed bullet FLAG present" "$(echo "$out7" | grep -q 'FLAG' && echo 1 || echo 0)"

# ─── Fixture 8: unresolved EVID ref -> FLAG + exit 1 ───────────────────────
# No ledger provided (default: EVIDENCE.md next to artifact, which doesn't exist)
cat > "$WORK/evid-unresolved.md" <<'EOF'
# Test artifact

This artifact references EVID-001 but there is no ledger.

## Grounding

- EVID-001: some claim with no backing ledger entry
EOF
ec8=$(lint_exit "$WORK/evid-unresolved.md")
check "unresolved EVID ref exits 1" "$([[ "$ec8" == "1" ]] && echo 1 || echo 0)"
out8=$(lint_stdout "$WORK/evid-unresolved.md")
check "unresolved EVID ref FLAG present" "$(echo "$out8" | grep -q 'FLAG' && echo 1 || echo 0)"
check "unresolved EVID ref FLAG names the token" "$(echo "$out8" | grep -q 'EVID-001' && echo 1 || echo 0)"

# ─── Fixture 9: ASSUMPTION with bash-n-failing verify cmd -> FLAG + exit 1 ──
cat > "$WORK/bad-verify.md" <<'EOF'
# Test artifact

## Grounding

- ASSUMPTION: some claim | verify: if [
EOF
ec9=$(lint_exit "$WORK/bad-verify.md")
check "bash-n-failing verify cmd exits 1" "$([[ "$ec9" == "1" ]] && echo 1 || echo 0)"
out9=$(lint_stdout "$WORK/bad-verify.md")
check "bash-n-failing verify cmd FLAG present" "$(echo "$out9" | grep -q 'FLAG' && echo 1 || echo 0)"

# ─── Fixture 10: whole-word UNVERIFIED inside section -> FLAG + exit 1 ──────
cat > "$WORK/unverified-inside.md" <<'EOF'
# Test artifact

## Grounding

- UNVERIFIED
EOF
ec10=$(lint_exit "$WORK/unverified-inside.md")
check "UNVERIFIED inside section exits 1" "$([[ "$ec10" == "1" ]] && echo 1 || echo 0)"
out10=$(lint_stdout "$WORK/unverified-inside.md")
check "UNVERIFIED inside section FLAG present" "$(echo "$out10" | grep -q 'FLAG' && echo 1 || echo 0)"

# Also: whole word in a regular line (not a bullet) inside section
cat > "$WORK/unverified-line.md" <<'EOF'
# Test artifact

## Grounding

State is UNVERIFIED at this time.

- none
EOF
ec10b=$(lint_exit "$WORK/unverified-line.md")
check "UNVERIFIED in non-bullet line inside section exits 1" "$([[ "$ec10b" == "1" ]] && echo 1 || echo 0)"

# ─── Fixture 11: - none coexists with EVID bullet -> FLAG + exit 1 ──────────
ledger11="$WORK/EVIDENCE-11.md"
cat > "$ledger11" <<'EOF'
# Evidence ledger
- EVID-001 | 2026-07-02T12:00:00Z | claim: test | cmd: echo test | out: test
EOF
cat > "$WORK/none-plus-evid.md" <<'EOF'
# Test artifact

## Grounding

- none
- EVID-001: contradicts the none above
EOF
ec11=$(lint_exit "$WORK/none-plus-evid.md" "$ledger11")
check "- none + EVID bullet contradiction exits 1" "$([[ "$ec11" == "1" ]] && echo 1 || echo 0)"
out11=$(lint_stdout "$WORK/none-plus-evid.md" "$ledger11")
check "- none + EVID contradiction FLAG present" "$(echo "$out11" | grep -q 'FLAG' && echo 1 || echo 0)"

# Also check: - none + ASSUMPTION contradiction
cat > "$WORK/none-plus-assumption.md" <<'EOF'
# Test artifact

## Grounding

- none
- ASSUMPTION: some external claim | verify: echo ok
EOF
ec11b=$(lint_exit "$WORK/none-plus-assumption.md")
check "- none + ASSUMPTION contradiction exits 1" "$([[ "$ec11b" == "1" ]] && echo 1 || echo 0)"

# ─── Fixture 12: FLAG lines carry real line numbers ─────────────────────────
cat > "$WORK/linenos.md" <<'EOF'
# Line 1
# Line 2
# Line 3

## Grounding

- bad format bullet here
EOF
# "- bad format bullet here" is on line 7
out12=$(lint_stdout "$WORK/linenos.md")
check "FLAG line carries line number 7" "$(echo "$out12" | grep -q 'FLAG.*:7:' && echo 1 || echo 0)"

# ─── Fixture 13: missing artifact -> stderr + exit 1 ────────────────────────
ec13=$(lint_exit "$WORK/does-not-exist.md")
check "missing artifact exits 1" "$([[ "$ec13" == "1" ]] && echo 1 || echo 0)"

# ─── Fixture 14: list also prints 'grounding-lint: ok' on stdout on success ─
stdout14=$(bash "$LIB" "$WORK/plain-none.md" 2>/dev/null)
check "exit 0 prints 'grounding-lint: ok'" "$(echo "$stdout14" | grep -q 'grounding-lint: ok' && echo 1 || echo 0)"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
