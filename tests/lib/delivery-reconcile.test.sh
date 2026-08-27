#!/usr/bin/env bash
# Tests for lib/delivery-reconcile.sh (observe a gh-created PR into delivery.json).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/lib/delivery-reconcile.sh"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

WORK="${TMPDIR:-/tmp}/loop-spec-delivery-reconcile.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/repo/.loop-spec/features/my-feature" "$WORK/shims"

git -C "$WORK/repo" init -q -b main
git -C "$WORK/repo" config user.email t@t
git -C "$WORK/repo" config user.name t
printf 'base\n' > "$WORK/repo/base.txt"
git -C "$WORK/repo" add base.txt
git -C "$WORK/repo" commit -q -m base
HEAD_SHA="$(git -C "$WORK/repo" rev-parse HEAD)"

FEAT="$WORK/repo/.loop-spec/features/my-feature"
write_feature() {
  jq -n --arg sha "$HEAD_SHA" --arg pr "${1:-}" --arg checkpoint "${2:-}" '{
    schemaVersion: 7,
    slug: "my-feature",
    feature_title: "Reconcile",
    currentPhase: "deliver",
    branch: "feat/my-feature",
    baseBranch: "main",
    prUrl: (if $pr == "" then null else $pr end),
    checkpointPrUrl: (if $checkpoint == "" then null else $checkpoint end),
    delivery: {status:"pending",targets:[]},
    warnings: []
  }' > "$FEAT/feature.json"
}

cat > "$WORK/shims/pr-delivery" <<'SHIM'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "${FAKE_OBSERVE_LOG:?}"
outcome="${FAKE_OBSERVE_OUTCOME:-delivered-draft}"
url="${FAKE_OBSERVE_PR_URL:-https://github.com/test/repo/pull/40}"
code="${FAKE_OBSERVE_ERROR:-}"
ok=true
rc=0
[[ -z "$code" ]] || { ok=false; rc=1; }
jq -cn --argjson ok "$ok" --arg outcome "$outcome" --arg url "$url" --arg code "$code" \
  '{schema:1,ok:$ok,mode:"observe",outcome:$outcome,prUrl:$url,prNumber:40,
    isDraft:($outcome == "delivered-draft"),targetSha:"abc",remoteSha:"abc",headSha:"abc",
    checks:{status:"passed",required:[]},errorCode:(if $code == "" then null else $code end),
    error:null}'
exit "$rc"
SHIM
chmod +x "$WORK/shims/pr-delivery"

run_observe() {
  : > "$WORK/observe.log"
  FAKE_OBSERVE_LOG="$WORK/observe.log" \
    LOOP_SPEC_PR_DELIVERY_BIN="$WORK/shims/pr-delivery" \
    bash "$SCRIPT" observe "$FEAT" "$@"
}

write_feature "https://github.com/test/repo/pull/40"
rm -f "$FEAT/delivery.json"
ec=0; out="$(run_observe 2>"$WORK/err")" || ec=$?
check "draft: exit 0" "0" "$ec"
check "draft: sidecar status" "delivered-draft" "$(jq -r '.status' "$FEAT/delivery.json")"
check "draft: nextPhase completed" "completed" "$(jq -r '.nextPhase' "$FEAT/delivery.json")"
check "draft: stdout is sidecar" "delivered-draft" "$(jq -r '.status' <<<"$out")"
check "draft: observe mode" "1" "$(grep -c '^observe ' "$WORK/observe.log" || true)"
check "draft: no title passed" "0" "$(grep -c -- '--title ' "$WORK/observe.log" || true)"

# Canonical sidecar is a no-op and does not re-observe.
: > "$WORK/observe.log"
ec=0; out="$(run_observe 2>"$WORK/err")" || ec=$?
check "canonical no-op: exit 0" "0" "$ec"
check "canonical no-op: no observe call" "0" "$(grep -c '^observe ' "$WORK/observe.log" || true)"
check "canonical no-op: status unchanged" "delivered-draft" "$(jq -r '.status' "$FEAT/delivery.json")"

write_feature "https://github.com/test/repo/pull/41"
rm -f "$FEAT/delivery.json"
ec=0
out="$(FAKE_OBSERVE_OUTCOME=delivered FAKE_OBSERVE_PR_URL="https://github.com/test/repo/pull/41" \
  run_observe 2>"$WORK/err")" || ec=$?
