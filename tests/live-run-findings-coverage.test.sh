#!/usr/bin/env bash
# Pins the contract lines the 2026-09-07 live headless cycle on tf-meldn showed were
# missing (evals/findings-2026-09-07-tf-meldn.md): subagents get absolute template
# paths, task sections are rendered from tasks.json, state changes name their command,
# the headless join is stated as fact, and the tool-boundary backstops are wired.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fixed-string-coverage.sh"

checks=(
  $'skills/discuss/SKILL.md\tartifact-templates/PATTERNS.md.template'
  $'skills/discuss/SKILL.md\tlib/feature-write.sh" set "$feature_dir" artifacts.patternsPrefetch'
  $'skills/plan/SKILL.md\tartifact-templates/PATTERNS.md.template'
  $'skills/plan/SKILL.md\tartifact-templates/PLAN.md.template'
  $'skills/plan/SKILL.md\tlib/plan-render.sh'
  $'agents/planner.md\ttemplate_path'
  $'agents/planner.md\tlib/plan-render.sh'
  $'agents/pattern-mapper.md\tnever search the disk'
  $'skills/shared/dispatch.md\tThis holds'
  $'skills/shared/dispatch.md\tunder `claude -p`'
  $'skills/shared/critique-gate-protocol.md\tunder `claude -p` as well'
  $'skills/shared/critique-gate-protocol.md\tACCEPTED as `[minor]`'
  $'skills/shared/critique-gate-protocol.md\tplan-render.sh render'
  $'hooks/team/result-forgery-guard.sh\tbash lib/feature-write.sh set <feature_dir> <dot.path>'
  $'hooks/hooks.json\thooks/team/busy-wait-guard.sh'
  $'hooks/hooks.json\thooks/team/artifact-lint-feedback.sh'
  $'hooks/hooks.json\thooks/team/dispatch-prompt-guard.sh'
  $'hooks/team/busy-wait-guard.sh\tLOOP_SPEC_BUSY_WAIT_GUARD'
  $'hooks/team/artifact-lint-feedback.sh\tbefore reporting DONE'
  $'lib/execute-step.sh\tdispatchable:false, reason:"blocked"'
  $'skills/cycle/SKILL.md\tRun it; do not `ls`'
  $'lib/acceptance-lint.sh\t=~ [^[:space:]]'
  $'lib/evidence.sh\trefusing an email address or credential path'
  $'lib/owned-gitignore.sh\tensure <repo> <line>...'
  $'evals/README.md\tauto-mode classifier'
  $'lib/execute-prepare.sh\tdispatch/environment.txt'
  $'lib/dispatch-files.sh\tdispatch/tasks-collapsed.json'
  $'lib/dispatch-files.sh\tDo not read SPEC.md, PLAN.md, PATTERNS.md, or EVIDENCE.md'
  $'lib/execute-step.sh\t(.memberIds // [.id])[]'
  $'lib/execute-step.sh\tverifyCommand:$vc'
  $'skills/shared/execute-subagent.md\tDo NOT run the task\'s verify command'
  $'skills/shared/execute-subagent.md\tDo not open SPEC.md, PLAN.md'
  $'agents/planner.md\tlib/task-batch.sh'
  $'lib/security-signal.sh\tdeclared absent'
  $'docs/loop-spec/configuration.md\tLOOP_SPEC_TASK_BATCH_AUTO'
)

check_fixed_strings "${checks[@]}"
finish_fixed_string_coverage
