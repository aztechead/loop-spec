#!/usr/bin/env bash
# Structural contract for VERIFY -> ITERATE -> DELIVER and final worktree exit.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PASS=0
FAIL=0

present() {
  local name="$1" file="$2" needle="$3"
  if grep -qF -- "$needle" "$file"; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name ($file lacks '$needle')"; FAIL=$((FAIL + 1))
  fi
}

absent() {
  local name="$1" file="$2" needle="$3"
  if grep -qF -- "$needle" "$file"; then
    echo "FAIL: $name ($file still contains '$needle')"; FAIL=$((FAIL + 1))
  else
    echo "PASS: $name"; PASS=$((PASS + 1))
  fi
}

present "DELIVER skill exists" skills/deliver/SKILL.md "name: deliver"
present "DELIVER never AskUserQuestion as a wait" skills/deliver/SKILL.md "Never AskUserQuestion as a wait"
present "ITERATE never AskUserQuestion as a wait" skills/iterate/SKILL.md "Never AskUserQuestion as a wait"
present "DELIVER invokes deterministic controller" skills/deliver/SKILL.md "lib/deliver.sh"
present "controller delegates one-repo delivery" lib/deliver.sh "pr-delivery.sh"
present "bypass PRs are reconciled at publication" lib/delivery-reconcile.sh "Turn a GitHub PR created outside"
present "pr-delivery observe does not flip readiness" lib/pr-delivery.sh "Green draft"
present "cycle-result fail-open reconciles" lib/cycle-result.sh "delivery-reconcile.sh"
present "DELIVER skill names the reconciler" skills/deliver/SKILL.md "delivery-reconcile.sh"
present "ITERATE advances to DELIVER" skills/iterate/SKILL.md 'currentPhase = "deliver"'
present "cycle documents seven-phase chain" skills/cycle/SKILL.md "VERIFY -> ITERATE -> DELIVER"
present "short path still walks ITERATE and DELIVER" skills/cycle/references/completion.md "ITERATE and DELIVER still run"
present "completion still emits the terminal result" skills/cycle/references/completion.md "cycle-result.sh write"
present "empty ITERATE summary still publishes" skills/cycle/references/completion.md "Cycle completed; PR delivered."
present "named open PRs are adopted" skills/cycle/SKILL.md "adopt-pr.sh"
present "micro adopts a named open PR" skills/micro/SKILL.md "adopt-pr.sh"
present "cycle exits worktree only after delivery" skills/cycle/references/completion.md "final operation after DELIVER"
present "fresh rewind set is explicit" skills/cycle/references/phase-loop.md "execute|plan|spec|discuss"
present "blocked delivery cannot spin" skills/cycle/references/phase-loop.md "Never immediately invoke DELIVER again"
present "single-repo base is fetched" skills/cycle/references/feature-init.md 'fetch --quiet origin "$base_branch"'
present "workspace cleanliness checks output" skills/cycle/references/workspace-mode.md '[[ "$clean_state" != "clean" ]]'
present "workspace bases are fetched" skills/cycle/references/workspace-mode.md 'fetch --quiet origin "$base_branch_r"'
present "candidate finalization is deterministic" lib/deliver.sh 'finalize-delivery-candidate.sh'
present "candidate finalizer scopes digest" lib/finalize-delivery-candidate.sh 'docs/loop-spec/telemetry/runs/$slug.json'
present "terminal iteration evidence is committed" skills/iterate/SKILL.md 'iterate: NO_JIRA ${slug} terminal evidence'
present "terminal backlog commit is path scoped" skills/iterate/SKILL.md 'git diff --cached --quiet -- "$iteration_path" .loop-spec/BACKLOG.md'
present "VERIFY commit is path scoped" skills/verify/SKILL.md 'git commit -m "verify: NO_JIRA {slug}" -- docs/loop-spec/features/{slug}/VERIFICATION.md'
present "workspace VERIFY avoids parent commit" skills/verify/references/workspace-mode.md 'workspace root is not a delivery target'
absent "workspace VERIFY does not commit parent" skills/verify/references/workspace-mode.md 'git -C "$feature_workspace_root" commit'
present "single-repo delivery has candidate preflight" lib/deliver.sh "Candidate preflight"
present "hard retries bind to the recorded SHA" lib/deliver.sh "candidate_sha_drift"
present "hard delivery failure skips tracked commit" skills/cycle/references/phase-loop.md '[[ "$currentPhase" != "deliver" || "$next_phase" == "execute" ]]'
present "hard delivery retry skips finalization commits" lib/finalize-delivery-candidate.sh 'Exact-SHA retries and completion recovery are observation-only'
present "cycle commits its own ignore mutation" skills/cycle/references/phase-loop.md 'state_paths=("$fj" ".loop-spec/features/${slug}/PROGRESS.md" ".gitignore")'
present "cycle rejects pre-existing ignore dirt" skills/cycle/references/phase-loop.md 'refusing to mix pre-existing .gitignore changes'
present "fleet consumer rejects startup failures" skills/shared/execute-loop-fleet.md 'rc" -ne 0 && "$rc" -ne 1'
present "completion recovery bypasses project tests" skills/cycle/SKILL.md 'skip project tests'
present "workspace readiness is staged" lib/deliver.sh "stage readiness"
present "workspace promotion rollback is supported" lib/pr-delivery.sh "restore_draft"
present "workspace lifecycle avoids parent commits" skills/cycle/references/phase-loop.md '[[ "$workspaceMode" != "workspace" ]]'
present "controller supports held readiness" lib/pr-delivery.sh "hold_ready"
present "workspace surfaces a representative PR url" lib/deliver.sh 'select(.outcome == "delivered")'
absent "VERIFY does not create PRs" skills/verify/SKILL.md "gh pr create"
absent "VERIFY does not push branches" skills/verify/SKILL.md "git push -u origin"
absent "VERIFY does not exit worktree" skills/verify/SKILL.md "ExitWorktree"
absent "workspace VERIFY does not create PRs" skills/verify/references/workspace-mode.md "gh pr create"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
