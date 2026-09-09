#!/usr/bin/env bash
# Tests for lib/verify-gate.sh, lib/verify-passes.sh, lib/iterate-judged.sh, and the
# cycle-driver deliver fold: the per-phase bookkeeping the lead used to run by hand.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DRV="$REPO_ROOT/lib/cycle-driver.sh"
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
WORK="${TMPDIR:-/tmp}"; WORK="${WORK%/}/phase-bundles-test.$$"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export LOOP_SPEC_HARNESS=codex LOOP_SPEC_TEAMS_MODE=none LOOP_SPEC_WORKFLOWS_AVAILABLE=0 LOOP_SPEC_CHECKPOINT_PR=0 LOOP_SPEC_WORKTREES=0
unset LOOP_SPEC_AUTONOMOUS LOOP_SPEC_NON_INTERACTIVE
cd "$REPO"
bash "$DRV" start --dir "$REPO" -- my feature >/dev/null 2>&1
bash "$DRV" init --dir "$REPO" --slug my-feature --title "my feature" --style auto --profile standard --autonomous 1 >/dev/null 2>&1
FD="$REPO/.loop-spec/features/my-feature"
DOCS="$REPO/docs/loop-spec/features/my-feature"; mkdir -p "$DOCS"
fj() { jq -r "$1" "$FD/feature.json"; }
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
printf '# PLAN\n' > "$DOCS/PLAN.md"
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" commands '{"prepare":"","test":"true","lint":"","typecheck":""}' >/dev/null
printf 'echo ok\n' > a.sh; git add -A; git commit -q -m "feat: a.sh"

# --- verify gate: both verdicts pass ----------------------------------------------------
cat > "$DOCS/VERIFICATION.md" <<'MD'
# My Feature - Verification
## Repository grounding
- criterion: GE-001 | implementation: a.sh:1 - proves it | integration: none - covered by unit scope
## Acceptance criteria
| # | Criterion | Status | Evidence |
|---|-----------|--------|----------|
| 1 | it works | PASS | `bash -n a.sh` -> ok |
MD
ec=0; out="$(bash "$DRV" verify gate --feature-dir "$FD" --verifier ALL_PASS --suite PASS --reviewer PASS_WITH_MINOR --minors '["a.sh:1 - naming"]' 2>/dev/null)" || ec=$?
check "gate pass: route is pass" "pass" "$(jq -r '.route' <<<"$out")"
check "gate pass: exit 0" "0" "$ec"
check "gate pass: the exit lint ran clean" "true" "$(jq -r '.exit.ok' <<<"$out")"
check "gate pass: minors go to the backlog" "1" "$(jq -r '.minorsQueued' <<<"$out")"
check "gate pass: the backlog holds the minor" "1" "$(grep -c 'naming' "$REPO/.loop-spec/BACKLOG.md" 2>/dev/null || echo 0)"
check "gate pass: the acceptance gate recorded a pass" "pass" "$(fj '[.gateHistory[] | select(.gate == "acceptance")][-1].result')"

# A minors list with quotes and backslashes breaks inline JSON; @path reads one finding
# per line from a file and needs no JSON at all.
printf '.github/workflows/checks.yml:20 - curl "unpinned" \\ escape\n' > "$FD/minors.json"
ec=0; out="$(bash "$DRV" verify gate --feature-dir "$FD" --verifier ALL_PASS --suite PASS --reviewer PASS_WITH_MINOR --minors "@$FD/minors.json" 2>/dev/null)" || ec=$?
check "verify gate: --minors @path is read from the file" "1" "$(jq -r '.minorsQueued' <<<"$out")"
ec=0; bash "$DRV" verify gate --feature-dir "$FD" --verifier ALL_PASS --suite PASS --reviewer PASS_WITH_MINOR --minors "@$FD/nope.json" >/dev/null 2>&1 || ec=$?
check "verify gate: a missing @path is a usage error" "2" "$ec"

# --- verify gate: reviewer blocks ------------------------------------------------------
ec=0; out="$(bash "$DRV" verify gate --feature-dir "$FD" --verifier ALL_PASS --suite PASS --reviewer BLOCK \
  --remediation-tasks '[{"id":"task-001+remediate-1","subject":"Fix: boundary violation","files":["a.sh"]}]' 2>/dev/null)" || ec=$?
check "gate block: route is remediate" "remediate" "$(jq -r '.route' <<<"$out")"
check "gate block: class is code-review" "code-review" "$(jq -r '.class' <<<"$out")"
check "gate block: exit 1" "1" "$ec"
check "gate block: the task is queued with the project test command" "true" "$(fj '.pendingRemediationTasks[0].verifyCommand')"
check "gate block: the code-review gate recorded a fail" "fail" "$(fj '[.gateHistory[] | select(.gate == "code-review")][-1].result')"
check "gate block: verify_failure emitted" "1" "$(grep -c '"class":"code-review"' "$FD/events.jsonl")"
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" pendingRemediationTasks '[]' >/dev/null
out="$(bash "$DRV" verify gate --feature-dir "$FD" --verifier ALL_PASS --suite PASS --reviewer BLOCK \
  --remediation-tasks '[{"id":"task-001+remediate-2","subject":"Fix: boundary violation","files":["a.sh"]}]' 2>/dev/null)" || true
