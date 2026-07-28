#!/usr/bin/env bash
# Offline tests for lib/pr-delivery.sh. Uses a real git remote and a stateful gh shim.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/lib/pr-delivery.sh"
REAL_GIT="$(command -v git)"
export REAL_GIT
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

WORK="${TMPDIR:-/tmp}/loop-spec-pr-delivery.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/repo" "$WORK/shims"
TARGET_REPO="$(cd "$WORK/repo" && pwd -P)"

git -C "$WORK/repo" init -q -b main
git -C "$WORK/repo" config user.email t@t
git -C "$WORK/repo" config user.name t
printf 'base\n' > "$WORK/repo/base.txt"
git -C "$WORK/repo" add base.txt
git -C "$WORK/repo" commit -q -m base
git init --bare -q "$WORK/origin.git"
git -C "$WORK/repo" remote add origin "$WORK/origin.git"
git -C "$WORK/repo" push -q -u origin main
git -C "$WORK/repo" checkout -q -b feat/delivery
printf 'feature\n' > "$WORK/repo/feature.txt"
git -C "$WORK/repo" add feature.txt
git -C "$WORK/repo" commit -q -m feature
TARGET_SHA="$(git -C "$WORK/repo" rev-parse HEAD)"

# Move HEAD beyond the candidate. Delivery must push --sha, never implicit HEAD.
printf 'later\n' > "$WORK/repo/later.txt"
git -C "$WORK/repo" add later.txt
git -C "$WORK/repo" commit -q -m later

BODY="$WORK/body.md"
printf '## Summary\n\nA body with `code`, "quotes", and details.\n' > "$BODY"
GH_STATE="$WORK/gh-state.json"
GH_LOG="$WORK/gh-calls.log"

cat > "$WORK/shims/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
state="${FAKE_GH_STATE:?}"
log="${FAKE_GH_LOG:?}"
printf '%s\n' "$*" >> "$log"

write_state() {
  local json="$1" tmp="${state}.tmp"
  printf '%s\n' "$json" > "$tmp"
  mv "$tmp" "$state"
}

case "${1:-} ${2:-}" in
  "repo view")
    [[ "${FAKE_GH_REPO_FAIL:-0}" != "1" ]] || { echo "repo unavailable" >&2; exit 1; }
    jq -cn --arg url "${FAKE_GH_REPO_URL:-https://github.com/test/repo}" \
      '{nameWithOwner:"test/repo",url:$url}'
    ;;
  "pr list")
    jq -c '.prs' "$state"
    ;;
  "pr view")
    pr="$(jq -c '.prs[0] // empty' "$state")"
    [[ -n "$pr" ]] || exit 1
    write_state "$(jq -c '.viewCount = ((.viewCount // 0) + 1)' "$state")"
    if [[ -n "${FAKE_GH_HEAD_OVERRIDE:-}" && "${FAKE_GH_HEAD_OVERRIDE_AFTER_CHECKS:-0}" != "1" ]] \
      || [[ "${FAKE_GH_HEAD_OVERRIDE_AFTER_CHECKS:-0}" == "1" \
            && "$(jq -r '.checkIndex // 0' "$state")" -gt 0 ]]; then
      pr="$(jq -c --arg sha "$FAKE_GH_HEAD_OVERRIDE" '.headRefOid = $sha' <<<"$pr")"
    fi
    [[ -z "${FAKE_GH_HEAD_REPO:-}" ]] \
      || pr="$(jq -c --arg repo "$FAKE_GH_HEAD_REPO" '.headRepository.nameWithOwner = $repo | .isCrossRepository = true' <<<"$pr")"
    [[ "${FAKE_GH_BAD_DRAFT_TYPE:-0}" != "1" ]] \
      || pr="$(jq -c '.isDraft = "unknown"' <<<"$pr")"
    if [[ "${FAKE_GH_METADATA_OVERRIDE_AFTER_CHECKS:-0}" == "1" \
          && "$(jq -r '.checkIndex // 0' "$state")" -gt 0 ]]; then
      pr="$(jq -c '.title = "concurrent edit"' <<<"$pr")"
    fi
    printf '%s\n' "$pr"
    ;;
  "pr create")
    base=""; head=""; title=""; body_file=""
    shift 2
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --draft) shift ;;
        --base) base="$2"; shift 2 ;;
        --head) head="$2"; shift 2 ;;
        --title) title="$2"; shift 2 ;;
        --body-file) body_file="$2"; shift 2 ;;
        --repo) shift 2 ;;
        *) shift ;;
      esac
    done
    body="$(cat "$body_file")"
    pr="$(jq -cn --arg sha "${FAKE_GH_HEAD_SHA:?}" --arg base "$base" \
      --arg head "$head" --arg title "$title" --arg body "$body" \
      '{number:1,url:"https://github.com/test/repo/pull/1",isDraft:true,
        headRefOid:$sha,headRefName:$head,headRepository:{nameWithOwner:"test/repo"},
        isCrossRepository:false,baseRefName:$base,title:$title,body:$body,state:"OPEN"}')"
    write_state "$(jq -c --argjson pr "$pr" '.prs = [$pr]' "$state")"
    if [[ "${FAKE_GH_CREATE_AUTH_ONCE:-0}" == "1" && ! -f "${FAKE_GH_CREATE_AUTH_MARKER:?}" ]]; then
      : > "$FAKE_GH_CREATE_AUTH_MARKER"
      echo "HTTP 401: Bad credentials" >&2
      exit 1
    fi
    printf 'https://github.com/test/repo/pull/1\n'
    ;;
  "pr edit")
    title=""; base=""; body_file=""
    shift 2
    [[ $# -gt 0 ]] && shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --title) title="$2"; shift 2 ;;
        --base) base="$2"; shift 2 ;;
        --body-file) body_file="$2"; shift 2 ;;
        --repo) shift 2 ;;
        *) shift ;;
      esac
    done
    body="$(cat "$body_file")"
    write_state "$(jq -c --arg t "$title" --arg b "$base" --arg body "$body" \
      '.prs[0].title=$t | .prs[0].baseRefName=$b | .prs[0].body=$body' "$state")"
    ;;
  "pr ready")
    if [[ "$*" == *"--undo"* ]]; then
      write_state "$(jq -c '.prs[0].isDraft = true' "$state")"
      if [[ "${FAKE_GH_READY_AUTH_AFTER_APPLY:-}" == "undo" ]]; then
        echo "HTTP 401: readiness response lost" >&2
        exit 1
      fi
    elif [[ "${FAKE_GH_MOVE_HEAD_ON_READY:-0}" == "1" ]]; then
      write_state "$(jq -c '.prs[0].isDraft = false | .prs[0].headRefOid = "0000000000000000000000000000000000000000"' "$state")"
    else
      write_state "$(jq -c '.prs[0].isDraft = false' "$state")"
      if [[ "${FAKE_GH_READY_AUTH_AFTER_APPLY:-}" == "ready" ]]; then
        echo "HTTP 403: readiness response lost" >&2
        exit 1
      fi
    fi
    ;;
  "pr checks")
    if [[ "${FAKE_GH_PARTIAL_HANG_ON_CHECKS:-0}" == "1" ]]; then
      printf '[]\n'
      sleep 10
    fi
    if [[ "${FAKE_GH_HANG_ON_CHECKS:-0}" == "1" ]]; then
      sleep 10
    fi
    idx="$(jq -r '.checkIndex // 0' "$state")"
    count="$(jq -r '.checks | length' "$state")"
    if [[ "$count" -eq 0 ]]; then
      printf '[]\n'
      exit 0
    fi
    [[ "$idx" -lt "$count" ]] || idx=$((count - 1))
    payload="$(jq -c --argjson i "$idx" '.checks[$i]' "$state")"
    if [[ "$payload" == "[]" && "$(jq -r '.noRequired // false' "$state")" == "true" ]]; then
      echo "no required checks reported on the 'main' branch" >&2
      exit 1
    fi
    if [[ "$payload" == "[]" && "$(jq -r '.noChecks // false' "$state")" == "true" ]]; then
      echo "no checks reported on the 'main' branch" >&2
      exit 1
    fi
    printf '%s\n' "$payload"
    write_state "$(jq -c '.checkIndex = ((.checkIndex // 0) + 1)' "$state")"
    ;;
  *)
    echo "fake gh: unhandled $*" >&2
    exit 1
    ;;
