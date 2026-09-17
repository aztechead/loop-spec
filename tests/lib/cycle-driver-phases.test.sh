#!/usr/bin/env bash
# Tests for lib/cycle-driver.sh, part 4 of 5: phase-begin, next runs the phase exit, claude worktree path,
# live-run findings, the plugin checkout moving mid-phase, a quoted escalation route. Split so
# tests/run-all.sh runs the five parts in parallel; the serial file set the wall clock.
. "$(dirname "$0")/cycle-driver.common.sh"

rig_repo6_begun

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
out="$(cd "$REPO6" && AUTONOMOUS=1 SESSION=phase-discuss-fresh drv next --feature-dir "$FD6" 2>/dev/null)"
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

# --- the plugin checkout moves while a phase runs -----------------------------------
# A development clone edited mid-phase (the Codex EXECUTE live run) is a NOTE, not an
# escalation, and the note rides stderr: skills/cycle/SKILL.md acts on the FIRST stdout
# line, and the note there hid the protocol line on this exact path (PR 100 audit). A
# copy of the plugin stands in for the moving clone so the tree under test stays put.
PLUGIN="$WORK/plugin"; mkdir -p "$PLUGIN"
tar -C "$REPO_ROOT" --exclude=.git --exclude=tests --exclude='__pycache__' -cf - . | tar -C "$PLUGIN" -xf -
REPO11="$(new_repo moving-plugin)"
(cd "$REPO11" && SCRIPT="$PLUGIN/lib/cycle-driver.sh" drv start --dir "$REPO11" -- move it >/dev/null 2>&1
  SCRIPT="$PLUGIN/lib/cycle-driver.sh" drv init --dir "$REPO11" --slug move-it --title "move it" --style step --profile standard --autonomous 0 >/dev/null 2>&1)
FD11="$REPO11/.loop-spec/features/move-it"
out="$(cd "$REPO11" && SCRIPT="$PLUGIN/lib/cycle-driver.sh" drv next --feature-dir "$FD11" 2>/dev/null)"
check "moving plugin: the copy renders the spec phase" "NEXT phase=spec" "$(head -1 <<<"$out" | cut -d' ' -f1,2)"
moved="$(jq -r '.driverNext.instructions.manifest' "$FD11/feature.json" | xargs -I{} jq -r '.sources | keys[0]' {})"
printf '\n<!-- moved mid-phase -->\n' >> "$PLUGIN/$moved"
write_spec "$REPO11" "$FD11"
out="$(cd "$REPO11" && SCRIPT="$PLUGIN/lib/cycle-driver.sh" drv next --feature-dir "$FD11" --returned-from spec 2>"$WORK/moving.err")"
check "moving plugin: the first stdout line is the protocol line" "PAUSED node=human.after-spec" "$(head -1 <<<"$out")"
check "moving plugin: no NOTE line on stdout" "0" "$(grep -c '^NOTE ' <<<"$out")"
check "moving plugin: the snapshot note names the moved source on stderr" "1" "$(grep -c "^NOTE \[snapshot\] plugin source changed since the phase was rendered: $moved;" "$WORK/moving.err")"
check "moving plugin: the note is on the feature's warnings" "1" "$(jq -r '.warnings[]' "$FD11/feature.json" | grep -c '^NOTE \[snapshot\]')"
check "moving plugin: no escalation" "0" "$(jq -c 'select(.event == "escalated")' "$FD11/events.jsonl" | wc -l | tr -d ' ')"

# --- a quoted route: "full" is the same escalation as an unquoted one -----------------
# The probe and the shape lint strip YAML quotes; the driver's unquoted match let the
# gate's escalation write a second route: full line under a quoted one.
printf -- '---\nroute: "full"\nfootprint:\n  - a.py\n---\n## Intent\n\n## Implementation notes\n' > "$WORK/quoted.md"
python3 - "$REPO_ROOT/lib/graph/driver.py" "$WORK/quoted.md" >/dev/null <<'PY_'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("driver", sys.argv[1]); d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
d.spec_escalate(sys.argv[2], "held")
PY_
check "spec escalate: a quoted route: \"full\" gets no second route line" "1" "$(sed -n '1,/^---$/!d; /^route:/p' "$WORK/quoted.md" | grep -c '^route:')"
check "spec escalate: the reason is still recorded under Implementation notes" "1" "$(grep -c '^- escalated (route: full): held$' "$WORK/quoted.md")"


echo
echo "cycle-driver-phases: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
