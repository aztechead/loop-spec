#!/usr/bin/env bash
# Tests for lib/plan-render.sh -- PLAN.md's task sections are produced from tasks.json.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/lib/plan-render.sh"
LINT="$REPO_ROOT/lib/artifact-lint.sh"
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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/plan-render.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/tasks.json" <<'JSON'
[{"id":"task-001","subject":"Correct root.hcl","goal":"state the 1.x bootstrap","files":["root.hcl"],
  "read_first":["root.hcl:1-18"],"interfaces":{"consumes":"none","produces":"root.hcl header"},
  "blockedBy":[],"verifyCommand":"grep -qF 'expose = true' root.hcl","expected":"exit 0",
  "acceptanceCriteria":["grep -qF 'expose = true' root.hcl exits 0"],"steps":["run the verify, expect FAIL","edit","run the verify, expect PASS"]},
 {"id":"task-002","title":"Move the unit onto expose","files":["site/terragrunt.hcl"],"blockedBy":["task-001"],
  "verifyCommand":"terragrunt plan -lock=false | grep -qF 'No changes.'","acceptanceCriteria":["the plan prints No changes."]}]
JSON

# Stdout form renders both sections in the template's shape.
out="$(bash "$LIB" render --tasks "$WORK/tasks.json")"
check "renders the Task DAG heading" "1" "$(grep -c '^## Task DAG$' <<<"$out")"
check "renders one DAG row per task" "2" "$(grep -c '^| task-' <<<"$out")"
check "renders the task heading in template form" "1" "$(grep -c '^### task-001: Correct root.hcl$' <<<"$out")"
check "title is accepted as subject" "1" "$(grep -c '^### task-002: Move the unit onto expose$' <<<"$out")"
check "every block carries the three lint labels" "6" "$(grep -c -E '^\*\*(Files|Verify|Acceptance criteria):\*\*' <<<"$out")"
check "blockedBy is rendered" "1" "$(grep -c '^\*\*blockedBy:\*\* task-001$' <<<"$out")"
check "steps are rendered as checkboxes" "3" "$(grep -c '^- \[ \] Step ' <<<"$out")"

# In-place form replaces the two sections and preserves everything else.
cat > "$WORK/PLAN.md" <<'MD'
# Feature - Implementation Plan

## Architecture overview

Two sentences.

## Task DAG

| ID | Subject | BlockedBy | Files | Est scope |
|----|---------|-----------|-------|-----------|
| task-999 | stale | - | x | small |

## Tasks

### task-999: stale

**Files:**
- x

## Test strategy

Run it.

## Grounding

- none
MD
bash "$LIB" render --tasks "$WORK/tasks.json" --plan "$WORK/PLAN.md" >/dev/null
check "in place: stale block is gone" "0" "$(grep -c 'task-999' "$WORK/PLAN.md")"
check "in place: new blocks present" "2" "$(grep -c '^### task-00' "$WORK/PLAN.md")"
check "in place: prose before is kept" "1" "$(grep -c '^Two sentences.$' "$WORK/PLAN.md")"
check "in place: sections after are kept" "1" "$(grep -c '^## Grounding$' "$WORK/PLAN.md")"
check "in place: Test strategy still follows Tasks" "1" "$(awk '/^## Tasks/{t=1} /^## Test strategy/{if(t) print "ok"}' "$WORK/PLAN.md" | grep -c ok)"
before="$(cat "$WORK/PLAN.md")"; bash "$LIB" render --tasks "$WORK/tasks.json" --plan "$WORK/PLAN.md" >/dev/null
check "in place: idempotent" "1" "$([[ "$before" == "$(cat "$WORK/PLAN.md")" ]] && echo 1 || echo 0)"

# A plan without the sections gets them inserted before Test strategy.
cat > "$WORK/PLAN2.md" <<'MD'
# Feature - Implementation Plan

## Architecture overview

Prose.

## Test strategy

Run it.
MD
bash "$LIB" render --tasks "$WORK/tasks.json" --plan "$WORK/PLAN2.md" >/dev/null
check "absent sections: inserted before Test strategy" "1" "$(awk '/^## Tasks/{t=1} /^## Test strategy/{if(t) print "ok"}' "$WORK/PLAN2.md" | grep -c ok)"

# The rendered task sections satisfy the artifact lint's task-block rules.
lint="$(bash "$LINT" plan "$WORK/PLAN.md" 2>&1 || true)"
check "rendered blocks pass the lint's task-block checks" "0" "$(grep -c -E "task block .* is missing|no '### task-<id>:' blocks|Task DAG' table has no" <<<"$lint")"

# decisions: SPEC statements the plan lacks are copied verbatim; the coverage gate then passes.
cat > "$WORK/SPEC.md" <<'MD'
# Spec

