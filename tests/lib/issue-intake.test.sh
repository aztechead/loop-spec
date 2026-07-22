#!/usr/bin/env bash
# Tests for lib/issue-intake.sh (fixture + dry-run — offline, no gh/claude)
set -uo pipefail

LIB="$(cd "$(dirname "$0")/../.." && pwd)/lib/issue-intake.sh"
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

WORK="${TMPDIR:-/tmp}/loop-spec-issue-intake.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

FIXTURE="$WORK/issues.json"
cat > "$FIXTURE" << 'EOF'
[
  {"number": 10, "title": "Add rate limiting", "body": "Public API needs rate limits.", "labels": [{"name": "loop-spec"}]},
  {"number": 11, "title": "Already claimed", "body": "x", "labels": [{"name": "loop-spec"}, {"name": "loop-spec:in-progress"}]},
  {"number": 12, "title": "Already done", "body": "y", "labels": [{"name": "loop-spec"}, {"name": "loop-spec:done"}]},
  {"number": 13, "title": "Second eligible", "body": "z", "labels": [{"name": "loop-spec"}]}
]
EOF

# ── Case 1: dry-run plans only eligible issues, respects limit=1 ──────────────
out="$(bash "$LIB" run --fixture "$FIXTURE" --dry-run)"
check "1: plans issue 10" "1" "$(grep -c 'DRY-RUN issue #10' <<<"$out")"
check "1: limit 1 excludes issue 13" "0" "$(grep -c 'issue #13' <<<"$out")"
check "1: lifecycle-labeled 11 skipped" "0" "$(grep -c 'issue #11' <<<"$out")"
check "1: done-labeled 12 skipped" "0" "$(grep -c 'issue #12' <<<"$out")"
check "1: plan includes intake invocation" "1" "$(grep -c 'loop-spec:intake autonomous' <<<"$out")"
check "1: plan includes claim label step" "1" "$(grep -c 'add-label loop-spec:in-progress' <<<"$out")"
check "1: plan includes result contract read" "1" "$(grep -c 'last-result.json' <<<"$out")"

# ── Case 2: --limit 2 plans both eligible issues ──────────────────────────────
out="$(bash "$LIB" run --fixture "$FIXTURE" --dry-run --limit 2)"
check "2: plans issue 10" "1" "$(grep -c 'DRY-RUN issue #10' <<<"$out")"
check "2: plans issue 13" "1" "$(grep -c 'DRY-RUN issue #13' <<<"$out")"

# ── Case 3: all-claimed fixture → zero eligible, exit 0 ───────────────────────
cat > "$WORK/claimed.json" << 'EOF'
[{"number": 20, "title": "t", "body": "b", "labels": [{"name": "loop-spec"}, {"name": "loop-spec:failed"}]}]
EOF
ec=0
out="$(bash "$LIB" run --fixture "$WORK/claimed.json" --dry-run)" || ec=$?
check "3: exit 0" "0" "$ec"
check "3: reports none eligible" "1" "$(grep -c 'no eligible' <<<"$out")"

# ── Case 4: bad invocations ───────────────────────────────────────────────────
ec=0; bash "$LIB" bogus >/dev/null 2>&1 || ec=$?
check "4: unknown subcommand exit 2" "2" "$ec"
ec=0; bash "$LIB" run --fixture "$WORK/nope.json" --dry-run >/dev/null 2>&1 || ec=$?
check "4: missing fixture exit 2" "2" "$ec"
ec=0; bash "$LIB" run --fixture "$FIXTURE" --limit abc --dry-run >/dev/null 2>&1 || ec=$?
check "4: non-numeric limit exit 2" "2" "$ec"
echo 'not json' > "$WORK/bad.json"
ec=0; bash "$LIB" run --fixture "$WORK/bad.json" --dry-run >/dev/null 2>&1 || ec=$?
check "4: corrupt fixture exit 2" "2" "$ec"

# ── Case 5: custom claude flags surface in the dry-run plan ───────────────────
out="$(LOOP_SPEC_ISSUE_INTAKE_CLAUDE_FLAGS="--permission-mode plan" bash "$LIB" run --fixture "$FIXTURE" --dry-run)"
check "5: custom flags in plan" "1" "$(grep -c -- '--permission-mode plan' <<<"$out")"

