#!/usr/bin/env bash
# Tests for lib/cycle-driver.sh, part 2 of 5: driverRedo clears on a gate pass,
# start/resume, finish/escalate, profile preset, raw-prompt stamp, dirty refusal,
# begin (start+init in one call), finish report/decline, plugin-home refusal. Split so
# tests/run-all.sh runs the five parts in parallel; the serial file set the wall clock.
. "$(dirname "$0")/cycle-driver.common.sh"

# rig: rebuilds REPO/FD/DOCS1 to the state cycle-driver-core.test.sh leaves them in
# (paused at human.after-spec after the empty-Goals REDO round-trip); the driverRedo
# section below drives that same feature on through DISCUSS, PLAN, handoff and rewind.
ec=0; bash "$SCRIPT" >/dev/null 2>&1 || ec=$?
ec=0; bash "$SCRIPT" next >/dev/null 2>&1 || ec=$?
REPO="$(new_repo r1)"
out="$(drv start --dir "$REPO" -- add a json flag 2>/dev/null)"
out="$(AUTONOMOUS=1 drv start --dir "$REPO" -- add a json flag 2>/dev/null)"
out="$(drv start --dir "$REPO" 2>/dev/null)"
ec=0; AUTONOMOUS=1 drv start --dir "$REPO" >/dev/null 2>&1 || ec=$?
ec=0; NON_INTERACTIVE=1 LOOP_SPEC_ANSWER_STYLE=bogus drv start --dir "$REPO" -- x >/dev/null 2>&1 || ec=$?
ec=0; LOOP_SPEC_MODEL_IMPLEMENTER=bogus drv start --dir "$REPO" -- x >/dev/null 2>&1 || ec=$?
printf '# Export JSON flag\n\nbody\n' > "$WORK/spec.md"
out="$(NON_INTERACTIVE=1 LOOP_SPEC_SPEC_FILE="$WORK/spec.md" drv start --dir "$REPO" 2>/dev/null)"
EMPTY="$WORK/empty"; mkdir -p "$EMPTY"
ec=0; drv start --dir "$EMPTY" -- x >/dev/null 2>&1 || ec=$?
out="$(drv start --dir "$EMPTY" -- x 2>/dev/null)"
out="$(drv start --dir "$EMPTY" -- new x 2>/dev/null)"
init="$(drv init --dir "$REPO" --slug add-a-json-flag --title "add a json flag" --style step \
  --profile standard --autonomous 0 --spec-file "$WORK/spec.md" 2>/dev/null)"
FD="$(jq -r '.featureDir' <<<"$init")"
ec=0; err="$(drv init --dir "$REPO" --slug again --title again --style auto --profile standard 2>&1 >/dev/null)" || ec=$?
out="$(cd "$REPO" && drv next --feature-dir "$FD" 2>/dev/null)"
write_spec "$REPO" "$FD"
out="$(cd "$REPO" && drv next --feature-dir "$FD" --returned-from spec --note "wrote SPEC" 2>/dev/null)"
ec=0; err="$(cd "$REPO" && drv phase-begin plan --feature-dir "$FD" 2>&1 >/dev/null)" || ec=$?
DOCS1="$REPO/docs/loop-spec/features/$(jq -r '.slug' "$FD/feature.json")"
cp "$DOCS1/SPEC.md" "$DOCS1/SPEC.md.keep"; sed -i.bak '/^## Goals$/,/^## Boundaries/{/^Produce/d;}' "$DOCS1/SPEC.md"; rm -f "$DOCS1/SPEC.md.bak"
ec=0; out="$(cd "$REPO" && drv next --feature-dir "$FD" --returned-from spec 2>/dev/null)" || ec=$?
mv "$DOCS1/SPEC.md.keep" "$DOCS1/SPEC.md"

