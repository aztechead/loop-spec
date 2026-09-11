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
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd -P)"
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
check "mode spec: self-answer names the oracle" "oracle=self" "$(cut -d' ' -f2 <<<"$out")"
out="$(LOOP_SPEC_AUTONOMOUS=1 LOOP_SPEC_ORACLE=supervisor bash "$MODE" spec --feature-dir "$FD")"
check "mode spec: a supervisor rides on the line" "oracle=supervisor" "$(cut -d' ' -f2 <<<"$out")"
out="$(bash "$MODE" spec --feature-dir "$FD")"
check "mode spec: the interview path carries no oracle field" "0" "$(grep -c 'oracle=' <<<"$out")"
out="$(LOOP_SPEC_NON_INTERACTIVE=1 bash "$MODE" spec --feature-dir "$FD")"
check "mode spec: non-interactive synthesizes" "path=synthesize" "${out%% *}"
touch "$FD/spec-draft.md"
out="$(bash "$MODE" spec --feature-dir "$FD")"
check "mode spec: a draft is ingested before anything else" "path=ingest" "${out%% *}"
rm -f "$FD/spec-draft.md"

ec=0; out="$(bash "$EXIT" spec --feature-dir "$FD" 2>&1)" || ec=$?
check "exit spec: missing SPEC.md flags" "1" "$ec"
check "exit spec: the answer line names the count" "phase-exit: 1 flag(s) (spec)" "$(tail -1 <<<"$out")"
# The writer put SPEC.md in another checkout of this repository: name it and the move.
git worktree add -q "$WORK/other" -b other >/dev/null 2>&1
mkdir -p "$WORK/other/docs/loop-spec/features/my-feature"; printf '# stray\n' > "$WORK/other/docs/loop-spec/features/my-feature/SPEC.md"
ec=0; out="$(bash "$EXIT" spec --feature-dir "$FD" 2>&1)" || ec=$?
check "exit spec: a SPEC.md in another checkout is named as misplaced" "1" "$(grep -c "FLAG \[misplaced\] SPEC.md was written to $WORK/other/docs/loop-spec/features/my-feature/SPEC.md" <<<"$out")"
check "exit spec: the misplaced flag names the move" "1" "$(grep -c "mv $WORK/other/docs/loop-spec/features/my-feature/SPEC.md $REPO/docs/loop-spec/features/my-feature/SPEC.md" <<<"$out")"
git worktree remove --force "$WORK/other" >/dev/null 2>&1; git branch -q -D other >/dev/null 2>&1

# The feature lives in a worktree and the parent checkout holds a stale copy of its
# docs directory (the dda2cca run wrote SPEC.md next to the lead, twice). The gate is
# run from the parent, the lead's cwd, and reads the worktree copy: the stale one is
# never linted, never committed, and never named as misplaced.
git worktree add -q "$WORK/wt" -b feat/wt-feature >/dev/null 2>&1
WFD="$WORK/wt/.loop-spec/features/wt-feature"; WDOCS="$WORK/wt/docs/loop-spec/features/wt-feature"
mkdir -p "$WFD" "$WDOCS" "$REPO/docs/loop-spec/features/wt-feature"
jq '.slug = "wt-feature" | .feature_title = "wt feature" | .branch = "feat/wt-feature" | .worktreePath = "'"$WORK/wt"'" | .artifacts = {}' \
  "$FD/feature.json" > "$WFD/feature.json"
printf '# stale: not a spec at all\n' > "$REPO/docs/loop-spec/features/wt-feature/SPEC.md"
cat > "$WDOCS/SPEC.md" <<'MD'
---
unresolved_questions: []
---
# wt feature

## Problem

The worktree copy is the real one.

## Goals

Produce the requested behavior.

## Boundaries (what NOT to do)

Do not change unrelated behavior.

## Success criteria

### Good Enough

- [ ] `true` exits 0

## Grounding

