#!/usr/bin/env bash
# Tests for lib/oneshot-exit-gate.sh (ONESHOT's exit) and the oneshot phase's exit
# through lib/phase-exit.sh on the shipped graph.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$REPO_ROOT/lib/oneshot-exit-gate.sh"
EXIT="$REPO_ROOT/lib/phase-exit.sh"
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

WORK="${TMPDIR:-/tmp}"; WORK="${WORK%/}/oneshot-exit-test.$$"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export LOOP_SPEC_HARNESS=codex LOOP_SPEC_TEAMS_MODE=none LOOP_SPEC_WORKFLOWS_AVAILABLE=0 LOOP_SPEC_CHECKPOINT_PR=0
unset LOOP_SPEC_AUTONOMOUS LOOP_SPEC_NON_INTERACTIVE LOOP_SPEC_ROUTE
mkdir -p "$REPO/src" "$REPO/tests"
printf 'def slugify(s):\n    return s.lower()\n' > "$REPO/src/slugify.py"
printf 'from src.slugify import slugify\n\ndef test_lower():\n    assert slugify("A") == "a"\n' > "$REPO/tests/test_slugify.py"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m init

cd "$REPO"
bash "$REPO_ROOT/lib/cycle-driver.sh" start --dir "$REPO" -- fix slug >/dev/null 2>&1
bash "$REPO_ROOT/lib/cycle-driver.sh" init --dir "$REPO" --slug fix-slug --title "fix slug" \
  --style auto --profile standard --autonomous 1 >/dev/null 2>&1
FD="$REPO/.loop-spec/features/fix-slug"
DOCS="$REPO/docs/loop-spec/features/fix-slug"
mkdir -p "$DOCS"
fj() { jq -r "$1" "$FD/feature.json"; }

check "usage: no feature dir is a bad invocation" "2" "$(bash "$GATE" >/dev/null 2>&1; echo $?)"

