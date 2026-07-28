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
ambiguity_scores:
  ambiguity: 0.1
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

# --- json ---
printf '{"a": 1}' > "$WORK/ok.json"
printf '{"a": 1,}' > "$WORK/trailing.json"
check "valid json passes" 0 json "$WORK/ok.json"
check "trailing-comma json flags" 1 json "$WORK/trailing.json"
check "multi-file json: one bad file fails the batch" 1 json "$WORK/ok.json" "$WORK/trailing.json"

# --- the repo's own current templates/artifacts stay green ---
check "current PLAN template shape passes (real artifact)" 0 plan "$ROOT/docs/loop-spec/features/user-gate-flow/PLAN.md"
check "current SPEC template shape passes (real artifact)" 0 spec "$ROOT/docs/loop-spec/features/grounded-claims/SPEC.md"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