esac
GH
chmod +x "$WORK/shims/gh"

cat > "$WORK/shims/git" <<'GIT'
#!/usr/bin/env bash
set -uo pipefail
if [[ " $* " == *" push "* && -n "${FAKE_GIT_AUTH_MODE:-}" ]]; then
  count=0
  [[ ! -f "${FAKE_GIT_COUNT:?}" ]] || count="$(<"$FAKE_GIT_COUNT")"
  count=$((count + 1))
  printf '%s\n' "$count" > "$FAKE_GIT_COUNT"
  case "$FAKE_GIT_AUTH_MODE" in
    once)
      if [[ "$count" -eq 1 ]]; then
        echo "remote: HTTP 401: Bad credentials" >&2
        exit 128
      fi
      [[ "${GH_TOKEN:-}" == "refreshed-token" ]] \
        || { echo "remote: HTTP 403: stale token" >&2; exit 128; }
      ;;
    always)
      echo "fatal: Authentication failed for remote" >&2
      exit 128
      ;;
    nonauth)
      echo "remote rejected: protected branch" >&2
      exit 1
      ;;
  esac
fi
exec "${REAL_GIT:?}" "$@"
GIT
chmod +x "$WORK/shims/git"

REFRESH_LOG="$WORK/refresh.log"
REFRESH_HOOK="$WORK/credential-refresh.sh"
cat > "$REFRESH_HOOK" <<'REFRESH'
#!/usr/bin/env bash
set -uo pipefail
printf '%s|%s|%s|%s\n' "$LOOP_SPEC_CREDENTIAL_REFRESH_STAGE" \
  "$LOOP_SPEC_CREDENTIAL_REFRESH_REASON" "$LOOP_SPEC_CREDENTIAL_REFRESH_HOST" "$PWD" \
  >> "${FAKE_REFRESH_LOG:?}"
if [[ "${FAKE_REFRESH_FAIL:-0}" == "1" ]]; then
  echo "hook stdout secret: ${FAKE_REFRESH_SECRET:?}"
  echo "hook stderr secret: ${FAKE_REFRESH_SECRET:?}" >&2
  exit 9
fi
if [[ "${FAKE_REFRESH_SIGNAL:-0}" == "1" ]]; then
  printf '{"GH_TOKEN":"signal-secret-token"}\n'
  kill -TERM "$PPID"
  sleep 1
  exit 0
fi
[[ "${FAKE_REFRESH_SIDE_EFFECT_ONLY:-0}" != "1" ]] || exit 0
if [[ "$LOOP_SPEC_CREDENTIAL_REFRESH_REASON" == "auth-retry" ]]; then
  printf '{"GH_TOKEN":"refreshed-token"}\n'
else
  printf '{"GH_TOKEN":"initial-token"}\n'
fi
REFRESH
chmod +x "$REFRESH_HOOK"

reset_gh() {
  local prs="${1:-[]}" checks="${2:-[]}" no_required="${3:-false}" no_checks="${4:-false}"
  jq -n --argjson prs "$prs" --argjson checks "$checks" --argjson noRequired "$no_required" \
    --argjson noChecks "$no_checks" \
    '{prs:$prs,checks:$checks,checkIndex:0,viewCount:0,noRequired:$noRequired,noChecks:$noChecks}' > "$GH_STATE"
  : > "$GH_LOG"
}

run_delivery() {
  PATH="$WORK/shims:$PATH" FAKE_GH_STATE="$GH_STATE" FAKE_GH_LOG="$GH_LOG" \
    FAKE_GH_HEAD_SHA="$TARGET_SHA" bash "$SCRIPT" final -C "$WORK/repo" \
      --branch feat/delivery --base main --sha "$TARGET_SHA" \
      --title "feat: delivery" --body-file "$BODY" \
      --checks-timeout 2 --checks-interval 0
}