<decisions>
- Decision: no OpenTofu, Terragrunt, or provider version bumps. Rationale: scope. Alternatives considered: bumping.
- the existing unit directory `site` never moves or is renamed.
</decisions>
MD
printf '# Plan\n\n## Architecture overview\n\nProse.\n\n## User decisions (already made)\n\n- **bumps**: no OpenTofu, Terragrunt, or provider version bumps. Source: SPEC.\n\n## Global constraints\n\n- none\n' > "$WORK/PLAN3.md"
out="$(bash "$LIB" decisions --spec "$WORK/SPEC.md" --plan "$WORK/PLAN3.md")"
check "decisions: only the missing statement is copied" "plan-render: copied 1 decision(s) into $WORK/PLAN3.md" "$out"
check "decisions: the copy lands under the existing section" "1" "$(awk '/^## User decisions/{s=1} /^## Global/{s=0} s && /never moves or is renamed/{print "ok"}' "$WORK/PLAN3.md" | grep -c ok)"
check "decisions: the coverage gate passes afterwards" "0" "$(bash "$REPO_ROOT/lib/decision-coverage.sh" "$WORK/SPEC.md" "$WORK/PLAN3.md" >/dev/null 2>&1; echo $?)"
check "decisions: idempotent" "plan-render: decisions already covered (2)" "$(bash "$LIB" decisions --spec "$WORK/SPEC.md" --plan "$WORK/PLAN3.md")"
printf '# Plan\n\n## Architecture overview\n\nProse.\n\n## Global constraints\n\n- none\n' > "$WORK/PLAN4.md"
bash "$LIB" decisions --spec "$WORK/SPEC.md" --plan "$WORK/PLAN4.md" >/dev/null
check "decisions: the section is created before Global constraints" "1" "$(awk '/^## User decisions/{u=NR} /^## Global constraints/{g=NR} END{print (u && g && u<g) ? 1 : 0}' "$WORK/PLAN4.md")"

# prose-lines counts what the pruner would read: everything outside the rendered span.
check "prose-lines counts lines outside the rendered sections" "7" "$(bash "$LIB" prose-lines --plan "$WORK/PLAN.md")"
ec=0; bash "$LIB" prose-lines --plan "$WORK/nope.md" >/dev/null 2>&1 || ec=$?
check "prose-lines on a missing plan exits 1" "1" "$ec"

# Failure paths are loud.
ec=0; bash "$LIB" render --tasks "$WORK/nope.json" >/dev/null 2>&1 || ec=$?
check "missing tasks file exits 1" "1" "$ec"
printf '{"x":1}\n' > "$WORK/bad.json"; ec=0; bash "$LIB" render --tasks "$WORK/bad.json" >/dev/null 2>&1 || ec=$?
check "non-array tasks exits 1" "1" "$ec"
ec=0; bash "$LIB" >/dev/null 2>&1 || ec=$?
check "no arguments exits 2" "2" "$ec"

# --- task-005: requirements/obligations/executionInputs round-trip -----------------
# Many-to-many (task-001 and task-002 both name GE-001; task-002 also names GE-002)
# and an Obligations-only scaffolding task (task-003, no Requirements at all).
python3 -c "
import json
rev1 = '1' * 64
rev2 = '2' * 64
owner = {'repository': 'r', 'feature': 'f'}
inputs = {'version': 1, 'toolchains': [], 'localInputs': [], 'externalInputs': [], 'sensitiveInputs': []}
tasks = [
    {'id': 'task-001', 'subject': 'first', 'files': ['a.sh'], 'blockedBy': [],
     'verifyCommand': 'bash -n a.sh', 'acceptanceCriteria': ['exits 0'],
     'requirements': [{'owner': owner, 'requirement': 'GE-001', 'revision': rev1, 'scenarios': ['SC-001']}],
     'executionInputs': inputs},
    {'id': 'task-002', 'subject': 'second', 'files': ['b.sh'], 'blockedBy': ['task-001'],
     'verifyCommand': 'bash -n b.sh', 'acceptanceCriteria': ['exits 0'],
     'requirements': [{'owner': owner, 'requirement': 'GE-001', 'revision': rev1, 'scenarios': ['SC-002']},
                       {'owner': owner, 'requirement': 'GE-002', 'revision': rev2, 'scenarios': ['SC-001']}],
     'executionInputs': inputs},
    {'id': 'task-003', 'subject': 'scaffolding only', 'files': ['c.sh'], 'blockedBy': [],
     'verifyCommand': 'bash -n c.sh', 'acceptanceCriteria': ['exits 0'],
     'obligations': ['OBL-runtime'], 'executionInputs': inputs},
]
json.dump(tasks, open('$WORK/tasks-v1.json', 'w'), indent=2)
"
bash "$LIB" render --tasks "$WORK/tasks-v1.json" --plan /dev/null >/dev/null 2>&1
rendered="$(bash "$LIB" render --tasks "$WORK/tasks-v1.json")"
check "renders a Requirements marker per task that has one" "2" "$(grep -c '^\*\*Requirements:\*\*$' <<<"$rendered")"
check "renders an Obligations marker for the scaffolding task" "1" "$(grep -c '^\*\*Obligations:\*\*$' <<<"$rendered")"
check "renders an Execution inputs line per task" "3" "$(grep -c '^\*\*Execution inputs:\*\*' <<<"$rendered")"
check "task-002 keeps both requirement references (many-to-many)" "2" \
  "$(awk '/^### task-002:/{t=1} /^### task-003:/{t=0} t' <<<"$rendered" | grep -c '"requirement":"GE-00')"

printf '# v1 fixture - Implementation Plan\n\n%s\n' "$rendered" > "$WORK/PLAN-v1.md"
printf '\n## Grounding\n\n- none\n' >> "$WORK/PLAN-v1.md"
reextracted="$(bash "$REPO_ROOT/lib/plan-tasks.sh" extract "$WORK/PLAN-v1.md")"
check "round trip: extract -> render -> extract yields the same JSON" "true" \
  "$(jq -n --argjson a "$(jq -Sc . "$WORK/tasks-v1.json")" --argjson b "$(jq -Sc . <<<"$reextracted")" '$a == $b' 2>/dev/null || echo false)"
rc=0; bash "$LINT" plan "$WORK/PLAN-v1.md" >/dev/null 2>&1 || rc=$?
check "the rendered v1 plan passes the structural plan lint" "0" "$rc"
rc=0; bash "$LINT" tasks - <<<"$reextracted" >/dev/null 2>&1 || rc=$?
check "the round-tripped tasks pass the structural tasks lint" "0" "$rc"

echo
echo "plan-render: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