# --- driverRedo clears on a gate pass (6.6.5 live run: a passed gate left the counter
# behind, so the next REDO on fresh damage inherited a stale count and escalated a full
# attempt early). Proving the clear needs a repeat return that actually PASSES, and on
# $FD that pass hands the phase straight past the human gate to discuss (it does not
# re-pause), which would move the boundary the checks just above this depend on. An
# isolated feature keeps that pass off $FD and still exercises the same driver path.
REPO_REDO="$(new_repo redo-probe)"
out="$(cd "$REPO_REDO" && AUTONOMOUS=1 drv begin -- "autonomous driverredo probe" 2>/dev/null)"
FD_REDO="$(jq -r '.featureDir' <<<"$out")"
(cd "$REPO_REDO" && drv next --feature-dir "$FD_REDO" >/dev/null 2>&1)
write_spec "$REPO_REDO" "$FD_REDO"
(cd "$REPO_REDO" && drv next --feature-dir "$FD_REDO" --returned-from spec --note "wrote SPEC" >/dev/null 2>&1)
DOCS_REDO="$REPO_REDO/docs/loop-spec/features/$(jq -r '.slug' "$FD_REDO/feature.json")"
cp "$DOCS_REDO/SPEC.md" "$DOCS_REDO/SPEC.md.keep"; sed -i.bak '/^## Goals$/,/^## Boundaries/{/^Produce/d;}' "$DOCS_REDO/SPEC.md"; rm -f "$DOCS_REDO/SPEC.md.bak"
out="$(cd "$REPO_REDO" && drv next --feature-dir "$FD_REDO" --returned-from spec 2>/dev/null)"
check "driverRedo: a broken-Goals REDO is attempt 1" "1" "$(head -1 <<<"$out" | grep -c 'attempt=1')"
mv "$DOCS_REDO/SPEC.md.keep" "$DOCS_REDO/SPEC.md"
out="$(cd "$REPO_REDO" && drv next --feature-dir "$FD_REDO" --returned-from spec 2>/dev/null)"
check "driverRedo: a passing repeat return zeroes the stale counter" "null" "$(jq -r '.driverRedo' "$FD_REDO/feature.json")"
cp "$DOCS_REDO/SPEC.md" "$DOCS_REDO/SPEC.md.keep"; sed -i.bak '/^## Goals$/,/^## Boundaries/{/^Produce/d;}' "$DOCS_REDO/SPEC.md"; rm -f "$DOCS_REDO/SPEC.md.bak"
out="$(cd "$REPO_REDO" && drv next --feature-dir "$FD_REDO" --returned-from spec 2>/dev/null)"
check "driverRedo: a fresh REDO after a pass starts at attempt 1, not a stale count" "1" "$(head -1 <<<"$out" | grep -c 'attempt=1')"
mv "$DOCS_REDO/SPEC.md.keep" "$DOCS_REDO/SPEC.md"

out="$(cd "$REPO" && drv next --feature-dir "$FD" 2>/dev/null)"
check "next: re-invoke after pause continues to discuss" 'NEXT phase=discuss label="Challenge and refine the specification" effort=system2' "$(head -1 <<<"$out")"
check "next: the resumed pause record is gone" "0" "$([[ -f "$FD/result.json" ]] && echo 1 || echo 0)"
check "next: the resumed pause pointer is gone" "0" "$([[ -f "$REPO/.loop-spec/last-result.json" ]] && echo 1 || echo 0)"

# DISCUSS may still rewrite Goal and Boundary (the run that froze them at SPEC exit died
# when the human answered DISCUSS's follow-ups); the human gate says so, PLAN freezes.
sed -i.bak 's/^Produce the requested behavior\.$/Produce the requested behavior and log it./' "$DOCS1/SPEC.md"; rm -f "$DOCS1/SPEC.md.bak"
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
# Past begin the work is reported through the cycle, never declined (port4-haiku-3
# declined with the fix committed). Pinned before finish, so the refusal is this begun
# feature and not the one a later init starts in the same checkout.
ec=0; out="$(cd "$REPO10" && drv decline --dir "$REPO10" --reason "a harness error, work is done" 2>&1 >/dev/null)" || ec=$?
check "decline: refused once a feature has begun in the checkout" "1" "$ec"
check "decline: the refusal names the feature and the way out" "1" "$(grep -c 'has begun (phase .*); a run past begin finishes through the cycle or escalates' <<<"$out")"
printf '{"status":"pushed-no-pr","nextPhase":"completed","targets":[{"name":"finish-report","targetSha":"0123456789abcdef0123","prUrl":null,"errorCode":null}],"feedback":null}\n' > "$FD10/delivery.json"
out="$(cd "$REPO10" && drv finish --feature-dir "$FD10" --completed 1 2>/dev/null)"
check "finish: the report opens with the outcome" "1" "$(jq -r '.report' <<<"$out" | head -1 | grep -c 'pushed to the remote')"
check "finish: one line per target with its SHA" "1" "$(jq -r '.report' <<<"$out" | grep -c '^- finish-report, sha 0123456789ab$')"
check "finish: the report ends with the backlog count" "1" "$(jq -r '.report' <<<"$out" | tail -1 | grep -c '^backlog entries remaining: [0-9]')"
# 6.6.7: finish makes the terminal transition durable, in feature.json and on the state
# ref, so a same-checkout chain after delivery does not read "deliver" forever.
check "finish: currentPhase advances to completed" "completed" "$(jq -r '.currentPhase' "$FD10/feature.json")"
SLUG10="$(jq -r '.slug' "$FD10/feature.json")"
check "finish: the state ref carries the same completed snapshot" "completed" "$(git -C "$REPO10" show "refs/loop-spec/state/$SLUG10:feature.json" | jq -r '.currentPhase')"
ec=0; drv init --dir "$REPO10" --slug next-one --title "next one" --style auto --profile standard --autonomous 1 >/dev/null 2>&1 || ec=$?
check "finish: a delivered feature never blocks the next init in the same checkout" "0" "$ec"
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