run_delivery_with_refresh() {
  PATH="$WORK/shims:$PATH" REAL_GIT="$REAL_GIT" \
    FAKE_GH_STATE="$GH_STATE" FAKE_GH_LOG="$GH_LOG" FAKE_GH_HEAD_SHA="$TARGET_SHA" \
    FAKE_GIT_COUNT="$WORK/git-push-count" FAKE_REFRESH_LOG="$REFRESH_LOG" \
    LOOP_SPEC_CREDENTIAL_REFRESH_CMD="$REFRESH_HOOK" bash "$SCRIPT" final -C "$WORK/repo" \
      --branch feat/delivery --base main --sha "$TARGET_SHA" \
      --title "feat: delivery" --body-file "$BODY" \
      --checks-timeout 2 --checks-interval 0 "$@"
}

# Create one draft, wait pending -> pass, then mark ready.
reset_gh '[]' '[[{"name":"test","workflow":"CI","bucket":"pending","state":"IN_PROGRESS","link":"u"}],[{"name":"test","workflow":"CI","bucket":"pass","state":"SUCCESS","link":"u"}]]'
ec=0; out="$(run_delivery 2>"$WORK/err")" || ec=$?
check "create: exit 0" "0" "$ec"
check "create: stdout is one JSON document" "1" "$(jq -s 'length' <<<"$out" 2>/dev/null)"
check "create: valid result" "true" "$(jq -r '.ok' <<<"$out" 2>/dev/null)"
check "create: delivered" "delivered" "$(jq -r '.outcome' <<<"$out" 2>/dev/null)"
check "create: exact target recorded" "$TARGET_SHA" "$(jq -r '.targetSha' <<<"$out" 2>/dev/null)"
check "create: exact target pushed" "$TARGET_SHA" "$(git --git-dir="$WORK/origin.git" rev-parse refs/heads/feat/delivery)"
check "create: required checks passed" "passed" "$(jq -r '.checks.status' <<<"$out" 2>/dev/null)"
check "create: PR ready" "false" "$(jq -r '.prs[0].isDraft' "$GH_STATE")"
check "create: one PR create" "1" "$(grep -c '^pr create ' "$GH_LOG" || true)"
check "create: identity resolved from push remote" "1" \
  "$(grep -cF "repo view $WORK/origin.git --json nameWithOwner,url" "$GH_LOG" || true)"

# Rerun reuses the same PR and performs no duplicate create/readiness mutation.
: > "$GH_LOG"
ec=0; out="$(run_delivery 2>"$WORK/err")" || ec=$?
check "rerun: exit 0" "0" "$ec"
check "rerun: PR reused" "reused" "$(jq -r '.prAction' <<<"$out" 2>/dev/null)"
check "rerun: no create" "0" "$(grep -c '^pr create ' "$GH_LOG" || true)"
check "rerun: no ready mutation" "0" "$(grep -c '^pr ready ' "$GH_LOG" || true)"

# Push and verification use the same configured push URL even when fetch differs.
git init --bare -q "$WORK/fetch-only.git"
git -C "$WORK/repo" remote set-url origin "$WORK/fetch-only.git"
git -C "$WORK/repo" config remote.origin.pushurl "$WORK/origin.git"
: > "$GH_LOG"; ec=0; out="$(run_delivery 2>"$WORK/err")" || ec=$?
check "push URL: exit 0" "0" "$ec"
check "push URL: exact target remains at push destination" "$TARGET_SHA" \
  "$(git --git-dir="$WORK/origin.git" rev-parse refs/heads/feat/delivery)"
check "push URL: fetch destination untouched" "1" \
  "$(git --git-dir="$WORK/fetch-only.git" show-ref --verify --quiet refs/heads/feat/delivery; echo $?)"
git -C "$WORK/repo" config --unset-all remote.origin.pushurl || true
git -C "$WORK/repo" remote set-url origin "$WORK/origin.git"

# Multiple push destinations are ambiguous and rejected before transport.
git -C "$WORK/repo" config --add remote.origin.pushurl "$WORK/origin.git"
git -C "$WORK/repo" config --add remote.origin.pushurl "$WORK/fetch-only.git"
ec=0; out="$(run_delivery 2>"$WORK/err")" || ec=$?
check "multiple push URLs: exit 2" "2" "$ec"
check "multiple push URLs: structured code" "remote_ambiguous" "$(jq -r '.errorCode' <<<"$out")"
git -C "$WORK/repo" config --unset-all remote.origin.pushurl || true

# A checkpoint draft is updated in place and promoted only after green checks.
checkpoint="$(jq -cn --arg sha "$TARGET_SHA" '{number:9,url:"https://github.com/test/repo/pull/9",isDraft:true,
  headRefOid:$sha,headRefName:"feat/delivery",headRepository:{nameWithOwner:"test/repo"},
  isCrossRepository:false,baseRefName:"wrong",title:"WIP",body:"old",state:"OPEN"}')"
reset_gh "[$checkpoint]" '[[]]' true
ec=0; out="$(run_delivery 2>"$WORK/err")" || ec=$?
check "checkpoint: exit 0" "0" "$ec"
check "checkpoint: reused number" "9" "$(jq -r '.prNumber' <<<"$out" 2>/dev/null)"
check "checkpoint: metadata updated" "updated" "$(jq -r '.metadataAction' <<<"$out" 2>/dev/null)"
check "checkpoint: no duplicate" "0" "$(grep -c '^pr create ' "$GH_LOG" || true)"
check "checkpoint: title reconciled" "feat: delivery" "$(jq -r '.prs[0].title' "$GH_STATE")"
check "checkpoint: body reconciled" "1" "$(jq -r '.prs[0].body | contains("A body with")' "$GH_STATE" | grep -c true)"
check "checkpoint: marked ready" "false" "$(jq -r '.prs[0].isDraft' "$GH_STATE")"

