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
WORK="$(cd "$WORK" && pwd -P)"

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
    -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID ${SESSION:+CLAUDE_CODE_SESSION_ID="$SESSION"} \
    ${AUTONOMOUS:+LOOP_SPEC_AUTONOMOUS="$AUTONOMOUS"} \
    ${NON_INTERACTIVE:+LOOP_SPEC_NON_INTERACTIVE="$NON_INTERACTIVE"} \
    LOOP_SPEC_HARNESS="${HARNESS:-codex}" LOOP_SPEC_TEAMS_MODE=none \
    LOOP_SPEC_WORKFLOWS_AVAILABLE=0 LOOP_SPEC_CHECKPOINT_PR=0 \
    GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    bash "$SCRIPT" "$@"
}

# write_spec ROOT FEATURE_DIR: the smallest SPEC.md the spec exit accepts, because
# `next --returned-from spec` now runs that exit and answers REDO without one. No
# approval: the driver records that itself when the cycle enters PLAN.
write_spec() {
  local root="$1" fd="$2" slug docs
  slug="$(jq -r '.slug' "$fd/feature.json")"; docs="$root/docs/loop-spec/features/$slug"; mkdir -p "$docs"
  cp "$REPO_ROOT/tests/fixtures/minimal-SPEC.md" "$docs/SPEC.md"
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
check "next: first step names spec" 'NEXT phase=spec label="Write the specification" effort=system2' "$(head -1 <<<"$out")"
# The spec node names the lite skill (graph data, port audit 3 N4): an EXT line the
# cycle skill acts on, never a change to the NEXT line's shape.
check "next: the spec node's skill is an EXT line" "EXT skill=spec-lite" "$(grep '^EXT skill=' <<<"$out")"
check "next: activation persisted models" "true" "$(jq '.models | length > 0' "$FD/feature.json")"
check "next: currentPhaseStartedAt stamped" "true" "$(jq '.currentPhaseStartedAt != null' "$FD/feature.json")"

write_spec "$REPO" "$FD"
out="$(cd "$REPO" && drv next --feature-dir "$FD" --returned-from spec --note "wrote SPEC" 2>/dev/null)"
check "next: style=step pauses at the human gate" "PAUSED node=human.after-spec" "$out"
check "next: SPEC exit records the intent the human saw, not an approval" "true" "$(jq '.specIntentSeen.sha256 != null and .specApproval == null' "$FD/feature.json")"
ec=0; err="$(cd "$REPO" && drv phase-begin plan --feature-dir "$FD" 2>&1 >/dev/null)" || ec=$?
check "phase-begin: PLAN without the recorded approval is refused" "1" "$ec"
check "phase-begin: the refusal names the record" "1" "$(grep -c 'PLAN needs the recorded Goal and Boundary approval' <<<"$err")"
check "phase-begin: the refusal is on the ledger as a refusal" "1" "$(jq -c 'select(.event == "entry_refused" and .phase == "plan")' "$FD/events.jsonl" | wc -l | tr -d ' ')"
check "phase-begin: the refusal escalates nothing" "0" "$(jq -c 'select(.event == "escalated")' "$FD/events.jsonl" | wc -l | tr -d ' ')"
check "phase-begin: the refusal leaves the paused result in place" "paused" "$(jq -r '.status' "$FD/result.json")"
# A repeat return reruns the exit gate (6.6.4: a phase edited after a clean close no
# longer advances on the stale close), so a spec that lost its Goals draws the gate's
# REDO before the snapshot reader sees it. Either way the driver answers, never a
# traceback.
DOCS1="$REPO/docs/loop-spec/features/$(jq -r '.slug' "$FD/feature.json")"
cp "$DOCS1/SPEC.md" "$DOCS1/SPEC.md.keep"; sed -i '/^## Goals$/,/^## Boundaries/{/^Produce/d}' "$DOCS1/SPEC.md"
ec=0; out="$(cd "$REPO" && drv next --feature-dir "$FD" --returned-from spec 2>/dev/null)" || ec=$?
check "next: a repeat spec return with an empty Goals section is the gate's REDO, not a traceback" "REDO phase=spec rc=0" "$(head -1 <<<"$out" | cut -d' ' -f1,2) rc=$ec"
mv "$DOCS1/SPEC.md.keep" "$DOCS1/SPEC.md"
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" driverRedo 'null' >/dev/null
check "next: journal records the real successor" "1" "$(grep -c 'spec → human.after-spec' "$FD/PROGRESS.md")"
check "next: state snapshot on the ref at the boundary" "state @ human.after-spec" "$(git -C "$REPO" log -1 --format=%s refs/loop-spec/state/add-a-json-flag)"
check "next: the feature branch carries no state commit" "0" "$(git -C "$REPO" log --oneline | grep -c 'state @')"
check "next: the project .gitignore is never written" "0" "$([[ -f "$REPO/.gitignore" ]] && grep -c 'loop-spec' "$REPO/.gitignore" || echo 0)"

out="$(cd "$REPO" && drv next --feature-dir "$FD" 2>/dev/null)"
check "next: re-invoke after pause continues to discuss" 'NEXT phase=discuss label="Challenge and refine the specification" effort=system2' "$(head -1 <<<"$out")"
check "next: the resumed pause record is gone" "0" "$([[ -f "$FD/result.json" ]] && echo 1 || echo 0)"
check "next: the resumed pause pointer is gone" "0" "$([[ -f "$REPO/.loop-spec/last-result.json" ]] && echo 1 || echo 0)"

# DISCUSS may still rewrite Goal and Boundary (the run that froze them at SPEC exit died
# when the human answered DISCUSS's follow-ups); the human gate says so, PLAN freezes.
sed -i 's/^Produce the requested behavior\.$/Produce the requested behavior and log it./' "$DOCS1/SPEC.md"
out="$(cd "$REPO" && drv next --feature-dir "$FD" --returned-from discuss 2>/dev/null)"
check "next: a Goals edit in DISCUSS pauses at the human gate instead of escalating" "PAUSED node=human.after-discuss intent=changed" "$out"
check "next: nothing is frozen before PLAN" "null" "$(jq -r '.specApproval' "$FD/feature.json")"
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" currentPhase '"discuss"' >/dev/null

# declined SPEC gate is terminal for the invocation
jq -n '{status:"paused", reason:"spec-confirmation-declined"}' > "$FD/result.json"
out="$(cd "$REPO" && drv next --feature-dir "$FD" --returned-from spec 2>/dev/null)"
check "next: declined SPEC gate ends the loop" "DONE status=paused reason=spec-confirmation-declined" "$out"
rm -f "$FD/result.json"

# every phase boundary hands off after bookkeeping (style auto: no human gate)
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" execStyle '"auto"' >/dev/null
out="$(cd "$REPO" && SESSION=s1 drv next --feature-dir "$FD" --returned-from discuss 2>/dev/null)"
check "next: handoff answer names the successor" "HANDOFF next=" "${out:0:13}"
check "next: handoff writes a paused result" "phase-handoff" "$(jq -r '.reason' "$FD/result.json")"

# The session that handed off is done: the driver refuses to carry it into the next
# phase whatever tool it reaches for; a fresh session (another id) proceeds.
check "next: the handoff records the session" "s1" "$(jq -r '.handoffSession.id' "$FD/feature.json")"
out="$(cd "$REPO" && SESSION=s1 drv next --feature-dir "$FD" 2>/dev/null)"
check "next: the same session gets the handoff answer again" "HANDOFF next=plan" "${out:0:17}"
check "next: entering PLAN recorded the approval from the run, not a lead" "human" "$(jq -r '.specApproval.source' "$FD/feature.json")"
check "next: the approval digests the DISCUSS-edited text" "1" "$(python3 -c "
import sys, json; sys.path.insert(0, '$REPO_ROOT/lib'); from spec_intent import intent_digest
print(int(intent_digest(open('$DOCS1/SPEC.md').read()) == json.load(open('$FD/feature.json'))['specApproval']['sha256']))")"
check "next: the spec-approved event names PLAN" "plan" "$(jq -r 'select(.event == "spec-approved") | .phase' "$FD/events.jsonl")"
# The repeat answers from the record: no second phase_end/phase_start pair lands in the
# ledger (a sink counting phase ends read two on the f0959f6 run; port audit 3, N7).
pairs_before="$(grep -c '"event":"phase_\(start\|end\)"' "$FD/events.jsonl")"
(cd "$REPO" && AUTONOMOUS=1 SESSION=s1 drv next --feature-dir "$FD" >/dev/null 2>&1)
check "next: a repeated handoff answer emits no phase event pair" "$pairs_before" "$(grep -c '"event":"phase_\(start\|end\)"' "$FD/events.jsonl")"
ec=0; (cd "$REPO" && SESSION=s1 drv phase-begin plan --feature-dir "$FD" >/dev/null 2>&1) || ec=$?
check "phase-begin: the same session is refused with 4" "4" "$ec"
ec=0; (cd "$REPO" && SESSION=s2 drv phase-begin plan --feature-dir "$FD" >/dev/null 2>&1) || ec=$?
check "phase-begin: a fresh session is not refused by the handoff" "0" "$([[ "$ec" -eq 4 ]] && echo 4 || echo 0)"

# A same-session re-entry through begin runs preflight, which clears the result pointer;
# the repeated answer and the refusal both put the pointer back for the caller.
bash "$REPO_ROOT/lib/cycle-result.sh" clear --result-root "$REPO"
out="$(cd "$REPO" && SESSION=s1 drv next --feature-dir "$FD" 2>/dev/null)"
check "next: the repeated handoff answer puts the result pointer back" "phase-handoff" "$(jq -r '.reason' "$REPO/.loop-spec/last-result.json" 2>/dev/null)"
bash "$REPO_ROOT/lib/cycle-result.sh" clear --result-root "$REPO"
ec=0; err="$(cd "$REPO" && SESSION=s1 AUTONOMOUS=1 drv begin --dir "$REPO" -- add a json flag 2>&1 >/dev/null)" || ec=$?
check "begin: the session that handed off is refused with 4" "4" "$ec"
check "begin: the refusal carries the handoff answer" "1" "$(grep -c 'HANDOFF next=plan' <<<"$err")"
check "begin: the refused re-entry emits no phase event pair" "$pairs_before" "$(grep -c '"event":"phase_\(start\|end\)"' "$FD/events.jsonl")"
check "begin: the refusal puts the result pointer back" "phase-handoff" "$(jq -r '.reason' "$REPO/.loop-spec/last-result.json" 2>/dev/null)"

# A human-approved SPEC rewind reopens the freeze: the engine resumes from the pause
# record at the approval gate, the driver retires the record, DISCUSS may amend, and
# the DISCUSS gate compares against what was approved.
FROZEN="$(jq -r '.specApproval.sha256' "$FD/feature.json")"
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" handoffSession null >/dev/null
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" execStyle '"step"' >/dev/null
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" iterate '{"used":1,"maxIterations":3,"feedback":{"type":"spec","description":"goal too narrow","fix_first":"widen"}}' >/dev/null
printf '{"node":"human.iterate-spec-approval"}\n' > "$FD/graph-pause.json"
out="$(cd "$REPO" && SESSION=s3 drv next --feature-dir "$FD" 2>/dev/null)"
check "next: the approved spec rewind enters DISCUSS" "NEXT phase=discuss" "${out:0:18}"
check "next: the approved rewind retires the approval" "null" "$(jq -r '.specApproval' "$FD/feature.json")"
check "next: the retired record keeps its digest and names the gate" "$FROZEN human.iterate-spec-approval" "$(jq -r '.specApprovalHistory[-1] | "\(.sha256) \(.reopenedBy)"' "$FD/feature.json")"
check "next: the DISCUSS gate will compare against the retired digest" "$FROZEN" "$(jq -r '.specIntentSeen.sha256' "$FD/feature.json")"
check "next: the reopen is on the event ledger" "1" "$(jq -c 'select(.event == "spec-reopened")' "$FD/events.jsonl" | wc -l | tr -d ' ')"
sed -i.bak 's/^Produce the requested behavior and log it\.$/Produce and log the requested behavior for every caller./' "$DOCS1/SPEC.md"; rm -f "$DOCS1/SPEC.md.bak"
out="$(cd "$REPO" && SESSION=s3 drv next --feature-dir "$FD" --returned-from discuss 2>/dev/null)"
check "next: the reopened Goals edit pauses at the DISCUSS gate as changed" "PAUSED node=human.after-discuss intent=changed" "$out"
out="$(cd "$REPO" && SESSION=s3 drv next --feature-dir "$FD" 2>/dev/null)"
check "next: PLAN freezes the amended text again" "true" "$(jq --arg old "$FROZEN" '.specApproval.sha256 != null and .specApproval.sha256 != $old' "$FD/feature.json")"
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" execStyle '"auto"' >/dev/null

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
# Attended, exactly one paused feature: it resumes without a question (6.6.4; the
# question used to be a resume decision).
out="$(cd "$REPO6" && drv begin -- "add a flag to the tool" 2>/dev/null)"
check "begin: the one paused feature resumes without a question" "resume" "$(jq -r '.action' <<<"$out")"
check "begin: the resumed feature is the paused one" "$FD6" "$(jq -r '.featureDir' <<<"$out")"
# Attended with nothing to go on: the title and commands are the human's decisions.
REPO6B="$(new_repo undecided)"
out="$(cd "$REPO6B" && drv begin -- 2>/dev/null)"
check "begin: a human decision is handed back" "decisions" "$(jq -r '.action' <<<"$out")"
check "begin: the decisions name the title and the commands" "title commands" "$(jq -r '[.decisions[].id] | join(" ")' <<<"$out")"
check "begin: the init command the lead runs next is rendered with start's values" "1" "$(jq -r '.next.init' <<<"$out" | grep -c '^bash "\$DRV" init --dir .* --slug <slug> --title "<title>" --style .* --greenfield <0|1> ')"
check "begin: the resume command is rendered for a pick" "1" "$(jq -r '.next.resume' <<<"$out" | grep -c '^bash "\$DRV" resume --dir .* --feature-root <featureRoot of the pick> --slug <slug of the pick>$')"

# --- finish renders the completion report; decline writes the mismatch result (N4) ----
REPO10="$(new_repo finish-report)"
out="$(cd "$REPO10" && AUTONOMOUS=1 drv begin -- "autonomous add a flag" 2>/dev/null)"; FD10="$(jq -r '.featureDir' <<<"$out")"
printf '{"status":"pushed-no-pr","nextPhase":"completed","targets":[{"name":"finish-report","targetSha":"0123456789abcdef0123","prUrl":null,"errorCode":null}],"feedback":null}\n' > "$FD10/delivery.json"
out="$(cd "$REPO10" && drv finish --feature-dir "$FD10" --completed 1 2>/dev/null)"
check "finish: the report opens with the outcome" "1" "$(jq -r '.report' <<<"$out" | head -1 | grep -c 'pushed to the remote')"
check "finish: one line per target with its SHA" "1" "$(jq -r '.report' <<<"$out" | grep -c '^- finish-report, sha 0123456789ab$')"
check "finish: the report ends with the backlog count" "1" "$(jq -r '.report' <<<"$out" | tail -1 | grep -c '^backlog entries remaining: [0-9]')"
check "finish: the report is one string the lead prints as is" "string" "$(jq -r '.report | type' <<<"$out")"
REPO11="$(new_repo decline)"; printf 'x\n' > "$REPO11/a.txt"; git -C "$REPO11" add -A && git -C "$REPO11" -c commit.gpgsign=false commit -q -m a
out="$(cd "$REPO11" && drv decline --dir "$REPO11" --reason "a question about the architecture" --summary "answer it in chat" 2>/dev/null)"
check "decline: the answer names the mismatch" "protocol-mismatch" "$(jq -r '.outcome' <<<"$out")"
check "decline: the terminal result is published" "escalated protocol-mismatch" "$(jq -r '"\(.status) \(.outcome)"' "$REPO11/.loop-spec/last-result.json")"
printf 'y\n' > "$REPO11/a.txt"
ec=0; (cd "$REPO11" && drv decline --dir "$REPO11" --reason "too late" >/dev/null 2>&1) || ec=$?
check "decline: a changed tree is work to finish, not a mismatch (the writer refuses)" "1" "$ec"
ec=0; (cd "$REPO11" && drv decline --dir "$REPO11" >/dev/null 2>&1) || ec=$?
check "decline: no reason is a bad invocation" "2" "$ec"
# Past begin the work is reported through the cycle, never declined (port4-haiku-3
# declined with the fix committed).
ec=0; out="$(cd "$REPO10" && drv decline --dir "$REPO10" --reason "a harness error, work is done" 2>&1 >/dev/null)" || ec=$?
check "decline: refused once a feature has begun in the checkout" "1" "$ec"
check "decline: the refusal names the feature and the way out" "1" "$(grep -c 'has begun (phase .*); a run past begin finishes through the cycle or escalates' <<<"$out")"

# --- a cycle never runs in the plugin's own repository (port audit 3, N6) ---------------
# The checkout carries this plugin's manifest and is not the project the harness opened.
REPO8="$(new_repo plugin-home)"; mkdir -p "$REPO8/.claude-plugin"
printf '{"name":"loop-spec","version":"0.0.0"}\n' > "$REPO8/.claude-plugin/plugin.json"
git -C "$REPO8" add -A && git -C "$REPO8" -c commit.gpgsign=false commit -q -m "manifest"
ec=0; out="$(cd "$REPO8" && CLAUDE_PROJECT_DIR= drv init --dir "$REPO8" --slug x --title x --style auto --profile standard 2>&1 >/dev/null)" || ec=$?
check "init: the plugin's own repository is refused with exit 3" "3" "$ec"
check "init: the refusal names the manifest and the rule" "1" "$(grep -c "plugin's own repository (.claude-plugin/plugin.json)" <<<"$out")"
check "init: nothing was initialized" "0" "$(ls -d "$REPO8"/.loop-spec/features/*/ 2>/dev/null | wc -l | tr -d ' ')"
ec=0; (cd "$REPO8" && CLAUDE_PROJECT_DIR="$REPO8" drv init --dir "$REPO8" --slug x --title x --style auto --profile standard >/dev/null 2>&1) || ec=$?
check "init: the plugin developing itself (the project the harness opened) is allowed" "0" "$ec"
# The driver running from a copy inside the checkout it would initialize (the eval's
# layout) is the second probe; a pure function, so the layout is a pair of paths.
check "init: a driver copy inside the target checkout is refused" "1" "$(cd "$REPO_ROOT/lib/graph" && python3 -c 'import driver; print(1 if driver.plugin_home_refusal("/w/loop-spec", "/w/loop-spec/evals/.runs/x/plugin", "/w/loop-spec/evals/.runs/x/t/project") else 0)')"
check "init: an installed plugin outside the project is not refused" "0" "$(cd "$REPO_ROOT/lib/graph" && python3 -c 'import driver; print(1 if driver.plugin_home_refusal("/w/project", "/home/u/.claude/plugins/loop-spec", "/w/project") else 0)')"

# --- the short route is one session: spec -> oneshot answers NEXT, not HANDOFF --------
REPO7="$(new_repo oneshot)"
printf 'def slugify(s):\n    return s.lower()\n' > "$REPO7/slugify.py"
git -C "$REPO7" add -A && git -C "$REPO7" -c commit.gpgsign=false commit -q -m "add slugify"
out="$(cd "$REPO7" && AUTONOMOUS=1 drv begin -- "autonomous fix slugify dots" 2>/dev/null)"
FD7="$(jq -r '.featureDir' <<<"$out")"
DOCS7="$REPO7/docs/loop-spec/features/$(jq -r '.slug' "$FD7/feature.json")"
# The driver decides the oneshot candidate from the scout's record and writes the
# skeleton where the exit gate reads it, with the facts it holds filled and the lead's
# values left as placeholders. The lead never types the footprint into the driver.
out="$(cd "$REPO7" && drv spec skeleton --feature-dir "$FD7" 2>/dev/null)"
check "spec skeleton: no scout cite is the full route" "full" "$(jq -r '.route' <<<"$out")"
check "spec skeleton: the reason says the scout cited nothing" "1" "$(jq -r '.reason' <<<"$out" | grep -c 'the scout cited no file')"
check "spec skeleton: nothing is written on the full route" "0" "$([[ -f "$DOCS7/SPEC.md" ]] && echo 1 || echo 0)"
for f in a b c d; do bash "$REPO_ROOT/lib/footprint.sh" cite "$FD7" "$f.py:1"; done
out="$(cd "$REPO7" && drv spec skeleton --feature-dir "$FD7" 2>/dev/null)"
check "spec skeleton: four cited files is the full route" "1" "$(jq -r '.reason' <<<"$out" | grep -c 'footprint names 4 files')"
rm -f "$FD7/footprint.jsonl"
bash "$REPO_ROOT/lib/footprint.sh" cite "$FD7" slugify.py:2 "lower() drops nothing"
bash "$REPO_ROOT/lib/footprint.sh" cite "$FD7" README.md:1 --read-only "docs are not the change"
out="$(cd "$WORK" && drv spec skeleton --feature-dir "$FD7" 2>/dev/null)"
check "spec skeleton: one cited file is the oneshot route" "oneshot" "$(jq -r '.route' <<<"$out")"
# Read-only is the task's word (port audit 4, item 1): README.md was marked read-only by
# the scout but the task protects nothing, so it stays in the footprint.
check "spec skeleton: a read-only mark on an unprotected file is not honored" '["slugify.py","README.md"]' "$(jq -c '.footprint' <<<"$out")"
check "spec skeleton: nothing is read-only without a protected list" '[]' "$(jq -c '.readOnly' <<<"$out")"
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD7" protected '["README.md"]' >/dev/null
rm -f "$DOCS7/SPEC.md"
out="$(cd "$REPO7" && drv spec skeleton --feature-dir "$FD7" 2>/dev/null)"
check "spec skeleton: the footprint is the record minus the protected file" '["slugify.py"]' "$(jq -c '.footprint' <<<"$out")"
check "spec skeleton: the protected file is read-only" '["README.md"]' "$(jq -c '.readOnly' <<<"$out")"
check "spec skeleton: prints the path in the feature's checkout, not the cwd" "$DOCS7/SPEC.md" "$(jq -r '.spec' <<<"$out")"
check "spec skeleton: the title is filled" "# fix slugify dots" "$(sed -n '/^# /p' "$DOCS7/SPEC.md" | head -1)"
check "spec skeleton: the footprint is filled" "1" "$(grep -c '^  - slugify.py$' "$DOCS7/SPEC.md")"
check "spec skeleton: the read-only file is not in the footprint" "0" "$(grep -c '^  - README.md$' "$DOCS7/SPEC.md")"
check "spec skeleton: one Implementation notes bullet per footprint file" "1" "$(grep -c '^- slugify.py: {' "$DOCS7/SPEC.md")"
check "spec skeleton: a read-only bullet per read-only cite" "1" "$(grep -c '^- README.md: read-only; the change does not touch it.$' "$DOCS7/SPEC.md")"
check "spec skeleton: no score to fill, only the two keys the probe reads" "0" "$(grep -c 'goal_clarity\|{0.00-1.00}' "$DOCS7/SPEC.md")"
check "spec skeleton: the frozen Intent block is in place" "2" "$(grep -c '^<!-- intent: frozen\|^<!-- /intent -->' "$DOCS7/SPEC.md")"
check "spec skeleton: the oneshot spec lint accepts the shape" "0" "$(bash "$REPO_ROOT/lib/oneshot-spec-lint.sh" "$DOCS7/SPEC.md" >/dev/null 2>&1; echo $?)"
# The driver is the only writer of the shape (port audit 3, N1): the lead fills values
# one call at a time and each answer carries the gate's flags so far.
out="$(cd "$REPO7" && drv spec fill --feature-dir "$FD7" --intent "Dots survive slugify." 2>/dev/null)"
check "spec fill: the intent lands inside the frozen block" "Dots survive slugify." "$(sed -n '/^## Intent$/,/^<!-- \/intent -->$/p' "$DOCS7/SPEC.md" | sed '1d;$d;/^$/d')"
check "spec fill: the answer names what it filled and the flags so far" "intent" "$(jq -r '.filled[0]' <<<"$out")"
out="$(cd "$REPO7" && drv spec fill --feature-dir "$FD7" --file slugify.py --note "strip dots in slugify()" 2>/dev/null)"
check "spec fill: a footprint file's bullet is replaced in place" "1" "$(grep -c '^- slugify.py: strip dots in slugify()$' "$DOCS7/SPEC.md")"
ec=0; (cd "$REPO7" && drv spec fill --feature-dir "$FD7" --file nope.py --note "x" >/dev/null 2>&1) || ec=$?
check "spec fill: a file with no bullet is refused" "1" "$ec"
# A criterion is two fields the driver writes, never a sentence the lead composes; the
# command also lands in the frontmatter map `verification run` executes (port audit 5, R1).
ec=0; (cd "$REPO7" && drv spec fill --feature-dir "$FD7" --criterion 'python3 -m unittest exits 0: all pass' >/dev/null 2>&1) || ec=$?
check "spec fill: a criterion sentence is refused" "2" "$ec"
ec=0; (cd "$REPO7" && drv spec fill --feature-dir "$FD7" --command 'true' >/dev/null 2>&1) || ec=$?
check "spec fill: a command without its expectation is refused" "2" "$ec"
out="$(cd "$REPO7" && drv spec fill --feature-dir "$FD7" --command 'python3 -c "from slugify import slugify; assert slugify(\x27a.b\x27) == \x27ab\x27"' --expect "dots are gone" 2>/dev/null)"
check "spec fill: the first criterion replaces the placeholders" "0" "$(grep -c '{check command}' "$DOCS7/SPEC.md")"
check "spec fill: the driver writes the line" "1" "$(grep -c '^- \[ \] `python3 -c "from slugify import slugify; assert slugify(.*` exits 0: dots are gone$' "$DOCS7/SPEC.md")"
check "spec fill: the answer names the row" "criterion:GE-001" "$(jq -r '.filled[0]' <<<"$out")"
check "spec fill: the command lands in the frontmatter criteria map" "1" "$(sed -n '1,/^---$/!d; /^  GE-001: "python3 -c /p' "$DOCS7/SPEC.md" | grep -c .)"
(cd "$REPO7" && drv spec fill --feature-dir "$FD7" --command 'python3 -c "from slugify import slugify; assert slugify(\x27a.b\x27) == \x27ab\x27"' --expect "dots are gone" >/dev/null 2>&1)
check "spec fill: a repeated criterion is not appended twice" "1" "$(grep -c '^- \[ \] `python3 -c' "$DOCS7/SPEC.md")"
# --row replaces (port audit 5, R2): the same row, a new command, still one criterion.
out="$(cd "$REPO7" && drv spec fill --feature-dir "$FD7" --command 'python3 -c "from slugify import slugify; assert slugify(\x27a.b\x27) == \x27ab\x27"' --expect "dots are gone, checked again" --row GE-001 2>/dev/null)"
check "spec fill --row: the criterion is replaced, not appended" "1" "$(grep -c '^- \[ \] ' "$DOCS7/SPEC.md")"
check "spec fill --row: the new expectation stands" "1" "$(grep -c 'exits 0: dots are gone, checked again$' "$DOCS7/SPEC.md")"
ec=0; (cd "$REPO7" && drv spec fill --feature-dir "$FD7" --command true --expect x --row GE-009 >/dev/null 2>&1) || ec=$?
check "spec fill --row: a row the spec does not hold is refused" "1" "$ec"
out="$(cd "$REPO7" && drv spec fill --feature-dir "$FD7" --grounding "slugify.py:2 is the one transform" 2>/dev/null)"
check "spec fill: a grounding bullet replaces none" "0" "$(grep -c '^- none$' "$DOCS7/SPEC.md")"
check "spec fill: the filled skeleton passes both spec lints" "[]" "$(jq -c '.flags' <<<"$out")"
ec=0; (cd "$REPO7" && drv spec fill --feature-dir "$FD7" >/dev/null 2>&1) || ec=$?
check "spec fill: nothing to fill is a bad invocation" "2" "$ec"
# One call for the whole spec (port audit 4, item 5): the same fills from a JSON object.
cp "$DOCS7/SPEC.md" "$WORK/spec7.filled"; rm -f "$DOCS7/SPEC.md"
(cd "$REPO7" && drv spec skeleton --feature-dir "$FD7" >/dev/null 2>&1)
out="$(cd "$REPO7" && printf '%s' '{"intent":"Dots survive slugify.","notes":{"slugify.py":"strip dots in slugify()"},"criteria":[{"command":"true","expect":"it runs"}],"grounding":["slugify.py:2 is the one transform"]}' | drv spec fill --feature-dir "$FD7" --json - 2>/dev/null)"
check "spec fill --json: every field in one call" "intent note:slugify.py criterion:GE-001 grounding" "$(jq -r '.filled | join(" ")' <<<"$out")"
ec=0; (cd "$REPO7" && printf '%s' '{"criteria":["`true` exits 0: a sentence"]}' | drv spec fill --feature-dir "$FD7" --json - >/dev/null 2>&1) || ec=$?
check "spec fill --json: a criterion sentence is refused" "2" "$ec"
check "spec fill --json: the result passes both spec lints" "[]" "$(jq -c '.flags' <<<"$out")"
ec=0; (cd "$REPO7" && printf 'not json' | drv spec fill --feature-dir "$FD7" --json - >/dev/null 2>&1) || ec=$?
check "spec fill --json: a non-object is a bad invocation" "2" "$ec"
cp "$WORK/spec7.filled" "$DOCS7/SPEC.md"
cp "$DOCS7/SPEC.md" "$WORK/spec7.bak"
# A whole-file write over the oneshot skeleton is refused; after an escalation the spec
# is the lead's full shape again.
printf '# a draft\n' > "$WORK/draft7.md"
ec=0; (cd "$REPO7" && drv spec write --feature-dir "$FD7" --file "$WORK/draft7.md" >/dev/null 2>&1) || ec=$?
check "spec write: refused over the oneshot skeleton" "1" "$ec"
check "spec write: the skeleton is untouched" "1" "$(grep -c '^## Intent$' "$DOCS7/SPEC.md")"
# Escalation is a gate's decision from evidence, never the lead's (port audit 5, R3).
ec=0; (cd "$REPO7" && drv spec escalate --feature-dir "$FD7" --reason "needs a fourth file" >/dev/null 2>&1) || ec=$?
check "spec escalate: not the lead's call" "2" "$ec"
check "spec escalate: nothing was written" "0" "$(grep -c '^route: full$' "$DOCS7/SPEC.md")"
cp "$WORK/spec7.bak" "$DOCS7/SPEC.md"
printf '# edited by the lead\n' >> "$DOCS7/SPEC.md"
out="$(cd "$REPO7" && drv spec skeleton --feature-dir "$FD7" 2>/dev/null)"
check "spec skeleton: an existing SPEC.md is kept" "1" "$(grep -c '^# edited by the lead$' "$DOCS7/SPEC.md")"
printf -- '---\nfootprint: [slugify.py]\n---\n# from a draft\n' > "$WORK/draft.md"
# On the full route (no skeleton) the draft is the lead's whole spec.
rm -f "$DOCS7/SPEC.md"
out="$(cd "$WORK" && drv spec write --feature-dir "$FD7" --file "$WORK/draft.md" 2>/dev/null)"
check "spec write: the draft lands at the one target" "$DOCS7/SPEC.md" "$out"
check "spec write: the content is the draft's" "# from a draft" "$(sed -n 4p "$DOCS7/SPEC.md")"
ec=0; (cd "$REPO7" && drv spec write --feature-dir "$FD7" --to "$WORK/elsewhere.md" >/dev/null 2>&1) || ec=$?
check "spec write: any other target is a bad invocation" "2" "$ec"
cat > "$DOCS7/SPEC.md" <<'MD'
---
unresolved_questions: []
footprint:
  - slugify.py
---
# fix slugify dots

<!-- intent: frozen. The ask as SPEC understood it. -->
## Intent

Dots survive slugify.
<!-- /intent -->

## Implementation notes

- slugify.py: strip dots in slugify().

## Success criteria

### Good Enough

- [ ] `python3 -c "from slugify import slugify; assert slugify('a.b') == 'ab'"` exits 0
- [ ] `python3 -m unittest discover -s tests -v 2>&1 | grep -c ' ok$'` prints 1

## Grounding

- none
MD
# The frontmatter map the driver would have written: what `verification run` executes.
python3 - "$DOCS7/SPEC.md" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("footprint:\n  - slugify.py\n---", "footprint:\n  - slugify.py\ncriteria:\n  GE-001: \"python3 -c \\\"from slugify import slugify; assert slugify('a.b') == 'ab'\\\"\"\n  GE-002: \"python3 -m unittest discover -s tests -v 2>&1 | grep -c ' ok$'\"\n---", 1)
open(p, "w").write(s)
PY
out="$(cd "$REPO7" && AUTONOMOUS=1 SESSION=s7 drv next --feature-dir "$FD7" 2>/dev/null)"
check "next: the oneshot candidate enters SPEC first" "NEXT phase=spec" "${out:0:15}"
out="$(cd "$REPO7" && AUTONOMOUS=1 SESSION=s7 drv next --feature-dir "$FD7" --returned-from spec --note "oneshot spec" 2>/dev/null)"
check "next: a oneshot spec enters ONESHOT in the same session (graph sameSession edge)" "NEXT phase=oneshot" "${out:0:18}"
check "next: no handoff is recorded across the same-session edge" "null" "$(jq -r '.handoffSession' "$FD7/feature.json")"
check "next: driverNext names oneshot" "oneshot" "$(jq -r '.driverNext.phase' "$FD7/feature.json")"
check "next: SPEC closed before ONESHOT opened" "spec" "$(jq -r '.completedPhases[-1]' "$FD7/feature.json")"
ec=0; out="$(cd "$REPO7" && AUTONOMOUS=1 SESSION=s7 drv phase-begin oneshot --feature-dir "$FD7" 2>/dev/null)" || ec=$?
check "phase-begin oneshot: the same session opens the phase (no exit 4)" "0" "$([[ "$ec" -eq 4 ]] && echo 4 || echo 0)"
# The node's ingress lists VERIFICATION.md as a skeleton: written once, from the
# template, one grounding row and one acceptance row per Good Enough criterion.
check "phase-begin oneshot: the VERIFICATION.md skeleton is written" "$DOCS7/VERIFICATION.md" "$(jq -r '.skeletons[0]' <<<"$out")"
check "phase-begin oneshot: the skeleton's title is the feature's" "# fix slugify dots - Verification" "$(head -1 "$DOCS7/VERIFICATION.md")"
check "phase-begin oneshot: no Plan line without a PLAN.md" "0" "$(grep -c '^\*\*Plan:\*\*' "$DOCS7/VERIFICATION.md")"
check "phase-begin oneshot: one grounding row per criterion" "1" "$(grep -c '^- criterion: GE-001 |' "$DOCS7/VERIFICATION.md")"
check "phase-begin oneshot: the acceptance row carries the criterion text and no status" "1" "$(grep -c "^| GE-001 | .*slugify('a.b') == 'ab'.* |  | " "$DOCS7/VERIFICATION.md")"
check "phase-begin oneshot: the second criterion gets its own rows" "2" "$(grep -c '^- criterion: GE-00[12] |' "$DOCS7/VERIFICATION.md")"
# A criterion that is a shell pipeline: the bare pipe would split the row and the
# floor would read the wrong cell (live run 3 paid a REDO and ten edits for it).
check "phase-begin oneshot: a pipe in the criterion is escaped in the table row" "1" "$(grep -c '^| GE-002 | `python3 -m unittest discover -s tests -v 2>&1 \\| grep -c .* |  | ' "$DOCS7/VERIFICATION.md")"
check "phase-begin oneshot: an empty status cell is a flag until the driver runs the criterion" "2" "$(bash "$REPO_ROOT/lib/artifact-lint.sh" verification "$DOCS7/VERIFICATION.md" 2>&1 | grep -c 'empty Status cell')"
# The oneshot skeleton is the sections the gates read and nothing more (port audit 3, N1).
check "phase-begin oneshot: the skeleton carries no section the gates do not read" "0" "$(grep -c '^## Security review summary\|^## Branch state\|^#### Performance' "$DOCS7/VERIFICATION.md")"
check "phase-begin oneshot: the skeleton is under 50 lines" "1" "$(( $(wc -l < "$DOCS7/VERIFICATION.md") < 50 ))"
# verification fill: one criterion per call, the review, the tests; each answer carries
# the four exit lints' flags over the file as it stands.
# The lead fills what it knows (grounding rows, the review); the driver observes the
# rest: `verification run` executes each criterion's command and writes the status from
# its exit, the evidence, and the output, then commands.test (port audit 4, items 2 and 4).
out="$(cd "$REPO7" && drv verification fill --feature-dir "$FD7" --row GE-001 --implementation slugify.py:2 --proof "replace strips dots" 2>/dev/null)"
check "verification fill: the grounding row is filled with integration none by default" "1" "$(grep -c '^- criterion: GE-001 | implementation: slugify.py:2 - replace strips dots | integration: none - ' "$DOCS7/VERIFICATION.md")"
check "verification fill: GE-002's placeholder row is still a flag" "1" "$(jq -r '.flags[]' <<<"$out" | grep -c 'implementation must be')"
mkdir -p "$REPO7/tests"; printf 'from slugify import slugify\n' > "$REPO7/tests/test_slugify.py"
out="$(cd "$REPO7" && drv verification fill --feature-dir "$FD7" --row GE-002 --implementation slugify.py:2 --proof "the same line" --integration tests/test_slugify.py:1 --integration-proof "the suite imports it" 2>/dev/null)"
check "verification fill: an integration ref is written as given" "1" "$(grep -c '| integration: tests/test_slugify.py:1 - the suite imports it$' "$DOCS7/VERIFICATION.md")"
ec=0; (cd "$REPO7" && drv verification fill --feature-dir "$FD7" --row GE-001 --evidence "PASS" >/dev/null 2>&1) || ec=$?
check "verification fill: the lead cannot supply evidence or a status" "2" "$ec"
# GE-001's command passes against the fixed slugify.py; GE-002's (a unittest run with no
# tests dir on the path) fails: the driver records what happened, not what was hoped.
printf 'def slugify(s):\n    return s.lower().replace(".", "")\n' > "$REPO7/slugify.py"
ec=0; out="$(cd "$REPO7" && drv verification run --feature-dir "$FD7" 2>/dev/null)" || ec=$?
check "verification run: a passing command is PASS from its exit" "1" "$(grep -c '^| GE-001 | .* | PASS | `python3 -c .* -> exit 0 |$' "$DOCS7/VERIFICATION.md")"
check "verification run: a failing command is FAIL from its exit" "1" "$(grep -c '^| GE-002 | .* | FAIL | `python3 -m unittest .* -> exit [1-9][0-9]* |$' "$DOCS7/VERIFICATION.md")"
check "verification run: a failing row is exit 1" "1" "$ec"
check "verification run: the answer lists each row's exit" "PASS FAIL" "$(jq -r '[.ran[] | select(.row | startswith("GE")) | .status] | join(" ")' <<<"$out")"
check "verification run: the output block is the command's output" "1" "$(grep -c '^(no output, exit 0)$' "$DOCS7/VERIFICATION.md")"
check "verification run: the floor refuses convergence on the FAIL row" "1" "$(jq -r '.flags[]' <<<"$out" | grep -c '^FLOOR GE-002')"
check "verification run: no commands.test means the block says so" "1" "$(grep -c '^(no commands.test is configured for this feature)$' "$DOCS7/VERIFICATION.md")"
# A criterion the spec gained after the skeleton, and one with no command: the driver
# owns the shape, so the row and the block are added, and the bare one is a FAIL row.
python3 - "$DOCS7/SPEC.md" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("\n## Grounding", "- [ ] all tests pass\n\n## Grounding", 1)
open(p, "w").write(s)
PY
ec=0; out="$(cd "$REPO7" && drv verification run --feature-dir "$FD7" 2>/dev/null)" || ec=$?
check "verification run: a criterion with no command on record is a FAIL row that says so" "1" "$(grep -c '^| GE-003 | all tests pass | FAIL | no command on record' "$DOCS7/VERIFICATION.md")"
check "verification run: the block for the added criterion exists" "1" "$(grep -c '^### Criterion 3$' "$DOCS7/VERIFICATION.md")"
check "verification run: the earlier rows were still written" "1" "$(grep -c '^| GE-001 | .* | PASS | ' "$DOCS7/VERIFICATION.md")"
python3 - "$DOCS7/SPEC.md" "$DOCS7/VERIFICATION.md" <<'PY'
import re, sys
for p in sys.argv[1:]:
    s = open(p).read()
    s = s.replace("- [ ] all tests pass\n\n", "", 1)
    s = re.sub(r"^\| GE-003 \|.*\n", "", s, flags=re.M)
    s = re.sub(r"\n### Criterion 3\n+```\n.*?\n```\n", "\n", s, flags=re.S)
    open(p, "w").write(s)
PY
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD7" commands.test '"python3 -c \"print(\\\"2 passed\\\")\""' >/dev/null
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD7" protected '[]' >/dev/null
# Fix the failing criterion's command in the spec and run again: the row turns PASS.
(cd "$REPO7" && drv spec fill --feature-dir "$FD7" --command 'python3 -c "print(1)" | grep -c 1' --expect "prints 1" --row GE-002 >/dev/null 2>&1)
check "the fixture's second criterion now runs a passing pipeline, replaced by row" "1" "$(grep -c 'print(1)" | grep -c 1` exits 0: prints 1' "$DOCS7/SPEC.md")"
check "and the frontmatter map carries the new command" "1" "$(sed -n '1,/^---$/!d; /^  GE-002: .*print(1)/p' "$DOCS7/SPEC.md" | grep -c .)"
ec=0; out="$(cd "$REPO7" && drv verification run --feature-dir "$FD7" 2>/dev/null)" || ec=$?
check "verification run: every row passing is exit 0" "0" "$ec"
check "verification run: the acceptance row follows the revised spec criterion" "1" "$(grep -c '^| GE-002 | `python3 -c "print(1)" \\| grep -c 1` exits 0: prints 1 | PASS |' "$DOCS7/VERIFICATION.md")"
check "verification run: the test suite block is the command's output with its exit" "1" "$(grep -c '^2 passed$' "$DOCS7/VERIFICATION.md")"
# The Code review section comes from the reviewer's report, never the lead's hand
# (port audit 4, item 3): findings become pending bullets the lead answers; none is none.
mkdir -p "$FD7/dispatch"
printf 'Verdict: PASS_WITH_MINOR\n\n- slugify.py:2 — replace runs before lower(), order is fine but undocumented\n- tests/test_slugify.py:1 — the suite has no dotted case.\n' > "$FD7/dispatch/oneshot.review.md"
out="$(cd "$REPO7" && drv verification review --feature-dir "$FD7" --reviewer-model haiku 2>/dev/null)"
check "verification review: the reviewer's verdict lands on the Reviewer line" "1" "$(grep -c '^\*\*Reviewer:\*\* code-reviewer (haiku): PASS_WITH_MINOR$' "$DOCS7/VERIFICATION.md")"
check "verification review: one pending bullet per finding" "2" "$(grep -c '| verdict: pending$' "$DOCS7/VERIFICATION.md")"
check "verification review: a pending finding is a flag until answered" "1" "$(jq -r '.flags[]' <<<"$out" | grep -c 'verdict' | awk '{print ($1 > 0)}')"
ec=0; (cd "$REPO7" && drv verification verdict --feature-dir "$FD7" --finding slugify.py:2 --verdict maybe --reason x >/dev/null 2>&1) || ec=$?
check "verification verdict: true or false only" "2" "$ec"
out="$(cd "$REPO7" && drv verification verdict --feature-dir "$FD7" --finding slugify.py:2 --verdict false --reason "lower() never adds a dot, so the order cannot change the result" 2>/dev/null)"
out="$(cd "$REPO7" && drv verification verdict --feature-dir "$FD7" --finding tests/test_slugify.py:1 --verdict true --reason "added the dotted case in the fix commit" --routing '{"route":"patch","cause":"missing dotted case","surface":"none","fixCommit":"1a2b3c4"}' 2>/dev/null)"
check "verification verdict: the answers replace pending" "0" "$(grep -c '| verdict: pending$' "$DOCS7/VERIFICATION.md")"
check "verification verdict: a false carries its disproof" "1" "$(grep -c '^- slugify.py:2 — .* | verdict: false — lower() never adds a dot' "$DOCS7/VERIFICATION.md")"
ec=0; (cd "$REPO7" && drv verification verdict --feature-dir "$FD7" --finding nope.py:9 --verdict true --reason x --routing '{"route":"defer","cause":"unknown","reason":"separate cleanup"}' >/dev/null 2>&1) || ec=$?
check "verification verdict: an unknown finding is refused" "1" "$ec"
printf 'Verdict: PASS\nNo findings.\n' > "$FD7/dispatch/oneshot.review.md"
out="$(cd "$REPO7" && drv verification review --feature-dir "$FD7" --reviewer-model haiku 2>/dev/null)"
check "verification review: a report with no finding renders none" "1" "$(sed -n '/^### Findings$/,/^## /p' "$DOCS7/VERIFICATION.md" | grep -c '^none$')"
check "verification review: none passes the triage lint" "0" "$(jq -r '.flags[]' <<<"$out" | grep -c 'review-triage\|verdict')"
check "verification fill: the reviewer model lands" "1" "$(grep -c '^\*\*Reviewer:\*\* code-reviewer (haiku)' "$DOCS7/VERIFICATION.md")"
rm -f "$FD7/dispatch/oneshot.review.md"
check "verification: the observed and filled skeleton has no flag from the four exit lints" "[]" "$(jq -c '.flags' <<<"$out")"
ec=0; (cd "$REPO7" && drv verification fill --feature-dir "$FD7" --row GE-009 --implementation a:1 --proof x >/dev/null 2>&1) || ec=$?
check "verification fill: a row the skeleton does not hold is refused" "1" "$ec"
check "verification: no placeholder is left" "0" "$(grep -c '{' "$DOCS7/VERIFICATION.md")"
printf '# filled by the lead\n' > "$DOCS7/VERIFICATION.md"
out="$(cd "$REPO7" && AUTONOMOUS=1 SESSION=s7 drv phase-begin oneshot --feature-dir "$FD7" 2>/dev/null)"
check "phase-begin oneshot: an existing VERIFICATION.md is kept" "null" "$(jq -r '.skeletons' <<<"$out")"
check "phase-begin oneshot: kept means untouched" "# filled by the lead" "$(head -1 "$DOCS7/VERIFICATION.md")"
rm -f "$DOCS7/VERIFICATION.md"; (cd "$REPO7" && AUTONOMOUS=1 SESSION=s7 drv phase-begin oneshot --feature-dir "$FD7" >/dev/null 2>&1)
# The one review pass is the driver's launch under the session layer, and the dispatch
# event the exit gate reads is driver-observed; attended, the lead dispatches in-harness.
out="$(cd "$REPO7" && drv oneshot review --feature-dir "$FD7" 2>/dev/null)"
check "oneshot review: attended is in-harness" "in-harness" "$(jq -r '.action' <<<"$out")"
SBIN7="$WORK/sbin7"; SPROF7="$WORK/sprof7"; mkdir -p "$SBIN7" "$SPROF7"
# The stub reviewer writes its report when asked to; a reviewer that completes with
# no report, or fails, leaves no dispatch event (port audit 3, N5).
printf '#!/usr/bin/env bash\nif [[ -n "${STUB_REPORT:-}" ]]; then echo "verdict: PASS" > "$STUB_REPORT"; fi\n[[ "${STUB_FAIL:-0}" == "1" ]] && { echo "Error: the stub refused" >&2; exit 1; }\necho "{\"ok\":true}"\n' > "$SBIN7/codex"; chmod +x "$SBIN7/codex"
printf 'name = "codex"\nbinary = "codex"\nlaunch_args = ["exec"]\nguarded_args = []\nbypass_args = []\nmodel_flag = "--model"\nprompt_template = "{prompt}"\n' > "$SPROF7/codex.toml"
printf 'def slugify(s):\n    return s.lower().replace(".", "")\n' > "$REPO7/slugify.py"; git -C "$REPO7" -c commit.gpgsign=false commit -qam "fix: strip dots"
out="$(cd "$REPO7" && PATH="$SBIN7:$PATH" LOOP_SPEC_SESSION_LAYER=1 LOOP_SPEC_SESSION_PROFILES="$SPROF7" drv oneshot review --feature-dir "$FD7" 2>/dev/null)"
check "oneshot review: a reviewer that completes without its report leaves no dispatch event" "0" "$(jq -c 'select(.event == "dispatch" and .data.launchedBy == "driver")' "$FD7/events.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
check "oneshot review: the withheld event is named in the answer" "1" "$(jq -r '.dispatchEvent // ""' <<<"$out" | grep -c '^withheld')"
out="$(cd "$REPO7" && PATH="$SBIN7:$PATH" STUB_FAIL=1 STUB_REPORT="$FD7/dispatch/oneshot.review.md" LOOP_SPEC_SESSION_LAYER=1 LOOP_SPEC_SESSION_PROFILES="$SPROF7" drv oneshot review --feature-dir "$FD7" 2>/dev/null)"
check "oneshot review: a failed reviewer session leaves no dispatch event even with a report" "0" "$(jq -c 'select(.event == "dispatch" and .data.launchedBy == "driver")' "$FD7/events.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
# The session leaves a durable log next to the report, and the answer quotes stderr's
# last line, so a failed reviewer is readable after the run ends (port audit 5, R6).
check "oneshot review: the session log is kept next to the report" "1" "$([[ -s "$FD7/dispatch/oneshot.reviewer.log" ]] && echo 1 || echo 0)"
check "oneshot review: the log records the session's status" "1" "$(grep -c '^=== .* stderr (failed)' "$FD7/dispatch/oneshot.reviewer.log")"
# At the boundary a failed session is handed to the lead once, in-harness; the driver
# does not relaunch it on the next return (port4-haiku-2 escalated out of that loop).
rm -f "$FD7/dispatch/oneshot.review.md"
out="$(cd "$REPO7" && AUTONOMOUS=1 SESSION=s7 PATH="$SBIN7:$PATH" STUB_FAIL=1 LOOP_SPEC_SESSION_LAYER=1 LOOP_SPEC_SESSION_PROFILES="$SPROF7" drv next --feature-dir "$FD7" --returned-from oneshot 2>/dev/null)"
check "next from oneshot: a failed reviewer session is one REDO naming the in-harness dispatch" "1" "$(grep -c 'the driver will not relaunch it: dispatch loop-spec:code-reviewer in-harness once' <<<"$out")"
check "next from oneshot: the REDO quotes stderr's last line and names the log" "1" "$(grep -c 'ended failed (Error: the stub refused; log .*oneshot.reviewer.log)' <<<"$out")"
check "next from oneshot: the failure is on record" "1" "$(jq -c 'select(.event == "review-session-failed")' "$FD7/events.jsonl" | wc -l | tr -d ' ')"
out="$(cd "$REPO7" && AUTONOMOUS=1 SESSION=s7 PATH="$SBIN7:$PATH" STUB_FAIL=1 LOOP_SPEC_SESSION_LAYER=1 LOOP_SPEC_SESSION_PROFILES="$SPROF7" drv next --feature-dir "$FD7" --returned-from oneshot 2>/dev/null)"
check "next from oneshot again: no relaunch; the gate names the missing dispatch" "1" "$(grep -c 'no code-reviewer dispatch recorded' <<<"$out")"
check "next from oneshot again: one failure on record, not two" "1" "$(jq -c 'select(.event == "review-session-failed")' "$FD7/events.jsonl" | wc -l | tr -d ' ')"
python3 - "$FD7/events.jsonl" <<'PY'
import sys
p = sys.argv[1]; lines = [l for l in open(p) if '"review-session-failed"' not in l]
open(p, "w").writelines(lines)
PY
rm -f "$FD7/dispatch/oneshot.review.md"
out="$(cd "$REPO7" && PATH="$SBIN7:$PATH" STUB_REPORT="$FD7/dispatch/oneshot.review.md" LOOP_SPEC_SESSION_LAYER=1 LOOP_SPEC_SESSION_PROFILES="$SPROF7" drv oneshot review --feature-dir "$FD7" 2>/dev/null)"
check "oneshot review: the reviewer ran as a session" "completed" "$(jq -r '.status' <<<"$out")"
check "oneshot review: the prompt is one line naming the package, the spec, and the report" "1" "$(grep -c '^Review the package in .* against the spec .*SPEC.md. Write your verdict .* to .*oneshot.review.md.$' "$FD7/dispatch/oneshot.reviewer.md")"
check "oneshot review: the package holds the diff since baseSha" "1" "$(grep -c 'replace' "$(jq -r '.package' <<<"$out")")"
check "oneshot review: the dispatch event is driver-observed" "1" "$(jq -c 'select(.event == "dispatch" and .phase == "oneshot" and .data.launchedBy == "driver")' "$FD7/events.jsonl" | wc -l | tr -d ' ')"
check "oneshot review: the exit gate's review check is satisfied by it" "0" "$(bash "$REPO_ROOT/lib/oneshot-exit-gate.sh" "$FD7" 2>&1 | grep -c '\[review\]')"
# At the boundary the driver runs the review itself when none is on record: one REDO
# carrying the report path, and the second return goes on to the exit gate.
: > "$FD7/events.jsonl"; rm -f "$FD7/dispatch/oneshot.review.md"
out="$(cd "$REPO7" && AUTONOMOUS=1 SESSION=s7 PATH="$SBIN7:$PATH" STUB_REPORT="$FD7/dispatch/oneshot.review.md" LOOP_SPEC_SESSION_LAYER=1 LOOP_SPEC_SESSION_PROFILES="$SPROF7" drv next --feature-dir "$FD7" --returned-from oneshot 2>/dev/null)"
check "next from oneshot: the driver runs the review pass and answers one REDO" "REDO phase=oneshot flags=1" "$(head -1 <<<"$out")"
check "next from oneshot: the FLAG hands the lead the report path" "1" "$(grep -c '^FLAG \[review\] the driver ran the one review pass; its verdict and findings are in .*oneshot.review.md' <<<"$out")"
check "boundary review: full FLAG is retained in redo telemetry" "$(printf '%s\n' "$out" | grep '^FLAG ')" "$(jq -r 'select(.event == "redo") | .data.messages[]?' "$FD7/events.jsonl" | tail -1)"
check "next from oneshot: the Code review section was written from the report (none)" "1" "$(grep -c 'the Code review section holds none' <<<"$out")"
check "next from oneshot: the dispatch event is driver-observed" "1" "$(jq -c 'select(.event == "dispatch" and .data.launchedBy == "driver")' "$FD7/events.jsonl" | wc -l | tr -d ' ')"
out="$(cd "$REPO7" && AUTONOMOUS=1 SESSION=s7 PATH="$SBIN7:$PATH" STUB_REPORT="$FD7/dispatch/oneshot.review.md" LOOP_SPEC_SESSION_LAYER=1 LOOP_SPEC_SESSION_PROFILES="$SPROF7" drv next --feature-dir "$FD7" --returned-from oneshot 2>/dev/null)"
check "next from oneshot again: no second review; the exit gate answers" "0" "$(grep -c 'the driver ran the one review pass' <<<"$out")"
check "next from oneshot again: one dispatch event, not two" "1" "$(jq -c 'select(.event == "dispatch" and .data.launchedBy == "driver")' "$FD7/events.jsonl" | wc -l | tr -d ' ')"
out="$(cd "$REPO7" && AUTONOMOUS=1 SESSION=s7 drv next --feature-dir "$FD7" --returned-from oneshot 2>/dev/null)"
check "next from oneshot in-harness: the driver launches nothing and the gate names the missing dispatch" "0" "$(grep -c 'the driver ran the one review pass' <<<"$out")"
# The third identical REDO is the gate's escalation (port audit 5, R3): route: full with
# the flag classes on record, and the run continues on the full path from DISCUSS.
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD7" driverRedo 'null' >/dev/null
out1="$(cd "$REPO7" && AUTONOMOUS=1 SESSION=s7 drv next --feature-dir "$FD7" --returned-from oneshot 2>/dev/null)"
out2="$(cd "$REPO7" && AUTONOMOUS=1 SESSION=s7 drv next --feature-dir "$FD7" --returned-from oneshot 2>/dev/null)"
out3="$(cd "$REPO7" && AUTONOMOUS=1 SESSION=s7 drv next --feature-dir "$FD7" --returned-from oneshot 2>"$WORK/out3.err")"
check "next from oneshot: the first two identical gates are REDOs" "REDO REDO" "$(printf '%s %s' "$(head -1 <<<"$out1" | cut -d' ' -f1)" "$(head -1 <<<"$out2" | cut -d' ' -f1)")"
# The note rides stderr: the cycle skill acts on the FIRST stdout line, and a NOTE there
# hid the protocol line (PR 100 audit, finding 1).
check "next from oneshot: the third identical gate escalates the route, never the lead (note on stderr)" "1" "$(grep -c '^NOTE \[escalate\] the oneshot exit gate held after 3 attempts' "$WORK/out3.err")"
check "next from oneshot: no NOTE line on stdout" "0" "$(grep -c '^NOTE ' <<<"$out3")"
check "next from oneshot: route: full is on the spec with the deadlock's classes" "1" "$(grep -c '^- escalated (route: full): the exit gate held after 3 attempts on ' "$DOCS7/SPEC.md")"
check "next from oneshot: the escalation is an event with its classes" "1" "$(jq -c 'select(.event == "escalate" and .phase == "oneshot" and (.data.classes | length) > 0)' "$FD7/events.jsonl" | wc -l | tr -d ' ')"
check "next from oneshot: the attempt's verification record is set aside" "1" "$([[ -f "$DOCS7/VERIFICATION.oneshot-attempt.md" ]] && echo 1 || echo 0)"
check "next from oneshot: the run continues to DISCUSS in a fresh session" "HANDOFF next=discuss" "$(grep -o '^HANDOFF next=discuss' <<<"$out3")"
[[ -n "$(grep -o '^HANDOFF next=discuss' <<<"$out3")" ]] || printf '%s\n' "$out3" | head -5 | sed 's/^/  out3: /'
ec=0; (cd "$REPO7" && drv spec write --feature-dir "$FD7" --file "$WORK/draft7.md" >/dev/null 2>&1) || ec=$?
check "spec write: allowed over an escalated spec (the full shape is the lead's)" "0" "$ec"

# --- the rewind rule: a next phase the graph lists earlier answers REWIND -------------
# The port made every earlier phase a rewind (iterate to verify prints REWIND where it
# did not before); the record of that protocol change is this pin, through the driver's
# own replay of a recorded handoff.
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD6" handoffSession '{"id":"s9","from":"iterate","next":"verify","at":"2026-09-09T00:00:00Z"}' >/dev/null
out="$(cd "$REPO6" && AUTONOMOUS=1 SESSION=s9 drv next --feature-dir "$FD6" 2>/dev/null)"
check "next: iterate to verify is a REWIND (verify precedes iterate on the graph)" "REWIND next=verify" "$out"
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD6" handoffSession '{"id":"s9","from":"verify","next":"iterate","at":"2026-09-09T00:00:00Z"}' >/dev/null
out="$(cd "$REPO6" && AUTONOMOUS=1 SESSION=s9 drv next --feature-dir "$FD6" 2>/dev/null)"
check "next: verify to iterate is a HANDOFF (forward on the graph)" "HANDOFF next=iterate" "${out:0:20}"
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD6" handoffSession null >/dev/null

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
check "next: the redo event retains the exact gate messages" "$(grep '^FLAG' <<<"$out")" \
  "$(jq -r 'select(.event == "redo") | .data.messages[]' "$FD6/events.jsonl")"
out="$(cd "$REPO6" && AUTONOMOUS=1 drv next --feature-dir "$FD6" --returned-from spec 2>/dev/null)"
check "next: the same flags again count the attempt" "REDO phase=spec flags=" "${out:0:22}"
check "next: attempt two is reported" "1" "$(head -1 <<<"$out" | grep -c 'attempt=2')"
out="$(cd "$REPO6" && AUTONOMOUS=1 drv next --feature-dir "$FD6" --returned-from spec 2>/dev/null)"
check "next: the third identical REDO escalates" "DONE status=escalated" "${out:0:21}"
check "next: the escalation names the gate" "1" "$(head -1 <<<"$out" | grep -c 'spec exit gate unsatisfied')"
check "next: an escalated result is published" "escalated" "$(jq -r '.status' "$FD6/result.json")"
rm -f "$FD6/result.json"; bash "$REPO_ROOT/lib/feature-write.sh" set "$FD6" driverRedo null >/dev/null
DOCS6="$REPO6/docs/loop-spec/features/$(jq -r '.slug' "$FD6/feature.json")"; mkdir -p "$DOCS6"
cp "$REPO_ROOT/tests/fixtures/minimal-SPEC.md" "$DOCS6/SPEC.md"
out="$(cd "$REPO6" && AUTONOMOUS=1 drv next --feature-dir "$FD6" --returned-from spec 2>/dev/null)"
check "next: a clean exit hands the successor to a fresh session" "HANDOFF next=discuss model=" "${out:0:27}"
check "next: the handoff wrote the paused result" "phase-handoff" "$(jq -r '.reason' "$FD6/result.json")"
out="$(cd "$REPO6" && AUTONOMOUS=1 drv next --feature-dir "$FD6" 2>/dev/null)"
check "next: the fresh session enters the handed phase" "NEXT phase=discuss" "${out:0:18}"
# From the record, never a second graph step: one phase_start for DISCUSS, the handoff
# record consumed (the full-route runs entered DISCUSS and PLAN twice; port audit 5, R5).
check "next: the fresh session's entry adds no second phase_start" "1" "$(jq -c 'select(.event == "phase_start" and .phase == "discuss")' "$FD6/events.jsonl" | wc -l | tr -d ' ')"
check "next: the handoff record is consumed by the entry" "null" "$(jq -r '.handoffSession' "$FD6/feature.json")"
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

# --- live-run findings (tf-meldn, 2026-09-07) -------------------------------------------
# The inline `autonomous` token honors LOOP_SPEC_ANSWER_TITLE (only the env var did).
REPO7="$(new_repo answers)"
out="$(AUTONOMOUS=1 LOOP_SPEC_ANSWER_TITLE="Short title" drv start --dir "$REPO7" -- a very long prose description that would slug badly 2>/dev/null)"
check "start: autonomous honors LOOP_SPEC_ANSWER_TITLE" "short-title" "$(jq -r '.invocation.slug' <<<"$out")"
check "start: autonomous keeps style auto under an env answer" "auto" "$(LOOP_SPEC_ANSWER_STYLE=step AUTONOMOUS=1 LOOP_SPEC_ANSWER_TITLE=t drv start --dir "$REPO7" -- x 2>/dev/null | jq -r '.invocation.style')"
# The headless warning is dropped when the invocation carries the token.
out="$(CLAUDE_CODE_ENTRYPOINT=sdk-cli LOOP_SPEC_HARNESS=codex LOOP_SPEC_TEAMS_MODE=none LOOP_SPEC_WORKFLOWS_AVAILABLE=0 LOOP_SPEC_CHECKPOINT_PR=0 bash "$SCRIPT" start --dir "$REPO7" -- autonomous ship it 2>/dev/null)"
check "start: no headless warning with the autonomous token" "0" "$(jq -r '[.warnings[] | select(startswith("headless invocation"))] | length' <<<"$out")"
out="$(CLAUDE_CODE_ENTRYPOINT=sdk-cli LOOP_SPEC_HARNESS=codex LOOP_SPEC_TEAMS_MODE=none LOOP_SPEC_WORKFLOWS_AVAILABLE=0 LOOP_SPEC_CHECKPOINT_PR=0 bash "$SCRIPT" start --dir "$REPO7" -- ship it 2>/dev/null)"
check "start: headless warning kept without the token" "1" "$(jq -r '[.warnings[] | select(startswith("headless invocation"))] | length' <<<"$out")"

# An interrupted round leaves plugin-owned files dirty; begin must resume, not refuse.
REPO8="$(new_repo interrupted)"
AUTONOMOUS=1 drv start --dir "$REPO8" -- add a json flag >/dev/null 2>&1
init="$(drv init --dir "$REPO8" --slug add-a-json-flag --title "add a json flag" --style auto --profile standard --autonomous 1 2>/dev/null)"
FD8="$(jq -r '.featureDir' <<<"$init")"
mkdir -p "$REPO8/docs/loop-spec/features/add-a-json-flag" "$REPO8/.claude/agent-memory/loop-spec-pattern-mapper"
printf '# draft\n' > "$REPO8/docs/loop-spec/features/add-a-json-flag/PLAN.md"
printf 'memory\n' > "$REPO8/.claude/agent-memory/loop-spec-pattern-mapper/MEMORY.md"
printf '{"x":1}\n' > "$FD8/scratch.json"
out="$(cd "$REPO8" && AUTONOMOUS=1 drv begin -- a different sentence than before 2>/dev/null)"
check "begin: plugin-owned dirt does not refuse the resume" "resume" "$(jq -r '.action' <<<"$out")"
check "begin: autonomous auto-picks the single resumable feature" "add-a-json-flag" "$(jq -r '.slug' <<<"$out")"
printf 'wip\n' > "$REPO8/notes.txt"
ec=0; (cd "$REPO8" && AUTONOMOUS=1 drv init --dir "$REPO8" --slug other --title other --style auto --profile standard --autonomous 1 >/dev/null 2>&1) || ec=$?
check "init: user dirt still refuses" "1" "$ec"

# A gitfile checkout (submodule or linked worktree) works in place: EnterWorktree refuses it.
REPO9="$(new_repo gitfile)"
GITDIR9="$WORK/gitfile.git"; mv "$REPO9/.git" "$GITDIR9"; printf 'gitdir: %s\n' "$GITDIR9" > "$REPO9/.git"
HARNESS=claude AUTONOMOUS=1 drv start --dir "$REPO9" -- ship it >/dev/null 2>&1
init="$(HARNESS=claude drv init --dir "$REPO9" --slug ship-it --title "ship it" --style auto --profile standard --autonomous 1 2>/tmp/gitfile.err)"
check "init: gitfile checkout enters no worktree" "null" "$(jq -r '.enterWorktree' <<<"$init")"
check "init: gitfile checkout names the reason" "1" "$(grep -c 'working in place' /tmp/gitfile.err)"


echo
echo "cycle-driver: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
