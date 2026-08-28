#!/usr/bin/env bash
# Ponytail coverage: the laziness-ladder directive MUST be present in every code-producing
# phase dispatch path, so the discipline is followed every time -- not only on the main
# thread (SessionStart hook) but inside each dispatched implementer / planner / reviewer,
# which a SessionStart hook does NOT reach.
#
# Relevant phases (skills/simplicity/SKILL.md "Relationship to the cycle"):
#   PLAN/planner, EXECUTE/implementer (team + subagent + loop-fleet rungs), VERIFY/code-reviewer.
#
# This is the enforcement that keeps the wiring from silently regressing.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0
FAIL=0

# file<TAB>regex(any-case) that must match at least once.
checks=(
  "skills/shared/laziness-ladder.md	laziness ladder"
  "agents/planner.md	laziness ladder"
  "agents/implementer.md	laziness ladder"
  "agents/code-reviewer.md	(ponytail|over-engineering pass)"
  "skills/shared/team-prompts/implementer.md	(laziness ladder|ponytail)"
  "skills/shared/execute-subagent.md	ponytail laziness ladder"
  "lib/plan-to-loop.sh	ponytail laziness ladder"
  "lib/workflows/execute-dag.js	ponytail laziness ladder"
)

for entry in "${checks[@]}"; do
  f="${entry%%	*}"
  rx="${entry##*	}"
  if [[ ! -f "$f" ]]; then
    echo "FAIL: $f missing"; FAIL=$((FAIL+1)); continue
  fi
  if grep -qiE "$rx" "$f"; then
    echo "PASS: $f carries the ladder (/$rx/)"; PASS=$((PASS+1))
  else
    echo "FAIL: $f does NOT carry the ponytail ladder (/$rx/) -- a dispatch path lost the directive"
    FAIL=$((FAIL+1))
  fi
done

# The EXECUTE subagent rung dispatches TWO implementer prompts (single-repo + workspace);
# both must carry the directive. Require >= 2 ladder occurrences in that file.
sub_count="$(grep -ciE "ponytail laziness ladder" skills/shared/execute-subagent.md)"
marker_count="$(grep -cF "implementer contract stanza — insert the block above" skills/shared/execute-subagent.md)"
if [[ "$sub_count" -ge 1 && "$marker_count" -ge 2 ]]; then
  echo "PASS: execute-subagent.md covers both implementer prompts ($sub_count occurrences)"
  PASS=$((PASS+1))
else
  echo "FAIL: execute-subagent.md has $sub_count ladder occurrences; expected stanza >= 1 and both prompts inserting it (marker >= 2)"
  FAIL=$((FAIL+1))
fi

# --- rung 2 (DRY) is measured, not recalled ---
#
# "Search the tree first" was in this directive from the start and second copies kept
# shipping: a run cannot find a helper in a file it never opened. lib/duplication-scan.sh
# is the measurement that closes it, and it has to reach the same dispatch paths as the
# ladder itself -- a probe named only in the canonical doc is absent where code is written.

for entry in \
  "skills/shared/laziness-ladder.md	DRY" \
  "agents/planner.md	DRY" \
  "agents/implementer.md	DRY" \
  "agents/code-reviewer.md	dry:" \
  "skills/shared/team-prompts/implementer.md	DRY" \
  "skills/shared/execute-subagent.md	DRY" \
  "lib/plan-to-loop.sh	DRY" \
  "lib/workflows/execute-dag.js	DRY" \
  "hooks/team/simplicity-inject.sh	DRY" \
  "CLAUDE.md	DRY"; do
  f="${entry%%	*}"
  rx="${entry##*	}"
  if grep -qF "$rx" "$f"; then
    echo "PASS: $f names the DRY rung (/$rx/)"; PASS=$((PASS+1))
  else
    echo "FAIL: $f does NOT name the DRY rung (/$rx/) -- rung 2 lost its name"
    FAIL=$((FAIL+1))
  fi
done

