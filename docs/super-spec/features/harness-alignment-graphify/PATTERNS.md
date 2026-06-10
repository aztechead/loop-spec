# PATTERNS.md - harness-alignment-graphify

> Produced by `super-spec-pattern-mapper`. Read by `super-spec-planner` before drafting tasks.
> One section per **concept** the upcoming feature will need. Concepts are system-design nouns/verbs, not file paths.

## Codebase context consulted

- `docs/super-spec/codebase/TECH.md`
- `docs/super-spec/codebase/ARCH.md`
- `docs/super-spec/codebase/QUALITY.md`
- `docs/super-spec/codebase/CONCERNS.md`
- `docs/super-spec/codebase/DOMAIN.md`

---

## Concept: Claude Code settings.json key injection

**Closest analog:** `.claude/` directory exists (only `worktrees/` inside); no `settings.json` yet exists in the repo.

**Why this analog (one line):** The SPEC requires adding `worktree.baseRef: "head"` to `.claude/settings.json`; there is no existing file to adapt, so this is novel file creation, but the key format follows the CC worktree documentation pattern.

**Imports**

```json
// .claude/settings.json format (CC harness-managed JSON)
// No imports - pure JSON config consumed by the Claude Code CLI at startup
```

**Core pattern**

```json
{
  "worktree": {
    "baseRef": "head"
  }
}
```

**Error handling**

```
// Verify command from SPEC:
python3 -c "import json,sys; d=json.load(sys.stdin); assert d['worktree']['baseRef'] == 'head', 'FAIL'" < .claude/settings.json
// Exits 0 on success; AssertionError on wrong value; FileNotFoundError if missing.
```

**Test analog** (if any)

```bash
# No existing test for settings.json; use verify command from SPEC criteria 1.
# Closest pattern: smoke.sh asserts feature.json fields via python3 inline:
python3 -c "import json; d=json.load(open('feature.json')); assert d['schemaVersion'] == 3"
# From tests/smoke.sh (same inline assertion style)
```

**Application gotchas**

- `.claude/` already exists but contains only `worktrees/`; do NOT overwrite the directory, only create `settings.json` inside it.
- The key is `worktree.baseRef` (nested JSON), not a flat `baseRef` key.
- No migration from an absent file is needed; create fresh with only the required key.

---

## Concept: hooks.json event-matcher migration

**Closest analog:** `hooks/hooks.json:1-36` (the entire file - current `PostToolUse:TaskUpdate` block)

**Why this analog (one line):** The feature replaces the existing `PostToolUse:TaskUpdate` entry with `TaskCompleted` and `TaskCreated` top-level events; the file is the only hooks registration point.

**Imports**

```json
// hooks/hooks.json structure:
// { "hooks": { "<EventName>": [ { "type": "command", "command": "...", "continueOnBlock": true } ] } }
```

**Core pattern** (current, to be replaced)

```json
// hooks/hooks.json:14-24 (existing PostToolUse block)
"PostToolUse": [
  {
    "matcher": "TaskUpdate",
    "hooks": [
      {
        "type": "command",
        "command": "${CLAUDE_PLUGIN_ROOT}/hooks/team/task-completed.sh"
      }
    ]
  }
]
```

**Error handling**

```json
// Verify via python3 assertion (from SPEC criteria 2):
// assert 'TaskCompleted' in events
// assert 'TaskCreated' in events
// assert no PostToolUse:TaskUpdate with matcher='TaskUpdate' remains
```

**Test analog** (if any)

```python
# From SPEC success criteria (authoritative):
python3 -c "
import json
d=json.load(open('hooks/hooks.json'))
events=list(d['hooks'].keys())
assert 'TaskCompleted' in events
assert 'TaskCreated' in events
tu=[h for h in d['hooks'].get('PostToolUse',[]) if h.get('matcher','')=='TaskUpdate']
assert len(tu)==0
"
```

**Application gotchas**

- `continueOnBlock: true` is required on the `TaskCompleted` entry (SPEC criterion 3); do not omit it.
- `TaskCreated` goes on `PreToolUse` (fires before the TaskCreate call, so it can block malformed tasks before they enter the harness); `TaskCompleted` is a dedicated event (not PostToolUse).
- The `TeammateIdle` entry must be preserved unchanged.
- The `PreToolUse: Write|Edit` entry must also be preserved unchanged.

