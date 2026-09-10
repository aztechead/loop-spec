#!/usr/bin/env bash
# Tests for lib/context-load.sh: the lines a phase skill makes the lead read, and the
# bound on the short route (port audit 1, F3).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/lib/context-load.sh"
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

WORK="${TMPDIR:-/tmp}/context-load-test.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/skills/demo/references" "$WORK/skills/shared/artifact-templates"
# The body cites a whole contract, one section of another, a template, its own
# reference, and a script; the whole contract cites a third file the lead never reads.
cat > "$WORK/skills/demo/SKILL.md" <<'MD'
# demo
Read `skills/shared/whole.md` and `skills/shared/parts.md#Second part`.
Write from `skills/shared/artifact-templates/T.md.template`; the bank is
`${CLAUDE_SKILL_DIR}/references/bank.md`; run `lib/probe.sh` and `lib/probe.sh` again.
Cite `skills/shared/whole.md` twice: it is counted once.
MD
printf '# whole\nline\nline\nSee `skills/shared/far.md`.\n' > "$WORK/skills/shared/whole.md"
printf '# far\nline\nline\nline\nline\nline\nline\nline\nline\n' > "$WORK/skills/shared/far.md"
printf '# parts\nintro\n## First part\na\nb\n## Second part\nc\nd\ne\n### Under second\nf\n## Third part\ng\n' > "$WORK/skills/shared/parts.md"
printf 'one\ntwo\n' > "$WORK/skills/shared/artifact-templates/T.md.template"
printf 'q1\nq2\nq3\n' > "$WORK/skills/demo/references/bank.md"

out="$(bash "$LIB" sum skills/demo/SKILL.md --root "$WORK")"
check "sum: the body counts" "5	skills/demo/SKILL.md" "$(sed -n 1p <<<"$out")"
check "sum: a whole contract counts every line" "1" "$(grep -c '^4	skills/shared/whole.md$' <<<"$out")"
check "sum: a section runs from its heading to the next of the same or a higher level (its subsections included)" "1" "$(grep -c '^6	skills/shared/parts.md#Second part$' <<<"$out")"
check "sum: a template counts" "1" "$(grep -c '^2	skills/shared/artifact-templates/T.md.template$' <<<"$out")"
check "sum: a skill reference resolves against its own skill dir" "1" "$(grep -c '^3	skills/demo/references/bank.md$' <<<"$out")"
check "sum: a script is executed, not read" "0" "$(grep -c 'probe.sh' <<<"$out")"
check "sum: a cite inside a cited contract is not followed at depth one" "0" "$(grep -c 'far.md' <<<"$out")"
check "sum: a file cited twice is counted once" "1" "$(grep -c 'whole.md' <<<"$out")"
check "sum: the total is the sum of the rows" "TOTAL 20" "$(tail -1 <<<"$out")"
check "sum --transitive follows the contract's own cites" "TOTAL 29" "$(bash "$LIB" sum skills/demo/SKILL.md --root "$WORK" --transitive | tail -1)"
check "cites: the reading list, body excluded" "skills/shared/whole.md skills/shared/parts.md#Second part skills/shared/artifact-templates/T.md.template skills/demo/references/bank.md" \
  "$(bash "$LIB" cites skills/demo/SKILL.md --root "$WORK" | paste -sd' ')"
check "a section entry as the body counts only that section" "TOTAL 6" "$(bash "$LIB" sum 'skills/shared/parts.md#Second part' --root "$WORK" | tail -1)"
printf 'Read `skills/shared/gone.md`.\n' > "$WORK/skills/demo/references/dead.md"
check "a cite to nothing is a failure, not an average" "2" "$(bash "$LIB" sum skills/demo/references/dead.md --root "$WORK" >/dev/null 2>&1; echo $?)"
check "the failure names the cite" "1" "$(bash "$LIB" sum skills/demo/references/dead.md --root "$WORK" 2>&1 >/dev/null | grep -c 'no such file or section: skills/shared/gone.md')"
check "a section that does not exist is a failure" "2" "$(bash "$LIB" sum 'skills/shared/parts.md#Fourth part' --root "$WORK" >/dev/null 2>&1; echo $?)"
check "bad invocation exits 2" "2" "$(bash "$LIB" tally x >/dev/null 2>&1; echo $?)"
check "no entry exits 2" "2" "$(bash "$LIB" sum --root "$WORK" >/dev/null 2>&1; echo $?)"

# --- the bound: the short route's reading list ------------------------------------------
# The short route loads three bodies, the cycle skill, the lite spec skill the spec node
# names, and the oneshot skill, each with what it cites. The bound is the audit's, over
# the path and not one skill (port audit 3, N4): 600 lines. The full SPEC body is loaded
# only when the lite skill hands to it, and is bounded on its own so it cannot creep.
ONESHOT_PATH_MAX=600
SPEC_BODY_MAX=230
total="$(bash "$LIB" sum skills/cycle/SKILL.md skills/spec-lite/SKILL.md skills/oneshot/SKILL.md --root "$REPO_ROOT" | tail -1 | cut -d' ' -f2)"
echo "short route (cycle + spec-lite + oneshot, with cites): $total lines (bound $ONESHOT_PATH_MAX)"
check "the short route's three bodies with their cites are at or under $ONESHOT_PATH_MAX lines" "1" "$(( total <= ONESHOT_PATH_MAX ))"
check "the spec node names the lite skill the bound counts" "spec-lite" "$(jq -r '.nodes[] | select(.id == "spec") | .skill' "$REPO_ROOT/graph/cycle.graph.json")"
spec_lines="$(wc -l < "$REPO_ROOT/skills/spec/SKILL.md")"
echo "spec skill body: $spec_lines lines (bound $SPEC_BODY_MAX); its whole reading list: $(bash "$LIB" sum skills/spec/SKILL.md --root "$REPO_ROOT" | tail -1)"
check "the spec skill body stays under $SPEC_BODY_MAX lines" "1" "$(( spec_lines <= SPEC_BODY_MAX ))"
check "every cite on the short route and the full spec resolves" "0" "$(bash "$LIB" sum skills/spec/SKILL.md skills/spec-lite/SKILL.md skills/oneshot/SKILL.md skills/cycle/SKILL.md --root "$REPO_ROOT" >/dev/null 2>&1; echo $?)"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
