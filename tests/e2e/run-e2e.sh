#!/usr/bin/env bash
# LIVE end-to-end smoke test for the headless cycle contract.
#
# THIS TEST IS OPT-IN AND COSTS REAL TOKENS AND WALL-CLOCK TIME (a full
# autonomous cycle, typically 10-45 minutes). It is deliberately NOT part of
# the default `tests/run-all.sh` suite (which must stay offline). Run it:
#
#   bash tests/e2e/run-e2e.sh              # directly
#   bash tests/run-all.sh --e2e            # appended to the offline suite
#
# What it proves (the machine-readable headless contract, README "Machine-
# readable results"):
#   1. A fixture repo + a local-scope plugin install of THIS checkout can run
#      `claude -p "/loop-spec:cycle autonomous <goal>"` end to end.
#   2. `.loop-spec/last-result.json` exists and honors result.json schema 1.
#   3. The per-feature events.jsonl exists, has >=1 phase_start, and its
#      terminal event matches result.json.status.
#   4. A feat/* branch exists in the fixture repo.
#   5. On status==completed, the requested change is actually present.
#
# Environment:
#   LOOP_SPEC_E2E_TIMEOUT_MINS   wall-clock ceiling for the cycle run (default 45)
#   LOOP_SPEC_E2E_KEEP=1         keep the tmp workdir for inspection
#   LOOP_SPEC_E2E_PERMISSION_FLAGS  override the permission flags passed to
#                                claude -p (default: --dangerously-skip-permissions,
#                                safe here because the run is confined to a
#                                throwaway fixture repo with no remote)
#
# Plugin provisioning (probed design decision, 2026-07): an isolated
# CLAUDE_CONFIG_DIR loses OAuth credentials (the keychain item is global but
# the CLI only resolves it for the default config dir), so instead of isolating
# the whole config we install the plugin with `--scope local` INSIDE the
# fixture repo (.claude/settings.local.json). User-level config is never
# touched; deleting the fixture removes the declaration. The only residue is
# the CLI's internal marketplace cache, removed best-effort on cleanup.
#
# Exit codes: 0 = all assertions passed; 1 = assertion failure; 2 = missing
# prerequisite (claude/git/jq not on PATH).
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

# ── Prerequisites (exit 2, distinct from assertion failure) ──────────────────
for bin in claude git jq; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "PREREQ: '$bin' not on PATH — cannot run the live e2e smoke" >&2
    exit 2
  fi
done

# ── Workdir + fixture repo ────────────────────────────────────────────────────
WORK="$(mktemp -d "${TMPDIR:-/tmp}/loop-spec-e2e.XXXXXX")"
PROJ="$WORK/proj"

