#!/usr/bin/env bash
# Feature-level adapter for lib/pr-delivery.sh.
#
# Usage: deliver.sh run <feature_dir>
#
# Reads the schema-7 feature topology, renders the final PR body, and delivers each
# changed repository. Successful/external delivery observations are written to the
# ignored delivery.json sidecar so the exact checked SHA stays clean; code-remediation
# failures atomically route tracked feature.json back to EXECUTE.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_DELIVERY="${LOOP_SPEC_PR_DELIVERY_BIN:-$SCRIPT_DIR/pr-delivery.sh}"

cmd="${1:-}"
feature_dir="${2:-}"
[[ "$cmd" == "run" && -n "$feature_dir" ]] || {
  echo "usage: deliver.sh run <feature_dir>" >&2
  exit 2
}
[[ -f "$feature_dir/feature.json" ]] || {
  echo "deliver: feature.json not found in $feature_dir" >&2
  exit 2
}
[[ -x "$PR_DELIVERY" || -f "$PR_DELIVERY" ]] || {
  echo "deliver: PR delivery controller not found: $PR_DELIVERY" >&2
  exit 2
}

feature_dir="$(cd "$feature_dir" && pwd)"
feature_json="$feature_dir/feature.json"
delivery_file="$feature_dir/delivery.json"
jq -e '.schemaVersion == 7 and (.currentPhase == "deliver")' "$feature_json" >/dev/null 2>&1 || {
  echo "deliver: feature must be schema 7 at currentPhase=deliver" >&2
  exit 2
}

slug="$(jq -r '.slug' "$feature_json")"
feature_title="$(jq -r '.feature_title // .slug' "$feature_json")"
workspace_root="$(jq -r '.workspace.root // empty' "$feature_json")"
if [[ -n "$workspace_root" ]]; then
  artifact_root="$workspace_root"
else
  artifact_root="$(git -C "$feature_dir" rev-parse --show-toplevel 2>/dev/null)" || {
    echo "deliver: feature directory is not inside a git work tree" >&2
    exit 2
  }
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/loop-spec-deliver-XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
body_file="$tmp_dir/pr-body.md"

# Concise GFM body — bounded excerpts + artifact links, never whole artifacts.
# Formatting policy lives in lib/pr-body.sh (one home; also the reference for
# micro/debug PR bodies).
bash "$SCRIPT_DIR/pr-body.sh" render "$feature_json" "$artifact_root" "$body_file" || {
  echo "deliver: PR body render failed" >&2
  exit 1
}

checks_timeout="${LOOP_SPEC_CHECKS_TIMEOUT_SECONDS:-900}"
checks_interval="${LOOP_SPEC_CHECKS_INTERVAL_SECONDS:-10}"
attempted_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Every observation is appended here; the delivered/skipped/held/failure counts are
# derived from this set after all targets are processed.
targets="[]"

invoke_delivery() {
  local repo_dir="$1" branch="$2" base="$3" sha="$4" title="$5" hint="$6" hold="${7:-0}" restore="${8:-0}"
  local args result rc=0
  args=(final -C "$repo_dir" --branch "$branch" --base "$base" --sha "$sha"
        --title "$title" --body-file "$body_file"
        --checks-timeout "$checks_timeout" --checks-interval "$checks_interval")
  [[ "$hold" == "1" ]] && args+=(--hold-ready)
  [[ "$restore" == "1" ]] && args+=(--restore-draft)
  [[ -n "$hint" ]] && args+=(--pr-url "$hint")
  result="$(bash "$PR_DELIVERY" "${args[@]}")" || rc=$?
  if ! jq -e 'type == "object" and has("ok")' <<<"$result" >/dev/null 2>&1; then
    result="$(jq -cn --arg repo "$repo_dir" --arg branch "$branch" --arg base "$base" --arg sha "$sha" \
      --arg hint "$hint" \
      --argjson rc "$rc" '{schema:1,ok:false,mode:"final",outcome:"blocked",repo:$repo,
        branch:$branch,baseBranch:$base,targetSha:$sha,remoteSha:null,headSha:null,
        prNumber:null,prUrl:(if $hint == "" then null else $hint end),prAction:"none",metadataAction:"none",
        readinessAction:"none",isDraft:null,checks:{status:"not-run",required:[]},
        observedAt:null,errorCode:"controller_error",error:("controller exited " + ($rc|tostring))}')"
    rc=1
  fi
  printf '%s\n' "$result"
  return "$rc"
}

