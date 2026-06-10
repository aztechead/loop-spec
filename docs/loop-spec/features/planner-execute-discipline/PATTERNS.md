# PATTERNS.md - planner-execute-discipline

> Produced by `loop-spec-planner`. Read by `loop-spec-planner` before drafting tasks.
> One section per **concept** the upcoming feature will need. Concepts are system-design nouns/verbs, not file paths.

## Codebase context consulted

- `docs/loop-spec/codebase/TECH.md`
- `docs/loop-spec/codebase/ARCH.md`
- `docs/loop-spec/codebase/QUALITY.md`
- `docs/loop-spec/codebase/CONCERNS.md`
- `docs/loop-spec/codebase/DOMAIN.md`

---

## Concept: Fail-open hook with kill-switch and trace-log

**Closest analog:** `hooks/team/post-task-complete-revalidate.sh` (entire file)

**Why this analog:** It is the most recent Cycle 2 hook addition that demonstrates all three required properties: fail-open (exit 0 on any parse error), a named kill-switch env var (`LOOP_SPEC_USERGATE_GUARD=0`), and a trace-log append via a configurable path env var.

**Core pattern**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Kill switch
[[ "${LOOP_SPEC_USERGATE_GUARD:-1}" == "0" ]] && exit 0

INPUT=$(cat 2>/dev/null) || INPUT=""

# Fail-open: parse errors exit 0
parse_result=$(printf '%s' "$INPUT" | python3 -c "..." 2>/dev/null) || { exit 0; }

# Trace log
TRACE_LOG="${LOOP_SPEC_USERGATE_TRACE_LOG:-/tmp/claude-hooks/loop-spec-user-gate-trace.log}"
mkdir -p "$(dirname "$TRACE_LOG")" 2>/dev/null || true
printf '%s|%s|%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$tool_name" "$result" \
  >> "$TRACE_LOG" 2>/dev/null || true
```

**Error handling**

```bash
# Any read/parse failure exits 0 (fail-open), never exits 2
parse_result=$(printf '%s' "$INPUT" | python3 -c "..." 2>/dev/null) || { exit 0; }
```

**Test analog**

```bash
# from hooks/team/post-task-complete-revalidate.test.sh
check "kill-switch: LOOP_SPEC_USERGATE_GUARD=0 exits 0" 0 \
  "$(payload_completed)" "" "LOOP_SPEC_USERGATE_GUARD=0"

check "fail-open: malformed JSON exits 0" 0 \
  "not-json"
```

**Application gotchas**

- Kill-switch env var name must follow the `LOOP_SPEC_<FEATURE>=0` pattern; do not invent a different disabling value.
- The trace-log `mkdir -p` and `>> $TRACE_LOG` must both be guarded with `|| true` so the hook never exits non-zero from a filesystem failure.
- `set -euo pipefail` is required but `|| true` guards prevent pipefail from triggering on intentional no-ops.

---

## Concept: JSON state file per session (temp file keyed by SESSION env var)

**Closest analog:** `hooks/team/stop-revalidate-user-gates.sh` lines reading `/tmp/...` state + `hooks/team/stop-deflection-guard.sh` reading `usage` from stdin JSON

**Why this analog:** `stop-deflection-guard.sh` shows the pattern of reading a computed numeric value from the hook's stdin JSON and comparing it against a configurable threshold, which mirrors how `strategy-rotation.sh` must read consecutive-failure state from a temp JSON keyed by session. The claude-octopus reference (`hooks/strategy-rotation.sh`) provides the actual per-session state write pattern.

**Core pattern (from claude-octopus reference)**

```bash
SESSION="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-$$}}"
STATE_FILE="/tmp/loop-spec-failures-${SESSION}.json"

# Load state (fail-open)
STATE="{}"
if [[ -f "$STATE_FILE" ]] && command -v jq &>/dev/null; then
    STATE=$(cat "$STATE_FILE" 2>/dev/null) || STATE="{}"
    [[ -z "$STATE" ]] && STATE="{}"
fi

# Validate JSON (fail-open)
if command -v jq &>/dev/null; then
    if ! printf '%s' "$STATE" | jq empty 2>/dev/null; then
        STATE="{}"
    fi
fi

