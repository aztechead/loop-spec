#!/usr/bin/env bash
# Test suite for hooks/team/route-terminal-guard.sh
# Stop hook: no route ends without a terminal result.
# Usage: bash hooks/team/route-terminal-guard.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/route-terminal-guard.sh"
CYCLE_RESULT="$HERE/../../lib/cycle-result.sh"
TMPDIR_TEST="${TMPDIR:-/tmp}/route-terminal-guard-test-$$"
mkdir -p "$TMPDIR_TEST"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

export LOOP_SPEC_ROUTE_GUARD_TRACE_LOG="$TMPDIR_TEST/trace.log"

PASS=0
FAIL=0

check() {
  local name="$1" expected_exit="$2" project="$3"; shift 3
  local actual_exit=0
  env CLAUDE_PROJECT_DIR="$project" "$@" bash "$HOOK" >/dev/null 2>&1 \
    <<<"${PAYLOAD:-{\}}" || actual_exit=$?
  if [[ "$actual_exit" -eq "$expected_exit" ]]; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name (expected exit $expected_exit, got $actual_exit)"; ((FAIL++)) || true
  fi
}

# An armed run is what task-route.sh leaves behind before the routed skill starts.
arm() {
  local project="$1" autonomous="$2" started="${3:-}"
  mkdir -p "$project/.loop-spec"
  jq -n --arg autonomous "$autonomous" --arg started "$started" \
    '{schema:1,cycleType:"full",title:"What is the architecture?",slug:null,branch:null,
      baseBranch:null,featureDir:null,phase:"routing",
      autonomous:($autonomous == "true"),
      startedAt:(if $started == "" then "2026-01-01T00:00:00Z" else $started end),
      updatedAt:(if $started == "" then "2026-01-01T00:00:00Z" else $started end)}' \
    > "$project/.loop-spec/active-run.json"
}

now_stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# a: an autonomous route that published nothing is the reported bug -> BLOCK.
ARMED="$TMPDIR_TEST/armed"; mkdir -p "$ARMED"
arm "$ARMED" true "$(now_stamp)"
check "a: armed autonomous route with no terminal result -> BLOCK" 2 "$ARMED"

# b: publishing the result disarms the run -> ALLOW.
PUBLISHED="$TMPDIR_TEST/published"; mkdir -p "$PUBLISHED"
arm "$PUBLISHED" true "$(now_stamp)"
bash "$CYCLE_RESULT" write-terminal --result-root "$PUBLISHED" --cycle-type full \
  --status escalated --outcome protocol-mismatch --title "What is the architecture?" \
  --converged false --reason "the request is a question, not a code-change task" \
  --summary "Routed to the full cycle; reported the non-task without changing the repo." \
  >/dev/null 2>&1
check "b: published terminal result -> ALLOW" 0 "$PUBLISHED"

# c: an interactive run ends turns to ask the human; the guard is not its business.
INTERACTIVE="$TMPDIR_TEST/interactive"; mkdir -p "$INTERACTIVE"
arm "$INTERACTIVE" false "$(now_stamp)"
check "c: armed interactive run -> ALLOW" 0 "$INTERACTIVE"

# d: a record from a run that died long ago is not this session's contract.
STALE="$TMPDIR_TEST/stale"; mkdir -p "$STALE"
arm "$STALE" true "2020-01-01T00:00:00Z"
check "d: armed run past the stand-down age -> ALLOW" 0 "$STALE"
check "d2: stand-down age is configurable" 2 "$STALE" \
  LOOP_SPEC_ROUTE_GUARD_MAX_AGE_MIN=99999999

# e: no armed run at all.
IDLE="$TMPDIR_TEST/idle"; mkdir -p "$IDLE/.loop-spec"
check "e: no armed run -> ALLOW" 0 "$IDLE"

# f: never hijack a project that does not use loop-spec.
FOREIGN="$TMPDIR_TEST/foreign"; mkdir -p "$FOREIGN"
check "f: project without .loop-spec -> ALLOW" 0 "$FOREIGN"

# g: kill switch and re-block suppression.
check "g: kill switch -> ALLOW" 0 "$ARMED" LOOP_SPEC_ROUTE_GUARD=0
PAYLOAD='{"stop_hook_active":true}' \
  check "h: stop_hook_active -> ALLOW" 0 "$ARMED"

# i: fail-open at the probe boundary — a broken lib must not strand the session.
BROKEN="$TMPDIR_TEST/broken-probe"
printf '#!/usr/bin/env bash\nexit 2\n' > "$BROKEN"; chmod +x "$BROKEN"
check "i: probe failure -> ALLOW" 0 "$ARMED" LOOP_SPEC_CYCLE_RESULT_BIN="$BROKEN"
check "j: missing probe -> ALLOW" 0 "$ARMED" \
  LOOP_SPEC_CYCLE_RESULT_BIN="$TMPDIR_TEST/does-not-exist.sh"
PAYLOAD='this is not json' check "k: malformed payload -> BLOCK (armed run stands)" 2 "$ARMED"
PAYLOAD='' check "l: empty payload -> BLOCK (armed run stands)" 2 "$ARMED"

# m: the block message has to be actionable on its own.
msg="$(env CLAUDE_PROJECT_DIR="$ARMED" bash "$HOOK" 2>&1 >/dev/null <<<'{}' || true)"
for needle in "write-terminal" "protocol-mismatch" "LOOP_SPEC_ROUTE_GUARD=0"; do
  if printf '%s' "$msg" | grep -qF -- "$needle"; then
    echo "PASS: m: block message names '$needle'"; ((PASS++)) || true
  else
    echo "FAIL: m: block message missing '$needle' (msg: $msg)"; ((FAIL++)) || true
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