append_target_failure() {
  local name="$1" path="$2" branch="$3" base="$4" sha="$5" hint="$6" code="$7" message="$8" observed="${9:-}" bindable="${10:-false}"
  local record
  record="$(jq -cn --arg name "$name" --arg path "$path" --arg branch "$branch" \
    --arg base "$base" --arg sha "$sha" --arg hint "$hint" --arg code "$code" --arg error "$message" --arg observed "$observed" --argjson bindable "$bindable" \
    '{schema:1,ok:false,mode:"final",outcome:"blocked",name:$name,path:$path,repo:null,
      branch:$branch,baseBranch:$base,targetSha:(if $sha == "" then null else $sha end),
      observedSha:(if $observed == "" then null else $observed end),
      bindingEligible:$bindable,
      remoteSha:null,headSha:null,prNumber:null,prUrl:(if $hint == "" then null else $hint end),
      prAction:"none",metadataAction:"none",readinessAction:"none",isDraft:null,
      checks:{status:"not-run",required:[]},observedAt:null,errorCode:$code,error:$error}')"
  targets="$(jq -c --argjson record "$record" '. + [$record]' <<<"$targets")"
}

# The prior attempt's sidecar. A hard delivery failure leaves nextPhase="deliver"
# and records the exact targetSha it tried; a resumed retry must re-deliver that
# same SHA (not whatever HEAD now is) so the push, checks, and readiness all bind
# to the verified commit. A remediation route (nextPhase="execute") intentionally
# produces a new SHA, so binding is skipped there.
prior_next=""
prior_targets="[]"
if [[ -f "$delivery_file" ]]; then
  prior_next="$(jq -r '.nextPhase // ""' "$delivery_file" 2>/dev/null || echo "")"
  prior_targets="$(jq -c '.targets // []' "$delivery_file" 2>/dev/null || echo "[]")"
