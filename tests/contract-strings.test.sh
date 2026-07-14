#!/usr/bin/env bash
# Contract-strings coverage: the deterministic scripts and the skill prose share
# string constants (warning prefixes, JSON keys, refusal reasons). A rename on one
# side silently breaks the other — e.g. autonomous-chain.sh greps for the
# `iterate-budget-spent:` prefix that iterate's prose writes; rename the prefix in
# the skill and the chain predicate never fires again, with no error anywhere.
# This test pins both sides of every such coupling (same pattern as
# ponytail-coverage.test.sh).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0
FAIL=0

# file<TAB>fixed-string that must be present.
checks=(
  # -- iterate-budget-spent: prefix: written by iterate prose, matched by the chain predicate
  "skills/iterate/SKILL.md	iterate-budget-spent:"
  "lib/autonomous-chain.sh	iterate-budget-spent:"
  # -- iterate-terminal: prefix: written by iterate prose, described by the shared contract
  "skills/iterate/SKILL.md	iterate-terminal:"
  "skills/shared/autonomous-mode.md	iterate-terminal:"
  # -- chain predicate: skill must consume the script and its stable reasons
  "skills/cycle/SKILL.md	autonomous-chain.sh\" should-chain"
  "skills/cycle/SKILL.md	max-features-reached"
  "skills/cycle/SKILL.md	next-entry-terminal"
  "lib/autonomous-chain.sh	max-features-reached"
  "lib/autonomous-chain.sh	next-entry-terminal"
  # -- delivery must finish before unattended chaining continues
  "skills/cycle/SKILL.md	delivery-incomplete"
  "lib/autonomous-chain.sh	delivery-incomplete"
  # -- backlogEntryId: written by cycle drain, matched by iterate terminal rule
  "skills/cycle/SKILL.md	backlogEntryId"
  "skills/iterate/SKILL.md	backlogEntryId"
  # -- gap ids: iterate stamps them via backlog.sh gap-id / add --id
  "skills/iterate/SKILL.md	gap-id"
  "skills/iterate/SKILL.md	--id"
  # -- TERMINAL marker: backlog.sh writes/reads it; chain + iterate rely on it
  "lib/backlog.sh	-- TERMINAL: "
  # -- preflight blob keys consumed by cycle prose
  "skills/cycle/SKILL.md	cycle-preflight.sh\" run"
  "skills/cycle/SKILL.md	.workspace.mode"
  "skills/cycle/SKILL.md	.teams.mode"
  "skills/cycle/SKILL.md	.graphify.ok"
  "skills/cycle/SKILL.md	.workflows.available"
  "lib/cycle-preflight.sh	needs_probe"
  "skills/cycle/SKILL.md	needs_probe"
  # -- invocation parser consumed by cycle + intake; debug goes through debug-init
  "skills/cycle/SKILL.md	parse-invocation.sh\" parse"
  "skills/intake/SKILL.md	parse-invocation.sh\" parse"
  "lib/debug-init.sh	parse-invocation.sh"
  # -- decisions store: shared contract + spec/discuss/plan/cycle all call it
  "skills/shared/autonomous-mode.md	decisions.sh\" add"
  "skills/spec/SKILL.md	decisions.sh\" add"
  "skills/discuss/SKILL.md	decisions.sh\" add"
  "skills/plan/SKILL.md	decisions.sh\" add"
  "skills/cycle/SKILL.md	decisions.sh\" migrate"
  # -- debug: init consumed by the skill
  "skills/debug/SKILL.md	debug-init.sh\" init"
  # -- greenfield: bootstrap in cycle, backfill invariant in execute
  "skills/cycle/SKILL.md	greenfield-bootstrap.sh\" bootstrap"
  "skills/execute/SKILL.md	greenfield-bootstrap.sh\" backfill-check"
  # -- grounding: evidence ledger + lint gate + challenger marker couplings
  "skills/discuss/SKILL.md	grounding-lint.sh\""
  "skills/plan/SKILL.md	grounding-lint.sh\""
  "skills/spec/SKILL.md	evidence.sh\" add"
  "skills/discuss/SKILL.md	evidence.sh\" add"
  "skills/plan/SKILL.md	evidence.sh\" add"
  "agents/challenger.md	UNGROUNDED:"
  "skills/shared/team-prompts/challenger.md	UNGROUNDED:"
  "skills/discuss/SKILL.md	UNGROUNDED:"
  "skills/plan/SKILL.md	UNGROUNDED:"
  "lib/evidence.sh	EVID-"
  "lib/grounding-lint.sh	EVID-"
  "skills/shared/grounding-protocol.md	## Grounding"
  "lib/grounding-lint.sh	## Grounding"
)

for entry in "${checks[@]}"; do
  f="${entry%%	*}"
  s="${entry#*	}"
  if [[ ! -f "$f" ]]; then
    echo "FAIL: $f missing"; FAIL=$((FAIL+1)); continue
  fi
  if grep -qF -- "$s" "$f"; then
    echo "PASS: $f carries '$s'"; PASS=$((PASS+1))
  else
    echo "FAIL: $f does NOT carry '$s' — one side of a string contract was renamed"
    FAIL=$((FAIL+1))
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
