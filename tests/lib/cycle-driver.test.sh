#!/usr/bin/env bash
# Tests for lib/cycle-driver.sh (the cycle's mechanical loop, one answer per call).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/lib/cycle-driver.sh"
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

WORK="${TMPDIR:-/tmp}"; WORK="${WORK%/}/cycle-driver-test.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

new_repo() {
  local dir="$WORK/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  printf '%s\n' "$dir"
}

# Pinned probes: no harness binary, no teams, no workflows, no network.
drv() {
  env -u CLAUDE_CODE_ENTRYPOINT -u LOOP_SPEC_AUTONOMOUS -u LOOP_SPEC_NON_INTERACTIVE \
    ${AUTONOMOUS:+LOOP_SPEC_AUTONOMOUS="$AUTONOMOUS"} \
    ${NON_INTERACTIVE:+LOOP_SPEC_NON_INTERACTIVE="$NON_INTERACTIVE"} \
    LOOP_SPEC_HARNESS="${HARNESS:-codex}" LOOP_SPEC_TEAMS_MODE=none \
    LOOP_SPEC_WORKFLOWS_AVAILABLE=0 LOOP_SPEC_CHECKPOINT_PR=0 \
    GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    bash "$SCRIPT" "$@"
}

# write_spec ROOT FEATURE_DIR: the smallest SPEC.md the spec exit accepts, because
# `next --returned-from spec` now runs that exit and answers REDO without one.
write_spec() {
  local root="$1" fd="$2" slug docs
  slug="$(jq -r '.slug' "$fd/feature.json")"; docs="$root/docs/loop-spec/features/$slug"; mkdir -p "$docs"
  cat > "$docs/SPEC.md" <<'MD'
---
ambiguity_scores:
  ambiguity: 0.1
  gate_passed: true
  unresolved_dimensions: []
---
# A feature

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
  printf '# transcript\n' > "$fd/spec-interview-transcript.md"
}
# --- usage ---------------------------------------------------------------------
ec=0; bash "$SCRIPT" >/dev/null 2>&1 || ec=$?
check "no subcommand exits 2" "2" "$ec"
ec=0; bash "$SCRIPT" next >/dev/null 2>&1 || ec=$?
check "next without --feature-dir exits 2" "2" "$ec"

# --- start ---------------------------------------------------------------------
REPO="$(new_repo r1)"
out="$(drv start --dir "$REPO" -- add a json flag 2>/dev/null)"
check "start: description mode" "description" "$(jq -r '.invocation.mode' <<<"$out")"
check "start: slug derived" "add-a-json-flag" "$(jq -r '.invocation.slug' <<<"$out")"
check "start: profile standard without evidence" "standard" "$(jq -r '.profile' <<<"$out")"
check "start: interactive asks only commands" "commands" "$(jq -r '[.decisions[].id] | join(",")' <<<"$out")"
check "start: runtime.json carries teamsMode" "none" "$(jq -r '.teamsMode' "$REPO/.loop-spec/runtime.json")"

out="$(AUTONOMOUS=1 drv start --dir "$REPO" -- add a json flag 2>/dev/null)"
check "start: autonomous asks nothing" "0" "$(jq -r '.decisions | length' <<<"$out")"
check "start: autonomous forces style auto" "auto" "$(jq -r '.invocation.style' <<<"$out")"
check "start: autonomous records the commands assumption" "1" \
  "$(grep -c 'detected project commands' "$REPO/.loop-spec/decisions-staging/decisions.jsonl" 2>/dev/null || echo 0)"

out="$(drv start --dir "$REPO" 2>/dev/null)"
check "start: bare interactive asks for a title" "title,commands" "$(jq -r '[.decisions[].id] | join(",")' <<<"$out")"
ec=0; AUTONOMOUS=1 drv start --dir "$REPO" >/dev/null 2>&1 || ec=$?
check "start: bare autonomous aborts with 3" "3" "$ec"
ec=0; NON_INTERACTIVE=1 LOOP_SPEC_ANSWER_STYLE=bogus drv start --dir "$REPO" -- x >/dev/null 2>&1 || ec=$?
check "start: bad LOOP_SPEC_ANSWER_STYLE exits 2" "2" "$ec"
ec=0; LOOP_SPEC_MODEL_IMPLEMENTER=bogus drv start --dir "$REPO" -- x >/dev/null 2>&1 || ec=$?
check "start: bad model selector exits 2" "2" "$ec"