check "gate block: the same finding twice is a repeat" "true" "$(jq -r '.repeat' <<<"$out")"
check "gate block: a repeat records a rule" "1" "$(grep -c 'repeat-fail' "$REPO/.loop-spec/RULES.md" 2>/dev/null || echo 0)"

# --- verify gate: a malformed record is a redo, never a recorded failure -----------------
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" pendingRemediationTasks '[]' >/dev/null
before="$(fj '.gateHistory | length')"
printf '# broken\n' > "$DOCS/VERIFICATION.md"
ec=0; out="$(bash "$DRV" verify gate --feature-dir "$FD" --verifier ALL_PASS --suite PASS --reviewer PASS 2>/dev/null)" || ec=$?
check "gate redo: route is redo" "redo" "$(jq -r '.route' <<<"$out")"
check "gate redo: exit 1" "1" "$ec"
check "gate redo: the flags come back" "true" "$(jq '.exit.flags | length > 0' <<<"$out")"
check "gate redo: nothing is recorded" "$before" "$(fj '.gateHistory | length')"
check "gate redo: no remediation task" "0" "$(fj '.pendingRemediationTasks | length')"
cat > "$DOCS/VERIFICATION.md" <<'MD'
# My Feature - Verification
## Repository grounding
- criterion: GE-001 | implementation: a.sh:1 - proves it | integration: none - covered by unit scope
## Acceptance criteria
| # | Criterion | Status | Evidence |
|---|-----------|--------|----------|
| 1 | it works | PASS | `bash -n a.sh` -> ok |
MD

# --- verify gate: verifier fails without tasks -------------------------------------------
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" pendingRemediationTasks '[]' >/dev/null
out="$(bash "$DRV" verify gate --feature-dir "$FD" --verifier FAIL --suite N/A --reviewer PASS 2>/dev/null)" || true
check "gate fail without tasks: one task is synthesized" "1" "$(jq '.tasks | length' <<<"$out")"
check "gate fail: class is acceptance" "acceptance" "$(jq -r '.class' <<<"$out")"
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" pendingRemediationTasks '[]' >/dev/null

# --- verify passes ---------------------------------------------------------------------
out="$(bash "$DRV" verify passes --feature-dir "$FD" 2>/dev/null)"
check "passes: one object with every pass" "6" "$(jq 'keys | length' <<<"$out")"
check "passes: live run is unconfigured here" "false" "$(jq -r '.live.configured' <<<"$out")"
check "passes: no review trail yet" "false" "$(jq -r '.reviewTrail.present' <<<"$out")"

