#!/usr/bin/env bash
# Unit tests for lib/runtime-preflight.sh without depending on the real jq.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/lib/runtime-preflight.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

run_check() {
  local path="$1" rc=0
  PATH="$path" /bin/bash "$SCRIPT" check-jq >"$WORK/out" 2>"$WORK/err" || rc=$?
  printf '%s' "$rc"
}

rc="$(run_check "$WORK/empty")"
[[ "$rc" == "1" ]] && pass "missing jq fails" || fail "missing jq fails (rc=$rc)"
grep -qF 'jq >= 1.5 is required' "$WORK/err" && pass "missing jq has actionable error" || fail "missing jq has actionable error"

make_jq() {
  local dir="$1" version="$2"
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\nprintf '\''%s\\n'\'' '\''%s'\''\n' '%s' "$version" > "$dir/jq"
  chmod +x "$dir/jq"
}

make_jq "$WORK/jq14" 'jq-1.4'
rc="$(run_check "$WORK/jq14:/usr/bin:/bin")"
[[ "$rc" == "1" ]] && pass "jq 1.4 rejected" || fail "jq 1.4 rejected (rc=$rc)"

make_jq "$WORK/jq15" 'jq-1.5'
rc="$(run_check "$WORK/jq15:/usr/bin:/bin")"
[[ "$rc" == "0" ]] && pass "jq 1.5 accepted" || fail "jq 1.5 accepted (rc=$rc)"

make_jq "$WORK/jq17" 'jq-1.7.1-apple'
rc="$(run_check "$WORK/jq17:/usr/bin:/bin")"
[[ "$rc" == "0" ]] && pass "newer jq suffix accepted" || fail "newer jq suffix accepted (rc=$rc)"

make_jq "$WORK/bad" 'jq-development'
rc="$(run_check "$WORK/bad:/usr/bin:/bin")"
[[ "$rc" == "1" ]] && pass "unparseable version rejected" || fail "unparseable version rejected (rc=$rc)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
