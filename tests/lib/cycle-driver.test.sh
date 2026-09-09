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
    -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID ${SESSION:+CLAUDE_CODE_SESSION_ID="$SESSION"} \
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
out="$(cd "$REPO" && SESSION=s1 drv next --feature-dir "$FD" --returned-from discuss 2>/dev/null)"
check "next: handoff answer names the successor" "HANDOFF next=" "${out:0:13}"
check "next: handoff writes a paused result" "phase-handoff" "$(jq -r '.reason' "$FD/result.json")"

# The session that handed off is done: the driver refuses to carry it into the next
# phase whatever tool it reaches for; a fresh session (another id) proceeds.
check "next: the handoff records the session" "s1" "$(jq -r '.handoffSession.id' "$FD/feature.json")"
out="$(cd "$REPO" && SESSION=s1 drv next --feature-dir "$FD" 2>/dev/null)"
check "next: the same session gets the handoff answer again" "HANDOFF next=plan" "${out:0:17}"
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
check "begin: the refusal puts the result pointer back" "phase-handoff" "$(jq -r '.reason' "$REPO/.loop-spec/last-result.json" 2>/dev/null)"

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
check "spec skeleton: the footprint is the record minus read-only" '["slugify.py"]' "$(jq -c '.footprint' <<<"$out")"
check "spec skeleton: the read-only files ride along" '["README.md"]' "$(jq -c '.readOnly' <<<"$out")"
check "spec skeleton: prints the path in the feature's checkout, not the cwd" "$DOCS7/SPEC.md" "$(jq -r '.spec' <<<"$out")"
check "spec skeleton: the title is filled" "# fix slugify dots" "$(sed -n '/^# /p' "$DOCS7/SPEC.md" | head -1)"
check "spec skeleton: the footprint is filled" "1" "$(grep -c '^  - slugify.py$' "$DOCS7/SPEC.md")"
check "spec skeleton: the read-only file is not in the footprint" "0" "$(grep -c '^  - README.md$' "$DOCS7/SPEC.md")"
check "spec skeleton: one Implementation notes bullet per footprint file" "1" "$(grep -c '^- slugify.py: {' "$DOCS7/SPEC.md")"
check "spec skeleton: a read-only bullet per read-only cite" "1" "$(grep -c '^- README.md: read-only; the change does not touch it.$' "$DOCS7/SPEC.md")"
check "spec skeleton: no score to fill, only the two keys the probe reads" "0" "$(grep -c 'goal_clarity\|{0.00-1.00}' "$DOCS7/SPEC.md")"
check "spec skeleton: the frozen Intent block is in place" "2" "$(grep -c '^<!-- intent: frozen\|^<!-- /intent -->' "$DOCS7/SPEC.md")"
check "spec skeleton: the oneshot spec lint accepts the shape" "0" "$(bash "$REPO_ROOT/lib/oneshot-spec-lint.sh" "$DOCS7/SPEC.md" >/dev/null 2>&1; echo $?)"
printf '# edited by the lead\n' >> "$DOCS7/SPEC.md"
out="$(cd "$REPO7" && drv spec skeleton --feature-dir "$FD7" 2>/dev/null)"
check "spec skeleton: an existing SPEC.md is kept" "1" "$(grep -c '^# edited by the lead$' "$DOCS7/SPEC.md")"
printf -- '---\nfootprint: [slugify.py]\n---\n# from a draft\n' > "$WORK/draft.md"
out="$(cd "$WORK" && drv spec write --feature-dir "$FD7" --file "$WORK/draft.md" 2>/dev/null)"
check "spec write: the draft lands at the one target" "$DOCS7/SPEC.md" "$out"
check "spec write: the content is the draft's" "# from a draft" "$(sed -n 4p "$DOCS7/SPEC.md")"
ec=0; (cd "$REPO7" && drv spec write --feature-dir "$FD7" --to "$WORK/elsewhere.md" >/dev/null 2>&1) || ec=$?
check "spec write: any other target is a bad invocation" "2" "$ec"
cat > "$DOCS7/SPEC.md" <<'MD'
---
ambiguity_scores:
  ambiguity: 0.1
  gate_passed: true
  unresolved_dimensions: []
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
check "phase-begin oneshot: the acceptance row carries the criterion text" "1" "$(grep -c "^| GE-001 | .*slugify('a.b') == 'ab'.* | PASS |" "$DOCS7/VERIFICATION.md")"
check "phase-begin oneshot: the second criterion gets its own rows" "2" "$(grep -c '^- criterion: GE-00[12] |' "$DOCS7/VERIFICATION.md")"
# A criterion that is a shell pipeline: the bare pipe would split the row and the
# floor would read the wrong cell (live run 3 paid a REDO and ten edits for it).
check "phase-begin oneshot: a pipe in the criterion is escaped in the table row" "1" "$(grep -c '^| GE-002 | `python3 -m unittest discover -s tests -v 2>&1 \\| grep -c .* | PASS |' "$DOCS7/VERIFICATION.md")"
check "phase-begin oneshot: the floor reads the escaped row's status from the right cell" "0" "$(bash "$REPO_ROOT/lib/converged-floor.sh" "$DOCS7/SPEC.md" "$DOCS7/VERIFICATION.md" 2>&1 | grep -c 'FLOOR GE-002')"
printf '# filled by the lead\n' > "$DOCS7/VERIFICATION.md"
out="$(cd "$REPO7" && AUTONOMOUS=1 SESSION=s7 drv phase-begin oneshot --feature-dir "$FD7" 2>/dev/null)"
check "phase-begin oneshot: an existing VERIFICATION.md is kept" "null" "$(jq -r '.skeletons' <<<"$out")"
check "phase-begin oneshot: kept means untouched" "# filled by the lead" "$(head -1 "$DOCS7/VERIFICATION.md")"
# The one review pass is the driver's launch under the session layer, and the dispatch
# event the exit gate reads is driver-observed; attended, the lead dispatches in-harness.
out="$(cd "$REPO7" && drv oneshot review --feature-dir "$FD7" 2>/dev/null)"
check "oneshot review: attended is in-harness" "in-harness" "$(jq -r '.action' <<<"$out")"
SBIN7="$WORK/sbin7"; SPROF7="$WORK/sprof7"; mkdir -p "$SBIN7" "$SPROF7"
printf '#!/usr/bin/env bash\necho "{\"ok\":true}"\n' > "$SBIN7/codex"; chmod +x "$SBIN7/codex"
printf 'name = "codex"\nbinary = "codex"\nlaunch_args = ["exec"]\nguarded_args = []\nbypass_args = []\nmodel_flag = "--model"\nprompt_template = "{prompt}"\n' > "$SPROF7/codex.toml"
printf 'def slugify(s):\n    return s.lower().replace(".", "")\n' > "$REPO7/slugify.py"; git -C "$REPO7" -c commit.gpgsign=false commit -qam "fix: strip dots"
out="$(cd "$REPO7" && PATH="$SBIN7:$PATH" LOOP_SPEC_SESSION_LAYER=1 LOOP_SPEC_SESSION_PROFILES="$SPROF7" drv oneshot review --feature-dir "$FD7" 2>/dev/null)"
check "oneshot review: the reviewer ran as a session" "completed" "$(jq -r '.status' <<<"$out")"
check "oneshot review: the prompt is one line naming the package, the spec, and the report" "1" "$(grep -c '^Review the package in .* against the spec .*SPEC.md. Write your verdict .* to .*oneshot.review.md.$' "$FD7/dispatch/oneshot.reviewer.md")"
check "oneshot review: the package holds the diff since baseSha" "1" "$(grep -c 'replace' "$(jq -r '.package' <<<"$out")")"
check "oneshot review: the dispatch event is driver-observed" "1" "$(jq -c 'select(.event == "dispatch" and .phase == "oneshot" and .data.launchedBy == "driver")' "$FD7/events.jsonl" | wc -l | tr -d ' ')"
check "oneshot review: the exit gate's review check is satisfied by it" "0" "$(bash "$REPO_ROOT/lib/oneshot-exit-gate.sh" "$FD7" 2>&1 | grep -c '\[review\]')"
# At the boundary the driver runs the review itself when none is on record: one REDO
# carrying the report path, and the second return goes on to the exit gate.
: > "$FD7/events.jsonl"; rm -f "$FD7/dispatch/oneshot.review.md"
out="$(cd "$REPO7" && AUTONOMOUS=1 SESSION=s7 PATH="$SBIN7:$PATH" LOOP_SPEC_SESSION_LAYER=1 LOOP_SPEC_SESSION_PROFILES="$SPROF7" drv next --feature-dir "$FD7" --returned-from oneshot 2>/dev/null)"
check "next from oneshot: the driver runs the review pass and answers one REDO" "REDO phase=oneshot flags=1" "$(head -1 <<<"$out")"
check "next from oneshot: the FLAG hands the lead the report path" "1" "$(grep -c '^FLAG \[review\] the driver ran the one review pass; its verdict and findings are in .*oneshot.review.md' <<<"$out")"
check "next from oneshot: the dispatch event is driver-observed" "1" "$(jq -c 'select(.event == "dispatch" and .data.launchedBy == "driver")' "$FD7/events.jsonl" | wc -l | tr -d ' ')"
out="$(cd "$REPO7" && AUTONOMOUS=1 SESSION=s7 PATH="$SBIN7:$PATH" LOOP_SPEC_SESSION_LAYER=1 LOOP_SPEC_SESSION_PROFILES="$SPROF7" drv next --feature-dir "$FD7" --returned-from oneshot 2>/dev/null)"
check "next from oneshot again: no second review; the exit gate answers" "0" "$(grep -c 'the driver ran the one review pass' <<<"$out")"
check "next from oneshot again: one dispatch event, not two" "1" "$(jq -c 'select(.event == "dispatch" and .data.launchedBy == "driver")' "$FD7/events.jsonl" | wc -l | tr -d ' ')"
out="$(cd "$REPO7" && AUTONOMOUS=1 SESSION=s7 drv next --feature-dir "$FD7" --returned-from oneshot 2>/dev/null)"
check "next from oneshot in-harness: the driver launches nothing and the gate names the missing dispatch" "0" "$(grep -c 'the driver ran the one review pass' <<<"$out")"

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
