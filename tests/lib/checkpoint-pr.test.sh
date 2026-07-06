#!/usr/bin/env bash
# Tests for lib/checkpoint-pr.sh
set -uo pipefail

LIB="$(cd "$(dirname "$0")/../.." && pwd)/lib/checkpoint-pr.sh"
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

# ── Test rig setup ────────────────────────────────────────────────────────────
WORK="${TMPDIR:-/tmp}/loop-spec-checkpoint-pr.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

# Real git repo
git init -q "$WORK/repo"
git -C "$WORK/repo" config user.email t@t
git -C "$WORK/repo" config user.name t
echo x > "$WORK/repo/a"
git -C "$WORK/repo" add a
git -C "$WORK/repo" commit -q -m init
DEFAULT_BRANCH=$(git -C "$WORK/repo" rev-parse --abbrev-ref HEAD)

# Bare repo as origin
git init --bare -q "$WORK/bare"
git -C "$WORK/repo" remote add origin "$WORK/bare"

# Feature branch with a commit (so there is something to push)
git -C "$WORK/repo" checkout -q -b feat/my-feature
echo y > "$WORK/repo/b"
git -C "$WORK/repo" add b
git -C "$WORK/repo" commit -q -m "feature work"
# Return to default branch so we exercise the explicit-ref push path
git -C "$WORK/repo" checkout -q "$DEFAULT_BRANCH"

REPO="$WORK/repo"

# gh shim — records its argv; env-controlled behavior:
#   SHIM_GH_PR_EXISTS=1  → pr list prints an existing PR URL
#   SHIM_GH_LOG=<file>   → pr create args are appended to that file
SHIMS="$WORK/shims"
mkdir -p "$SHIMS"
cat > "$SHIMS/gh" << 'GHSHIM'
#!/usr/bin/env bash
SHIM_LOG="${SHIM_GH_LOG:-/dev/null}"
subcmd="${1:-}"; sub2="${2:-}"
if [[ "$subcmd" == "pr" && "$sub2" == "list" ]]; then
  if [[ "${SHIM_GH_PR_EXISTS:-0}" == "1" ]]; then
    printf 'https://github.com/test/repo/pull/99\n'
  fi
  exit 0
fi
if [[ "$subcmd" == "pr" && "$sub2" == "create" ]]; then
  printf '%s\n' "pr create $*" >> "$SHIM_LOG"
  printf 'https://github.com/test/repo/pull/1\n'
  exit 0
fi
printf 'gh shim: unhandled: %s\n' "$*" >&2
exit 1
GHSHIM
chmod +x "$SHIMS/gh"

# Build a PATH that has git and jq but no gh (for case 6)
# We symlink the required binaries into a private dir so the test works even
# when system gh lives in the same bin directory as jq/git.
NOGH_BIN="$WORK/nogh-bin"
mkdir -p "$NOGH_BIN"
ln -sf "$(command -v git)" "$NOGH_BIN/git"
ln -sf "$(command -v jq)"  "$NOGH_BIN/jq"
ln -sf "$(command -v bash)" "$NOGH_BIN/bash"
NOGH_PATH="$NOGH_BIN:/usr/bin:/bin"

# Feature dir + fixture
FEAT_DIR="$REPO/.loop-spec/features/my-feature"
mkdir -p "$FEAT_DIR"

FIXTURE_FJ="$(jq -n '{
  schemaVersion: 7,
  slug: "my-feature",
  feature_title: "My Feature",
  currentPhase: "execute",
  branch: "feat/my-feature",
  baseBranch: "main",
  prUrl: null,
  checkpointPrUrl: null,
  autonomous: false,
  createdAt: "2026-01-01T00:00:00Z",
  updatedAt: "2026-01-01T01:00:00Z",
  warnings: []
}')"
printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"

# ── Helper: reset fixture to baseline ────────────────────────────────────────
reset_fixture() {
  printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"
  rm -f "$FEAT_DIR/events.jsonl"
}

# ── Case 1: LOOP_SPEC_CHECKPOINT_PR=0 → disabled, no push ────────────────────
reset_fixture
ec=0
out=$(LOOP_SPEC_CHECKPOINT_PR=0 bash "$LIB" create "$FEAT_DIR" 2>&1) || ec=$?
check "1: disabled exit 0" "0" "$ec"
check "1: disabled message" "1" "$([[ "$out" == *"disabled"* ]] && echo 1 || echo 0)"
check "1: no push (branch absent from bare)" \
  "0" "$(git -C "$WORK/bare" rev-parse --verify refs/heads/feat/my-feature >/dev/null 2>&1 && echo 1 || echo 0)"