# Real gh uses a generic no-checks error before any workflow context exists.
checkpoint="$(jq -c '.isDraft=true' <<<"$checkpoint")"
reset_gh "[$checkpoint]" '[[]]' false true
ec=0
out="$(PATH="$WORK/shims:$PATH" FAKE_GH_STATE="$GH_STATE" FAKE_GH_LOG="$GH_LOG" \
  FAKE_GH_HEAD_SHA="$TARGET_SHA" LOOP_SPEC_CHECKS_REGISTRATION_GRACE_SECONDS=0 \
  bash "$SCRIPT" final -C "$WORK/repo" --branch feat/delivery --base main \
  --sha "$TARGET_SHA" --title "feat: delivery" --body-file "$BODY" \
  --checks-timeout 2 --checks-interval 0 2>"$WORK/err")" || ec=$?
check "no checks configured: exit 0" "0" "$ec"
check "no checks configured: status none" "none" "$(jq -r '.checks.status' <<<"$out")"

# An empty successful check response is registration lag, not proof that no checks exist.
checkpoint="$(jq -c '.isDraft=true' <<<"$checkpoint")"
reset_gh "[$checkpoint]" '[[],[{"name":"test","workflow":"CI","bucket":"pass","state":"SUCCESS","link":"u"}]]'
ec=0; out="$(run_delivery 2>"$WORK/err")" || ec=$?
check "registration lag: exit 0" "0" "$ec"
check "registration lag: waits for checks" "2" "$(grep -c '^pr checks ' "$GH_LOG" || true)"
check "registration lag: eventual pass" "passed" "$(jq -r '.checks.status' <<<"$out" 2>/dev/null)"

# --hold-ready proves green checks but holds the draft->ready flip for staged delivery.
checkpoint="$(jq -c '.isDraft=true' <<<"$checkpoint")"
reset_gh "[$checkpoint]" '[[{"name":"test","workflow":"CI","bucket":"pass","state":"SUCCESS","link":"u"}]]'
ec=0
out="$(PATH="$WORK/shims:$PATH" FAKE_GH_STATE="$GH_STATE" FAKE_GH_LOG="$GH_LOG" \
  FAKE_GH_HEAD_SHA="$TARGET_SHA" bash "$SCRIPT" final -C "$WORK/repo" \
  --branch feat/delivery --base main --sha "$TARGET_SHA" --title "feat: delivery" \
  --body-file "$BODY" --hold-ready --checks-timeout 2 --checks-interval 0 2>"$WORK/err")" || ec=$?
check "hold-ready: exit 0" "0" "$ec"
check "hold-ready: outcome ready-pending" "ready-pending" "$(jq -r '.outcome' <<<"$out")"
check "hold-ready: readiness held" "held" "$(jq -r '.readinessAction' <<<"$out")"
check "hold-ready: checks proven passed" "passed" "$(jq -r '.checks.status' <<<"$out")"
check "hold-ready: PR left as draft" "true" "$(jq -r '.prs[0].isDraft' "$GH_STATE")"
check "hold-ready: no ready mutation" "0" "$(grep -c '^pr ready ' "$GH_LOG" || true)"

# A staged call cannot claim to hold a PR that is already externally ready.
ready_checkpoint="$(jq -c '.isDraft=false' <<<"$checkpoint")"
reset_gh "[$ready_checkpoint]" '[[{"name":"test","workflow":"CI","bucket":"pass","state":"SUCCESS","link":"u"}]]'
ec=0
out="$(PATH="$WORK/shims:$PATH" FAKE_GH_STATE="$GH_STATE" FAKE_GH_LOG="$GH_LOG" \
  FAKE_GH_HEAD_SHA="$TARGET_SHA" bash "$SCRIPT" final -C "$WORK/repo" \
  --branch feat/delivery --base main --sha "$TARGET_SHA" --title "feat: delivery" \
  --body-file "$BODY" --hold-ready --checks-timeout 2 --checks-interval 0 2>"$WORK/err")" || ec=$?
check "hold-ready already ready: exit 1" "1" "$ec"
check "hold-ready already ready: structured code" "pr_already_ready" "$(jq -r '.errorCode' <<<"$out")"

# Workspace rollback uses the same bounded controller to restore an already-promoted PR.
reset_gh "[$ready_checkpoint]" '[[{"name":"test","workflow":"CI","bucket":"pass","state":"SUCCESS","link":"u"}]]'
ec=0
out="$(PATH="$WORK/shims:$PATH" FAKE_GH_STATE="$GH_STATE" FAKE_GH_LOG="$GH_LOG" \
  FAKE_GH_HEAD_SHA="$TARGET_SHA" bash "$SCRIPT" final -C "$WORK/repo" \
  --branch feat/delivery --base main --sha "$TARGET_SHA" --title "feat: delivery" \
  --body-file "$BODY" --restore-draft --checks-timeout 2 --checks-interval 0 2>"$WORK/err")" || ec=$?
check "restore-draft: exit 0" "0" "$ec"
check "restore-draft: outcome ready-pending" "ready-pending" "$(jq -r '.outcome' <<<"$out")"
check "restore-draft: rolled back" "true" "$(jq -r '.prs[0].isDraft' "$GH_STATE")"

# A failed required check is a structured failure and the draft stays draft.
checkpoint="$(jq -cn --arg sha "$TARGET_SHA" '{number:10,url:"https://github.com/test/repo/pull/10",isDraft:true,
  headRefOid:$sha,headRefName:"feat/delivery",headRepository:{nameWithOwner:"test/repo"},
  isCrossRepository:false,baseRefName:"main",title:"feat: delivery",body:"",state:"OPEN"}')"
reset_gh "[$checkpoint]" '[[{"name":"test","workflow":"CI","bucket":"fail","state":"FAILURE","link":"u"}]]'
ec=0; out="$(run_delivery 2>"$WORK/err")" || ec=$?
check "checks fail: exit 1" "1" "$ec"
check "checks fail: structured code" "checks_failed" "$(jq -r '.errorCode' <<<"$out" 2>/dev/null)"
check "checks fail: not ready" "true" "$(jq -r '.prs[0].isDraft' "$GH_STATE")"

