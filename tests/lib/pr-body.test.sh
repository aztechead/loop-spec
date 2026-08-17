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
             iteration:"docs/loop-spec/features/demo/ITERATION.md",
             patternsSource:"pattern-mapper",
             codebaseSource:{tech:null,arch:null,quality:null,concerns:null,domain:null},
             tasks:".loop-spec/features/demo/tasks.json"}}' > "$WORK/feature.json"

# "Committed on this branch" is a literal contract. The renderer must consult the
# repository index rather than dumping the heterogeneous feature.artifacts object.
git -C "$WORK" init -q
git -C "$WORK" config user.name "PR body test"
git -C "$WORK" config user.email "pr-body@example.invalid"
git -C "$WORK" add docs
git -C "$WORK" commit -qm "artifacts"

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
check "1: run metadata is collapsed by default" "1" "$(grep -c '<summary>Run details</summary>' "$OUT")"
check "1: provenance role is not rendered as a path" "0" "$(grep -c 'pattern-mapper' "$OUT")"
check "1: metadata object is not rendered as a path" "0" "$(grep -c "'tech': None" "$OUT")"
check "1: runtime task sidecar is not rendered as a path" "0" "$(grep -c 'tasks.json' "$OUT")"
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

# ── Case 3b: the reviewer's guide is inlined, bounded, and H1-free ───────────
printf '# Verification\n\nresult ok\n' > "$DOCS/VERIFICATION.md"
{
  echo '# Suggested review order'
  echo
  echo '**The seam**'
  echo
  echo '- decides which branch runs'
  echo '  `lib/thing.sh:12`'
} > "$DOCS/REVIEW-ORDER.md"
git -C "$WORK" add docs >/dev/null 2>&1
git -C "$WORK" commit -qm "review order" >/dev/null 2>&1
jq '.artifacts.reviewOrder = "docs/loop-spec/features/demo/REVIEW-ORDER.md"' \
  "$WORK/feature.json" > "$WORK/feature-trail.json"
bash "$LIB" render "$WORK/feature-trail.json" "$WORK" "$OUT"
check "3b: review order section rendered" "1" "$(grep -c '^## Suggested review order' "$OUT")"
check "3b: stop anchor survives" "1" "$(grep -c 'lib/thing.sh:12' "$OUT")"
check "3b: trail H1 does not leak" "0" "$(grep -c '^# ' "$OUT")"
check "3b: trail is listed as a committed artifact" "1" \
  "$(grep -c 'docs/loop-spec/features/demo/REVIEW-ORDER.md' "$OUT")"
check "3b: guide precedes the verification evidence" "1" \
  "$(awk '/^## Suggested review order/{g=NR} /^## Verification/{v=NR} END{print (g && v && g<v)?1:0}' "$OUT")"

# A trail longer than the cap is truncated, never dumped whole.
{ echo '# Suggested review order'; echo; for i in $(seq 1 80); do echo "- framing $i"; echo "  \`lib/f$i.sh:$i\`"; done; } > "$DOCS/REVIEW-ORDER.md"
bash "$LIB" render "$WORK/feature-trail.json" "$WORK" "$OUT"
check "3b: long trail is capped" "1" \
  "$(awk '/^## Suggested review order/{c=1;next} /^## /{c=0} c&&/^- framing/{n++} END{print (n<=30)?1:0}' "$OUT")"

# ── Case 4: missing artifacts degrade to a minimal body ──────────────────────
jq -n '{schemaVersion:7,slug:"bare",feature_title:"Bare",warnings:[],artifacts:{}}' > "$WORK/bare.json"
bash "$LIB" render "$WORK/bare.json" "$WORK" "$OUT"
check "4: renders without artifacts" "0" "$?"
check "4: goal still present" "1" "$(grep -c '^\*\*Goal:\*\* Bare' "$OUT")"

