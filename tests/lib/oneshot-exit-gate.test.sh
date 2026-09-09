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
# The driver's skeleton, with the lead's values filled by a blunt substitution, passes
# both lints: a shape the driver wrote that a gate flags is a driver bug, not a REDO.
rm -f "$DOCS/SPEC.md" "$FD/footprint.jsonl"
bash "$REPO_ROOT/lib/footprint.sh" cite "$FD" src/slugify.py:2 "the lower() pass"
bash "$REPO_ROOT/lib/footprint.sh" cite "$FD" tests/test_slugify.py:3 "the existing case"
skel="$(bash "$REPO_ROOT/lib/cycle-driver.sh" spec skeleton --feature-dir "$FD" 2>/dev/null | jq -r '.spec')"
check "spec skeleton lands where the gate reads" "$DOCS/SPEC.md" "$skel"
sed -i 's/{what changes here[^}]*}/strip dots/; s/{One paragraph:[^}]*}/Dots survive slugify./; s/{check command}/true/g; s/{what that proves}/it runs/g; s/{expected}/ok/' "$DOCS/SPEC.md"
check "the filled skeleton passes artifact-lint spec" "0" "$(bash "$REPO_ROOT/lib/artifact-lint.sh" spec "$DOCS/SPEC.md" >/dev/null 2>&1; echo $?)"
check "the filled skeleton passes the oneshot spec lint" "0" "$(bash "$REPO_ROOT/lib/oneshot-spec-lint.sh" "$DOCS/SPEC.md" >/dev/null 2>&1; echo $?)"
check "the fixture is the filled skeleton's shape (both lints)" "0" "$(bash "$REPO_ROOT/lib/artifact-lint.sh" spec "$REPO_ROOT/tests/fixtures/oneshot-SPEC.md" >/dev/null 2>&1 && bash "$REPO_ROOT/lib/oneshot-spec-lint.sh" "$REPO_ROOT/tests/fixtures/oneshot-SPEC.md" >/dev/null 2>&1; echo $?)"

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
# The escalated exit is not a blind pass: the two scans and the verification lints
# still run; only the oneshot's own checks (footprint, intent, review, floor) are skipped.
printf 'import pytest\nfrom src.slugify import slugify\n\n@pytest.mark.skip\ndef test_lower():\n    assert slugify("A") == "a"\n' > "$REPO/tests/test_slugify.py"
git -C "$REPO" add tests/test_slugify.py && git -C "$REPO" commit -q -m "test: weaken"
ec=0; out="$(bash "$GATE" "$FD" 2>&1)" || ec=$?
check "an escalated run with a weakened test still flags under the tamper label" "1" "$(grep -c '^FLAG \[tamper\] ' <<<"$out" | awk '{print ($1 > 0)}')"
check "an escalated run skips the review and footprint checks" "0" "$(grep -c '^FLAG \[review\]\|^FLAG \[footprint\]' <<<"$out")"
git -C "$REPO" reset -q --hard HEAD~1
printf '# not a verification record\n' > "$DOCS/VERIFICATION.md"
ec=0; out="$(bash "$GATE" "$FD" 2>&1)" || ec=$?
check "an escalated run with a malformed VERIFICATION.md flags under artifact-lint" "1" "$(grep -c '^FLAG \[artifact-lint\] ' <<<"$out" | awk '{print ($1 > 0)}')"
rm -f "$DOCS/VERIFICATION.md"
# A SPEC.md the probe cannot read as either shape is a flag, never a pass.
printf '# no frontmatter at all\n\n## Intent\n' > "$DOCS/SPEC.md"
ec=0; out="$(bash "$GATE" "$FD" 2>&1)" || ec=$?
check "an unreadable frontmatter flags instead of passing" "1" "$ec"
check "the flag names the probe's reason" "1" "$(grep -c '^FLAG \[oneshot\] .*not readable as a oneshot or an escalated spec (SPEC.md frontmatter missing)' <<<"$out")"

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
# The footprint is a promise with no prose exit: an untouched file it names is a flag
# whatever Implementation notes say, and the one way out is the driver's recorded drop,
# which refuses a test module of a file that stays (followup-3, N2).
DRV="$REPO_ROOT/lib/cycle-driver.sh"
sed -i 's|^  - src/slugify.py$|  - src/slugify.py\n  - tests/test_slugify.py|' "$DOCS/SPEC.md"
ec=0; out="$(bash "$GATE" "$FD" 2>&1)" || ec=$?
check "an untouched test module flags even with an unchanged bullet in the notes" "1" "$(grep -c '^FLAG \[footprint\] tests/test_slugify.py is in SPEC.md.s footprint but not in the diff' <<<"$out")"
check "the flag names the drop command and its limit" "1" "$(grep -c 'spec footprint drop --feature-dir .* --file tests/test_slugify.py --reason .*; a test module of a footprint file cannot be dropped' <<<"$out")"
ec=0; out="$(bash "$DRV" spec footprint drop --feature-dir "$FD" --file tests/test_slugify.py --reason "the existing case covers it" 2>&1)" || ec=$?
check "dropping the test module of a footprint file is refused" "1" "$ec"
check "the refusal names the file it tests" "1" "$(grep -c 'tests/test_slugify.py is the test module of src/slugify.py, which \(stays in the footprint\|changed in the diff\)' <<<"$out")"
check "a refused drop changes nothing" "1" "$(grep -c '^  - tests/test_slugify.py$' "$DOCS/SPEC.md")"
spec
sed -i 's|^  - src/slugify.py$|  - src/slugify.py\n  - README.md|' "$DOCS/SPEC.md"
ec=0; out="$(bash "$GATE" "$FD" 2>&1)" || ec=$?
check "an untouched non-test file is a flag too" "1" "$(grep -c '^FLAG \[footprint\] README.md is in SPEC.md.s footprint but not in the diff' <<<"$out")"
ec=0; out="$(bash "$DRV" spec footprint drop --feature-dir "$FD" --file docs/none.md --reason "x" 2>&1)" || ec=$?
check "a file outside the footprint cannot be dropped" "1" "$ec"
out="$(bash "$DRV" spec footprint drop --feature-dir "$FD" --file README.md --reason "the fix needs no doc change" 2>/dev/null)"
check "the drop answers with the remaining footprint" "src/slugify.py" "$(jq -r '.footprint | join(",")' <<<"$out")"
check "the file is gone from the footprint" "0" "$(grep -c '^  - README.md$' "$DOCS/SPEC.md")"
check "the decision lands under Implementation notes with its reason" "1" "$(grep -c '^- README.md: dropped from the footprint by cycle-driver.sh spec footprint drop: the fix needs no doc change$' "$DOCS/SPEC.md")"
check "the decision is a ruling in decisions.jsonl" "1" "$(jq -c 'select(.kind == "ruling" and (.question | test("drop README.md")) and .rationale == "the fix needs no doc change")' "$FD/decisions.jsonl" | wc -l | tr -d ' ')"
check "the Intent block is untouched by the drop" "Dots survive slugify." "$(sed -n '/^## Intent$/,/^<!-- \/intent -->$/p' "$DOCS/SPEC.md" | sed -n 3p)"
ec=0; out="$(bash "$GATE" "$FD" 2>&1)" || ec=$?
check "after the recorded drop the gate passes" "0" "$ec"
# The order hole (followup-4, N2): dropping the changed source first does not free its
# test module; a test module of a file in the diff cannot be dropped.
spec; sed -i 's|^  - src/slugify.py$|  - src/slugify.py\n  - tests/test_slugify.py|' "$DOCS/SPEC.md"
bash "$DRV" spec footprint drop --feature-dir "$FD" --file src/slugify.py --reason "try to free the test" >/dev/null 2>&1
ec=0; out="$(bash "$DRV" spec footprint drop --feature-dir "$FD" --file tests/test_slugify.py --reason "now it tests nothing" 2>&1)" || ec=$?
check "dropping the test module after its changed source is still refused" "1" "$ec"
check "the refusal says the source changed in the diff" "1" "$(grep -c 'test module of src/slugify.py, which changed in the diff' <<<"$out")"
# The flow form of the list is handled the same way.
spec; sed -i 's|^footprint:$|footprint: [src/slugify.py, README.md]|; /^  - src\/slugify.py$/d' "$DOCS/SPEC.md"
bash "$DRV" spec footprint drop --feature-dir "$FD" --file README.md --reason "flow form" >/dev/null 2>&1
check "a flow-form footprint loses the file too" "1" "$(grep -c '^footprint: \[src/slugify.py\]$' "$DOCS/SPEC.md")"
spec
# The other direction: a changed file outside the footprint is the fourth file. The
# gate escalates the run itself, names the file, and the --after probe routes to DISCUSS.
printf 'extra\n' >> "$REPO/README.md"; git -C "$REPO" add README.md && git -C "$REPO" commit -q -m "docs: touch readme"
ec=0; out="$(bash "$GATE" "$FD" 2>&1)" || ec=$?
check "a diff file outside the footprint escalates instead of shipping" "0" "$ec"
check "the gate names the file" "1" "$(grep -c '^NOTE \[footprint\] the diff touches README.md outside SPEC.md.s footprint: route: full written' <<<"$out")"
check "route: full is written into the frontmatter" "1" "$(sed -n '1,/^---$/!d; /^route: full$/p' "$DOCS/SPEC.md" | grep -c 'route: full')"
check "the escalation note names the file under Implementation notes" "1" "$(grep -c '^- escalated by lib/oneshot-exit-gate.sh: the diff touches README.md, outside the footprint' "$DOCS/SPEC.md")"
check "the --after probe now routes to the full path" "route=full" "$(bash "$REPO_ROOT/lib/graph/probes/oneshot.sh" --feature-dir "$FD" --after | cut -d' ' -f1)"
git -C "$REPO" reset -q --hard HEAD~1
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