printf '# Export JSON flag\n\nbody\n' > "$WORK/spec.md"
out="$(NON_INTERACTIVE=1 LOOP_SPEC_SPEC_FILE="$WORK/spec.md" drv start --dir "$REPO" 2>/dev/null)"
check "start: spec file mode from env" "spec-file" "$(jq -r '.invocation.mode' <<<"$out")"
check "start: spec file title from heading" "Export JSON flag" "$(jq -r '.invocation.title' <<<"$out")"

EMPTY="$WORK/empty"; mkdir -p "$EMPTY"
ec=0; drv start --dir "$EMPTY" -- x >/dev/null 2>&1 || ec=$?
check "start: not a repo, non-autonomous, no new token -> asks greenfield" "0" "$ec"
out="$(drv start --dir "$EMPTY" -- x 2>/dev/null)"
check "start: greenfield decision offered" "greenfield" "$(jq -r '.decisions[0].id' <<<"$out")"
out="$(drv start --dir "$EMPTY" -- new x 2>/dev/null)"
check "start: new token marks greenfield" "true" "$(jq -r '.greenfield' <<<"$out")"

# --- init + next (in-place harness) --------------------------------------------
init="$(drv init --dir "$REPO" --slug add-a-json-flag --title "add a json flag" --style step \
  --profile standard --autonomous 0 --spec-file "$WORK/spec.md" 2>/dev/null)"
FD="$(jq -r '.featureDir' <<<"$init")"
check "init: in-place harness enters no worktree" "null" "$(jq -r '.enterWorktree' <<<"$init")"
check "init: feature branch checked out" "feat/add-a-json-flag" "$(git -C "$REPO" branch --show-current)"
check "init: schema-7 feature.json" "7" "$(jq -r '.schemaVersion' "$FD/feature.json")"
check "init: spec draft copied" "1" "$([[ -f "$FD/spec-draft.md" ]] && echo 1 || echo 0)"
check "init: no backlog entry recorded by default" "null" "$(jq -r '.backlogEntryId' "$FD/feature.json")"

ec=0; drv init --dir "$REPO" --slug again --title again --style auto --profile standard >/dev/null 2>&1 || ec=$?
check "init: refuses a second feature on a dirty/branched checkout" "1" "$ec"

out="$(cd "$REPO" && drv next --feature-dir "$FD" 2>/dev/null)"
check "next: first step names spec" 'NEXT phase=spec label="Write the specification" effort=system2' "$out"
check "next: activation persisted models" "true" "$(jq '.models | length > 0' "$FD/feature.json")"
check "next: currentPhaseStartedAt stamped" "true" "$(jq '.currentPhaseStartedAt != null' "$FD/feature.json")"

write_spec "$REPO" "$FD"
out="$(cd "$REPO" && drv next --feature-dir "$FD" --returned-from spec --note "wrote SPEC" 2>/dev/null)"
check "next: style=step pauses at the human gate" "PAUSED node=human.after-spec" "$out"
check "next: journal records the real successor" "1" "$(grep -c 'spec → human.after-spec' "$FD/PROGRESS.md")"
check "next: state snapshot on the ref at the boundary" "state @ human.after-spec" "$(git -C "$REPO" log -1 --format=%s refs/loop-spec/state/add-a-json-flag)"
check "next: the feature branch carries no state commit" "0" "$(git -C "$REPO" log --oneline | grep -c 'state @')"
check "next: the project .gitignore is never written" "0" "$([[ -f "$REPO/.gitignore" ]] && grep -c 'loop-spec' "$REPO/.gitignore" || echo 0)"

out="$(cd "$REPO" && drv next --feature-dir "$FD" 2>/dev/null)"
check "next: re-invoke after pause continues to discuss" 'NEXT phase=discuss label="Challenge and refine the specification" effort=system2' "$out"

# declined SPEC gate is terminal for the invocation
jq -n '{status:"paused", reason:"spec-confirmation-declined"}' > "$FD/result.json"
out="$(cd "$REPO" && drv next --feature-dir "$FD" --returned-from spec 2>/dev/null)"
check "next: declined SPEC gate ends the loop" "DONE status=paused reason=spec-confirmation-declined" "$out"
rm -f "$FD/result.json"

# every phase boundary hands off after bookkeeping (style auto: no human gate)
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" execStyle '"auto"' >/dev/null
out="$(cd "$REPO" && drv next --feature-dir "$FD" --returned-from discuss 2>/dev/null)"
check "next: handoff answer names the successor" "HANDOFF next=" "${out:0:13}"
check "next: handoff writes a paused result" "phase-handoff" "$(jq -r '.reason' "$FD/result.json")"

