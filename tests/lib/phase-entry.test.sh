#!/usr/bin/env bash
# Tests for lib/phase-entry.sh (one call names a phase's whole ingress).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENTRY="$REPO_ROOT/lib/phase-entry.sh"
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

WORK="${TMPDIR:-/tmp}"; WORK="${WORK%/}/phase-entry-test.$$"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export LOOP_SPEC_HARNESS=codex LOOP_SPEC_TEAMS_MODE=none LOOP_SPEC_WORKFLOWS_AVAILABLE=0 LOOP_SPEC_CHECKPOINT_PR=0
unset LOOP_SPEC_AUTONOMOUS LOOP_SPEC_NON_INTERACTIVE

cd "$REPO"
bash "$REPO_ROOT/lib/cycle-driver.sh" start --dir "$REPO" -- my feature >/dev/null 2>&1
bash "$REPO_ROOT/lib/cycle-driver.sh" init --dir "$REPO" --slug my-feature --title "my feature" \
  --style auto --profile standard --autonomous 0 >/dev/null 2>&1
FD="$REPO/.loop-spec/features/my-feature"
DOCS="$REPO/docs/loop-spec/features/my-feature"
mkdir -p "$DOCS"

fields() { grep '^fields=' <<<"$1" | sed 's/^fields=//'; }

# --- usage ------------------------------------------------------------------------
ec=0; bash "$ENTRY" >/dev/null 2>&1 || ec=$?
check "no phase is a bad invocation" "2" "$ec"
ec=0; bash "$ENTRY" bogus --feature-dir "$FD" >/dev/null 2>&1 || ec=$?
check "unknown phase is a bad invocation" "2" "$ec"
ec=0; bash "$ENTRY" spec >/dev/null 2>&1 || ec=$?
check "missing feature dir is a bad invocation" "2" "$ec"

# --- spec: first phase, nothing upstream to require ---------------------------------
ec=0; out="$(bash "$ENTRY" spec --feature-dir "$FD")" || ec=$?
check "spec: fresh feature enters clean" "0" "$ec"
check "spec: answer line" "phase-entry: ok (spec)" "$(tail -1 <<<"$out")"
check "spec: packet carries the slug" "my-feature" "$(jq -r '.slug' <<<"$(fields "$out")")"
check "spec: packet carries execStyle" "auto" "$(jq -r '.execStyle' <<<"$(fields "$out")")"
check "spec: packet omits keys SPEC never reads" "false" "$(jq 'has("iterate") or has("models")' <<<"$(fields "$out")")"
check "spec: no file to read yet" "0" "$(grep -c '^read=' <<<"$out")"

check "spec: entry snapshots feature.json as the egress baseline" "my-feature" "$(jq -r '.slug' "$FD/.phase-entry.json")"

# --- discuss: SPEC.md is required ingress -------------------------------------------
ec=0; out="$(bash "$ENTRY" discuss --feature-dir "$FD")" || ec=$?
check "discuss: missing SPEC.md flags" "1" "$ec"
check "discuss: the flag names the missing artifact" "1" "$(grep -c '^FLAG .*SPEC.md' <<<"$out")"
check "discuss: answer line counts the flag" "phase-entry: 1 flag(s) (discuss)" "$(tail -1 <<<"$out")"

printf '# My Feature\n' > "$DOCS/SPEC.md"
ec=0; out="$(bash "$ENTRY" discuss --feature-dir "$FD")" || ec=$?
check "discuss: SPEC.md present enters clean" "0" "$ec"
check "discuss: read list names SPEC.md" "1" "$(grep -c '^read=.*SPEC.md$' <<<"$out")"

# --- plan: SPEC.md required, PATTERNS.md optional -----------------------------------
ec=0; out="$(bash "$ENTRY" plan --feature-dir "$FD")" || ec=$?
check "plan: SPEC.md alone enters clean" "0" "$ec"
check "plan: absent PATTERNS.md is not listed and not flagged" "0" "$(grep -c 'PATTERNS.md' <<<"$out")"
printf '# Patterns\n' > "$DOCS/PATTERNS.md"
out="$(bash "$ENTRY" plan --feature-dir "$FD")"
check "plan: present PATTERNS.md is listed" "1" "$(grep -c '^read=.*PATTERNS.md$' <<<"$out")"

# --- execute: the tasks sidecar and PLAN.md are required ----------------------------
ec=0; out="$(bash "$ENTRY" execute --feature-dir "$FD")" || ec=$?
check "execute: no sidecar, no PLAN.md flags twice" "2" "$(grep -c '^FLAG ' <<<"$out")"
printf '[]\n' > "$FD/tasks.json"
bash "$REPO_ROOT/lib/feature-write.sh" set "$FD" artifacts.tasks "\"$FD/tasks.json\"" >/dev/null
printf '# Plan\n' > "$DOCS/PLAN.md"
ec=0; out="$(bash "$ENTRY" execute --feature-dir "$FD")" || ec=$?
check "execute: sidecar and PLAN.md present enter clean" "0" "$ec"
check "execute: read list names the sidecar" "1" "$(grep -c '^read=.*tasks.json$' <<<"$out")"
check "execute: packet carries the branch" "feat/my-feature" "$(jq -r '.branch' <<<"$(fields "$out")")"
check "execute: packet carries commands as an object" "object" "$(jq -r '.commands | type' <<<"$(fields "$out")")"

# --- verify / iterate / deliver ------------------------------------------------------
ec=0; out="$(bash "$ENTRY" verify --feature-dir "$FD")" || ec=$?
check "verify: SPEC.md and PLAN.md present enter clean" "0" "$ec"
ec=0; out="$(bash "$ENTRY" iterate --feature-dir "$FD")" || ec=$?
check "iterate: missing VERIFICATION.md flags" "1" "$ec"
printf '# Verification\n' > "$DOCS/VERIFICATION.md"
ec=0; out="$(bash "$ENTRY" iterate --feature-dir "$FD")" || ec=$?
check "iterate: VERIFICATION.md present enters clean" "0" "$ec"
check "iterate: packet carries the iterate block" "object" "$(jq -r '.iterate | type' <<<"$(fields "$out")")"
ec=0; out="$(bash "$ENTRY" deliver --feature-dir "$FD")" || ec=$?
check "deliver: enters clean" "0" "$ec"
check "deliver: packet carries baseBranch" "main" "$(jq -r '.baseBranch' <<<"$(fields "$out")")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