check "ready: exit 0" "0" "$ec"
check "ready: sidecar status" "ready-for-review" "$(jq -r '.status' "$FEAT/delivery.json")"
check "ready: target outcome" "delivered" "$(jq -r '.targets[0].outcome' "$FEAT/delivery.json")"

# Pending/failed checks leave the sidecar unwritten.
write_feature "https://github.com/test/repo/pull/42"
rm -f "$FEAT/delivery.json"
ec=0
out="$(FAKE_OBSERVE_OUTCOME=blocked FAKE_OBSERVE_ERROR=checks_pending \
  FAKE_OBSERVE_PR_URL="https://github.com/test/repo/pull/42" \
  run_observe 2>"$WORK/err")" || ec=$?
check "pending: exit 1" "1" "$ec"
check "pending: no sidecar" "0" "$([[ -f "$FEAT/delivery.json" ]] && echo 1 || echo 0)"

ec=0
out="$(FAKE_OBSERVE_OUTCOME=blocked FAKE_OBSERVE_ERROR=pr_head_moved \
  run_observe 2>"$WORK/err")" || ec=$?
check "sha mismatch: exit 1" "1" "$ec"
check "sha mismatch: no sidecar" "0" "$([[ -f "$FEAT/delivery.json" ]] && echo 1 || echo 0)"

# Checkpoint-only PRs stay unrecorded unless the agent claimed completion.
CHECKPOINT="https://github.com/test/repo/pull/7"
write_feature "" "$CHECKPOINT"
rm -f "$FEAT/delivery.json"
ec=0
out="$(FAKE_OBSERVE_PR_URL="$CHECKPOINT" run_observe 2>"$WORK/err")" || ec=$?
check "checkpoint refused: exit 1" "1" "$ec"
check "checkpoint refused: no sidecar" "0" "$([[ -f "$FEAT/delivery.json" ]] && echo 1 || echo 0)"

ec=0
out="$(FAKE_OBSERVE_PR_URL="$CHECKPOINT" run_observe --accept-checkpoint 2>"$WORK/err")" || ec=$?
check "checkpoint accepted: exit 0" "0" "$ec"
check "checkpoint accepted: sidecar" "delivered-draft" "$(jq -r '.status' "$FEAT/delivery.json")"

# The recorded base is asserted by observe; an unrecorded base is not invented.
write_feature "https://github.com/test/repo/pull/40"
rm -f "$FEAT/delivery.json"
run_observe >/dev/null 2>&1
check "recorded base: passed through" "1" "$(grep -c -- '--base main' "$WORK/observe.log" || true)"

jq 'del(.baseBranch)' "$FEAT/feature.json" > "$FEAT/feature.json.tmp"
mv "$FEAT/feature.json.tmp" "$FEAT/feature.json"
rm -f "$FEAT/delivery.json"
run_observe >/dev/null 2>&1
check "absent base: no --base asserted" "0" "$(grep -c -- '--base ' "$WORK/observe.log" || true)"

# Kill switch skips without writing.
write_feature "https://github.com/test/repo/pull/40"
rm -f "$FEAT/delivery.json"
ec=0
out="$(LOOP_SPEC_DELIVERY_RECONCILE=0 run_observe 2>"$WORK/err")" || ec=$?
check "kill switch: exit 0" "0" "$ec"
check "kill switch: no sidecar" "0" "$([[ -f "$FEAT/delivery.json" ]] && echo 1 || echo 0)"
check "kill switch: no observe" "0" "$(grep -c '^observe ' "$WORK/observe.log" || true)"

# Workspace mode is out of scope.
jq '.workspace = {root:"/tmp/ws",repos:[]}' "$FEAT/feature.json" > "$FEAT/feature.json.tmp"
mv "$FEAT/feature.json.tmp" "$FEAT/feature.json"
rm -f "$FEAT/delivery.json"
ec=0; out="$(run_observe 2>"$WORK/err")" || ec=$?
check "workspace: exit 1" "1" "$ec"
check "workspace: no sidecar" "0" "$([[ -f "$FEAT/delivery.json" ]] && echo 1 || echo 0)"

# Bad invocation.
ec=0; bash "$SCRIPT" >/dev/null 2>&1 || ec=$?
check "no args: exit 2" "2" "$ec"
ec=0; bash "$SCRIPT" observe >/dev/null 2>&1 || ec=$?
check "missing feature dir: exit 2" "2" "$ec"
ec=0; bash "$SCRIPT" observe "$WORK/missing" >/dev/null 2>&1 || ec=$?
check "missing feature.json: exit 2" "2" "$ec"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
