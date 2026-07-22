#!/usr/bin/env bash
# Tests for lib/cycle-result.sh
set -uo pipefail

LIB="$(cd "$(dirname "$0")/../.." && pwd)/lib/cycle-result.sh"
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

WORK="${TMPDIR:-/tmp}/loop-spec-cycle-result.$$"
trap 'rm -rf "$WORK"' EXIT

# Build a minimal feature.json fixture shaped like .loop-spec/features/<slug>/
# (two levels deep so ../../ resolves to $WORK/.loop-spec)
LOOP_DIR="$WORK/.loop-spec"
FEAT_DIR="$LOOP_DIR/features/my-feature"
mkdir -p "$FEAT_DIR"

FIXTURE_FJ="$(jq -n '{
  schemaVersion: 7,
  slug: "my-feature",
  feature_title: "Add rate limiting",
  currentPhase: "completed",
  branch: "feat/my-feature",
  baseBranch: "main",
  prUrl: "https://github.com/test/repo/pull/1",
  checkpointPrUrl: null,
  delivery: {status:"ready-for-review",attemptedAt:"2026-01-01T01:00:00Z",
    finishedAt:"2026-01-01T01:05:00Z",targets:[{name:"my-feature",ok:true,
      outcome:"delivered",targetSha:"abc",remoteSha:"abc",headSha:"abc",
      prUrl:"https://github.com/test/repo/pull/1",checks:{status:"passed"}}]},
  autonomous: false,
  createdAt: "2026-01-01T00:00:00Z",
  updatedAt: "2026-01-01T01:00:00Z",
  warnings: [],
  iterate: {used: 2, maxIterations: 10}
}')"
printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"

# Case A: write --status completed produces valid result.json
bash "$LIB" write "$FEAT_DIR" --status completed >/dev/null 2>&1
check "A: result.json created" "1" "$([[ -f "$FEAT_DIR/result.json" ]] && echo 1 || echo 0)"
check "A: valid JSON" "0" "$(jq . "$FEAT_DIR/result.json" >/dev/null 2>&1; echo $?)"
check "A: schema=1" "1" "$(jq '.schema' "$FEAT_DIR/result.json")"
check "A: status=completed" "completed" "$(jq -r '.status' "$FEAT_DIR/result.json")"
check "A: slug" "my-feature" "$(jq -r '.slug' "$FEAT_DIR/result.json")"
check "A: feature_title" "Add rate limiting" "$(jq -r '.feature_title' "$FEAT_DIR/result.json")"
check "A: iterations.used=2" "2" "$(jq '.iterations.used' "$FEAT_DIR/result.json")"
check "A: iterations.max=10" "10" "$(jq '.iterations.max' "$FEAT_DIR/result.json")"
check "A: branch" "feat/my-feature" "$(jq -r '.branch' "$FEAT_DIR/result.json")"
check "A: baseBranch" "main" "$(jq -r '.baseBranch' "$FEAT_DIR/result.json")"
check "A: finishedAt present" "1" "$([[ "$(jq -r '.finishedAt' "$FEAT_DIR/result.json")" != "null" ]] && echo 1 || echo 0)"
check "A: delivery status exposed" "ready-for-review" "$(jq -r '.delivery.status' "$FEAT_DIR/result.json")"

# Case B: converged=true with empty warnings
check "B: converged=true on clean completion" "true" "$(jq '.converged' "$FEAT_DIR/result.json")"

# Case C: converged=false when warnings contains iterate-budget-spent:
printf '%s\n' "$(jq '.warnings = ["iterate-budget-spent: foo gap"]' "$FEAT_DIR/feature.json")" > "$FEAT_DIR/feature.json"
bash "$LIB" write "$FEAT_DIR" --status completed >/dev/null 2>&1
check "C: converged=false with iterate-budget-spent warning" "false" "$(jq '.converged' "$FEAT_DIR/result.json")"
check "C: warnings array present" "1" "$(jq '.warnings | length' "$FEAT_DIR/result.json")"

# Restore clean warnings
printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"

# Case D: --pr-url wins over feature.json .prUrl
printf '%s\n' "$(jq '.prUrl = "https://github.com/old/pr/1"' "$FEAT_DIR/feature.json")" > "$FEAT_DIR/feature.json"
bash "$LIB" write "$FEAT_DIR" --status completed --pr-url "https://github.com/new/pr/2" >/dev/null 2>&1
check "D: --pr-url wins over feature.json prUrl" "https://github.com/new/pr/2" "$(jq -r '.prUrl' "$FEAT_DIR/result.json")"

