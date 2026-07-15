#!/usr/bin/env bash
# Tests for the feature/workspace adapter around pr-delivery.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/lib/deliver.sh"
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

WORK="${TMPDIR:-/tmp}/loop-spec-deliver.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/shims"

cat > "$WORK/shims/pr-delivery" <<'SHIM'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "${FAKE_DELIVERY_LOG:?}"
repo=""; branch=""; base=""; sha=""; body=""; hold=0; restore=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -C) repo="$2"; shift 2 ;;
    --branch) branch="$2"; shift 2 ;;
    --base) base="$2"; shift 2 ;;
    --sha) sha="$2"; shift 2 ;;
    --body-file) body="$2"; shift 2 ;;
    --hold-ready) hold=1; shift ;;
    --restore-draft) restore=1; shift ;;
    *) shift ;;
  esac
done
cp "$body" "${FAKE_DELIVERY_BODY:?}"
# Distinct URL per repo so workspace aggregates can be checked.
url="https://github.com/test/$(basename "$repo")/pull/7"
[[ "$(basename "$repo")" == "repo" || "$(basename "$repo")" == "single" ]] \
  && url="https://github.com/test/repo/pull/7"
if [[ "${FAKE_DELIVERY_MALFORMED:-0}" == "1" ]]; then
  printf 'not-json\n'
  exit 1
fi
# FAKE_DELIVERY_FAIL fails every call; FAKE_DELIVERY_FAIL_MATCH fails only repos whose
# path contains the substring (a single repo's checks failing inside a workspace).
fail=0; fail_code="checks_failed"
[[ "${FAKE_DELIVERY_FAIL:-0}" == "1" ]] && fail=1
[[ -n "${FAKE_DELIVERY_FAIL_MATCH:-}" && "$repo" == *"$FAKE_DELIVERY_FAIL_MATCH"* ]] && fail=1
if [[ "$hold" == "0" && "$restore" == "0" && -n "${FAKE_DELIVERY_PROMOTE_FAIL_MATCH:-}" \
      && "$repo" == *"$FAKE_DELIVERY_PROMOTE_FAIL_MATCH"* ]]; then
  fail=1; fail_code="ready_failed"
fi
if [[ "$fail" == "1" ]]; then
  jq -cn --arg repo "$repo" --arg branch "$branch" --arg base "$base" --arg sha "$sha" --arg url "$url" --arg code "$fail_code" \
    '{schema:1,ok:false,mode:"final",outcome:"blocked",repo:$repo,branch:$branch,
      baseBranch:$base,targetSha:$sha,remoteSha:$sha,headSha:$sha,prNumber:7,prUrl:$url,
      prAction:"reused",metadataAction:"unchanged",readinessAction:"none",isDraft:true,
      checks:{status:"failed",required:[{name:"test",bucket:"fail"}]},
      observedAt:"2026-01-01T00:00:00Z",errorCode:$code,error:"failed"}'
  exit 1
fi
if [[ "$restore" == "1" ]]; then
  jq -cn --arg repo "$repo" --arg branch "$branch" --arg base "$base" --arg sha "$sha" --arg url "$url" \
    '{schema:1,ok:true,mode:"final",outcome:"ready-pending",repo:$repo,branch:$branch,
      baseBranch:$base,targetSha:$sha,remoteSha:$sha,headSha:$sha,prNumber:7,prUrl:$url,
      prAction:"reused",metadataAction:"unchanged",readinessAction:"rolled_back",isDraft:true,
      checks:{status:"passed",required:[{name:"test",bucket:"pass"}]},
      observedAt:"2026-01-01T00:00:00Z",errorCode:null,error:null}'
  exit 0
fi
if [[ "$hold" == "1" ]]; then
  jq -cn --arg repo "$repo" --arg branch "$branch" --arg base "$base" --arg sha "$sha" --arg url "$url" \
    '{schema:1,ok:true,mode:"final",outcome:"ready-pending",repo:$repo,branch:$branch,
      baseBranch:$base,targetSha:$sha,remoteSha:$sha,headSha:$sha,prNumber:7,prUrl:$url,
      prAction:"reused",metadataAction:"unchanged",readinessAction:"held",isDraft:true,
      checks:{status:"passed",required:[{name:"test",bucket:"pass"}]},
      observedAt:"2026-01-01T00:00:00Z",errorCode:null,error:null}'
  exit 0
