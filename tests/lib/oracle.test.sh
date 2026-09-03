#!/usr/bin/env bash
# Tests for lib/supervisor/oracle.sh (who answers an interview question).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/lib/supervisor/oracle.sh"
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

WORK="${TMPDIR:-/tmp}/loop-spec-oracle.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/auto" "$WORK/human"
printf '{"slug":"a","autonomous":true}' > "$WORK/auto/feature.json"
printf '{"slug":"h","autonomous":false}' > "$WORK/human/feature.json"
unset LOOP_SPEC_AUTONOMOUS LOOP_SPEC_ORACLE LOOP_SPEC_PROFILE_PRESET 2>/dev/null || true
export LOOP_SPEC_PROFILE="$WORK/none.json"

# not autonomous: the human is the oracle, whatever LOOP_SPEC_ORACLE says
check "human without feature dir" "oracle=human reason=not-autonomous" "$(bash "$SCRIPT" mode)"
check "human from feature.json" "oracle=human reason=not-autonomous" "$(bash "$SCRIPT" mode --feature-dir "$WORK/human")"
check "LOOP_SPEC_ORACLE cannot make a run autonomous" "oracle=human" "$(LOOP_SPEC_ORACLE=supervisor bash "$SCRIPT" mode --feature-dir "$WORK/human" | cut -d' ' -f1)"

# autonomous, no oracle named: self (today's behavior)
check "self from feature.json" "oracle=self reason=unset,feature.json.autonomous" "$(bash "$SCRIPT" mode --feature-dir "$WORK/auto")"
check "self from env" "oracle=self reason=unset,LOOP_SPEC_AUTONOMOUS=1" "$(LOOP_SPEC_AUTONOMOUS=1 bash "$SCRIPT" mode)"
check "self when named" "oracle=self reason=self,LOOP_SPEC_AUTONOMOUS=1" "$(LOOP_SPEC_AUTONOMOUS=1 LOOP_SPEC_ORACLE=self bash "$SCRIPT" mode)"

# autonomous with a supervisor
check "supervisor from env" "oracle=supervisor reason=LOOP_SPEC_ORACLE=supervisor,feature.json.autonomous" "$(LOOP_SPEC_ORACLE=supervisor bash "$SCRIPT" mode --feature-dir "$WORK/auto")"

# fail-safe: an unknown value is self, and says so
check "unknown value is self" "oracle=self reason=unknown-value:bogus,LOOP_SPEC_AUTONOMOUS=1" "$(LOOP_SPEC_AUTONOMOUS=1 LOOP_SPEC_ORACLE=bogus bash "$SCRIPT" mode)"

# the profile file is applied first
printf '{"preset":"supervised"}' > "$WORK/profile.json"
check "supervised preset selects the supervisor" "oracle=supervisor reason=LOOP_SPEC_ORACLE=supervisor,LOOP_SPEC_AUTONOMOUS=1" "$(LOOP_SPEC_PROFILE="$WORK/profile.json" bash "$SCRIPT" mode)"
check "env outranks the profile" "oracle=self reason=self,LOOP_SPEC_AUTONOMOUS=1" "$(LOOP_SPEC_PROFILE="$WORK/profile.json" LOOP_SPEC_ORACLE=self bash "$SCRIPT" mode)"

# an unreadable feature.json is not autonomous (never invents autonomy)
printf 'nope' > "$WORK/human/feature.json"
check "unparseable feature.json is human" "oracle=human" "$(bash "$SCRIPT" mode --feature-dir "$WORK/human" | cut -d' ' -f1)"

# bad invocations
ec=0; bash "$SCRIPT" >/dev/null 2>&1 || ec=$?
check "no op exits 2" "2" "$ec"
ec=0; bash "$SCRIPT" mode --feature-dir >/dev/null 2>&1 || ec=$?
check "empty --feature-dir exits 2" "2" "$ec"
ec=0; bash "$SCRIPT" mode --bogus >/dev/null 2>&1 || ec=$?
check "unknown flag exits 2" "2" "$ec"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
