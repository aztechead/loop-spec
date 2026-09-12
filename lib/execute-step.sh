#!/usr/bin/env bash
# execute-step.sh - One EXECUTE task step per call: dispatch, package, verdict, integrate.
#
# Why: per task the subagent wave loop asked the lead for a worktree resolve, a worktree
# add, a base SHA, a brief, a report path, two events, a review package, a fix-loop
# action, an integration, a mark-done, and a closing event, each as its own Bash call
# (the 2026-09-06 live evals, finding 7). Every one is deterministic. These four
# subcommands are the steps a lead still has to sequence around its Agent calls; the
# rest happens inside them. lib/execute-prepare.sh must have run first: the rung, the
# roots, and the caps are read from dispatch/prepare.json, never re-measured.
#
# Usage:
#   execute-step.sh dispatch  --feature-dir DIR --task ID [--attempt N]
#       Creates the task worktree when the rung isolates by worktree, records the base
#       SHA, writes the brief and report paths, resolves the implementer model, emits the
#       dispatch and task_start events. Prints the dispatch packet (JSON).
#   execute-step.sh package   --feature-dir DIR --task ID --head SHA
#       Writes the review package from the recorded base to HEAD, emits the reviewer's
#       dispatch event. Prints {package, model}.
#   execute-step.sh verdict   --feature-dir DIR --task ID --verdict pass|rework|block --attempt N
#       Applies the reviewer's verdict: pass -> {action:"integrate"}; rework ->
#       lib/fix-loop.sh's action with the model to use; block or a spent breaker ->
#       {action:"blocked", reason} with the task_end event emitted.
#   execute-step.sh integrate --feature-dir DIR --task ID
#       Worktree mode: lib/integrate-task.sh with --cleanup. In-place mode: runs the task's
#       verify command through lib/output-digest.sh, commits exactly task.files, and checks
#       HEAD advanced. Either way a published task is marked done, task_end is emitted,
#       and task-001 of a greenfield feature runs the command backfill.
#       Prints {published, reason, detail, sha, blocked}.
#   execute-step.sh add-files --feature-dir DIR --task ID <file...>
#       Widens a task's write scope for a rework attempt: appends the files
#       (deduplicated, repo-relative, no absolute paths or `..`) to task.files in the
#       tasks.json sidecar, dispatch/tasks-collapsed.json, and dispatch/prepare.json, so
#       every copy of the task the wave loop reads agrees. Refuses a task
#       task-progress.sh already marked done (add-files is for an open rework, not a
#       closed one). Prints {task, files, updated: [paths]}.
#       Exit 0 done; 1 already integrated; 2 bad invocation or path.
#   execute-step.sh run       --feature-dir DIR --task ID --role implementer|reviewer
#       The session rung's launch, in the driver and never in the lead
#       (the port principles, rule 12). On rung=session it
#       writes the prompt, one line and the paths (the brief and the report for the
#       implementer; the package, the spec, and the report for the reviewer, after
#       `package`), runs extensions/sessions/session_run.py with the harness's profile
#       in the task worktree (the feature root for the reviewer), and prints the
#       runner's JSON line plus {role, prompt}. An env-fault or timeout is retried once
#       inside; a second one is the answer. On any other rung it prints
#       {action:"in-harness", rung} and the lead dispatches through the harness tool.
#       Exit 0 completed or in-harness; 1 the session failed (the reason is in the
#       JSON); 2 bad invocation, no profile, or no CLI.
#
# Per-task state lives in DIR/dispatch/<task>.json (base SHA, worktree, attempt, blocked).
#
# Workspace mode (prepare.json .workspace non-null): the task's `repo` names a
# workspace.repos[] entry, every git call and the verify command run in that repo, and
# task.files drop their `<repo>/` prefix before staging. A task with no repo, or a repo
# the feature does not list, is a bad invocation (exit 2), never a git call at the root.
#
# Exit: 0 the step answered; 1 the step's answer is a stop (blocked, escalation, not
# published) with the reason in the JSON; 2 bad invocation or missing prepare.json.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib() { bash "$SCRIPT_DIR/$1.sh" "${@:2}"; }
usage() { sed -n '2,48p' "$0" | grep -E '^#( |$)' | sed 's/^# \{0,1\}//' >&2 || true; exit 2; }

