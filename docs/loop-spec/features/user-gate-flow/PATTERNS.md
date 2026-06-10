# PATTERNS.md - user-gate-flow

> Produced by `loop-spec-pattern-mapper`. Read by `loop-spec-planner` before drafting tasks.
> One section per **concept** the upcoming feature will need.

## Codebase context consulted

- `docs/loop-spec/codebase/TECH.md`
- `docs/loop-spec/codebase/ARCH.md`
- `docs/loop-spec/codebase/QUALITY.md`
- `docs/loop-spec/codebase/CONCERNS.md`
- `docs/loop-spec/codebase/DOMAIN.md`
- `hooks/team/task-created.sh`
- `hooks/team/task-completed.sh`
- `hooks/team/task-created.test.sh`
- `hooks/team/task-completed.test.sh`
- `hooks/team/teammate-idle.sh`
- `lib/validate-task-metadata.sh`
- `tests/lib/validate-task-metadata.test.sh`
- `hooks/hooks.json`

---

## Concept: Hook kill-switch and fail-open pattern

**Closest analog:** `hooks/team/task-completed.sh:1-36`

**Why this analog:** task-completed.sh is the most complete production hook; it demonstrates the full kill-switch + fail-open + stdin-capture idiom used by all team hooks.

**Core pattern**

```bash
set -euo pipefail

INPUT=$(cat)   # capture stdin once; reused by all python3 calls below

# Kill-switch: set LOOP_SPEC_SOME_GUARD=0 to disable
if [[ "${LOOP_SPEC_SOME_GUARD:-1}" == "0" ]]; then
  exit 0
fi

# Fail-open: any read / parse error must produce exit 0, not exit 2
FEATURE_DIR="${LOOP_SPEC_FEATURE_DIR:-}"
FEATURE_JSON=""
if [[ -n "$FEATURE_DIR" ]]; then
  FEATURE_JSON="$FEATURE_DIR/feature.json"
else
  REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
  FEATURE_JSON=$(find "$REPO_ROOT/.loop-spec/features" -maxdepth 2 -name "feature.json" 2>/dev/null | head -1 || true)
fi

if [[ -z "$FEATURE_JSON" || ! -f "$FEATURE_JSON" ]]; then
  exit 0   # fail-open: no state = no block
fi
```

**Error handling**

All python3 calls wrap the body in `try/except Exception: print('')` so any parse error yields an empty string that the bash guard treats as "unknown = allow":

```python
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(d.get('currentPhase', ''))
except Exception:
    print('')
```

**Test analog**

```bash
# From hooks/team/task-completed.test.sh:119-125
# A: Missing feature.json -> ALLOW (exit 0)
check "A: missing feature.json graceful exit 0" 0 \
  "$(payload_completed)"

# K: feature dir exists but no feature.json -> exit 0
echo "$(payload_completed)" | LOOP_SPEC_FEATURE_DIR="$EMPTY_DIR" bash "$HOOK" >/dev/null 2>&1 || check_exit=$?
```

**Application gotchas**

- Kill-switch env var name must be unique per hook; do NOT reuse `LOOP_SPEC_FEATURE_DIR` as a kill-switch.
- The `|| true` on `find` is mandatory under `set -euo pipefail`; omitting it causes the hook to exit 1 on a missing directory instead of falling through.
- New hooks do NOT read `feature.json` for phase detection; they read the CC transcript via stdin (`INPUT=$(cat)`).

---

## Concept: Stdin JSON capture and python3 parsing

**Closest analog:** `hooks/team/task-created.sh:15-47`

**Why this analog:** task-created.sh is the canonical minimal example of `INPUT=$(cat)` + inline python3 for parsing hook payloads.

**Core pattern**

```bash
INPUT=$(cat)

validate_metadata() {
  printf '%s' "$INPUT" | python3 -c "
import json, sys

d = json.load(sys.stdin)
metadata = d.get('tool_input', {}).get('metadata', None)

required = ['blockedBy', 'files', 'verifyCommand', 'acceptanceCriteria']
missing = []
# ... validation logic ...
if missing:
    print('MISSING:' + ','.join(missing))
else:
    print('OK')
"
}

RESULT=$(validate_metadata)
if [[ "$RESULT" != "OK" ]]; then
  echo "DENY: ..." >&2
  exit 2
fi
exit 0
```

**Error handling**

The python3 block uses `json.load(sys.stdin)` which will raise `json.JSONDecodeError` on malformed input. The caller must either catch this in the python3 block or surround the entire `validate_metadata` call with a bash guard that treats a non-zero subshell exit as fail-open (exit 0), not fail-closed (exit 2).

