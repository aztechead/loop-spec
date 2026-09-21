#!/usr/bin/env bash
# Tests for lib/cycle-driver.sh, part 1 of 5: usage, start, init+next. Split so
# tests/run-all.sh runs the five parts in parallel; the serial file set the wall clock.
. "$(dirname "$0")/cycle-driver.common.sh"

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
check "start: default bounds are recorded as not explicit" "false" "$(jq -r '.resources.explicit' "$REPO/.loop-spec/runtime.json")"

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

ec=0; err="$(drv init --dir "$REPO" --slug again --title again --style auto --profile standard 2>&1 >/dev/null)" || ec=$?
check "init: refuses a second feature on a dirty/branched checkout" "1" "$ec"
# The refusal names WHICH guard fired (6.6.7: currentPhase alone used to be the guard
# and could not tell a live cycle from a merged record), so it names the checkout
# evidence, not just the recorded phase.
check "init: the refusal names the live-checkout reason" "1" "$(grep -c 'already active in this checkout' <<<"$err")"
check "init: the refusal names the branch" "1" "$(grep -c 'feat/add-a-json-flag' <<<"$err")"

out="$(cd "$REPO" && drv next --feature-dir "$FD" 2>/dev/null)"
check "next: first step names spec" 'NEXT phase=spec label="Write the specification" effort=system2' "$(head -1 <<<"$out")"
# The spec node names the lite skill (graph data, port audit 3 N4): an EXT line the
# cycle skill acts on, never a change to the NEXT line's shape.
check "next: the spec node's skill is an EXT line" "EXT skill=spec-lite" "$(grep '^EXT skill=' <<<"$out")"
check "next: activation persisted models" "true" "$(jq '.models | length > 0' "$FD/feature.json")"
check "next: currentPhaseStartedAt stamped" "true" "$(jq '.currentPhaseStartedAt != null' "$FD/feature.json")"

write_spec "$REPO" "$FD"
out="$(cd "$REPO" && drv next --feature-dir "$FD" --returned-from spec --note "wrote SPEC" 2>/dev/null)"
check "next: style=step pauses at the human gate" "PAUSED node=human.after-spec" "${out%% intent=*}"
check "next: SPEC exit records the intent the human saw, not an approval" "true" "$(jq '.specIntentSeen.sha256 != null and .specApproval == null' "$FD/feature.json")"
ec=0; err="$(cd "$REPO" && drv phase-begin plan --feature-dir "$FD" 2>&1 >/dev/null)" || ec=$?
check "phase-begin: PLAN without the recorded approval is refused" "1" "$ec"
check "phase-begin: refused PLAN emits no planner packet" "0" "$(find "$FD/dispatch" -name 'plan-planner-brief.md' -print 2>/dev/null | wc -l | tr -d ' ')"
check "phase-begin: the refusal names the record" "1" "$(grep -c 'PLAN needs the recorded Goal and Boundary approval' <<<"$err")"
check "phase-begin: the refusal is on the ledger as a refusal" "1" "$(jq -c 'select(.event == "entry_refused" and .phase == "plan")' "$FD/events.jsonl" | wc -l | tr -d ' ')"
check "phase-begin: the refusal escalates nothing" "0" "$(jq -c 'select(.event == "escalated")' "$FD/events.jsonl" | wc -l | tr -d ' ')"
check "phase-begin: the refusal leaves the paused result in place" "paused" "$(jq -r '.status' "$FD/result.json")"
# A repeat return reruns the exit gate (6.6.4: a phase edited after a clean close no
# longer advances on the stale close), so a spec that lost its Goals draws the gate's
# REDO before the snapshot reader sees it. Either way the driver answers, never a
# traceback.
DOCS1="$REPO/docs/loop-spec/features/$(jq -r '.slug' "$FD/feature.json")"
cp "$DOCS1/SPEC.md" "$DOCS1/SPEC.md.keep"; sed -i.bak '/^## Goals$/,/^## Boundaries/{/^Produce/d;}' "$DOCS1/SPEC.md"; rm -f "$DOCS1/SPEC.md.bak"
ec=0; out="$(cd "$REPO" && drv next --feature-dir "$FD" --returned-from spec 2>/dev/null)" || ec=$?
check "next: a repeat spec return with an empty Goals section is the gate's REDO, not a traceback" "REDO phase=spec rc=0" "$(head -1 <<<"$out" | cut -d' ' -f1,2) rc=$ec"
check "next: the empty-Goals REDO is attempt 1" "1" "$(head -1 <<<"$out" | grep -c 'attempt=1')"
mv "$DOCS1/SPEC.md.keep" "$DOCS1/SPEC.md"
check "next: journal records the real successor" "1" "$(grep -c 'spec → human.after-spec' "$FD/PROGRESS.md")"
check "next: state snapshot on the ref at the boundary" "state @ human.after-spec" "$(git -C "$REPO" log -1 --format=%s refs/loop-spec/state/add-a-json-flag)"
check "next: the feature branch carries no state commit" "0" "$(git -C "$REPO" log --oneline | grep -c 'state @')"
check "next: the project .gitignore is never written" "0" "$([[ -f "$REPO/.gitignore" ]] && grep -c 'loop-spec' "$REPO/.gitignore" || echo 0)"


echo
echo "cycle-driver-core: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
