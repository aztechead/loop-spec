# PLAN.md - spec-phase

**Feature:** Spec Phase (Quantitative Ambiguity Gate)
**Slug:** `spec-phase`
**Tier:** quick
**Planned:** 2026-05-28

---

## Assumptions

1. The SPEC.md `ambiguity_scores` frontmatter block is written dynamically by the spec-interviewer agent -- `skills/shared/artifact-templates/SPEC.md.template` is NOT modified (no template task needed). If this assumption is wrong the implementer of task-04 must add a task for the template update.
2. `skills/discuss/SKILL.md` Step 3's spec-writer spawn message references the SPEC.md path -- the "Exceptional" criterion for `ambiguity_scores` in discuss/SKILL.md requires only a one-line note in the spawn prompt block (Step 3) telling spec-writer-1 to read and preserve the `ambiguity_scores` frontmatter block when the spec phase already ran. This is a targeted Edit, not a full rewrite.
3. `preset-matrix.md` already defines a model for `spec-interviewer` role or the spec/SKILL.md references `spec-writer`'s model slot. The implementer of task-02 must pick the model alias from `preset-matrix.md` and document the assumption if the role is new.
4. The SPEC.md decisions block locks all ambiguity formula weights, gate thresholds, per-dimension minimums, and the 5 rotating perspectives. The spec skill and agent must use those exact values verbatim.
5. The `super-spec-spec-interviewer` agent is a non-restricted agent (has Write/Edit) and must NOT be added to `RESTRICTED_AGENTS` in `validate-agents.sh`. Its path restriction comes from the `hooks/restrict-agent-paths.sh` case block (task-03).

---

## Tasks

---

### task-01: skills/spec/SKILL.md -- new spec phase skill

**Subject:** Create `skills/spec/SKILL.md` with the full 6-round Socratic interview procedure, ambiguity scoring, gate check, SPEC.md output, and non-interactive mode documentation.

**files:**
- `skills/spec/SKILL.md`

**blockedBy:** []

**read_first:**
- `docs/super-spec/features/spec-phase/SPEC.md` (success criteria, decisions, user-facing behavior)
- `skills/discuss/SKILL.md` (skill structure template, AskUserQuestion patterns, TeamCreate/TeamDelete lifecycle, non-interactive mode section)
- `skills/cycle/SKILL.md` (non-interactive env var table, phase routing contract)
- `/Users/cbobrowitz/Projects/_reference/gsd-redux/get-shit-done/workflows/spec-phase.md` (interview perspectives, ambiguity model, gate behavior)
- `docs/super-spec/features/spec-phase/PATTERNS.md` (Concept: skill SKILL.md structure)

**Steps:**

1. Write a failing verify: `test -f /Users/cbobrowitz/Projects/super-spec/skills/spec/SKILL.md` -- confirm it fails (file absent).
2. Create `skills/spec/` directory.
3. Apply the skill structure pattern from `skills/discuss/SKILL.md:1-12` (frontmatter: `name: spec`, description, no tools list -- skills are markdown). Include:
   - Inputs from cycle/feature.json: `slug`, `tier`, `execStyle`, `feature_dir`
   - Step 1: TeamCreate `super-spec-spec-{slug}` with `spec-interviewer-1`, `advocate-1`, `challenger-1` (model from preset-matrix; see Assumption 3)
   - Write `currentTeamName` and `currentTeammates` via `lib/feature-write.sh`
   - Step 2: SendMessage to `spec-interviewer-1` with slug, tier, feature context, spec output path
   - Step 3: Interview loop -- spec-interviewer-1 runs internally (the lead waits for TeammateIdle or a "SPEC.md written" message); the skill does NOT micromanage individual interview rounds
   - Step 4: On "SPEC.md written": write `artifacts.specInterview` path to feature.json; write `artifacts.spec` path; append `"spec"` to `completedPhases`; set `currentPhase = "discuss"`
   - Step 5: Commit SPEC.md: `git add docs/super-spec/features/{slug}/SPEC.md && git commit -m "spec: NO_JIRA {slug}"`
   - Step 6: TeamDelete + clear `currentTeamName`/`currentTeammates`
   - Step 7: Phase routing (same execStyle pattern as discuss/SKILL.md Step 8: auto -> invoke discuss, step/interactive -> return to user)
