#!/usr/bin/env bash
# Tests for lib/phase-exit.sh (one command closes a phase) and lib/phase-mode.sh
# (one line selects a phase's path).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EXIT="$REPO_ROOT/lib/phase-exit.sh"
MODE="$REPO_ROOT/lib/phase-mode.sh"
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

WORK="${TMPDIR:-/tmp}"; WORK="${WORK%/}/phase-exit-test.$$"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export LOOP_SPEC_HARNESS=codex LOOP_SPEC_TEAMS_MODE=none LOOP_SPEC_WORKFLOWS_AVAILABLE=0 LOOP_SPEC_CHECKPOINT_PR=0
unset LOOP_SPEC_AUTONOMOUS LOOP_SPEC_NON_INTERACTIVE

# A real schema-7 feature, the way the cycle makes one.
cd "$REPO"
bash "$REPO_ROOT/lib/cycle-driver.sh" start --dir "$REPO" -- my feature >/dev/null 2>&1
bash "$REPO_ROOT/lib/cycle-driver.sh" init --dir "$REPO" --slug my-feature --title "my feature" \
  --style auto --profile standard --autonomous 0 >/dev/null 2>&1
FD="$REPO/.loop-spec/features/my-feature"
DOCS="$REPO/docs/loop-spec/features/my-feature"
mkdir -p "$DOCS"
fj() { jq -r "$1" "$FD/feature.json"; }

# --- usage ------------------------------------------------------------------------
ec=0; bash "$EXIT" >/dev/null 2>&1 || ec=$?
check "exit: no phase is a bad invocation" "2" "$ec"
ec=0; bash "$EXIT" bogus --feature-dir "$FD" >/dev/null 2>&1 || ec=$?
check "exit: unknown phase is a bad invocation" "2" "$ec"
ec=0; bash "$MODE" spec >/dev/null 2>&1 || ec=$?
check "mode: missing feature dir is a bad invocation" "2" "$ec"

# --- spec ---------------------------------------------------------------------------
out="$(bash "$MODE" spec --feature-dir "$FD")"
check "mode spec: human attached interviews" "path=interview" "${out%% *}"
out="$(LOOP_SPEC_AUTONOMOUS=1 bash "$MODE" spec --feature-dir "$FD")"
check "mode spec: autonomous self-answers" "path=self-answer" "${out%% *}"
out="$(LOOP_SPEC_NON_INTERACTIVE=1 bash "$MODE" spec --feature-dir "$FD")"
check "mode spec: non-interactive synthesizes" "path=synthesize" "${out%% *}"
touch "$FD/spec-draft.md"
out="$(bash "$MODE" spec --feature-dir "$FD")"
check "mode spec: a draft is ingested before anything else" "path=ingest" "${out%% *}"
rm -f "$FD/spec-draft.md"

ec=0; out="$(bash "$EXIT" spec --feature-dir "$FD" 2>&1)" || ec=$?
check "exit spec: missing SPEC.md flags" "1" "$ec"
check "exit spec: the answer line names the count" "phase-exit: 1 flag(s) (spec)" "$(tail -1 <<<"$out")"

cat > "$DOCS/SPEC.md" <<'MD'
---
ambiguity_scores:
  ambiguity: 0.1
  gate_passed: true
  unresolved_dimensions: []
---
# My Feature

## Problem

Something is broken.

## Success criteria

### Good Enough

- [ ] `bash -n a.sh` exits 0

### Exceptional

- [ ] stretch

## Grounding

- none
MD
printf '# transcript\n' > "$FD/spec-interview-transcript.md"
ec=0; out="$(bash "$EXIT" spec --feature-dir "$FD" 2>&1)" || ec=$?
check "exit spec: well-formed SPEC.md passes" "0" "$ec"
check "exit spec: artifact pointer recorded" "docs/loop-spec/features/my-feature/SPEC.md" "$(fj '.artifacts.spec')"
check "exit spec: transcript pointer recorded" "1" "$([[ "$(fj '.artifacts.specInterview')" == *transcript.md ]] && echo 1 || echo 0)"
check "exit spec: phase closed" "spec" "$(fj '.completedPhases[-1]')"
check "exit spec: SPEC.md committed" "1" "$(git log --oneline | grep -c 'spec: my-feature')"