# Every dispatch copy must point at the probe, not merely assert the rung: a prompt that
# says "reuse what exists" without naming the measurement is the prose criterion this
# change exists to replace. The planner is excluded on purpose -- it has no Bash for
# probes, so it names existing files in readFirst instead of running one.
for f in agents/implementer.md agents/code-reviewer.md \
         skills/shared/team-prompts/implementer.md skills/shared/execute-subagent.md \
         lib/plan-to-loop.sh lib/workflows/execute-dag.js hooks/team/simplicity-inject.sh; do
  if grep -qF "duplication-scan.sh" "$f"; then
    echo "PASS: $f names the duplication probe"; PASS=$((PASS+1))
  else
    echo "FAIL: $f does not name duplication-scan.sh -- rung 2 is prose again there"
    FAIL=$((FAIL+1))
  fi
done

# The probe ships inside the plugin; a dispatched agent's cwd is the target repository, so
# a bare `lib/...` invocation resolves to nothing there. Each site substitutes a real path.
for f in skills/shared/laziness-ladder.md agents/implementer.md agents/code-reviewer.md \
         skills/shared/team-prompts/implementer.md skills/shared/execute-subagent.md \
         lib/plan-to-loop.sh lib/workflows/execute-dag.js hooks/team/simplicity-inject.sh; do
  if grep -qE 'bash (")?lib/duplication-scan\.sh' "$f"; then
    echo "FAIL: $f invokes the probe by bare relative path -- unreachable outside this repo"
    FAIL=$((FAIL+1))
  else
    echo "PASS: $f has no bare-relative probe invocation"; PASS=$((PASS+1))
  fi
done

# Each site resolves the path by its own available mechanism.
resolvers=(
  "skills/shared/execute-subagent.md	CLAUDE_SKILL_DIR}/\.\./\.\./lib/duplication-scan\.sh"
  "skills/shared/team-prompts/implementer.md	CLAUDE_SKILL_DIR}/\.\./\.\./lib/duplication-scan\.sh"
  "lib/plan-to-loop.sh	\{lib_dir\}/duplication-scan\.sh"
  "lib/workflows/execute-dag.js	libDir \+ '/duplication-scan\.sh"
  "hooks/team/simplicity-inject.sh	LIB_DIR\}/duplication-scan\.sh"
  "agents/implementer.md	probe_dir\}/duplication-scan\.sh"
  "agents/code-reviewer.md	probe_dir\}/duplication-scan\.sh"
)
for entry in "${resolvers[@]}"; do
  f="${entry%%	*}"
  rx="${entry##*	}"
  if grep -qE "$rx" "$f"; then
    echo "PASS: $f resolves the probe path (/$rx/)"; PASS=$((PASS+1))
  else
    echo "FAIL: $f lost its probe-path resolution (/$rx/)"; FAIL=$((FAIL+1))
  fi
done

# The shared stanza carries the probe once; both prompts insert the stanza.
dup_count="$(grep -cF "duplication-scan.sh" skills/shared/execute-subagent.md)"
if [[ "$dup_count" -ge 1 ]]; then
  echo "PASS: execute-subagent.md carries the probe in the shared stanza ($dup_count occurrences)"
  PASS=$((PASS+1))
else
  echo "FAIL: execute-subagent.md has $dup_count probe references; expected >= 1 (shared stanza)"
  FAIL=$((FAIL+1))
fi

# VERIFY must hand the reviewer a probe_dir, or the reviewer's dry: findings can only be
# Minor -- the severity rule keys on being able to point at probe output.
if grep -qF 'probe_dir' skills/verify/SKILL.md; then
  echo "PASS: verify/SKILL.md passes probe_dir to the reviewer"; PASS=$((PASS+1))
else
  echo "FAIL: verify/SKILL.md no longer passes probe_dir -- dry: findings cannot block"
  FAIL=$((FAIL+1))
fi

# The probe is the deterministic half of the rung: it must exist, be executable, and be
# wired into the offline suite.
if [[ -x lib/duplication-scan.sh ]]; then
  echo "PASS: lib/duplication-scan.sh exists and is executable"; PASS=$((PASS+1))
else
  echo "FAIL: lib/duplication-scan.sh missing or not executable"; FAIL=$((FAIL+1))