---

## Concept: hook script event-payload adaptation (task-completed.sh)

**Closest analog:** `hooks/team/task-completed.sh:1-174`

**Why this analog (one line):** The hook must be rewritten to remove status-parsing logic (`$STATUS != "completed"` branch) because `TaskCompleted` fires only on completion transitions; the rest of the phase-gate logic (lint/typecheck in execute, metadata validation in discuss/plan) is preserved verbatim.

**Imports**

```bash
#!/usr/bin/env bash
set -euo pipefail
INPUT=$(cat)
```

**Core pattern** (lines 20-32, the status-parsing block to DELETE)

```bash
# hooks/team/task-completed.sh:20-32 (DELETE this block)
TOOL_NAME=$(printf '%s' "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tool_name',''))")

# Only apply to TaskUpdate calls
if [[ "$TOOL_NAME" != "TaskUpdate" ]]; then
  exit 0
fi

STATUS=$(printf '%s' "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('status',''))")

# Only apply when status is being set to completed
if [[ "$STATUS" != "completed" ]]; then
  exit 0
fi
```

**Error handling**

```bash
# hooks/team/task-completed.sh:107-117 (PRESERVE - run_check allowlist guard)
run_check() {
  local cmd="$1"
  if [[ "$cmd" =~ [^[:alnum:][:space:]_./@:=+-] ]]; then
    echo "DENY: feature.json command contains forbidden character; refusing to execute: $cmd" >&2
    return 2
  fi
  local -a parts
  read -ra parts <<< "$cmd"
  local rc=0
  ( "${parts[@]}" ) >/dev/null 2>&1 || rc=$?
  return $rc
}
```

**Test analog** (if any)

```bash
# hooks/team/task-completed.test.sh:44-48 (existing test harness shape - adapt for new event)
payload_completed() {
  local task_id="${1:-task-001}"
  # Old: '{"tool_name":"TaskUpdate","tool_input":{"taskId":"...","status":"completed"}}'
  # New (TaskCompleted event): '{"event":"TaskCompleted","task":{"taskId":"..."}}'
  # Exact payload shape must be verified against CC harness docs/source
  printf '{"tool_name":"TaskCompleted","tool_input":{"taskId":"%s"}}' "$task_id"
}
```

**Application gotchas**

- The new `TaskCompleted` event payload schema may differ from the old `TaskUpdate` payload. The `tool_input.status` path no longer applies; check CC harness event payload docs before writing the new input-parsing block.
- The `validate_metadata` function at lines 63-93 was designed for `PostToolUse:TaskUpdate`; its `d.get('tool_input',{}).get('metadata',None)` path may need adjustment for the new event payload structure.
- Do NOT silently drop the existing test suite (`task-completed.test.sh`); update the test fixtures to match the new payload shape.

---

## Concept: new hook script creation (task-created.sh)

**Closest analog:** `hooks/team/teammate-idle.sh:1-69` (existing hook script of similar size; same bash conventions)

**Why this analog (one line):** `task-created.sh` is a new `PreToolUse:TaskCreate` hook that validates task metadata at creation time; `teammate-idle.sh` is the best structural analog (small advisory hook with graceful fallbacks).

**Imports**

```bash
#!/usr/bin/env bash
# PreToolUse hook: validate task metadata at creation time.
# exit 0 = allow, exit 2 = block (DENY message to stderr)
set -euo pipefail
INPUT=$(cat)
```

**Core pattern** (from `teammate-idle.sh:14-42` - graceful feature.json location pattern)

```bash
# teammate-idle.sh:19-27 (reuse this feature.json location pattern)
FEATURE_JSON=""
if [[ -n "${SUPER_SPEC_FEATURE_DIR:-}" ]]; then
  FEATURE_JSON="${SUPER_SPEC_FEATURE_DIR}/feature.json"
else
  if [[ -d ".super-spec/features" ]]; then
    FEATURE_JSON=$(find .super-spec/features -maxdepth 2 -name feature.json | head -1)
  fi
fi
```

**Error handling**