# --- start: an autonomous re-invocation resumes the one paused feature ------------
out="$(AUTONOMOUS=1 drv start --dir "$REPO" -- add a json flag reworded 2>/dev/null)"
check "start: autonomous with one paused feature and a new title resumes it" "add-a-json-flag" "$(jq -r '.resume.autoPick' <<<"$out")"
check "start: the resume decision names the reworded slug" "1" \
  "$(grep -c 'outranks a new title (add-a-json-flag-reworded)' "$REPO/.loop-spec/decisions-staging/decisions.jsonl" 2>/dev/null || echo 0)"

# --- resume ----------------------------------------------------------------------
out="$(cd "$REPO" && drv resume --dir "$REPO" --feature-root "$REPO" 2>/dev/null)"
check "resume: in-place feature resumes from its root" "add-a-json-flag" "$(jq -r '.slug' <<<"$out")"
ec=0; (cd "$WORK" && drv resume --dir "$WORK" --feature-root "$REPO" >/dev/null 2>&1) || ec=$?
check "resume: in-place feature refuses another root" "1" "$ec"

OTHER="$REPO/.loop-spec/features/aaa-other"
mkdir -p "$OTHER"
jq '.slug="aaa-other" | .currentTeamName="untouched"' "$FD/feature.json" > "$OTHER/feature.json"
ec=0; drv resume --dir "$REPO" --feature-root "$REPO" >/dev/null 2>&1 || ec=$?
check "resume: shared root without identity refuses ambiguity" "1" "$ec"
out="$(drv resume --dir "$REPO" --feature-root "$REPO" --slug add-a-json-flag 2>/dev/null)"
check "resume: selected slug survives shared checkout" "add-a-json-flag" "$(jq -r '.slug' <<<"$out")"
check "resume: other feature remains untouched" "untouched" "$(jq -r '.currentTeamName' "$OTHER/feature.json")"
out="$(AUTONOMOUS=1 drv start --dir "$REPO" -- yet another title 2>/dev/null)"
check "start: two paused features and a new title pick nothing" "null" "$(jq -r '.resume.autoPick' <<<"$out")"
ec=0; drv resume --dir "$REPO" --feature-root "$REPO" --slug missing >/dev/null 2>&1 || ec=$?
check "resume: missing selected feature never falls back" "1" "$ec"
ec=0; drv resume --dir "$REPO" --feature-root "$REPO" --slug ../add-a-json-flag >/dev/null 2>&1 || ec=$?
check "resume: slug cannot traverse directories" "1" "$ec"

# --- finish / escalate -----------------------------------------------------------
ec=0; drv finish --feature-dir "$FD" >/dev/null 2>&1 || ec=$?
check "finish: no delivery sidecar is delivery-incomplete" "1" "$ec"
out="$(cd "$REPO" && drv escalate --feature-dir "$FD" --reason "iteration limit" 2>/dev/null)"
check "escalate: result is escalated" "escalated" "$(jq -r '.status' "$FD/result.json")"
check "escalate: team state cleared" "null" "$(jq -r '.currentTeamName' "$FD/feature.json")"
check "escalate: in-place feature exits no worktree" "false" "$(jq -r '.exitWorktree' <<<"$out")"

# --- profile preset reaches the driver --------------------------------------------------
REPO3="$(new_repo profiled)"
mkdir -p "$REPO3/.loop-spec"
printf '{"preset":"autonomous"}\n' > "$REPO3/.loop-spec/profile.json"
out="$(cd "$REPO3" && drv start -- "add a flag to the tool" 2>/dev/null)"
check "start: the profile's autonomous preset leaves no human decisions" "0" "$(jq '.decisions | length' <<<"$out")"
ec=0; init="$(cd "$REPO3" && drv init --dir "$REPO3" --slug flag --title "add a flag" --style auto --profile standard --autonomous 1 2>/dev/null)" || ec=$?
check "init: an untracked profile.json is not dirt" "0" "$ec"
check "init: the profile's preset arms the run autonomous" "true" "$(jq -r '.autonomous' "$REPO3/.loop-spec/active-run.json")"