# Write state back (never exit non-zero on write failure)
printf '%s' "$STATE" > "$STATE_FILE" 2>/dev/null || true
```

**Error handling**

- Any `cat` or `jq` failure resets state to `{}` and continues rather than propagating an error.
- Write is guarded by `|| true`.

**Test analog**

```bash
# from hooks/team/task-completed.test.sh: pattern for tmp-dir-based state in tests
TMPDIR_TESTS="${TMPDIR:-/tmp}/strategy-rotation-tests-$$"
mkdir -p "$TMPDIR_TESTS"
# Set SESSION to an isolated value so tests don't collide with live hooks
check() { ... SESSION="test-$$" bash "$HOOK" ...; }
```

**Application gotchas**

- Use `${TMPDIR:-/tmp}` when creating the state file directory in tests; the state file itself uses `/tmp/` directly (same as octopus reference) because it is a runtime artifact, not a test artifact.
- Do not use `${SESSION:-default}` as the key literal -- use the same env var chain as octopus: `CLAUDE_CODE_SESSION_ID` then `CLAUDE_SESSION_ID` then `$$`.

---

## Concept: hookSpecificOutput additionalContext emission

**Closest analog:** `hooks/team/stop-deflection-guard.sh` lines emitting JSON to stdout

**Why this analog:** It already emits a `{"additionalContext":"..."}` JSON object to stdout (the Claude Code hook protocol for injecting context into the agent's next turn), matching the required output format for both `strategy-rotation.sh` and `budget-gate.sh`.

**Core pattern**

```bash
# Emit additionalContext block (stdout, not stderr)
cat <<EOF
{"additionalContext":"STRATEGY ROTATION NEEDED: The ${TOOL_DISPLAY} tool has failed ${CONSECUTIVE} consecutive times. Stop and verbalize what failed, describe a completely different approach, and explain why it avoids the same failure."}
EOF
```

**Error handling**

- `cat <<EOF ... EOF` never fails in practice; no guard needed.
- This is stdout-only. Diagnostic messages go to stderr.

**Test analog**

```bash
# from hooks/team/stop-deflection-guard.test.sh
output=$(echo "$payload" | bash "$HOOK" 2>/dev/null)
echo "$output" | grep -q '"additionalContext"' && echo "PASS" || echo "FAIL"
```

**Application gotchas**

- The JSON key must be exactly `"additionalContext"` (camelCase, no spaces). The Claude Code harness rejects other keys silently.
- Do not emit additionalContext to stderr; it will not be injected. Only stdout is read by the harness.
- For budget-gate blocking (exit 2), the harness reads stderr for the block message. AdditionalContext (stdout) is only for non-blocking guidance.

---

## Concept: hooks.json wiring (PreToolUse and PostToolUse entries)

**Closest analog:** `hooks/hooks.json` current PreToolUse Write|Edit entry

**Why this analog:** It is the exact file that must be extended and shows the required JSON structure for adding new PreToolUse and PostToolUse entries.

**Core pattern**

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/restrict-agent-paths.sh" }]
      }
    ]
  }
}
```

**Error handling**

- `hooks.json` is a pure data file; no runtime error handling applies.
- Malformed JSON causes the CC harness to silently skip all hooks.

**Test analog**

```bash
jq '.hooks.PreToolUse | map(select(.matcher == "Agent")) | length' hooks/hooks.json
# must return 1
```

**Application gotchas**

- The `matcher` field is a regex, not a glob. `Bash|Edit|Write` is a valid regex alternation.
- Each hook entry in the `hooks` array must have both `"type": "command"` and `"command"`.
- Adding a new top-level event key (e.g., `PostToolUse`) requires it to be a JSON array, not a single object.

---

## Concept: Bash script JSON parsing with jq and exit-code comparison

**Closest analog:** `lib/feature-write.sh:22-56` (jq parsing and path validation)

**Why this analog:** It shows the project-canonical pattern for jq-based JSON reading: pipe stdin through `jq`, capture stdout, guard with `|| true` or explicit error exit, and validate result before use.

**Core pattern**

```bash
# Parse a field from JSON stdin (fail-open pattern)
FIELD=$(printf '%s' "$INPUT" | jq -r '.some_field // empty' 2>/dev/null) || FIELD=""

# Numeric comparison via awk (float-safe)
result=$(awk -v a="$CURRENT" -v b="$MAX" 'BEGIN { print (a+0 >= b+0) ? "yes" : "no" }')
```

**Error handling**

```bash
# jq parse failure produces empty FIELD, not an error exit
FIELD=$(printf '%s' "$INPUT" | jq -r '.field // empty' 2>/dev/null) || FIELD=""
[[ -z "$FIELD" ]] && exit 0   # fail-open: unknown value -> allow
```

**Test analog**

```bash
# from tests/lib/feature-write.test.sh: check() helper pattern
check() {
  local name="$1" expected_exit="$2"; shift 2
  local actual_exit=0
  "$@" >/dev/null 2>&1 || actual_exit=$?
  if [[ "$actual_exit" -eq "$expected_exit" ]]; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name (expected $expected_exit, got $actual_exit)"; ((FAIL++)) || true
  fi
}
```

**Application gotchas**