4. Add **Non-interactive mode** section documenting `SUPER_SPEC_NON_INTERACTIVE=1` behavior: the spec-interviewer agent replaces AskUserQuestion calls (round confirmations, round-6 override prompt) with env var reads. Document env vars: `SUPER_SPEC_ANSWER_SPEC_CONFIRM=yes` (skip "gate passed, proceed?" prompt), `SUPER_SPEC_ANSWER_SPEC_OVERRIDE=yes` (auto-override at round 6 if gate fails).
5. Run verify: `test -f /Users/cbobrowitz/Projects/super-spec/skills/spec/SKILL.md` -- confirm exit 0.

**verifyCommand:** `test -f /Users/cbobrowitz/Projects/super-spec/skills/spec/SKILL.md`

**acceptanceCriteria:**
- `skills/spec/SKILL.md` exists
- Frontmatter has `name: spec` and a non-empty `description`
- Documents all 5 rotating interview perspectives (Researcher, Simplifier, Boundary Keeper, Failure Analyst, Seed Closer) and the 6-round cap
- Documents the gate threshold: ambiguity <= 0.20 AND all 4 per-dimension minimums
- Documents SPEC.md output with `ambiguity_scores` frontmatter block
- Includes a Non-interactive mode section referencing `SUPER_SPEC_NON_INTERACTIVE=1`
- No em-dash anywhere in the file (`grep -c -- "—" skills/spec/SKILL.md` returns 0)
- TeamCreate/TeamDelete lifecycle is owned by the spec skill (not cycle)

---

### task-02: agents/super-spec-spec-interviewer.md -- new agent definition

**Subject:** Create `agents/super-spec-spec-interviewer.md` with all 5 perspectives, scoring rubric (verbatim formula), gate thresholds, and write contract.

**files:**
- `agents/super-spec-spec-interviewer.md`
- `tests/validate-agents.sh`

**blockedBy:** []

**read_first:**
- `agents/super-spec-spec-writer.md` (agent frontmatter pattern, write contract, report format)
- `agents/super-spec-advocate.md` (minimal frontmatter reference)
- `docs/super-spec/features/spec-phase/SPEC.md` (verbatim formula, gate values, perspective names)
- `/Users/cbobrowitz/Projects/_reference/gsd-redux/get-shit-done/workflows/spec-phase.md` (interview procedure, dimension minimums)
- `tests/validate-agents.sh` (EXPECTED count, RESTRICTED_AGENTS list)
- `docs/super-spec/features/spec-phase/PATTERNS.md` (Concept: agent frontmatter schema)

**Steps:**

1. Write a failing verify: `test -f /Users/cbobrowitz/Projects/super-spec/agents/super-spec-spec-interviewer.md` -- confirm absent.
2. Apply the agent frontmatter pattern from `agents/super-spec-spec-writer.md:1-11`:
   ```markdown
   ---
   name: super-spec-spec-interviewer
   description: Conducts a Socratic interview loop across up to 6 rounds ...
   tools:
     - Read
     - Write
     - Edit
     - Grep
     - Glob
     - AskUserQuestion
   model: claude-opus-4-7
   ---
   ```
   (Use `claude-opus-4-7` to match the spec-authoring role; document this assumption.)
3. Write the agent body:
   - Input section: `slug`, `tier`, `feature_title`, codebase context paths
   - Role: conduct the Socratic interview, score dimensions after each round, check gate, write SPEC.md with `ambiguity_scores` block
   - Include the verbatim formula string: `1.0 - (0.35 * goal_clarity + 0.25 * boundary_clarity + 0.20 * constraint_clarity + 0.20 * acceptance_clarity)`
   - Gate threshold: ambiguity <= 0.20 AND goal_clarity >= 0.6, boundary_clarity >= 0.5, constraint_clarity >= 0.4, acceptance_clarity >= 0.5
   - All 5 perspectives with round assignments and example questions (from GSD reference)
   - Max 6 rounds; at round 6 with gate failing: display scores + gaps, AskUserQuestion override-or-continue
   - Write-path constraint: `docs/super-spec/features/{slug}/SPEC.md` and `.super-spec/features/{slug}/spec-interview-transcript.md`
   - Report format: Status: DONE | NEEDS_CONTEXT, spec path, final ambiguity score, dimension scores
