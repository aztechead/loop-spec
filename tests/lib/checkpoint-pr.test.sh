#!/usr/bin/env bash
# Tests for lib/checkpoint-pr.sh
set -uo pipefail

LIB="$(cd "$(dirname "$0")/../.." && pwd)/lib/checkpoint-pr.sh"
REAL_GIT="$(command -v git)"
export REAL_GIT
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
# The remote names a host (what gh needs); insteadOf carries the push to the bare repo.
git -C "$WORK/repo" remote add origin https://github.com/test/repo.git
git -C "$WORK/repo" config url."$WORK/bare".insteadOf https://github.com/test/repo.git

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
[[ -z "${SHIM_GH_CALL_LOG:-}" ]] || printf '%s\n' "$*" >> "$SHIM_GH_CALL_LOG"
if [[ "$subcmd" == "pr" && "$sub2" == "list" ]]; then
  if [[ "${SHIM_GH_LIST_AUTH_ONCE:-0}" == "1" && ! -f "${SHIM_GH_LIST_AUTH_MARKER:?}" ]]; then
    : > "$SHIM_GH_LIST_AUTH_MARKER"
    echo "HTTP 401: Bad credentials" >&2
    exit 1
  fi
  if [[ -n "${SHIM_GH_STATE:-}" && -s "$SHIM_GH_STATE" ]]; then
    cat "$SHIM_GH_STATE"
    exit 0
  fi
  if [[ "${SHIM_GH_PR_EXISTS:-0}" == "1" ]]; then
    printf 'https://github.com/test/repo/pull/99\n'
  fi
  exit 0
fi
if [[ "$subcmd" == "pr" && "$sub2" == "create" ]]; then
  printf '%s\n' "pr create $*" >> "$SHIM_LOG"
  if [[ "${SHIM_GH_CREATE_APPLIED_AUTH:-0}" == "1" ]]; then
    printf 'https://github.com/test/repo/pull/7\n' > "${SHIM_GH_STATE:?}"
    echo "HTTP 403: response lost after create" >&2
    exit 1
  fi
  printf 'https://github.com/test/repo/pull/1\n'
  exit 0
fi
printf 'gh shim: unhandled: %s\n' "$*" >&2
exit 1
GHSHIM
chmod +x "$SHIMS/gh"

cat > "$SHIMS/git" <<'GITSHIM'
#!/usr/bin/env bash
set -uo pipefail
if [[ " $* " == *" push "* && "${SHIM_GIT_AUTH_ONCE:-0}" == "1" ]]; then
  count=0
  [[ ! -f "${SHIM_GIT_COUNT:?}" ]] || count="$(<"$SHIM_GIT_COUNT")"
  count=$((count + 1))
  printf '%s\n' "$count" > "$SHIM_GIT_COUNT"
  if [[ "$count" -eq 1 ]]; then
    echo "remote: HTTP 401: Bad credentials" >&2
    exit 128
  fi
  [[ "${GH_TOKEN:-}" == "checkpoint-refreshed-token" ]] \
    || { echo "remote: HTTP 403: stale token" >&2; exit 128; }
fi
exec "${REAL_GIT:?}" "$@"
GITSHIM
chmod +x "$SHIMS/git"

REFRESH_LOG="$WORK/refresh.log"
REFRESH_HOOK="$WORK/checkpoint-refresh.sh"
cat > "$REFRESH_HOOK" <<'REFRESH'
#!/usr/bin/env bash
set -uo pipefail
printf '%s|%s|%s|%s\n' "$LOOP_SPEC_CREDENTIAL_REFRESH_STAGE" \
  "$LOOP_SPEC_CREDENTIAL_REFRESH_REASON" "$LOOP_SPEC_CREDENTIAL_REFRESH_HOST" "$PWD" \
  >> "${SHIM_REFRESH_LOG:?}"
if [[ "$LOOP_SPEC_CREDENTIAL_REFRESH_REASON" == "auth-retry" ]]; then
  printf '{"GH_TOKEN":"checkpoint-refreshed-token"}\n'
else
  printf '{"GH_TOKEN":"checkpoint-initial-token"}\n'
fi
REFRESH
chmod +x "$REFRESH_HOOK"