# --- exhausted design budget is a terminal driver decision ----------------------------
REPO_BUDGET="$(new_repo budget)"
AUTONOMOUS=1 out="$(cd "$REPO_BUDGET" && drv begin -- "autonomous budget guard" 2>/dev/null)"
FD_BUDGET="$(jq -r '.featureDir' <<<"$out")"
(cd "$REPO_BUDGET" && drv next --feature-dir "$FD_BUDGET" >/dev/null 2>&1)
write_spec "$REPO_BUDGET" "$FD_BUDGET"
jq -r '.slug' "$FD_BUDGET/feature.json" > "$FD_BUDGET/slug"
jq '.currentPhase = "spec" | .currentPhaseStartedAt = "2020-01-01T00:00:00Z" | .autonomousClassification = {estimatedFiles:0, criteriaCount:1}' \
  "$FD_BUDGET/feature.json" > "$FD_BUDGET/tmp" && mv "$FD_BUDGET/tmp" "$FD_BUDGET/feature.json"
printf '%s\n' '{"event":"phase_end","phase":"spec","attemptId":"budget","ts":"2020-01-02T00:00:00Z","elapsedSeconds":3600}' > "$FD_BUDGET/events.jsonl"
printf '# invalid\n' > "$REPO_BUDGET/docs/loop-spec/features/$(cat "$FD_BUDGET/slug")/SPEC.md"
ec=0; out="$(cd "$REPO_BUDGET" && drv next --feature-dir "$FD_BUDGET" --returned-from spec 2>/dev/null)" || ec=$?
check "budget exhaustion escalates a failing gate" "1" "$(grep -c '^DONE status=escalated' <<<"$out")"

REPO_BUDGET_PASS="$(new_repo budget-pass)"
AUTONOMOUS=1 out="$(cd "$REPO_BUDGET_PASS" && drv begin -- "autonomous budget pass" 2>/dev/null)"
FD_BUDGET_PASS="$(jq -r '.featureDir' <<<"$out")"
(cd "$REPO_BUDGET_PASS" && drv next --feature-dir "$FD_BUDGET_PASS" >/dev/null 2>&1)
write_spec "$REPO_BUDGET_PASS" "$FD_BUDGET_PASS"
jq '.currentPhase = "spec" | .currentPhaseStartedAt = "2020-01-01T00:00:00Z" | .autonomousClassification = {estimatedFiles:0, criteriaCount:1}' \
  "$FD_BUDGET_PASS/feature.json" > "$FD_BUDGET_PASS/tmp" && mv "$FD_BUDGET_PASS/tmp" "$FD_BUDGET_PASS/feature.json"
printf '%s\n' '{"event":"phase_end","phase":"spec","attemptId":"budget","ts":"2020-01-02T00:00:00Z","elapsedSeconds":3600}' > "$FD_BUDGET_PASS/events.jsonl"
ec=0; out="$(cd "$REPO_BUDGET_PASS" && drv next --feature-dir "$FD_BUDGET_PASS" --returned-from spec 2>/dev/null)" || ec=$?
check "budget exhaustion does not block a passing gate" "0" "$ec"
check "budget exhaustion allows a passing gate to advance" "1" "$(jq -r '.currentPhase' "$FD_BUDGET_PASS/feature.json" | grep -Ec '^(discuss|plan|execute|verify|iterate|deliver)$')"
check "budget exhaustion pass does not publish escalation" "0" "$(grep -c '^DONE status=escalated' <<<"$out")"
export LOOP_SPEC_DESIGN_BUDGET_MINS=bogus
budget_err="$WORK/budget-error"
ec=0; (cd "$REPO_BUDGET_PASS" && drv next --feature-dir "$FD_BUDGET_PASS" --returned-from spec >/dev/null 2>"$budget_err") || ec=$?
unset LOOP_SPEC_DESIGN_BUDGET_MINS
check "invalid design budget override is rejected" "2" "$ec"
check "invalid design budget override preserves diagnostic" "1" "$(grep -F -c 'design-budget: LOOP_SPEC_DESIGN_BUDGET_MINS must be an integer from 1 to 3600' "$budget_err")"
check "driver Die includes the probe diagnostic" "1" "$(grep -F -c 'design budget probe failed: design-budget: LOOP_SPEC_DESIGN_BUDGET_MINS must be an integer from 1 to 3600' "$budget_err")"

echo
echo "cycle-driver-redo: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