# Restore fixture
printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"

# Case E: feature.json .prUrl used when no --pr-url arg
printf '%s\n' "$(jq '.prUrl = "https://github.com/feat/pr/5"' "$FEAT_DIR/feature.json")" > "$FEAT_DIR/feature.json"
bash "$LIB" write "$FEAT_DIR" --status completed >/dev/null 2>&1
check "E: feature.json prUrl used when no arg" "https://github.com/feat/pr/5" "$(jq -r '.prUrl' "$FEAT_DIR/result.json")"

# Restore fixture
printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"

# Case F: last-result.json copy created at the right relative location
bash "$LIB" write "$FEAT_DIR" --status completed >/dev/null 2>&1
check "F: last-result.json created" "1" "$([[ -f "$LOOP_DIR/last-result.json" ]] && echo 1 || echo 0)"
check "F: last-result.json has same slug" "my-feature" "$(jq -r '.slug' "$LOOP_DIR/last-result.json")"

# Case G: missing feature.json → exit 0 + no result.json written
mkdir -p "$WORK/empty-feat"
rm -f "$WORK/empty-feat/result.json"
ec=0
bash "$LIB" write "$WORK/empty-feat" --status completed >/dev/null 2>&1 || ec=$?
check "G: missing feature.json exits 0" "0" "$ec"
check "G: no result.json on missing feature.json" "0" "$([[ -f "$WORK/empty-feat/result.json" ]] && echo 1 || echo 0)"

# Case H: bad --status → exit 0 + no result.json written
printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"
rm -f "$FEAT_DIR/result.json"
ec=0
bash "$LIB" write "$FEAT_DIR" --status invalid_status >/dev/null 2>&1 || ec=$?
check "H: bad --status exits 0" "0" "$ec"
check "H: no result.json on bad status" "0" "$([[ -f "$FEAT_DIR/result.json" ]] && echo 1 || echo 0)"

# Case I: the matching event line appears in events.jsonl
printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"
rm -f "$FEAT_DIR/events.jsonl"
bash "$LIB" write "$FEAT_DIR" --status completed >/dev/null 2>&1
check "I: events.jsonl written" "1" "$([[ -f "$FEAT_DIR/events.jsonl" ]] && echo 1 || echo 0)"
evt_event="$(tail -1 "$FEAT_DIR/events.jsonl" | jq -r '.event' 2>/dev/null || echo MISSING)"
check "I: event matches status" "completed" "$evt_event"

# Case J: --reason persisted in result.json; no --reason arg produces null
printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"
bash "$LIB" write "$FEAT_DIR" --status paused --reason "user pause" >/dev/null 2>&1
check "J: reason in result.json" "user pause" "$(jq -r '.reason' "$FEAT_DIR/result.json")"
printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"
bash "$LIB" write "$FEAT_DIR" --status completed >/dev/null 2>&1
check "J2: no reason arg → reason is null" "null" "$(jq -r '.reason' "$FEAT_DIR/result.json")"

# Case K: converged=false for iterate-terminal: warning
printf '%s\n' "$(jq '.warnings = ["iterate-terminal: gap closed as terminal"]' "$FEAT_DIR/feature.json")" > "$FEAT_DIR/feature.json"
bash "$LIB" write "$FEAT_DIR" --status completed >/dev/null 2>&1
check "K: converged=false with iterate-terminal warning" "false" "$(jq '.converged' "$FEAT_DIR/result.json")"

# Case L: no --status → exit 0
printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"
ec=0
bash "$LIB" write "$FEAT_DIR" >/dev/null 2>&1 || ec=$?
check "L: missing --status exits 0" "0" "$ec"

# Case M: successful DELIVER sidecar supplies logical completion without changing HEAD state.
printf '%s\n' "$(jq '.currentPhase = "deliver" | .prUrl = null | .delivery = {status:"pending",targets:[]}' \
  <<<"$FIXTURE_FJ")" > "$FEAT_DIR/feature.json"
jq -n '{schema:1,ok:true,status:"ready-for-review",nextPhase:"completed",
  prUrl:"https://github.com/sidecar/pr/9",attemptedAt:"2026-01-01T01:00:00Z",
  finishedAt:"2026-01-01T01:05:00Z",targets:[{name:"my-feature",ok:true}]}' \
  > "$FEAT_DIR/delivery.json"