4. Update `tests/validate-agents.sh` line 4: change `EXPECTED="${EXPECTED:-12}"` to `EXPECTED="${EXPECTED:-13}"`.
5. Confirm no em-dash in the new file: `grep -c -- "—" agents/super-spec-spec-interviewer.md` returns 0.
6. Run verify: `grep -F "1.0 - (0.35 * goal_clarity + 0.25 * boundary_clarity + 0.20 * constraint_clarity + 0.20 * acceptance_clarity)" agents/super-spec-spec-interviewer.md` exits 0.

**verifyCommand:** `grep -F "1.0 - (0.35 * goal_clarity + 0.25 * boundary_clarity + 0.20 * constraint_clarity + 0.20 * acceptance_clarity)" /Users/cbobrowitz/Projects/super-spec/agents/super-spec-spec-interviewer.md`

**acceptanceCriteria:**
- `agents/super-spec-spec-interviewer.md` exists with correct frontmatter (`name:` matches filename, `description` non-empty, `tools` list present, `model` in allowed set)
- Contains verbatim formula string `1.0 - (0.35 * goal_clarity + 0.25 * boundary_clarity + 0.20 * constraint_clarity + 0.20 * acceptance_clarity)`
- `grep -E "0\.20|0\.6|0\.5|0\.4" agents/super-spec-spec-interviewer.md | wc -l` returns >= 4 (gate threshold and per-dimension minimums present)
- All 5 perspectives (Researcher, Simplifier, Boundary Keeper, Failure Analyst, Seed Closer) documented with round assignments
- `tests/validate-agents.sh` EXPECTED bumped to 13
- `bash tests/validate-agents.sh` exits 0 and prints `All 13 agents validated.`
- No em-dash in the file

---

### task-03: hooks/restrict-agent-paths.sh -- add spec-interviewer to path restriction

**Subject:** Add `super-spec-spec-interviewer` to the write-restriction case block in `hooks/restrict-agent-paths.sh` so it is restricted to `docs/super-spec/features/**`.

**files:**
- `hooks/restrict-agent-paths.sh`

**blockedBy:** []

**read_first:**
- `hooks/restrict-agent-paths.sh:85-108` (case block -- the write-restriction pattern)
- `docs/super-spec/features/spec-phase/PATTERNS.md` (Concept: path-restriction hook registration)
- `docs/super-spec/codebase/CONCERNS.md:25` (permissive default risk note)

**Steps:**

1. Write a failing verify: grep for `super-spec-spec-interviewer` in `hooks/restrict-agent-paths.sh` -- confirm absent.
2. Apply the case-block pattern from `hooks/restrict-agent-paths.sh:86`:
   Edit the pipe-delimited list on line 86 from:
   ```bash
   super-spec-spec-writer|super-spec-planner|super-spec-pattern-mapper)
   ```
   to:
   ```bash
   super-spec-spec-writer|super-spec-planner|super-spec-pattern-mapper|super-spec-spec-interviewer)
   ```
3. Run verify: `grep -q "super-spec-spec-interviewer" /Users/cbobrowitz/Projects/super-spec/hooks/restrict-agent-paths.sh && echo ok`
4. Run the existing hook test to confirm no regression: `bash /Users/cbobrowitz/Projects/super-spec/hooks/restrict-agent-paths.test.sh`

**verifyCommand:** `grep -q "super-spec-spec-interviewer" /Users/cbobrowitz/Projects/super-spec/hooks/restrict-agent-paths.sh && bash /Users/cbobrowitz/Projects/super-spec/hooks/restrict-agent-paths.test.sh`

**acceptanceCriteria:**
- `super-spec-spec-interviewer` appears in the pipe-delimited case list at line 86 (or equivalent line after edit)
- `hooks/restrict-agent-paths.test.sh` exits 0 with no new failures
- The existing `super-spec-spec-writer|super-spec-planner|super-spec-pattern-mapper` restriction is preserved (not split into a separate case block)

