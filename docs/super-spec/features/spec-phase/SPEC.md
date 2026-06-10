# Spec Phase (Quantitative Ambiguity Gate)

**Slug:** `spec-phase`
**Created:** 2026-05-28
**Tier:** quick
**Execution style:** auto

<decisions>
- Decision: New phase named "spec" inserted BEFORE "discuss" in phase order. Rationale: clean separation of "lock down requirements ambiguity" (spec) vs "design the system" (discuss). Alternatives considered: merge spec-interviewer into the existing spec-writer agent (rejected per user scope decision; would bloat the spec-writer role and conflate two distinct responsibilities).
- Decision: feature.json schemaVersion bumps 3 -> 4. Rationale: currentPhase enum gains "spec"; completedPhases ordering gains spec as first entry; retryBudget.perPhase and perPhaseUsed each gain a "spec" field; new artifacts.specInterview field. Alternatives considered: reuse schemaVersion 3 with optional fields (rejected; optional-but-required fields create ambiguous parsing and break existing resume detection).
- Decision: Migration from schemaVersion 3 to 4 is opt-in on resume. Rationale: in-flight features on v3 must not be broken. cycle/SKILL.md detects schemaVersion: 3, prompts user via AskUserQuestion to migrate or finish on v3. Alternatives considered: auto-migrate silently (rejected; could corrupt an in-flight feature mid-execution).
- Decision: Ambiguity scoring formula: `1.0 - (0.35 * goal_clarity + 0.25 * boundary_clarity + 0.20 * constraint_clarity + 0.20 * acceptance_clarity)`. Rationale: weighted to prioritize goal + boundary clarity as highest-leverage dimensions. Each dimension scored 0.0-1.0 by spec-interviewer agent from interview responses. Alternatives considered: equal weights across all 4 dimensions (rejected; goal ambiguity is the most expensive form of ambiguity to discover late).
- Decision: Gate threshold: ambiguity <= 0.20 AND every dimension >= its minimum (goal >= 0.6, boundary >= 0.5, constraint >= 0.4, acceptance >= 0.5). Rationale: prevents single-dimension averaging exploits where one very high score masks a critically unclear dimension. Alternatives considered: overall ambiguity score only without per-dimension floors (rejected for exploit risk).
- Decision: Max 6 interview rounds, then escalate. Rationale: bounded retries discipline; 6 rounds with 2-3 questions each (12-18 total questions) is sufficient to resolve ambiguity on any feature. Alternatives considered: unlimited rounds (rejected; unbounded interview loops are operationally expensive and indicate a feature not ready to spec).
- Decision: 5 rotating interviewer perspectives applied across rounds: Researcher (round 1), Simplifier (round 2), Boundary Keeper (round 3), Failure Analyst (round 4), Seed Closer (rounds 5+). Rationale: forces multiple angles of inquiry to avoid blind spots a single perspective would miss. Alternatives considered: single fixed perspective (rejected; single-perspective interviews systematically miss boundary and failure-mode ambiguity).
- Decision: SPEC.md frontmatter gains an `ambiguity_scores` block written at end of spec phase. Rationale: traceability and critique gate uses these scores as ground truth to validate the spec was produced from a cleared gate. Alternatives considered: store scores only in feature.json (rejected; SPEC.md is the authoritative output artifact and should be self-contained).
- Decision: One new agent file: `agents/super-spec-spec-interviewer.md`. Rationale: keep agent count bounded; the spec-interviewer subsumes spec-writer responsibility after the gate passes (it writes SPEC.md directly). The existing spec-writer agent is retained as a fallback; the cycle no longer dispatches it directly. Alternatives considered: two agents (interviewer + separate writer) (rejected; the interviewer has full context from the interview and is best positioned to write the spec directly).
</decisions>

## Problem

super-spec's DISCUSS phase produces SPEC.md but has no quantitative gate on specification ambiguity before design begins. Vague specs reach EXECUTE and cause re-work that the downstream critique gates cannot fully prevent. There is no phase that forces a user to ground the feature in specific outcomes, explicit boundaries, and falsifiable acceptance criteria before the design conversation starts.

## Goals

- Add a "spec" phase that runs before "discuss" and interviews the user from 5 rotating perspectives across up to 6 rounds
- Compute a weighted ambiguity score across 4 dimensions after each round and gate progression on score <= 0.20 with per-dimension minimums
- Write SPEC.md (with `ambiguity_scores` frontmatter) only after the gate passes or the user explicitly overrides at round 6
- Bump feature.json to schemaVersion 4 with a migration path for in-flight v3 features
- Ensure the new phase integrates cleanly into the existing cycle skill without breaking v3 in-flight features

## Non-goals