# --- discuss ------------------------------------------------------------------------
out="$(bash "$MODE" discuss --feature-dir "$FD")"
check "mode discuss: human attached grills" "grill=run" "${out%% *}"
check "mode discuss: gated spec skips the critique" "1" "$(grep -c 'critique=skip' <<<"$out")"
out="$(LOOP_SPEC_AUTONOMOUS=1 bash "$MODE" discuss --feature-dir "$FD")"
check "mode discuss: autonomous self-answers the grill" "grill=self-answer" "${out%% *}"
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" execStyle '"review-only"' >/dev/null
out="$(bash "$MODE" discuss --feature-dir "$FD")"
check "mode discuss: review-only skips the grill" "grill=skip" "${out%% *}"
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" execStyle '"auto"' >/dev/null

ec=0; bash "$EXIT" discuss --feature-dir "$FD" >/dev/null 2>&1 || ec=$?
check "exit discuss: clean spec passes" "0" "$ec"
check "exit discuss: checkpoint tagged" "1" "$(git tag | grep -c 'post-discuss')"

# --- plan ---------------------------------------------------------------------------
cat > "$DOCS/PLAN.md" <<'MD'
# My Feature - Implementation Plan

**Spec:** `docs/loop-spec/features/my-feature/SPEC.md`

## Architecture overview

One task.

## Task DAG

| ID | Subject | BlockedBy | Files | Est scope |
|----|---------|-----------|-------|-----------|
| task-001 | do a thing | - | a.sh | small |

## Spec coverage

- `bash -n a.sh` exits 0 -> task-001

## Tasks

### task-001: do a thing

**Goal:** one sentence.

**Files:**
- `a.sh`

**Verify:** `bash -n a.sh`

**Acceptance criteria:**
- [ ] `bash -n a.sh` exits 0

## Grounding

- none
MD
printf '# PATTERNS.md - my feature\n\n## Concept: writer\n\ndetail\n' > "$DOCS/PATTERNS.md"
ec=0; out="$(bash "$EXIT" plan --feature-dir "$FD" 2>&1)" || ec=$?
check "exit plan: missing tasks.json flags" "1" "$ec"
check "exit plan: names the sidecar" "1" "$(grep -c 'tasks.json missing' <<<"$out")"
printf '[{"id":"task-001","brief":"do a thing","files":["a.sh"],"blockedBy":["task-001"],"verifyCommand":"bash -n a.sh","acceptanceCriteria":["`bash -n a.sh` exits 0"]}]' > "$FD/tasks.json"
ec=0; out="$(bash "$EXIT" plan --feature-dir "$FD" 2>&1)" || ec=$?
check "exit plan: a self-blocking task is a cycle" "1" "$(grep -c 'dependency cycle' <<<"$out")"
printf '[{"id":"task-001","brief":"do a thing","files":["a.sh"],"blockedBy":[],"verifyCommand":"bash -n a.sh","acceptanceCriteria":["`bash -n a.sh` exits 0"]}]' > "$FD/tasks.json"
out="$(bash "$MODE" plan --feature-dir "$FD")"
check "mode plan: one small task takes the fast path" "critique=skip" "${out%% *}"
ec=0; out="$(bash "$EXIT" plan --feature-dir "$FD" 2>&1)" || ec=$?
check "exit plan: gated plan passes" "0" "$ec"
check "exit plan: tasks pointer recorded" "1" "$([[ "$(fj '.artifacts.tasks')" == *tasks.json ]] && echo 1 || echo 0)"
check "exit plan: patterns source defaulted" "pattern-mapper" "$(fj '.artifacts.patternsSource')"
check "exit plan: PLAN.md committed" "1" "$(git log --oneline | grep -c 'plan: my-feature')"

# --- execute ------------------------------------------------------------------------
ec=0; out="$(bash "$EXIT" execute --feature-dir "$FD" 2>&1)" || ec=$?
check "exit execute: unpublished task flags" "1" "$ec"
check "exit execute: names the task" "1" "$(grep -c 'task-001' <<<"$out")"
bash "$REPO_ROOT/lib/task-progress.sh" mark-done "$FD/tasks.json" task-001 >/dev/null
ec=0; bash "$EXIT" execute --feature-dir "$FD" >/dev/null 2>&1 || ec=$?
check "exit execute: all published passes" "0" "$ec"
check "exit execute: merge queue cleared" "0" "$(fj '.mergeQueue | length')"
check "exit execute: checkpoint tagged" "1" "$(git tag | grep -c 'post-execute')"