# --- workspace mode: the footprint is checked per repo, against each repo's baseSha ---
WS="$WORK/ws"; mkdir -p "$WS/a/tests" "$WS/b"
printf 'x = 1\n' > "$WS/a/x.py"; printf 'def test_x():\n    assert True\n' > "$WS/a/tests/test_x.py"; printf 'y = 1\n' > "$WS/b/y.py"
for r in a b; do git -C "$WS/$r" init -q -b main && git -C "$WS/$r" add -A && git -C "$WS/$r" commit -q -m init; done
A_SHA="$(git -C "$WS/a" rev-parse HEAD)"; B_SHA="$(git -C "$WS/b" rev-parse HEAD)"
WFD="$WS/.loop-spec/features/ws-fix"; WDOCS="$WS/docs/loop-spec/features/ws-fix"; mkdir -p "$WFD" "$WDOCS"
jq -n --arg ws "$WS" --arg a "$A_SHA" --arg b "$B_SHA" '{schemaVersion:7, slug:"ws-fix", feature_title:"ws fix", autonomous:true, execStyle:"auto",
  workspace:{root:$ws, mode:"workspace", repos:[{name:"a", path:"a", baseSha:$a, branch:"feat/ws-fix", baseBranch:"main"}, {name:"b", path:"b", baseSha:$b, branch:"feat/ws-fix", baseBranch:"main"}]},
  artifacts:{}, warnings:[]}' > "$WFD/feature.json"
