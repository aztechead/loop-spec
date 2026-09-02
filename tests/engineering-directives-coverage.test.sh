#!/usr/bin/env bash
# Pin the engineering-directives set: every code-producing dispatch surface names
# skills/shared/engineering-directives.md and carries the compact directive's four
# rules (simple over clever, versions from a tool, scaling input first, one test one
# break); the phase skills open through lib/phase-entry.sh; nothing in the cycle
# forbids the harness's lookup tools.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fixed-string-coverage.sh"

checks=(
  "skills/shared/engineering-directives.md	Canonical compact directive"
  "skills/shared/engineering-directives.md	never from recall"
  "skills/shared/engineering-directives.md	One test, one break"
  "skills/shared/engineering-directives.md	phase-entry.sh"
  "skills/shared/execute-subagent.md	engineering-directives.md"
  "skills/shared/execute-subagent.md	never from recall"
  "skills/shared/team-prompts/implementer.md	engineering-directives.md"
  "skills/shared/team-prompts/implementer.md	versions from a tool never from recall"
  "agents/implementer.md	engineering-directives.md"
  "agents/implementer.md	never from recall"
  "agents/implementer.md	version: <name>@<v> source: <command>"
  "agents/implementer.md	- **Versions**: one \`version:"
  "agents/planner.md	engineering-directives.md"
  "agents/planner.md	Design for scale before code exists"
  "agents/planner.md	Versions come from a tool, never from recall"
  "agents/code-reviewer.md	engineering-directives.md"
  "agents/code-reviewer.md	recall:"
  "skills/shared/execute-rungs.md	engineering-directives.md"
  "skills/execute/SKILL.md	engineering-directives.md"
  "lib/plan-to-loop.sh	engineering-directives.md"
  "lib/plan-to-loop.sh	never from recall"
  "lib/workflows/execute-dag.js	engineering-directives.md"
  "lib/workflows/execute-dag.js	never from recall"
  "skills/shared/implementer-contract.md	engineering-directives.md"
  "hooks/team/human-code-inject.sh	engineering-directives.md"
  "hooks/team/human-code-inject.sh	never from recall"
  "skills/spec/SKILL.md	phase-entry.sh\" spec"
  "skills/discuss/SKILL.md	phase-entry.sh\" discuss"
  "skills/plan/SKILL.md	phase-entry.sh\" plan"
  "skills/execute/SKILL.md	phase-entry.sh\" execute"
  "skills/verify/SKILL.md	phase-entry.sh\" verify"
  "skills/iterate/SKILL.md	phase-entry.sh\" iterate"
  "skills/deliver/SKILL.md	phase-entry.sh\" deliver"
  "skills/cycle/SKILL.md	phase-entry.sh"
  "tests/run-all.sh	tests/lib/phase-entry.test.sh"
)

check_fixed_strings "${checks[@]}"

# The subagent stanza wraps "one test, one break" across a line; pin it unwrapped.
if tr '\n' ' ' < skills/shared/execute-subagent.md | grep -qF "one test, one break"; then
  PASS=$((PASS+1)); echo "PASS: execute-subagent.md carries one test, one break"
else
  FAIL=$((FAIL+1)); echo "FAIL: execute-subagent.md lost one test, one break"
fi

# The cycle no longer forbids lookup tools: the host program decides what exists.
for f in skills/cycle/SKILL.md agents/implementer.md; do
  if grep -qE 'WebFetch|WebSearch' "$f"; then
    FAIL=$((FAIL+1)); echo "FAIL: $f still names WebFetch/WebSearch as forbidden"
  else
    PASS=$((PASS+1)); echo "PASS: $f leaves lookup tools to the harness"
  fi
done

# A phase skill that still lists its inputs in prose has two ingress contracts.
for f in skills/{spec,discuss,plan,execute,verify,iterate}/SKILL.md; do
  if grep -qE 'Inputs (come )?from' "$f"; then
    FAIL=$((FAIL+1)); echo "FAIL: $f lists inputs in prose beside the entry packet"
  else
    PASS=$((PASS+1)); echo "PASS: $f has one ingress: the entry packet"
  fi
done

finish_fixed_string_coverage