spec() {
  # spec [<extra top-level frontmatter line>]
  cat > "$DOCS/SPEC.md" <<MD
---
ambiguity_scores:
  ambiguity: 0.1
  gate_passed: true
  unresolved_dimensions: []
footprint:
  - src/slugify.py
${1:-}
---
# fix slug

<!-- intent: frozen. The ask as SPEC understood it. -->
## Intent

Dots survive slugify.
<!-- /intent -->

## Implementation notes

- src/slugify.py: strip dots in slugify().
- tests/test_slugify.py: unchanged; the existing case covers the fix.

## Success criteria

### Good Enough

- [ ] \`python3 -c "from src.slugify import slugify; assert slugify('a.b') == 'ab'"\` exits 0

## Grounding

- none
MD
}
spec
check "artifact-lint accepts the oneshot spec shape" "0" "$(bash "$REPO_ROOT/lib/artifact-lint.sh" spec "$DOCS/SPEC.md" >/dev/null 2>&1; echo $?)"
check "the oneshot spec lint accepts the shape" "0" "$(bash "$REPO_ROOT/lib/oneshot-spec-lint.sh" "$DOCS/SPEC.md" >/dev/null 2>&1; echo $?)"
{ cat "$DOCS/SPEC.md"; for i in $(seq 1 45); do echo "narrative line $i"; done; } > "$WORK/long.md"
out="$(bash "$REPO_ROOT/lib/oneshot-spec-lint.sh" "$WORK/long.md" 2>&1)"; ec=$?
check "a oneshot spec over 60 lines flags" "1" "$ec"
check "the flag names the line count and the template" "1" "$(grep -c 'FLAG \[oneshot-shape\] SPEC.md is 7[0-9] lines; a spec with a oneshot footprint keeps to 60' <<<"$out")"
sed 's/^## Implementation notes$/## Notes/' "$DOCS/SPEC.md" > "$WORK/nonotes.md"
check "a oneshot spec without Implementation notes flags" "1" "$(bash "$REPO_ROOT/lib/oneshot-spec-lint.sh" "$WORK/nonotes.md" 2>&1 | grep -c 'no .## Implementation notes. section')"
sed 's/^## Intent$/## Problem/' "$DOCS/SPEC.md" > "$WORK/nointent.md"
# The variant stays inside the repository: the rule resolves the test module against
# the spec's own git toplevel.
grep -v 'tests/test_slugify.py' "$DOCS/SPEC.md" > "$DOCS/notest.md"
out="$(bash "$REPO_ROOT/lib/oneshot-spec-lint.sh" "$DOCS/notest.md" 2>&1)"; ec=$?
rm -f "$DOCS/notest.md"
check "a footprint file whose test module the spec never names flags" "1" "$ec"
check "the flag names the module" "1" "$(grep -c 'src/slugify.py has a test module tests/test_slugify.py' <<<"$out")"
check "a oneshot spec without the Intent block flags" "1" "$(bash "$REPO_ROOT/lib/oneshot-spec-lint.sh" "$WORK/nointent.md" 2>&1 | grep -c 'no .## Intent. block')"
sed 's/^footprint:$/footprint: [a.py, b.py, c.py, d.py]/; /^  - src\/slugify.py$/d' "$WORK/long.md" > "$WORK/full.md"
check "a full-shape spec (four files) passes the lint untouched" "0" "$(bash "$REPO_ROOT/lib/oneshot-spec-lint.sh" "$WORK/full.md" >/dev/null 2>&1; echo $?)"
check "a spec without a footprint passes the lint" "0" "$(printf -- '---\nambiguity_scores:\n  gate_passed: true\n---\n# x\n' > "$WORK/nofp.md"; bash "$REPO_ROOT/lib/oneshot-spec-lint.sh" "$WORK/nofp.md" >/dev/null 2>&1; echo $?)"
check "the oneshot template is under 60 lines" "1" "$([[ $(wc -l < "$REPO_ROOT/skills/shared/artifact-templates/SPEC-oneshot.md.template") -lt 60 ]] && echo 1 || echo 0)"

# --- an unfinished oneshot: no VERIFICATION.md ----------------------------------------
ec=0; out="$(bash "$GATE" "$FD" 2>&1)" || ec=$?
check "no VERIFICATION.md flags" "1" "$ec"
check "the flag names the file and the skill step" "1" "$(grep -c '^FLAG \[verification\] .*VERIFICATION.md missing: ONESHOT writes it' <<<"$out")"

# --- an escalated spec closes with nothing to check -----------------------------------
spec 'route: full'
ec=0; out="$(bash "$GATE" "$FD" 2>&1)" || ec=$?
check "route: full passes the gate with no VERIFICATION.md" "0" "$ec"
check "an escalated exit prints nothing" "" "$out"
ec=0; out="$(bash "$EXIT" oneshot --feature-dir "$FD" 2>&1)" || ec=$?
check "phase-exit oneshot: an escalated spec closes clean" "phase-exit: ok (oneshot)" "$(tail -1 <<<"$out")"
check "phase-exit oneshot: the phase is closed" "oneshot" "$(fj '.completedPhases[-1]')"
check "phase-exit oneshot: SPEC.md with the escalation is committed" "1" "$(git log --oneline | grep -c 'oneshot: fix-slug')"
check "phase-exit oneshot: no verification pointer on escalation" "null" "$(fj '.artifacts.verification')"
check "the --after probe routes the escalated run to the full path" "route=full" "$(bash "$REPO_ROOT/lib/graph/probes/oneshot.sh" --feature-dir "$FD" --after | cut -d' ' -f1)"

# --- a finished oneshot: change committed, VERIFICATION.md proves the criterion ------
spec
printf 'def slugify(s):\n    return s.lower().replace(".", "")\n' > "$REPO/src/slugify.py"
git -C "$REPO" add src/slugify.py && git -C "$REPO" commit -q -m "fix: strip dots"
cat > "$DOCS/VERIFICATION.md" <<'MD'
# fix slug - Verification

**Spec:** `docs/loop-spec/features/fix-slug/SPEC.md`

## Repository grounding

- criterion: GE-001 | implementation: src/slugify.py:2 - replace(".", "") strips dots | integration: tests/test_slugify.py:3 - the suite imports slugify

## Acceptance criteria

| # | Criterion | Status | Evidence |
|---|-----------|--------|----------|
| GE-001 | slugify('a.b') == 'ab' | PASS | `python3 -c ...` -> exit 0 |

## Verify command outputs

### Criterion 1

```
(no output, exit 0)
```

## Code review

**Reviewer:** code-reviewer (haiku)

### Findings

none

## Final test suite

```
1 passed
```
MD
ec=0; out="$(bash "$GATE" "$FD" 2>&1)" || ec=$?
check "no recorded reviewer dispatch flags" "1" "$(grep -c '^FLAG \[review\] no code-reviewer dispatch recorded for oneshot' <<<"$out")"
bash "$REPO_ROOT/lib/events.sh" emit "$FD" dispatch --phase oneshot --data '{"role":"code-reviewer","model":"haiku","rung":"subagent"}' >/dev/null 2>&1
ec=0; out="$(bash "$GATE" "$FD" 2>&1)" || ec=$?
check "a finished oneshot passes the gate" "0" "$ec"
check "a clean gate prints nothing" "" "$out"
# The Intent block is frozen: the escalated SPEC.md is committed above, so a rewrite
# of the ask after that commit is a flag, and a change outside the block is not.
sed -i 's/^Dots survive slugify\.$/Dots and dashes survive slugify./' "$DOCS/SPEC.md"
ec=0; out="$(bash "$GATE" "$FD" 2>&1)" || ec=$?
check "an Intent block edited after its commit flags" "1" "$(grep -c '^FLAG \[intent\] the frozen Intent block of docs/loop-spec/features/fix-slug/SPEC.md changed since its commit' <<<"$out")"
spec
printf -- '- also: nothing else changes.\n' >> "$DOCS/SPEC.md"
ec=0; out="$(bash "$GATE" "$FD" 2>&1)" || ec=$?
check "a change outside the Intent block passes" "0" "$ec"
spec
# A review finding without its verdict is the triage lint's flag.
sed -i 's/^none$/- src\/slugify.py:2 — the replace runs before lower()/' "$DOCS/VERIFICATION.md"
ec=0; out="$(bash "$GATE" "$FD" 2>&1)" || ec=$?
check "a finding without a verdict flags under the review-triage label" "1" "$(grep -c '^FLAG \[review-triage\] .*finding has no verdict' <<<"$out")"
sed -i 's/^- src\/slugify.py:2 — the replace runs before lower()$/- src\/slugify.py:2 — the replace runs before lower() | verdict: false — lower() never adds a dot, so the order cannot change the result/' "$DOCS/VERIFICATION.md"
ec=0; out="$(bash "$GATE" "$FD" 2>&1)" || ec=$?
check "a rejected finding with its disproof passes" "0" "$ec"
# The footprint is a promise: a file it names that the diff never touched is a flag.
sed -i 's|^  - src/slugify.py$|  - src/slugify.py\n  - tests/test_slugify.py|' "$DOCS/SPEC.md"
ec=0; out="$(bash "$GATE" "$FD" 2>&1)" || ec=$?
check "an untouched footprint file flags" "1" "$(grep -c '^FLAG \[footprint\] tests/test_slugify.py is in SPEC.md.s footprint but not in the diff' <<<"$out")"
spec
# The converged floor is the full one: a FAIL row is a finding, not a shape.
sed -i 's/| PASS |/| FAIL |/' "$DOCS/VERIFICATION.md"
ec=0; out="$(bash "$GATE" "$FD" 2>&1)" || ec=$?
check "a FAIL row flags under the converged-floor label" "1" "$(grep -c '^FLAG \[converged-floor\] ' <<<"$out" | awk '{print ($1 > 0)}')"
sed -i 's/| FAIL |/| PASS |/' "$DOCS/VERIFICATION.md"
# A weakened test is caught by the same tamper scan VERIFY runs.
printf 'import pytest\nfrom src.slugify import slugify\n\n@pytest.mark.skip\ndef test_lower():\n    assert slugify("A") == "a"\n' > "$REPO/tests/test_slugify.py"
git -C "$REPO" add tests/test_slugify.py && git -C "$REPO" commit -q -m "test: weaken"
ec=0; out="$(bash "$GATE" "$FD" 2>&1)" || ec=$?
check "a weakened test flags under the tamper label" "1" "$(grep -c '^FLAG \[tamper\] ' <<<"$out" | awk '{print ($1 > 0)}')"
git -C "$REPO" reset -q --hard HEAD~1
spec

ec=0; out="$(bash "$EXIT" oneshot --feature-dir "$FD" 2>&1)" || ec=$?
check "phase-exit oneshot: a finished oneshot closes clean" "phase-exit: ok (oneshot)" "$(tail -1 <<<"$out")"
check "phase-exit oneshot: the verification pointer is recorded" "docs/loop-spec/features/fix-slug/VERIFICATION.md" "$(fj '.artifacts.verification')"
check "phase-exit oneshot: the checkpoint is tagged" "1" "$(git tag | grep -c 'post-oneshot' | awk '{print ($1 > 0)}')"
check "the --after probe routes the finished run to DELIVER" "route=oneshot" "$(bash "$REPO_ROOT/lib/graph/probes/oneshot.sh" --feature-dir "$FD" --after | cut -d' ' -f1)"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