# Pending is not success; a bounded wait returns checks_timeout and keeps draft.
reset_gh "[$checkpoint]" '[[{"name":"test","workflow":"CI","bucket":"pending","state":"QUEUED","link":"u"}]]'
ec=0
out="$(PATH="$WORK/shims:$PATH" FAKE_GH_STATE="$GH_STATE" FAKE_GH_LOG="$GH_LOG" \
  FAKE_GH_HEAD_SHA="$TARGET_SHA" bash "$SCRIPT" final -C "$WORK/repo" \
  --branch feat/delivery --base main --sha "$TARGET_SHA" --title "feat: delivery" \
  --body-file "$BODY" --checks-timeout 0 --checks-interval 0 2>"$WORK/err")" || ec=$?
check "checks pending: exit 1" "1" "$ec"
check "checks pending: timeout code" "checks_timeout" "$(jq -r '.errorCode' <<<"$out" 2>/dev/null)"
check "checks pending: not ready" "true" "$(jq -r '.prs[0].isDraft' "$GH_STATE")"

# A hung gh request is bounded independently of the polling deadline.
reset_gh "[$checkpoint]" '[[]]'
started="$(date +%s)"; ec=0
out="$(PATH="$WORK/shims:$PATH" FAKE_GH_STATE="$GH_STATE" FAKE_GH_LOG="$GH_LOG" \
  FAKE_GH_HEAD_SHA="$TARGET_SHA" FAKE_GH_HANG_ON_CHECKS=1 \
  LOOP_SPEC_GH_COMMAND_TIMEOUT_SECONDS=1 bash "$SCRIPT" final -C "$WORK/repo" \
  --branch feat/delivery --base main --sha "$TARGET_SHA" --title "feat: delivery" \
  --body-file "$BODY" --checks-timeout 30 --checks-interval 0 2>"$WORK/err")" || ec=$?
elapsed=$(( $(date +%s) - started ))
check "hung checks: exit 1" "1" "$ec"
check "hung checks: timeout code" "checks_timeout" "$(jq -r '.errorCode' <<<"$out" 2>/dev/null)"
check "hung checks: bounded" "1" "$([[ "$elapsed" -lt 5 ]] && echo 1 || echo 0)"

# A command timeout wins even when the killed process emitted parseable partial JSON.
reset_gh "[$checkpoint]" '[[]]'
ec=0
out="$(PATH="$WORK/shims:$PATH" FAKE_GH_STATE="$GH_STATE" FAKE_GH_LOG="$GH_LOG" \
  FAKE_GH_HEAD_SHA="$TARGET_SHA" FAKE_GH_PARTIAL_HANG_ON_CHECKS=1 \
  LOOP_SPEC_GH_COMMAND_TIMEOUT_SECONDS=1 bash "$SCRIPT" final -C "$WORK/repo" \
  --branch feat/delivery --base main --sha "$TARGET_SHA" --title "feat: delivery" \
  --body-file "$BODY" --checks-timeout 30 --checks-interval 0 2>"$WORK/err")" || ec=$?
check "partial hung checks: exit 1" "1" "$ec"
check "partial hung checks: timeout code" "checks_timeout" "$(jq -r '.errorCode' <<<"$out")"

# PR head drift is rejected before readiness/check success can be claimed.
reset_gh "[$checkpoint]" '[[]]'
ec=0
out="$(PATH="$WORK/shims:$PATH" FAKE_GH_STATE="$GH_STATE" FAKE_GH_LOG="$GH_LOG" \
  FAKE_GH_HEAD_SHA="$TARGET_SHA" FAKE_GH_HEAD_OVERRIDE="0000000000000000000000000000000000000000" \
  bash "$SCRIPT" final -C "$WORK/repo" --branch feat/delivery --base main \
  --sha "$TARGET_SHA" --title "feat: delivery" --body-file "$BODY" \
  --checks-timeout 1 --checks-interval 0 2>"$WORK/err")" || ec=$?
check "head drift: exit 1" "1" "$ec"
check "head drift: structured code" "pr_head_moved" "$(jq -r '.errorCode' <<<"$out" 2>/dev/null)"

# A head move after green checks is rejected before the draft is promoted.
reset_gh "[$checkpoint]" '[[{"name":"test","workflow":"CI","bucket":"pass","state":"SUCCESS","link":"u"}]]'
ec=0
out="$(PATH="$WORK/shims:$PATH" FAKE_GH_STATE="$GH_STATE" FAKE_GH_LOG="$GH_LOG" \
  FAKE_GH_HEAD_SHA="$TARGET_SHA" FAKE_GH_HEAD_OVERRIDE_AFTER_CHECKS=1 \
  FAKE_GH_HEAD_OVERRIDE="0000000000000000000000000000000000000000" \
  bash "$SCRIPT" final -C "$WORK/repo" --branch feat/delivery --base main \
  --sha "$TARGET_SHA" --title "feat: delivery" --body-file "$BODY" \
  --checks-timeout 1 --checks-interval 0 2>"$WORK/err")" || ec=$?
check "pre-ready drift: exit 1" "1" "$ec"
check "pre-ready drift: structured code" "pr_head_moved" "$(jq -r '.errorCode' <<<"$out" 2>/dev/null)"
check "pre-ready drift: no promotion" "0" "$(grep -c '^pr ready ' "$GH_LOG" || true)"

# Metadata is revalidated before promotion, not only afterward.
reset_gh "[$checkpoint]" '[[{"name":"test","workflow":"CI","bucket":"pass","state":"SUCCESS","link":"u"}]]'
ec=0
out="$(PATH="$WORK/shims:$PATH" FAKE_GH_STATE="$GH_STATE" FAKE_GH_LOG="$GH_LOG" \
  FAKE_GH_HEAD_SHA="$TARGET_SHA" FAKE_GH_METADATA_OVERRIDE_AFTER_CHECKS=1 \
  bash "$SCRIPT" final -C "$WORK/repo" --branch feat/delivery --base main \
  --sha "$TARGET_SHA" --title "feat: delivery" --body-file "$BODY" \
  --checks-timeout 1 --checks-interval 0 2>"$WORK/err")" || ec=$?
