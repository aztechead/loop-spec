# PATTERNS.md - spec-phase

> Produced by `loop-spec-pattern-mapper`. Read by `loop-spec-planner` before drafting tasks.
> One section per **concept** the upcoming feature will need. Concepts are system-design nouns/verbs, not file paths.

## Codebase context consulted

- `docs/loop-spec/codebase/TECH.md`
- `docs/loop-spec/codebase/ARCH.md`
- `docs/loop-spec/codebase/QUALITY.md`
- `docs/loop-spec/codebase/CONCERNS.md`
- `docs/loop-spec/codebase/DOMAIN.md`

---

## Concept: skill SKILL.md structure with frontmatter and procedure

**Closest analog:** `skills/discuss/SKILL.md:1-12` (full skill anatomy)

**Why this analog (one line):** The discuss skill is the most structurally complete phase-skill in the repo and the direct predecessor to the new spec skill.

**Imports**

```markdown
(none -- skills are markdown interpreted by the CC harness)
```

**Core pattern**

```markdown
---
name: discuss
description: DISCUSS phase - conversational requirements gathering, spawns a discuss team, runs advocate/challenger debate via SendMessage, writes SPEC.md.
---

# DISCUSS Phase

You are the DISCUSS phase orchestrator. Invoked by `loop-spec:cycle` after tier + style + slug are chosen.

## Inputs (from cycle skill via feature.json)

- `slug`, `tier`, `execStyle`, `feature_title`
- `feature_dir`: `.loop-spec/features/{slug}/`
- `feature_json_path`: `.loop-spec/features/{slug}/feature.json`

## Procedure

### Step 1 - ...
```

**Error handling**

```markdown
## Non-interactive mode

If invoked with no pending user conversation (e.g., `execStyle == "auto"` and the caller passes a pre-written transcript path):
- Skip Step 1.
- Read the transcript from the provided path.
- Proceed directly to Step 2 (TeamCreate).
```

**Test analog**

(none -- skill content is not unit-tested; covered by smoke.sh end-to-end)

**Application gotchas**

- The spec skill owns its own `TeamCreate`/`TeamDelete` lifecycle -- do NOT move team management into cycle.
- `LOOP_SPEC_NON_INTERACTIVE=1` must be documented inside the skill's own "Non-interactive mode" section (see cycle/SKILL.md and discuss/SKILL.md precedent); the cycle reads this env var but each skill must honor it for its own AskUserQuestion calls.
- Non-interactive mode replaces AskUserQuestion with env var reads -- document which env vars override which questions (e.g., round confirmation, override prompt at round 6).

---

## Concept: agent frontmatter schema and tool allow-list

**Closest analog:** `agents/loop-spec-spec-writer.md:1-11`

**Why this analog (one line):** spec-interviewer is a write-capable phase agent in the same family as spec-writer; identical frontmatter shape applies.

**Core pattern**

```markdown
---
name: loop-spec-spec-writer
description: Produces SPEC.md from a discuss-phase conversation. Writes only to docs/loop-spec/features/**.
tools:
  - Read
  - Write
  - Edit
  - Grep
  - Glob
model: claude-opus-4-7
---
```

**Error handling**

```markdown
## What NOT to do

- Do NOT write to any path outside `docs/loop-spec/features/{slug}/` (the PreToolUse hook will deny).
- Do NOT write code or modify other files.
```

**Test analog**

```bash
# from tests/validate-agents.sh:11-46
for f in agents/loop-spec-*.md; do
  fm=$(awk '/^---$/{c++; next} c==1{print} c==2{exit}' "$f")
  fm_name=$(echo "$fm" | grep '^name:' | sed 's/^name: *//')
  [[ "$fm_name" == "$basename" ]] || { echo "FAIL: name mismatch"; exit 1; }
  echo "$fm" | grep -q '^description: .\+' || { echo "FAIL: missing description"; exit 1; }
  echo "$fm" | grep -q '^tools:' || { echo "FAIL: missing tools"; exit 1; }
done
```

**Application gotchas**

- The `name:` value in frontmatter MUST exactly match the filename (without `.md`); `validate-agents.sh` enforces this and will fail if they diverge.
- The new `loop-spec-spec-interviewer` agent requires Write/Edit (it writes SPEC.md and interview transcript) -- it must NOT be added to the `RESTRICTED_AGENTS` list in `validate-agents.sh`.
- `validate-agents.sh` line 4 has `EXPECTED="${EXPECTED:-12}"` -- this must be bumped to 13 in the same commit that creates the new agent file, otherwise `validate-agents.sh` exits 1.