**Test analog**

```bash
# From hooks/team/task-created.test.sh:12-27
check() {
  local name="$1"
  local expected_exit="$2"
  local payload="$3"
  local actual_exit=0

  echo "$payload" | bash "$HOOK" >/dev/null 2>&1 || actual_exit=$?

  if [[ "$actual_exit" -eq "$expected_exit" ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected exit $expected_exit, got $actual_exit)"
    ((FAIL++)) || true
  fi
}
```

**Application gotchas**

- New hooks parse a different payload shape: `Stop` event payloads differ from `TaskCreate` payloads. The python3 extraction logic must match the actual event schema (transcript array under `stop_hook_active` or similar), not the `tool_input.metadata` path from task-created.
- Use `printf '%s' "$INPUT"` not `echo "$INPUT"` to avoid adding a trailing newline to binary-unsafe content.

---

## Concept: Hook test harness (check() + payload helpers)

**Closest analog:** `hooks/team/task-created.test.sh:1-73`

**Why this analog:** task-created.test.sh is the shortest and most idiomatic of the test harnesses; its `check()` + `payload_with_metadata()` structure is the house pattern for all hook unit tests.

**Core pattern**

```bash
#!/usr/bin/env bash
set -euo pipefail

HOOK="$(dirname "$0")/task-created.sh"

PASS=0
FAIL=0

check() {
  local name="$1"
  local expected_exit="$2"
  local payload="$3"
  local actual_exit=0

  echo "$payload" | bash "$HOOK" >/dev/null 2>&1 || actual_exit=$?

  if [[ "$actual_exit" -eq "$expected_exit" ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected exit $expected_exit, got $actual_exit)"
    ((FAIL++)) || true
  fi
}

echo "=== task-created.sh tests ==="
# ... test cases ...
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
```

**Application gotchas**

- Tests that require env var overrides (e.g., kill-switch, trace-log path) must use `env VAR=value bash "$HOOK"`, not `VAR=value bash "$HOOK"`. The `env` form is portable across macOS `zsh` default shells.
- The `((PASS++)) || true` idiom is required because `((expr))` returns exit 1 when the result is 0, which triggers `set -e`. Do NOT replace it with `PASS=$((PASS + 1))`.
- Each test file must clean up any temp files in a `rm -rf "$TMPDIR_TESTS"` block at the end.

---

## Concept: hooks.json event wiring with continueOnBlock

**Closest analog:** `hooks/hooks.json:14-24`

**Why this analog:** The `TaskCompleted` entry is the only existing example of `continueOnBlock: true` in the repo, which is the required behavior for the chained `post-task-complete-revalidate.sh` entry.

**Core pattern**

```json
"TaskCompleted": [
  {
    "continueOnBlock": true,
    "hooks": [
      {
        "type": "command",
        "command": "${CLAUDE_PLUGIN_ROOT}/hooks/team/task-completed.sh"
      }
    ]
  }
]
```

**Application gotchas**

- `Stop` event entries in `hooks.json` do NOT use `continueOnBlock`; they use only `hooks: [{type, command}]`.
- `PreToolUse` entries require a `matcher` string alongside `hooks`; the `TaskUpdate` matcher covers all `TaskUpdate` tool calls including status transitions.
- Multiple hooks under the same event are separate array entries, not merged into one `hooks` array inside a single entry.
- The `${CLAUDE_PLUGIN_ROOT}` variable is expanded by the CC harness at runtime; use it consistently rather than relative paths.

---

## Concept: Schema extension with optional fields in a markdown table

**Closest analog:** `skills/shared/feature-state-schema.md:96-118`

**Why this analog:** The "Harness task list usage" table in feature-state-schema.md is the canonical location for documenting task metadata fields; it uses a 4-column table (`Field | Type | Set by | Description`) that all consumers read.

**Core pattern**

```markdown
| Field | Type | Set by | Description |
|---|---|---|---|
| `retries` | integer | Hook ... | Per-task retry counter ... |
| `claimedBy` | string or null | Implementer ... | ... |
| `blockedBy` | array of task ids | Lead at `TaskCreate` | ... |
```

**Application gotchas**

- New optional fields must be marked optional explicitly (e.g., "Optional. Set by ...") in the Description column; unmarked fields are assumed required by readers.
- Do NOT add new fields to the `feature.json` Schema (v3) block at the top of the file; the 9 new fields live only in the task metadata table, not in the feature-level JSON schema.

---

## Concept: lib/validate-task-metadata.sh extension for optional fields