# --- the raw-prompt stamp restores a dropped token ----------------------------------------
REPO5="$(new_repo stamped)"
mkdir -p "$REPO5/.loop-spec"
printf '{"schema":1,"skill":"cycle","args":"autonomous add a flag to the tool","ts":%s}\n' "$(date +%s)" > "$REPO5/.loop-spec/invocation-stamp.json"
out="$(cd "$REPO5" && drv start -- "add a flag to the tool" 2>/dev/null)"
check "start: a stamped autonomous token survives the prose rewrite" "true" "$(jq -r '.invocation.autonomous' <<<"$out")"
check "start: the stamp is consumed" "0" "$([[ -f "$REPO5/.loop-spec/invocation-stamp.json" ]] && echo 1 || echo 0)"
printf '{"schema":1,"skill":"cycle","args":"autonomous add a flag","ts":%s}\n' "$(( $(date +%s) - 7200 ))" > "$REPO5/.loop-spec/invocation-stamp.json"
out="$(cd "$REPO5" && drv start -- "add a flag to the tool" 2>/dev/null)"
check "start: a stale stamp is ignored" "false" "$(jq -r '.invocation.autonomous' <<<"$out")"

# --- dirty refusal names the paths ------------------------------------------------------
REPO4="$(new_repo dirty)"
printf 'wip\n' > "$REPO4/notes.txt"
out="$(cd "$REPO4" && drv init --dir "$REPO4" --slug d --title d --style auto --profile standard 2>&1 >/dev/null)" || true
check "init: dirty refusal names the dirty path" "1" "$(grep -c 'notes.txt' <<<"$out")"

# --- begin: start and init in one call ------------------------------------------------
REPO6="$(new_repo begun)"
out="$(cd "$REPO6" && AUTONOMOUS=1 drv begin -- "autonomous add a flag to the tool" 2>/dev/null)"
check "begin: an autonomous run initializes without a second call" "init" "$(jq -r '.action' <<<"$out")"
check "begin: the feature dir is created" "1" "$([[ -d "$(jq -r '.featureDir' <<<"$out")" ]] && echo 1 || echo 0)"
check "begin: start's notices ride along" "1" "$(jq '.notices | length > 0' <<<"$out" | grep -c true)"
FD6="$(jq -r '.featureDir' <<<"$out")"
out="$(cd "$REPO6" && drv begin -- "add a flag to the tool" 2>/dev/null)"
check "begin: a human decision is handed back" "decisions" "$(jq -r '.action' <<<"$out")"

# --- phase-begin: one ingress call per phase ------------------------------------------
out="$(cd "$REPO6" && AUTONOMOUS=1 drv phase-begin spec --feature-dir "$FD6" 2>/dev/null)"
check "phase-begin spec: entry packet is parsed" "1" "$(jq '.entry.fields | length > 0' <<<"$out" | grep -c true)"
check "phase-begin spec: the mode line is an object" "self-answer" "$(jq -r '.mode.path' <<<"$out")"
check "phase-begin spec: no flags on a fresh feature" "0" "$(jq '.entry.flags | length' <<<"$out")"
ec=0; out="$(cd "$REPO6" && drv phase-begin execute --feature-dir "$FD6" 2>/dev/null)" || ec=$?
check "phase-begin execute: a missing PLAN.md is a flagged ingress" "1" "$ec"
check "phase-begin execute: the flags name the missing artifacts" "true" "$(jq '[.entry.flags[] | select(test("PLAN"))] | length > 0' <<<"$out")"

# --- next runs the phase exit: REDO on flags, NEXT when clean ---------------------------
out="$(cd "$REPO6" && AUTONOMOUS=1 drv next --feature-dir "$FD6" 2>/dev/null)"
check "next: first entry is SPEC" "NEXT phase=spec" "${out:0:15}"
out="$(cd "$REPO6" && AUTONOMOUS=1 drv next --feature-dir "$FD6" --returned-from spec 2>/dev/null)"
check "next: a phase that wrote nothing is sent back" "REDO phase=spec" "${out:0:15}"
check "next: the FLAG lines follow the answer" "true" "$([[ "$(grep -c '^FLAG' <<<"$out")" -gt 0 ]] && echo true || echo false)"
out="$(cd "$REPO6" && AUTONOMOUS=1 drv next --feature-dir "$FD6" --returned-from spec 2>/dev/null)"
check "next: the same flags again count the attempt" "REDO phase=spec flags=" "${out:0:22}"
check "next: attempt two is reported" "1" "$(head -1 <<<"$out" | grep -c 'attempt=2')"
out="$(cd "$REPO6" && AUTONOMOUS=1 drv next --feature-dir "$FD6" --returned-from spec 2>/dev/null)"
check "next: the third identical REDO escalates" "DONE status=escalated" "${out:0:21}"
check "next: the escalation names the gate" "1" "$(head -1 <<<"$out" | grep -c 'spec exit gate unsatisfied')"
check "next: an escalated result is published" "escalated" "$(jq -r '.status' "$FD6/result.json")"
rm -f "$FD6/result.json"; bash "$REPO_ROOT/lib/feature-write.sh" set "$FD6" driverRedo null >/dev/null
DOCS6="$REPO6/docs/loop-spec/features/$(jq -r '.slug' "$FD6/feature.json")"; mkdir -p "$DOCS6"
cat > "$DOCS6/SPEC.md" <<'MD'
---
ambiguity_scores:
  ambiguity: 0.1
  gate_passed: true
  unresolved_dimensions: []