# ── Case 2: Non-autonomous + env unset → skipped ─────────────────────────────
reset_fixture
ec=0
out=$( (cd "$REPO"; env -u LOOP_SPEC_CHECKPOINT_PR bash "$LIB" create "$FEAT_DIR") 2>&1 ) || ec=$?
check "2: non-auto exit 0" "0" "$ec"
check "2: skip message contains 'interactive run'" \
  "1" "$([[ "$out" == *"skipped (interactive run"* ]] && echo 1 || echo 0)"
check "2: no push" \
  "0" "$(git -C "$WORK/bare" rev-parse --verify refs/heads/feat/my-feature >/dev/null 2>&1 && echo 1 || echo 0)"

# ── Case 3: autonomous:true + env unset → gating passes ──────────────────────
# (gh not in NOGH_PATH so it exits on that precondition, not on the gating check)
reset_fixture
printf '%s\n' "$(jq '.autonomous = true' "$FEAT_DIR/feature.json")" > "$FEAT_DIR/feature.json"
ec=0
out=$( (cd "$REPO"; env -u LOOP_SPEC_CHECKPOINT_PR PATH="$NOGH_PATH" bash "$LIB" create "$FEAT_DIR") 2>&1 ) || ec=$?
check "3: exit 0" "0" "$ec"
check "3: gating passed (not interactive-skip)" \
  "0" "$([[ "$out" == *"skipped (interactive run"* ]] && echo 1 || echo 0)"
check "3: stopped at gh precondition" \
  "1" "$([[ "$out" == *"'gh' not on PATH"* ]] && echo 1 || echo 0)"
reset_fixture

# ── Case 4: Happy path (LOOP_SPEC_CHECKPOINT_PR=1) ───────────────────────────
reset_fixture
GH_LOG4="$WORK/gh-case4.log"
ec=0
out=$( (cd "$REPO"; PATH="$SHIMS:$PATH" LOOP_SPEC_CHECKPOINT_PR=1 SHIM_GH_LOG="$GH_LOG4" \
  bash "$LIB" create "$FEAT_DIR" --reason "test escalation") 2>&1 ) || ec=$?
check "4: exit 0" "0" "$ec"
check "4: branch pushed to bare" \
  "1" "$(git -C "$WORK/bare" rev-parse --verify refs/heads/feat/my-feature >/dev/null 2>&1 && echo 1 || echo 0)"
check "4: gh shim saw pr create --draft" \
  "1" "$([[ -f "$GH_LOG4" ]] && grep -q -- "--draft" "$GH_LOG4" && echo 1 || echo 0)"
check "4: feature.json has checkpointPrUrl" \
  "https://github.com/test/repo/pull/1" \
  "$(jq -r '.checkpointPrUrl // empty' "$FEAT_DIR/feature.json" 2>/dev/null)"
check "4: events.jsonl has checkpoint_pr event" \
  "checkpoint_pr" \
  "$(jq -r '.event // empty' "$FEAT_DIR/events.jsonl" 2>/dev/null | tail -1)"
check "4: events.jsonl checkpoint_pr data.url" \
  "https://github.com/test/repo/pull/1" \
  "$(jq -r '.data.url // empty' "$FEAT_DIR/events.jsonl" 2>/dev/null | tail -1)"
check "4: output contains draft PR url" \
  "1" "$([[ "$out" == *"https://github.com/test/repo/pull/1"* ]] && echo 1 || echo 0)"

# ── Case 5: Idempotency — existing open PR reused ────────────────────────────
reset_fixture
GH_LOG5="$WORK/gh-case5.log"
ec=0
out=$( (cd "$REPO"; PATH="$SHIMS:$PATH" LOOP_SPEC_CHECKPOINT_PR=1 \
  SHIM_GH_PR_EXISTS=1 SHIM_GH_LOG="$GH_LOG5" \
  bash "$LIB" create "$FEAT_DIR") 2>&1 ) || ec=$?
check "5: exit 0" "0" "$ec"
check "5: no pr create call" \
  "0" "$([[ -f "$GH_LOG5" ]] && grep -q "pr create" "$GH_LOG5" && echo 1 || echo 0)"
check "5: existing URL persisted in feature.json" \
  "https://github.com/test/repo/pull/99" \
  "$(jq -r '.checkpointPrUrl // empty' "$FEAT_DIR/feature.json" 2>/dev/null)"
check "5: output says existing PR" \
  "1" "$([[ "$out" == *"existing PR"* ]] && echo 1 || echo 0)"

# ── Case 6: No gh on PATH → exit 0, warn ─────────────────────────────────────
reset_fixture
ec=0
out=$( (cd "$REPO"; LOOP_SPEC_CHECKPOINT_PR=1 PATH="$NOGH_PATH" \
  bash "$LIB" create "$FEAT_DIR") 2>&1 ) || ec=$?
check "6: exit 0 with no gh" "0" "$ec"
check "6: warns about missing gh" \
  "1" "$([[ "$out" == *"'gh' not on PATH"* ]] && echo 1 || echo 0)"

# ── Case 7: Missing feature.json → exit 0, warn ──────────────────────────────
mkdir -p "$WORK/empty-feat"
rm -f "$WORK/empty-feat/feature.json"
ec=0
out=$(LOOP_SPEC_CHECKPOINT_PR=1 bash "$LIB" create "$WORK/empty-feat" 2>&1) || ec=$?
check "7: missing feature.json exits 0" "0" "$ec"
check "7: warns about missing feature.json" \
  "1" "$([[ "$out" == *"feature.json not found"* ]] && echo 1 || echo 0)"

# ── Case 8: Workspace-style feature.json (branch: null) → exit 0, skip ───────
reset_fixture
printf '%s\n' "$(jq '.branch = null' "$FEAT_DIR/feature.json")" > "$FEAT_DIR/feature.json"
ec=0
out=$(LOOP_SPEC_CHECKPOINT_PR=1 bash "$LIB" create "$FEAT_DIR" 2>&1) || ec=$?
check "8: workspace null branch exits 0" "0" "$ec"
check "8: skip message mentions workspace" \
  "1" "$([[ "$out" == *"workspace mode"* ]] && echo 1 || echo 0)"
reset_fixture

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
