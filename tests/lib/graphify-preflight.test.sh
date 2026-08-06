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

# check: missing -> degrade by default. The graph serves the ripple layer only;
# structural lookups have other answers, so an absent graph must not end the run.
rc=0; deg_err="$(GRAPHIFY_BIN="$WORK/nope-graphify" bash "$SCRIPT" check 2>&1 >/dev/null)" || rc=$?
[[ "$rc" -eq 0 ]] && pass "check degrades (exit 0) when missing" || fail "check degrades when missing (rc=$rc)"
echo "$deg_err" | grep -q "ripple layer degraded" && pass "degradation names the layer lost" || fail "degradation names the layer lost"
echo "$deg_err" | grep -q "LOOP_SPEC_REQUIRE_GRAPHIFY=1" && pass "degradation names the escalation switch" || fail "degradation names the escalation switch"

# check: missing + explicitly required -> exit 1 + install hint on stderr
err="$(LOOP_SPEC_REQUIRE_GRAPHIFY=1 GRAPHIFY_BIN="$WORK/nope-graphify" bash "$SCRIPT" check 2>&1 >/dev/null || true)"
rc=0; LOOP_SPEC_REQUIRE_GRAPHIFY=1 GRAPHIFY_BIN="$WORK/nope-graphify" bash "$SCRIPT" check >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 1 ]] && pass "check fails (exit 1) when missing and required" || fail "check fails when missing and required (rc=$rc)"
echo "$err" | grep -q "uv tool install graphifyy" && pass "install hint shown" || fail "install hint shown"
pi_err="$(LOOP_SPEC_REQUIRE_GRAPHIFY=1 LOOP_SPEC_HARNESS=pi GRAPHIFY_BIN="$WORK/nope-graphify" bash "$SCRIPT" check 2>&1 >/dev/null || true)"
echo "$pi_err" | grep -q 'graphify install --platform pi' && pass "pi registration hint shown" || fail "pi registration hint shown"
oc_err="$(LOOP_SPEC_REQUIRE_GRAPHIFY=1 LOOP_SPEC_HARNESS=opencode GRAPHIFY_BIN="$WORK/nope-graphify" bash "$SCRIPT" check 2>&1 >/dev/null || true)"
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

# localize: graph output stays useful locally but is never staged in a feature PR.
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
printf '%s\n' '{"nodes":[{"id":"old","label":"Old Graph"}],"links":[]}' > "$REPO/graphify-out/graph.json"
git -C "$REPO" add graphify-out
git -C "$REPO" commit -qm initial
printf '%s\n' '{"nodes":[{"id":"example","label":"Example Service"}],"links":[]}' > "$REPO/graphify-out/graph.json"
printf '%s\n' '# Graph report' > "$REPO/graphify-out/GRAPH_REPORT.md"
printf '%s\n' '{}' > "$REPO/graphify-out/manifest.json"
printf '%s\n' '<html></html>' > "$REPO/graphify-out/graph.html"
printf '%s\n' local > "$REPO/graphify-out/.graphify_python"
printf '%s\n' '{}' > "$REPO/graphify-out/.graphify_analysis.json"
printf '%s\n' local > "$REPO/graphify-out/cache/new-local.json"
git -C "$REPO" add graphify-out/graph.json
printf '%s\n' staged > "$REPO/other.txt"
git -C "$REPO" add other.txt
bash "$SCRIPT" localize "$REPO"
staged="$(git -C "$REPO" diff --cached --name-only)"
[[ "$staged" == "other.txt" ]] && pass "localize leaves unrelated staged work alone" || fail "localize leaves unrelated staged work alone ($staged)"
if echo "$staged" | grep -q 'graphify-out/'; then
  fail "localize stages no graph output"
else
  pass "localize stages no graph output"
fi
[[ -s "$REPO/graphify-out/graph.json" ]] && pass "local graph remains queryable" || fail "local graph remains queryable"
ignored="$(git -C "$REPO" status --short --ignored)"
echo "$ignored" | grep -q '!! graphify-out/.graphify_python' && pass "stage ignores machine interpreter" || fail "stage ignores machine interpreter"
echo "$ignored" | grep -q '!! graphify-out/cache/new-local.json' && pass "localize ignores new cache output" || fail "localize ignores new cache output"
echo "$ignored" | grep -q '!! graphify-out/.graphify_analysis.json' && pass "localize ignores generated graph sidecars" || fail "localize ignores generated graph sidecars"

# stage: linked worktrees must use the common repository's info/exclude path
LINKED="$WORK/linked"
git -C "$REPO" worktree add -q -b linked "$LINKED"
rc=0; bash "$SCRIPT" localize "$LINKED" >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 0 ]] && pass "localize works in linked worktree" || fail "localize works in linked worktree (rc=$rc)"
linked_exclude="$(git -C "$LINKED" rev-parse --path-format=absolute --git-path info/exclude)"
grep -q '# loop-spec managed local artifacts' "$linked_exclude" && pass "linked worktree uses common exclude" || fail "linked worktree uses common exclude"

# A normal feature commit cannot sweep the generated graph into its diff.
git -C "$REPO" commit -qm feature
if git -C "$REPO" diff HEAD~1 --name-only | grep -q 'graphify-out/'; then
  fail "feature commit excludes graphify output"
else
  pass "feature commit excludes graphify output"
fi

# A valid graph is reusable only with a matching source snapshot. The local
# stamp is intentionally stricter than graph-status: a missing/corrupt stamp or
# any tracked source edit returns stale and forces the assistant lifecycle.
bash "$SCRIPT" stamp "$REPO"
[[ "$(bash "$SCRIPT" freshness "$REPO")" == "fresh" ]] \
  && pass "matching source stamp is fresh" || fail "matching source stamp is fresh"
printf 'changed\n' >> "$REPO/other.txt"
[[ "$(bash "$SCRIPT" freshness "$REPO")" == "stale" ]] \
  && pass "tracked source change invalidates stamp" || fail "tracked source change invalidates stamp"
git -C "$REPO" restore other.txt
printf 'not-json\n' > "$REPO/graphify-out/.loop-spec-source-fingerprint.json"
[[ "$(bash "$SCRIPT" freshness "$REPO")" == "stale" ]] \
  && pass "corrupt stamp never reuses graph" || fail "corrupt stamp never reuses graph"
bash "$SCRIPT" stamp "$REPO"
[[ "$(bash "$SCRIPT" freshness "$REPO")" == "fresh" ]] \
  && pass "restamped clean graph is fresh" || fail "restamped clean graph is fresh"

# Explicit maintenance publishing is the inverse of feature localize: it re-enables
# graph paths and stages portable generated output for its own review, never cache.
bash "$SCRIPT" publish "$REPO"
published="$(git -C "$REPO" diff --cached --name-only)"
echo "$published" | grep -q 'graphify-out/graph.json' && pass "publish stages graph for maintenance review" || fail "publish stages graph for maintenance review"
if echo "$published" | grep -q 'graphify-out/cache/'; then
  fail "publish excludes cache"
else
  pass "publish excludes cache"
fi

echo ""; echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