---

### task-04: skills/shared/feature-state-schema.md -- document schemaVersion 4

**Subject:** Update `skills/shared/feature-state-schema.md` to document schemaVersion 4: new `currentPhase` enum value `"spec"`, `retryBudget.perPhase.spec`, `retryBudget.perPhaseUsed.spec`, and `artifacts.specInterview`.

**files:**
- `skills/shared/feature-state-schema.md`

**blockedBy:** []

**read_first:**
- `skills/shared/feature-state-schema.md` (full file -- schema doc to be updated)
- `docs/super-spec/features/spec-phase/SPEC.md` (decision: schemaVersion 4 fields list)
- `docs/super-spec/features/spec-phase/PATTERNS.md` (Concept: feature.json schemaVersion bump)

**Steps:**

1. Read the full `skills/shared/feature-state-schema.md` to understand the existing schema structure.
2. Edit the schema heading from `## Schema (v3)` to `## Schema (v4)`.
3. In the JSON block, change `"schemaVersion": 3` to `"schemaVersion": 4`.
4. In the `"currentPhase"` field comment, add `"spec"` before `"discuss"`: `"spec | discuss | plan | execute | verify | completed"`.
5. In the `retryBudget.perPhase` object, add `"spec": "integer (tier-dependent, mirrors discuss budget)"` alongside the existing discuss/plan/execute/verify entries.
6. In the `retryBudget.perPhaseUsed` object, add `"spec": 0` alongside the existing entries.
7. In the `artifacts` object, add `"specInterview": "path or null (.super-spec/features/{slug}/spec-interview-transcript.md)"` alongside `artifacts.spec`.
8. In the Field notes section, add a note: "Schema version 4 adds the `spec` phase fields. Migration from v3 to v4 is opt-in via `lib/migrate-schema-v3-to-v4.sh`. In-flight v3 features continue on v3 unless the user explicitly migrates."
9. Run verify: `grep -E "schemaVersion.*4|spec.*perPhase|specInterview" /Users/cbobrowitz/Projects/super-spec/skills/shared/feature-state-schema.md | wc -l` returns >= 3.

**verifyCommand:** `grep -E "schemaVersion.*4|spec.*perPhase|specInterview" /Users/cbobrowitz/Projects/super-spec/skills/shared/feature-state-schema.md | wc -l`

**acceptanceCriteria:**
- `## Schema (v4)` heading exists (replaces `## Schema (v3)`)
- `"schemaVersion": 4` in JSON block
- `currentPhase` enum includes `"spec"` before `"discuss"`
- `retryBudget.perPhase` and `retryBudget.perPhaseUsed` each document a `"spec"` field
- `artifacts.specInterview` documented as a nullable path field
- Field notes mention v3-to-v4 migration is opt-in via `lib/migrate-schema-v3-to-v4.sh`
- `grep -E "schemaVersion.*4|spec.*perPhase|specInterview" ... | wc -l` returns >= 3

---

### task-05: lib/migrate-schema-v3-to-v4.sh -- migration script (TDD)

**Subject:** Write `lib/migrate-schema-v3-to-v4.sh` that migrates a v3 feature.json to v4 by adding spec-phase fields. Idempotent. Uses `lib/feature-write.sh` for atomic write.

**files:**
- `lib/migrate-schema-v3-to-v4.sh`
- `tests/lib/migrate-schema-v3-to-v4.test.sh`

**blockedBy:** ["task-04"]

**read_first:**
- `lib/feature-write.sh` (full file -- atomic write pattern, jq mutation subcommands)
- `tests/lib/feature-write.test.sh` (test structure: check() helper, WORK tmpdir, trap EXIT)
- `skills/shared/feature-state-schema.md` (v4 schema -- new fields to add)
- `docs/super-spec/features/spec-phase/PATTERNS.md` (Concept: lib bash script with set -euo pipefail; Concept: test suite for a lib script)
- `docs/super-spec/features/spec-phase/SPEC.md` (Exceptional criteria: idempotency, 3 test cases)

**Steps:**

