#!/usr/bin/env bash
# Tests for lib/pr-body.sh — the concise GFM PR body renderer.
# Contract: short, well-formed GitHub-flavored markdown. Bounded excerpts instead of
# inlined artifacts, no leaked H1s from artifact files, balanced code fences, and a
# hard size cap that never cuts mid-fence.
set -uo pipefail

LIB="$(cd "$(dirname "$0")/../.." && pwd)/lib/pr-body.sh"
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

WORK="${TMPDIR:-/tmp}/loop-spec-pr-body.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/docs/loop-spec/features/demo"
DOCS="$WORK/docs/loop-spec/features/demo"

cat > "$DOCS/SPEC.md" <<'EOF'
# Spec: Demo feature

## Summary

Adds a demo capability so users can demo things.
It is scoped to the demo module only.

## Acceptance criteria

- demo command exits 0
- demo output contains the marker

## Deep design notes

These notes are long and should NOT be inlined into the PR body.
EOF

cat > "$DOCS/VERIFICATION.md" <<'EOF'
# Verification

All checks pass: 42 tests, lint clean.

```text
tests: 42 passed
```
EOF

cat > "$DOCS/ITERATION.md" <<'EOF'
# Iteration

Converged after 1 round.
EOF

jq -n '{schemaVersion:7,slug:"demo",feature_title:"Demo feature",warnings:["one warning"],
  artifacts:{spec:"docs/loop-spec/features/demo/SPEC.md",
             verification:"docs/loop-spec/features/demo/VERIFICATION.md",
             iteration:"docs/loop-spec/features/demo/ITERATION.md"}}' > "$WORK/feature.json"

# ── Case 1: concise, well-formed body ────────────────────────────────────────
OUT="$WORK/body.md"
bash "$LIB" render "$WORK/feature.json" "$WORK" "$OUT"
check "1: renders" "0" "$?"
check "1: goal line present" "1" "$(grep -c '^\*\*Goal:\*\* Demo feature' "$OUT")"
check "1: summary excerpt present" "1" "$(grep -c 'demo capability' "$OUT")"
check "1: acceptance criteria present" "1" "$(grep -c 'demo command exits 0' "$OUT")"
check "1: verification excerpt present" "1" "$(grep -c '42 tests' "$OUT")"
check "1: convergence excerpt present" "1" "$(grep -c 'Converged' "$OUT")"
check "1: warning bullet present" "1" "$(grep -c -- '- one warning' "$OUT")"
check "1: artifact paths listed" "1" "$(grep -c 'docs/loop-spec/features/demo/SPEC.md' "$OUT")"
check "1: no artifact H1 leaks" "0" "$(grep -c '^# ' "$OUT")"
check "1: deep sections not inlined" "0" "$(grep -c 'Deep design notes' "$OUT")"
check "1: balanced code fences" "0" "$(( $(grep -c '^```' "$OUT") % 2 ))"

# ── Case 2: huge artifacts stay bounded ──────────────────────────────────────
{ echo '# Verification'; echo; for i in $(seq 1 3000); do echo "evidence line $i with some padding text"; done; } > "$DOCS/VERIFICATION.md"
bash "$LIB" render "$WORK/feature.json" "$WORK" "$OUT"
size="$(wc -c < "$OUT" | tr -d ' ')"
check "2: body stays under 10000 bytes" "1" "$([[ "$size" -le 10000 ]] && echo 1 || echo 0)"
check "2: truncation is announced" "1" "$(grep -c 'truncated' "$OUT" | awk '{print ($1>=1)?1:0}')"
check "2: still valid (goal survives)" "1" "$(grep -c '^\*\*Goal:\*\*' "$OUT")"

# ── Case 3: unbalanced fence in an artifact gets closed ──────────────────────
printf '# Verification\n\nresult ok\n\n```text\nunclosed fence\n' > "$DOCS/VERIFICATION.md"
bash "$LIB" render "$WORK/feature.json" "$WORK" "$OUT"
check "3: fences balanced after render" "0" "$(( $(grep -c '^```' "$OUT") % 2 ))"

# ── Case 4: missing artifacts degrade to a minimal body ──────────────────────
jq -n '{schemaVersion:7,slug:"bare",feature_title:"Bare",warnings:[],artifacts:{}}' > "$WORK/bare.json"
bash "$LIB" render "$WORK/bare.json" "$WORK" "$OUT"
check "4: renders without artifacts" "0" "$?"
check "4: goal still present" "1" "$(grep -c '^\*\*Goal:\*\* Bare' "$OUT")"

# ── Case 5: bad invocation ───────────────────────────────────────────────────
ec=0; bash "$LIB" render >/dev/null 2>&1 || ec=$?
check "5: missing args exit 2" "2" "$ec"
ec=0; bash "$LIB" bogus a b c >/dev/null 2>&1 || ec=$?
check "5: unknown subcommand exit 2" "2" "$ec"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