```bash
# Pattern from restrict-agent-paths.sh:86-91 (DENY exit 2 pattern)
echo "DENY: Task metadata missing required fields: $MISSING_FIELDS" >&2
exit 2
```

**Test analog** (if any)

```bash
# hooks/team/task-completed.test.sh:14-42 (reuse check() harness pattern for task-created tests)
check() {
  local name="$1"
  local expected_exit="$2"
  local payload="$3"
  local actual_exit=0
  echo "$payload" | bash "$HOOK" >/dev/null 2>&1 || actual_exit=$?
  if [[ "$actual_exit" -eq "$expected_exit" ]]; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name (expected exit $expected_exit, got $actual_exit)"; ((FAIL++)) || true
  fi
}
```

**Application gotchas**

- SPEC criterion 5 requires exit 2 when required metadata fields (`blockedBy`, `files`, `verifyCommand`, `acceptanceCriteria`) are absent from `tool_input.metadata`.
- The payload for `PreToolUse:TaskCreate` contains `tool_input.metadata` (not `tool_input.status`). Check the CC harness payload shape before writing the parser.
- ARCH.md already documents `task-created.sh` as existing at `hooks/team/task-created.sh`; however the file does not exist on disk. This is novel file creation.
- The metadata validation logic to implement is the same as `validate_metadata()` in `task-completed.sh:63-93`; extract it to avoid duplication, or duplicate it (project has no shared bash lib for this pattern yet).

---

## Concept: optional external tool detection (graphify pre-flight)

**Closest analog:** `hooks/team/teammate-idle.sh:36-41` (jq-vs-python3 fallback pattern)

**Why this analog (one line):** The `command -v jq` check with a `python3` fallback in `teammate-idle.sh` is the project's only existing optional-tool detection pattern.

**Imports**

```bash
# No imports; pure bash capability check
```

**Core pattern**

```bash
# teammate-idle.sh:36-41 (optional tool detection pattern)
if command -v jq >/dev/null 2>&1; then
  CURRENT_PHASE=$(jq -r '.currentPhase // empty' "$FEATURE_JSON" 2>/dev/null) || true
else
  # Fallback: python3 for zero-dep environments
  CURRENT_PHASE=$(python3 -c "..." < "$FEATURE_JSON" 2>/dev/null) || true
fi
```

**Error handling**

```bash
# For graphify, the pattern is: detect presence, run if available, skip + warn if absent.
if command -v graphify >/dev/null 2>&1; then
  graphify . --update --wiki
else
  echo "[map-codebase] graphify not installed. Install with: pip install graphifyy" >&2
fi
```

**Test analog** (if any)

```bash
# No existing test for optional-tool detection. Verify via grep:
grep -n 'command -v graphify' skills/map-codebase/SKILL.md  # must match
```

**Application gotchas**

- `command -v graphify` is the correct idiom (not `which graphify` or `hash graphify`); consistent with the jq check in `teammate-idle.sh:36`.
- The SPEC uses `graphify . --update --wiki` in map-codebase and `graphify . --update` (no `--wiki`) in verify. The distinction is intentional: verify needs a fast update without rebuilding the full wiki.
- SPEC criterion 8 requires both `command -v graphify` and `graphify.*--update` to appear in `skills/map-codebase/SKILL.md`.

---

## Concept: mapper agent deletion + validate-agents.sh count update

**Closest analog:** `tests/validate-agents.sh:4` (hard-coded `EXPECTED="${EXPECTED:-14}"`)

**Why this analog (one line):** Deleting `super-spec-mapper-arch.md` and `super-spec-mapper-tech.md` drops the agent count from 14 to 12; the validator's hard-coded constant must be updated in the same commit.

**Imports**

```bash
#!/usr/bin/env bash
EXPECTED="${EXPECTED:-14}"   # <-- change to 12
```

**Core pattern**

```bash
# tests/validate-agents.sh:4-9
EXPECTED="${EXPECTED:-14}"
# ...
count=$(ls agents/super-spec-*.md 2>/dev/null | wc -l | tr -d ' ')
[[ "$count" == "$EXPECTED" ]] || { echo "FAIL: expected $EXPECTED agent files, found $count"; exit 1; }
```

