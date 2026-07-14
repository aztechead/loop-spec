#!/usr/bin/env bash
# Reconcile one exact git commit into one GitHub PR.
#
# Usage:
#   pr-delivery.sh checkpoint|final -C <repo> \
#     --branch <head> --base <base> --sha <full-sha> \
#     --title <title> --body-file <path> [--pr-url <url>] \
#     [--remote origin] [--checks-timeout 900] [--checks-interval 10] [--hold-ready]
#
# --hold-ready (final only): push, reconcile the PR, and wait for green required
# checks, but stop before the draft->ready flip (outcome "ready-pending"). A second,
# plain final call promotes it. Callers use this to stage multi-repo readiness so no
# PR is marked ready until every repo in the feature has cleared its checks.
#
# stdout is exactly one JSON result. Diagnostics go to stderr.
# Exit 0: delivered/checkpointed; 1: operational or policy failure; 2: bad input.
set -uo pipefail

mode="${1:-}"
shift || true

repo_dir="."
parse_error=""
if [[ "${1:-}" == "-C" ]]; then
  if [[ $# -lt 2 ]]; then
    parse_error="-C requires a value"
    shift
  else
    repo_dir="$2"
    shift 2
  fi
fi

branch=""
base_branch=""
target_arg=""
title=""
body_file=""
pr_url_hint=""
remote="origin"
checks_timeout="${LOOP_SPEC_CHECKS_TIMEOUT_SECONDS:-900}"
checks_interval="${LOOP_SPEC_CHECKS_INTERVAL_SECONDS:-10}"
command_timeout="${LOOP_SPEC_GH_COMMAND_TIMEOUT_SECONDS:-60}"
registration_grace="${LOOP_SPEC_CHECKS_REGISTRATION_GRACE_SECONDS:-30}"
hold_ready=0
unknown_arg=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hold-ready) hold_ready=1; shift ;;
    --branch|--base|--sha|--title|--body-file|--pr-url|--remote|--checks-timeout|--checks-interval)
      if [[ $# -lt 2 ]]; then
        parse_error="$1 requires a value"
        shift
        break
      fi
      option="$1"; value="$2"; shift 2
      case "$option" in
        --branch) branch="$value" ;;
        --base) base_branch="$value" ;;
        --sha) target_arg="$value" ;;
        --title) title="$value" ;;
        --body-file) body_file="$value" ;;
        --pr-url) pr_url_hint="$value" ;;
        --remote) remote="$value" ;;
        --checks-timeout) checks_timeout="$value" ;;
        --checks-interval) checks_interval="$value" ;;
      esac
      ;;
    *) unknown_arg="$1"; shift ;;
  esac
done

target_sha=""
remote_sha=""
head_sha=""
repo_identity=""
repo_selector=""
repo_host=""
remote_url=""
pr_number="null"
pr_url="$pr_url_hint"
if [[ "$pr_url_hint" =~ /pull/([0-9]+)(/|$) ]]; then
  pr_number="${BASH_REMATCH[1]}"
fi
pr_action="none"
metadata_action="none"
readiness_action="none"
is_draft="null"
checks_json='{"status":"not-run","timeoutSeconds":0,"elapsedSeconds":0,"counts":{"pass":0,"skipping":0,"pending":0,"fail":0,"cancel":0},"required":[]}'

emit_result() {
  local ok="$1" outcome="$2" error_code="$3" error_message="$4"
  local observed
  observed="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -cn \
    --argjson ok "$ok" \
    --arg mode "$mode" \
    --arg outcome "$outcome" \
    --arg repo "$repo_identity" \
    --arg branch "$branch" \
    --arg base "$base_branch" \
    --arg target "$target_sha" \
    --arg remoteSha "$remote_sha" \
    --arg headSha "$head_sha" \
    --argjson number "$pr_number" \
    --arg url "$pr_url" \
    --arg prAction "$pr_action" \
    --arg metadataAction "$metadata_action" \
    --arg readinessAction "$readiness_action" \
    --argjson draft "$is_draft" \
    --argjson checks "$checks_json" \
    --arg observed "$observed" \
    --arg errorCode "$error_code" \
    --arg error "$error_message" \
    '{schema:1,ok:$ok,mode:$mode,outcome:$outcome,
      repo:(if $repo == "" then null else $repo end),
      branch:(if $branch == "" then null else $branch end),
      baseBranch:(if $base == "" then null else $base end),
      targetSha:(if $target == "" then null else $target end),
      remoteSha:(if $remoteSha == "" then null else $remoteSha end),
      headSha:(if $headSha == "" then null else $headSha end),
      prNumber:$number,
      prUrl:(if $url == "" then null else $url end),
      prAction:$prAction,metadataAction:$metadataAction,
      readinessAction:$readinessAction,isDraft:$draft,checks:$checks,
      observedAt:$observed,
      errorCode:(if $errorCode == "" then null else $errorCode end),
      error:(if $error == "" then null else $error end)}'
}

