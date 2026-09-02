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
present "ITERATE spec-rewind gate is a questions-wrapper call" skills/iterate/SKILL.md 'AskUserQuestion({'
present "ITERATE spec-rewind header is Re-open SPEC" skills/iterate/SKILL.md 'header: "Re-open SPEC"'
present "DELIVER invokes deterministic controller" skills/deliver/SKILL.md "lib/deliver.sh"
present "controller delegates one-repo delivery" lib/deliver.sh "pr-delivery.sh"
present "bypass PRs are reconciled at publication" lib/delivery-reconcile.sh "Turn a GitHub PR created outside"
present "pr-delivery observe does not flip readiness" lib/pr-delivery.sh "Green draft"
present "cycle-result fail-open reconciles" lib/cycle-result.sh "delivery-reconcile.sh"
present "DELIVER skill names the reconciler" skills/deliver/SKILL.md "delivery-reconcile.sh"
present "ITERATE closes the phase on the terminal pass" skills/iterate/SKILL.md '--terminal'
present "cycle documents seven-phase chain" skills/cycle/SKILL.md "VERIFY -> ITERATE -> DELIVER"
present "short path still walks ITERATE and DELIVER" skills/cycle/SKILL.md "never skips ITERATE or DELIVER"
present "completion still emits the terminal result" lib/cycle-driver.sh "cycle-result write"
present "empty ITERATE summary still publishes" lib/cycle-driver.sh "Cycle completed; PR delivered."
present "named open PRs are adopted" lib/cycle-driver.sh "adopt-pr resolve"
present "micro adopts a named open PR" skills/micro/SKILL.md "adopt-pr.sh"
present "cycle exits worktree only after delivery" skills/cycle/SKILL.md "keep the worktree until"
present "fresh rewind set is explicit" lib/cycle-driver.sh "execute|plan|spec|discuss"
present "blocked delivery cannot spin" lib/cycle-driver.sh "the graph must not re-enter DELIVER"
present "single-repo base is fetched" lib/cycle-driver.sh 'fetch --quiet origin "$base_branch"'
present "workspace cleanliness checks output" lib/cycle-driver.sh '== "clean" ]] || dirty+='
present "workspace bases are fetched" lib/cycle-driver.sh 'fetch --quiet origin "$bb"'
present "candidate finalization is deterministic" lib/deliver.sh 'finalize-delivery-candidate.sh'
present "candidate finalizer scopes digest" lib/finalize-delivery-candidate.sh 'docs/loop-spec/telemetry/runs/$slug.json'
present "terminal iteration evidence is committed" lib/phase-exit.sh 'commit_paths "iterate: $slug'
present "terminal backlog commit is path scoped" lib/phase-exit.sh 'git diff --cached --quiet -- "${existing[@]}"'
present "VERIFY commit is path scoped" lib/phase-exit.sh 'git commit -q -m "$msg" -- "${existing[@]}"'
present "workspace VERIFY avoids parent commit" lib/phase-exit.sh 'workspace root is not a delivery target'
absent "workspace VERIFY does not commit parent" lib/phase-exit.sh 'git -C "$feature_workspace_root" commit'
present "single-repo delivery has candidate preflight" lib/deliver.sh "Candidate preflight"
present "hard retries bind to the recorded SHA" lib/deliver.sh "candidate_sha_drift"
present "hard delivery failure skips tracked commit" lib/cycle-driver.sh '"$phase" == "deliver" && "$next" != "execute"'
present "hard delivery retry skips finalization commits" lib/finalize-delivery-candidate.sh 'Exact-SHA retries and completion recovery are observation-only'
present "cycle commits its own ignore mutation" lib/cycle-driver.sh 'git add -- "$rel/feature.json" "$rel/PROGRESS.md" .gitignore'
present "cycle rejects pre-existing ignore dirt" lib/cycle-driver.sh 'refusing to mix pre-existing .gitignore changes'
present "fleet consumer rejects startup failures" skills/shared/execute-loop-fleet.md 'rc" -ne 0 && "$rc" -ne 1'
present "completion recovery bypasses project tests" skills/cycle/SKILL.md 'PR was already proven'
present "workspace readiness is staged" lib/deliver.sh "stage readiness"
present "workspace promotion rollback is supported" lib/pr-delivery.sh "restore_draft"
present "workspace lifecycle avoids parent commits" lib/cycle-driver.sh '"$ws_mode" != "workspace"'
present "controller supports held readiness" lib/pr-delivery.sh "hold_ready"
present "workspace surfaces a representative PR url" lib/deliver.sh 'select(.outcome == "delivered")'
absent "VERIFY does not create PRs" skills/verify/SKILL.md "gh pr create"
absent "VERIFY does not push branches" skills/verify/SKILL.md "git push -u origin"
absent "VERIFY does not exit worktree" skills/verify/SKILL.md "ExitWorktree"
absent "workspace VERIFY does not create PRs" lib/phase-exit.sh "gh pr create"

if grep -E '^allowed-tools:' skills/verify/SKILL.md | grep -q AskUserQuestion; then
  echo "FAIL: VERIFY allowed-tools omit AskUserQuestion"; FAIL=$((FAIL + 1))
else
  echo "PASS: VERIFY allowed-tools omit AskUserQuestion"; PASS=$((PASS + 1))
fi
if grep -E '^allowed-tools:' skills/deliver/SKILL.md | grep -q AskUserQuestion; then
  echo "FAIL: DELIVER allowed-tools omit AskUserQuestion"; FAIL=$((FAIL + 1))
else
  echo "PASS: DELIVER allowed-tools omit AskUserQuestion"; PASS=$((PASS + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