fi
jq -cn --arg repo "$repo" --arg branch "$branch" --arg base "$base" --arg sha "$sha" --arg url "$url" \
  '{schema:1,ok:true,mode:"final",outcome:"delivered",repo:$repo,branch:$branch,
    baseBranch:$base,targetSha:$sha,remoteSha:$sha,headSha:$sha,prNumber:7,prUrl:$url,
    prAction:"reused",metadataAction:"unchanged",readinessAction:"marked_ready",isDraft:false,
    checks:{status:"passed",required:[{name:"test",bucket:"pass"}]},
    observedAt:"2026-01-01T00:00:00Z",errorCode:null,error:null}'
SHIM
chmod +x "$WORK/shims/pr-delivery"

init_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  printf 'base\n' > "$repo/a"
  git -C "$repo" add a
  git -C "$repo" commit -q -m base
}

# Single repository.
SINGLE="$WORK/single"
init_repo "$SINGLE"
BASE="$(git -C "$SINGLE" rev-parse HEAD)"
git -C "$SINGLE" checkout -q -b feat/demo
printf 'feature\n' > "$SINGLE/b"
git -C "$SINGLE" add b
git -C "$SINGLE" commit -q -m feature
FDIR="$SINGLE/.loop-spec/features/demo"
DOCS="$SINGLE/docs/loop-spec/features/demo"
mkdir -p "$FDIR" "$DOCS"
cat > "$SINGLE/.gitignore" <<'EOF'
/.loop-spec/features/*/*
!/.loop-spec/features/*/feature.json
EOF
printf '# Spec\nThe goal.\n' > "$DOCS/SPEC.md"
printf '# Verification\nAll pass.\n' > "$DOCS/VERIFICATION.md"
printf '# Iteration\nConverged.\n' > "$DOCS/ITERATION.md"
jq -n --arg base "$BASE" '{schemaVersion:7,slug:"demo",feature_title:"Demo feature",
  currentPhase:"deliver",branch:"feat/demo",baseSha:$base,baseBranch:"main",workspace:null,
  prUrl:null,checkpointPrUrl:"https://github.com/test/repo/pull/7",warnings:[],
  artifacts:{spec:"docs/loop-spec/features/demo/SPEC.md",verification:"docs/loop-spec/features/demo/VERIFICATION.md",iteration:"docs/loop-spec/features/demo/ITERATION.md"},
  delivery:{status:"pending",attemptedAt:null,finishedAt:null,targets:[]}}' > "$FDIR/feature.json"
git -C "$SINGLE" add .gitignore ".loop-spec/features/demo/feature.json" \
  "docs/loop-spec/features/demo"
git -C "$SINGLE" commit -q -m "final candidate"
SHA="$(git -C "$SINGLE" rev-parse HEAD)"

LOG="$WORK/calls.log"; BODY="$WORK/body.md"; : > "$LOG"
ec=0
out="$(FAKE_DELIVERY_LOG="$LOG" FAKE_DELIVERY_BODY="$BODY" \
  LOOP_SPEC_PR_DELIVERY_BIN="$WORK/shims/pr-delivery" bash "$SCRIPT" run "$FDIR")" || ec=$?
check "single: exit 0" "0" "$ec"
check "single: aggregate ready" "ready-for-review" "$(jq -r '.status' <<<"$out" 2>/dev/null)"
check "single: sidecar ready" "ready-for-review" "$(jq -r '.status' "$FDIR/delivery.json")"
check "single: deterministic next phase" "completed" "$(jq -r '.nextPhase' "$FDIR/delivery.json")"
check "single: committed phase remains resumable" "deliver" "$(jq -r '.currentPhase' "$FDIR/feature.json")"
check "single: URL persisted locally" "https://github.com/test/repo/pull/7" "$(jq -r '.prUrl' "$FDIR/delivery.json")"
check "single: exact HEAD delegated" "$SHA" "$(jq -r '.targets[0].targetSha' "$FDIR/delivery.json")"
check "single: checkout remains clean" "0" "$(git -C "$SINGLE" status --porcelain | wc -l | tr -d ' ')"
check "single: checkpoint hint reused" "1" "$(grep -c -- '--pr-url https://github.com/test/repo/pull/7' "$LOG" || true)"
check "single: final iteration in body" "1" "$(grep -c 'Converged' "$BODY" || true)"