fi

if grep -qF "tests/lib/duplication-scan.test.sh" tests/run-all.sh; then
  echo "PASS: tests/lib/duplication-scan.test.sh registered in run-all.sh"; PASS=$((PASS+1))
else
  echo "FAIL: tests/lib/duplication-scan.test.sh is not registered in tests/run-all.sh"
  FAIL=$((FAIL+1))
fi

# Both tiers must reach the prompts. The shape tier (`similar=`) is the one that catches
# what a model actually writes -- the same block with every name changed -- so a prompt that
# mentions only `duplicate=` teaches the implementer to ignore the finding that matters.
for f in agents/implementer.md agents/code-reviewer.md \
         skills/shared/team-prompts/implementer.md skills/shared/execute-subagent.md \
         lib/plan-to-loop.sh lib/workflows/execute-dag.js hooks/team/simplicity-inject.sh \
         skills/shared/laziness-ladder.md; do
  if grep -qF "similar=" "$f" && grep -qF "duplicate=" "$f"; then
    echo "PASS: $f names both match tiers"; PASS=$((PASS+1))
  else
    echo "FAIL: $f does not name both tiers (duplicate= and similar=)"
    FAIL=$((FAIL+1))
  fi
done

# Rung 1 (YAGNI) is the other rung prose could not enforce: the one-caller wrapper looks
# justified while it is being written and is only countable afterwards. lib/indirection-scan.sh
# is that count, and it has to reach the same dispatch paths as the ladder itself.
for f in agents/implementer.md agents/code-reviewer.md \
         skills/shared/team-prompts/implementer.md skills/shared/execute-subagent.md \
         lib/plan-to-loop.sh lib/workflows/execute-dag.js hooks/team/simplicity-inject.sh \
         skills/shared/laziness-ladder.md; do
  if grep -qF "indirection-scan.sh" "$f"; then
    echo "PASS: $f names the indirection probe"; PASS=$((PASS+1))
  else
    echo "FAIL: $f does not name indirection-scan.sh -- rung 1 is prose again there"
    FAIL=$((FAIL+1))
  fi
done

# The probe must exist, be executable, and be wired into the offline suite.
if [[ -x lib/indirection-scan.sh ]]; then
  echo "PASS: lib/indirection-scan.sh exists and is executable"; PASS=$((PASS+1))
else
  echo "FAIL: lib/indirection-scan.sh missing or not executable"; FAIL=$((FAIL+1))
fi
if grep -qF "tests/lib/indirection-scan.test.sh" tests/run-all.sh; then
  echo "PASS: tests/lib/indirection-scan.test.sh registered in run-all.sh"; PASS=$((PASS+1))
else
  echo "FAIL: tests/lib/indirection-scan.test.sh is not registered"; FAIL=$((FAIL+1))
fi

# Decomposition is not indirection. Without that carve-out the directive tells implementers
# to inline every helper, which is the opposite of the design-for-change companion.
for f in agents/implementer.md agents/code-reviewer.md skills/shared/laziness-ladder.md \
         hooks/team/simplicity-inject.sh; do
  if grep -qiE "decomposition|earns its hop|long function with one caller" "$f"; then
    echo "PASS: $f keeps the decomposition carve-out"; PASS=$((PASS+1))
  else
    echo "FAIL: $f omits the decomposition carve-out -- rung 1 becomes an inline-everything order"
    FAIL=$((FAIL+1))
  fi
done

# The reviewer must not turn the probe into a licence to merge lookalikes: two blocks that
# change for different reasons are not duplication, and merging them couples them.
for f in agents/implementer.md agents/code-reviewer.md hooks/team/simplicity-inject.sh; do
  if grep -qiE "coincidental|different reasons|look alike|coupling bug" "$f"; then
    echo "PASS: $f keeps the coincidental-resemblance carve-out"; PASS=$((PASS+1))
  else
    echo "FAIL: $f omits the coincidental-resemblance carve-out -- DRY becomes a merge order"
    FAIL=$((FAIL+1))
  fi
done

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "PASS: ponytail ladder present in every relevant-phase dispatch path"