**Closest analog:** `lib/validate-task-metadata.sh:35-70`

**Why this analog:** This is the only orchestrator-side schema validator in the repo; it uses the same python3-inline pattern and must be extended to accept the 9 new optional fields without rejecting them.

**Core pattern**

```bash
RESULT=$(printf '%s' "$METADATA" | python3 -c "
import json, sys

try:
    metadata = json.loads(sys.stdin.read())
except json.JSONDecodeError as e:
    print(f'INVALID_JSON:{e}')
    sys.exit(0)

required = ['blockedBy', 'files', 'verifyCommand', 'acceptanceCriteria']
missing = []

# ... check required fields ...

if missing:
    print('MISSING:' + ','.join(missing))
else:
    print('OK')
")
```

**Application gotchas**

- The validator uses an explicit `required` list; unknown fields in the input are silently ignored by the current implementation. Extending it for optional fields means simply verifying that if a new field IS present, its value is of the correct type. Do NOT add the new fields to `required`.
- The python3 inline block is passed as a `-c` argument; keep it under ~40 lines to stay readable. If the type-checking logic grows, consider a `PY` heredoc pattern (used in some hooks) instead.

---

## Concept: Markdown skill document structure (SKILL.md)

**Closest analog:** `/Users/cbobrowitz/Projects/_reference/pcvelz-superpowers/skills/checking-gates/SKILL.md:1-88`

**Why this analog:** The reference `checking-gates` and `specifying-gates` SKILL.md files are the direct upstream originals for the two skills to be ported. Their YAML frontmatter + announce + numbered steps + "What NOT to do" + Integration block structure is the canonical skill layout.

**Core pattern**

```markdown
---
name: checking-gates
description: <one line role description>
---

# <Human title>

## When to invoke

<Exact trigger conditions>

**Announce at start:** "<announce text>"

## The three-step process

### Step 1 — <name>
### Step 2 — <name>
### Step 3 — <name>

## Do-I-know-HOW self-check

## What NOT to do

## Integration

- **Invoked from:** ...
- **May hand off to:** ...
- **Returns to:** ...
```

**Application gotchas**

- The reference skills reference `.tasks.json` (a superpowers-specific artifact). In loop-spec, task state lives in the harness task list (`TaskGet`/`TaskUpdate`), not a `.tasks.json` file. Replace all `.tasks.json` references with `TaskGet`/`TaskUpdate` harness calls.
- The reference skills reference `/gate-check` and `/specify-gate` slash commands that do not exist in loop-spec. Substitute the loop-spec invoke pattern: `Skill(loop-spec:checking-gates)` and `Skill(loop-spec:specifying-gates)`.
- "Sync `.tasks.json`" in specifying-gates Step 3 becomes `TaskUpdate` with the full new description in loop-spec.

---

## Concepts with no clear analog

- **Transcript window scanning for AC: / PROVEN BY tokens** -- no existing hook reads the session transcript JSONL to find assistant messages; the CC harness delivers the transcript via stdin in the Stop event payload but the exact schema (fields, nesting, content structure) is not documented in any existing hook. The implementer must treat this as novel work and be conservative: if the transcript field is absent or the format is unexpected, fail-open (exit 0).
- **Context usage percentage calculation** -- no existing hook reads `usage` data from the transcript. The `stop-deflection-guard.sh` hook will need to locate the `usage` field in the Stop payload and compute `(input_tokens + cache_read_input_tokens + cache_creation_input_tokens) / LOOP_SPEC_CONTEXT_LIMIT`. Treat as novel work.
- **Task DAG reconstruction from transcript for blockedBy enforcement** -- no existing hook queries the harness task list to reconstruct dependency state. `pre-task-blockedby-enforce.sh` must parse the `TaskUpdate` `tool_input` to extract `blockedBy` and then correlate against other tasks' statuses. The mechanism for reading peer task statuses inside a `PreToolUse` hook is not established in the codebase; the implementer must use whatever data is present in the current payload (the hook likely receives the full current task list in the Stop/TaskUpdate payload) and fail-open if not.

## Open questions for the planner

- The CC agent-teams harness Stop event payload schema (what fields are present, how the transcript is embedded) is not documented in the codebase. All three Stop/PreToolUse hooks that need to scan transcript content must treat the exact payload shape as an assumption and document it inline with a fail-open fallback.
- `validate-agents.sh` hard-codes the expected agent count (currently 12). No new agent files are added by this feature, so the count stays 12. Confirm: the spec says "All 12 agents validated." -- no new agents are added.