# CI failure persists the PR identity but does not claim readiness.
: > "$LOG"
ec=0
out="$(FAKE_DELIVERY_LOG="$LOG" FAKE_DELIVERY_BODY="$BODY" FAKE_DELIVERY_FAIL=1 \
  LOOP_SPEC_PR_DELIVERY_BIN="$WORK/shims/pr-delivery" bash "$SCRIPT" run "$FDIR")" || ec=$?
check "failure: exit 1" "1" "$ec"
check "failure: state not ready" "checks-failed" "$(jq -r '.delivery.status' "$FDIR/feature.json")"
check "failure: deterministic remediation route" "execute" "$(jq -r '.delivery.nextPhase' "$FDIR/feature.json")"
check "failure: remediation attempt counted" "1" "$(jq -r '.delivery.ciRemediationAttempts' "$FDIR/feature.json")"
check "failure: phase routed to execute" "execute" "$(jq -r '.currentPhase' "$FDIR/feature.json")"
check "failure: remediation task appended" "task-delivery-ci-demo" "$(jq -r '.pendingRemediationTasks[0].id' "$FDIR/feature.json")"
check "failure: remediation verify command nonempty" "1" "$([[ -n "$(jq -r '.pendingRemediationTasks[0].verifyCommand' "$FDIR/feature.json")" ]] && echo 1 || echo 0)"
check "failure: PR URL retained" "https://github.com/test/repo/pull/7" "$(jq -r '.prUrl' "$FDIR/feature.json")"

# CI remediation is bounded: after two routed attempts, fail closed at DELIVER.
jq '.currentPhase = "deliver" | .delivery.ciRemediationAttempts = 2 | .pendingRemediationTasks = []' \
  "$FDIR/feature.json" > "$FDIR/feature.json.tmp"
mv "$FDIR/feature.json.tmp" "$FDIR/feature.json"
git -C "$SINGLE" add ".loop-spec/features/demo/feature.json"
git -C "$SINGLE" commit -q -m "route back to deliver"
: > "$LOG"; ec=0
out="$(FAKE_DELIVERY_LOG="$LOG" FAKE_DELIVERY_BODY="$BODY" FAKE_DELIVERY_FAIL=1 \
  LOOP_SPEC_PR_DELIVERY_BIN="$WORK/shims/pr-delivery" bash "$SCRIPT" run "$FDIR")" || ec=$?
check "failure limit: exit 1" "1" "$ec"
check "failure limit: route stops at deliver" "deliver" "$(jq -r '.nextPhase' "$FDIR/delivery.json")"
check "failure limit: tracked phase unchanged" "deliver" "$(jq -r '.currentPhase' "$FDIR/feature.json")"
check "failure limit: no extra attempt" "2" "$(jq -r '.ciRemediationAttempts' "$FDIR/delivery.json")"

# Adapter-generated controller errors retain the known checkpoint identity.
: > "$LOG"; ec=0
out="$(FAKE_DELIVERY_LOG="$LOG" FAKE_DELIVERY_BODY="$BODY" FAKE_DELIVERY_MALFORMED=1 \
  LOOP_SPEC_PR_DELIVERY_BIN="$WORK/shims/pr-delivery" bash "$SCRIPT" run "$FDIR")" || ec=$?
check "controller error: exit 1" "1" "$ec"
check "controller error: PR hint retained" "https://github.com/test/repo/pull/7" \
  "$(jq -r '.prUrl' "$FDIR/delivery.json")"