check "pre-ready metadata drift: exit 1" "1" "$ec"
check "pre-ready metadata drift: structured code" "metadata_drift" "$(jq -r '.errorCode' <<<"$out")"
check "pre-ready metadata drift: no promotion" "0" "$(grep -c '^pr ready ' "$GH_LOG" || true)"

# If the head races after promotion, best-effort rollback restores draft state.
reset_gh "[$checkpoint]" '[[{"name":"test","workflow":"CI","bucket":"pass","state":"SUCCESS","link":"u"}]]'
ec=0
out="$(PATH="$WORK/shims:$PATH" FAKE_GH_STATE="$GH_STATE" FAKE_GH_LOG="$GH_LOG" \
  FAKE_GH_HEAD_SHA="$TARGET_SHA" FAKE_GH_MOVE_HEAD_ON_READY=1 \
  bash "$SCRIPT" final -C "$WORK/repo" --branch feat/delivery --base main \
  --sha "$TARGET_SHA" --title "feat: delivery" --body-file "$BODY" \
  --checks-timeout 1 --checks-interval 0 2>"$WORK/err")" || ec=$?
check "post-ready race: exit 1" "1" "$ec"
check "post-ready race: structured code" "pr_head_moved" "$(jq -r '.errorCode' <<<"$out")"
check "post-ready race: rolled back to draft" "true" "$(jq -r '.prs[0].isDraft' "$GH_STATE")"

# A hinted PR from another repository cannot be reconciled against this remote.
wrong_repo="$(jq -c '.url="https://github.com/other/repo/pull/10"' <<<"$checkpoint")"
reset_gh "[$wrong_repo]" '[[]]' true
ec=0
out="$(PATH="$WORK/shims:$PATH" FAKE_GH_STATE="$GH_STATE" FAKE_GH_LOG="$GH_LOG" \
  FAKE_GH_HEAD_SHA="$TARGET_SHA" bash "$SCRIPT" final -C "$WORK/repo" \
  --branch feat/delivery --base main --sha "$TARGET_SHA" --title "feat: delivery" \
  --body-file "$BODY" --pr-url "https://github.com/other/repo/pull/10" \
  --checks-timeout 2 --checks-interval 0 2>"$WORK/err")" || ec=$?
check "PR identity mismatch: exit 1" "1" "$ec"
check "PR identity mismatch: structured code" "pr_identity_mismatch" "$(jq -r '.errorCode' <<<"$out" 2>/dev/null)"

# Host and head-repository identity are part of the same invariant.
reset_gh "[$checkpoint]" '[[]]' true
ec=0
out="$(PATH="$WORK/shims:$PATH" FAKE_GH_STATE="$GH_STATE" FAKE_GH_LOG="$GH_LOG" \
  FAKE_GH_HEAD_SHA="$TARGET_SHA" FAKE_GH_REPO_URL="https://ghe.example/test/repo" \
  bash "$SCRIPT" final -C "$WORK/repo" --branch feat/delivery --base main \
  --sha "$TARGET_SHA" --title "feat: delivery" --body-file "$BODY" \
  --checks-timeout 2 --checks-interval 0 2>"$WORK/err")" || ec=$?
check "PR host mismatch: exit 1" "1" "$ec"
check "PR host mismatch: structured code" "pr_identity_mismatch" "$(jq -r '.errorCode' <<<"$out")"

# GitHub Enterprise can omit the same-repository head identity. The canonical
# PR URL, non-cross-repository flag, branch, and exact SHA still bind the PR.
ghe_checkpoint="$(jq -c '
  .url="https://ghe.example/test/repo/pull/10"
  | .headRepository.nameWithOwner=""
' <<<"$checkpoint")"
reset_gh "[$ghe_checkpoint]" '[[]]' true
ec=0
out="$(PATH="$WORK/shims:$PATH" FAKE_GH_STATE="$GH_STATE" FAKE_GH_LOG="$GH_LOG" \
  FAKE_GH_HEAD_SHA="$TARGET_SHA" FAKE_GH_REPO_URL="https://ghe.example/test/repo" \
  bash "$SCRIPT" final -C "$WORK/repo" --branch feat/delivery --base main \
  --sha "$TARGET_SHA" --title "feat: delivery" --body-file "$BODY" \
  --checks-timeout 2 --checks-interval 0 2>"$WORK/err")" || ec=$?
check "GHE empty head repo: exit 0" "0" "$ec"
check "GHE empty head repo: delivered" "delivered" "$(jq -r '.outcome' <<<"$out")"

# An empty head identity is never sufficient for a cross-repository PR.
ghe_fork="$(jq -c '.isCrossRepository=true' <<<"$ghe_checkpoint")"
reset_gh "[$ghe_fork]" '[[]]' true
ec=0
out="$(PATH="$WORK/shims:$PATH" FAKE_GH_STATE="$GH_STATE" FAKE_GH_LOG="$GH_LOG" \
  FAKE_GH_HEAD_SHA="$TARGET_SHA" FAKE_GH_REPO_URL="https://ghe.example/test/repo" \
  bash "$SCRIPT" final -C "$WORK/repo" --branch feat/delivery --base main \
  --sha "$TARGET_SHA" --title "feat: delivery" --body-file "$BODY" \
  --checks-timeout 2 --checks-interval 0 2>"$WORK/err")" || ec=$?
check "GHE empty fork head repo: exit 1" "1" "$ec"
check "GHE empty fork head repo: identity mismatch" "pr_identity_mismatch" "$(jq -r '.errorCode' <<<"$out")"

# A populated head identity must still equal the pushed repository even when gh
# reports that the PR is not cross-repository.
same_repo_mismatch="$(jq -c '.headRepository.nameWithOwner="other/repo"' <<<"$checkpoint")"
reset_gh "[$same_repo_mismatch]" '[[]]' true
ec=0
out="$(run_delivery 2>"$WORK/err")" || ec=$?
check "same-repo head mismatch: exit 1" "1" "$ec"
check "same-repo head mismatch: identity mismatch" "pr_identity_mismatch" "$(jq -r '.errorCode' <<<"$out")"

