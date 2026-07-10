#!/usr/bin/env bash
# LIVE end-to-end smoke for the sentinel drive loop (ROADMAP-3.0 A3+A4).
#
# OPT-IN, COSTS REAL TOKENS AND TIME (one autonomous cycle sourced from the
# sentinel queue). Not part of the default offline suite. Run it:
#
#   bash tests/e2e/run-e2e-sentinel.sh        # directly
#   bash tests/run-all.sh --e2e               # after the cycle smoke
#
# What it proves:
#   1. `claude -p "/loop-spec:sentinel run"` in a fixture repo with a seeded
#      backlog entry scans, pops the head item, and drives a cycle from it.
#   2. The pick is recorded in .loop-spec/sentinel-events.jsonl (A4: every
#      decision is ledgered).
#   3. The run is PR-terminated/bounded: main is never advanced by the run
#      (no auto-merge at any trust level in this release) and work lands on a
#      feat/* branch.
#   4. .loop-spec/last-result.json honors the headless contract.
#
# Environment: same knobs as run-e2e.sh (LOOP_SPEC_E2E_TIMEOUT_MINS,
# LOOP_SPEC_E2E_KEEP, LOOP_SPEC_E2E_PERMISSION_FLAGS).
#
# Exit codes: 0 = all assertions passed; 1 = assertion failure; 2 = missing
# prerequisite.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TIMEOUT_MINS="${LOOP_SPEC_E2E_TIMEOUT_MINS:-45}"
PERMISSION_FLAGS="${LOOP_SPEC_E2E_PERMISSION_FLAGS:---dangerously-skip-permissions}"

PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"; PASS=$((PASS+1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL+1))
  fi
}

for bin in claude git jq; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "PREREQ: '$bin' not on PATH — cannot run the live sentinel e2e" >&2
    exit 2
  fi
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/loop-spec-e2e-sentinel.XXXXXX")"
PROJ="$WORK/proj"

cleanup() {
  if [[ "${LOOP_SPEC_E2E_KEEP:-0}" == "1" ]]; then
    echo "e2e-sentinel: keeping workdir at $WORK (LOOP_SPEC_E2E_KEEP=1)"
    return
  fi
  ( cd "$PROJ" 2>/dev/null && \
    claude plugin uninstall loop-spec@loop-spec-marketplace >/dev/null 2>&1; \
    claude plugin marketplace remove loop-spec-marketplace >/dev/null 2>&1 ) || true
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$PROJ"
git -C "$PROJ" init -q
git -C "$PROJ" config user.email e2e@loop-spec.test
git -C "$PROJ" config user.name "loop-spec e2e"

cat > "$PROJ/calc.sh" << 'EOF'
#!/usr/bin/env bash
# Tiny calculator used by the loop-spec e2e fixture.
add() {
  echo $(( $1 + $2 ))
}

case "${1:-}" in
  add) add "$2" "$3" ;;
  *) echo "usage: calc.sh add <a> <b>" >&2; exit 2 ;;
esac
EOF
chmod +x "$PROJ/calc.sh"

mkdir -p "$PROJ/tests"
cat > "$PROJ/tests/test.sh" << 'EOF'
#!/usr/bin/env bash
set -uo pipefail
fail=0
[[ "$(bash "$(dirname "$0")/../calc.sh" add 2 3)" == "5" ]] || { echo "FAIL: add"; fail=1; }
[[ "$fail" -eq 0 ]] && echo "tests passed"
exit "$fail"
EOF
chmod +x "$PROJ/tests/test.sh"

# Seed the sentinel's offline source: one backlog entry (the gh/CI adapters
# degrade gracefully without auth — the backlog keeps the queue non-empty).
mkdir -p "$PROJ/.loop-spec"
( cd "$PROJ" && bash "$REPO_ROOT/lib/backlog.sh" add e2e-fixture manual \
  "add a multiply function to calc.sh (calc.sh multiply A B prints A*B) and cover it in tests/test.sh" >/dev/null )

git -C "$PROJ" add -A
git -C "$PROJ" commit -qm "fixture: calc with add + seeded backlog"
MAIN_BEFORE="$(git -C "$PROJ" rev-parse HEAD)"
# No origin remote on purpose: push/PR paths must degrade gracefully.

if ! ( cd "$PROJ" && claude plugin marketplace add "$REPO_ROOT" --scope local >/dev/null 2>&1 \
      && claude plugin install loop-spec@loop-spec-marketplace --scope local >/dev/null 2>&1 ); then
  echo "PREREQ: local-scope plugin provisioning failed" >&2
  exit 2
fi

echo "e2e-sentinel: running sentinel drive loop in $PROJ (ceiling ${TIMEOUT_MINS}m)..."
RUN_LOG="$WORK/sentinel-run.log"
(
  cd "$PROJ" && \
  env LOOP_SPEC_REQUIRE_GRAPHIFY=0 \
      LOOP_SPEC_SKIP_HEALTHCHECK=1 \
      claude -p "/loop-spec:sentinel run" $PERMISSION_FLAGS
) > "$RUN_LOG" 2>&1 &
CYCLE_PID=$!

DEADLINE=$(( $(date +%s) + TIMEOUT_MINS * 60 ))
TIMED_OUT=0
while kill -0 "$CYCLE_PID" 2>/dev/null; do
  if (( $(date +%s) >= DEADLINE )); then
    echo "e2e-sentinel: wall-clock ceiling hit; killing run" >&2
    kill "$CYCLE_PID" 2>/dev/null
    TIMED_OUT=1
    break
  fi
  sleep 15
done
wait "$CYCLE_PID" 2>/dev/null
RUN_EC=$?

echo "e2e-sentinel: process exited $RUN_EC (timed_out=$TIMED_OUT); log tail:"
tail -5 "$RUN_LOG" || true

check "run did not hit the wall-clock ceiling" "0" "$TIMED_OUT"

# ── Sentinel mechanics ─────────────────────────────────────────────────────────
check "queue file written by the scan" "1" \
  "$([[ -f "$PROJ/.loop-spec/sentinel-queue.json" ]] && echo 1 || echo 0)"

EVENTS="$PROJ/.loop-spec/sentinel-events.jsonl"
check "sentinel decision ledger exists" "1" "$([[ -f "$EVENTS" ]] && echo 1 || echo 0)"
if [[ -f "$EVENTS" ]]; then
  check "the pick was recorded" "1" \
    "$(jq -rs 'map(select(.event == "picked")) | length >= 1' "$EVENTS" 2>/dev/null | grep -c true)"
fi

# ── The cycle it drove ─────────────────────────────────────────────────────────
RESULT="$PROJ/.loop-spec/last-result.json"
check "last-result.json exists" "1" "$([[ -f "$RESULT" ]] && echo 1 || echo 0)"
if [[ -f "$RESULT" ]]; then
  STATUS="$(jq -r '.status // empty' "$RESULT" 2>/dev/null)"
  check "result status is a valid terminal status" "1" \
    "$([[ "$STATUS" =~ ^(completed|paused|escalated|terminal)$ ]] && echo 1 || echo 0)"
fi

check "a feat/* branch exists" "1" \
  "$([[ -n "$(git -C "$PROJ" branch --list 'feat/*')" ]] && echo 1 || echo 0)"

# ── A4: PR-terminated — the run must never advance main ──────────────────────
MAIN_AFTER="$(git -C "$PROJ" rev-parse main 2>/dev/null || git -C "$PROJ" rev-parse master 2>/dev/null || echo unknown)"
check "main was not advanced (no auto-merge)" "$MAIN_BEFORE" "$MAIN_AFTER"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