cmd="${1:-}"; shift || true
feature_dir="" task_id="" attempt=0 head_sha="" verdict="" role="implementer"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature-dir) feature_dir="${2:-}" ;; --task) task_id="${2:-}" ;; --attempt) attempt="${2:-0}" ;;
    --head) head_sha="${2:-}" ;; --verdict) verdict="${2:-}" ;; --role) role="${2:-}" ;;
    # add-files' trailing paths are not --flags; every other subcommand keeps the strict
    # flags-only grammar, so a stray positional argument there still fails usage.
    *) [[ "$cmd" == "add-files" ]] && break; usage ;;
  esac
  shift 2 || usage
done
files=("$@")
case "$cmd" in dispatch|package|verdict|integrate|run|add-files) ;; *) usage ;; esac
case "$role" in implementer|reviewer) ;; *) usage ;; esac
[[ -n "$feature_dir" && -f "$feature_dir/feature.json" && -n "$task_id" ]] || usage
feature_dir="$(cd "$feature_dir" && pwd -P)"
fj="$feature_dir/feature.json"
prep="$feature_dir/dispatch/prepare.json"
[[ -f "$prep" ]] || { echo "execute-step: $prep is missing; run lib/execute-prepare.sh first" >&2; exit 2; }
fget() { bash "$SCRIPT_DIR/feature-read.sh" "$feature_dir" -r --filter "$1"; }
pget() { jq -r "$1" "$prep"; }
slug="$(fget '.slug')"
root="$(pget '.featureRoot')"
sidecar="$(pget '.sidecar')"
# The dispatch list is the collapsed one (lib/task-batch.sh): a merged chain or batch
# carries the union of its members' files and verifies, which the sidecar row for the
# surviving id does not. The sidecar is the fallback for a task that is not listed.
task_json="$(jq -c --arg id "$task_id" '.tasks | map(select(.id == $id)) | first // empty' "$prep")"
[[ -n "$task_json" ]] || task_json="$(jq -c --arg id "$task_id" '(if type == "object" and has("tasks") then .tasks else . end) | map(select(.id == $id)) | first // empty' "$sidecar")"
[[ -n "$task_json" ]] || { echo "execute-step: no task $task_id in $sidecar" >&2; exit 2; }
# A live workspace run recorded taskBaseSha="" and ran verify outside every repo because
# the packet's root was the orchestration root: in workspace mode the root is the task's.
repo_name="" repo_rel=""
if [[ "$(pget '.workspace // "null"')" != "null" ]]; then
  repo_name="$(jq -r '.repo // ""' <<<"$task_json")"
  [[ -n "$repo_name" ]] || { echo "execute-step: workspace task $task_id names no repo (tasks[].repo)" >&2; exit 2; }
  repo_rel="$(jq -r --arg n "$repo_name" '[.workspace.repos[] | select(.name == $n) | .path] | first // ""' "$prep")"
  [[ -n "$repo_rel" ]] || { echo "execute-step: task $task_id names repo '$repo_name', which feature.workspace.repos does not list" >&2; exit 2; }
  root="$(pget '.workspace.root')/$repo_rel"
  [[ -d "$root/.git" || -f "$root/.git" ]] || { echo "execute-step: repo '$repo_name' at $root is not a git work tree" >&2; exit 2; }