reset_gh "[$checkpoint]" '[[]]' true
ec=0
out="$(PATH="$WORK/shims:$PATH" FAKE_GH_STATE="$GH_STATE" FAKE_GH_LOG="$GH_LOG" \
  FAKE_GH_HEAD_SHA="$TARGET_SHA" FAKE_GH_HEAD_REPO="fork/repo" \
  bash "$SCRIPT" final -C "$WORK/repo" --branch feat/delivery --base main \
  --sha "$TARGET_SHA" --title "feat: delivery" --body-file "$BODY" \
  --checks-timeout 2 --checks-interval 0 2>"$WORK/err")" || ec=$?
check "PR head repo mismatch: exit 1" "1" "$ec"
check "PR head repo mismatch: structured code" "pr_identity_mismatch" "$(jq -r '.errorCode' <<<"$out")"

# Malformed gh field types fail with one structured result.
reset_gh "[$checkpoint]" '[[]]' true
ec=0
out="$(PATH="$WORK/shims:$PATH" FAKE_GH_STATE="$GH_STATE" FAKE_GH_LOG="$GH_LOG" \
  FAKE_GH_HEAD_SHA="$TARGET_SHA" FAKE_GH_BAD_DRAFT_TYPE=1 \
  bash "$SCRIPT" final -C "$WORK/repo" --branch feat/delivery --base main \
  --sha "$TARGET_SHA" --title "feat: delivery" --body-file "$BODY" \
  --checks-timeout 2 --checks-interval 0 2>"$WORK/err")" || ec=$?
check "malformed PR fields: exit 1" "1" "$ec"
check "malformed PR fields: one JSON document" "1" "$(jq -s 'length' <<<"$out")"
check "malformed PR fields: structured code" "pr_lookup_failed" "$(jq -r '.errorCode' <<<"$out")"

# A known checkpoint identity survives failures that occur before PR lookup.
reset_gh '[]' '[]'
hint_url="https://github.com/test/repo/pull/77"
ec=0
out="$(PATH="$WORK/shims:$PATH" FAKE_GH_STATE="$GH_STATE" FAKE_GH_LOG="$GH_LOG" \
  FAKE_GH_HEAD_SHA="$TARGET_SHA" FAKE_GH_REPO_FAIL=1 \
  bash "$SCRIPT" final -C "$WORK/repo" --branch feat/delivery --base main \
  --sha "$TARGET_SHA" --title "feat: delivery" --body-file "$BODY" --pr-url "$hint_url" \
  --checks-timeout 1 --checks-interval 0 2>"$WORK/err")" || ec=$?
check "early failure hint: exit 1" "1" "$ec"
check "early failure hint: URL retained" "$hint_url" "$(jq -r '.prUrl' <<<"$out" 2>/dev/null)"
check "early failure hint: number retained" "77" "$(jq -r '.prNumber' <<<"$out" 2>/dev/null)"

# Credential hooks run in the target repository before authenticated stages.
reset_gh "[$ready_checkpoint]" '[[{"name":"test","workflow":"CI","bucket":"pass","state":"SUCCESS","link":"u"}]]'
: > "$REFRESH_LOG"; rm -f "$WORK/git-push-count"
ec=0; out="$(FAKE_REFRESH_SIDE_EFFECT_ONLY=1 run_delivery_with_refresh 2>"$WORK/err")" || ec=$?
check "credential pre-stage: exit 0" "0" "$ec"
check "credential pre-stage: push context" "1" \
  "$(grep -cF "push|pre-stage|github.com|$TARGET_REPO" "$REFRESH_LOG" || true)"
check "credential pre-stage: GitHub context" "1" \
  "$([[ "$(grep -c '^github-.*|pre-stage|' "$REFRESH_LOG" || true)" -gt 0 ]] && echo 1 || echo 0)"

# A git authentication failure refreshes credentials and retries the exact push once.
reset_gh "[$ready_checkpoint]" '[[{"name":"test","workflow":"CI","bucket":"pass","state":"SUCCESS","link":"u"}]]'
: > "$REFRESH_LOG"; rm -f "$WORK/git-push-count"
ec=0
out="$(FAKE_GIT_AUTH_MODE=once run_delivery_with_refresh 2>"$WORK/err")" || ec=$?
check "credential retry: exit 0" "0" "$ec"
check "credential retry: push attempted twice" "2" "$(<"$WORK/git-push-count")"
check "credential retry: one auth refresh" "1" \
  "$(grep -c '^push|auth-retry|' "$REFRESH_LOG" || true)"

# A second authentication failure is terminal; there is no third attempt.
reset_gh "[$ready_checkpoint]" '[]'
: > "$REFRESH_LOG"; rm -f "$WORK/git-push-count"
ec=0
out="$(FAKE_GIT_AUTH_MODE=always run_delivery_with_refresh 2>"$WORK/err")" || ec=$?
check "credential second failure: exit 1" "1" "$ec"
check "credential second failure: stable code" "authentication_failed" "$(jq -r '.errorCode' <<<"$out")"
check "credential second failure: exactly two attempts" "2" "$(<"$WORK/git-push-count")"

# Non-auth transport failures are not retried.
reset_gh "[$ready_checkpoint]" '[]'
: > "$REFRESH_LOG"; rm -f "$WORK/git-push-count"
ec=0
out="$(FAKE_GIT_AUTH_MODE=nonauth run_delivery_with_refresh 2>"$WORK/err")" || ec=$?
check "credential non-auth: exit 1" "1" "$ec"
check "credential non-auth: push code retained" "push_failed" "$(jq -r '.errorCode' <<<"$out")"
check "credential non-auth: one attempt" "1" "$(<"$WORK/git-push-count")"
check "credential non-auth: no auth refresh" "0" \
  "$(grep -c '^push|auth-retry|' "$REFRESH_LOG" || true)"

