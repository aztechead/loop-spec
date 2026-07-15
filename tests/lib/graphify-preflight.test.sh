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
pi_err="$(LOOP_SPEC_HARNESS=pi GRAPHIFY_BIN="$WORK/nope-graphify" bash "$SCRIPT" check 2>&1 >/dev/null || true)"
echo "$pi_err" | grep -q 'graphify install --platform pi' && pass "pi registration hint shown" || fail "pi registration hint shown"
oc_err="$(LOOP_SPEC_HARNESS=opencode GRAPHIFY_BIN="$WORK/nope-graphify" bash "$SCRIPT" check 2>&1 >/dev/null || true)"
echo "$oc_err" | grep -q 'graphify install --platform opencode' && pass "OpenCode registration hint shown" || fail "OpenCode registration hint shown"

# check: bypass env -> exit 0 even when missing
if LOOP_SPEC_REQUIRE_GRAPHIFY=0 GRAPHIFY_BIN="$WORK/nope-graphify" bash "$SCRIPT" check >/dev/null 2>&1; then
  pass "bypass env allows missing graphify"; else fail "bypass env allows missing graphify"; fi

# graph-status: require named nodes and the complete assistant output set
STATUS_DIR="$WORK/status"; mkdir -p "$STATUS_DIR/graphify-out"
[[ "$(bash "$SCRIPT" graph-status "$STATUS_DIR")" == "missing" ]] && pass "graph-status missing" || fail "graph-status missing"
printf '%s\n' '{}' > "$STATUS_DIR/graphify-out/graph.json"
[[ "$(bash "$SCRIPT" graph-status "$STATUS_DIR")" == "missing" ]] && pass "graph-status rejects empty graph" || fail "graph-status rejects empty graph"
printf '%s\n' '{not json' > "$STATUS_DIR/graphify-out/graph.json"
[[ "$(bash "$SCRIPT" graph-status "$STATUS_DIR")" == "missing" ]] && pass "graph-status rejects malformed graph" || fail "graph-status rejects malformed graph"
printf '%s\n' '{"nodes":[{"id":"example"}],"links":[]}' > "$STATUS_DIR/graphify-out/graph.json"
[[ "$(bash "$SCRIPT" graph-status "$STATUS_DIR")" == "missing" ]] && pass "graph-status rejects unlabeled nodes" || fail "graph-status rejects unlabeled nodes"
printf '%s\n' '{"nodes":[{"id":"example","label":"deadbeefdeadbeef"}],"links":[]}' > "$STATUS_DIR/graphify-out/graph.json"
[[ "$(bash "$SCRIPT" graph-status "$STATUS_DIR")" == "missing" ]] && pass "graph-status rejects opaque node labels" || fail "graph-status rejects opaque node labels"
printf '%s\n' '{"nodes":[{"id":"example","label":"Example Service"}],"links":[]}' > "$STATUS_DIR/graphify-out/graph.json"
[[ "$(bash "$SCRIPT" graph-status "$STATUS_DIR")" == "missing" ]] && pass "graph-status requires report" || fail "graph-status requires report"
printf '%s\n' '# Graph report' > "$STATUS_DIR/graphify-out/GRAPH_REPORT.md"
[[ "$(bash "$SCRIPT" graph-status "$STATUS_DIR")" == "missing" ]] && pass "graph-status requires manifest" || fail "graph-status requires manifest"
printf '%s\n' '{}' > "$STATUS_DIR/graphify-out/manifest.json"
[[ "$(bash "$SCRIPT" graph-status "$STATUS_DIR")" == "missing" ]] && pass "graph-status requires HTML" || fail "graph-status requires HTML"
printf '%s\n' '<html></html>' > "$STATUS_DIR/graphify-out/graph.html"
[[ "$(bash "$SCRIPT" graph-status "$STATUS_DIR")" == "present" ]] && pass "graph-status present" || fail "graph-status present"
if bash "$SCRIPT" validate "$STATUS_DIR" >/dev/null 2>&1; then
  pass "validate accepts complete assistant graph"; else fail "validate accepts complete assistant graph"; fi

# The preflight must never construct a graph; assistant skill invocation owns it.
rc=0; GRAPHIFY_BIN="$STUBDIR/graphify" bash "$SCRIPT" build "$STATUS_DIR" >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] && pass "build command is retired" || fail "build command is retired (rc=$rc)"

# stage: commit shared outputs, ignore local-only churn, and untrack old local artifacts
REPO="$WORK/repo"; mkdir -p "$REPO/graphify-out/cache"
git -C "$REPO" init -q
git -C "$REPO" config user.name test
git -C "$REPO" config user.email test@example.com
printf '%s\n' old > "$REPO/graphify-out/cost.json"
printf '%s\n' old > "$REPO/graphify-out/.graphify_root"
printf '%s\n' old > "$REPO/graphify-out/.graphify_uncached.txt"
printf '%s\n' old > "$REPO/graphify-out/cache/deadbeef.json"
printf '%s\n' old > "$REPO/graphify-out/.graphify_detect.json"
printf '%s\n' old > "$REPO/graphify-out/.graphify_semantic_1.json"
printf '%s\n' old > "$REPO/graphify-out/.needs_update"
git -C "$REPO" add graphify-out
git -C "$REPO" commit -qm initial
printf '%s\n' '{"nodes":[{"id":"example","label":"Example Service"}],"links":[]}' > "$REPO/graphify-out/graph.json"
printf '%s\n' '# Graph report' > "$REPO/graphify-out/GRAPH_REPORT.md"
printf '%s\n' '{}' > "$REPO/graphify-out/manifest.json"
printf '%s\n' '<html></html>' > "$REPO/graphify-out/graph.html"
printf '%s\n' local > "$REPO/graphify-out/.graphify_python"
printf '%s\n' '{}' > "$REPO/graphify-out/.graphify_analysis.json"
bash "$SCRIPT" stage "$REPO"
staged="$(git -C "$REPO" diff --cached --name-only)"
for artifact in graph.json GRAPH_REPORT.md manifest.json graph.html .graphify_analysis.json; do
  echo "$staged" | grep -q "graphify-out/$artifact" && pass "stage includes $artifact" || fail "stage includes $artifact"
done
for artifact in cost.json .graphify_root .graphify_uncached.txt cache/deadbeef.json .graphify_detect.json .graphify_semantic_1.json .needs_update; do
  echo "$staged" | grep -q "graphify-out/$artifact" && pass "stage removes tracked $artifact" || fail "stage removes tracked $artifact"
done
ignored="$(git -C "$REPO" status --short --ignored)"
echo "$ignored" | grep -q '!! graphify-out/.graphify_python' && pass "stage ignores machine interpreter" || fail "stage ignores machine interpreter"
echo "$ignored" | grep -q '!! graphify-out/cache/' && pass "stage ignores cache" || fail "stage ignores cache"

echo ""; echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
