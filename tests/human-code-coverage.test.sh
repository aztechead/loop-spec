#!/usr/bin/env bash
# Code-for-humans coverage: the "house style over habit" directive MUST be present in
# every code-producing dispatch path, mirroring tests/ponytail-coverage.test.sh for the
# laziness ladder and tests/design-coverage.test.sh for seams. The directive codifies:
# read the neighbors and match them, comments carry why not what, comment density is set
# by the file rather than an absolute, a good name deletes a comment, and the diff is
# written for its reviewer.
#
# A SessionStart hook does not reach a dispatched implementer, so a directive that lives
# only in the hook is absent exactly where code gets written. This is the enforcement that
# keeps the wiring from silently regressing.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0
FAIL=0

# file<TAB>regex(any-case) that must match at least once.
checks=(
  "skills/shared/human-code.md	house style over habit"
  "skills/shared/human-code.md	comments carry why, never what"
  "skills/shared/human-code.md	density matches the file"
  "agents/implementer.md	house style over habit"
  "agents/planner.md	house style over habit"
  "agents/code-reviewer.md	code-for-humans pass"
  "skills/shared/team-prompts/implementer.md	house style over habit"
  "skills/shared/execute-subagent.md	house style over habit"
  "lib/plan-to-loop.sh	house style over habit"
  "lib/workflows/execute-dag.js	house style over habit"
  "hooks/team/human-code-inject.sh	CODE FOR HUMANS MODE ACTIVE"
  "skills/human-code/SKILL.md	code-for-humans mode"
  "CLAUDE.md	house style over habit"
  "skills/shared/human-code.md	Fail loudly"
  "skills/shared/human-code.md	names what broke"
  "agents/implementer.md	Code a human can operate"
  "skills/shared/team-prompts/implementer.md	Code a human can operate"
  "skills/shared/execute-subagent.md	CODE A HUMAN CAN OPERATE"
  "hooks/team/human-code-inject.sh	CODE A HUMAN CAN OPERATE"
  "agents/code-reviewer.md	the operate half"
  "CLAUDE.md	failure path"
)

for entry in "${checks[@]}"; do
  f="${entry%%	*}"
  rx="${entry##*	}"
  if [[ ! -f "$f" ]]; then
    echo "FAIL: $f missing"; FAIL=$((FAIL+1)); continue
  fi
  if grep -qiE "$rx" "$f"; then
    echo "PASS: $f carries code-for-humans (/$rx/)"; PASS=$((PASS+1))
  else
    echo "FAIL: $f does NOT carry code-for-humans (/$rx/) -- a dispatch path lost the directive"
    FAIL=$((FAIL+1))
  fi
done

# The EXECUTE subagent rung dispatches TWO implementer prompts (single-repo + workspace);
# both must carry the directive, same as the ladder and design requirements.
sub_count="$(grep -ciE "house style over habit" skills/shared/execute-subagent.md)"
if [[ "$sub_count" -ge 2 ]]; then
  echo "PASS: execute-subagent.md covers both implementer prompts ($sub_count occurrences)"
  PASS=$((PASS+1))
else
  echo "FAIL: execute-subagent.md has $sub_count code-for-humans occurrences; expected >= 2 (single-repo + workspace prompts)"
  FAIL=$((FAIL+1))
fi

# The operate half is the one nobody rereads, because it only runs when something is
# already wrong. A rung that carries the style directive without it ships code that goes
# quiet exactly when a person needs it to speak.
for f in agents/implementer.md agents/code-reviewer.md \
         skills/shared/team-prompts/implementer.md skills/shared/execute-subagent.md \
         lib/plan-to-loop.sh lib/workflows/execute-dag.js hooks/team/human-code-inject.sh \
         skills/human-code/SKILL.md skills/shared/human-code.md; do
  if grep -q "failure-tells.sh" "$f"; then
    echo "PASS: $f names the failure-path probe"; PASS=$((PASS+1))
  else
    echo "FAIL: $f does not name failure-tells.sh -- the operate half is missing"
    FAIL=$((FAIL+1))
  fi
  if grep -qE 'bash (")?lib/failure-tells\.sh' "$f"; then
    echo "FAIL: $f invokes failure-tells.sh by bare relative path -- unreachable outside this repo"
    FAIL=$((FAIL+1))
  else
    echo "PASS: $f has no bare-relative failure-tells invocation"; PASS=$((PASS+1))
  fi
done

# The reviewer needs a tag for it, or a measured silence has nowhere to be reported.
if grep -qF 'silent:' agents/code-reviewer.md; then
  echo "PASS: code-reviewer.md carries the silent: finding tag"; PASS=$((PASS+1))
else
  echo "FAIL: code-reviewer.md has no silent: tag for failure-path findings"; FAIL=$((FAIL+1))
fi

# Every dispatch copy must point at the probes, not just assert the principle: a prompt
# that says "match the conventions" without naming the measurement is the prose criterion
# this change exists to replace.
for f in agents/implementer.md agents/code-reviewer.md \
         skills/shared/team-prompts/implementer.md skills/shared/execute-subagent.md \
         lib/plan-to-loop.sh lib/workflows/execute-dag.js hooks/team/human-code-inject.sh; do
  if grep -q "house-style.sh" "$f" && grep -q "comment-tells.sh" "$f"; then
    echo "PASS: $f names both probes"; PASS=$((PASS+1))
  else
    echo "FAIL: $f does not name both probes (house-style.sh + comment-tells.sh)"
    FAIL=$((FAIL+1))
  fi
done