# --- iterate: limit, record, harvest -----------------------------------------------------
out="$(bash "$DRV" iterate limit --feature-dir "$FD")"
check "iterate limit: rounds left means judge" "judge" "$(jq -r '.route' <<<"$out")"
printf 'The judge says:\n```json\n{"converged": true, "deterministic_gate_passed": true, "scores": [], "summary": "done"}\n```\n' > "$FD/.iterate-judge.out"
out="$(bash "$DRV" iterate record --feature-dir "$FD" --judge-out "$FD/.iterate-judge.out")"
check "iterate record: a converged verdict routes to deliver" "deliver" "$(jq -r '.route' <<<"$out")"
check "iterate record: used is incremented" "1" "$(fj '.iterate.used')"
check "iterate record: the verdict is recorded" "true" "$(fj '.iterate.lastVerdict.converged')"
check "iterate record: iterate_verdict emitted" "1" "$(grep -c '"event":"iterate_verdict"' "$FD/events.jsonl")"
out="$(bash "$DRV" iterate record --feature-dir "$FD" --judge-out "$FD/.iterate-judge.out")"
check "iterate record: the same judge output again is one round" "1" "$(fj '.iterate.used')"
check "iterate record: a repeat says so and keeps the route" "deliver" "$(jq -r 'select(.repeated == true) | .route' <<<"$out")"
printf '{"converged": false, "deterministic_gate_passed": true, "summary": "not yet", "gap": {"type": "execute", "description": "flag missing", "fix_first": "add the flag"}, "remaining_gaps": [{"type": "execute", "description": "docs", "fix_first": "update README"}]}\n' > "$FD/.iterate-judge.out"
out="$(bash "$DRV" iterate record --feature-dir "$FD" --judge-out "$FD/.iterate-judge.out")"
check "iterate record: an execute gap routes to execute" "execute" "$(jq -r '.route' <<<"$out")"
check "iterate record: one task per execute gap" "2" "$(fj '.pendingRemediationTasks | length')"
check "iterate record: feedback carries the gap" "add the flag" "$(fj '.iterate.feedback.fix_first')"
# A gap only an operator can close escalates instead of rewinding: by the judge's flag,
# or when the same fix_first survives a remediation round.
printf '{"converged": false, "deterministic_gate_passed": true, "summary": "locked", "gap": {"type": "execute", "description": "plan cannot run", "fix_first": "run gcloud auth login", "needs_operator": true}, "remaining_gaps": []}\n' > "$FD/.iterate-judge.out"
out="$(bash "$DRV" iterate record --feature-dir "$FD" --judge-out "$FD/.iterate-judge.out")"
check "iterate record: needs_operator routes to escalate" "escalate" "$(jq -r '.route' <<<"$out")"
check "iterate record: an escalated gap adds no remediation task" "2" "$(fj '.pendingRemediationTasks | length')"
printf '{"converged": false, "deterministic_gate_passed": true, "summary": "still", "gap": {"type": "execute", "description": "x", "fix_first": "Add the flag"}, "remaining_gaps": []}\n' > "$FD/.iterate-judge.out"
out="$(bash "$DRV" iterate record --feature-dir "$FD" --judge-out "$FD/.iterate-judge.out")"
check "iterate record: a fresh execute gap still rewinds" "execute" "$(jq -r '.route' <<<"$out")"
printf '{"converged": false, "deterministic_gate_passed": true, "summary": "again", "gap": {"type": "execute", "description": "y", "fix_first": "add the  flag"}, "remaining_gaps": []}\n' > "$FD/.iterate-judge.out"
out="$(bash "$DRV" iterate record --feature-dir "$FD" --judge-out "$FD/.iterate-judge.out")"
check "iterate record: the same fix_first after a round escalates" "escalate" "$(jq -r '.route' <<<"$out")"
ec=0; out="$(bash "$DRV" next --feature-dir "$FD" --returned-from iterate 2>/dev/null)" || ec=$?
check "next after an escalate route ends the run escalated" "1" "$(grep -c '^DONE status=escalated reason="operator action needed: add the  flag"' <<<"$out")"
check "next after an escalate route writes the result" "escalated" "$(jq -r '.status' "$FD/result.json")"
rm -f "$FD/result.json"
# Restore the two-gap verdict the harvest checks below read as the freshest one.
printf '{"converged": false, "deterministic_gate_passed": true, "summary": "not yet", "gap": {"type": "execute", "description": "flag missing", "fix_first": "add the flag"}, "remaining_gaps": [{"type": "execute", "description": "docs", "fix_first": "update README"}]}\n' > "$FD/.iterate-judge.out"
bash "$DRV" iterate record --feature-dir "$FD" --judge-out "$FD/.iterate-judge.out" >/dev/null
printf 'no verdict here\n' > "$FD/.iterate-judge.out"
ec=0; bash "$DRV" iterate record --feature-dir "$FD" --judge-out "$FD/.iterate-judge.out" >/dev/null 2>&1 || ec=$?
check "iterate record: a malformed verdict is refused" "1" "$ec"
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" iterate.used 10 >/dev/null
out="$(bash "$DRV" iterate limit --feature-dir "$FD")"
check "iterate limit: a spent budget owes one confirmation pass" "confirmation" "$(jq -r '.route' <<<"$out")"
out="$(bash "$DRV" iterate limit --feature-dir "$FD")"
check "iterate limit: then it harvests" "harvest" "$(jq -r '.route' <<<"$out")"
out="$(bash "$DRV" iterate harvest --feature-dir "$FD")"
check "iterate harvest: gaps become warnings" "2" "$(jq '.warnings | length' <<<"$out")"
check "iterate harvest: warnings are prefixed" "1" "$(jq -r '.warnings[0]' <<<"$out" | grep -c '^iterate-budget-spent:')"
check "iterate harvest: the backlog holds the gap" "1" "$(grep -c 'add the flag' "$REPO/.loop-spec/BACKLOG.md")"
check "iterate harvest: routes to deliver" "deliver" "$(jq -r '.route' <<<"$out")"

# --- deliver fold: no remote here, so the controller blocks and the route says so ---------
ec=0; out="$(bash "$DRV" deliver --feature-dir "$FD" 2>/dev/null)" || ec=$?
check "deliver: a blocked delivery routes back to deliver" "deliver" "$(jq -r '.route' <<<"$out")"
check "deliver: exit 1 when not completed" "1" "$ec"
check "deliver: the controller's exit code is reported" "true" "$(jq -r '.rc != 0' <<<"$out")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