1. Write the test file FIRST (TDD). Create `tests/lib/migrate-schema-v3-to-v4.test.sh` with the `check()` + WORK tmpdir + trap pattern from `tests/lib/feature-write.test.sh`. Include at least 3 test cases:
   - Case A: v3 feature with `currentPhase: "discuss"` (not yet started spec) -- migration sets schemaVersion=4, adds `perPhase.spec`, `perPhaseUsed.spec`, `artifacts.specInterview`
   - Case B: v3 feature with `currentPhase: "plan"` (already past discuss) -- migration adds schema fields and sets `currentPhase` to its current value (not "spec"), does not rewind
   - Case C: v3 feature.json with no `retryBudget.perPhaseUsed` field (older subschema within v3) -- migration handles missing field gracefully (treats as empty object, adds spec key)
   - Case D (idempotency): run the script twice on the same feature.json, compute a hash of each output, assert hashes are equal
2. Run the test: `bash tests/lib/migrate-schema-v3-to-v4.test.sh` -- confirm ALL cases fail (script does not exist yet).
3. Create `lib/migrate-schema-v3-to-v4.sh` with `#!/usr/bin/env bash` and `set -euo pipefail`. Usage: `bash lib/migrate-schema-v3-to-v4.sh <feature_dir>`. The script:
   - Validates arg count (exit 1 if not exactly 1 arg)
   - Reads `feature_dir/feature.json`; validates it parses (exit 1 on failure)
   - Reads `schemaVersion`; if already 4, prints "already v4, no-op" and exits 0 (idempotency)
   - If schemaVersion != 3: prints "unsupported schemaVersion, aborting" and exits 1
   - Uses `jq` to produce a new JSON blob with all v4 additions (schemaVersion=4; perPhase.spec added; perPhaseUsed.spec added; artifacts.specInterview=null)
   - Delegates write to `lib/feature-write.sh "$feature_dir" "$new_json"` (atomic)
4. Mark executable: `chmod +x lib/migrate-schema-v3-to-v4.sh`
5. Run test: `bash tests/lib/migrate-schema-v3-to-v4.test.sh` -- confirm all cases PASS.
6. Run verify: `test -x /Users/cbobrowitz/Projects/super-spec/lib/migrate-schema-v3-to-v4.sh`

**verifyCommand:** `test -x /Users/cbobrowitz/Projects/super-spec/lib/migrate-schema-v3-to-v4.sh && bash /Users/cbobrowitz/Projects/super-spec/tests/lib/migrate-schema-v3-to-v4.test.sh`

**acceptanceCriteria:**
- `lib/migrate-schema-v3-to-v4.sh` exists and is executable (`test -x`)
- `tests/lib/migrate-schema-v3-to-v4.test.sh` exits 0
- Test file covers at least 3 cases: (a) v3+discuss, (b) v3+plan, (c) v3 with missing perPhaseUsed
- Idempotency: running the script twice on the same v3 feature.json produces identical JSON (`md5sum` or `sha256sum` of outputs are equal)
- The script exits 0 without modification when input is already schemaVersion 4
- The script calls `lib/feature-write.sh` for the actual write (not direct file writes)
- No em-dash in either file

---

### task-06: skills/cycle/SKILL.md -- Step 5 (schemaVersion 4) + Step 6 (spec routing) + resume (migration prompt)

**Subject:** Update `skills/cycle/SKILL.md` to initialize `schemaVersion: 4` and `currentPhase: "spec"` for new features, add spec as the first routed phase, and add schemaVersion 3 detection + AskUserQuestion migration prompt on resume.

**files:**
- `skills/cycle/SKILL.md`

**blockedBy:** ["task-04", "task-05"]

**read_first:**
- `skills/cycle/SKILL.md` (full file -- Step 1 resume detection, Step 5 state initialization jq block, Step 6 routing, description frontmatter)
- `skills/shared/feature-state-schema.md` (v4 schema -- new fields now documented)
- `docs/super-spec/features/spec-phase/PATTERNS.md` (Concept: cycle Step 5 initialization; Concept: cycle Step 6 routing; Concept: resume with schemaVersion detection)
- `lib/migrate-schema-v3-to-v4.sh` (migration script path -- referenced in the AskUserQuestion prompt)