**Error handling**

```bash
# After deleting agent files and updating constant:
bash tests/validate-agents.sh  # must print "All 12 agents validated." and exit 0
```

**Test analog** (if any)

```bash
# tests/validate-agents.test.sh exercises the validator against fixtures.
# After this change, run: bash tests/validate-agents.sh (the full validator, not just the fixture test).
```

**Application gotchas**

- Delete both `.md` files and update the constant in the same commit to avoid a transient failure window where agent count is 12 but constant is 14.
- The `restrict-agent-paths.sh` hook uses `super-spec-mapper-*` glob pattern (line 93), which does NOT need updating when specific mapper files are deleted - the glob still covers the remaining three mappers.
- `map-codebase/SKILL.md` references mapper teammates by name in the TeamCreate block; remove the `mapper-tech-1` and `mapper-arch-1` entries from that block as part of the graphify integration task (not this deletion task).

---

## Concept: skill markdown conditional-path documentation (two-path skill prose)

**Closest analog:** `skills/map-codebase/SKILL.md:32-44` (the incremental mode conditional already in the skill)

**Why this analog (one line):** The map-codebase skill already uses `If mode == "full" or --domain specified: ...` conditional prose; the graphify-present / graphify-absent conditional follows the same pattern.

**Imports**

```markdown
<!-- Skills are markdown files; no imports. Conditionals are expressed as prose. -->
```

**Core pattern**

```markdown
<!-- skills/map-codebase/SKILL.md:32-44 - existing conditional prose pattern -->
### Step 1 - Determine stale domains

If `mode == "full"` or `--domain` specified: stale_domains = explicit list (or all 5)

Else (incremental):
...
```

**Error handling**

```markdown
<!-- For graphify conditional, follow the same prose-branch style: -->
### Step 0 - Pre-flight graphify detection

```bash
if command -v graphify >/dev/null 2>&1; then
  graphify . --update --wiki
  # dispatch only QUALITY, CONCERNS, DOMAIN mappers (Step 2)
else
  echo "[map-codebase] graphify not installed. Install with: pip install graphifyy" >&2
  # dispatch all 5 mappers: TECH, ARCH, QUALITY, CONCERNS, DOMAIN (Step 2)
fi
```
```

**Test analog** (if any)

```bash
# Verify via SPEC grep criterion (criterion 8):
grep -n 'command -v graphify' skills/map-codebase/SKILL.md   # exits 0
grep -n 'graphify.*--update\|--update.*graphify' skills/map-codebase/SKILL.md  # exits 0
grep -n 'fallback\|5.*mapper\|five.*mapper\|mapper-tech\|mapper-arch' skills/map-codebase/SKILL.md  # exits 0
```

**Application gotchas**

- Skill files are prose interpreted by an LLM; the bash block above is illustrative, not executable. Keep it in a code fence but it is read as instruction.
- The `--wiki` flag triggers wiki generation in `graphify-out/wiki/`; the SPEC's acceptance criterion for planner/pattern-mapper agents references `graphify-out/wiki` as a navigation source.
- The verify skill's Step 7 already invokes map-codebase; add `graphify . --update` (no `--wiki`) to `verify/SKILL.md` Step 7 preamble (before the map-codebase invocation), conditional on `command -v graphify`.

---

## Concept: agent prompt instruction update (graphify query preference)

**Closest analog:** `agents/super-spec-planner.md:55-63` (the "Role boundary" section with read instructions)

**Why this analog (one line):** Both planner and pattern-mapper agents have "Role boundary" or "Procedure" sections listing what to read; the graphify query instructions go in those sections as a conditional preference rule.

**Imports**

```markdown
<!-- Agent files are YAML-frontmatter + markdown; no imports. -->
```

**Core pattern**

```markdown
<!-- agents/super-spec-planner.md:55-63 (existing role boundary - add graphify preference above) -->
## Role boundary

- Read `patterns_path` (PATTERNS.md) before drafting tasks.
```

**Error handling**