---
# Add a flag

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
printf '# transcript\n' > "$FD6/spec-interview-transcript.md"
out="$(cd "$REPO6" && AUTONOMOUS=1 drv next --feature-dir "$FD6" --returned-from spec 2>/dev/null)"
check "next: a clean exit hands the successor to a fresh session" "HANDOFF next=discuss model=" "${out:0:27}"
check "next: the handoff wrote the paused result" "phase-handoff" "$(jq -r '.reason' "$FD6/result.json")"
out="$(cd "$REPO6" && AUTONOMOUS=1 drv next --feature-dir "$FD6" 2>/dev/null)"
check "next: the fresh session enters the handed phase" "NEXT phase=discuss" "${out:0:18}"
check "next: the exit committed the artifact" "1" "$(git -C "$REPO6" log --oneline | grep -c 'spec: ')"

# --- claude worktree path -------------------------------------------------------------
REPO2="$(new_repo r2)"
HARNESS=claude AUTONOMOUS=1 drv start --dir "$REPO2" -- ship it >/dev/null 2>&1
init="$(HARNESS=claude drv init --dir "$REPO2" --slug ship-it --title "ship it" --style auto --profile standard --autonomous 1 \
  --backlog-entry '{"id":"abcd1234","text":"ship it"}' 2>/dev/null)"
check "init: backlog entry id persisted" "abcd1234" "$(jq -r '.backlogEntryId' "$(jq -r '.featureDir' <<<"$init")/feature.json")"
WT="$(jq -r '.enterWorktree' <<<"$init")"
check "init: claude gets a worktree to enter" "1" "$([[ -d "$WT" ]] && echo 1 || echo 0)"
check "init: control checkout stays on main" "main" "$(git -C "$REPO2" branch --show-current)"
out="$(cd "$WT" && HARNESS=claude drv next --feature-dir "$WT/.loop-spec/features/ship-it" 2>/dev/null)"
check "next: works from inside the worktree" "NEXT phase=spec" "${out:0:15}"
check "next: records the answered phase for cycle-result" "spec" "$(jq -r '.driverNext.phase' "$WT/.loop-spec/features/ship-it/feature.json")"
# The lead often runs the driver from the project root while the feature lives in the
# worktree; the state commit must land on the feature branch either way, never stage a
# .gitignore in the root checkout, and never fail silently.
write_spec "$WT" "$WT/.loop-spec/features/ship-it"
out="$(cd "$REPO2" && HARNESS=claude drv next --feature-dir "$WT/.loop-spec/features/ship-it" --returned-from spec --note "wrote SPEC" 2>/dev/null)"
check "next: from the project root still answers" "HANDOFF next=" "${out:0:13}"
check "next: the state ref is shared by the worktree and the root checkout" "$(git -C "$WT" rev-parse refs/loop-spec/state/ship-it)" "$(git -C "$REPO2" rev-parse refs/loop-spec/state/ship-it)"
check "next: the feature branch in the worktree carries no state commit" "0" "$(git -C "$WT" log --oneline | grep -c 'state @')"
check "next: the root checkout stays untouched" "" "$(git -C "$REPO2" status --porcelain -- .gitignore)"
out="$(HARNESS=claude drv resume --dir "$REPO2" --feature-root "$WT" 2>/dev/null)"
check "resume: claude re-enters the recorded worktree" "$WT" "$(jq -r '.enterWorktree' <<<"$out")"
ec=0; HARNESS=claude LOOP_SPEC_WORKTREES=0 drv resume --dir "$REPO2" --feature-root "$WT" >/dev/null 2>&1 || ec=$?
check "resume: LOOP_SPEC_WORKTREES=0 refuses a worktree feature" "1" "$ec"

echo
echo "cycle-driver: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