- none
MD
bash "$REPO_ROOT/lib/cycle-driver.sh" spec approve --feature-dir "$WFD" --source human >/dev/null
ec=0; out="$(cd "$REPO" && bash "$EXIT" spec --feature-dir "$WFD" 2>&1)" || ec=$?
check "exit spec from a worktree feature: the worktree copy is the one read (clean exit)" "phase-exit: ok (spec)" "$(tail -1 <<<"$out")"
check "exit spec from a worktree feature: the stale parent copy is not named as misplaced" "0" "$(grep -c 'misplaced' <<<"$out")"
check "exit spec from a worktree feature: the worktree copy is committed on the feature branch" "1" "$(git -C "$WORK/wt" show HEAD:docs/loop-spec/features/wt-feature/SPEC.md 2>/dev/null | grep -c 'The worktree copy is the real one')"
check "exit spec from a worktree feature: the parent checkout commits nothing" "0" "$(git -C "$REPO" log --oneline -- docs/loop-spec/features/wt-feature 2>/dev/null | wc -l | tr -d ' ')"
check "exit spec from a worktree feature: the artifact pointer is the worktree-relative path" "docs/loop-spec/features/wt-feature/SPEC.md" "$(jq -r '.artifacts.spec' "$WFD/feature.json")"
rm -rf "$REPO/docs/loop-spec/features/wt-feature"
git worktree remove --force "$WORK/wt" >/dev/null 2>&1; git branch -q -D feat/wt-feature >/dev/null 2>&1

