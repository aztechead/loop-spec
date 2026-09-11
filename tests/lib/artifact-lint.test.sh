#!/usr/bin/env bash
# Offline unit suite for lib/artifact-lint.sh — the structural format gate that keeps
# one phase's model-authored artifact from arriving misformatted at the next phase.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/lib/artifact-lint.sh"
WORK="${TMPDIR:-/tmp}/loop-spec-artifact-lint.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"
PASS=0; FAIL=0

check() {
  local name="$1" expected_rc="$2"; shift 2
  local rc=0 out
  out="$(bash "$SCRIPT" "$@" 2>&1)" || rc=$?
  if [[ "$rc" == "$expected_rc" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected rc=$expected_rc, got rc=$rc)"; echo "$out" | sed 's/^/    /'
    FAIL=$((FAIL + 1))
  fi
}

check_output() {
  local name="$1" pattern="$2"; shift 2
  local out
  out="$(bash "$SCRIPT" "$@" 2>&1 || true)"
  if grep -qF "$pattern" <<<"$out"; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (output missing '$pattern')"; echo "$out" | sed 's/^/    /'
    FAIL=$((FAIL + 1))
  fi
}

# --- invocation ---
check "no args is usage error" 2
check "unknown type is usage error" 2 bogus "$WORK/x.md"
check "missing file flags, does not crash" 1 spec "$WORK/does-not-exist.md"

# --- spec ---
cat > "$WORK/spec-good.md" <<'EOF'
---
unresolved_questions: []
---
# My Feature

## Problem

Something is broken.

## Success criteria

### Good Enough

- [ ] `bash tests/run-all.sh` exits 0
- [x] a done criterion

### Exceptional

- [ ] stretch

## Grounding

- none
EOF
check "well-formed spec passes (frontmatter allowed)" 0 spec "$WORK/spec-good.md"
sed 's/unresolved_questions: .*/unresolved_questions: ["Should empty input fail, or return nothing?"]/' "$WORK/spec-good.md" > "$WORK/spec-open.md"
check "a concrete unanswered question blocks SPEC" 1 spec "$WORK/spec-open.md"
check_output "question itself appears in the failure" "Should empty input fail, or return nothing?" spec "$WORK/spec-open.md"
sed 's/unresolved_questions: .*/unresolved_questions: null/' "$WORK/spec-good.md" > "$WORK/spec-invalid.md"
check "null questions cannot pass as resolved" 1 spec "$WORK/spec-invalid.md"
sed '/unresolved_questions:/d' "$WORK/spec-good.md" > "$WORK/spec-missing-questions.md"
check "missing question field fails closed" 1 spec "$WORK/spec-missing-questions.md"

sed '/^unresolved_questions:/a\
requirements_version: 999
' "$WORK/spec-good.md" > "$WORK/spec-unknown-version.md"
check "explicit unknown requirements version cannot use legacy" 1 spec "$WORK/spec-unknown-version.md"

sed -e '/^unresolved_questions:/a\
requirements_version: 1\
requirements_owner: {"repository":"repo","feature":"feature"}
' -e 's/^- \[ \] `bash tests\/run-all.sh` exits 0/- [ ] GE-001: The suite passes.\
  - SC-001: The suite exits zero./' -e 's/^- \[x\] a done criterion/- [x] GE-002: Other behavior works.\
  - SC-001: Its result is visible./' "$WORK/spec-good.md" > "$WORK/spec-v1.md"
check "well-formed explicit v1 passes" 0 spec "$WORK/spec-v1.md"
sed 's/GE-002/GE-001/' "$WORK/spec-v1.md" > "$WORK/spec-v1-duplicate.md"
check "explicit v1 duplicate identities fail" 1 spec "$WORK/spec-v1-duplicate.md"
python3 - "$WORK/spec-oversized.md" <<'PYTEST'
import sys
with open(sys.argv[1], 'wb') as stream:
    stream.write(b'x' * (16 * 1024 * 1024 + 1))
PYTEST
check "oversized SPEC fails before parsing" 1 spec "$WORK/spec-oversized.md"
check_output "oversized SPEC names the limit" "SPEC exceeds 16 MiB" spec "$WORK/spec-oversized.md"

# Both shapes, from the fixtures: the full SPEC opens with Problem, the oneshot SPEC
# with the ask in a frozen Intent block and Implementation notes.
check "the full-shape fixture passes" 0 spec "$ROOT/tests/fixtures/real-SPEC.md"
check "the oneshot-shape fixture passes" 0 spec "$ROOT/tests/fixtures/oneshot-SPEC.md"
sed '/^<!-- intent: frozen/d' "$ROOT/tests/fixtures/oneshot-SPEC.md" > "$WORK/spec-unfrozen.md"
check "an Intent without the frozen opener flags" 1 spec "$WORK/spec-unfrozen.md"
check_output "the flag names the frozen block" "has no \`<!-- intent: frozen" spec "$WORK/spec-unfrozen.md"
sed '/^<!-- \/intent -->$/d' "$ROOT/tests/fixtures/oneshot-SPEC.md" > "$WORK/spec-unclosed-intent.md"
check "an Intent block without its close flags" 1 spec "$WORK/spec-unclosed-intent.md"
check_output "the flag names the close marker" "not closed with" spec "$WORK/spec-unclosed-intent.md"
sed 's/^## Implementation notes$/## Notes/' "$ROOT/tests/fixtures/oneshot-SPEC.md" > "$WORK/spec-nonotes.md"
check "an oneshot spec without Implementation notes flags" 1 spec "$WORK/spec-nonotes.md"
sed 's/^## Problem$/## Context/' "$WORK/spec-good.md" > "$WORK/spec-noproblem.md"
check "a spec with neither Problem nor Intent flags" 1 spec "$WORK/spec-noproblem.md"
check_output "the flag names both shapes" "or a frozen '## Intent' block" spec "$WORK/spec-noproblem.md"

sed 's/### Good Enough/### Good enough/' "$WORK/spec-good.md" > "$WORK/spec-heading.md"
check "case-drifted Good Enough heading flags" 1 spec "$WORK/spec-heading.md"
check_output "Good Enough drift names the missing heading" \
  "missing required section heading '### Good Enough'" spec "$WORK/spec-heading.md"

cat > "$WORK/spec-nochecks.md" <<'EOF'
# My Feature

## Problem

x

## Success criteria

### Good Enough

The feature works well.

## Grounding

- none
EOF
check "Good Enough without checkboxes flags" 1 spec "$WORK/spec-nochecks.md"

# whole-file code-fence wrap (a real model failure mode)
{ echo '```markdown'; cat "$WORK/spec-good.md"; echo '```'; } > "$WORK/spec-fenced.md"
check "spec wrapped in a code fence flags" 1 spec "$WORK/spec-fenced.md"
check_output "fence wrap is named" "wrapped in" spec "$WORK/spec-fenced.md"

printf '# T\r\n\r\n## Problem\r\nx\r\n' > "$WORK/spec-crlf.md"
check "CRLF line endings flag" 1 spec "$WORK/spec-crlf.md"

: > "$WORK/empty.md"
check "empty artifact flags" 1 spec "$WORK/empty.md"

# unclosed fence: headings hidden inside it must still be found (renderer auto-closes)
cat > "$WORK/spec-unclosed.md" <<'EOF'
# My Feature

## Problem

```bash
echo unclosed fence

## Success criteria

### Good Enough

- [ ] criterion

## Grounding

- none
EOF
check "unclosed fence flags" 1 spec "$WORK/spec-unclosed.md"
check_output "unclosed fence is named" "unbalanced code fence" spec "$WORK/spec-unclosed.md"

# headings inside a CLOSED fence must NOT satisfy section requirements
cat > "$WORK/spec-hidden.md" <<'EOF'
# My Feature

```markdown
## Problem
## Success criteria
### Good Enough
- [ ] fake
## Grounding
```

Prose only.
EOF
check "headings inside a closed fence do not count" 1 spec "$WORK/spec-hidden.md"

cat > "$WORK/spec-placeholder.md" <<'EOF'
# {feature_title}

## Problem

x

## Success criteria

### Good Enough

- [ ] criterion

## Grounding

- none
EOF
check "unfilled template placeholder flags" 1 spec "$WORK/spec-placeholder.md"
check_output "placeholder line is named" "unfilled template placeholder" spec "$WORK/spec-placeholder.md"

# --- plan ---
cat > "$WORK/plan-good.md" <<'EOF'
# My Feature - Implementation Plan

**Spec:** `docs/loop-spec/features/my-feature/SPEC.md`

## Architecture overview

Two tasks. Note: prose may mention `.loop-spec/features/{slug}/` paths legitimately.

## Task DAG

| ID | Subject | BlockedBy | Files | Est scope |
|----|---------|-----------|-------|-----------|
| task-001 | do a thing | - | a.sh | small |
| task-002 | do more | task-001 | b.sh | small |

## Tasks

### task-001: do a thing

**Goal:** one sentence.

**Files:**
- `a.sh`

**Verify:** `bash -n a.sh`

**Acceptance criteria:**
- [ ] `bash -n a.sh` exits 0

### task-002: do more

**Files:**
- `b.sh`

**Verify:** `bash -n b.sh`

**Acceptance criteria:**
- [ ] `bash -n b.sh` exits 0

## Grounding

- none
EOF
check "well-formed plan passes" 0 plan "$WORK/plan-good.md"

# The System design block ships as placeholders; one left in place is template text
# where the stance's deliverable should be.
sed 's/^## Task DAG/## System design\n\n- Architecture: {components and their owners}\n\n## Task DAG/' \
    "$WORK/plan-good.md" > "$WORK/plan-system-design-unfilled.md"
check "unfilled System design placeholder flags" 1 plan "$WORK/plan-system-design-unfilled.md"
check_output "System design placeholder line is named" "unfilled template placeholder" plan "$WORK/plan-system-design-unfilled.md"

# colon-outside-the-bold marker variant ('**Files**:') must not force a repair round
sed -e 's/\*\*Files:\*\*/**Files**:/' -e 's/\*\*Verify:\*\* /**Verify**: /' \
    -e 's/\*\*Acceptance criteria:\*\*/**Acceptance criteria**:/' \
    "$WORK/plan-good.md" > "$WORK/plan-colon-outside.md"
check "colon-outside-bold markers pass" 0 plan "$WORK/plan-colon-outside.md"

grep -v '^\*\*Verify:\*\*' "$WORK/plan-good.md" > "$WORK/plan-noverify.md"
check "task block without Verify flags" 1 plan "$WORK/plan-noverify.md"
check_output "missing Verify names the task" \
  "task block task-001 is missing '**Verify:**'" plan "$WORK/plan-noverify.md"

sed 's/### task-002: do more/### task-001: do more/' "$WORK/plan-good.md" > "$WORK/plan-dup.md"
check "duplicate task ids flag" 1 plan "$WORK/plan-dup.md"

cat > "$WORK/plan-notasks.md" <<'EOF'
# Plan

## Task DAG

| ID |
|----|

## Tasks

The work is straightforward.
EOF
check "plan with no task blocks flags" 1 plan "$WORK/plan-notasks.md"
check_output "no task blocks message points at template" \
  "EXECUTE Step 2a parses these blocks" plan "$WORK/plan-notasks.md"

cat > "$WORK/plan-emptyac.md" <<'EOF'
# Plan

## Task DAG

| task-001 |

## Tasks

### task-001: thing

**Files:**
- a.sh

**Verify:** `true`

**Acceptance criteria:**

**Steps:**
- [ ] Step 1
EOF
check "Acceptance criteria marker with no items flags" 1 plan "$WORK/plan-emptyac.md"

# --- patterns ---
printf '# PATTERNS.md - feat\n\n## Concept: writer\n\ndetail\n' > "$WORK/patterns-good.md"
check "patterns with a Concept section passes" 0 patterns "$WORK/patterns-good.md"
printf '# PATTERNS.md - feat\n\nno sections at all\n' > "$WORK/patterns-bare.md"
check "patterns without sections flags" 1 patterns "$WORK/patterns-bare.md"

# --- verification ---
cat > "$WORK/verif-good.md" <<'EOF'
# My Feature - Verification

## Repository grounding

- criterion: GE-001 | implementation: a.sh:1 - proves it | integration: none - covered by unit scope

## Acceptance criteria

| # | Criterion | Status | Evidence |
|---|-----------|--------|----------|
| 1 | it works | PASS | `true` -> ok |
EOF
check "well-formed verification passes" 0 verification "$WORK/verif-good.md"

grep -v '^## Repository grounding' "$WORK/verif-good.md" > "$WORK/verif-norows.md"
check "verification without Repository grounding flags" 1 verification "$WORK/verif-norows.md"

cat > "$WORK/verif-notable.md" <<'EOF'
# V

## Repository grounding

- criterion: GE-001 | implementation: a.sh:1 - x | integration: none - because reasons

## Acceptance criteria

All criteria pass, trust me.
EOF
check "acceptance criteria without table rows flags" 1 verification "$WORK/verif-notable.md"

# --- tasks ---
cat > "$WORK/tasks-good.json" <<'EOF'
[
  {"id": "task-001", "brief": "do a thing", "files": ["a.sh"], "blockedBy": [],
   "verifyCommand": "bash -n a.sh", "acceptanceCriteria": ["exits 0"],
   "readFirst": ["lib/x.sh"], "specPath": null},
  {"id": "task-002", "subject": "do more", "files": [], "blockedBy": ["task-001"],
   "verifyCommand": "true", "acceptanceCriteria": ["ok"]}
]
EOF
check "well-formed tasks pass" 0 tasks "$WORK/tasks-good.json"

printf '[{"id":"task-001","brief":"x","files":[],"blockedBy":[],"verifyCommand":"true","acceptanceCriteria":["ok"],"status":"done"}]' \
  > "$WORK/tasks-done.json"
check "status=done is accepted" 0 tasks "$WORK/tasks-done.json"

printf '[{"id":"task-001","brief":"x","files":[],"blockedBy":[],"verifyCommand":"true","acceptanceCriteria":["ok"],"status":"merged"}]' \
  > "$WORK/tasks-badstatus.json"
check "unknown status flags" 1 tasks "$WORK/tasks-badstatus.json"
check_output "unknown status is named" "pending or done" tasks "$WORK/tasks-badstatus.json"

check "tasks from stdin works" 0 tasks - < "$WORK/tasks-good.json"

printf '[{"id": "task-001"}]' > "$WORK/tasks-missing.json"
check "task missing required fields flags" 1 tasks "$WORK/tasks-missing.json"
check_output "missing verifyCommand is named" "verifyCommand" tasks "$WORK/tasks-missing.json"

printf '{"tasks": []}' > "$WORK/tasks-obj.json"
check "tasks as object (not array) flags" 1 tasks "$WORK/tasks-obj.json"

printf '[{"id": "task-001", "brief": "x", "files": [], "blockedBy": ["task-999"], "verifyCommand": "true", "acceptanceCriteria": ["ok"]}]' > "$WORK/tasks-dangle.json"
check "dangling blockedBy reference flags" 1 tasks "$WORK/tasks-dangle.json"
check_output "dangling edge names the unknown id" "task-999" tasks "$WORK/tasks-dangle.json"

printf '[{"id": "task-001", "brief": "x", "files": [], "blockedBy": [], "verifyCommand": "  ", "acceptanceCriteria": ["ok"]}]' > "$WORK/tasks-blankvc.json"
check "whitespace-only verifyCommand flags" 1 tasks "$WORK/tasks-blankvc.json"

printf 'not json' > "$WORK/tasks-bad.json"
check "invalid tasks JSON flags (not crash)" 1 tasks "$WORK/tasks-bad.json"

# fence-wrapped JSON (a real model failure mode) gets a precise, one-shot-fixable flag
{ echo '```json'; cat "$WORK/tasks-good.json"; echo '```'; } > "$WORK/tasks-fenced.json"
check "fence-wrapped tasks JSON flags" 1 tasks "$WORK/tasks-fenced.json"
check_output "fence wrap on JSON is named" "markdown code fence" tasks "$WORK/tasks-fenced.json"

printf '\xef\xbb\xbf{"a": 1}' > "$WORK/tasks-bom.json"
check "BOM-prefixed JSON flags" 1 json "$WORK/tasks-bom.json"
check_output "BOM is named" "UTF-8 BOM" json "$WORK/tasks-bom.json"

# --- json ---
printf '{"a": 1}' > "$WORK/ok.json"
printf '{"a": 1,}' > "$WORK/trailing.json"
check "valid json passes" 0 json "$WORK/ok.json"
check "trailing-comma json flags" 1 json "$WORK/trailing.json"
check "multi-file json: one bad file fails the batch" 1 json "$WORK/ok.json" "$WORK/trailing.json"

printf '[{"id": "task-001", "brief": "x", "files": [], "blockedBy": [], "verifyCommand": "true", "acceptanceCriteria": ["ok"], "batchGroup": "rename-foo", "modelTier": "mechanical", "interfaces": {"consumes": "none", "produces": "Foo"}}]' > "$WORK/tasks-optional.json"
check "optional batchGroup, modelTier, interfaces pass" 0 tasks "$WORK/tasks-optional.json"

printf '[{"id": "task-001", "brief": "x", "files": [], "blockedBy": [], "verifyCommand": "true", "acceptanceCriteria": ["ok"], "batchGroup": "  "}]' > "$WORK/tasks-blank-bg.json"
check "whitespace-only batchGroup flags" 1 tasks "$WORK/tasks-blank-bg.json"

printf '[{"id": "task-001", "brief": "x", "files": [], "blockedBy": [], "verifyCommand": "true", "acceptanceCriteria": ["ok"], "modelTier": "haiku"}]' > "$WORK/tasks-bad-tier.json"
check "unknown modelTier flags" 1 tasks "$WORK/tasks-bad-tier.json"

# --- task-005: Requirements/Obligations/Execution inputs structural shape ----------
# A minimal v1 feature dir (skeleton always bootstraps v1 by default) --
# feature_read.load_state only reads feature.json, so no git checkout is needed here.
V1DIR="$WORK/v1-feature"
mkdir -p "$V1DIR"
bash "$ROOT/lib/feature-init.sh" skeleton --mode single \
  --slug demo --now N --style auto --branch feat/demo --base-sha abc --base-branch main --worktree wt \
  > "$V1DIR/feature.json"
if jq -e '.requirementsContract.format == "v1"' "$V1DIR/feature.json" >/dev/null 2>&1; then
  echo "PASS: v1 fixture: feature.json records format v1"; PASS=$((PASS + 1))
else
  echo "FAIL: v1 fixture: feature.json records format v1"; FAIL=$((FAIL + 1))
fi
LEGACYDIR="$WORK/legacy-feature"
mkdir -p "$LEGACYDIR"
bash "$ROOT/lib/feature-init.sh" skeleton --mode single \
  --slug legacy --now N --style auto --branch feat/legacy --base-sha abc --base-branch main --worktree wt \
  > "$LEGACYDIR/feature.json"
# skeleton always bootstraps v1 now; strip it to model a legacy fixture (a resumed
# pre-7 cycle bootstraps this way itself, via begin_operation, never a switch).
jq 'del(.requirementsContract) | del(.artifactPublication)' "$LEGACYDIR/feature.json" > "$LEGACYDIR/feature.json.tmp"
mv "$LEGACYDIR/feature.json.tmp" "$LEGACYDIR/feature.json"
if jq -e 'has("requirementsContract") | not' "$LEGACYDIR/feature.json" >/dev/null 2>&1; then
  echo "PASS: legacy fixture: feature.json carries no requirementsContract"; PASS=$((PASS + 1))
else
  echo "FAIL: legacy fixture: feature.json carries no requirementsContract"; FAIL=$((FAIL + 1))
fi

req_block() {  # $1 requirement JSON bullet text (the raw line after '- ')
  printf '# Plan\n\n## Task DAG\n\n| ID | Subject | BlockedBy | Files | Est scope |\n|----|---------|-----------|-------|-----------|\n| task-001 | x | - | a.sh | small |\n\n## Tasks\n\n### task-001: x\n\n**Files:**\n- a.sh\n\n**Requirements:**\n- %s\n\n**Verify:** `true`\n\n**Acceptance criteria:**\n- [ ] ok\n' "$1"
}
good_rev="1234567890123456789012345678901234567890123456789012345678901234"
good_owner='{"repository":"r","feature":"f"}'

# 1. malformed Requirements JSON
req_block "not valid json" > "$WORK/plan-req-badjson.md"
check "plan: malformed Requirements JSON flags" 1 plan "$WORK/plan-req-badjson.md"
check_output "plan: malformed Requirements JSON is named" "not single-line JSON" plan "$WORK/plan-req-badjson.md"

# 2. a non-GE requirement id
req_block "{\"owner\":$good_owner,\"requirement\":\"REQ-1\",\"revision\":\"$good_rev\",\"scenarios\":[\"SC-001\"]}" > "$WORK/plan-req-badid.md"
check "plan: non-GE requirement id flags" 1 plan "$WORK/plan-req-badid.md"
check_output "plan: non-GE requirement id is named" "canonical GE-NNN id" plan "$WORK/plan-req-badid.md"

# 3. a bad revision shape (too short, not hex-64)
req_block "{\"owner\":$good_owner,\"requirement\":\"GE-001\",\"revision\":\"abc123\",\"scenarios\":[\"SC-001\"]}" > "$WORK/plan-req-badrev.md"
check "plan: bad revision shape flags" 1 plan "$WORK/plan-req-badrev.md"
check_output "plan: bad revision shape is named" "lowercase SHA-256" plan "$WORK/plan-req-badrev.md"

# valid Requirements bullet, for contrast (also used below as the v1-clean baseline)
req_ok="{\"owner\":$good_owner,\"requirement\":\"GE-001\",\"revision\":\"$good_rev\",\"scenarios\":[\"SC-001\"]}"
req_block "$req_ok" > "$WORK/plan-req-ok.md"
check "plan: well-formed Requirements bullet passes" 0 plan "$WORK/plan-req-ok.md"

# 4. an OBL bullet that is not an id
printf '# Plan\n\n## Task DAG\n\n| ID | Subject | BlockedBy | Files | Est scope |\n|----|---------|-----------|-------|-----------|\n| task-001 | x | - | a.sh | small |\n\n## Tasks\n\n### task-001: x\n\n**Files:**\n- a.sh\n\n**Obligations:**\n- keep it offline\n\n**Verify:** `true`\n\n**Acceptance criteria:**\n- [ ] ok\n' > "$WORK/plan-obl-notid.md"
check "plan: Obligations bullet that is not an id flags" 1 plan "$WORK/plan-obl-notid.md"
check_output "plan: bad Obligations bullet is named" "bare OBL-... id" plan "$WORK/plan-obl-notid.md"

# 5. a malformed Execution inputs object (missing required keys)
printf '# Plan\n\n## Task DAG\n\n| ID | Subject | BlockedBy | Files | Est scope |\n|----|---------|-----------|-------|-----------|\n| task-001 | x | - | a.sh | small |\n\n## Tasks\n\n### task-001: x\n\n**Files:**\n- a.sh\n\n**Execution inputs:** {"version":1}\n\n**Verify:** `true`\n\n**Acceptance criteria:**\n- [ ] ok\n' > "$WORK/plan-execinputs-bad.md"
check "plan: malformed Execution inputs flags" 1 plan "$WORK/plan-execinputs-bad.md"
check_output "plan: malformed Execution inputs is named" "needs version, toolchains" plan "$WORK/plan-execinputs-bad.md"

# 6. a v1 task block with neither Requirements nor Obligations
printf '# Plan\n\n## Task DAG\n\n| ID | Subject | BlockedBy | Files | Est scope |\n|----|---------|-----------|-------|-----------|\n| task-001 | x | - | a.sh | small |\n\n## Tasks\n\n### task-001: x\n\n**Files:**\n- a.sh\n\n**Execution inputs:** {"version":1,"toolchains":[],"localInputs":[],"externalInputs":[],"sensitiveInputs":[]}\n\n**Verify:** `true`\n\n**Acceptance criteria:**\n- [ ] ok\n' > "$WORK/plan-v1-noexemption.md"
check "plan legacy: no Requirements/Obligations passes without --feature-dir" 0 plan "$WORK/plan-v1-noexemption.md"
check "plan v1: no Requirements/Obligations flags with the v1 feature-dir" 1 plan "$WORK/plan-v1-noexemption.md" --feature-dir "$V1DIR"
check_output "plan v1: the free-text exemption is named" "no free-text coverage exemption" \
  plan "$WORK/plan-v1-noexemption.md" --feature-dir "$V1DIR"

# 7. a v1 task block missing Execution inputs (Requirements present, otherwise valid)
req_block "$req_ok" > "$WORK/plan-v1-noexecinputs.md"
check "plan legacy: missing Execution inputs passes without --feature-dir" 0 plan "$WORK/plan-v1-noexecinputs.md"
check "plan v1: missing Execution inputs flags with the v1 feature-dir" 1 plan "$WORK/plan-v1-noexecinputs.md" --feature-dir "$V1DIR"
check_output "plan v1: missing Execution inputs is named" "is missing '**Execution inputs:**'" \
  plan "$WORK/plan-v1-noexecinputs.md" --feature-dir "$V1DIR"

# 8. a legacy PLAN with none of these lines at all still passes, --feature-dir or not
check "plan legacy: a plan with no v1 lines passes (no --feature-dir)" 0 plan "$WORK/plan-good.md"
check "plan legacy: the same plan passes under a legacy feature-dir too" 0 plan "$WORK/plan-good.md" --feature-dir "$LEGACYDIR"

# --- the same shape checks from the tasks.json side ---
tasks_with() {  # $1 extra JSON fields to splice into the one task object
  printf '[{"id":"task-001","brief":"x","files":[],"blockedBy":[],"verifyCommand":"true","acceptanceCriteria":["ok"]%s}]' "$1"
}
tasks_with ',"requirements":["not an object"]' > "$WORK/tasks-req-badshape.json"
check "tasks: a non-object requirements entry flags" 1 tasks "$WORK/tasks-req-badshape.json"
check_output "tasks: bad requirements shape is named" "needs exactly owner, requirement" tasks "$WORK/tasks-req-badshape.json"

tasks_with ',"obligations":["keep it offline"]' > "$WORK/tasks-obl-notid.json"
check "tasks: an Obligations entry that is not an id flags" 1 tasks "$WORK/tasks-obl-notid.json"
check_output "tasks: bad obligations entry is named" "bare OBL-... id" tasks "$WORK/tasks-obl-notid.json"

tasks_with ',"executionInputs":{"version":1}' > "$WORK/tasks-execinputs-bad.json"
check "tasks: malformed executionInputs flags" 1 tasks "$WORK/tasks-execinputs-bad.json"
check_output "tasks: malformed executionInputs is named" "needs version, toolchains" tasks "$WORK/tasks-execinputs-bad.json"

tasks_with '' > "$WORK/tasks-v1-noexemption.json"
check "tasks legacy: no requirements/obligations passes without --feature-dir" 0 tasks "$WORK/tasks-v1-noexemption.json"
check "tasks v1: no requirements/obligations flags with the v1 feature-dir" 1 tasks "$WORK/tasks-v1-noexemption.json" --feature-dir "$V1DIR"
check_output "tasks v1: the free-text exemption is named" "no free-text coverage exemption" \
  tasks "$WORK/tasks-v1-noexemption.json" --feature-dir "$V1DIR"

tasks_with ",\"requirements\":[{\"owner\":$good_owner,\"requirement\":\"GE-001\",\"revision\":\"$good_rev\",\"scenarios\":[\"SC-001\"]}]" > "$WORK/tasks-v1-noexecinputs.json"
check "tasks legacy: missing executionInputs passes without --feature-dir" 0 tasks "$WORK/tasks-v1-noexecinputs.json"
check "tasks v1: missing executionInputs flags with the v1 feature-dir" 1 tasks "$WORK/tasks-v1-noexecinputs.json" --feature-dir "$V1DIR"
check_output "tasks v1: missing executionInputs is named" "executionInputs is required under a v1 contract" \
  tasks "$WORK/tasks-v1-noexecinputs.json" --feature-dir "$V1DIR"

# --- the repo's own current templates/artifacts stay green ---
check "current PLAN template shape passes (real artifact)" 0 plan "$ROOT/tests/fixtures/real-PLAN.md"
check "current SPEC template shape passes (real artifact)" 0 spec "$ROOT/tests/fixtures/real-SPEC.md"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
