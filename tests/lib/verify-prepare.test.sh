#!/usr/bin/env bash
# Tests for lib/verify-prepare.sh (VERIFY's pre-team scans, one JSON answer).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/lib/verify-prepare.sh"
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
WORK="${TMPDIR:-/tmp}"; WORK="${WORK%/}/verify-prepare-test.$$"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export LOOP_SPEC_HARNESS=codex LOOP_SPEC_TEAMS_MODE=none LOOP_SPEC_WORKFLOWS_AVAILABLE=0 LOOP_SPEC_CHECKPOINT_PR=0 LOOP_SPEC_WORKTREES=0
unset LOOP_SPEC_AUTONOMOUS LOOP_SPEC_NON_INTERACTIVE
cd "$REPO"
bash "$REPO_ROOT/lib/cycle-driver.sh" start --dir "$REPO" -- my feature >/dev/null 2>&1
bash "$REPO_ROOT/lib/cycle-driver.sh" init --dir "$REPO" --slug my-feature --title "my feature" \
  --style auto --profile standard --autonomous 0 >/dev/null 2>&1
FD="$REPO/.loop-spec/features/my-feature"
DOCS="$REPO/docs/loop-spec/features/my-feature"; mkdir -p "$DOCS"
printf '# SPEC\n' > "$DOCS/SPEC.md"; printf '# PLAN\n' > "$DOCS/PLAN.md"
# FD now carries a v1 artifactPublication from creation: a plain `set` needs the
# ingress token that begins an operation (task-009 strict enforcement).
tok="$(mktemp "${TMPDIR:-/tmp}/verify-prepare-fw-token.XXXXXX")"
python3 "$REPO_ROOT/lib/feature_write.py" ingress "$FD" > "$tok"
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" commands '{"prepare":"","test":"true","lint":"","typecheck":""}' --token "$tok" >/dev/null
rm -f "$tok"
# The cycle's state commit keeps the tree clean for the validation baseline; stand in for it.
git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -q -m "chore: state" >/dev/null 2>&1

ec=0; bash "$SCRIPT" >/dev/null 2>&1 || ec=$?
check "usage: no subcommand is a bad invocation" "2" "$ec"

# --- clean branch ------------------------------------------------------------------
printf 'def f():\n    return 1\n' > "$REPO/app.py"
git -C "$REPO" add app.py; git -C "$REPO" commit -q -m "feat: app"
ec=0; out="$(bash "$SCRIPT" run --feature-dir "$FD" 2>/dev/null)" || ec=$?
check "clean: route is continue" "continue" "$(jq -r '.route' <<<"$out")"
check "clean: exit 0" "0" "$ec"
check "clean: the placeholder scan ran" "true" "$(jq -r '.placeholder.ran' <<<"$out")"
check "clean: no remediation tasks" "0" "$(jq '.remediationTasks | length' <<<"$out")"

# --- a placeholder in an added line ---------------------------------------------------
printf 'def g():\n    # TODO implement\n    raise NotImplementedError\n' > "$REPO/stub.py"
git -C "$REPO" add stub.py; git -C "$REPO" commit -q -m "feat: stub"
ec=0; out="$(bash "$SCRIPT" run --feature-dir "$FD" 2>/dev/null)" || ec=$?
check "marker: route is remediate" "remediate" "$(jq -r '.route' <<<"$out")"
check "marker: class is marker" "marker" "$(jq -r '.class' <<<"$out")"
check "marker: exit 1" "1" "$ec"
check "marker: one task per signal lands in pendingRemediationTasks" "$(jq '.remediationTasks | length' <<<"$out")" "$(jq '.pendingRemediationTasks | length' "$FD/feature.json")"
check "marker: tasks carry the project test command" "true" "$(jq -r '.pendingRemediationTasks[0].verifyCommand' "$FD/feature.json")"
check "marker: the acceptance gate recorded a fail" "fail" "$(jq -r '[.gateHistory[] | select(.phase == "verify" and .gate == "acceptance")][-1].result' "$FD/feature.json")"
check "marker: a verify_failure event was emitted" "1" "$(grep -c '"event":"verify_failure"' "$FD/events.jsonl")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
