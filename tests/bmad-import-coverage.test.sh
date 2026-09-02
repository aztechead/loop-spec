#!/usr/bin/env bash
# BMAD-import coverage: the imports from docs/loop-spec/bmad-scan-proposals.md are
# cross-file mechanisms -- a script plus the phase that calls it plus the docs that
# describe it. Each coupling below broke silently at least once while it was being built,
# so each is pinned here.
#
# This checks WIRING, not behavior; the behavior lives in tests/lib/*.test.sh.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0
FAIL=0

# file<TAB>regex(any-case)<TAB>why it matters
checks=(
  # B1 -- the reviewer's guide
  "skills/walkthrough/SKILL.md	review-trail\.sh	the walkthrough skill must call the trail script, not eyeball the diff"
  "skills/verify/SKILL.md	review-trail\.sh.? lint	VERIFY must lint the written trail against the real diff"
  "lib/phase-exit.sh	artifacts\.reviewOrder	VERIFY must record the trail so DELIVER can inline it"
  "lib/pr-body.sh	reviewOrder	the PR body must inline the trail"
  "lib/pr-body.sh	Suggested review order	the trail needs its own PR body heading"
  "README.md	walkthrough	the skills table must list the walkthrough skill"

  # B2 -- the verification-gap pass
  "skills/shared/review-prompts/verification-gap.md	verification-gap-scan\.sh	the prompt must send the reviewer to the probe"
  "skills/verify/SKILL.md	verification-gap-scan\.sh	VERIFY must run the probe before dispatching the pass"
  "skills/verify/SKILL.md	review-prompts/verification-gap\.md	VERIFY must carry the canonical prompt"

  # B3 -- extension points
  "skills/verify/SKILL.md	extension-points\.sh.? layers verify	VERIFY must offer the project its review layers"
  "lib/cycle-driver.sh	extension-points instructions	the cycle must load per-phase instructions"
  "lib/cycle-driver.sh	extension-points facts	the cycle must load standing facts"

  # B4 -- map audit
  "skills/map-codebase/SKILL.md	map-audit\.sh	the map skill must be able to measure its own output"

  # B6 -- trust marking (plus F3, the index prune that pairs with the orphans probe)
  "skills/map-codebase/SKILL.md	map-trust\.sh.? mark .* generated	every refresh must stamp its documents generated"
  "skills/map-codebase/SKILL.md	map-trust\.sh.? mark .* verified --by	the skill must know promotion is an operator action"
  "skills/map-codebase/SKILL.md	map-index-prune\.sh	pruning is a script, never an instruction (F3)"
  "lib/map-audit.sh	trust-expired	the audit must flag a ratification the doc outgrew"

  # B7 -- fresh-eyes prose pruning
  "skills/spec/SKILL.md	review-prompts/prose-pruning\.md	SPEC must run the fresh-eyes pass on its own artifact"
  "skills/plan/SKILL.md	review-prompts/prose-pruning\.md	PLAN must run the fresh-eyes pass on its own artifact"
  "skills/map-codebase/SKILL.md	review-prompts/prose-pruning\.md	an over-budget map needs the pass that names the cuts"
  "skills/shared/review-prompts/prose-pruning.md	never rewrite	the pass lists; the maker applies"
  "skills/spec/SKILL.md	never AskUserQuestion as a wait	SPEC scout fan-out and pruning must not stall on a fake question"
  "skills/plan/SKILL.md	never AskUserQuestion as a wait	PLAN teammate joins and pruning must not stall on a fake question"
  "skills/discuss/SKILL.md	never AskUserQuestion as a wait	DISCUSS scout fan-out and spec-writer join must not stall on a fake question"
  "skills/map-codebase/SKILL.md	never AskUserQuestion as a wait	map mapper joins and pruning must not stall on a fake question"
  "skills/shared/critique-gate-protocol.md	never AskUserQuestion as a wait	critique TeammateIdle joins must not stall on a fake question"
)

for entry in "${checks[@]}"; do
  IFS=$'\t' read -r file rx why <<<"$entry"
  if [[ ! -f "$file" ]]; then
    echo "FAIL: $file missing ($why)"; FAIL=$((FAIL+1)); continue
  fi
  if grep -qiE "$rx" "$file"; then
    echo "PASS: $file wires /$rx/"; PASS=$((PASS+1))
  else
    echo "FAIL: $file lost /$rx/ -- $why"
    FAIL=$((FAIL+1))
  fi
done

# Every shipped import must be documented as a supported control, or an operator has no
# way to learn it exists. configuration.md is the exhaustive contract by its own claim.
for knob in LOOP_SPEC_EXTENSIONS LOOP_SPEC_MAP_MAX_LINES LOOP_SPEC_MAP_MAX_AGE_DAYS; do
  if grep -q "$knob" docs/loop-spec/configuration.md; then
    echo "PASS: configuration.md documents $knob"; PASS=$((PASS+1))
  else
    echo "FAIL: configuration.md does not document $knob -- an undocumented control is not a control"
    FAIL=$((FAIL+1))
  fi
done

# The guardrail that separates this from BMAD's customize.toml: extensions add, never
# subtract. If a built-in gate id ever becomes claimable, the whole authority argument in
# bmad-scan-proposals.md B3 is void.
if bash lib/extension-points.sh validate >/dev/null 2>&1; then :; fi
GUARD_DIR="${TMPDIR:-/tmp}/loop-spec-bmad-guard.$$"
mkdir -p "$GUARD_DIR"
trap 'rm -rf "$GUARD_DIR"' EXIT
printf '{"schemaVersion":1,"reviewLayers":[{"id":"security","name":"x"}]}\n' > "$GUARD_DIR/ext.json"
if LOOP_SPEC_EXTENSIONS="$GUARD_DIR/ext.json" bash lib/extension-points.sh validate >/dev/null 2>&1; then
  echo "FAIL: a built-in gate id was accepted as an extension layer -- extensions must never shadow a gate"
  FAIL=$((FAIL+1))
else
  echo "PASS: built-in gate ids stay unclaimable by extensions"; PASS=$((PASS+1))
fi

# Every new script carries the house probe shape: an ANSWER and its REASON on one line.
for script in lib/review-trail.sh lib/verification-gap-scan.sh lib/map-audit.sh \
              lib/map-trust.sh lib/map-index-prune.sh; do
  if grep -q 'reason=' "$script"; then
    echo "PASS: $script reports the reason behind its answer"; PASS=$((PASS+1))
  else
    echo "FAIL: $script emits answers without reasons -- an unauditable probe"
    FAIL=$((FAIL+1))
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