```markdown
<!-- Verify via SPEC grep criterion (criteria 11-12): -->
<!-- grep -n 'graphify.*query\|graphify.*path\|graphify.*explain\|graphify-out/wiki' agents/super-spec-planner.md -->
<!-- grep -n 'graphify.*query\|graphify.*path\|graphify.*explain\|graphify-out/wiki' agents/super-spec-pattern-mapper.md -->
```

**Test analog** (if any)

```bash
# Agent prompt bodies have no unit test; validate via grep:
grep -n 'graphify' agents/super-spec-planner.md
grep -n 'graphify' agents/super-spec-pattern-mapper.md
```

**Application gotchas**

- The graphify instruction must be conditional on presence: agents cannot `command -v graphify`; phrase it as "If `graphify-out/wiki/index.md` exists, prefer `graphify query/path/explain` over reading flat ARCH.md and TECH.md".
- Do NOT remove the flat-file fallback from the agent instructions. The graphify path is additive, not a replacement.
- QUALITY.md, CONCERNS.md, and DOMAIN.md reads are explicitly out of scope for replacement (SPEC non-goals); only ARCH.md and TECH.md reads should be de-prioritized.

---

## Concept: feature-state-schema graphify block addition

**Closest analog:** `skills/shared/feature-state-schema.md:22-36` (the `artifacts` block in the v3 schema)

**Why this analog (one line):** The SPEC requires adding a `graphify` block to `index.json` schema and reflecting the reduced mapper set; the `artifacts.codebaseSource` block is the closest structural analog.

**Imports**

```markdown
<!-- feature-state-schema.md is markdown prose + JSON example; no imports. -->
```

**Core pattern**

```json
// skills/shared/feature-state-schema.md:22-36 (artifacts block shape - analogous structure)
"artifacts": {
  "codebaseSource": {
    "tech": "gsd-ingest | mapper | manual | null",
    "arch": "gsd-ingest | mapper | manual | null",
    ...
  }
}
```

**Error handling**

```bash
# Verify via SPEC criterion 13:
grep -n 'graphify' skills/shared/feature-state-schema.md   # exits 0
# Plus content check: match includes 'last_updated' or 'graph_json_path' or 'wiki_path'
```

**Application gotchas**

- The new block should live inside `.super-spec/codebase/index.json` schema documentation (which is already documented in `feature-state-schema.md`), not inside `feature.json` schema.
- The `last_refreshed_at` domain set should document that in graphify-present mode only `quality`, `concerns`, and `domain` domains appear; `tech` and `arch` are handled by graphify.
- Do NOT change the `feature.json` schema itself (that is a separate concern not required by the SPEC).

---

## Concepts with no clear analog

- `TaskCompleted` and `TaskCreated` event payload schemas -- The CC harness documentation for these dedicated event types is not in the codebase. The implementer must check CC harness docs or use the `PostToolUse:TaskUpdate` payload shape as a fallback assumption and note it explicitly. The SPEC acknowledges the payload shape may differ.
- `continueOnBlock: true` semantics -- No existing hook in the repo uses this flag. The SPEC states it allows implementers to fix and retry in the same turn rather than ending the turn on a block. The implementer should add it verbatim to the `TaskCompleted` hooks entry without inferring further semantics from the codebase.
- `.claude/settings.json` `worktree.baseRef` key -- No existing `.claude/settings.json` in the repo (only `.claude/worktrees/`). The key name and value come from CC v2.1.133 release notes referenced in the SPEC, not from the codebase itself.

## Open questions for the planner

- The `TaskCompleted` event payload schema is not documented in the codebase. Assumption: `{"tool_name":"TaskCompleted","tool_input":{"taskId":"..."}}` (analogous to old TaskUpdate shape). State this assumption explicitly in the task implementing `task-completed.sh`.
- The `TaskCreated` event payload schema is not documented in the codebase. Assumption: `{"tool_name":"TaskCreate","tool_input":{"metadata":{...}}}` (consistent with what `task-created.sh` already expects per ARCH.md). State this assumption in the task implementing `task-created.sh`.
- graphify `--update` flag: per the graphify README, `--update` re-extracts only changed files. The `--wiki` flag generates `graphify-out/wiki/`. In verify, `graphify . --update` (without `--wiki`) is faster; in map-codebase, `graphify . --update --wiki` keeps the wiki current. This split is what the SPEC specifies.