# Workspace mode processes changed repos and records zero-commit repos explicitly.
WS="$WORK/workspace"; mkdir -p "$WS"
init_repo "$WS/changed"; init_repo "$WS/unchanged"
CHANGED_BASE="$(git -C "$WS/changed" rev-parse HEAD)"
UNCHANGED_BASE="$(git -C "$WS/unchanged" rev-parse HEAD)"
git -C "$WS/changed" checkout -q -b feat/ws
printf 'change\n' > "$WS/changed/b"
git -C "$WS/changed" add b
git -C "$WS/changed" commit -q -m change
git -C "$WS/unchanged" checkout -q -b feat/ws
WFDIR="$WS/.loop-spec/features/ws"; WDocs="$WS/docs/loop-spec/features/ws"
mkdir -p "$WFDIR" "$WDocs"
printf '# Spec\nWorkspace.\n' > "$WDocs/SPEC.md"
printf '# Verification\nPass.\n' > "$WDocs/VERIFICATION.md"
printf '# Iteration\nConverged.\n' > "$WDocs/ITERATION.md"
jq -n --arg root "$WS" --arg cb "$CHANGED_BASE" --arg ub "$UNCHANGED_BASE" \
  '{schemaVersion:7,slug:"ws",feature_title:"Workspace feature",currentPhase:"deliver",
    branch:null,baseSha:null,baseBranch:null,prUrl:null,checkpointPrUrl:null,warnings:[],
    artifacts:{spec:"docs/loop-spec/features/ws/SPEC.md",verification:"docs/loop-spec/features/ws/VERIFICATION.md",iteration:"docs/loop-spec/features/ws/ITERATION.md"},
    workspace:{root:$root,repos:[
      {name:"changed",path:"changed",branch:"feat/ws",baseSha:$cb,baseBranch:"main"},
      {name:"unchanged",path:"unchanged",branch:"feat/ws",baseSha:$ub,baseBranch:"main"}]},
    delivery:{status:"pending",attemptedAt:null,finishedAt:null,targets:[]}}' > "$WFDIR/feature.json"

: > "$LOG"; ec=0
out="$(FAKE_DELIVERY_LOG="$LOG" FAKE_DELIVERY_BODY="$BODY" \
  LOOP_SPEC_PR_DELIVERY_BIN="$WORK/shims/pr-delivery" bash "$SCRIPT" run "$WFDIR")" || ec=$?
check "workspace: exit 0" "0" "$ec"
check "workspace: ready" "ready-for-review" "$(jq -r '.status' "$WFDIR/delivery.json")"
check "workspace: committed phase remains deliver" "deliver" "$(jq -r '.currentPhase' "$WFDIR/feature.json")"
check "workspace: two durable targets" "2" "$(jq -r '.targets | length' "$WFDIR/delivery.json")"
check "workspace: changed delivered" "delivered" "$(jq -r '.targets[] | select(.name=="changed") | .outcome' "$WFDIR/delivery.json")"
check "workspace: unchanged skipped" "skipped-no-commits" "$(jq -r '.targets[] | select(.name=="unchanged") | .outcome' "$WFDIR/delivery.json")"
check "workspace: one controller call" "1" "$(wc -l < "$LOG" | tr -d ' ')"
check "workspace: representative PR url surfaced" "https://github.com/test/changed/pull/7" \
  "$(jq -r '.prUrl' "$WFDIR/delivery.json")"

# A repo on the wrong branch is blocked, never misreported as no changes.
git -C "$WS/changed" checkout -q main
: > "$LOG"; ec=0
out="$(FAKE_DELIVERY_LOG="$LOG" FAKE_DELIVERY_BODY="$BODY" \
  LOOP_SPEC_PR_DELIVERY_BIN="$WORK/shims/pr-delivery" bash "$SCRIPT" run "$WFDIR")" || ec=$?
check "workspace wrong branch: exit 1" "1" "$ec"
check "workspace wrong branch: structured error" "branch_mismatch" \
  "$(jq -r '.targets[] | select(.name=="changed") | .errorCode' "$WFDIR/delivery.json")"
check "workspace wrong branch: not skipped" "blocked" \
  "$(jq -r '.targets[] | select(.name=="changed") | .outcome' "$WFDIR/delivery.json")"
check "workspace wrong branch: PR hint retained" "https://github.com/test/changed/pull/7" \
  "$(jq -r '.targets[] | select(.name=="changed") | .prUrl' "$WFDIR/delivery.json")"
check "workspace wrong branch: no controller call" "0" "$(wc -l < "$LOG" | tr -d ' ')"