# ── Case 6: pi harness dispatches pi --mode json with /skill: prefix, no
#            claude-only permission flags ─────────────────────────────────────
out="$(LOOP_SPEC_HARNESS=pi bash "$LIB" run --fixture "$FIXTURE" --dry-run)"
check "6: pi CLI in plan" "1" "$(grep -c -- 'pi --mode json' <<<"$out")"
check "6: /skill:intake prefix" "1" "$(grep -c -- '/skill:intake autonomous' <<<"$out")"
check "6: no permission-mode default" "0" "$(grep -c -- '--permission-mode' <<<"$out")"

# claude harness keeps the original shape
out="$(LOOP_SPEC_HARNESS=claude bash "$LIB" run --fixture "$FIXTURE" --dry-run)"
check "6b: claude -p in plan" "1" "$(grep -c -- 'claude -p' <<<"$out")"
check "6b: /loop-spec:intake prefix" "1" "$(grep -c -- '/loop-spec:intake autonomous' <<<"$out")"

# Case 7: live linked-worktree runs clear and read the control-checkout pointer.
mkdir -p "$WORK/shims"
cat > "$WORK/shims/gh" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_GH_LOG:?}"
exit 0
SHIM
cat > "$WORK/shims/claude" <<'SHIM'
#!/usr/bin/env bash
printf 'called\n' >> "${FAKE_CLAUDE_LOG:?}"
exit 0
SHIM
chmod +x "$WORK/shims/gh" "$WORK/shims/claude"
CONTROL="$WORK/control"
LINKED="$WORK/linked"
mkdir -p "$CONTROL"
git -C "$CONTROL" init -q
git -C "$CONTROL" -c user.name=Test -c user.email=test@example.com commit --allow-empty -qm init
git -C "$CONTROL" worktree add -q -b linked "$LINKED"
mkdir -p "$CONTROL/.loop-spec"
printf '{"status":"completed","prUrl":"https://example/stale"}\n' > "$CONTROL/.loop-spec/last-result.json"
GH_LOG="$WORK/gh.log"; CLAUDE_LOG="$WORK/claude.log"; : > "$GH_LOG"; : > "$CLAUDE_LOG"
ec=0
(cd "$LINKED" && PATH="$WORK/shims:$PATH" LOOP_SPEC_HARNESS=claude \
  FAKE_GH_LOG="$GH_LOG" FAKE_CLAUDE_LOG="$CLAUDE_LOG" \
  bash "$LIB" run --fixture "$FIXTURE" --limit 1 >/dev/null) || ec=$?
check "7: missing current result fails issue" "1" "$ec"
check "7: stale control pointer cleared" "0" "$([[ -f "$CONTROL/.loop-spec/last-result.json" ]] && echo 1 || echo 0)"
check "7: agent invoked once" "1" "$(wc -l < "$CLAUDE_LOG" | tr -d ' ')"
check "7: failed lifecycle label recorded" "1" "$(grep -c -- 'loop-spec:failed' "$GH_LOG" || true)"

# Case 8: unsafe result roots fail without following the symlink or invoking the agent.
UNSAFE="$WORK/unsafe"
EXTERNAL="$WORK/external"
mkdir -p "$UNSAFE" "$EXTERNAL"
stale_external='{"status":"completed","prUrl":"https://example/stale-external"}'
printf '%s\n' "$stale_external" > "$EXTERNAL/last-result.json"
ln -s "$EXTERNAL" "$UNSAFE/.loop-spec"
: > "$GH_LOG"; : > "$CLAUDE_LOG"; ec=0
(cd "$UNSAFE" && PATH="$WORK/shims:$PATH" LOOP_SPEC_HARNESS=claude \
  FAKE_GH_LOG="$GH_LOG" FAKE_CLAUDE_LOG="$CLAUDE_LOG" \
  bash "$LIB" run --fixture "$FIXTURE" --limit 1 >/dev/null 2>&1) || ec=$?
check "8: unsafe pointer fails issue" "1" "$ec"
check "8: external pointer preserved" "$stale_external" "$(<"$EXTERNAL/last-result.json")"
check "8: unsafe run does not invoke agent" "0" "$(wc -l < "$CLAUDE_LOG" | tr -d ' ')"
check "8: failure report does not attribute stale PR" "0" \
  "$(grep -c -- 'stale-external' "$GH_LOG" || true)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