# --- verify -------------------------------------------------------------------------
printf 'echo ok\n' > a.sh; git add a.sh; git commit -q -m "feat: a.sh"
cat > "$DOCS/VERIFICATION.md" <<'MD'
# My Feature - Verification

## Repository grounding

- criterion: GE-001 | implementation: a.sh:1 - proves it | integration: none - covered by unit scope

## Acceptance criteria

| # | Criterion | Status | Evidence |
|---|-----------|--------|----------|
| 1 | it works | PASS | `bash -n a.sh` -> ok |
MD
out="$(bash "$MODE" verify --feature-dir "$FD")"
check "mode verify: standard profile runs every gate" "placeholder=run tamper=run validation=run acceptance=run codeReview=run regression=skip" "${out% reason=*}"
ec=0; bash "$EXIT" verify --feature-dir "$FD" >/dev/null 2>&1 || ec=$?
check "exit verify: grounded verification passes" "0" "$ec"
check "exit verify: pointer recorded" "docs/loop-spec/features/my-feature/VERIFICATION.md" "$(fj '.artifacts.verification')"
check "exit verify: team state cleared" "null" "$(fj '.currentTeamName')"

# --- iterate ------------------------------------------------------------------------
printf '# Iteration\n' > "$DOCS/ITERATION.md"
ec=0; bash "$EXIT" iterate --feature-dir "$FD" >/dev/null 2>&1 || ec=$?
check "exit iterate: rewind pass leaves the phase open" "verify" "$(fj '.completedPhases[-1]')"
ec=0; bash "$EXIT" iterate --feature-dir "$FD" --terminal >/dev/null 2>&1 || ec=$?
check "exit iterate: terminal pass closes the phase" "iterate" "$(fj '.completedPhases[-1]')"

# --- egress guard -------------------------------------------------------------------
# ITERATION.md is present, so the only thing left to judge is what the phase wrote.
ENTRY="$REPO_ROOT/lib/phase-entry.sh"
bash "$ENTRY" iterate --feature-dir "$FD" >/dev/null
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" iterate.used 1 >/dev/null
ec=0; out="$(bash "$EXIT" iterate --feature-dir "$FD" 2>&1)" || ec=$?
check "egress: a key the phase owns raises nothing" "0" "$(grep -c '\[egress\]' <<<"$out")"
check "egress: the snapshot is consumed on ok" "missing" "$([[ -f "$FD/.phase-entry.json" ]] && echo present || echo missing)"

bash "$ENTRY" iterate --feature-dir "$FD" >/dev/null
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" scratch.note '"left behind"' >/dev/null
ec=0; out="$(bash "$EXIT" iterate --feature-dir "$FD" 2>&1)" || ec=$?
check "egress: a stray key warns by default and does not block" "0" "$ec"
check "egress: the warning names the path" "1" "$(grep -c '^WARN \[egress\] scratch.note ' <<<"$out")"

bash "$ENTRY" iterate --feature-dir "$FD" >/dev/null
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" scratch.note '"changed again"' >/dev/null
ec=0; out="$(LOOP_SPEC_EGRESS_GUARD=deny bash "$EXIT" iterate --feature-dir "$FD" 2>&1)" || ec=$?
check "egress: deny mode flags the stray key" "1" "$ec"
check "egress: deny mode names the path as a FLAG" "1" "$(grep -c '^FLAG \[egress\] scratch.note ' <<<"$out")"
ec=0; out="$(LOOP_SPEC_EGRESS_GUARD=off bash "$EXIT" iterate --feature-dir "$FD" 2>&1)" || ec=$?
check "egress: off mode is silent" "0" "$(grep -c '\[egress\]' <<<"$out")"
ec=0; LOOP_SPEC_EGRESS_GUARD=bogus bash "$EXIT" iterate --feature-dir "$FD" >/dev/null 2>&1 || ec=$?
check "egress: an unknown mode is a bad invocation" "2" "$ec"
rm -f "$FD/.phase-entry.json"
ec=0; out="$(bash "$EXIT" iterate --feature-dir "$FD" 2>&1)" || ec=$?
check "egress: no snapshot means nothing to judge" "0" "$(grep -c '\[egress\]' <<<"$out")"

echo
echo "phase-exit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