# ── Case 5: ambiguity_scores frontmatter → percentage table, no decimal leak ─
cat > "$DOCS/SPEC.md" <<'EOF'
---
ambiguity_scores:
  goal_clarity: 0.85
  boundary_clarity: 0.80
  constraint_clarity: 0.45
  acceptance_clarity: 0.80
  ambiguity: 0.18
  rounds_completed: 3
  gate_passed: true
  unresolved_dimensions: []
---

# Spec: Demo feature

The demo feature adds a demo capability.

## Acceptance criteria

- demo command exits 0
EOF
printf '# Verification\n\nAll pass.\n' > "$DOCS/VERIFICATION.md"
bash "$LIB" render "$WORK/feature.json" "$WORK" "$OUT"
check "5: renders with frontmatter" "0" "$?"
check "5: no raw decimal scores leak" "0" "$(grep -c '0\.18\|goal_clarity' "$OUT")"
check "5: no frontmatter delimiter leaks" "0" "$(grep -c '^---$' "$OUT")"
check "5: spec quality section present" "1" "$(grep -c '^### Spec quality' "$OUT")"
check "5: spec quality follows reviewer-facing verification" "1" \
  "$(awk '/^## Verification/{v=NR} /^### Spec quality/{q=NR} END{print (v && q && v<q)?1:0}' "$OUT")"
check "5: percentages rendered" "1" "$(grep -c '| \*\*18%\*\* |' "$OUT")"
check "5: per-dimension gate marks" "1" "$(grep -c '| Goal clarity | 85% | >= 60% | ✅ |' "$OUT")"
check "5: rounds note rendered" "1" "$(grep -c 'Gate passed after 3 interview round' "$OUT")"
check "5: summary fallback skips frontmatter" "1" "$(grep -c 'adds a demo capability' "$OUT")"

# Failing dimension shows ❌ and 'not passed'.
sed -i '' -e 's/gate_passed: true/gate_passed: false/' -e 's/ambiguity: 0.18/ambiguity: 0.35/' "$DOCS/SPEC.md"
bash "$LIB" render "$WORK/feature.json" "$WORK" "$OUT"
check "5: failing ambiguity gets ❌" "1" "$(grep -c '| \*\*35%\*\* | <= 20% | ❌ |' "$OUT")"
check "5: gate not passed note" "1" "$(grep -c 'not passed' "$OUT")"

# Warnings render as a GFM alert.
check "5: warnings as GFM alert" "1" "$(grep -c '> \[!WARNING\]' "$OUT")"

# Verbose mode preserves expanded run sections for operators that want them.
LOOP_SPEC_PR_BODY_VERBOSE=1 bash "$LIB" render "$WORK/feature.json" "$WORK" "$OUT"
check "5b: verbose mode expands run details" "1" "$(grep -c '^## Spec quality' "$OUT")"
check "5b: verbose mode omits details wrapper" "0" "$(grep -c '<summary>Run details</summary>' "$OUT")"

# External artifact storage never claims those paths are committed in the PR.
LOOP_SPEC_ARTIFACTS_IN_PR=0 bash "$LIB" render "$WORK/feature.json" "$WORK" "$OUT"
check "5c: external artifact mode omits committed path list" "0" \
  "$(grep -c 'docs/loop-spec/features/demo/SPEC.md' "$OUT")"
check "5c: external artifact mode explains the audit trail" "1" \
  "$(grep -c 'Stored outside the PR' "$OUT")"

# ── Case 6: bad invocation ───────────────────────────────────────────────────
ec=0; bash "$LIB" render >/dev/null 2>&1 || ec=$?
check "6: missing args exit 2" "2" "$ec"
ec=0; bash "$LIB" bogus a b c >/dev/null 2>&1 || ec=$?
check "6: unknown subcommand exit 2" "2" "$ec"
ec=0; LOOP_SPEC_PR_BODY_VERBOSE=maybe bash "$LIB" render "$WORK/feature.json" "$WORK" "$OUT" >/dev/null 2>&1 || ec=$?
check "6: invalid verbosity exits 2" "2" "$ec"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