**Steps:**

1. Read all of `skills/cycle/SKILL.md` end to end before making any edits.
2. **Step 5 jq block edits** (apply the initialization pattern from PATTERNS.md Concept: cycle Step 5):
   - Change `schemaVersion: 3` to `schemaVersion: 4`
   - Change `currentPhase: "discuss"` to `currentPhase: "spec"`
   - Add `spec: (if $tier == "quick" then 1 elif $tier == "balanced" then 2 else 3 end)` to `retryBudget.perPhase` (same pattern as `discuss`)
   - Add `spec: 0` to `retryBudget.perPhaseUsed`
   - Add `specInterview: null` to the `artifacts` object alongside `spec: null`
3. **Step 6 description update**: edit the prose that describes the first phase from "discuss" to "spec". The routing logic itself (`Skill(super-spec:{currentPhase})`) is already generic -- only the description text needs updating.
4. **Frontmatter + header description update**: update the `description:` frontmatter field from `"DISCUSS -> PLAN -> EXECUTE -> VERIFY"` to `"SPEC -> DISCUSS -> PLAN -> EXECUTE -> VERIFY"`.
5. **Step 1 resume detection -- schemaVersion 3 check**: after successfully parsing feature.json and before the orphan probe, add:
   ```
   - If `schemaVersion == 3`: prompt the user via AskUserQuestion:
       header: "In-flight v3 feature detected"
       question: "Feature {slug} is on schemaVersion 3. Migrate to v4 (adds spec-phase fields, does NOT rewind completed phases) or continue on v3?"
       options: ["Migrate to v4", "Continue on v3"]
     - "Migrate to v4": run `bash "${CLAUDE_PLUGIN_ROOT}/lib/migrate-schema-v3-to-v4.sh" ".super-spec/features/{slug}"`, reload feature.json
     - "Continue on v3": proceed without migration; cycle will use the existing v3 behavior (no spec phase)
     - When `SUPER_SPEC_NON_INTERACTIVE=1`: default to "Continue on v3" unless `SUPER_SPEC_ANSWER_MIGRATE_SCHEMA=1` is set
   ```
6. Run verify: `grep -E "schemaVersion.*4|currentPhase.*spec" /Users/cbobrowitz/Projects/super-spec/skills/cycle/SKILL.md | wc -l` returns >= 2.
7. Run verify: `grep -E "spec.*first|route.*spec|Skill.*spec" /Users/cbobrowitz/Projects/super-spec/skills/cycle/SKILL.md` exits 0.
8. Run verify: `grep -E "schemaVersion.*3.*migrate|AskUserQuestion.*migrate|migrate.*v3" /Users/cbobrowitz/Projects/super-spec/skills/cycle/SKILL.md` exits 0.

**verifyCommand:** `grep -E "schemaVersion.*4|currentPhase.*spec" /Users/cbobrowitz/Projects/super-spec/skills/cycle/SKILL.md | wc -l`

**acceptanceCriteria:**
- `grep -E "schemaVersion.*4|currentPhase.*spec" skills/cycle/SKILL.md | wc -l` returns >= 2
- `grep -E "spec.*first|route.*spec|Skill.*spec" skills/cycle/SKILL.md` exits 0 (spec is routed as first phase)
- `grep -E "schemaVersion.*3.*migrate|AskUserQuestion.*migrate|migrate.*v3" skills/cycle/SKILL.md` exits 0
- The description/frontmatter header reflects "SPEC -> DISCUSS -> PLAN -> EXECUTE -> VERIFY"
- Step 5 jq block initializes `schemaVersion: 4` and `currentPhase: "spec"`
- Step 5 jq block includes `spec` in both `retryBudget.perPhase` and `retryBudget.perPhaseUsed`
- `artifacts.specInterview: null` appears in the Step 5 initialization
- Non-interactive default for migration is "Continue on v3" unless `SUPER_SPEC_ANSWER_MIGRATE_SCHEMA=1`
- No em-dash added to the file

---

### task-07: skills/discuss/SKILL.md -- note ambiguity_scores in spec-writer spawn (Exceptional criterion)