fi
state="$feature_dir/dispatch/$task_id.json"
sget() { jq -r "$1" "$state" 2>/dev/null || true; }
sset() { local cur; cur="$(cat "$state" 2>/dev/null || echo '{}')"; jq -c --arg k "$1" --argjson v "$2" '.[$k] = $v' <<<"$cur" > "$state"; }
in_place=true
[[ "$(pget '.rung.worktreesEnabled // false')" == "true" && "$(pget '.rung.subagentIsolation // "none"')" == "lead-worktree" ]] && in_place=false
total="$(jq 'length' <<<"$(pget '.tasks')")"; index="$(jq --arg id "$task_id" 'map(.id) | index($id) // 0 | . + 1' <<<"$(pget '.tasks')")"
emit() { lib events emit "$feature_dir" "$1" --phase execute --data "$2" >/dev/null 2>&1 || true; }
task_end() { emit task_end "$(jq -cn --argjson i "$index" --argjson t "$total" --arg id "$task_id" --arg r "$1" '{index:$i,total:$t,id:$id,result:$r}')"; }

case "$cmd" in
  dispatch)
    # A dispatch is not a query: it creates a worktree and records a base SHA. A live
    # lead called it on a blocked task while diagnosing and had to tear the worktree down.
    unmet="$(jq -r --arg done "$(lib task-progress done "$sidecar" 2>/dev/null | tr '\n' ' ')" \
      '[.blockedBy // [] | .[] | . as $b | select((" " + $done + " ") | contains(" " + $b + " ") | not)] | join(",")' <<<"$task_json")"
    [[ -z "$unmet" ]] || { jq -cn --arg id "$task_id" --arg u "$unmet" '{taskId:$id, dispatchable:false, reason:"blocked", detail:("waiting on " + $u)}'; exit 1; }
    branch="task/$task_id-$slug"; worktree=""; base_sha=""
    if [[ "$in_place" == false ]]; then
      worktree="$(lib worktree-base resolve "$root" task "$slug/$task_id" | jq -r '.path')"
      if [[ ! -d "$worktree" ]]; then
        git -C "$root" worktree add "$worktree" -b "$branch" "feat/$slug" >/dev/null 2>&1 \
          || { echo "execute-step: cannot create worktree $worktree" >&2; jq -cn --arg id "$task_id" '{taskId:$id, dispatchable:false, reason:"worktree-add-failed"}'; exit 1; }
      fi
      base_sha="$(git -C "$worktree" rev-parse HEAD)"
    else
      dirty="$(git -C "$root" status --porcelain --untracked-files=all -- . ':(exclude).loop-spec' ':(exclude).claude/agent-memory' 2>/dev/null)"
      [[ -z "$dirty" ]] || { jq -cn --arg id "$task_id" --arg d "$dirty" '{taskId:$id, dispatchable:false, reason:"feature-root-dirty", detail:$d}'; exit 1; }
      base_sha="$(git -C "$root" rev-parse HEAD)"
    fi
    brief="$(lib dispatch-files brief --feature-dir "$feature_dir" --task-id "$task_id")" || { echo "execute-step: brief failed" >&2; exit 2; }
    report="$(lib dispatch-files report-path --feature-dir "$feature_dir" --task-id "$task_id")"
    # Cheapest model that fits: a concrete pin, else the tier, else the role default.
    model="$(jq -r '.metadata.model // empty' <<<"$task_json")"
    if [[ -z "$model" ]]; then
      tier="$(jq -r '.metadata.modelTier // empty' <<<"$task_json")"
      [[ -n "$tier" ]] && model="$(lib model-tier model "$tier" 2>/dev/null || true)"
    fi
    [[ -n "$model" && "$model" != "inherit" ]] || model="$(fget '.models.implementer // "inherit"')"
    sset taskBaseSha "\"$base_sha\""; sset worktree "\"$worktree\""; sset branch "\"$branch\""; sset attempt "$attempt"; sset inPlace "$in_place"; sset model "\"$model\""
    emit dispatch "$(jq -cn --arg m "$model" --arg r "$(pget '.rung.rung')" '{role:"implementer",model:$m,rung:$r}')"
    emit task_start "$(jq -cn --argjson i "$index" --argjson t "$total" --arg id "$task_id" --arg s "$(jq -r '.subject' <<<"$task_json")" '{index:$i,total:$t,id:$id,subject:$s}')"
    jq -cn --argjson task "$task_json" --arg root "$root" --arg wt "$worktree" --arg br "$branch" --arg base "$base_sha" \
      --arg brief "$brief" --arg report "$report" --arg model "$model" --argjson ip "$in_place" --argjson i "$index" --argjson t "$total" \
      --argjson attempt "$attempt" --argjson max "$(pget '.maxRetries')" --arg prepare "$(fget '.commands.prepare // ""')" \
      '{dispatchable:true, taskId:$task.id, subject:$task.subject, files:($task.files // []), verifyCommand:$task.verifyCommand,
        acceptanceCriteria:($task.acceptanceCriteria // []), readFirst:($task.readFirst // []), specPath:($task.specPath // null),
        featureRoot:$root, inPlace:$ip, worktreePath:(if $wt == "" then null else $wt end), branch:$br, taskBaseSha:$base,
        brief:$brief, report:$report, model:$model, prepareCommand:$prepare, index:$i, total:$t, attempt:$attempt, maxRetries:$max}'
    ;;
  package)
    [[ -n "$head_sha" ]] || usage
    base_sha="$(sget '.taskBaseSha')"; repo="$(sget '.worktree')"; [[ -n "$repo" && "$repo" != "null" ]] || repo="$root"
    [[ -n "$base_sha" && "$base_sha" != "null" ]] || { echo "execute-step: no recorded base SHA for $task_id; dispatch first" >&2; exit 2; }
    pkg="$(lib dispatch-files package --repo "$repo" --base "$base_sha" --head "$head_sha")" || { echo "execute-step: package failed" >&2; exit 2; }
    model="$(fget '.models.specComplianceReviewer // "inherit"')"
    emit dispatch "$(jq -cn --arg m "$model" --arg r "$(pget '.rung.rung')" '{role:"spec-compliance-reviewer",model:$m,rung:$r}')"
    sset package "\"$pkg\""; sset reviewerModel "\"$model\""
    jq -cn --arg p "$pkg" --arg m "$model" --arg base "$base_sha" --arg head "$head_sha" --arg brief "$(lib dispatch-files brief --feature-dir "$feature_dir" --task-id "$task_id" 2>/dev/null || true)" \
      --arg report "$(lib dispatch-files report-path --feature-dir "$feature_dir" --task-id "$task_id")" --arg wt "$repo" \
      --arg vc "$(jq -r '.verifyCommand // ""' <<<"$task_json")" \
      '{package:$p, model:$m, base:$base, head:$head, brief:$brief, report:$report, worktree:$wt, verifyCommand:$vc}'
    ;;
  run)
    rung="$(pget '.rung.rung')"
    if [[ "$rung" != "session" ]]; then
      jq -cn --arg r "$rung" '{action:"in-harness", rung:$r, reason:"this rung dispatches through the harness tool (skills/shared/execute-rungs.md)"}'
      exit 0
    fi
    report="$(lib dispatch-files report-path --feature-dir "$feature_dir" --task-id "$task_id")"
    # Artifacts are rooted at featureRoot (the workspace root in workspace mode), not the task's repo.
    spec="$(fget '.artifacts.spec // ""')"; [[ "$spec" == /* || -z "$spec" ]] || spec="$(pget '.featureRoot')/$spec"
    prompt="$feature_dir/dispatch/$task_id.$role.md"
    # A dispatch is a path and one line (the port principles, rule 5).
    if [[ "$role" == "implementer" ]]; then
      brief="$(lib dispatch-files brief --feature-dir "$feature_dir" --task-id "$task_id")" || { echo "execute-step: brief failed" >&2; exit 2; }
      cwd="$(sget '.worktree')"; [[ -n "$cwd" && "$cwd" != "null" ]] || cwd="$root"
      model="$(sget '.model')"; [[ -n "$model" && "$model" != "null" ]] || model="$(fget '.models.implementer // "inherit"')"
      printf 'Implement the task in %s. The spec is %s. Write your report to %s.\n' "$brief" "$spec" "$report" > "$prompt"
    else
      pkg="$(sget '.package')"
      [[ -n "$pkg" && "$pkg" != "null" ]] || { echo "execute-step: no review package for $task_id; run package first" >&2; exit 2; }
      cwd="$root"
      model="$(sget '.reviewerModel')"; [[ -n "$model" && "$model" != "null" ]] || model="$(fget '.models.specComplianceReviewer // "inherit"')"
      printf 'Review the package in %s against the spec %s. Write your verdict to %s.\n' "$pkg" "$spec" "$report" > "$prompt"
    fi
    mkdir -p "$feature_dir/dispatch/sessions"
    launch() {
      python3 "$SCRIPT_DIR/../extensions/sessions/session_run.py" --profile "$(lib harness cli)" --cwd "$cwd" \
        --prompt-file "$prompt" --model "$model" --seed-from "$root" --log-dir "$feature_dir/dispatch/sessions"
    }
    rc=0; line="$(launch)" || rc=$?
    # A provider or transport fault is not an attempt: once more, then it is the answer.
    if [[ "$rc" -eq 4 || "$rc" -eq 5 ]]; then rc=0; line="$(launch)" || rc=$?; fi
    [[ "$rc" -le 1 || "$rc" -ge 4 ]] || { echo "execute-step: the session runner refused the launch (exit $rc): $line" >&2; exit 2; }
    jq -c --arg role "$role" --arg prompt "$prompt" '. + {role:$role, prompt:$prompt}' <<<"${line:-{\}}"
    exit "$(( rc == 0 ? 0 : 1 ))"
    ;;
  verdict)
    case "$verdict" in pass|rework|block) ;; *) usage ;; esac
    max="$(pget '.maxRetries')"
    case "$verdict" in
      pass) jq -cn '{action:"integrate"}' ;;
      block) sset blocked '"spec-compliance-block"'; task_end failed; jq -cn '{action:"blocked", reason:"spec-compliance-block"}'; exit 1 ;;
      rework)
        action="$(lib fix-loop action "$attempt" "$max")"
        case "$action" in
          breaker) sset blocked '"retry-exhausted"'; task_end failed; jq -cn '{action:"blocked", reason:"retry-exhausted"}'; exit 1 ;;
          resume)
            live="$(lib fix-loop live "$(pget '.rung.rung')")"
            [[ "$live" == "resumeable" ]] || action=oneshot
            jq -cn --arg a "$action" --arg m "$(fget '.models.implementer // "inherit"')" --argjson n "$((attempt + 1))" '{action:$a, model:$m, nextAttempt:$n}' ;;
          fresh-upgrade)
            jq -cn --arg a "$action" --arg m "$(lib model-tier upgrade "$(fget '.models.implementer // "inherit"')" 2>/dev/null || echo inherit)" --argjson n "$((attempt + 1))" '{action:$a, model:$m, nextAttempt:$n}' ;;
          *) jq -cn --arg a "$action" --argjson n "$((attempt + 1))" '{action:$a, nextAttempt:$n}' ;;
        esac ;;
    esac
    ;;
  integrate)
    verify_cmd="$(jq -r '.verifyCommand' <<<"$task_json")"
    if [[ "$(sget '.inPlace')" != "true" ]]; then
      worktree="$(sget '.worktree')"; branch="$(sget '.branch')"
      res="$(lib integrate-task --feature-root "$root" --feature-branch "feat/$slug" --task-worktree "$worktree" \
        --task-branch "$branch" --verify "$verify_cmd" --cleanup)" || true
      published="$(jq -r '.published // false' <<<"$res")"
      sha="$(git -C "$root" rev-parse "feat/$slug" 2>/dev/null || true)"
      answer="$(jq -c --arg sha "$sha" '{published:(.published // false), reason:(.reason // null), detail:(.detail // null), sha:$sha, blocked:null}' <<<"$res")"
    else
      mkdir -p "$feature_dir/logs"
      # A batch collapsed across repos (lib/task-batch.sh keys on batchGroup, not repo) would
      # stage only the files under this repo and publish the rest as done. Refuse it first.
      foreign=""
      [[ -z "$repo_name" ]] || foreign="$(jq -r --arg n "$repo_name" --argjson fs "$(jq -c '.files // []' <<<"$task_json")" \
        '[.workspace.repos[] | select(.name != $n) | (.name + "/"), (.path + "/")] as $ps | [$fs[] | . as $f | select(any($ps[]; . as $p | $f | startswith($p)))] | join(", ")' "$prep")"
      vrc=0
      if [[ -n "$foreign" ]]; then
        answer="$(jq -cn --arg d "$foreign" '{published:false, reason:"files-outside-repo", detail:("task.files name another workspace repo: " + $d), sha:null, blocked:null}')"
      else
        lib output-digest run --log "$feature_dir/logs/verify-$task_id.log" --label "verify $task_id" -- bash -c "cd '$root' && $verify_cmd" >&2 || vrc=$?
      fi
      if [[ -n "$foreign" ]]; then :
      elif (( vrc != 0 )); then
        answer="$(jq -cn --argjson rc "$vrc" '{published:false, reason:"verify-failed", detail:("verify command exited " + ($rc | tostring)), sha:null, blocked:null}')"
      else
        before="$(git -C "$root" rev-parse HEAD)"
        files_json="$(jq -c '.files // []' <<<"$task_json")"
        # Workspace files are written `<repo>/<path>` (skills/plan/SKILL.md); git in the repo wants `<path>`.
        [[ -z "$repo_name" ]] || files_json="$(jq -c --arg n "$repo_name/" --arg p "$repo_rel/" 'map(if startswith($n) then ltrimstr($n) else ltrimstr($p) end)' <<<"$files_json")"
        while IFS= read -r f; do
          [[ -n "$f" ]] || continue
          git -C "$root" add -- "$f" 2>/dev/null || echo "execute-step: $task_id lists $f but nothing at that path could be staged in $root" >&2
        done < <(jq -r '.[]' <<<"$files_json")
        git -C "$root" commit -q -m "feat: NO_JIRA $(jq -r '.subject' <<<"$task_json")" >/dev/null 2>&1 || true
        after="$(git -C "$root" rev-parse HEAD)"
        outside="$(git -C "$root" status --porcelain --untracked-files=all -- . ':(exclude).loop-spec' ':(exclude)docs/loop-spec' ':(exclude).claude/agent-memory' 2>/dev/null)"
        # A workspace implementer commits itself (execute-subagent.md, workspace Step 4), so
        # there published means HEAD advanced from the recorded base. A single-repo in-place
        # implementer must not commit; there only this call's own commit counts, so a replayed
        # integrate is still commit-missing rather than a second success.
        base_sha="$before"
        [[ -z "$repo_name" ]] || { base_sha="$(sget '.taskBaseSha')"; [[ -n "$base_sha" && "$base_sha" != "null" ]] || base_sha="$before"; }
        if [[ "$base_sha" == "$after" ]]; then
          answer="$(jq -cn '{published:false, reason:"commit-missing", detail:"nothing to commit under task.files", sha:null, blocked:"commit-missing"}')"
        elif [[ -n "$outside" ]]; then
          answer="$(jq -cn --arg sha "$after" --arg d "$outside" '{published:true, reason:"dirty-outside-task-files", detail:$d, sha:$sha, blocked:null}')"
        else
          answer="$(jq -cn --arg sha "$after" '{published:true, reason:null, detail:null, sha:$sha, blocked:null}')"
        fi
      fi
    fi
    if [[ "$(jq -r '.published' <<<"$answer")" == "true" ]]; then
      for member in $(jq -r '(.memberIds // [.id])[]' <<<"$task_json"); do
        lib task-progress mark-done "$sidecar" "$member" >/dev/null
      done
      task_end merged
      if [[ "$task_id" == "task-001" && "$(fget '.greenfield // false')" == "true" ]]; then
        test_cmd="$(lib detect-test-cmd "$root" 2>/dev/null || true)"
        [[ -n "$test_cmd" ]] && lib feature-write set "$feature_dir" commands.test "\"$test_cmd\"" >/dev/null
        prep_cmd="$(lib prepare-environment resolve --root "$root" 2>/dev/null | jq -r '.command // ""' || true)"
        [[ -n "$prep_cmd" ]] && lib feature-write set "$feature_dir" commands.prepare "\"$prep_cmd\"" >/dev/null
        lib greenfield-bootstrap backfill-check "$feature_dir" >&2 || answer="$(jq -c '.detail = "greenfield backfill missing: commands.test is empty after the scaffold"' <<<"$answer")"
      fi
      printf '%s\n' "$answer"; exit 0
    fi
    reason="$(jq -r '.reason' <<<"$answer")"
    # A refusal keeps its own name: every unlisted reason used to read as
    # `rebase-conflict`, and a dirty feature worktree sent a lead hunting for a conflict.
    case "$reason" in
      verify-failed|prepare-failed) sset blocked '"retry-exhausted"' ;;
      zero-commit|commit-missing) sset blocked '"commit-missing"' ;;
      check-dirty-worktree|candidate-changed|feature-moved) sset blocked '"dirty-worktree"' ;;
      rebase-conflict) sset blocked '"rebase-conflict"' ;;
      *) sset blocked "$(jq -cn --arg r "$reason" '$r')" ;;
    esac
    task_end failed
    jq -c --arg b "$(sget '.blocked')" '.blocked = $b' <<<"$answer"; exit 1
    ;;
  add-files)
    [[ ${#files[@]} -gt 0 ]] || usage
    for f in "${files[@]}"; do
      [[ "$f" != /* ]] || { echo "execute-step: add-files path must be repo-relative, got absolute '$f'" >&2; exit 2; }
      case "$f" in *..*) echo "execute-step: add-files path escapes the repo: '$f'" >&2; exit 2 ;; esac
    done
    # A rework attempt widens scope on an OPEN task; the `integrate` case above marks a
    # task done via task-progress.sh once it publishes, so a widen past that point is a
    # stale rework request against a task that already shipped.
    if grep -qxF "$task_id" <<<"$(lib task-progress done "$sidecar")"; then
      echo "execute-step: $task_id is already integrated; add-files is for a rework attempt on an open task" >&2
      exit 1
    fi
    add_json="$(printf '%s\n' "${files[@]}" | jq -R . | jq -cs 'unique')"
    final_files="$(jq -cn --argjson e "$(jq -c '.files // []' <<<"$task_json")" --argjson a "$add_json" '($e + $a) | unique')"
    collapsed="$feature_dir/dispatch/tasks-collapsed.json"
    # The task lives in three copies (sidecar, the collapsed dispatch list, and the
    # frozen prepare.json); every reader downstream picks one, so all three widen
    # together. A batch merge erases every member id but the first (lib/task-batch.sh),
    # so bump matches on the surviving id's memberIds too.
    tmp="$sidecar.tmp"
    jq --arg id "$task_id" --argjson f "$final_files" '
      def bump: if .id == $id or (.memberIds // [] | index($id)) then .files = $f else . end;
      if type == "object" and has("tasks") then .tasks |= map(bump) else map(bump) end
    ' "$sidecar" > "$tmp" && mv "$tmp" "$sidecar"
    tmp="$collapsed.tmp"
    jq --arg id "$task_id" --argjson f "$final_files" '
      def bump: if .id == $id or (.memberIds // [] | index($id)) then .files = $f else . end;
      map(bump)
    ' "$collapsed" > "$tmp" && mv "$tmp" "$collapsed"
    tmp="$prep.tmp"
    jq --arg id "$task_id" --argjson f "$final_files" '
      def bump: if .id == $id or (.memberIds // [] | index($id)) then .files = $f else . end;
      .tasks |= map(bump)
    ' "$prep" > "$tmp" && mv "$tmp" "$prep"
    jq -cn --arg t "$task_id" --argjson f "$final_files" --arg s "$sidecar" --arg c "$collapsed" --arg p "$prep" \
      '{task:$t, files:$f, updated:[$s,$c,$p]}'
    ;;
esac