fi
bound_target_sha() {
  local name="$1"
  [[ "$prior_next" == "deliver" || "$prior_next" == "completed" ]] || return 0
  jq -r --arg n "$name" \
    'def local_error: ["repo_invalid","repo_root_mismatch","branch_mismatch","git_status_failed",
       "dirty_worktree","base_sha_missing","base_sha_invalid","base_not_ancestor","no_commits",
       "git_history_failed","local_artifact_policy_failed"];
     [.[] | select(.name == $n and (.targetSha // "") != "") as $target
      | select($target.bindingEligible == true or
          (($target | has("bindingEligible") | not) and ((local_error | index($target.errorCode // "")) == null)))
      | .targetSha] | first // empty' \
    <<<"$prior_targets"
}

if [[ -z "$workspace_root" ]]; then
  bash "$SCRIPT_DIR/runtime-ignore.sh" ensure "$artifact_root" >/dev/null || {
    echo "deliver: failed to install local-artifact exclusions" >&2
    exit 2
  }
  branch="$(jq -r '.branch // empty' "$feature_json")"
  base_branch="$(jq -r '.baseBranch // "main"' "$feature_json")"
  base_sha="$(jq -r '.baseSha // empty' "$feature_json")"
  hint=""
  [[ -f "$delivery_file" ]] && hint="$(jq -r '.prUrl // empty' "$delivery_file" 2>/dev/null || true)"
  [[ -n "$hint" ]] || hint="$(jq -r '.prUrl // .checkpointPrUrl // empty' "$feature_json")"

  # Candidate preflight (parity with the workspace path): the artifact root must be
  # a git work tree at the repository root, on the recorded feature branch, with at
  # least one commit past the recorded base.
  preflight_ok=1
  repo_top="$(git -C "$artifact_root" rev-parse --show-toplevel 2>/dev/null || true)"
  actual_branch="$(git -C "$artifact_root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  target_sha="$(git -C "$artifact_root" rev-parse --verify HEAD 2>/dev/null || true)"
  dirty_state=""
  status_ok=1
  dirty_state="$(git -C "$artifact_root" status --porcelain --untracked-files=all 2>/dev/null)" || status_ok=0
  if [[ -z "$target_sha" ]]; then
    append_target_failure "$slug" "$artifact_root" "$branch" "$base_branch" "" "$hint" \
      "git_history_failed" "cannot resolve feature HEAD"
    preflight_ok=0
  elif [[ "$repo_top" != "$artifact_root" ]]; then
    append_target_failure "$slug" "$artifact_root" "$branch" "$base_branch" "$target_sha" "$hint" \
      "repo_root_mismatch" "feature directory does not name the repository root"
    preflight_ok=0
  elif [[ -n "$branch" && "$actual_branch" != "$branch" ]]; then
    append_target_failure "$slug" "$artifact_root" "$branch" "$base_branch" "$target_sha" "$hint" \
      "branch_mismatch" "checkout is on '$actual_branch', expected '$branch'"
    preflight_ok=0
  elif [[ -z "$base_sha" ]]; then
    append_target_failure "$slug" "$artifact_root" "$branch" "$base_branch" "$target_sha" "$hint" \
      "base_sha_missing" "feature state has no recorded base SHA"
    preflight_ok=0
  elif [[ -n "$base_sha" ]] && ! git -C "$artifact_root" rev-parse --verify "${base_sha}^{commit}" >/dev/null 2>&1; then
    append_target_failure "$slug" "$artifact_root" "$branch" "$base_branch" "$target_sha" "$hint" \
      "base_sha_invalid" "recorded base SHA is not a local commit"
    preflight_ok=0
  elif [[ -n "$base_sha" ]] && ! git -C "$artifact_root" merge-base --is-ancestor "$base_sha" "$target_sha"; then
    append_target_failure "$slug" "$artifact_root" "$branch" "$base_branch" "$target_sha" "$hint" \
      "base_not_ancestor" "recorded base SHA is not an ancestor of the candidate"
    preflight_ok=0
  elif [[ -n "$base_sha" ]] && [[ "$(git -C "$artifact_root" rev-list --count "${base_sha}..${target_sha}" 2>/dev/null || echo 0)" -eq 0 ]]; then
    append_target_failure "$slug" "$artifact_root" "$branch" "$base_branch" "$target_sha" "$hint" \
      "no_commits" "feature branch has no commits past its recorded base"
    preflight_ok=0
  elif [[ "$status_ok" -ne 1 ]]; then
    append_target_failure "$slug" "$artifact_root" "$branch" "$base_branch" "$target_sha" "$hint" \
      "git_status_failed" "cannot establish candidate worktree cleanliness" "" true
    preflight_ok=0
  elif [[ -n "$dirty_state" ]]; then
    append_target_failure "$slug" "$artifact_root" "$branch" "$base_branch" "$target_sha" "$hint" \
      "dirty_worktree" "candidate repository has uncommitted changes" "" true
    preflight_ok=0
  fi

  if [[ "$preflight_ok" -eq 1 ]]; then
    bound="$(bound_target_sha "$slug")"
    if [[ -n "$bound" && "$bound" != "$target_sha" ]]; then
      append_target_failure "$slug" "$artifact_root" "$branch" "$base_branch" "$bound" "$hint" \
        "candidate_sha_drift" "HEAD '$target_sha' drifted from the SHA the prior attempt verified '$bound'" "$target_sha" true
    else
      result_rc=0
      result="$(invoke_delivery "$artifact_root" "$branch" "$base_branch" "$target_sha" \
        "feat: $feature_title" "$hint")" || result_rc=$?
      record="$(jq -c --arg name "$slug" --arg path "$artifact_root" '. + {name:$name,path:$path,bindingEligible:true}' <<<"$result")"
      targets="$(jq -c --argjson record "$record" '. + [$record]' <<<"$targets")"
    fi
  fi
else
  # Pass 1 - preflight every configured repo. Blocked/zero-commit repos are recorded
  # now; repos with real commits are collected as deliverables for pass 2.
  deliverables="[]"
  while IFS= read -r repo_entry; do
    name="$(jq -r '.name' <<<"$repo_entry")"
    rel_path="$(jq -r '.path' <<<"$repo_entry")"
    repo_dir="$workspace_root/$rel_path"
    branch="$(jq -r '.branch' <<<"$repo_entry")"
    base_sha="$(jq -r '.baseSha' <<<"$repo_entry")"
    base_branch="$(jq -r '.baseBranch // "main"' <<<"$repo_entry")"
    hint=""
    [[ -f "$delivery_file" ]] && hint="$(jq -r --arg name "$name" \
      '.targets[]? | select(.name == $name) | .prUrl // empty' "$delivery_file" 2>/dev/null | head -1)"
    [[ -n "$hint" ]] || hint="$(jq -r --arg name "$name" \
      '.delivery.targets[]? | select(.name == $name) | .prUrl // empty' "$feature_json" | head -1)"

    if [[ ! -d "$repo_dir" ]] || ! git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      append_target_failure "$name" "$repo_dir" "$branch" "$base_branch" "" "$hint" \
        "repo_invalid" "workspace target is not a git work tree"
      continue
    fi
    repo_abs="$(cd "$repo_dir" && pwd -P)"
    if ! bash "$SCRIPT_DIR/runtime-ignore.sh" ensure "$repo_dir" >/dev/null; then
      append_target_failure "$name" "$repo_dir" "$branch" "$base_branch" "" "$hint" \
        "local_artifact_policy_failed" "cannot install local-artifact exclusions"
      continue
    fi
    repo_top="$(git -C "$repo_dir" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ "$repo_top" != "$repo_abs" ]]; then
      append_target_failure "$name" "$repo_dir" "$branch" "$base_branch" "" "$hint" \
        "repo_root_mismatch" "workspace target does not name the repository root"
      continue
    fi
    actual_branch="$(git -C "$repo_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if [[ "$actual_branch" != "$branch" ]]; then
      append_target_failure "$name" "$repo_dir" "$branch" "$base_branch" "" "$hint" \
        "branch_mismatch" "workspace target is on '$actual_branch', expected '$branch'"
      continue
    fi
    target_sha="$(git -C "$repo_dir" rev-parse --verify HEAD 2>/dev/null || true)"
    dirty_state=""
    status_ok=1
    dirty_state="$(git -C "$repo_dir" status --porcelain --untracked-files=all 2>/dev/null)" || status_ok=0
    if ! git -C "$repo_dir" rev-parse --verify "${base_sha}^{commit}" >/dev/null 2>&1; then
      append_target_failure "$name" "$repo_dir" "$branch" "$base_branch" "" "$hint" \
        "base_sha_invalid" "workspace base SHA is not a local commit"
      continue
    fi
    if [[ -n "$target_sha" ]] && ! git -C "$repo_dir" merge-base --is-ancestor "$base_sha" "$target_sha"; then
      append_target_failure "$name" "$repo_dir" "$branch" "$base_branch" "$target_sha" "$hint" \
        "base_not_ancestor" "workspace base SHA is not an ancestor of the candidate"
      continue
    fi
    if [[ -z "$target_sha" ]] || ! commit_count="$(git -C "$repo_dir" rev-list --count "${base_sha}..${target_sha}" 2>/dev/null)"; then
      append_target_failure "$name" "$repo_dir" "$branch" "$base_branch" "$target_sha" "$hint" \
        "git_history_failed" "cannot compare workspace target with its recorded base"
      continue
    fi
    if [[ "$status_ok" -ne 1 ]]; then
      append_target_failure "$name" "$repo_dir" "$branch" "$base_branch" "$target_sha" "$hint" \
        "git_status_failed" "cannot establish workspace worktree cleanliness" "" true
      continue
    fi
    if [[ -n "$dirty_state" ]]; then
      append_target_failure "$name" "$repo_dir" "$branch" "$base_branch" "$target_sha" "$hint" \
        "dirty_worktree" "workspace target has uncommitted changes" "" true
      continue
    fi
    if [[ "$commit_count" -eq 0 ]]; then
      record="$(jq -cn --arg name "$name" --arg path "$repo_dir" --arg branch "$branch" \
        --arg base "$base_branch" --arg hint "$hint" '{schema:1,ok:true,mode:"final",outcome:"skipped-no-commits",
          name:$name,path:$path,repo:null,branch:$branch,baseBranch:$base,targetSha:null,
          remoteSha:null,headSha:null,prNumber:null,prUrl:(if $hint == "" then null else $hint end),prAction:"none",
          metadataAction:"none",readinessAction:"none",isDraft:null,
          checks:{status:"skipped",required:[]},observedAt:null,errorCode:null,error:null}')"
      targets="$(jq -c --argjson record "$record" '. + [$record]' <<<"$targets")"
      continue
    fi
    bound="$(bound_target_sha "$name")"
    if [[ -n "$bound" && "$bound" != "$target_sha" ]]; then
      append_target_failure "$name" "$repo_dir" "$branch" "$base_branch" "$bound" "$hint" \
        "candidate_sha_drift" "HEAD '$target_sha' drifted from the SHA the prior attempt verified '$bound'" "$target_sha" true
      continue
    fi
    deliverables="$(jq -c --arg name "$name" --arg path "$repo_dir" --arg branch "$branch" \
      --arg base "$base_branch" --arg sha "$target_sha" --arg hint "$hint" \
      '. + [{name:$name,path:$path,branch:$branch,base:$base,sha:$sha,hint:$hint}]' <<<"$deliverables")"
  done < <(jq -c '.workspace.repos[]' "$feature_json")

  # Readiness is a feature-level invariant. If any configured target failed local
  # preflight, do not touch GitHub for otherwise-valid siblings.
  if [[ "$(jq '[.[] | select(.ok == false)] | length' <<<"$targets")" -gt 0 ]]; then
    while IFS= read -r entry; do
      append_target_failure "$(jq -r '.name' <<<"$entry")" "$(jq -r '.path' <<<"$entry")" \
        "$(jq -r '.branch' <<<"$entry")" "$(jq -r '.base' <<<"$entry")" \
        "$(jq -r '.sha' <<<"$entry")" "$(jq -r '.hint' <<<"$entry")" \
        "workspace_preflight_failed" "another workspace target failed local preflight" "" true
    done < <(jq -c '.[]' <<<"$deliverables")
    deliverables="[]"
  fi

  # Pass 2 - deliver. With two or more changed repos, stage readiness: prove every
  # repo's checks are green (held as drafts) before promoting any, so a single repo's
  # CI failure never leaves a half-ready set of PRs. One changed repo needs no staging.
  deliverable_count="$(jq 'length' <<<"$deliverables")"
  run_target() {
    local entry="$1" hold="$2" restore="${3:-0}" result_rc=0 result record
    local name path branch base sha hint
    name="$(jq -r '.name' <<<"$entry")"; path="$(jq -r '.path' <<<"$entry")"
    branch="$(jq -r '.branch' <<<"$entry")"; base="$(jq -r '.base' <<<"$entry")"
    sha="$(jq -r '.sha' <<<"$entry")"; hint="$(jq -r '.hint' <<<"$entry")"
    result="$(invoke_delivery "$path" "$branch" "$base" "$sha" \
      "feat: $feature_title ($name)" "$hint" "$hold" "$restore")" || result_rc=$?
    record="$(jq -c --arg name "$name" --arg path "$path" '. + {name:$name,path:$path,bindingEligible:true}' <<<"$result")"
    targets="$(jq -c --argjson record "$record" '. + [$record]' <<<"$targets")"
    return "$result_rc"
  }

  if [[ "$deliverable_count" -ge 2 ]]; then
    all_held=1
    while IFS= read -r entry; do
      run_target "$entry" 1 || all_held=0
    done < <(jq -c '.[]' <<<"$deliverables")
    if [[ "$all_held" -eq 1 ]]; then
      # Every repo cleared its checks. Promote each with a plain (idempotent) call.
      promoted="[]"
      promotion_failed=0
      while IFS= read -r entry; do
        if run_target "$entry" 0; then
          promoted="$(jq -c --argjson entry "$entry" '. + [$entry]' <<<"$promoted")"
        else
          promotion_failed=1
          break
        fi
      done < <(jq -c '.[]' <<<"$deliverables")
      if [[ "$promotion_failed" -eq 1 ]]; then
        while IFS= read -r entry; do
          run_target "$entry" 0 1 || true
        done < <(jq -c '.[]' <<<"$promoted")
      fi
      # Each promoted repo now has both its held and its delivered record; keep the
      # last delivered/rollback/failure observation per repo.
      targets="$(jq -c 'group_by(.name) | map(.[-1])' <<<"$targets")"
    fi
  else
    while IFS= read -r entry; do
      run_target "$entry" 0 || true
    done < <(jq -c '.[]' <<<"$deliverables")
  fi
fi

# Derive counts from the final target set. A "ready-pending" target is a staged repo
# that cleared its checks but was held back because a sibling repo failed; it is not
# delivered, so it keeps the feature out of ready-for-review.
delivered_count="$(jq '[.[] | select(.outcome == "delivered")] | length' <<<"$targets")"
skipped_count="$(jq '[.[] | select(.outcome == "skipped-no-commits")] | length' <<<"$targets")"
held_count="$(jq '[.[] | select(.outcome == "ready-pending")] | length' <<<"$targets")"
failure_count="$(jq '[.[] | select(.ok == false)] | length' <<<"$targets")"
first_error="$(jq -r '[.[] | select(.ok == false) | .errorCode // "delivery_failed"] | first // ""' <<<"$targets")"

status="ready-for-review"
finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ok=true
next_phase="completed"
ci_remediation_limit=2
ci_remediation_attempts="$(jq -r '
  (.delivery.ciRemediationAttempts // 0)
  | if type == "number" and . >= 0 and floor == . then . else 0 end
' "$feature_json")"
if [[ "$failure_count" -gt 0 || "$held_count" -gt 0 ]]; then
  ok=false
  finished_at=""
  if [[ "$failure_count" -eq 0 ]]; then
    # Every repo cleared checks but promotion did not complete; resume re-promotes.
    status="ready-pending"
  elif [[ "$delivered_count" -gt 0 || "$held_count" -gt 0 ]]; then
    status="partial"
  else
    status="${first_error//_/-}"
  fi
  all_checks_failed="$(jq -r '([.[] | select(.ok == false)] | length) > 0 and
    ([.[] | select(.ok == false) | .errorCode == "checks_failed"] | all)' <<<"$targets")"
  if [[ "$all_checks_failed" == "true" ]]; then
    if [[ "$ci_remediation_attempts" -lt "$ci_remediation_limit" ]]; then
      ci_remediation_attempts=$((ci_remediation_attempts + 1))
      next_phase="execute"
    else
      next_phase="deliver"
    fi
  else
    next_phase="deliver"
  fi
elif [[ "$delivered_count" -eq 0 ]]; then
  ok=false
  finished_at=""
  status="no-changes"
  next_phase="deliver"
fi

delivery="$(jq -cn --arg status "$status" --arg attempted "$attempted_at" \
  --arg finished "$finished_at" --arg nextPhase "$next_phase" --argjson targets "$targets" \
  --argjson ciAttempts "$ci_remediation_attempts" --argjson ciLimit "$ci_remediation_limit" \
  '{status:$status,attemptedAt:$attempted,
    finishedAt:(if $finished == "" then null else $finished end),
    nextPhase:$nextPhase,ciRemediationAttempts:$ciAttempts,
    ciRemediationLimit:$ciLimit,targets:$targets}')"

remediations="[]"
if [[ "$next_phase" == "execute" ]]; then
  remediations="$(jq -cn --argjson targets "$targets" --argjson feature "$(cat "$feature_json")" '
    def test_command($name):
      if $feature.workspace == null then ($feature.commands.test // "")
      else ([ $feature.workspace.repos[] | select(.name == $name) | (.commands.test // "") ][0] // "")
      end;
    [ $targets[]
      | select(.ok == false and .errorCode == "checks_failed")
      | . as $target
      | ($target.name | gsub("[^A-Za-z0-9]+"; "-") | gsub("^-|-$"; "")) as $id_name
      | (test_command($target.name)) as $test_command
      | {
          id: ("task-delivery-ci-" + $id_name),
          subject: ("Fix: required PR checks failed (" + $target.name + ")"),
          files: [],
          verifyCommand: (if $test_command != "" then $test_command else "git diff --check" end),
          acceptanceCriteria: ["all required PR checks pass for the delivered SHA"],
          repo: (if $feature.workspace == null then null else $target.name end),
          blockedBy: [],
          retries: 0,
          notes: ([ $target.checks.required[]?
                    | ((.name // "check") +
                       (if (.link // "") == "" then "" else " " + .link end)) ]
                  | join("; "))
        }
    ]')"
fi

# Surface a clickable PR. Single-repo has one; a workspace has one per changed repo,
# so report the first delivered repo's PR as the representative (the full set lives in
# targets[].prUrl), falling back to any target that carries a URL.
if [[ -z "$workspace_root" ]]; then
  pr_url_json="$(jq -c '.[0].prUrl // null' <<<"$targets")"
else
  pr_url_json="$(jq -c '
    ([.[] | select(.outcome == "delivered") | .prUrl | select(. != null)] | first)
    // ([.[] | .prUrl | select(. != null)] | first)
    // null' <<<"$targets")"
fi
aggregate="$(jq -cn --argjson ok "$ok" --arg status "$status" --arg nextPhase "$next_phase" \
  --argjson prUrl "$pr_url_json" --arg attempted "$attempted_at" --arg finished "$finished_at" \
  --argjson targets "$targets" --argjson ciAttempts "$ci_remediation_attempts" \
  --argjson ciLimit "$ci_remediation_limit" \
  '{schema:1,ok:$ok,status:$status,nextPhase:$nextPhase,prUrl:$prUrl,attemptedAt:$attempted,
    finishedAt:(if $finished == "" then null else $finished end),
    ciRemediationAttempts:$ciAttempts,ciRemediationLimit:$ciLimit,targets:$targets}')"

# The sidecar is the local observation record. It must not change the candidate commit.
printf '%s\n' "$aggregate" > "$delivery_file.tmp" || exit 2
sync
mv "$delivery_file.tmp" "$delivery_file" || exit 2

if [[ "$next_phase" == "execute" ]]; then
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  updated="$(jq --argjson delivery "$delivery" --argjson prUrl "$pr_url_json" \
    --argjson remediations "$remediations" --arg now "$now" '
        .delivery = $delivery
        | .prUrl = $prUrl
        | .updatedAt = $now
        | .currentPhaseStartedAt = null
        | .currentPhase = "execute"
        | (.pendingRemediationTasks // []) as $pending
        | .pendingRemediationTasks = reduce $remediations[] as $task
            ($pending; if (map(.id) | index($task.id)) == null then . + [$task] else . end)
  ' "$feature_json")" || {
    echo "deliver: failed to build updated feature state" >&2
    exit 2
  }
  bash "$SCRIPT_DIR/feature-write.sh" "$feature_dir" "$updated" || exit 2
fi

printf '%s\n' "$aggregate"

[[ "$ok" == "true" ]] && exit 0
exit 1