# Hook failures are structured and neither output stream exposes hook secrets.
reset_gh "[$ready_checkpoint]" '[]'
: > "$REFRESH_LOG"; secret="refresh-secret-value"
ec=0
out="$(FAKE_REFRESH_FAIL=1 FAKE_REFRESH_SECRET="$secret" run_delivery_with_refresh 2>"$WORK/err")" || ec=$?
check "credential hook failure: exit 1" "1" "$ec"
check "credential hook failure: stable code" "credential_refresh_failed" "$(jq -r '.errorCode' <<<"$out")"
check "credential hook failure: stdout redacted" "0" "$(grep -cF "$secret" <<<"$out" || true)"
check "credential hook failure: stderr redacted" "0" "$(grep -cF "$secret" "$WORK/err" || true)"

# An auth-looking create failure is re-listed before create could be repeated.
reset_gh '[]' '[[{"name":"test","workflow":"CI","bucket":"pass","state":"SUCCESS","link":"u"}]]'
: > "$REFRESH_LOG"; rm -f "$WORK/create-auth-once"
ec=0
out="$(FAKE_GH_CREATE_AUTH_ONCE=1 FAKE_GH_CREATE_AUTH_MARKER="$WORK/create-auth-once" \
  run_delivery_with_refresh 2>"$WORK/err")" || ec=$?
check "credential create reconcile: exit 0" "0" "$ec"
check "credential create reconcile: one create" "1" "$(grep -c '^pr create ' "$GH_LOG" || true)"
check "credential create reconcile: re-listed" "2" "$(grep -c '^pr list ' "$GH_LOG" || true)"
check "credential create reconcile: PR reused" "reused" "$(jq -r '.prAction' <<<"$out")"

# Ambiguous readiness success is observed before any retry.
checkpoint="$(jq -c '.isDraft=true' <<<"$checkpoint")"
reset_gh "[$checkpoint]" '[[{"name":"test","workflow":"CI","bucket":"pass","state":"SUCCESS","link":"u"}]]'
: > "$REFRESH_LOG"
ec=0
out="$(FAKE_GH_READY_AUTH_AFTER_APPLY=ready run_delivery_with_refresh 2>"$WORK/err")" || ec=$?
check "ready ambiguity: exit 0" "0" "$ec"
check "ready ambiguity: delivered" "delivered" "$(jq -r '.outcome' <<<"$out")"
check "ready ambiguity: desired state accepted" "false" "$(jq -r '.prs[0].isDraft' "$GH_STATE")"
check "ready ambiguity: mutation not repeated" "1" "$(grep -c '^pr ready ' "$GH_LOG" || true)"
check "ready ambiguity: credentials refreshed" "1" \
  "$(grep -c '^github-pr|auth-retry|' "$REFRESH_LOG" || true)"

# The same reconciliation applies to --undo readiness mutations.
reset_gh "[$ready_checkpoint]" '[[{"name":"test","workflow":"CI","bucket":"pass","state":"SUCCESS","link":"u"}]]'
: > "$REFRESH_LOG"
ec=0
out="$(FAKE_GH_READY_AUTH_AFTER_APPLY=undo run_delivery_with_refresh --restore-draft \
  2>"$WORK/err")" || ec=$?
check "undo ambiguity: exit 0" "0" "$ec"
check "undo ambiguity: desired state accepted" "true" "$(jq -r '.prs[0].isDraft' "$GH_STATE")"
check "undo ambiguity: mutation not repeated" "1" "$(grep -c '^pr ready ' "$GH_LOG" || true)"
check "undo ambiguity: credentials refreshed" "1" \
  "$(grep -c '^github-pr|auth-retry|' "$REFRESH_LOG" || true)"

# A signal during token output leaves no private credential files behind.
mkdir -p "$WORK/refresh-tmp"
reset_gh "[$ready_checkpoint]" '[]'
: > "$REFRESH_LOG"
ec=0
out="$(TMPDIR="$WORK/refresh-tmp" FAKE_REFRESH_SIGNAL=1 run_delivery_with_refresh \
  2>"$WORK/err")" || ec=$?
refresh_leftovers=("$WORK/refresh-tmp"/loop-spec-credential-refresh-*)
[[ -e "${refresh_leftovers[0]}" ]] || refresh_leftovers=()
check "credential signal cleanup: exit 1" "1" "$ec"
check "credential signal cleanup: stable code" "credential_refresh_failed" "$(jq -r '.errorCode' <<<"$out")"
check "credential signal cleanup: no token files" "0" "${#refresh_leftovers[@]}"
check "credential signal cleanup: secret redacted" "0" \
  "$(grep -cF 'signal-secret-token' <<<"$out$(<"$WORK/err")" || true)"

# Bad invocation is distinct from an operational delivery failure.
ec=0; out="$(bash "$SCRIPT" final -C "$WORK/repo" 2>/dev/null)" || ec=$?
check "bad invocation: exit 2" "2" "$ec"
check "bad invocation: JSON result" "false" "$(jq -r '.ok' <<<"$out" 2>/dev/null)"

ec=0; out="$(bash "$SCRIPT" final -C "$WORK/repo" --branch 2>/dev/null)" || ec=$?
check "missing option value: exit 2" "2" "$ec"
check "missing option value: structured code" "missing_argument" "$(jq -r '.errorCode' <<<"$out")"
ec=0
out="$(bash "$SCRIPT" final -C "$WORK/repo" --branch feat/delivery --base main --sha "$TARGET_SHA" \
  --title t --body-file "$BODY" --checks-timeout nope 2>/dev/null)" || ec=$?
check "bad timeout: exit 2" "2" "$ec"
check "bad timeout: one JSON document" "1" "$(jq -s 'length' <<<"$out")"
check "bad timeout: structured code" "bad_timeout" "$(jq -r '.errorCode' <<<"$out")"
ec=0
out="$(bash "$SCRIPT" final -C "$WORK/repo" --branch feat/delivery --base main --sha "$TARGET_SHA" \
  --title t --body-file "$BODY" --checks-timeout 999999999999999999999 2>/dev/null)" || ec=$?
check "oversized timeout: exit 2" "2" "$ec"
check "oversized timeout: structured code" "bad_timeout" "$(jq -r '.errorCode' <<<"$out")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
