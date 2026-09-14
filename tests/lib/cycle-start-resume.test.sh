#!/usr/bin/env bash
# Tests for lib/graph/driver.py cmd_start's attended resume decision (#9, 6.6.4
# live-run finding): a single paused feature resumes without an interactive
# question, several print a notice and start fresh, and a leading `new` token
# skips resume even with one candidate.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DRIVER="$REPO_ROOT/lib/cycle-driver.sh"
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

WORK="${TMPDIR:-/tmp}"; WORK="${WORK%/}/cycle-start-resume-test.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/repo"
REPO="$WORK/repo"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

FEATS="$REPO/.loop-spec/features"
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mk_feature() { # slug phase
  mkdir -p "$FEATS/$1"
  jq -n --arg p "$2" --arg u "$now_iso" \
    '{schemaVersion: 7, currentPhase: $p, currentTeamName: null, updatedAt: $u, stalenessHours: 48}' \
    > "$FEATS/$1/feature.json"
}

run_start() { # args...
  env -u CLAUDE_CODE_ENTRYPOINT -u LOOP_SPEC_AUTONOMOUS -u LOOP_SPEC_NON_INTERACTIVE \
    LOOP_SPEC_HARNESS=claude LOOP_SPEC_TEAMS_MODE=none LOOP_SPEC_WORKFLOWS_AVAILABLE=0 \
    GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    bash "$DRIVER" start --dir "$REPO" -- "$@"
}

# a: one candidate -> auto-resume, no interactive "resume" decision.
mk_feature one-paused execute
out="$(run_start)"
check "one candidate: autoPick resumes it" "one-paused" "$(jq -r '.resume.autoPick' <<<"$out")"
check "one candidate: no interactive resume question" "0" \
  "$(jq -r '[.decisions[] | select(.id == "resume")] | length' <<<"$out")"
check "one candidate: reason recorded" "1" \
  "$(jq -rs '[.[] | select(.answer == "resume one-paused" and (.rationale | contains("attended")))] | length' \
     "$REPO/.loop-spec/decisions-staging/decisions.jsonl" 2>/dev/null)"
rm -f "$REPO/.loop-spec/decisions-staging/decisions.jsonl"

# b: a second paused feature -> no auto-resume, a notice instead of a question.
mk_feature two-paused plan
out="$(run_start)"
check "two candidates: no autoPick" "null" "$(jq -r '.resume.autoPick' <<<"$out")"
check "two candidates: no interactive resume question" "0" \
  "$(jq -r '[.decisions[] | select(.id == "resume")] | length' <<<"$out")"
check "two candidates: a notice names both slugs" "1" \
  "$(jq -r '[.notices[] | select(contains("one-paused") and contains("two-paused"))] | length' <<<"$out")"

# c: a leading `new` token skips resume even with a single candidate, and is not
# treated as greenfield bootstrap now that this is an existing git repo.
rm -rf "$FEATS/two-paused"
out="$(run_start new "a fresh title")"
check "new token: candidates cleared" "0" "$(jq -r '.resume.candidates | length' <<<"$out")"
check "new token: no autoPick" "null" "$(jq -r '.resume.autoPick' <<<"$out")"
check "new token: not treated as greenfield in a git repo" "false" "$(jq -r '.greenfield' <<<"$out")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