# A missing configured repository is also a hard target error, not a zero-commit skip.
git -C "$WS/changed" checkout -q feat/ws
jq '(.workspace.repos[] | select(.name == "changed") | .path) = "missing"' \
  "$WFDIR/feature.json" > "$WFDIR/feature.json.tmp"
mv "$WFDIR/feature.json.tmp" "$WFDIR/feature.json"
: > "$LOG"; ec=0
out="$(FAKE_DELIVERY_LOG="$LOG" FAKE_DELIVERY_BODY="$BODY" \
  LOOP_SPEC_PR_DELIVERY_BIN="$WORK/shims/pr-delivery" bash "$SCRIPT" run "$WFDIR")" || ec=$?
check "workspace missing repo: exit 1" "1" "$ec"
check "workspace missing repo: structured error" "repo_invalid" \
  "$(jq -r '.targets[] | select(.name=="changed") | .errorCode' "$WFDIR/delivery.json")"
check "workspace missing repo: not skipped" "blocked" \
  "$(jq -r '.targets[] | select(.name=="changed") | .outcome' "$WFDIR/delivery.json")"

# Single-repo candidate preflight: a checkout on the wrong branch is blocked before
# any controller call, exactly like the workspace path.
PF="$WORK/preflight"; init_repo "$PF"
PF_BASE="$(git -C "$PF" rev-parse HEAD)"
PFDIR="$PF/.loop-spec/features/pf"; mkdir -p "$PFDIR"
jq -n --arg base "$PF_BASE" '{schemaVersion:7,slug:"pf",feature_title:"PF",currentPhase:"deliver",
  branch:"feat/pf",baseSha:$base,baseBranch:"main",workspace:null,prUrl:null,checkpointPrUrl:null,
  warnings:[],artifacts:{}}' > "$PFDIR/feature.json"
: > "$LOG"; ec=0
out="$(FAKE_DELIVERY_LOG="$LOG" FAKE_DELIVERY_BODY="$BODY" \
  LOOP_SPEC_PR_DELIVERY_BIN="$WORK/shims/pr-delivery" bash "$SCRIPT" run "$PFDIR")" || ec=$?
check "single preflight wrong branch: exit 1" "1" "$ec"
check "single preflight wrong branch: structured error" "branch_mismatch" \
  "$(jq -r '.targets[0].errorCode' "$PFDIR/delivery.json")"
check "single preflight wrong branch: no controller call" "0" "$(wc -l < "$LOG" | tr -d ' ')"

# Dirty source is not part of the candidate SHA and must block before PR body/rendered
# evidence can diverge from the pushed commit.
DIRTY="$WORK/dirty"; init_repo "$DIRTY"
DIRTY_BASE="$(git -C "$DIRTY" rev-parse HEAD)"
git -C "$DIRTY" checkout -q -b feat/dirty
printf 'feature\n' > "$DIRTY/b"; git -C "$DIRTY" add b; git -C "$DIRTY" commit -q -m feature
DDIR="$DIRTY/.loop-spec/features/dirty"; mkdir -p "$DDIR"
printf '/.loop-spec/features/*/*\n!/.loop-spec/features/*/feature.json\n' > "$DIRTY/.gitignore"
jq -n --arg base "$DIRTY_BASE" '{schemaVersion:7,slug:"dirty",feature_title:"Dirty",currentPhase:"deliver",
  branch:"feat/dirty",baseSha:$base,baseBranch:"main",workspace:null,warnings:[],artifacts:{}}' > "$DDIR/feature.json"
git -C "$DIRTY" add .gitignore ".loop-spec/features/dirty/feature.json"; git -C "$DIRTY" commit -q -m state
printf 'uncommitted\n' >> "$DIRTY/b"
: > "$LOG"; ec=0
out="$(FAKE_DELIVERY_LOG="$LOG" FAKE_DELIVERY_BODY="$BODY" \
  LOOP_SPEC_PR_DELIVERY_BIN="$WORK/shims/pr-delivery" bash "$SCRIPT" run "$DDIR")" || ec=$?
check "single dirty: exit 1" "1" "$ec"
check "single dirty: structured error" "dirty_worktree" "$(jq -r '.targets[0].errorCode' "$DDIR/delivery.json")"
check "single dirty: no controller call" "0" "$(wc -l < "$LOG" | tr -d ' ')"