**Subject:** Update `skills/discuss/SKILL.md` Step 3's spec-writer-1 spawn message to reference `ambiguity_scores` when a SPEC.md from the spec phase already exists.

**files:**
- `skills/discuss/SKILL.md`

**blockedBy:** ["task-01"]

**read_first:**
- `skills/discuss/SKILL.md:86-119` (Step 3 -- the spawn message block to be edited)
- `docs/super-spec/features/spec-phase/SPEC.md` (Exceptional criterion for ambiguity_scores in discuss)

**Steps:**

1. Read `skills/discuss/SKILL.md` Step 3 (the `SendMessage` to `spec-writer-1`) in full.
2. In the `body:` of the `SendMessage` call, add after "Produce SPEC.md at the output path per your role definition":
   ```
   If `docs/super-spec/features/{slug}/SPEC.md` already exists and contains an `ambiguity_scores` frontmatter block (produced by the spec phase), treat the spec phase output as locked requirements. Read the `ambiguity_scores` block for context. Do NOT overwrite or remove the `ambiguity_scores` block when revising SPEC.md.
   ```
3. Run verify: `grep -i "ambiguity_scores" /Users/cbobrowitz/Projects/super-spec/skills/discuss/SKILL.md` exits 0.

**verifyCommand:** `grep -i "ambiguity_scores" /Users/cbobrowitz/Projects/super-spec/skills/discuss/SKILL.md`

**acceptanceCriteria:**
- `grep -i "ambiguity_scores" skills/discuss/SKILL.md` exits 0
- The existing Step 3 SendMessage structure (body, to, format) is preserved; only the quoted prose inside body is extended
- No em-dash added to the file

---

### task-08: README.md + CHANGELOG.md -- documentation updates

**Subject:** Update README.md to reflect phase order SPEC -> DISCUSS -> PLAN -> EXECUTE -> VERIFY and add a CHANGELOG [Unreleased] entry for the new phase and v3->v4 migration.

**files:**
- `README.md`
- `CHANGELOG.md`

**blockedBy:** []

**read_first:**
- `README.md:85-95` (phase table and description block)
- `CHANGELOG.md:1-50` (Unreleased section structure and entry format)
- `docs/super-spec/features/spec-phase/SPEC.md` (success criteria for README and CHANGELOG)

**Steps:**

1. Read `README.md` and `CHANGELOG.md` fully before editing.
2. In `README.md`:
   - Update the phase table (lines ~90-95) to prepend a SPEC row: `| **SPEC** | \`docs/super-spec/features/{slug}/SPEC.md\` + \`ambiguity_scores\` frontmatter | 6-round Socratic interview, ambiguity gate |`
   - Update any prose that says "DISCUSS -> PLAN -> EXECUTE -> VERIFY" to "SPEC -> DISCUSS -> PLAN -> EXECUTE -> VERIFY"
   - Update the `### What the cycle does` section description accordingly
3. In `CHANGELOG.md`, add under `## [Unreleased]` a new `### Added` bullet (or add to existing Added section):
   ```markdown
   - **Spec phase** (`skills/spec/SKILL.md`): new SPEC -> DISCUSS -> PLAN -> EXECUTE -> VERIFY phase order. The spec phase runs a Socratic interview (up to 6 rounds, 5 rotating perspectives) with a quantitative ambiguity gate (ambiguity <= 0.20, per-dimension minimums). Produces SPEC.md with `ambiguity_scores` frontmatter. Agent: `agents/super-spec-spec-interviewer.md`.
   - **schemaVersion 4** (`skills/shared/feature-state-schema.md`): adds `spec` to `currentPhase` enum, `retryBudget.perPhase.spec`, `retryBudget.perPhaseUsed.spec`, `artifacts.specInterview`. Opt-in migration via `lib/migrate-schema-v3-to-v4.sh`. In-flight v3 features continue on v3 unless user chooses to migrate.
   ```
4. Run verify: `grep -E "SPEC.*DISCUSS.*PLAN|spec.*discuss.*plan" /Users/cbobrowitz/Projects/super-spec/README.md` exits 0.
5. Run verify: `grep -A5 "Unreleased" /Users/cbobrowitz/Projects/super-spec/CHANGELOG.md | grep -i "spec.*phase\|spec-phase\|schemaVersion"` exits 0.