---

## Concept: path-restriction hook registration for new agent

**Closest analog:** `hooks/restrict-agent-paths.sh:85-108` (case block)

**Why this analog (one line):** Every new write-capable agent that should be restricted to `docs/loop-spec/features/**` must add its name to the case block; spec-writer and planner are the canonical examples.

**Core pattern**

```bash
case "$CALLER" in
  loop-spec-spec-writer|loop-spec-planner|loop-spec-pattern-mapper)
    if path_allowed "docs/loop-spec/features"; then
      exit 0
    fi
    echo "DENY: $CALLER may only $TOOL_NAME under docs/loop-spec/features/** (attempted: $FILE_PATH)" >&2
    exit 2
    ;;
  loop-spec-mapper-*)
    ...
    ;;
  loop-spec-implementer|loop-spec-verifier|"")
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
```

**Error handling**

```bash
# Broad except on transcript parse -- falls through to CALLER="" (unrestricted)
except Exception:
    pass
```

**Application gotchas**

- The broad `except Exception: pass` in the Python transcript-parsing block means a mis-named agent will fall through to the `*)` case (unrestricted) rather than block. After adding `loop-spec-spec-interviewer` to the case block, verify the hook test (`hooks/restrict-agent-paths.test.sh`) still exits 0.
- The `*)` case is permissive by default (CONCERNS.md:25); do not rely on it for security -- the agent must be explicitly named in the case block.
- The CONCERNS.md flags the `*)` default as a latent escape hatch -- spec-interviewer must be explicitly listed, not left to fall through.

---

## Concept: feature.json schemaVersion bump and new fields

**Closest analog:** `skills/shared/feature-state-schema.md:1-94` (full schema doc + atomic write pattern)

**Why this analog (one line):** The schema doc is the canonical source of truth for feature.json structure; the v2-to-v3 clean-break pattern documents the design intent for breaking schema changes.

**Core pattern**

```json
{
  "schemaVersion": 3,
  "currentPhase": "discuss | plan | execute | verify | completed",
  "completedPhases": ["array of phase names"],
  "retryBudget": {
    "perPhase": {"discuss": 3, "plan": 4, "execute": null, "verify": 4},
    "perPhaseUsed": {"discuss": 0, "plan": 0, "execute": 0, "verify": 0}
  },
  "artifacts": {
    "spec": "path or null"
  }
}
```

**Error handling**

```markdown
### Field notes

- Schema version jumps from 2 to 3. There is no migration from v2 (clean break).
- In-flight features must be completed on v0.3.x or restarted on v1.0.0.
```

**Application gotchas**

- v3-to-v4 migration is opt-in (not automatic), unlike the v2-to-v3 break. The migration script must be idempotent: running it twice must produce identical output (check by comparing JSON hash of two consecutive runs).
- `retryBudget.perPhase` and `retryBudget.perPhaseUsed` must each gain a `"spec"` field -- the schema doc lists them as exact keyed objects, so adding `spec` is an additive change that does not break existing v3 readers.
- `artifacts.specInterview` is new in v4 -- document it under `artifacts` in the schema section, alongside `artifacts.spec`.
- `currentPhase` enum gains `"spec"` -- update both the schema JSON block and the Field notes section in `feature-state-schema.md`.

---

## Concept: cycle skill Step 5 state initialization (new phase injection)

**Closest analog:** `skills/cycle/SKILL.md:204-257` (Step 5 jq block)

**Why this analog (one line):** The jq initialization block is the single source of truth for the default shape of a new feature.json; adding spec fields here is the only correct place.

**Core pattern**

```bash
feature_json=$(jq -n \
  --arg slug "$slug" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg tier "$tier" --arg preset "$preset" --arg style "$execStyle" \
  '{
    schemaVersion: 3,
    currentPhase: "discuss",
    completedPhases: [],
    retryBudget: {
      perPhase: {
        discuss: (if $tier == "quick" then 1 elif $tier == "balanced" then 2 else 3 end),
        plan: (if $tier == "quick" then 1 elif $tier == "balanced" then 3 else 4 end),
        execute: null,
        verify: (if $tier == "quick" then 2 elif $tier == "balanced" then 3 else 4 end)
      },
      perPhaseUsed: {discuss: 0, plan: 0, execute: 0, verify: 0}
    }
  }')
bash "${CLAUDE_PLUGIN_ROOT}/lib/feature-write.sh" ".loop-spec/features/${slug}" "$feature_json"
```

**Error handling**

