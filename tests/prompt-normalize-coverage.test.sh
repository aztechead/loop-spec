#!/usr/bin/env bash
# Every implementer-facing entry skill must front its input with the shared
# prompt-normalize pass, and the contract must keep the rules that make the
# pass safe: never invent, artifacts byte-for-byte, one pass per input.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fixed-string-coverage.sh"

checks=(
  "skills/shared/prompt-normalize.md	Normalize, never invent"
  "skills/shared/prompt-normalize.md	byte-for-byte"
  "skills/shared/prompt-normalize.md	stay gaps - the ambiguity gate"
  "skills/shared/prompt-normalize.md	non-interactive"
  "skills/shared/prompt-normalize.md	SPEC-shaped"
  "skills/shared/prompt-normalize.md	never loop-spec output"
  "skills/shared/prompt-normalize.md	the routed-to skill runs the pass"
  "skills/shared/prompt-normalize.md	A normalize that finds nothing changes nothing"
  "skills/cycle/SKILL.md	shared/prompt-normalize.md"
  "skills/intake/SKILL.md	shared/prompt-normalize.md"
  "skills/micro/SKILL.md	shared/prompt-normalize.md"
  "skills/debug/SKILL.md	shared/prompt-normalize.md"
)

check_fixed_strings "${checks[@]}"
finish_fixed_string_coverage
