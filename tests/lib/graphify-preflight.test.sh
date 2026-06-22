#!/usr/bin/env bash
# Unit tests for lib/graphify-preflight.sh
set -euo pipefail
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/graphify-preflight.sh"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# A fake graphify binary on a controlled PATH.
STUBDIR="$WORK/bin"; mkdir -p "$STUBDIR"
cat > "$STUBDIR/graphify" <<'EOF'
#!/usr/bin/env bash
echo "stub graphify $*"
EOF
chmod +x "$STUBDIR/graphify"

# check: present -> exit 0
if GRAPHIFY_BIN="$STUBDIR/graphify" bash "$SCRIPT" check >/dev/null 2>&1; then
  pass "check passes when graphify present"; else fail "check passes when graphify present"; fi

# check: missing -> exit 1 + install hint on stderr
err="$(GRAPHIFY_BIN="$WORK/nope-graphify" bash "$SCRIPT" check 2>&1 >/dev/null || true)"
rc=0; GRAPHIFY_BIN="$WORK/nope-graphify" bash "$SCRIPT" check >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 1 ]] && pass "check fails (exit 1) when missing" || fail "check fails when missing (rc=$rc)"
echo "$err" | grep -q "uv tool install graphifyy" && pass "install hint shown" || fail "install hint shown"

# check: bypass env -> exit 0 even when missing
if LOOP_SPEC_REQUIRE_GRAPHIFY=0 GRAPHIFY_BIN="$WORK/nope-graphify" bash "$SCRIPT" check >/dev/null 2>&1; then
  pass "bypass env allows missing graphify"; else fail "bypass env allows missing graphify"; fi

# graph-status: missing then present
[[ "$(bash "$SCRIPT" graph-status "$WORK")" == "missing" ]] && pass "graph-status missing" || fail "graph-status missing"
mkdir -p "$WORK/graphify-out"; echo '{}' > "$WORK/graphify-out/graph.json"
[[ "$(bash "$SCRIPT" graph-status "$WORK")" == "present" ]] && pass "graph-status present" || fail "graph-status present"

# build: graph present -> uses --update
out="$(GRAPHIFY_BIN="$STUBDIR/graphify" bash "$SCRIPT" build "$WORK")"
echo "$out" | grep -q -- "--update" && pass "build uses --update when graph present" || fail "build uses --update (got: $out)"

# build: graph absent -> plain build
FRESH="$WORK/fresh"; mkdir -p "$FRESH"
out="$(GRAPHIFY_BIN="$STUBDIR/graphify" bash "$SCRIPT" build "$FRESH")"
echo "$out" | grep -q -- "--update" && fail "fresh build no --update" || pass "fresh build no --update"

# build: missing binary, required -> exit 1
rc=0; GRAPHIFY_BIN="$WORK/nope" bash "$SCRIPT" build "$WORK" >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 1 ]] && pass "build hard-fails when missing+required" || fail "build hard-fails (rc=$rc)"

# build: missing binary, bypassed -> exit 0
if LOOP_SPEC_REQUIRE_GRAPHIFY=0 GRAPHIFY_BIN="$WORK/nope" bash "$SCRIPT" build "$WORK" >/dev/null 2>&1; then
  pass "build skips when missing+bypassed"; else fail "build skips when missing+bypassed"; fi

echo ""; echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