cp "$REPO_ROOT/tests/fixtures/minimal-SPEC.md" "$DOCS/SPEC.md"
bash "$REPO_ROOT/lib/cycle-driver.sh" spec approve --feature-dir "$FD" --source human >/dev/null
ec=0; out="$(bash "$EXIT" spec --feature-dir "$FD" 2>&1)" || ec=$?
check "exit spec: well-formed SPEC.md passes" "0" "$ec"
check "exit spec: artifact pointer recorded" "docs/loop-spec/features/my-feature/SPEC.md" "$(fj '.artifacts.spec')"
check "exit spec: no interview transcript is recorded" "null" "$(fj '.artifacts.specInterview')"
check "exit spec: phase closed" "spec" "$(fj '.completedPhases[-1]')"
bash "$EXIT" spec --feature-dir "$FD" >/dev/null 2>&1 || true
check "exit spec: a re-entered phase closes once" "1" "$(fj '[.completedPhases[] | select(. == "spec")] | length')"
check "exit spec: SPEC.md committed" "1" "$(git log --oneline | grep -c 'spec: my-feature')"
# A single-mode workspace record (what lib/workspace.sh detect reports for an ordinary
# repository) must not read as workspace mode: the haiku re-run of todo-due carried one
# and phase-exit committed nothing. Re-run the exit over an edited SPEC.md and expect a
# second commit.
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" workspace "{\"root\":\"$REPO\",\"mode\":\"single\",\"repos\":[]}" >/dev/null
printf '\nA line the second commit carries.\n' >> "$DOCS/SPEC.md"
bash "$EXIT" spec --feature-dir "$FD" >/dev/null 2>&1
check "exit spec: a single-mode workspace record still commits" "2" "$(git log --oneline | grep -c 'spec: my-feature')"
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" workspace null >/dev/null

# --- discuss ------------------------------------------------------------------------
out="$(bash "$MODE" discuss --feature-dir "$FD")"
check "mode discuss: human attached grills" "grill=run" "${out%% *}"
check "mode discuss: gated spec skips the critique" "1" "$(grep -c 'critique=skip' <<<"$out")"
out="$(LOOP_SPEC_AUTONOMOUS=1 bash "$MODE" discuss --feature-dir "$FD")"
check "mode discuss: autonomous self-answers the grill" "grill=self-answer" "${out%% *}"
out="$(LOOP_SPEC_AUTONOMOUS=1 LOOP_SPEC_ORACLE=supervisor bash "$MODE" discuss --feature-dir "$FD")"
check "mode discuss: a supervisor rides on the grill line" "oracle=supervisor" "$(cut -d' ' -f2 <<<"$out")"
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" execStyle '"review-only"' >/dev/null
out="$(bash "$MODE" discuss --feature-dir "$FD")"
check "mode discuss: review-only skips the grill" "grill=skip" "${out%% *}"
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" execStyle '"auto"' >/dev/null

# the oracle gate: a named supervisor that no discuss question reached keeps the phase open
ec=0; out="$(LOOP_SPEC_AUTONOMOUS=1 LOOP_SPEC_ORACLE=supervisor bash "$EXIT" discuss --feature-dir "$FD" 2>&1)" || ec=$?
check "exit discuss: supervisor named, nothing asked, flags" "1" "$ec"
check "exit discuss: the flag names the oracle" "1" "$(grep -c 'FLAG \[oracle\]' <<<"$out")"
bash "$REPO_ROOT/lib/decisions.sh" add "$FD" spec "Runtime?" "python3" "oracle unavailable: I decided not to ask" >/dev/null
ec=0; LOOP_SPEC_AUTONOMOUS=1 LOOP_SPEC_ORACLE=supervisor bash "$EXIT" spec --feature-dir "$FD" >/dev/null 2>&1 || ec=$?
check "exit spec: an assumed decision naming the oracle does not satisfy the gate" "1" "$ec"
LOOP_SPEC_ORACLE_WRITE=1 bash "$REPO_ROOT/lib/decisions.sh" add "$FD" discuss "Which store?" "sqlite" "supervisor chose it" supervised >/dev/null
ec=0; LOOP_SPEC_AUTONOMOUS=1 LOOP_SPEC_ORACLE=supervisor bash "$EXIT" discuss --feature-dir "$FD" >/dev/null 2>&1 || ec=$?
check "exit discuss: a supervised decision satisfies the gate" "0" "$ec"
git -C "$REPO" tag | grep post-discuss | xargs -r git -C "$REPO" tag -d >/dev/null 2>&1 || true
LOOP_SPEC_ORACLE_WRITE=1 bash "$REPO_ROOT/lib/decisions.sh" add "$FD" spec "Runtime?" "(unanswered)" "oracle unavailable: denied" oracle-unavailable >/dev/null
ec=0; LOOP_SPEC_AUTONOMOUS=1 LOOP_SPEC_ORACLE=supervisor bash "$EXIT" spec --feature-dir "$FD" >/dev/null 2>&1 || ec=$?
check "exit spec: a failed question tool satisfies the gate" "0" "$ec"
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
check "exit plan: missing sidecar names the extract command" "1" "$(grep -c 'plan-tasks.sh extract' <<<"$out")"
printf '[]' > "$FD/tasks.json"
ec=0; out="$(bash "$EXIT" plan --feature-dir "$FD" 2>&1)" || ec=$?
check "exit plan: an empty tasks.json flags" "1" "$ec"
check "exit plan: empty sidecar differs from PLAN.md ids" "1" "$(grep -c 'task-001) differ from' <<<"$out")"
printf '[{"id":"task-009","brief":"stale","files":["a.sh"],"blockedBy":[],"verifyCommand":"bash -n a.sh","acceptanceCriteria":["`bash -n a.sh` exits 0"]}]' > "$FD/tasks.json"
ec=0; out="$(bash "$EXIT" plan --feature-dir "$FD" 2>&1)" || ec=$?
check "exit plan: a sidecar whose ids differ from PLAN.md flags" "1" "$(grep -c 'differ from' <<<"$out")"
bash "$REPO_ROOT/lib/plan-tasks.sh" extract "$DOCS/PLAN.md" > "$FD/tasks.json"
ec=0; out="$(bash "$EXIT" plan --feature-dir "$FD" 2>&1)" || ec=$?
check "exit plan: the derived sidecar carries no [tasks] flag" "0" "$(grep -c '^FLAG \[tasks\]' <<<"$out")"
printf '[{"id":"task-001","brief":"do a thing","files":["a.sh"],"blockedBy":["task-001"],"verifyCommand":"bash -n a.sh","acceptanceCriteria":["`bash -n a.sh` exits 0"]}]' > "$FD/tasks.json"
ec=0; out="$(bash "$EXIT" plan --feature-dir "$FD" 2>&1)" || ec=$?
check "exit plan: a self-blocking task is a cycle" "1" "$(grep -c 'dependency cycle' <<<"$out")"
printf '[{"id":"task-001","brief":"do a thing","files":["a.sh"],"blockedBy":[],"verifyCommand":"pip install -e . && uv venv --python 3.14 && bash -n a.sh","acceptanceCriteria":["`bash -n a.sh` exits 0"]}]' > "$FD/tasks.json"
ec=0; out="$(bash "$EXIT" plan --feature-dir "$FD" 2>&1)" || ec=$?
check "exit plan: a verify command that installs is a feasibility flag" "1" "$(grep -c 'installs or creates an environment' <<<"$out")"
for cmd in "uv sync && bash -n a.sh" "npm ci && bash -n a.sh" "poetry install && bash -n a.sh"; do
  printf '[{"id":"task-001","brief":"do a thing","files":["a.sh"],"blockedBy":[],"verifyCommand":"%s","acceptanceCriteria":["`bash -n a.sh` exits 0"]}]' "$cmd" > "$FD/tasks.json"
  out="$(bash "$EXIT" plan --feature-dir "$FD" 2>&1 || true)"
  check "exit plan: '$cmd' is an install flag" "1" "$(grep -c 'installs or creates an environment' <<<"$out")"
done
printf '[{"id":"task-001","brief":"do a thing","files":["a.sh"],"blockedBy":[],"verifyCommand":"bash -n a.sh","acceptanceCriteria":["`bash -n a.sh` exits 0"]}]' > "$FD/tasks.json"
out="$(bash "$MODE" plan --feature-dir "$FD")"
check "mode plan: one small task takes the fast path" "critique=skip" "${out%% *}"
ec=0; out="$(bash "$EXIT" plan --feature-dir "$FD" 2>&1)" || ec=$?
check "exit plan: gated plan passes" "0" "$ec"
check "exit plan: tasks pointer recorded" "1" "$([[ "$(fj '.artifacts.tasks')" == *tasks.json ]] && echo 1 || echo 0)"
check "exit plan: patterns source defaulted" "pattern-mapper" "$(fj '.artifacts.patternsSource')"
check "exit plan: PLAN.md committed" "1" "$(git log --oneline | grep -c 'plan: my-feature')"

# --- plan (v1 contract): the reviewed task relation replaces positional coverage ----
# A v1 feature, built the way tests/lib/cycle-driver.test.sh and
# tests/lib/feature-init.test.sh do (LOOP_SPEC_REQUIREMENTS_V1_FIXTURE=1 at creation --
# a transitional, fixture-only switch; not a downgrade a real cycle can choose).
REPOV1="$WORK/repov1"; mkdir -p "$REPOV1"
git -C "$REPOV1" init -q -b main
git -C "$REPOV1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
bash "$REPO_ROOT/lib/cycle-driver.sh" start --dir "$REPOV1" -- v1 relation check >/dev/null 2>&1
LOOP_SPEC_REQUIREMENTS_V1_FIXTURE=1 bash "$REPO_ROOT/lib/cycle-driver.sh" init --dir "$REPOV1" \
  --slug v1-relation-check --title "v1 relation check" --style auto --profile standard --autonomous 0 >/dev/null 2>&1
FDV1="$REPOV1/.loop-spec/features/v1-relation-check"
DOCSV1="$REPOV1/docs/loop-spec/features/v1-relation-check"
mkdir -p "$DOCSV1"
check "v1 fixture: creation records a v1 contract" "v1" "$(jq -r '.requirementsContract.format' "$FDV1/feature.json")"
owner_json="$(jq -c '.requirementsContract.owner' "$FDV1/feature.json")"

cat > "$DOCSV1/SPEC.md" <<EOF
---
requirements_version: 1
requirements_owner: $owner_json
---
# v1 relation check

## Success criteria

### Good Enough

- [ ] GE-001: The user sees the result.
  - SC-001: Reload shows the result.

## Constraints

- OBL-runtime: keep it offline.
EOF
# The revision comes from the inventory reader itself, never typed by hand
# (docs/loop-spec/requirements-format.md; requirements.py's own digest is the
# only authoritative source of a requirement's revision).
ge001_revision="$(bash "$REPO_ROOT/lib/requirements.sh" inventory --spec "$DOCSV1/SPEC.md" --feature-dir "$FDV1" \
  | jq -r '.requirements[0].revision')"
check "v1 fixture: inventory reader produced a revision" "64" "${#ge001_revision}"

write_v1_plan() {
  # $1 requirements bullet (or "-" for none), $2 obligations bullet (or "-" for none)
  local req_line="$1" obl_line="$2"
  {
    printf '# v1 relation check - Implementation Plan\n\n## Task DAG\n\n'
    printf '| ID | Subject | BlockedBy | Files | Est scope |\n|----|---------|-----------|-------|-----------|\n'
    printf '| task-001 | do a thing | - | a.sh | small |\n\n## Tasks\n\n### task-001: do a thing\n\n'
    printf '**Goal:** one sentence.\n\n**Files:**\n- `a.sh`\n\n'
    if [[ "$req_line" != "-" ]]; then printf '**Requirements:**\n- %s\n\n' "$req_line"; fi
    if [[ "$obl_line" != "-" ]]; then printf '**Obligations:**\n- %s\n\n' "$obl_line"; fi
    printf '**Execution inputs:** {"version":1,"toolchains":[],"localInputs":[],"externalInputs":[],"sensitiveInputs":[]}\n\n'
    printf '**Verify:** `bash -n a.sh`\n\n**Acceptance criteria:**\n- [ ] `bash -n a.sh` exits 0\n\n'
    printf '## Grounding\n\n- none\n'
  } > "$DOCSV1/PLAN.md"
}
printf '# PATTERNS.md - v1 relation check\n\n## Concept: writer\n\ndetail\n' > "$DOCSV1/PATTERNS.md"

valid_req="{\"owner\":$owner_json,\"requirement\":\"GE-001\",\"revision\":\"$ge001_revision\",\"scenarios\":[\"SC-001\"]}"

# a. a scenario the SPEC inventory lacks
write_v1_plan "{\"owner\":$owner_json,\"requirement\":\"GE-001\",\"revision\":\"$ge001_revision\",\"scenarios\":[\"SC-999\"]}" "-"
bash "$REPO_ROOT/lib/plan-tasks.sh" extract "$DOCSV1/PLAN.md" > "$FDV1/tasks.json"
ec=0; out="$(bash "$EXIT" plan --feature-dir "$FDV1" 2>&1)" || ec=$?
check "v1 exit plan: unknown scenario exits 1" "1" "$ec"
check "v1 exit plan: unknown scenario names GE-001/SC-999" "1" "$(grep -c 'GE-001/SC-999' <<<"$out")"

# b. a stale revision
write_v1_plan "{\"owner\":$owner_json,\"requirement\":\"GE-001\",\"revision\":\"$(printf '0%.0s' $(seq 1 64))\",\"scenarios\":[\"SC-001\"]}" "-"
bash "$REPO_ROOT/lib/plan-tasks.sh" extract "$DOCSV1/PLAN.md" > "$FDV1/tasks.json"
ec=0; out="$(bash "$EXIT" plan --feature-dir "$FDV1" 2>&1)" || ec=$?
check "v1 exit plan: stale revision exits 1" "1" "$ec"
check "v1 exit plan: stale revision is named" "1" "$(grep -c 'stale revision for GE-001' <<<"$out")"

# c. a dangling task reference in the derived '## Spec coverage' summary
write_v1_plan "$valid_req" "-"
bash "$REPO_ROOT/lib/plan-tasks.sh" extract "$DOCSV1/PLAN.md" > "$FDV1/tasks.json"
printf '\n## Spec coverage\n\n- The user sees the result -> task-999\n' >> "$DOCSV1/PLAN.md"
ec=0; out="$(bash "$EXIT" plan --feature-dir "$FDV1" 2>&1)" || ec=$?
check "v1 exit plan: dangling task-999 reference exits 1" "1" "$ec"
check "v1 exit plan: dangling reference names task-999" "1" "$(grep -c 'dangling task reference task-999' <<<"$out")"

# d. a free-text exemption instead of a Requirements/Obligations bullet
write_v1_plan "-" "-"
bash "$REPO_ROOT/lib/plan-tasks.sh" extract "$DOCSV1/PLAN.md" > "$FDV1/tasks.json"
ec=0; out="$(bash "$EXIT" plan --feature-dir "$FDV1" 2>&1)" || ec=$?
check "v1 exit plan: no Requirements/Obligations bullet exits 1" "1" "$ec"
check "v1 exit plan: names the free-text exemption" "yes" "$(grep -q 'no free-text coverage exemption' <<<"$out" && echo yes)"

# e. an OBL- id not declared under SPEC '## Constraints'
write_v1_plan "-" "OBL-unknown"
bash "$REPO_ROOT/lib/plan-tasks.sh" extract "$DOCSV1/PLAN.md" > "$FDV1/tasks.json"
ec=0; out="$(bash "$EXIT" plan --feature-dir "$FDV1" 2>&1)" || ec=$?
check "v1 exit plan: undeclared obligation exits 1" "1" "$ec"
check "v1 exit plan: undeclared obligation is named" "1" "$(grep -c 'obligation OBL-unknown not declared' <<<"$out")"

# f. tasks.json with the same ids as PLAN.md but an altered dispatch field
write_v1_plan "$valid_req" "-"
bash "$REPO_ROOT/lib/plan-tasks.sh" extract "$DOCSV1/PLAN.md" > "$FDV1/tasks.json"
ec=0; bash "$EXIT" plan --feature-dir "$FDV1" >/dev/null 2>&1 || ec=$?
check "v1 exit plan: the valid relation passes clean first" "0" "$ec"
python3 -c "
import json
tasks = json.load(open('$FDV1/tasks.json'))
tasks[0]['verifyCommand'] = 'echo altered'
json.dump(tasks, open('$FDV1/tasks.json', 'w'))
"
ec=0; out="$(bash "$EXIT" plan --feature-dir "$FDV1" 2>&1)" || ec=$?
check "v1 exit plan: an altered sidecar verifyCommand exits 1" "1" "$ec"
check "v1 exit plan: the altered field is named" "1" "$(grep -c 'task-001.verifyCommand differs' <<<"$out")"

# g. the valid relation, restored, passes clean
bash "$REPO_ROOT/lib/plan-tasks.sh" extract "$DOCSV1/PLAN.md" > "$FDV1/tasks.json"
ec=0; out="$(bash "$EXIT" plan --feature-dir "$FDV1" 2>&1)" || ec=$?
check "v1 exit plan: the valid relation passes clean" "0" "$ec"

# --- verify (v1 contract): the exit's own gates recheck the same GE-001/SC-001
# binding against a real execution_observation.observe() record (task-008) ----------
printf 'echo ok\n' > "$REPOV1/a.sh"
git -C "$REPOV1" add -A && git -C "$REPOV1" -c user.email=t@t -c user.name=t commit -q -m "feat: a.sh"
python3 -c "
path = '$DOCSV1/SPEC.md'
text = open(path).read()
line = 'scenario_checks: {\"GE-001/SC-001\":{\"command\":\"bash -n a.sh\",\"executionInputs\":' \
       '{\"version\":1,\"toolchains\":[],\"localInputs\":[],\"externalInputs\":[],\"sensitiveInputs\":[]}}}\n'
text = text.replace('---\n', '---\n' + line, 1)
open(path, 'w').write(text)
"
cat > "$DOCSV1/VERIFICATION.md" <<'MD'
# v1 relation check - Verification

## Repository grounding

- criterion: GE-001/SC-001 | implementation: a.sh:1 - proves it | integration: none - standalone check

## Acceptance criteria

| # | Criterion | Status | Evidence |
|---|-----------|--------|----------|

## Code review

**Reviewer:** code-reviewer (inherit)

### Findings

none

## Final test suite

```
(no commands.test is configured for this feature)
```
MD
(cd "$REPOV1" && bash "$REPO_ROOT/lib/cycle-driver.sh" verification run --feature-dir "$FDV1" >/dev/null 2>&1)
ec=0; out="$(bash "$EXIT" verify --feature-dir "$FDV1" 2>&1)" || ec=$?
check "v1 exit verify: a fresh eligible GE-001/SC-001 record passes" "0" "$ec"

# A changed scenario revision without a fresh run: the exit's own
# verification-grounding gate refuses the now-stale row (never a numeric or
# document-position check -- the same binding recheck cycle-driver.test.sh drives
# through `verification run` directly).
sed -i.bak 's/Reload shows the result\./Reload shows the result, reworded./' "$DOCSV1/SPEC.md"
rm -f "$DOCSV1/SPEC.md.bak"
ec=0; out="$(bash "$EXIT" verify --feature-dir "$FDV1" 2>&1)" || ec=$?
check "v1 exit verify: a stale record (changed revision) fails the exit" "1" "$ec"
check "v1 exit verify: the flag names current evidence" "1" "$(grep -c 'not current evidence' <<<"$out")"
(cd "$REPOV1" && bash "$REPO_ROOT/lib/cycle-driver.sh" verification run --feature-dir "$FDV1" >/dev/null 2>&1)
ec=0; bash "$EXIT" verify --feature-dir "$FDV1" >/dev/null 2>&1 || ec=$?
check "v1 exit verify: a fresh run over the reworded scenario passes again" "0" "$ec"

# --- execute ------------------------------------------------------------------------
ec=0; out="$(bash "$EXIT" execute --feature-dir "$FD" 2>&1)" || ec=$?
check "exit execute: unpublished task flags" "1" "$ec"
check "exit execute: names the task" "1" "$(grep -c 'task-001' <<<"$out")"
bash "$REPO_ROOT/lib/task-progress.sh" mark-done "$FD/tasks.json" task-001 >/dev/null
ec=0; bash "$EXIT" execute --feature-dir "$FD" >/dev/null 2>&1 || ec=$?
check "exit execute: all published passes" "0" "$ec"
check "exit execute: merge queue cleared" "0" "$(fj '.mergeQueue | length')"
check "exit execute: checkpoint tagged" "1" "$(git tag | grep -c 'post-execute')"

# Every exit refusal below must occur even though the published task is done.
for pending in '[{"id":"still-queued","subject":"not dispatched"}]' 'false' '{}'; do
  bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" pendingRemediationTasks "$pending" >/dev/null
  ec=0; out="$(bash "$EXIT" execute --feature-dir "$FD" 2>&1)" || ec=$?
  check "exit execute: pending remediation $pending blocks exit" "1" "$ec"
  check "exit execute: pending remediation diagnostic" "1" "$(grep -c 'pendingRemediationTasks' <<<"$out")"
done
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" pendingRemediationTasks '[]' >/dev/null
cp "$FD/tasks.json" "$WORK/published-tasks.json"
for broken in '{' '[{}]' '[]' '{"tasks":[]}'; do
  printf '%s' "$broken" > "$FD/tasks.json"
  ec=0; out="$(bash "$EXIT" execute --feature-dir "$FD" 2>&1)" || ec=$?
  check "exit execute: malformed sidecar $broken blocks exit" "1" "$ec"
done
rm "$FD/tasks.json"
ec=0; out="$(bash "$EXIT" execute --feature-dir "$FD" 2>&1)" || ec=$?
check "exit execute: unreadable sidecar blocks exit" "1" "$ec"
cp "$WORK/published-tasks.json" "$FD/tasks.json"
mkdir -p "$WORK/unreadable-progress"
real_python="$(python3 -c 'import sys; print(sys.executable)')"
cat > "$WORK/unreadable-progress/python3" <<SH
#!/usr/bin/env bash
if [[ "\${1:-}" == - && "\${2:-}" == remaining ]]; then
  echo 'task-progress: injected unreadable task sidecar' >&2
  exit 1
fi
exec "$real_python" "\$@"
SH
chmod +x "$WORK/unreadable-progress/python3"
ec=0; out="$(PATH="$WORK/unreadable-progress:$PATH" bash "$EXIT" execute --feature-dir "$FD" 2>&1)" || ec=$?
check "exit execute: unreadable task progress blocks exit after successful lint" "1" "$ec"
check "exit execute: task-progress error is an actionable flag" "1" "$(grep -c 'cannot read task progress' <<<"$out")"


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
# A table ITERATE's floor cannot read is VERIFY's REDO, never a converged-verdict veto
# that rewinds through an empty EXECUTE (the 6.3.0 fastapi runs).
cp "$DOCS/VERIFICATION.md" "$WORK/verification.shape"
sed 's/| PASS |/| passed |/' "$WORK/verification.shape" > "$DOCS/VERIFICATION.md"
ec=0; out="$(bash "$EXIT" verify --feature-dir "$FD" 2>&1)" || ec=$?
check "exit verify: an unreadable acceptance status is a flag" "1" "$ec"
check "exit verify: the flag names the acceptance-table gate and the grammar" "1" "$(grep -c 'FLAG \[acceptance-table\] FLOOR GE-001 acceptance result is unreadable' <<<"$out")"
sed 's/| PASS |/| FAIL |/' "$WORK/verification.shape" > "$DOCS/VERIFICATION.md"
ec=0; bash "$EXIT" verify --feature-dir "$FD" >/dev/null 2>&1 || ec=$?
check "exit verify: a FAIL result is readable, not a format flag" "0" "$ec"
cp "$WORK/verification.shape" "$DOCS/VERIFICATION.md"
bash "$EXIT" verify --feature-dir "$FD" >/dev/null 2>&1 || true

# --- iterate ------------------------------------------------------------------------
printf '# Iteration\n' > "$DOCS/ITERATION.md"
ec=0; bash "$EXIT" iterate --feature-dir "$FD" >/dev/null 2>&1 || ec=$?
check "exit iterate: rewind pass leaves the phase open" "verify" "$(fj '.completedPhases[-1]')"
ec=0; bash "$EXIT" iterate --feature-dir "$FD" --terminal >/dev/null 2>&1 || ec=$?
check "exit iterate: terminal pass closes the phase" "iterate" "$(fj '.completedPhases[-1]')"

bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" iterate.lastVerdict '{"converged":true}' >/dev/null
cp "$DOCS/VERIFICATION.md" "$WORK/verification.good"
sed 's/| PASS |/| PENDING |/' "$WORK/verification.good" > "$DOCS/VERIFICATION.md"
ec=0; bash "$EXIT" iterate --feature-dir "$FD" --terminal >/dev/null 2>&1 || ec=$?
check "exit iterate: convergence with pending acceptance is rejected" "1" "$ec"
cp "$WORK/verification.good" "$DOCS/VERIFICATION.md"
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" iterate.lastVerdict null >/dev/null

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

# --- publication contract --------------------------------------------------------------
# Point LOOP_SPEC_GRAPH at a copy of the real graph whose spec node's gates also run an
# intruder script: it proves whether the gate ran (a marker file) and, when told to,
# performs a plain write that races the token this exit captured at ingress.
PUB_GRAPH="$WORK/graph-publication.json"
jq --arg body "tests/fixtures/publication-intruder-gate.sh" \
  '(.nodes[] | select(.id == "spec") | .egress.gates) += [{label:"intruder",body:$body,args:[]}]' \
  "$REPO_ROOT/graph/cycle.graph.json" > "$PUB_GRAPH"
MARKER="$WORK/intruder-marker"

# AC2: the gate's plain write (LOOP_SPEC_PUBLICATION_TOKEN unset inside it) advances the
# generation behind this exit's back; the exit must FLAG and accept nothing of its own.
before_completed="$(fj '.completedPhases')"
before_pointer="$(fj '.artifacts.spec')"
before_commits="$(git -C "$REPO" log --oneline | wc -l | tr -d ' ')"
before_tags="$(git -C "$REPO" tag | wc -l | tr -d ' ')"
rm -f "$MARKER"
ec=0
out="$(LOOP_SPEC_GRAPH="$PUB_GRAPH" MARKER_FILE="$MARKER" INTRUDE_FEATURE_DIR="$FD" \
  INTRUDE_LIB="$REPO_ROOT/lib/feature-write.sh" bash "$EXIT" spec --feature-dir "$FD" 2>&1)" || ec=$?
check "publication AC2: an intervening plain write during a gate fails the exit" "1" "$ec"
check "publication AC2: the publication FLAG is printed" "1" \
  "$(grep -c 'FLAG \[publication\] feature state changed since this exit began; run the exit again' <<<"$out")"
check "publication AC2: completedPhases is unchanged" "$before_completed" "$(fj '.completedPhases')"
check "publication AC2: no artifacts pointer was written" "$before_pointer" "$(fj '.artifacts.spec')"
check "publication AC2: no commit was created" "$before_commits" "$(git -C "$REPO" log --oneline | wc -l | tr -d ' ')"
check "publication AC2: no tag was created" "$before_tags" "$(git -C "$REPO" tag | wc -l | tr -d ' ')"
check "publication AC2: the gate did run" "1" "$([[ -f "$MARKER" ]] && echo 1 || echo 0)"
check "publication AC2: the intruder's write was accepted" '["intruder"]' "$(jq -c '.warnings' "$FD/feature.json")"

# A migration in progress refuses entry before any gate runs -- prove it with the same
# gate body: the marker must stay absent, since begin_operation refuses before gates run.
rm -f "$MARKER"
digest64="$(printf 'a%.0s' {1..64})"
jq --arg d "$digest64" '.artifactPublication.migration = {id:"m1",previewDigest:$d,phase:"marker",originalGeneration:0,publishedHashes:{}}' \
  "$FD/feature.json" > "$FD/feature.json.tmp" && mv "$FD/feature.json.tmp" "$FD/feature.json"
ec=0
LOOP_SPEC_GRAPH="$PUB_GRAPH" MARKER_FILE="$MARKER" INTRUDE_FEATURE_DIR="$FD" \
  INTRUDE_LIB="$REPO_ROOT/lib/feature-write.sh" bash "$EXIT" spec --feature-dir "$FD" >/dev/null 2>&1 || ec=$?
check "publication: migration in progress exits non-zero" "1" "$([[ "$ec" -ne 0 ]] && echo 1 || echo 0)"
check "publication: no gate ran during a migration refusal" "0" "$([[ -f "$MARKER" ]] && echo 1 || echo 0)"
jq '.artifactPublication.migration = null' "$FD/feature.json" > "$FD/feature.json.tmp" && mv "$FD/feature.json.tmp" "$FD/feature.json"

echo
echo "phase-exit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