bash "$LIB" write "$FEAT_DIR" --status completed >/dev/null 2>&1
check "M: sidecar advances logical phase" "completed" "$(jq -r '.phaseReached' "$FEAT_DIR/result.json")"
check "M: sidecar PR exposed" "https://github.com/sidecar/pr/9" "$(jq -r '.prUrl' "$FEAT_DIR/result.json")"
check "M: sidecar delivery exposed" "ready-for-review" "$(jq -r '.delivery.status' "$FEAT_DIR/result.json")"
jq '(.targets[0].feedback) = {observationStatus:"complete",changesRequested:true}' \
  "$FEAT_DIR/delivery.json" > "$FEAT_DIR/delivery.json.tmp"
mv "$FEAT_DIR/delivery.json.tmp" "$FEAT_DIR/delivery.json"
bash "$LIB" write "$FEAT_DIR" --status completed >/dev/null 2>&1
check "M2: blocking feedback prevents convergence" "false" "$(jq '.converged' "$FEAT_DIR/result.json")"
check "M2: blocking feedback becomes a warning" "pr-feedback-changes-requested:my-feature" \
  "$(jq -r '.warnings[] | select(startswith("pr-feedback-changes-requested:"))' "$FEAT_DIR/result.json")"

# Case N: an explicit control root receives the stable pointer even when the
# feature state lives under a separate Claude worktree.
CONTROL="$WORK/control"
WT_FEAT="$WORK/worktree/.loop-spec/features/wt-feature"
mkdir -p "$CONTROL/.loop-spec" "$WT_FEAT"
printf '%s\n' "$(jq '.slug = "wt-feature"' <<<"$FIXTURE_FJ")" > "$WT_FEAT/feature.json"
LOOP_SPEC_RESULT_ROOT="$CONTROL" bash "$LIB" write "$WT_FEAT" --status completed >/dev/null 2>&1
check "N: control-root pointer created" "1" "$([[ -f "$CONTROL/.loop-spec/last-result.json" ]] && echo 1 || echo 0)"
check "N: worktree pointer not substituted" "0" "$([[ -f "$WORK/worktree/.loop-spec/last-result.json" ]] && echo 1 || echo 0)"

# Legacy feature states without resultRoot recover the control checkout from Git's
# linked-worktree registry.
LEGACY_CONTROL="$WORK/legacy-control"
mkdir -p "$LEGACY_CONTROL"
git -C "$LEGACY_CONTROL" init -q
git -C "$LEGACY_CONTROL" -c user.name=Test -c user.email=test@example.com commit --allow-empty -qm init
LEGACY_WT="$WORK/legacy-worktree"
git -C "$LEGACY_CONTROL" worktree add -q -b legacy-feature "$LEGACY_WT"
LEGACY_FEAT="$LEGACY_WT/.loop-spec/features/legacy"
mkdir -p "$LEGACY_FEAT"
printf '%s\n' "$(jq 'del(.resultRoot) | .slug = "legacy"' <<<"$FIXTURE_FJ")" > "$LEGACY_FEAT/feature.json"
bash "$LIB" write "$LEGACY_FEAT" --status completed >/dev/null 2>&1
check "N2: legacy worktree finds control pointer" "1" \
  "$([[ -f "$LEGACY_CONTROL/.loop-spec/last-result.json" ]] && echo 1 || echo 0)"
rm -f "$LEGACY_CONTROL/.loop-spec/last-result.json"
bash "$LIB" write-terminal --result-root "$LEGACY_WT" --cycle-type micro \
  --status completed --outcome verified --title "Linked micro" --pr-url https://example/pr/3 \
  --converged true --verification-status passed >/dev/null
check "N3: reduced cycle resolves linked worktree control pointer" "1" \
  "$([[ -f "$LEGACY_CONTROL/.loop-spec/last-result.json" ]] && echo 1 || echo 0)"
check "N3: reduced cycle leaves no disposable pointer" "0" \
  "$([[ -f "$LEGACY_WT/.loop-spec/last-result.json" ]] && echo 1 || echo 0)"