cleanup() {
  if [[ "${LOOP_SPEC_E2E_KEEP:-0}" == "1" ]]; then
    echo "e2e: keeping workdir at $WORK (LOOP_SPEC_E2E_KEEP=1)"
    return
  fi
  # Best-effort: drop the CLI's cached copy of the local-scope marketplace.
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

git -C "$PROJ" add -A
git -C "$PROJ" commit -qm "fixture: calc with add"
# No origin remote on purpose: push/PR/checkpoint paths must degrade gracefully.

# ── Provision the plugin from THIS checkout, local scope only ─────────────────
if ! ( cd "$PROJ" && claude plugin marketplace add "$REPO_ROOT" --scope local >/dev/null 2>&1 \
      && claude plugin install loop-spec@loop-spec-marketplace --scope local >/dev/null 2>&1 ); then
  echo "PREREQ: local-scope plugin provisioning failed (claude plugin marketplace add / install)" >&2
  exit 2
fi

# ── Run the autonomous cycle with a wall-clock ceiling ────────────────────────
GOAL="add a subtract function to calc.sh (calc.sh subtract A B prints A-B) and cover it in tests/test.sh"
echo "e2e: running autonomous cycle in $PROJ (ceiling ${TIMEOUT_MINS}m)..."

RUN_LOG="$WORK/cycle-run.log"
(
  cd "$PROJ" && \
  env LOOP_SPEC_REQUIRE_GRAPHIFY=0 \
      LOOP_SPEC_SKIP_HEALTHCHECK=1 \
      LOOP_SPEC_CHECKPOINT_PR=0 \
      claude -p "/loop-spec:cycle autonomous $GOAL" $PERMISSION_FLAGS
) > "$RUN_LOG" 2>&1 &
CYCLE_PID=$!

# Portable wall-clock watchdog (macOS ships no `timeout` binary).
DEADLINE=$(( $(date +%s) + TIMEOUT_MINS * 60 ))
TIMED_OUT=0
while kill -0 "$CYCLE_PID" 2>/dev/null; do
  if (( $(date +%s) >= DEADLINE )); then
    echo "e2e: wall-clock ceiling hit; killing cycle run" >&2
    kill "$CYCLE_PID" 2>/dev/null
    TIMED_OUT=1
    break
  fi
  sleep 15
done
wait "$CYCLE_PID" 2>/dev/null
CYCLE_EC=$?

echo "e2e: cycle process exited $CYCLE_EC (timed_out=$TIMED_OUT); log tail:"
tail -5 "$RUN_LOG" || true

check "cycle did not hit the wall-clock ceiling" "0" "$TIMED_OUT"

# ── Assertions on the machine-readable contract ───────────────────────────────
RESULT="$PROJ/.loop-spec/last-result.json"
check "last-result.json exists" "1" "$([[ -f "$RESULT" ]] && echo 1 || echo 0)"

if [[ -f "$RESULT" ]]; then
  check "result schema == 1" "1" "$(jq -r '.schema // empty' "$RESULT" 2>/dev/null)"

  STATUS="$(jq -r '.status // empty' "$RESULT" 2>/dev/null)"
  check "result status is a valid terminal status" "1" \
    "$([[ "$STATUS" =~ ^(completed|paused|escalated|terminal)$ ]] && echo 1 || echo 0)"

  SLUG="$(jq -r '.slug // empty' "$RESULT" 2>/dev/null)"
  check "result slug non-empty" "1" "$([[ -n "$SLUG" ]] && echo 1 || echo 0)"

  check "result converged is boolean" "1" \
    "$(jq -r '.converged | type == "boolean"' "$RESULT" 2>/dev/null | grep -c true)"

  check "result iterations.used is a number" "number" \
    "$(jq -r '.iterations.used | type' "$RESULT" 2>/dev/null)"

  EVENTS="$PROJ/.loop-spec/features/$SLUG/events.jsonl"
  check "events.jsonl exists" "1" "$([[ -f "$EVENTS" ]] && echo 1 || echo 0)"
  if [[ -f "$EVENTS" ]]; then
    check "events.jsonl every line is valid JSON" "1" \
      "$(jq -es 'length >= 1' "$EVENTS" >/dev/null 2>&1 && echo 1 || echo 0)"
    check "events.jsonl has >=1 phase_start" "1" \
      "$(jq -rs 'map(select(.event == "phase_start")) | length >= 1' "$EVENTS" 2>/dev/null | grep -c true)"
    check "events.jsonl terminal event matches result status" "1" \
      "$(jq -rs --arg s "$STATUS" 'map(select(.event == $s)) | length >= 1' "$EVENTS" 2>/dev/null | grep -c true)"
  fi

  check "a feat/* branch exists in the fixture repo" "1" \
    "$([[ -n "$(git -C "$PROJ" branch --list 'feat/*')" ]] && echo 1 || echo 0)"

  if [[ "$STATUS" == "completed" ]]; then
    BRANCH="$(jq -r '.branch // empty' "$RESULT" 2>/dev/null)"
    SUBTRACT_PRESENT=0
    if [[ -n "$BRANCH" ]] && git -C "$PROJ" grep -q "subtract" "$BRANCH" -- calc.sh 2>/dev/null; then
      SUBTRACT_PRESENT=1
    elif grep -rq "subtract" "$PROJ/calc.sh" 2>/dev/null; then
      SUBTRACT_PRESENT=1
    else
      # The feature branch may live in a worktree; scan all feat/* branches.
      for b in $(git -C "$PROJ" for-each-ref --format='%(refname:short)' 'refs/heads/feat/*'); do
        git -C "$PROJ" grep -q "subtract" "$b" -- calc.sh 2>/dev/null && SUBTRACT_PRESENT=1 && break
      done
    fi
    check "completed run actually contains the subtract function" "1" "$SUBTRACT_PRESENT"
  else
    echo "NOTE: status=$STATUS (not completed) — content assertion skipped; contract assertions above still apply"
  fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