sed 's|^  - src/slugify.py$|  - a/x.py\n  - a/tests/test_x.py\n  - b/y.py|; s|^- src/slugify.py: strip dots in slugify().$|- a/x.py: bump x.|; /^- tests\/test_slugify.py: unchanged/d' "$DOCS/SPEC.md" > "$WDOCS/SPEC.md"
printf 'x = 2\n' > "$WS/a/x.py"; git -C "$WS/a" add -A && git -C "$WS/a" commit -q -m "fix: bump x"
ec=0; out="$(cd "$WS" && bash "$GATE" "$WFD" 2>&1)" || ec=$?
check "workspace mode: the footprint check runs per repo (the untouched test module in repo a flags)" "1" "$(grep -c '^FLAG \[footprint\] a/tests/test_x.py is in SPEC.md.s footprint but not in the diff' <<<"$out")"
check "workspace mode: an untouched non-test file in repo b flags too" "1" "$(grep -c '^FLAG \[footprint\] b/y.py is in SPEC.md.s footprint but not in the diff' <<<"$out")"
check "workspace mode: the changed file in repo a satisfies the footprint" "0" "$(grep -c 'a/x.py' <<<"$out")"
printf 'z = 1\n' > "$WS/b/z.py"; git -C "$WS/b" add -A && git -C "$WS/b" commit -q -m "feat: z"
sed -i 's|^  - a/tests/test_x.py$||' "$WDOCS/SPEC.md"; sed -i '/^- b\/y.py: unchanged; dropped/d; /^route: full$/d; /^- escalated by/d' "$WDOCS/SPEC.md"
ec=0; out="$(cd "$WS" && bash "$GATE" "$WFD" 2>&1)" || ec=$?
check "workspace mode: a changed file outside the footprint in repo b escalates" "1" "$(grep -c '^NOTE \[footprint\] the diff touches b/z.py outside' <<<"$out")"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