```bash
# feature-write.sh validates JSON before any write:
if ! printf '%s' "$feature_json" | jq -e . >/dev/null 2>&1; then
  echo "feature-write: invalid JSON input" >&2
  exit 1
fi
```

**Application gotchas**

- Change `schemaVersion: 3` to `schemaVersion: 4` and `currentPhase: "discuss"` to `currentPhase: "spec"` in the jq block -- these are the two literal string changes required for v4 initialization.
- Add `spec: (tier-based budget)` to `perPhase` and `perPhaseUsed` in the same jq block (alongside discuss, plan, execute, verify). Use the same tier-conditional pattern as the other phases.
- Add `artifacts.specInterview: null` alongside `artifacts.spec: null` so the field exists from initialization.

---

## Concept: cycle skill Step 6 phase routing (adding new phase)

**Closest analog:** `skills/cycle/SKILL.md:359-377` (Step 6 route-to-phase block)

**Why this analog (one line):** Step 6 is a simple `Skill(loop-spec:{currentPhase})` dispatch -- adding "spec" as a valid `currentPhase` requires no structural change to Step 6 itself, only ensuring the new skill is registered.

**Core pattern**

```markdown
### Step 6 - Route to phase

1. **Invoke phase skill:**
   ```
   Skill(loop-spec:{currentPhase})
   ```
   `{currentPhase}` is read from the in-memory `feature_json` loaded earlier.
   The phase skill runs inside its own team, writes `currentTeamName` on entry,
   advances `currentPhase`, and clears `currentTeamName` on exit.
```

**Error handling**

```markdown
3. **Route to next iteration:**
   - If `next_phase == "completed"`: jump to the "On completion" section below.
   - If `execStyle` is `auto` or `review-only`: continue the loop.
   - If `execStyle` is `step` or `interactive`: print phase summary and return to user.
```

**Application gotchas**

- The routing is generic (`Skill(loop-spec:{currentPhase})`), so no code change to the routing logic is needed -- only the initialization in Step 5 (changing `currentPhase: "discuss"` to `currentPhase: "spec"`) and the description text in Step 6 need to change.
- The description text at the top of cycle/SKILL.md currently says "DISCUSS -> PLAN -> EXECUTE -> VERIFY"; update it to "SPEC -> DISCUSS -> PLAN -> EXECUTE -> VERIFY". Check the `name:` frontmatter description too.

---

## Concept: cycle skill resume with schemaVersion detection and AskUserQuestion migration prompt

**Closest analog:** `skills/cycle/SKILL.md:67-87` (Step 1 resume detection block)

**Why this analog (one line):** The resume detection is already structured around reading feature.json fields; adding a schemaVersion check follows the same parse-then-branch pattern.

**Core pattern**