git -C "$DIRTY" checkout -q -- b
jq 'del(.baseSha)' "$DDIR/feature.json" > "$DDIR/feature.json.tmp" && mv "$DDIR/feature.json.tmp" "$DDIR/feature.json"
git -C "$DIRTY" add ".loop-spec/features/dirty/feature.json"; git -C "$DIRTY" commit -q -m "remove base"
: > "$LOG"; ec=0
out="$(FAKE_DELIVERY_LOG="$LOG" FAKE_DELIVERY_BODY="$BODY" \
  LOOP_SPEC_PR_DELIVERY_BIN="$WORK/shims/pr-delivery" bash "$SCRIPT" run "$DDIR")" || ec=$?
check "single missing base: exit 1" "1" "$ec"
check "single missing base: structured error" "base_sha_missing" "$(jq -r '.targets[0].errorCode' "$DDIR/delivery.json")"

# A recorded base must be an ancestor, not merely an existing commit.
DIV="$WORK/divergent"; init_repo "$DIV"
DIV_BASE="$(git -C "$DIV" rev-parse HEAD)"
git -C "$DIV" checkout -q --orphan feat/div
git -C "$DIV" rm -q -rf .
printf 'orphan\n' > "$DIV/orphan"; git -C "$DIV" add orphan; git -C "$DIV" commit -q -m orphan
VDIR="$DIV/.loop-spec/features/div"; mkdir -p "$VDIR"
printf '/.loop-spec/features/*/*\n!/.loop-spec/features/*/feature.json\n' > "$DIV/.gitignore"
jq -n --arg base "$DIV_BASE" '{schemaVersion:7,slug:"div",feature_title:"Div",currentPhase:"deliver",
  branch:"feat/div",baseSha:$base,baseBranch:"main",workspace:null,warnings:[],artifacts:{}}' > "$VDIR/feature.json"
git -C "$DIV" add .gitignore ".loop-spec/features/div/feature.json"; git -C "$DIV" commit -q -m state
: > "$LOG"; ec=0
out="$(FAKE_DELIVERY_LOG="$LOG" FAKE_DELIVERY_BODY="$BODY" \
  LOOP_SPEC_PR_DELIVERY_BIN="$WORK/shims/pr-delivery" bash "$SCRIPT" run "$VDIR")" || ec=$?
check "single divergent: exit 1" "1" "$ec"
check "single divergent: structured error" "base_not_ancestor" "$(jq -r '.targets[0].errorCode' "$VDIR/delivery.json")"

# Hard-failure retries bind to the recorded SHA: a controller error leaves
# nextPhase=deliver with the exact targetSha, and a drifted HEAD then fails closed
# instead of silently delivering a different commit.
BIND="$WORK/bind"; init_repo "$BIND"
BIND_BASE="$(git -C "$BIND" rev-parse HEAD)"
git -C "$BIND" checkout -q -b feat/bind
printf 'one\n' > "$BIND/one"; git -C "$BIND" add one; git -C "$BIND" commit -q -m one
BINDDIR="$BIND/.loop-spec/features/bind"; mkdir -p "$BINDDIR"
printf '/.loop-spec/features/*/*\n!/.loop-spec/features/*/feature.json\n' > "$BIND/.gitignore"
jq -n --arg base "$BIND_BASE" '{schemaVersion:7,slug:"bind",feature_title:"Bind",currentPhase:"deliver",
  branch:"feat/bind",baseSha:$base,baseBranch:"main",workspace:null,prUrl:null,checkpointPrUrl:null,
  warnings:[],artifacts:{}}' > "$BINDDIR/feature.json"
git -C "$BIND" add .gitignore ".loop-spec/features/bind/feature.json"; git -C "$BIND" commit -q -m state
SHA1="$(git -C "$BIND" rev-parse HEAD)"
: > "$LOG"; ec=0
out="$(FAKE_DELIVERY_LOG="$LOG" FAKE_DELIVERY_BODY="$BODY" FAKE_DELIVERY_MALFORMED=1 \
  LOOP_SPEC_PR_DELIVERY_BIN="$WORK/shims/pr-delivery" bash "$SCRIPT" run "$BINDDIR")" || ec=$?