**verifyCommand:** `grep -E "SPEC.*DISCUSS.*PLAN|spec.*discuss.*plan" /Users/cbobrowitz/Projects/super-spec/README.md`

**acceptanceCriteria:**
- README phase table includes a SPEC row
- README prose reflects "SPEC -> DISCUSS -> PLAN -> EXECUTE -> VERIFY" phase order
- CHANGELOG [Unreleased] entry documents the new spec phase and v3->v4 migration
- `grep -A5 "Unreleased" CHANGELOG.md | grep -i "spec.*phase\|spec-phase\|schemaVersion"` exits 0
- No em-dash in any new or modified text

---

### task-09: tests/run-all.sh + no-em-dash final verification

**Subject:** Add `lib/migrate-schema-v3-to-v4` to `tests/run-all.sh` and run all suites to confirm the full test harness exits 0 with 13 agents validated.

**files:**
- `tests/run-all.sh`

**blockedBy:** ["task-01", "task-02", "task-03", "task-04", "task-05", "task-06", "task-07", "task-08"]

**read_first:**
- `tests/run-all.sh` (full file -- existing run_suite calls pattern)
- `docs/super-spec/features/spec-phase/PATTERNS.md` (Concept: test suite for a lib script -- run-all registration pattern)

**Steps:**

1. Read `tests/run-all.sh` fully.
2. Add a `run_suite` call for the new migration test, after `run_suite "lib/detect-test-cmd"`:
   ```bash
   run_suite "lib/migrate-schema-v3-to-v4"  "bash tests/lib/migrate-schema-v3-to-v4.test.sh"
   ```
3. Run the full suite: `bash /Users/cbobrowitz/Projects/super-spec/tests/run-all.sh` -- confirm exit 0 and all suites pass.
4. Run validate-agents: `bash /Users/cbobrowitz/Projects/super-spec/tests/validate-agents.sh` -- confirm output is `All 13 agents validated.`
5. No-em-dash scan across all new and modified files:
   ```bash
   grep -rn -- "—" \
     /Users/cbobrowitz/Projects/super-spec/skills/spec/ \
     /Users/cbobrowitz/Projects/super-spec/agents/super-spec-spec-interviewer.md \
     /Users/cbobrowitz/Projects/super-spec/lib/migrate-schema-v3-to-v4.sh \
     /Users/cbobrowitz/Projects/super-spec/tests/lib/migrate-schema-v3-to-v4.test.sh
   ```
   Confirm no matches (0 lines output).

**verifyCommand:** `bash /Users/cbobrowitz/Projects/super-spec/tests/run-all.sh`

**acceptanceCriteria:**
- `tests/run-all.sh` includes a `run_suite "lib/migrate-schema-v3-to-v4"` entry
- `bash tests/run-all.sh` exits 0 with all suites passing (Suites failed: 0)
- `bash tests/validate-agents.sh` prints `All 13 agents validated.` and exits 0
- Em-dash scan returns no matches across all new files
- No existing suite is broken (all TOTAL_PASS count matches pre-task count + 1 for the new suite)

---

## Dependency graph

```
task-01 (skills/spec/SKILL.md)            independent
task-02 (agent + validate-agents count)   independent
task-03 (hook path restriction)           independent
task-04 (feature-state-schema.md)         independent
task-05 (migrate script + test)           blocked by task-04 (needs v4 schema to be defined first)
task-06 (cycle/SKILL.md updates)          blocked by task-04 (v4 schema), task-05 (migration script path)
task-07 (discuss/SKILL.md note)           blocked by task-01 (references spec phase output)
task-08 (README + CHANGELOG)              independent (documentation only)
task-09 (run-all.sh + final verify)       blocked by ALL (integration task)
```

Note: EXECUTE Step 2b will add synthetic `blockedBy` edges for any tasks whose `files[]` overlap. The planner has enumerated only logical dependencies above. File-overlap edges (e.g., if any two tasks touch the same file) are computed automatically.