```markdown
### Step 1 - Resume detection

Scan `.loop-spec/features/*/feature.json` (if directory exists). For each:
- Parse safely (try/except; on parse fail, try `feature.json.bak`)
- Skip if `currentPhase == "completed"`
- **Orphan detection:** if `currentTeamName != null`, probe team liveness ...
- If `currentTeamName == null` AND `(now - updatedAt) < stalenessHours * 3600`: add to resumable list.

If resumable list non-empty: present via AskUserQuestion (or skip if LOOP_SPEC_NON_INTERACTIVE=1)
```

**Error handling**

```markdown
- On parse failure, try `feature.json.bak`. On both failing, skip the candidate.
```

**Application gotchas**

- The schemaVersion check should happen AFTER parsing but BEFORE the orphan probe -- a v3 feature that is also orphaned should show the orphan-cleanup message, not the migration prompt.
- When `LOOP_SPEC_NON_INTERACTIVE=1`, the migration prompt must be skipped; the default behavior should be "finish on v3" (conservative) unless `LOOP_SPEC_ANSWER_MIGRATE_SCHEMA=1` is set.
- AskUserQuestion for migration must be a separate call from the resume-feature-selection prompt -- do not combine them into a single ambiguous multi-question prompt.

---

## Concept: lib bash script with set -euo pipefail, jq mutation, and atomic write

**Closest analog:** `lib/feature-write.sh:1-93` (full script)

**Why this analog (one line):** `migrate-schema-v3-to-v4.sh` is a lib script in the same family -- same error handling discipline, same jq-mutation approach, same atomic-write pattern via `feature-write.sh`.

**Core pattern**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Subcommand dispatch: set/append for targeted key mutation
if [[ "$1" == "set" || "$1" == "append" ]]; then
  ...
fi

if [[ $# -ne 2 ]]; then
  echo "usage: feature-write.sh <feature_dir> <feature_json_string>" >&2
  exit 1
fi

# Validate JSON
if ! printf '%s' "$feature_json" | jq -e . >/dev/null 2>&1; then
  echo "feature-write: invalid JSON input" >&2
  exit 1
fi

# Atomic write
{
  printf '%s\n' "$feature_json" > "$tmp"
  sync
  [[ -f "$final" ]] && mv "$final" "$bak"
  mv "$tmp" "$final"
} || { echo "feature-write: io failure" >&2; exit 2; }
```

**Test analog**

```bash
# from tests/lib/feature-write.test.sh:22-58 -- canonical test structure for a lib script
LIB="$(cd "$(dirname "$0")/../.." && pwd)/lib/feature-write.sh"
PASS=0; FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name (expected $expected, got $actual)"; ((FAIL++)) || true
  fi
}

WORK="${TMPDIR:-/tmp}/loop-spec-feature-write.$$"
trap 'rm -rf "$WORK"' EXIT
```

**Application gotchas**

- Use `${TMPDIR:-/tmp}` for temp work dirs in tests, not `/tmp` directly -- the sandbox policy requires TMPDIR.
- `migrate-schema-v3-to-v4.sh` must delegate to `feature-write.sh` for the actual write (not write feature.json directly) so the atomic-write contract is honored.
- The migration script must verify the input is schemaVersion 3 and exit 0 (no-op) if it is already version 4 -- this makes it idempotent and safe to run twice.

---

## Concept: test suite for a lib script (pass/fail/count pattern)

**Closest analog:** `tests/lib/feature-write.test.sh:1-80` (full test file)

**Why this analog (one line):** All lib test files follow the same `check()` helper + WORK tmpdir + trap EXIT pattern; `migrate-schema-v3-to-v4.test.sh` must follow this pattern exactly.

**Core pattern**

```bash
#!/usr/bin/env bash
set -euo pipefail

LIB="$(cd "$(dirname "$0")/../.." && pwd)/lib/migrate-schema-v3-to-v4.sh"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name (expected $expected, got $actual)"; ((FAIL++)) || true
  fi
}

WORK="${TMPDIR:-/tmp}/loop-spec-migrate.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/feat"

echo ""
if [[ "$FAIL" -gt 0 ]]; then
  echo "FAIL: $FAIL test(s) failed"
  exit 1
fi
echo "PASS: all $PASS tests passed"
```

**Application gotchas**

- End with `exit 0` explicitly (or rely on `[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0`). `run-all.sh` treats any non-zero exit as a suite failure.
- `run-all.sh` discovers test suites by explicit name -- the new test must be added to `run-all.sh` with a `run_suite` call. Do not rely on globbing.
- `((PASS++)) || true` is the idiomatic pattern to avoid `set -e` tripping on arithmetic in bash; use it consistently.

---

## Concepts with no clear analog

- `ambiguity scoring formula` -- The four-dimension weighted scoring formula (`1.0 - (0.35*goal + 0.25*boundary + 0.20*constraint + 0.20*acceptance)`) and per-dimension gate minimums are novel to this codebase. There is no existing scoring or gate-threshold numeric computation in any skill or agent. The spec-interviewer agent will implement this as inline prose instructions to the Claude model (no external library). Planner should treat the scoring display format and gate check logic as novel work derived from the GSD reference at `/Users/cbobrowitz/Projects/_reference/gsd-redux/get-shit-done/workflows/spec-phase.md`.
- `Socratic interview loop with rotating perspectives` -- No existing skill or agent in the repo conducts a multi-round, perspective-rotating interview. The discuss phase has a conversational loop (discuss/SKILL.md Step 1) but it does not apply named perspectives or cap rounds at 6. The spec skill's interview loop is novel; the planner should derive it from the GSD reference source and the SPEC.md decisions block.
- `ambiguity_scores frontmatter block in SPEC.md` -- No existing SPEC.md template or artifact template contains a scored-dimensions frontmatter block. The planner should note this as novel content added to the SPEC.md.template output, not as an existing pattern to copy.

## Open questions for the planner

- The SPEC.md.template (`skills/shared/artifact-templates/SPEC.md.template`) does not currently have an `ambiguity_scores` frontmatter block. The spec-interviewer will need to add this block when writing SPEC.md. Confirm whether the template itself should be updated (adding a static placeholder) or whether the agent adds it dynamically without a template change. Based on the SPEC.md for this feature (which already has `ambiguity_scores` as a locked decision), the planner should assume the template is NOT modified (spec-interviewer adds the block dynamically) unless the spec says otherwise.