check "bind: hard failure routes to deliver" "deliver" "$(jq -r '.nextPhase' "$BINDDIR/delivery.json")"
check "bind: recorded the tried SHA" "$SHA1" "$(jq -r '.targets[0].targetSha' "$BINDDIR/delivery.json")"
printf 'two\n' > "$BIND/two"; git -C "$BIND" add two; git -C "$BIND" commit -q -m two
: > "$LOG"; ec=0
out="$(FAKE_DELIVERY_LOG="$LOG" FAKE_DELIVERY_BODY="$BODY" \
  LOOP_SPEC_PR_DELIVERY_BIN="$WORK/shims/pr-delivery" bash "$SCRIPT" run "$BINDDIR")" || ec=$?
check "bind: drift fails closed" "1" "$ec"
check "bind: drift structured error" "candidate_sha_drift" \
  "$(jq -r '.targets[0].errorCode' "$BINDDIR/delivery.json")"
check "bind: no controller call on drift" "0" "$(wc -l < "$LOG" | tr -d ' ')"

# Staged workspace readiness: with two changed repos, every repo is held until all
# checks are green, then all are promoted (2 holds + 2 promotions).
STAGE="$WORK/stage"; mkdir -p "$STAGE"
init_repo "$STAGE/a"; init_repo "$STAGE/b"
A_BASE="$(git -C "$STAGE/a" rev-parse HEAD)"; B_BASE="$(git -C "$STAGE/b" rev-parse HEAD)"
for r in a b; do
  git -C "$STAGE/$r" checkout -q -b feat/stage
  printf 'x\n' > "$STAGE/$r/x"; git -C "$STAGE/$r" add x; git -C "$STAGE/$r" commit -q -m x
done
SFDIR="$STAGE/.loop-spec/features/stage"; SDocs="$STAGE/docs/loop-spec/features/stage"
mkdir -p "$SFDIR" "$SDocs"
printf '# Iteration\nConverged.\n' > "$SDocs/ITERATION.md"
jq -n --arg root "$STAGE" --arg ab "$A_BASE" --arg bb "$B_BASE" \
  '{schemaVersion:7,slug:"stage",feature_title:"Stage",currentPhase:"deliver",
    branch:null,baseSha:null,baseBranch:null,prUrl:null,checkpointPrUrl:null,warnings:[],
    artifacts:{iteration:"docs/loop-spec/features/stage/ITERATION.md"},
    workspace:{root:$root,repos:[
      {name:"a",path:"a",branch:"feat/stage",baseSha:$ab,baseBranch:"main"},
      {name:"b",path:"b",branch:"feat/stage",baseSha:$bb,baseBranch:"main"}]},
    delivery:{status:"pending",attemptedAt:null,finishedAt:null,targets:[]}}' > "$SFDIR/feature.json"
: > "$LOG"; ec=0
out="$(FAKE_DELIVERY_LOG="$LOG" FAKE_DELIVERY_BODY="$BODY" \
  LOOP_SPEC_PR_DELIVERY_BIN="$WORK/shims/pr-delivery" bash "$SCRIPT" run "$SFDIR")" || ec=$?
check "stage: exit 0" "0" "$ec"
check "stage: ready-for-review" "ready-for-review" "$(jq -r '.status' "$SFDIR/delivery.json")"
check "stage: both delivered" "2" "$(jq '[.targets[]|select(.outcome=="delivered")]|length' "$SFDIR/delivery.json")"
check "stage: two holds then two promotions" "4" "$(wc -l < "$LOG" | tr -d ' ')"
check "stage: exactly two hold calls" "2" "$(grep -c -- '--hold-ready' "$LOG" || true)"
check "stage: representative PR url populated" "https://github.com/test/a/pull/7" \
  "$(jq -r '.prUrl' "$SFDIR/delivery.json")"

# Staged workspace with one repo's checks failing: no repo is promoted, the passing
# repo stays held, and the feature routes to remediation rather than half-ready PRs.
jq '.delivery = {status:"pending",attemptedAt:null,finishedAt:null,targets:[]}' \
  "$SFDIR/feature.json" > "$SFDIR/feature.json.tmp" && mv "$SFDIR/feature.json.tmp" "$SFDIR/feature.json"