- Multi-LLM scoring (all scoring is done by the single Claude model running the spec-interviewer agent)
- External NLP dependency for scoring (Claude's own assessment is the scoring mechanism)
- Backwards compatibility with schemaVersion 2 or earlier (already deprecated; clean break was made at v3)
- Modifying the DISCUSS phase's fundamental behavior (DISCUSS still produces SPEC.md as a fallback when spec phase output is absent)
- Forcing v3 in-flight features to migrate (migration is opt-in on resume)

## Boundaries (what NOT to do)

- Do NOT remove or modify the existing `agents/super-spec-spec-writer.md` agent; it must remain as a fallback
- Do NOT change the DISCUSS phase's core logic for features that lack spec-phase output
- Do NOT add em-dash anywhere in any deliverable (docs, agents, skills, scripts, or tests)
- Do NOT force v3 features to migrate; offer the choice and respect "finish on v3"
- Do NOT add multi-LLM or any external scoring dependency
- Do NOT create a `specifying-gates` or `checking-gates` dependency for the spec-phase interview loop; the spec-interviewer drives scoring internally
- Do NOT make the spec-interviewer agent write to any path outside `docs/super-spec/features/{slug}/` and `.super-spec/features/{slug}/`

## Constraints

- Runtime stack: bash >= 4, git, jq >= 1.5, python3 >= 3.6 only (no npm, pip, brew)
- All commits must follow the pattern: `<type>: NO_JIRA <message>`
- Source reference for interview model: `/Users/cbobrowitz/Projects/_reference/gsd-redux/get-shit-done/workflows/spec-phase.md`
- The 9 decisions in the `<decisions>` block are locked; PLAN must not re-open them
- No em-dash anywhere

## User-facing behavior

When a user invokes `super-spec:cycle` for a new feature:

1. The cycle initializes with `schemaVersion: 4` and `currentPhase: "spec"` instead of the previous `currentPhase: "discuss"`.
2. The cycle routes to the new `super-spec:spec` skill.
3. The spec skill spawns a team with `super-spec-spec-interviewer` as lead plus advocate and challenger.
4. The spec-interviewer conducts a Socratic interview across up to 6 rounds. Each round applies a different perspective (Researcher, Simplifier, Boundary Keeper, Failure Analyst, Seed Closer) and asks 2-3 targeted questions.
5. After each round, the agent scores 4 dimensions (goal clarity, boundary clarity, constraint clarity, acceptance clarity) and displays the updated ambiguity score.
6. When ambiguity <= 0.20 and all dimension minimums are met, the agent asks the user to confirm and writes SPEC.md with an `ambiguity_scores` frontmatter block.
7. If round 6 is reached with the gate still failing, the agent presents scores + gaps and asks the user to override or continue talking.
8. After SPEC.md is written, the cycle advances to the "discuss" phase (which now reads the locked SPEC.md rather than producing one from scratch).

When a user resumes an in-flight v3 feature, the cycle detects `schemaVersion: 3` and presents two options: migrate to v4 (which adds the spec phase fields and sets currentPhase to spec if the feature has not yet entered discuss) or continue on v3 using the existing behavior.

## Success criteria

### Good Enough

- [ ] `skills/spec/SKILL.md` exists with the full procedure documented (all 5 perspectives, 6-round maximum, gate check, SPEC.md output with ambiguity_scores). Verify: `test -f /Users/cbobrowitz/Projects/super-spec/skills/spec/SKILL.md`
- [ ] `agents/super-spec-spec-interviewer.md` exists with all 5 perspectives documented and the scoring rubric. Verify: `test -f /Users/cbobrowitz/Projects/super-spec/agents/super-spec-spec-interviewer.md`
- [ ] `agents/super-spec-spec-interviewer.md` contains the verbatim formula string `1.0 - (0.35 * goal_clarity + 0.25 * boundary_clarity + 0.20 * constraint_clarity + 0.20 * acceptance_clarity)`. Verify: `grep -F "1.0 - (0.35 * goal_clarity + 0.25 * boundary_clarity + 0.20 * constraint_clarity + 0.20 * acceptance_clarity)" /Users/cbobrowitz/Projects/super-spec/agents/super-spec-spec-interviewer.md`
- [ ] `agents/super-spec-spec-interviewer.md` documents the gate threshold (<= 0.20) and all 4 per-dimension minimums. Verify: `grep -E "0\.20|0\.6|0\.5|0\.4" /Users/cbobrowitz/Projects/super-spec/agents/super-spec-spec-interviewer.md | wc -l` returns >= 4
- [ ] `skills/shared/feature-state-schema.md` documents schemaVersion 4 with currentPhase enum including "spec", retryBudget.perPhase.spec, retryBudget.perPhaseUsed.spec, and artifacts.specInterview. Verify: `grep -E "schemaVersion.*4|spec.*perPhase|specInterview" /Users/cbobrowitz/Projects/super-spec/skills/shared/feature-state-schema.md | wc -l` returns >= 3
- [ ] `skills/cycle/SKILL.md` Step 5 initializes `schemaVersion: 4` and `currentPhase: "spec"` for new features. Verify: `grep -E "schemaVersion.*4|currentPhase.*spec" /Users/cbobrowitz/Projects/super-spec/skills/cycle/SKILL.md | wc -l` returns >= 2
- [ ] `skills/cycle/SKILL.md` Step 6 routes to "spec" as the first phase. Verify: `grep -E "spec.*first|route.*spec|Skill.*spec" /Users/cbobrowitz/Projects/super-spec/skills/cycle/SKILL.md`
- [ ] `skills/cycle/SKILL.md` resume logic detects `schemaVersion: 3` and prompts the user via AskUserQuestion to migrate or finish on v3. Verify: `grep -E "schemaVersion.*3.*migrate|AskUserQuestion.*migrate|migrate.*v3" /Users/cbobrowitz/Projects/super-spec/skills/cycle/SKILL.md`
- [ ] `lib/migrate-schema-v3-to-v4.sh` exists and is executable. Verify: `test -x /Users/cbobrowitz/Projects/super-spec/lib/migrate-schema-v3-to-v4.sh`
- [ ] `tests/lib/migrate-schema-v3-to-v4.test.sh` exists and exits 0. Verify: `bash /Users/cbobrowitz/Projects/super-spec/tests/lib/migrate-schema-v3-to-v4.test.sh; echo $?` outputs `0`
- [ ] README.md reflects the new phase order SPEC -> DISCUSS -> PLAN -> EXECUTE -> VERIFY. Verify: `grep -E "SPEC.*DISCUSS.*PLAN|spec.*discuss.*plan" /Users/cbobrowitz/Projects/super-spec/README.md`
- [ ] `bash tests/run-all.sh` exits 0 with all suites passing. Verify: run from repo root, check exit code.
- [ ] `bash tests/validate-agents.sh` exits 0 and prints `All 13 agents validated.`. Verify: run from repo root, compare output.
- [ ] CHANGELOG [Unreleased] entry documents the new phase and the v3->v4 migration. Verify: `grep -A5 "Unreleased" /Users/cbobrowitz/Projects/super-spec/CHANGELOG.md | grep -i "spec.*phase\|spec-phase\|schemaVersion"`
- [ ] No em-dash in any new or modified file. Verify: `grep -rn -- "—" /Users/cbobrowitz/Projects/super-spec/skills/spec/ /Users/cbobrowitz/Projects/super-spec/agents/super-spec-spec-interviewer.md /Users/cbobrowitz/Projects/super-spec/lib/migrate-schema-v3-to-v4.sh /Users/cbobrowitz/Projects/super-spec/tests/lib/migrate-schema-v3-to-v4.test.sh` returns no matches

### Exceptional

- [ ] `lib/migrate-schema-v3-to-v4.sh` is idempotent: running it twice on the same feature.json produces identical output. Verify: run the script once, capture output hash, run again, compare hashes.
- [ ] `tests/lib/migrate-schema-v3-to-v4.test.sh` covers at least 3 cases: (a) v3 feature with currentPhase: discuss (not yet started spec), (b) v3 feature with currentPhase: plan (already past discuss), (c) v3 feature.json with no perPhaseUsed field (older subschema within v3). Verify: count test case blocks in the test file.
- [ ] `skills/spec/SKILL.md` documents non-interactive mode behavior (how `SUPER_SPEC_NON_INTERACTIVE=1` + env vars replace AskUserQuestion calls in the spec-phase gate check and round confirmations). Verify: `grep -i "NON_INTERACTIVE\|non_interactive" /Users/cbobrowitz/Projects/super-spec/skills/spec/SKILL.md`
- [ ] `skills/discuss/SKILL.md` is updated so Step 2's team spawn prompt to spec-writer-1 references `ambiguity_scores` when a SPEC.md from the spec phase already exists. Verify: `grep -i "ambiguity_scores" /Users/cbobrowitz/Projects/super-spec/skills/discuss/SKILL.md`

## Out of scope

- Multi-LLM scoring panels (considered; rejected to keep agent count bounded and avoid inter-model coordination complexity)
- External NLP libraries or APIs for scoring (considered; rejected per the lean-deps philosophy: bash + jq + python3 + Claude only)
- Backwards compatibility with schemaVersion 2 or earlier (considered; rejected because v2 was a clean break when v1.0.0 shipped and no known in-flight features remain on v2)
- Merging the spec-interviewer role into the existing spec-writer agent (considered in decision #9; rejected to preserve single-responsibility and avoid bloating spec-writer)
- Automatic silent migration of v3 features (considered; rejected because silent migration mid-execution could corrupt a feature in the plan or execute phase)
- Per-round debate (advocate + challenger) inside the spec interview loop (considered; not needed because the scoring formula provides the objective gate; a debate would add latency without correctness benefit at this phase)
- Modifying the GSD-redux reference source (it is read-only reference material for this cycle)

## Open questions

(none - resolved during DISCUSS phase)
