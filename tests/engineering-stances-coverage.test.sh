#!/usr/bin/env bash
# Pin the engineering-stances set: skills/shared/engineering-stances.md holds the five
# stances (build from scratch, system design, refactor, debug, performance) with their
# deliverables; every phase surface that adopts one names the file; the artifact
# templates carry the sections the deliverables land in. A stance that lives only in
# the contract is absent exactly where the work gets done.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fixed-string-coverage.sh"

checks=(
  "skills/shared/engineering-stances.md	Build from scratch"
  "skills/shared/engineering-stances.md	System design"
  "skills/shared/engineering-stances.md	Refactor"
  "skills/shared/engineering-stances.md	Debug"
  "skills/shared/engineering-stances.md	Performance"
  "skills/shared/engineering-stances.md	true MVP"
  "skills/shared/engineering-stances.md	caching strategy"
  "skills/shared/engineering-stances.md	Behavior is frozen"
  "skills/shared/engineering-stances.md	root cause"
  "skills/shared/engineering-stances.md	unnecessary rendering"
  "skills/shared/engineering-stances.md	never selects a route or a phase"
  "skills/shared/engineering-directives.md	engineering-stances.md"
  "skills/spec/SKILL.md	engineering-stances.md"
  "skills/spec/references/interview-prompts.md	Which input grows in production"
  "agents/spec-writer.md	engineering-stances.md"
  "skills/discuss/SKILL.md	engineering-stances.md"
  "skills/plan/SKILL.md	engineering-stances.md"
  "agents/planner.md	engineering-stances.md"
  "agents/planner.md	## System design"
  "agents/pattern-mapper.md	engineering-stances.md"
  "agents/pattern-mapper.md	## Problem areas"
  "agents/code-reviewer.md	engineering-stances.md"
  "agents/code-reviewer.md	Performance pass"
  "agents/code-reviewer.md	perf:"
  "agents/iterate-judge.md	engineering-stances.md"
  "skills/debug/SKILL.md	engineering-stances.md"
  "skills/debug/SKILL.md	edge cases"
  "skills/quality-loop/SKILL.md	engineering-stances.md"
  "skills/shared/artifact-templates/PLAN.md.template	## System design"
  "skills/shared/artifact-templates/PLAN.md.template	Caching strategy"
  "skills/shared/artifact-templates/VERIFICATION.md.template	#### Performance"
  "CLAUDE.md	engineering-stances.md"
  "tests/run-all.sh	tests/engineering-stances-coverage.test.sh"
)

check_fixed_strings "${checks[@]}"

# A stance is applied inside a phase; it must never appear as a route or phase selector.
for f in lib/task-route.sh lib/cycle-driver.sh lib/parse-invocation.sh; do
  if [[ ! -f "$f" ]]; then
    FAIL=$((FAIL+1)); echo "FAIL: $f is gone; re-point this pin at the route selector"
  elif grep -qF "engineering-stances" "$f"; then
    FAIL=$((FAIL+1)); echo "FAIL: $f names the stance contract from a route selector"
  else
    PASS=$((PASS+1)); echo "PASS: $f selects routes without the stance contract"
  fi
done

finish_fixed_string_coverage