: > "$LOG"; ec=0
out="$(FAKE_DELIVERY_LOG="$LOG" FAKE_DELIVERY_BODY="$BODY" FAKE_DELIVERY_FAIL_MATCH="$STAGE/b" \
  LOOP_SPEC_PR_DELIVERY_BIN="$WORK/shims/pr-delivery" bash "$SCRIPT" run "$SFDIR")" || ec=$?
check "stage fail: exit 1" "1" "$ec"
check "stage fail: no promotion, two hold calls only" "2" "$(wc -l < "$LOG" | tr -d ' ')"
check "stage fail: passing repo held not delivered" "ready-pending" \
  "$(jq -r '.targets[]|select(.name=="a")|.outcome' "$SFDIR/delivery.json")"
check "stage fail: routes to remediation" "execute" "$(jq -r '.delivery.nextPhase' "$SFDIR/feature.json")"
check "stage fail: remediation task for failing repo" "task-delivery-ci-b" \
  "$(jq -r '.pendingRemediationTasks[]|select(.subject|contains("(b)"))|.id' "$SFDIR/feature.json")"
check "stage fail: remediation carries workspace repo" "b" \
  "$(jq -r '.pendingRemediationTasks[]|select(.id=="task-delivery-ci-b")|.repo' "$SFDIR/feature.json")"
check "stage fail: local fallback is executable" "git diff --check" \
  "$(jq -r '.pendingRemediationTasks[]|select(.id=="task-delivery-ci-b")|.verifyCommand' "$SFDIR/feature.json")"

# Any local preflight failure aborts the whole workspace before a sibling PR is held
# or promoted.
jq '.currentPhase="deliver" | .delivery={status:"pending",attemptedAt:null,finishedAt:null,targets:[]} | .pendingRemediationTasks=[]' \
  "$SFDIR/feature.json" > "$SFDIR/feature.json.tmp" && mv "$SFDIR/feature.json.tmp" "$SFDIR/feature.json"
git -C "$STAGE/b" checkout -q main
: > "$LOG"; ec=0
out="$(FAKE_DELIVERY_LOG="$LOG" FAKE_DELIVERY_BODY="$BODY" \
  LOOP_SPEC_PR_DELIVERY_BIN="$WORK/shims/pr-delivery" bash "$SCRIPT" run "$SFDIR")" || ec=$?
check "stage preflight fail: exit 1" "1" "$ec"
check "stage preflight fail: no controller calls" "0" "$(wc -l < "$LOG" | tr -d ' ')"
check "stage preflight fail: valid sibling blocked" "workspace_preflight_failed" \
  "$(jq -r '.targets[]|select(.name=="a")|.errorCode' "$SFDIR/delivery.json")"

# If promotion fails after an earlier sibling was promoted, restore that sibling to
# draft so the next staged retry is not permanently blocked by an already-ready PR.
git -C "$STAGE/b" checkout -q feat/stage
jq '.currentPhase="deliver" | .delivery={status:"pending",attemptedAt:null,finishedAt:null,targets:[]} | .pendingRemediationTasks=[]' \
  "$SFDIR/feature.json" > "$SFDIR/feature.json.tmp" && mv "$SFDIR/feature.json.tmp" "$SFDIR/feature.json"
: > "$LOG"; ec=0
out="$(FAKE_DELIVERY_LOG="$LOG" FAKE_DELIVERY_BODY="$BODY" FAKE_DELIVERY_PROMOTE_FAIL_MATCH="$STAGE/b" \
  LOOP_SPEC_PR_DELIVERY_BIN="$WORK/shims/pr-delivery" bash "$SCRIPT" run "$SFDIR")" || ec=$?
check "stage promotion fail: exit 1" "1" "$ec"
check "stage promotion fail: prior sibling rolled back" "rolled_back" \
  "$(jq -r '.targets[]|select(.name=="a")|.readinessAction' "$SFDIR/delivery.json")"
check "stage promotion fail: no delivered siblings" "0" \
  "$(jq '[.targets[]|select(.outcome=="delivered")]|length' "$SFDIR/delivery.json")"
check "stage promotion fail: restore call made" "1" "$(grep -c -- '--restore-draft' "$LOG" || true)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