# Build a PATH that has everything the script touches before its gh probe, but
# no gh (for cases 2, 3, 6). The private dir is the WHOLE path: re-appending
# /usr/bin would silently reintroduce gh on hosts that install it there, and the
# three gh-precondition checks would pass the probe they exist to stop at.
NOGH_BIN="$WORK/nogh-bin"
mkdir -p "$NOGH_BIN"
ln -sf "$(command -v git)" "$NOGH_BIN/git"
ln -sf "$(command -v jq)"  "$NOGH_BIN/jq"
# A version-manager shim needs tools excluded from this PATH; use its interpreter.
ln -sf "$(python3 -c 'import sys; print(sys.executable)')" "$NOGH_BIN/python3"
ln -sf "$(command -v bash)" "$NOGH_BIN/bash"
ln -sf "$(command -v dirname)" "$NOGH_BIN/dirname"
for tool in cat tr grep sed awk mktemp rm tail; do
  ln -sf "$(command -v "$tool")" "$NOGH_BIN/$tool"
done
NOGH_PATH="$NOGH_BIN"

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

run_checkpoint_with_refresh() {
  (cd "$REPO" && PATH="$SHIMS:$PATH" LOOP_SPEC_CHECKPOINT_PR=1 \
    SHIM_REFRESH_LOG="$REFRESH_LOG" LOOP_SPEC_CREDENTIAL_REFRESH_CMD="$REFRESH_HOOK" \
    bash "$LIB" create "$FEAT_DIR" "$@")
}

# ── Case 1: LOOP_SPEC_CHECKPOINT_PR=0 → disabled, no push ────────────────────
reset_fixture
ec=0
out=$(LOOP_SPEC_CHECKPOINT_PR=0 bash "$LIB" create "$FEAT_DIR" 2>&1) || ec=$?
check "1: disabled exit 0" "0" "$ec"
check "1: disabled message" "1" "$([[ "$out" == *"disabled"* ]] && echo 1 || echo 0)"
check "1: no push (branch absent from bare)" \
  "0" "$(git -C "$WORK/bare" rev-parse --verify refs/heads/feat/my-feature >/dev/null 2>&1 && echo 1 || echo 0)"