# Case O: micro/debug use the same compatibility keys at the stable root.
GENERIC_ROOT="$WORK/generic"
mkdir -p "$GENERIC_ROOT"
bash "$LIB" write-terminal --result-root "$GENERIC_ROOT" --cycle-type micro \
  --status completed --outcome verified --slug doc-refresh --title "Refresh docs" \
  --branch micro/doc-refresh --base-branch main --pr-url https://github.com/test/repo/pull/8 \
  --converged true --verification-status passed --verification-command "bash tests/run-all.sh" \
  --autonomous true >/dev/null
GENERIC_RESULT="$GENERIC_ROOT/.loop-spec/last-result.json"
check "O: generic pointer created" "1" "$([[ -f "$GENERIC_RESULT" ]] && echo 1 || echo 0)"
check "O: cycle type" "micro" "$(jq -r '.cycleType' "$GENERIC_RESULT")"
check "O: compatibility branch" "micro/doc-refresh" "$(jq -r '.branch' "$GENERIC_RESULT")"
check "O: compatibility PR" "https://github.com/test/repo/pull/8" "$(jq -r '.prUrl' "$GENERIC_RESULT")"
check "O: explicit convergence" "true" "$(jq -r '.converged' "$GENERIC_RESULT")"
check "O: verification command" "bash tests/run-all.sh" "$(jq -r '.verification.command' "$GENERIC_RESULT")"
check "O: no temporary pointer remains" "0" "$([[ -f "$GENERIC_RESULT.tmp" ]] && echo 1 || echo 0)"

# Case P: contradictory success claims are rejected and clear removes stale pointers.
rm -f "$GENERIC_RESULT"
bash "$LIB" write-terminal --result-root "$GENERIC_ROOT" --cycle-type micro \
  --status failed --outcome verification-failed --title "Bad claim" --pr-url https://example/pr/1 \
  --converged true --verification-status passed >/dev/null 2>&1
check "P: contradictory convergence rejected" "0" "$([[ -f "$GENERIC_RESULT" ]] && echo 1 || echo 0)"
bash "$LIB" write-terminal --result-root "$GENERIC_ROOT" --cycle-type debug \
  --status completed --outcome fixed --title "Fixed" --pr-url https://example/pr/2 \
  --converged true --verification-status passed >/dev/null
bash "$LIB" clear --result-root "$GENERIC_ROOT"
check "P: clear removes stale pointer" "0" "$([[ -f "$GENERIC_RESULT" ]] && echo 1 || echo 0)"

# Case Q: result operations never follow a symlinked .loop-spec directory.
SYMLINK_ROOT="$WORK/symlink-root"
EXTERNAL_ROOT="$WORK/external-loop-spec"
mkdir -p "$SYMLINK_ROOT" "$EXTERNAL_ROOT"
printf 'keep\n' > "$EXTERNAL_ROOT/last-result.json"
ln -s "$EXTERNAL_ROOT" "$SYMLINK_ROOT/.loop-spec"
ec=0
bash "$LIB" clear --result-root "$SYMLINK_ROOT" >/dev/null 2>&1 || ec=$?
check "Q: unsafe clear fails loudly" "1" "$ec"
check "Q: unsafe clear preserves external pointer" "keep" "$(<"$EXTERNAL_ROOT/last-result.json")"
bash "$LIB" write-terminal --result-root "$SYMLINK_ROOT" --cycle-type micro \
  --status completed --outcome verified --title "Unsafe" --pr-url https://example/pr/4 \
  --converged true --verification-status passed >/dev/null 2>&1
check "Q: unsafe write preserves external pointer" "keep" "$(<"$EXTERNAL_ROOT/last-result.json")"
SYMLINK_FEATURE="$SYMLINK_ROOT/.loop-spec/features/unsafe"
mkdir -p "$SYMLINK_FEATURE"
printf '%s\n' "$(jq '.slug = "unsafe"' <<<"$FIXTURE_FJ")" > "$SYMLINK_FEATURE/feature.json"
bash "$LIB" write "$SYMLINK_FEATURE" --status completed >/dev/null 2>&1
check "Q: unsafe full write preserves external pointer" "keep" "$(<"$EXTERNAL_ROOT/last-result.json")"
check "Q: unsafe full write creates no external result" "0" \
  "$([[ -f "$SYMLINK_FEATURE/result.json" ]] && echo 1 || echo 0)"
check "Q: unsafe full write creates no external events" "0" \
  "$([[ -f "$SYMLINK_FEATURE/events.jsonl" ]] && echo 1 || echo 0)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