fail_bad() {
  echo "pr-delivery: $2" >&2
  emit_result false "invalid" "$1" "$2"
  exit 2
}

fail_delivery() {
  echo "pr-delivery: $2" >&2
  emit_result false "blocked" "$1" "$2"
  exit 1
}

[[ "$mode" == "checkpoint" || "$mode" == "final" ]] \
  || fail_bad "bad_mode" "mode must be checkpoint or final"
[[ -z "$parse_error" ]] || fail_bad "missing_argument" "$parse_error"
[[ -z "$unknown_arg" ]] || fail_bad "unknown_argument" "unknown argument: $unknown_arg"
[[ -d "$repo_dir" ]] || fail_bad "repo_missing" "repository directory does not exist: $repo_dir"
repo_dir="$(cd "$repo_dir" && pwd -P)"
[[ -n "$branch" && -n "$base_branch" && -n "$target_arg" && -n "$title" && -n "$body_file" ]] \
  || fail_bad "missing_argument" "--branch, --base, --sha, --title, and --body-file are required"
[[ -r "$body_file" ]] || fail_bad "body_unreadable" "body file is not readable: $body_file"
[[ "$checks_timeout" =~ ^[0-9]+$ ]] || fail_bad "bad_timeout" "--checks-timeout must be a non-negative integer"
[[ "$checks_interval" =~ ^[0-9]+$ ]] || fail_bad "bad_interval" "--checks-interval must be a non-negative integer"
[[ "$command_timeout" =~ ^[1-9][0-9]*$ ]] || fail_bad "bad_command_timeout" "LOOP_SPEC_GH_COMMAND_TIMEOUT_SECONDS must be a positive integer"
[[ "$registration_grace" =~ ^[0-9]+$ ]] || fail_bad "bad_registration_grace" "LOOP_SPEC_CHECKS_REGISTRATION_GRACE_SECONDS must be a non-negative integer"
checks_timeout=$((10#$checks_timeout))
checks_interval=$((10#$checks_interval))
command_timeout=$((10#$command_timeout))
registration_grace=$((10#$registration_grace))
checks_json="$(jq -cn --argjson timeout "$checks_timeout" \
  '{status:"not-run",timeoutSeconds:$timeout,elapsedSeconds:0,
    counts:{pass:0,skipping:0,pending:0,fail:0,cancel:0},required:[]}')"

git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || fail_bad "not_git_repo" "not a git work tree: $repo_dir"
git check-ref-format --branch "$branch" >/dev/null 2>&1 \
  || fail_bad "bad_branch" "invalid head branch: $branch"
git check-ref-format --branch "$base_branch" >/dev/null 2>&1 \
  || fail_bad "bad_base" "invalid base branch: $base_branch"
target_sha="$(git -C "$repo_dir" rev-parse --verify "${target_arg}^{commit}" 2>/dev/null)" \
  || fail_bad "bad_sha" "target is not a local commit: $target_arg"
git -C "$repo_dir" remote get-url "$remote" >/dev/null 2>&1 \
  || fail_bad "remote_missing" "remote '$remote' is not configured"
push_urls=()
while IFS= read -r push_url; do
  [[ -n "$push_url" ]] && push_urls+=("$push_url")
done < <(git -C "$repo_dir" remote get-url --push --all "$remote" 2>/dev/null)
[[ "${#push_urls[@]}" -gt 0 ]] || fail_bad "remote_missing" "remote '$remote' has no push URL"
[[ "${#push_urls[@]}" -eq 1 ]] \
  || fail_bad "remote_ambiguous" "remote '$remote' has multiple push URLs; exact delivery requires one destination"
remote_url="${push_urls[0]}"
command -v gh >/dev/null 2>&1 || fail_bad "gh_missing" "gh is not on PATH"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/loop-spec-pr-delivery-XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
export GH_PROMPT_DISABLED=1 GIT_TERMINAL_PROMPT=0
export LOOP_SPEC_PR_DELIVERY_CWD="$repo_dir"

# Run a network command with a per-call timeout. Python 3.6 supports communicate(timeout=).
run_gh() {
  local stdout_file="$1" stderr_file="$2"
  shift 2
  python3 - "$command_timeout" "$stdout_file" "$stderr_file" "$@" <<'PY'
import os, signal, subprocess, sys

timeout = int(sys.argv[1])
stdout_path, stderr_path = sys.argv[2], sys.argv[3]
argv = sys.argv[4:]
try:
    proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            universal_newlines=True, preexec_fn=os.setsid,
                            cwd=os.environ.get("LOOP_SPEC_PR_DELIVERY_CWD") or None)
    try:
        out, err = proc.communicate(timeout=timeout)
        rc = proc.returncode
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            out, err = proc.communicate(timeout=1)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            out, err = proc.communicate()
        err = (err or "") + "\ncommand timed out"
        rc = 124
except OSError as exc:
    out, err, rc = "", str(exc), 127
with open(stdout_path, "w") as f:
    f.write(out or "")
with open(stderr_path, "w") as f:
    f.write(err or "")
sys.exit(rc)
PY
}

gh_out="$tmp_dir/gh.out"
gh_err="$tmp_dir/gh.err"
refresh_remote_sha() {
  local rc=0
  run_gh "$tmp_dir/git-ls-remote.out" "$tmp_dir/git-ls-remote.err" \
    git -C "$repo_dir" ls-remote "$remote_url" "refs/heads/$branch" || rc=$?
  [[ "$rc" -eq 0 ]] || return "$rc"
  remote_sha="$(awk 'NR == 1 {print $1}' "$tmp_dir/git-ls-remote.out")"
}

# Resolve GitHub identity from the exact push URL, not whichever remote gh happens
# to prefer in the working tree.
if ! run_gh "$gh_out" "$gh_err" gh repo view "$remote_url" --json nameWithOwner,url; then
  fail_delivery "gh_error" "cannot resolve GitHub repository: $(tr '\n' ' ' < "$gh_err")"
fi
repo_identity="$(jq -r '.nameWithOwner // empty' "$gh_out" 2>/dev/null)"
[[ -n "$repo_identity" ]] || fail_delivery "gh_error" "gh repo view returned no repository identity"
canonical_repo_url="$(jq -r '.url // empty' "$gh_out" 2>/dev/null)"
[[ -n "$canonical_repo_url" ]] || fail_delivery "gh_error" "gh repo view returned no canonical repository URL"
repo_host="$(python3 - "$canonical_repo_url" <<'PY'
import sys
try:
    from urllib.parse import urlparse
except ImportError:
    from urlparse import urlparse

host = (urlparse(sys.argv[1]).hostname or "").lower()
if not host:
    sys.exit(1)
if host == "www.github.com":
    host = "github.com"
print(host)
PY
)" || fail_delivery "gh_error" "cannot derive repository selector from '$canonical_repo_url'"
repo_selector="$repo_host/$repo_identity"

# Push the requested commit, not HEAD, then prove the remote ref is identical.
push_rc=0
run_gh "$tmp_dir/git-push.out" "$tmp_dir/git-push.err" \
  git -C "$repo_dir" push "$remote_url" "$target_sha:refs/heads/$branch" || push_rc=$?
if [[ "$push_rc" -ne 0 ]]; then
  fail_delivery "push_failed" "exact-SHA push failed: $(tr '\n' ' ' < "$tmp_dir/git-push.err")"
fi
refresh_remote_sha || fail_delivery "remote_query_failed" "cannot read pushed branch: $(tr '\n' ' ' < "$tmp_dir/git-ls-remote.err")"
[[ "$remote_sha" == "$target_sha" ]] \
  || fail_delivery "remote_sha_mismatch" "remote branch is '$remote_sha', expected '$target_sha'"

pr_json=""
pr_fields="number,url,isDraft,headRefOid,headRefName,headRepository,isCrossRepository,baseRefName,title,body,state"
view_pr() {
  local ref="$1"
  if ! run_gh "$gh_out" "$gh_err" gh pr view "$ref" --repo "$repo_selector" \
      --json "$pr_fields"; then
    return 1
  fi
  jq -e 'type == "object"' "$gh_out" >/dev/null 2>&1
}

validate_pr_snapshot() {
  local context="$1" pr_repo_identity pr_url_host head_repo
  local parsed=()
  jq -e '
    type == "object"
    and (.number | type == "number" and floor == . and . > 0)
    and (.url | type == "string" and length > 0)
    and (.isDraft | type == "boolean")
    and (.headRefOid | type == "string")
    and (.headRefName | type == "string")
    and (.baseRefName | type == "string")
    and (.title | type == "string")
    and (.body | type == "string")
    and (.state | type == "string")
    and (.isCrossRepository | type == "boolean")
    and (.headRepository | type == "object")
    and (.headRepository.nameWithOwner | type == "string" and length > 0)
  ' <<<"$pr_json" >/dev/null 2>&1 \
    || fail_delivery "pr_lookup_failed" "$context returned malformed PR fields"

  pr_number="$(jq -r '.number' <<<"$pr_json")"
  pr_url="$(jq -r '.url' <<<"$pr_json")"
  head_sha="$(jq -r '.headRefOid' <<<"$pr_json")"
  is_draft="$(jq -r '.isDraft' <<<"$pr_json")"
  pr_state="$(jq -r '.state' <<<"$pr_json")"
  pr_head="$(jq -r '.headRefName' <<<"$pr_json")"
  head_repo="$(jq -r '.headRepository.nameWithOwner' <<<"$pr_json")"

  while IFS= read -r parsed_value; do
    parsed+=("$parsed_value")
  done < <(python3 - "$pr_url" <<'PY'
import sys
try:
    from urllib.parse import urlparse
except ImportError:
    from urlparse import urlparse

parsed = urlparse(sys.argv[1])
host = (parsed.hostname or "").lower()
if host == "www.github.com":
    host = "github.com"
parts = [part for part in parsed.path.split("/") if part]
if not host or len(parts) != 4 or parts[2] != "pull" or not parts[3].isdigit():
    sys.exit(1)
print(host)
print(parts[0] + "/" + parts[1])
PY
  )
  [[ "${#parsed[@]}" -eq 2 ]] \
    || fail_delivery "pr_identity_mismatch" "$context returned a malformed PR URL: '$pr_url'"
  pr_url_host="${parsed[0]}"
  pr_repo_identity="${parsed[1]}"
  [[ "$pr_url_host" == "$repo_host" && "$pr_repo_identity" == "$repo_identity" ]] \
    || fail_delivery "pr_identity_mismatch" "PR '$pr_url_host/$pr_repo_identity' does not match pushed repository '$repo_selector'"
  [[ "$head_repo" == "$repo_identity" && "$(jq -r '.isCrossRepository' <<<"$pr_json")" == "false" ]] \
    || fail_delivery "pr_identity_mismatch" "PR head repository '$head_repo' does not match pushed repository '$repo_identity'"
  [[ "$pr_state" == "OPEN" ]] || fail_delivery "pr_closed" "PR is not open"
  [[ "$pr_head" == "$branch" ]] \
    || fail_delivery "pr_identity_mismatch" "PR head '$pr_head' does not match '$branch'"
  [[ "$head_sha" == "$target_sha" ]] \
    || fail_delivery "pr_head_moved" "PR head is '$head_sha', expected verified SHA '$target_sha'"
}

if [[ -n "$pr_url_hint" ]]; then
  view_pr "$pr_url_hint" || fail_delivery "pr_lookup_failed" "cannot load hinted PR '$pr_url_hint'"
  pr_json="$(jq -c . "$gh_out")"
  pr_action="reused"
else
  if ! run_gh "$gh_out" "$gh_err" gh pr list --repo "$repo_selector" --head "$branch" \
      --state open --json "$pr_fields"; then
    fail_delivery "pr_lookup_failed" "cannot list PRs for '$branch': $(tr '\n' ' ' < "$gh_err")"
  fi
  list_count="$(jq -r 'if type == "array" then length else -1 end' "$gh_out" 2>/dev/null || echo -1)"
  [[ "$list_count" -ge 0 ]] || fail_delivery "pr_lookup_failed" "gh pr list returned malformed JSON"
  [[ "$list_count" -le 1 ]] || fail_delivery "pr_ambiguous" "multiple open PRs found for '$branch'"
  if [[ "$list_count" -eq 1 ]]; then
    pr_json="$(jq -c '.[0]' "$gh_out")"
    pr_action="reused"
  else
    create_rc=0
    run_gh "$gh_out" "$gh_err" gh pr create --draft --repo "$repo_selector" \
      --base "$base_branch" --head "$branch" --title "$title" --body-file "$body_file" \
      || create_rc=$?
    if [[ "$create_rc" -ne 0 ]]; then
      # A concurrent delivery may have won the create race. Re-list once.
      run_gh "$gh_out" "$gh_err" gh pr list --repo "$repo_selector" --head "$branch" \
        --state open --json "$pr_fields" \
        || fail_delivery "pr_create_failed" "gh pr create failed"
      [[ "$(jq -r 'length' "$gh_out" 2>/dev/null)" == "1" ]] \
        || fail_delivery "pr_create_failed" "gh pr create failed and no unique PR appeared"
      pr_json="$(jq -c '.[0]' "$gh_out")"
      pr_action="reused"
    else
      created_ref="$(tr -d '\r\n' < "$gh_out")"
      [[ -n "$created_ref" ]] || fail_delivery "pr_create_failed" "gh pr create returned no PR URL"
      view_pr "$created_ref" || fail_delivery "pr_create_failed" "created PR could not be loaded"
      pr_json="$(jq -c . "$gh_out")"
      pr_action="created"
    fi
  fi
fi

validate_pr_snapshot "PR lookup"

expected_body="$(cat "$body_file")"
actual_title="$(jq -r '.title // ""' <<<"$pr_json")"
actual_base="$(jq -r '.baseRefName // ""' <<<"$pr_json")"
actual_body="$(jq -r '.body // ""' <<<"$pr_json")"
if [[ "$actual_title" != "$title" || "$actual_base" != "$base_branch" || "$actual_body" != "$expected_body" ]]; then
  if ! run_gh "$gh_out" "$gh_err" gh pr edit "$pr_number" --repo "$repo_selector" \
      --title "$title" --base "$base_branch" --body-file "$body_file"; then
    fail_delivery "metadata_failed" "failed to reconcile PR title, body, or base"
  fi
  metadata_action="updated"
  view_pr "$pr_number" || fail_delivery "metadata_failed" "updated PR could not be refreshed"
  pr_json="$(jq -c . "$gh_out")"
  validate_pr_snapshot "metadata refresh"
else
  metadata_action="unchanged"
fi

actual_title="$(jq -r '.title' <<<"$pr_json")"
actual_base="$(jq -r '.baseRefName' <<<"$pr_json")"
actual_body="$(jq -r '.body' <<<"$pr_json")"
[[ "$actual_title" == "$title" && "$actual_base" == "$base_branch" && "$actual_body" == "$expected_body" ]] \
  || fail_delivery "metadata_failed" "PR title, body, or base did not reconcile"

if [[ "$mode" == "checkpoint" ]]; then
  checks_json="$(jq -cn --argjson timeout "$checks_timeout" \
    '{status:"skipped",timeoutSeconds:$timeout,elapsedSeconds:0,
      counts:{pass:0,skipping:0,pending:0,fail:0,cancel:0},required:[]}')"
  readiness_action="unchanged"
  emit_result true "checkpointed" "" ""
  exit 0
fi

checks_started="$(date +%s)"
while :; do
  view_pr "$pr_number" || fail_delivery "pr_lookup_failed" "cannot refresh PR before checking CI"
  pr_json="$(jq -c . "$gh_out")"
  validate_pr_snapshot "CI refresh"

  checks_rc=0
  run_gh "$gh_out" "$gh_err" gh pr checks "$pr_number" --repo "$repo_selector" \
    --required --json name,workflow,bucket,state,link || checks_rc=$?
  [[ "$checks_rc" -ne 124 ]] \
    || fail_delivery "checks_timeout" "gh pr checks exceeded its command timeout"

  checks_payload=""
  no_checks_confirmed=false
  if jq -e 'type == "array"' "$gh_out" >/dev/null 2>&1; then
    checks_payload="$(jq -c . "$gh_out")"
  elif grep -qi "no required checks" "$gh_err" 2>/dev/null; then
    checks_payload="[]"
    no_checks_confirmed=true
  elif grep -qi "no checks reported" "$gh_err" 2>/dev/null; then
    checks_payload="[]"
  else
    fail_delivery "checks_unsupported" "required checks could not be read: $(tr '\n' ' ' < "$gh_err")"
  fi

  jq -e 'all(.[];
    type == "object" and (.bucket | type == "string") and
    (.bucket == "pass" or .bucket == "skipping" or .bucket == "pending" or
     .bucket == "fail" or .bucket == "cancel"))' <<<"$checks_payload" >/dev/null 2>&1 \
    || fail_delivery "checks_unsupported" "required checks returned malformed fields or an unknown bucket"

  counts="$(jq -c '{pass:([.[]|select(.bucket=="pass")]|length),
    skipping:([.[]|select(.bucket=="skipping")]|length),
    pending:([.[]|select(.bucket=="pending")]|length),
    fail:([.[]|select(.bucket=="fail")]|length),
    cancel:([.[]|select(.bucket=="cancel")]|length)}' <<<"$checks_payload")"
  now_epoch="$(date +%s)"
  elapsed=$((now_epoch - checks_started))
  failed="$(jq -r '.fail + .cancel' <<<"$counts")"
  pending="$(jq -r '.pending' <<<"$counts")"
  total="$(jq -r 'length' <<<"$checks_payload")"

  if [[ "$elapsed" -gt "$checks_timeout" ]]; then
    checks_json="$(jq -cn --argjson timeout "$checks_timeout" --argjson elapsed "$elapsed" \
      --argjson counts "$counts" --argjson required "$checks_payload" \
      '{status:"timeout",timeoutSeconds:$timeout,elapsedSeconds:$elapsed,counts:$counts,required:$required}')"
    fail_delivery "checks_timeout" "required-check observation exceeded ${checks_timeout}s"
  fi

  # Empty output and gh's generic "no checks reported" error are ambiguous just
  # after push. Give workflows a bounded registration window, then classify no CI.
  if [[ "$total" -eq 0 && "$no_checks_confirmed" != "true" ]]; then
    checks_json="$(jq -cn --argjson timeout "$checks_timeout" --argjson elapsed "$elapsed" \
      --argjson counts "$counts" \
      '{status:"pending-registration",timeoutSeconds:$timeout,elapsedSeconds:$elapsed,counts:$counts,required:[]}')"
    if [[ "$elapsed" -ge "$registration_grace" ]]; then
      checks_json="$(jq -cn --argjson timeout "$checks_timeout" --argjson elapsed "$elapsed" \
        --argjson counts "$counts" \
        '{status:"none",timeoutSeconds:$timeout,elapsedSeconds:$elapsed,counts:$counts,required:[]}')"
      break
    fi
    [[ "$elapsed" -ge "$checks_timeout" ]] \
      && fail_delivery "checks_timeout" "required checks did not register within ${checks_timeout}s"
    sleep_for="$checks_interval"
    remaining=$((checks_timeout - elapsed))
    [[ "$sleep_for" -le "$remaining" ]] || sleep_for="$remaining"
    [[ "$sleep_for" -gt 0 ]] && sleep "$sleep_for"
    continue
  fi

  if [[ "$failed" -gt 0 ]]; then
    checks_json="$(jq -cn --argjson timeout "$checks_timeout" --argjson elapsed "$elapsed" \
      --argjson counts "$counts" --argjson required "$checks_payload" \
      '{status:"failed",timeoutSeconds:$timeout,elapsedSeconds:$elapsed,counts:$counts,required:$required}')"
    fail_delivery "checks_failed" "one or more required checks failed or were cancelled"
  fi
  if [[ "$pending" -eq 0 ]]; then
    check_status="passed"
    [[ "$total" -eq 0 ]] && check_status="none"
    checks_json="$(jq -cn --arg status "$check_status" --argjson timeout "$checks_timeout" \
      --argjson elapsed "$elapsed" --argjson counts "$counts" --argjson required "$checks_payload" \
      '{status:$status,timeoutSeconds:$timeout,elapsedSeconds:$elapsed,counts:$counts,required:$required}')"
    break
  fi
  if [[ "$elapsed" -ge "$checks_timeout" ]]; then
    checks_json="$(jq -cn --argjson timeout "$checks_timeout" --argjson elapsed "$elapsed" \
      --argjson counts "$counts" --argjson required "$checks_payload" \
      '{status:"timeout",timeoutSeconds:$timeout,elapsedSeconds:$elapsed,counts:$counts,required:$required}')"
    fail_delivery "checks_timeout" "required checks did not finish within ${checks_timeout}s"
  fi
  sleep_for="$checks_interval"
  remaining=$((checks_timeout - elapsed))
  [[ "$sleep_for" -le "$remaining" ]] || sleep_for="$remaining"
  [[ "$sleep_for" -gt 0 ]] && sleep "$sleep_for"
done

# Re-read both refs immediately before changing review visibility. Checks can pass
# and then a concurrent push can move the head before `gh pr ready` runs.
view_pr "$pr_number" || fail_delivery "pr_lookup_failed" "cannot refresh PR before readiness transition"
pr_json="$(jq -c . "$gh_out")"
validate_pr_snapshot "pre-readiness refresh"
refresh_remote_sha || fail_delivery "remote_query_failed" "cannot read remote branch before readiness transition"
[[ "$remote_sha" == "$target_sha" ]] \
  || fail_delivery "remote_sha_mismatch" "remote branch moved to '$remote_sha' before readiness transition"

# Staged delivery (multi-repo workspaces): prove push + identity + green required
# checks, but hold the draft->ready flip so no PR in the set is promoted until every
# repo has cleared its checks. The caller promotes with a second, plain final call.
if [[ "$hold_ready" == "1" ]]; then
  readiness_action="held"
  emit_result true "ready-pending" "" ""
  exit 0
fi

if [[ "$is_draft" == "true" ]]; then
  run_gh "$gh_out" "$gh_err" gh pr ready "$pr_number" --repo "$repo_selector" \
    || fail_delivery "ready_failed" "required checks passed but the draft PR could not be marked ready"
  readiness_action="marked_ready"
else
  readiness_action="unchanged"
fi

view_pr "$pr_number" || fail_delivery "pr_lookup_failed" "cannot perform final PR observation"
pr_json="$(jq -c . "$gh_out")"
validate_pr_snapshot "final PR observation"
refresh_remote_sha || fail_delivery "remote_query_failed" "cannot read remote branch for final observation"
[[ "$remote_sha" == "$target_sha" ]] \
  || fail_delivery "remote_sha_mismatch" "final remote SHA no longer matches '$target_sha'"
[[ "$is_draft" == "false" ]] || fail_delivery "ready_failed" "PR remains a draft after readiness transition"
actual_title="$(jq -r '.title' <<<"$pr_json")"
actual_base="$(jq -r '.baseRefName' <<<"$pr_json")"
actual_body="$(jq -r '.body' <<<"$pr_json")"
[[ "$actual_title" == "$title" && "$actual_base" == "$base_branch" && "$actual_body" == "$expected_body" ]] \
  || fail_delivery "metadata_drift" "PR title, body, or base changed during required-check polling"

emit_result true "delivered" "" ""