# ── Case 2: Non-autonomous + env unset → default-on (gating passes) ──────────
# (gh not in NOGH_PATH; branch/state push must still complete before the skip)
reset_fixture
ec=0
out=$( (cd "$REPO"; env -u LOOP_SPEC_CHECKPOINT_PR PATH="$NOGH_PATH" bash "$LIB" create "$FEAT_DIR") 2>&1 ) || ec=$?
check "2: non-auto exit 0" "0" "$ec"
check "2: gating passed (no interactive-skip)" \
  "0" "$([[ "$out" == *"skipped (interactive run"* ]] && echo 1 || echo 0)"
check "2: stopped after push at gh precondition" \
  "1" "$([[ "$out" == *"'gh' not on PATH"* ]] && echo 1 || echo 0)"

# ── Case 3: autonomous:true + env unset → gating passes ──────────────────────
# (gh not in NOGH_PATH; branch/state push must still complete)
reset_fixture
printf '%s\n' "$(jq '.autonomous = true' "$FEAT_DIR/feature.json")" > "$FEAT_DIR/feature.json"
git -C "$REPO" update-ref refs/loop-spec/state/my-feature "$(git -C "$REPO" rev-parse feat/my-feature)"
ec=0
out=$( (cd "$REPO"; env -u LOOP_SPEC_CHECKPOINT_PR PATH="$NOGH_PATH" bash "$LIB" create "$FEAT_DIR") 2>&1 ) || ec=$?
check "3: exit 0" "0" "$ec"
check "3: gating passed (not interactive-skip)" \
  "0" "$([[ "$out" == *"skipped (interactive run"* ]] && echo 1 || echo 0)"
check "3: stopped after push at gh precondition" \
  "1" "$([[ "$out" == *"'gh' not on PATH"* ]] && echo 1 || echo 0)"
check "3: branch SHA matches without gh" \
  "$(git -C "$REPO" rev-parse feat/my-feature)" "$(git -C "$WORK/bare" rev-parse refs/heads/feat/my-feature)"
check "3: state ref pushed without gh" \
  "1" "$(git -C "$WORK/bare" rev-parse --verify refs/loop-spec/state/my-feature >/dev/null 2>&1 && echo 1 || echo 0)"
check "3: state SHA matches without gh" \
  "$(git -C "$REPO" rev-parse refs/loop-spec/state/my-feature)" "$(git -C "$WORK/bare" rev-parse refs/loop-spec/state/my-feature)"
reset_fixture

# ── Case 3b: origin names no host → pushed, PR step skipped, gh never asked ──
# (the 6.6.3 FastAPI run reported "gh pr list failed" against a bare-path origin)
reset_fixture
git -C "$REPO" remote set-url origin "$WORK/bare"
GH_LOG3B="$WORK/gh-case3b.log"
ec=0
out=$( (cd "$REPO"; PATH="$SHIMS:$PATH" LOOP_SPEC_CHECKPOINT_PR=1 SHIM_GH_LOG="$GH_LOG3B" \
  bash "$LIB" create "$FEAT_DIR") 2>&1 ) || ec=$?
check "3b: exit 0" "0" "$ec"
check "3b: branch pushed to bare" \
  "1" "$(git -C "$WORK/bare" rev-parse --verify refs/heads/feat/my-feature >/dev/null 2>&1 && echo 1 || echo 0)"
check "3b: the skip names the reason" "1" "$([[ "$out" == *"remote URL names no host"* ]] && echo 1 || echo 0)"
check "3b: gh never asked to create a PR" "0" "$([[ -f "$GH_LOG3B" ]] && grep -c 'pr create' "$GH_LOG3B" || echo 0)"
git -C "$REPO" remote set-url origin https://github.com/test/repo.git
git -C "$WORK/bare" branch -D feat/my-feature >/dev/null 2>&1 || true

# ── Case 4: Happy path (LOOP_SPEC_CHECKPOINT_PR=1) ───────────────────────────
reset_fixture
GH_LOG4="$WORK/gh-case4.log"
# An escalated run's BLOCKED verification rows ride in the PR body.
mkdir -p "$REPO/docs/loop-spec/features/my-feature"
printf '# V\n\n## Acceptance criteria\n\n| # | Criterion | Status | Evidence |\n|---|---|---|---|\n| GE-001 | plan succeeds | BLOCKED | gcloud reauth needed |\n| GE-002 | fmt clean | PASS | ok |\n' > "$REPO/docs/loop-spec/features/my-feature/VERIFICATION.md"
ec=0
out=$( (cd "$REPO"; PATH="$SHIMS:$PATH" LOOP_SPEC_CHECKPOINT_PR=1 SHIM_GH_LOG="$GH_LOG4" \
  bash "$LIB" create "$FEAT_DIR" --reason "test escalation") 2>&1 ) || ec=$?
check "4: exit 0" "0" "$ec"
check "4: branch pushed to bare" \
  "1" "$(git -C "$WORK/bare" rev-parse --verify refs/heads/feat/my-feature >/dev/null 2>&1 && echo 1 || echo 0)"
check "4: gh shim saw pr create --draft" \
  "1" "$([[ -f "$GH_LOG4" ]] && grep -q -- "--draft" "$GH_LOG4" && echo 1 || echo 0)"
check "4: the PR body carries the BLOCKED row and not the PASS row" \
  "1,0" "$(grep -c 'GE-001 | plan succeeds | BLOCKED' "$GH_LOG4"),$(grep -c 'GE-002' "$GH_LOG4")"
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
check "4: pr create used the branch head (LOOP_SPEC_ARTIFACTS_IN_PR unset)" \
  "1" "$([[ -f "$GH_LOG4" ]] && grep -q -- "--head feat/my-feature" "$GH_LOG4" && echo 1 || echo 0)"

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

# ── Case 9: push auth expiry refreshes and retries once ───────────────────────
reset_fixture
: > "$REFRESH_LOG"; rm -f "$WORK/checkpoint-git-count"
ec=0
out="$(SHIM_GIT_AUTH_ONCE=1 SHIM_GIT_COUNT="$WORK/checkpoint-git-count" \
  SHIM_GH_PR_EXISTS=1 run_checkpoint_with_refresh 2>&1)" || ec=$?
check "9: push auth retry exits 0" "0" "$ec"
check "9: branch/state pushes include auth retry" "3" "$(<"$WORK/checkpoint-git-count")"
check "9: push auth refresh once" "1" "$(grep -c '^push|auth-retry|' "$REFRESH_LOG" || true)"
check "9: existing PR still persisted" "https://github.com/test/repo/pull/99" \
  "$(jq -r '.checkpointPrUrl // empty' "$FEAT_DIR/feature.json")"

# ── Case 10: PR list auth expiry refreshes and retries once ───────────────────
reset_fixture
: > "$REFRESH_LOG"; : > "$WORK/checkpoint-gh-calls"; rm -f "$WORK/list-auth-marker"
ec=0
out="$(SHIM_GH_LIST_AUTH_ONCE=1 SHIM_GH_LIST_AUTH_MARKER="$WORK/list-auth-marker" \
  SHIM_GH_CALL_LOG="$WORK/checkpoint-gh-calls" SHIM_GH_PR_EXISTS=1 \
  run_checkpoint_with_refresh 2>&1)" || ec=$?
check "10: list auth retry exits 0" "0" "$ec"
check "10: list attempted twice" "2" "$(grep -c '^pr list ' "$WORK/checkpoint-gh-calls" || true)"
check "10: list auth refresh once" "1" "$(grep -c '^github-pr|auth-retry|' "$REFRESH_LOG" || true)"
check "10: create not attempted" "0" "$(grep -c '^pr create ' "$WORK/checkpoint-gh-calls" || true)"

# ── Case 11: ambiguous create is re-listed, never duplicated ─────────────────
reset_fixture
: > "$REFRESH_LOG"; : > "$WORK/checkpoint-gh-calls"; : > "$WORK/create-state"
GH_LOG11="$WORK/gh-case11.log"; : > "$GH_LOG11"
ec=0
out="$(SHIM_GH_CREATE_APPLIED_AUTH=1 SHIM_GH_STATE="$WORK/create-state" \
  SHIM_GH_CALL_LOG="$WORK/checkpoint-gh-calls" SHIM_GH_LOG="$GH_LOG11" \
  run_checkpoint_with_refresh 2>&1)" || ec=$?
check "11: ambiguous create exits 0" "0" "$ec"
check "11: create attempted once" "1" "$(grep -c '^pr create ' "$WORK/checkpoint-gh-calls" || true)"
check "11: create re-listed" "2" "$(grep -c '^pr list ' "$WORK/checkpoint-gh-calls" || true)"
check "11: remote PR accepted" "https://github.com/test/repo/pull/7" \
  "$(jq -r '.checkpointPrUrl // empty' "$FEAT_DIR/feature.json")"
check "11: create auth refresh once" "1" "$(grep -c '^github-pr|auth-retry|' "$REFRESH_LOG" || true)"

# ── Case 12: LOOP_SPEC_ARTIFACTS_IN_PR=0 scrubs the checkpoint PR head too ───
reset_fixture
BASE_SHA="$(git -C "$WORK/repo" rev-parse "$DEFAULT_BRANCH")"
SCRUB_FEAT_DIR="$REPO/.loop-spec/features/scrubbed"
mkdir -p "$SCRUB_FEAT_DIR"
SCRUB_FIXTURE_FJ="$(jq -n --arg baseSha "$BASE_SHA" '{
  schemaVersion: 7,
  slug: "scrubbed",
  feature_title: "Scrubbed Feature",
  currentPhase: "execute",
  branch: "feat/scrubbed",
  baseBranch: "main",
  baseSha: $baseSha,
  prUrl: null,
  checkpointPrUrl: null,
  autonomous: false,
  createdAt: "2026-01-01T00:00:00Z",
  updatedAt: "2026-01-01T01:00:00Z",
  warnings: []
}')"
printf '%s\n' "$SCRUB_FIXTURE_FJ" > "$SCRUB_FEAT_DIR/feature.json"

git -C "$REPO" checkout -q -b feat/scrubbed "$DEFAULT_BRANCH"
mkdir -p "$REPO/src" "$REPO/docs/loop-spec/features/scrubbed"
echo "print('x')" > "$REPO/src/x.py"
echo "# spec" > "$REPO/docs/loop-spec/features/scrubbed/SPEC.md"
echo "# evidence" > "$REPO/docs/loop-spec/features/scrubbed/EVIDENCE.md"
git -C "$REPO" add src/x.py docs/loop-spec/features/scrubbed
git -C "$REPO" commit -q -m "scrubbed feature work"
git -C "$REPO" checkout -q "$DEFAULT_BRANCH"

GH_LOG12="$WORK/gh-case12.log"
ec=0
out=$( (cd "$REPO"; PATH="$SHIMS:$PATH" LOOP_SPEC_CHECKPOINT_PR=1 LOOP_SPEC_ARTIFACTS_IN_PR=0 \
  SHIM_GH_LOG="$GH_LOG12" bash "$LIB" create "$SCRUB_FEAT_DIR") 2>&1 ) || ec=$?
check "12: exit 0" "0" "$ec"
rc=0
git -C "$WORK/bare" rev-parse --verify -q refs/heads/feat/scrubbed-checkpoint >/dev/null 2>&1 || rc=$?
check "12: checkpoint ref exists in bare" "0" "$rc"
TREE_CKPT="$(git -C "$WORK/bare" ls-tree -r --name-only feat/scrubbed-checkpoint 2>/dev/null)"
check "12: checkpoint tree has src/x.py" \
  "1" "$(echo "$TREE_CKPT" | grep -qx 'src/x.py' && echo 1 || echo 0)"
check "12: checkpoint tree lacks SPEC.md" \
  "0" "$(echo "$TREE_CKPT" | grep -q 'docs/loop-spec/features/scrubbed/SPEC.md' && echo 1 || echo 0)"
TREE_BRANCH="$(git -C "$WORK/bare" ls-tree -r --name-only feat/scrubbed 2>/dev/null)"
check "12: feature branch still carries SPEC.md (pushed intact)" \
  "1" "$(echo "$TREE_BRANCH" | grep -q 'docs/loop-spec/features/scrubbed/SPEC.md' && echo 1 || echo 0)"
check "12: checkpoint commit parent is the feature branch tip" \
  "1" "$([[ "$(git -C "$REPO" rev-parse feat/scrubbed-checkpoint^)" == "$(git -C "$REPO" rev-parse feat/scrubbed)" ]] && echo 1 || echo 0)"
check "12: pr create used the checkpoint head" \
  "1" "$(grep -q -- "--head feat/scrubbed-checkpoint" "$GH_LOG12" && echo 1 || echo 0)"
check "12: pr body explains the scrub" \
  "1" "$(grep -q 'kept out of this PR' "$GH_LOG12" && echo 1 || echo 0)"

# Rebuild: a second checkpoint on new branch content force-pushes a fresh ref.
git -C "$REPO" checkout -q feat/scrubbed
echo "print('y')" > "$REPO/src/x.py"
git -C "$REPO" add src/x.py
git -C "$REPO" commit -q -m "scrubbed feature work v2"
git -C "$REPO" checkout -q "$DEFAULT_BRANCH"

ec=0
out=$( (cd "$REPO"; PATH="$SHIMS:$PATH" LOOP_SPEC_CHECKPOINT_PR=1 LOOP_SPEC_ARTIFACTS_IN_PR=0 \
  SHIM_GH_LOG="$GH_LOG12" bash "$LIB" create "$SCRUB_FEAT_DIR") 2>&1 ) || ec=$?
check "12: rebuild exit 0" "0" "$ec"
check "12: rebuilt checkpoint carries the new content" \
  "print('y')" "$(git -C "$WORK/bare" show feat/scrubbed-checkpoint:src/x.py 2>/dev/null)"
check "12: rebuilt checkpoint still lacks SPEC.md" \
  "0" "$(git -C "$WORK/bare" ls-tree -r --name-only feat/scrubbed-checkpoint 2>/dev/null | grep -c 'docs/loop-spec/features/scrubbed/SPEC.md')"

# ── Case 13: the scrub restores the docs dir to its base image, not to empty ────
reset_fixture
mkdir -p "$REPO/docs/loop-spec/features/based"
echo "# base readme" > "$REPO/docs/loop-spec/features/based/README.md"
git -C "$REPO" add docs/loop-spec/features/based
git -C "$REPO" commit -q -m "base carries a run document"
BASE13="$(git -C "$REPO" rev-parse "$DEFAULT_BRANCH")"
BASED_FEAT_DIR="$REPO/.loop-spec/features/based"
mkdir -p "$BASED_FEAT_DIR"
jq --arg baseSha "$BASE13" '.slug = "based" | .branch = "feat/based" | .baseSha = $baseSha' \
  <<<"$SCRUB_FIXTURE_FJ" > "$BASED_FEAT_DIR/feature.json"
git -C "$REPO" checkout -q -b feat/based "$DEFAULT_BRANCH"
echo "# edited on the branch" > "$REPO/docs/loop-spec/features/based/README.md"
echo "# spec" > "$REPO/docs/loop-spec/features/based/SPEC.md"
git -C "$REPO" add docs/loop-spec/features/based
git -C "$REPO" commit -q -m "based feature work"
git -C "$REPO" checkout -q "$DEFAULT_BRANCH"
ec=0
out=$( (cd "$REPO"; PATH="$SHIMS:$PATH" LOOP_SPEC_CHECKPOINT_PR=1 LOOP_SPEC_ARTIFACTS_IN_PR=0 \
  SHIM_GH_LOG="$WORK/gh-case13.log" bash "$LIB" create "$BASED_FEAT_DIR") 2>&1 ) || ec=$?
check "13: exit 0" "0" "$ec"
check "13: checkpoint keeps the base image of the docs dir" \
  "# base readme" "$(git -C "$WORK/bare" show feat/based-checkpoint:docs/loop-spec/features/based/README.md 2>/dev/null)"
check "13: checkpoint drops the branch-added SPEC.md" \
  "0" "$(git -C "$WORK/bare" ls-tree -r --name-only feat/based-checkpoint 2>/dev/null | grep -c 'features/based/SPEC.md')"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