- Float comparisons must use `awk` or `python3 -c`; bash arithmetic `(( ))` is integer-only and silently truncates decimal cost values.
- `jq -r '.field // empty'` returns an empty string (not the literal "null") when the field is absent -- use `[[ -z "$VAR" ]]` to detect absence, not `[[ "$VAR" == "null" ]]`.

---

## Concept: Skill markdown procedure amendment (adding a gate step)

**Closest analog:** `skills/plan/SKILL.md` Step 5 (commit gate) and `skills/execute/SKILL.md` Step 10 (phase exit)

**Why this analog:** Both files show the existing prose-step structure that must be amended to insert the decision-coverage gate (before Step 5 commit) and the plan-adherence gate (before Step 10 exit). The amendment pattern is `Edit` with precise surgical insertion rather than a full rewrite.

**Core pattern**

```markdown
### Step 5 - Commit PLAN.md and update feature.json

Before committing, run the decision coverage gate:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/lib/decision-coverage.sh" \
  "{spec_path}" "docs/loop-spec/features/{slug}/PLAN.md"
exit_code=$?
```
- If exit 0: proceed to commit.
- If exit 1 (uncovered decisions): on quality/balanced tiers, re-dispatch planner with gap list. On quick tier, log warning and proceed.
```

**Error handling**

- The gate script exits 0 (pass), 1 (coverage gap), or 0 (no `<decisions>` block found -- gate skipped).
- The skill markdown describes the branching logic; it does not execute bash directly.

**Application gotchas**

- Do not restructure Steps 1-4 or 6+ when inserting the gate. Surgical Edit only.
- The spec-writer update (requiring `<decisions>` block) is a separate file from the plan skill; do not conflate them in a single task.

---

## Concept: Bash lib helper with stdin-based PLAN.md parsing and JSON output

**Closest analog:** `lib/gsd-ingest.sh:1-40` (stdin-based parsing and structured output)

**Why this analog:** `gsd-ingest.sh` shows the project pattern for a lib helper that reads file contents (via argument path or stdin), applies regex extraction, and emits structured text output (here `INGESTED`/`SKIPPED`/`NONE`). `lib/decision-coverage.sh` and `lib/plan-adherence.sh` follow this same pattern but emit JSON.

**Core pattern**

```bash
#!/usr/bin/env bash
set -euo pipefail

SPEC_PATH="$1"
PLAN_PATH="$2"

# Extract <decisions> block
decisions=$(awk '/<decisions>/,/<\/decisions>/' "$SPEC_PATH" \
  | grep -v '<decisions>\|</decisions>' \
  | grep -v '^[[:space:]]*$' \
  | sed 's/^[[:space:]]*//')

# Emit JSON result
printf '{"plan_task_ids":[%s],"gap_message":%s}\n' \
  "$(echo "$TASK_IDS" | jq -R . | paste -sd,)" \
  "$([ -z "$GAP" ] && echo 'null' || printf '"%s"' "$GAP")"
```

**Error handling**

```bash
# Missing file: exit 0 with skip indicator
[[ -f "$SPEC_PATH" ]] || { echo '{"skipped":true}'; exit 0; }
```

**Test analog**

```bash
# from tests/lib/gsd-ingest.test.sh: check() + process substitution
check "decision-coverage: all covered" 0 \
  "bash lib/decision-coverage.sh \
    <(printf '<decisions>\n- Decision: use bash\n</decisions>') \
    <(printf '### task-001: use bash in this task')"
```

**Application gotchas**

- Process substitution (`<(...)`) works in bash but not in sh. The shebang must be `#!/usr/bin/env bash`.
- `awk '/<decisions>/,/<\/decisions>/'` includes the delimiter lines; pipe through `grep -v` to strip them.
- The PLAN.md regex `^### task-\d+:` uses `\d` which is a PCRE extension; use `[0-9]` for POSIX `grep -E` compatibility.

---

## Concepts with no clear analog

- `lib/detect-test-cmd.sh` -- no existing script probes for Makefile/package.json/Cargo.toml/pyproject.toml/go.mod to auto-detect a test command. This is net-new logic. The closest is `gsd-ingest.sh`'s file-existence probe pattern (`[[ -f "$path" ]] && ...`), but the multi-format probe loop is novel.

- `docs/loop-spec/planner-antipatterns.md` -- there is no existing reference doc of this type in the codebase. Structure it after `docs/design.md` (plain markdown, no frontmatter, developer-for-developer tone per CLAUDE.md).

## Open questions for the planner

- The SPEC says `lib/plan-adherence.sh` compares plan task IDs against harness `TaskList({status: "completed"})` subjects. The lead invokes this before Step 10 exits, but the lead has no file to run -- the comparison logic is described in prose in `skills/execute/SKILL.md`. Assumption: `plan-adherence.sh` emits only the JSON object (task IDs + gap message); the lead reads stdout and does the comparison inline. The script is a parser, not a comparator.
