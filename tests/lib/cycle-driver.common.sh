# Shared rig for tests/lib/cycle-driver-*.test.sh: helpers, drv(), new_repo(), write_spec().
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
  local call_session=""
  if [[ "${NO_ID:-}" != "1" ]]; then
    call_session="${SESSION:-test-fresh-${RANDOM}-$$}"
  fi
  env -u CLAUDE_CODE_ENTRYPOINT -u LOOP_SPEC_AUTONOMOUS -u LOOP_SPEC_NON_INTERACTIVE \
    -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID ${call_session:+LOOP_SPEC_SESSION_ID="$call_session" CLAUDE_CODE_SESSION_ID="$call_session"} \
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

# rig: REPO6/FD6 is created once in cycle-driver-core.test.sh ("begin: start and init in
# one call") and then driven further by both the short-route part (the rewind rule) and
# the phases part (phase-begin onward); both need the same fresh feature, so the create
# step is shared here instead of pasted twice.
rig_repo6_begun() {
  REPO6="$(new_repo begun)"
  out="$(cd "$REPO6" && AUTONOMOUS=1 drv begin -- "autonomous add a flag to the tool" 2>/dev/null)"
  FD6="$(jq -r '.featureDir' <<<"$out")"
}