# The probes ship inside the plugin; a dispatched agent's cwd is the target repository.
# A bare `lib/...` invocation resolves to nothing there, so no dispatch site may carry one
# -- each must substitute a real path (CLAUDE_SKILL_DIR, an injected arg, BASH_SOURCE, or
# the probe_dir brief input) before the directive goes out.
for f in skills/shared/human-code.md agents/implementer.md agents/code-reviewer.md \
         agents/planner.md skills/shared/team-prompts/implementer.md \
         skills/shared/execute-subagent.md lib/plan-to-loop.sh \
         lib/workflows/execute-dag.js hooks/team/human-code-inject.sh; do
  if grep -qE 'bash (")?lib/(house-style|comment-tells)\.sh' "$f"; then
    echo "FAIL: $f invokes the probes by bare relative path -- unreachable outside this repo"
    FAIL=$((FAIL+1))
  else
    echo "PASS: $f has no bare-relative probe invocation"; PASS=$((PASS+1))
  fi
done

# Each site must resolve the path by its own available mechanism.
resolvers=(
  "skills/shared/execute-subagent.md	CLAUDE_SKILL_DIR}/\.\./\.\./lib/house-style\.sh"
  "skills/shared/team-prompts/implementer.md	CLAUDE_SKILL_DIR}/\.\./\.\./lib/house-style\.sh"
  "lib/plan-to-loop.sh	LIB_DIR=\"\\\$\(cd"
  "lib/workflows/execute-dag.js	skillDir \? "
  "hooks/team/human-code-inject.sh	LIB_DIR=\"\\\$\(cd"
  "agents/implementer.md	probe_dir"
  "agents/code-reviewer.md	probe_dir"
  "skills/verify/SKILL.md	probe_dir"
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

# `probe` describes the neighbourhood WITH the target pooled into it, so it can never show
# a deviation -- a file breaking every convention around it reports as the convention. The
# severity rule ("a deviation the probe measured is Important and blocks") therefore rests
# entirely on `compare`, which holds the file out of its own baseline. A dispatch path that
# names only `probe` has the directive without the thing that makes it enforceable.
for f in agents/implementer.md agents/code-reviewer.md \
         skills/shared/team-prompts/implementer.md skills/shared/execute-subagent.md \
         lib/plan-to-loop.sh lib/workflows/execute-dag.js hooks/team/human-code-inject.sh \
         skills/shared/human-code.md skills/human-code/SKILL.md; do
  if grep -qE 'house-style\.sh"? compare|house-style\.sh compare' "$f"; then
    echo "PASS: $f carries the compare mode"; PASS=$((PASS+1))
  else
    echo "FAIL: $f names only house-style probe -- it cannot demonstrate a deviation"
    FAIL=$((FAIL+1))
  fi
done

# Both subagent implementer prompts, same as every other directive half.
cmp_count="$(grep -cF "house-style.sh\" compare" skills/shared/execute-subagent.md)"
if [[ "$cmp_count" -ge 2 ]]; then
  echo "PASS: execute-subagent.md carries compare in both prompts ($cmp_count occurrences)"
  PASS=$((PASS+1))
else
  echo "FAIL: execute-subagent.md has $cmp_count compare references; expected >= 2"
  FAIL=$((FAIL+1))
fi

# The probes are the deterministic half of the directive; they must exist, be executable,
# and be wired into the offline suite.
for probe in lib/house-style.sh lib/comment-tells.sh lib/failure-tells.sh; do
  if [[ -x "$probe" ]]; then
    echo "PASS: $probe exists and is executable"; PASS=$((PASS+1))
  else
    echo "FAIL: $probe missing or not executable"; FAIL=$((FAIL+1))
  fi
done

for suite in tests/lib/house-style.test.sh tests/lib/comment-tells.test.sh \
             tests/lib/failure-tells.test.sh hooks/team/human-code-inject.test.sh; do
  if grep -qF "$suite" tests/run-all.sh; then
    echo "PASS: $suite registered in run-all.sh"; PASS=$((PASS+1))
  else
    echo "FAIL: $suite is not registered in tests/run-all.sh"; FAIL=$((FAIL+1))
  fi
done

# The carve-outs are load-bearing: without them the directive tells implementers to strip
# the `simplicity:` markers the laziness ladder requires, and the two disciplines fight.
for f in skills/shared/human-code.md agents/implementer.md hooks/team/human-code-inject.sh; do
  if grep -qF 'simplicity:' "$f"; then
    echo "PASS: $f carries the simplicity: carve-out"; PASS=$((PASS+1))
  else
    echo "FAIL: $f omits the simplicity: carve-out -- it would order the ladder's markers deleted"
    FAIL=$((FAIL+1))
  fi
done

# The reviewer's severity line is the behavioral fork: probe-demonstrable deviations block,
# taste does not. Both halves must survive.
if grep -qF 'code-for-humans findings from step 8' agents/code-reviewer.md &&
   grep -qiE 'taste (never blocks|is Minor)' agents/code-reviewer.md; then
  echo "PASS: code-reviewer.md blocks on measured findings and keeps taste non-blocking"
  PASS=$((PASS+1))
else
  echo "FAIL: code-reviewer.md lost the measured-blocks / taste-is-Minor split"
  FAIL=$((FAIL+1))
fi

# The SessionStart hook must be registered, or main-thread work never sees the directive.
if grep -qF 'human-code-inject.sh' hooks/hooks.json; then
  echo "PASS: human-code-inject.sh registered in hooks.json"; PASS=$((PASS+1))
else
  echo "FAIL: human-code-inject.sh is not registered in hooks/hooks.json"; FAIL=$((FAIL+1))
fi

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "PASS: code-for-humans directive present in every relevant dispatch path"
