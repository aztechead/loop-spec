#!/usr/bin/env bash
# Pin the SPEC/PLAN wall-clock contract: one bounded critique round, no separate
# code-lookup dispatch, no prose-pruning dispatch, and no advocate dispatch.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fixed-string-coverage.sh"

checks=(
  "skills/spec/SKILL.md	spec critique skipped"
  "skills/spec/SKILL.md	lib/graph/probes/spec-critique.sh"
  "skills/spec/SKILL.md	Never spawn \`advocate-1\`"
  "skills/plan/SKILL.md	Send the planner one combined list"
  'skills/plan/SKILL.md	The critique never re-opens on a `REDO`'
  "skills/plan/SKILL.md	Never spawn \`advocate-1\`"
  'skills/plan/SKILL.md	`artifact-lint plan` rejects a PLAN'
  "agents/challenger.md	Critique is challenger-only"
  "skills/shared/team-prompts/challenger.md	not dispatched"
  "skills/shared/team-prompts/advocate.md	not dispatched"
  "docs/loop-spec/architecture.md	Critique gate protocol (challenger-only)"
  "skills/plan/SKILL.md	Do not dispatch a prose-pruning reviewer"
  "skills/spec/SKILL.md	phase-exit.sh\" spec"
  "skills/shared/critique-gate-protocol.md	without an advocate or debate round"
  "skills/shared/critique-gate-protocol.md	Do NOT drop it — add it to the fix-list"
  "skills/shared/critique-gate-protocol.md	keep it on the fix-list (stricter bias)"
  "skills/shared/critique-gate-protocol.md	gate.sh next"
  "skills/shared/critique-gate-protocol.md	--convergence cap-reached"
  "skills/shared/critique-gate-protocol.md	never count rounds by hand"
  "skills/shared/team-prompts/critic.md	introduced:"
  "skills/shared/team-prompts/critic.md	unaddressed:"
  "skills/shared/tier-matrix.md	gate.sh next"
  "docs/loop-spec/configuration.md	LOOP_SPEC_CRITIQUE_ROUNDS"
  "skills/plan/SKILL.md	gate.sh next"
  'skills/spec/SKILL.md	answering `close` ends the gate with SPEC as it stands'
  "skills/shared/tier-matrix.md	There is no advocate and no debate"
  "graph/cycle.graph.json	lib/graph/probes/spec-critique.sh"
  "lib/graph/probes/spec-critique.sh	gate=skip"
)

check_fixed_strings "${checks[@]}"

must_not=(
  "skills/spec/SKILL.md	subagent_type: \"loop-spec:advocate\""
  "skills/plan/SKILL.md	subagent_type: \"loop-spec:advocate\""
  "skills/shared/critique-gate-protocol.md	Spawn \`advocate-1\`"
  "skills/shared/dispatch.md	advocate one-shot"
  "graph/critique.graph.json	critique.debate"
  "graph/critique.graph.json	loop-spec:advocate"
  "agents/challenger.md	Escalated debate"
  "skills/shared/team-prompts/challenger.md	Your debate partner"
  "skills/shared/team-prompts/challenger.md	SendMessage({to: \"advocate-"
  "docs/loop-spec/architecture.md	advocate on escalation"
  "docs/loop-spec/architecture.md	Lead spawns advocate-1"
)

for entry in "${must_not[@]}"; do
  file="${entry%%	*}"
  needle="${entry#*	}"
  if [[ -f "$file" ]] && grep -qF -e "$needle" "$file"; then
    FAIL=$((FAIL+1)); echo "FAIL: $file still contains '$needle'"
  else
    PASS=$((PASS+1)); echo "PASS: $file dropped '$needle'"
  fi
done

finish_fixed_string_coverage
