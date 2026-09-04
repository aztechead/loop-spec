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
check "init: phaseHandoff persisted false" "false" "$(jq -r '.phaseHandoff' "$FD/feature.json")"
check "init: no backlog entry recorded by default" "null" "$(jq -r '.backlogEntryId' "$FD/feature.json")"

ec=0; drv init --dir "$REPO" --slug again --title again --style auto --profile standard >/dev/null 2>&1 || ec=$?
check "init: refuses a second feature on a dirty/branched checkout" "1" "$ec"

out="$(cd "$REPO" && drv next --feature-dir "$FD" 2>/dev/null)"
check "next: first step names spec" 'NEXT phase=spec label="Write the specification" effort=system2' "$out"
check "next: activation persisted models" "true" "$(jq '.models | length > 0' "$FD/feature.json")"
check "next: currentPhaseStartedAt stamped" "true" "$(jq '.currentPhaseStartedAt != null' "$FD/feature.json")"

out="$(cd "$REPO" && drv next --feature-dir "$FD" --returned-from spec --note "wrote SPEC" 2>/dev/null)"
check "next: style=step pauses at the human gate" "PAUSED node=human.after-spec" "$out"
check "next: journal records the real successor" "1" "$(grep -c 'spec → human.after-spec' "$FD/PROGRESS.md")"
check "next: state committed at the boundary" "1" "$(git -C "$REPO" log --oneline | grep -c 'state @ human.after-spec')"
check "next: PROGRESS.md gitignore exception added" "1" "$(grep -c '^!/.loop-spec/features/\*/PROGRESS.md$' "$REPO/.gitignore")"

out="$(cd "$REPO" && drv next --feature-dir "$FD" 2>/dev/null)"
check "next: re-invoke after pause continues to discuss" 'NEXT phase=discuss label="Challenge and refine the specification" effort=system2' "$out"

# declined SPEC gate is terminal for the invocation
jq -n '{status:"paused", reason:"spec-confirmation-declined"}' > "$FD/result.json"
out="$(cd "$REPO" && drv next --feature-dir "$FD" --returned-from spec 2>/dev/null)"
check "next: declined SPEC gate ends the loop" "DONE status=paused reason=spec-confirmation-declined" "$out"
rm -f "$FD/result.json"

# phase handoff exits after bookkeeping with the next phase named (style auto: no human gate)
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" execStyle '"auto"' >/dev/null
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" phaseHandoff true >/dev/null
out="$(cd "$REPO" && drv next --feature-dir "$FD" --returned-from discuss 2>/dev/null)"
check "next: handoff answer names the successor" "HANDOFF next=" "${out:0:13}"
check "next: handoff writes a paused result" "phase-handoff" "$(jq -r '.reason' "$FD/result.json")"

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
out="$(HARNESS=claude drv resume --dir "$REPO2" --feature-root "$WT" 2>/dev/null)"
check "resume: claude re-enters the recorded worktree" "$WT" "$(jq -r '.enterWorktree' <<<"$out")"
ec=0; HARNESS=claude LOOP_SPEC_WORKTREES=0 drv resume --dir "$REPO2" --feature-root "$WT" >/dev/null 2>&1 || ec=$?
check "resume: LOOP_SPEC_WORKTREES=0 refuses a worktree feature" "1" "$ec"

echo
echo "cycle-driver: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
