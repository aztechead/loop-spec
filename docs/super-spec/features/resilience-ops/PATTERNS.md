# PATTERNS.md - resilience-ops

> Produced by `super-spec-pattern-mapper`. Read by `super-spec-planner` before drafting tasks.
> One section per **concept** the upcoming feature will need. Concepts are system-design nouns/verbs, not file paths.

## Codebase context consulted

- `docs/super-spec/codebase/TECH.md`
- `docs/super-spec/codebase/ARCH.md`
- `docs/super-spec/codebase/QUALITY.md`
- `docs/super-spec/codebase/CONCERNS.md`
- `docs/super-spec/codebase/DOMAIN.md`

---

## Concept: Kill-switch + fail-open hook

**Closest analog:** `hooks/team/stop-deflection-guard.sh:27-43`

**Why this analog (one line):** Every new hook in this feature needs the same two-line kill switch and `trap 'exit 0' ERR` fail-open pattern already established in existing hooks.

**Core pattern**

```bash
# Kill switch.
if [[ "${SUPER_SPEC_DEFLECTION_GUARD:-1}" == "0" ]]; then
  exit 0
fi

# Fail-open: any unexpected error must not block the session.
trap 'exit 0' ERR
```

**Error handling**

```bash
# All parse/IO errors default to allow.
trap 'exit 0' ERR
```

**Test analog**

```bash
# from hooks/team/teammate-idle.test.sh
check() {
  local name="$1"
  local expected_exit="$2"
  local stderr_pattern="$3"
  shift 3
  local actual_exit=0
  local actual_stderr
  actual_stderr=$(env "$@" bash "$HOOK" 2>&1 >/dev/null) || actual_exit=$?
  if [[ "$actual_exit" -ne "$expected_exit" ]]; then
    echo "FAIL: $name (expected exit $expected_exit, got $actual_exit)"
    ((FAIL++)) || true
    return
  fi
  echo "PASS: $name"
  ((PASS++)) || true
}
```

**Application gotchas**

- Each new hook's kill switch env var MUST follow the naming pattern `SUPER_SPEC_<HOOKNAME>=0` (not `off` as in the octopus reference), to match the existing project's pattern (e.g., `SUPER_SPEC_DEFLECTION_GUARD=0`).
- Do NOT use the octopus `_octo_hook_exit` EXIT trap pattern; the project uses `trap 'exit 0' ERR` (ERR, not EXIT).

---

## Concept: additionalContext injection from hook

**Closest analog:** `hooks/team/strategy-rotation.sh:135-155`

**Why this analog (one line):** Shows the exact JSON shape needed to inject `additionalContext` as hook output rather than blocking (exit 0 + stdout JSON).

**Core pattern**

```bash
printf '{"additionalContext":"%s"}\n' "$MSG"
```

**Error handling**

```bash
# Always exit 0 after emitting; never block on advisory hooks.
exit 0
```

**Test analog**

```bash
# Capture stdout and assert JSON shape
actual_stdout=$(echo "$INPUT" | bash "$HOOK")
# Assert contains additionalContext key
echo "$actual_stdout" | grep -q "additionalContext"
```

**Application gotchas**

- The `additionalContext` value must be a single JSON string; embed newlines as spaces or `\n` escaped. The reference uses `printf '...' "$MSG"` which handles this correctly.
- For SessionStart hooks the wrapper key is `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"..."}}` (octopus discipline-inject.sh:44), not the bare `{"additionalContext":"..."}` used by PostToolUse hooks. Verify which event each hook fires on before choosing the envelope.

---

## Concept: Per-session temp-file state (debounce / counter)

**Closest analog:** `hooks/team/strategy-rotation.sh:48-132`

**Why this analog (one line):** Uses a `${TMPDIR:-/tmp}/super-spec-failures-${SESSION}.json` file keyed by session ID to persist counter state across hook invocations without shared memory.

**Core pattern**

```bash
SESSION="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-$$}}"
STATE_FILE="${TMPDIR:-/tmp}/super-spec-failures-${SESSION}.json"

STATE="{}"
if [[ -f "$STATE_FILE" ]]; then
  STATE=$(cat "$STATE_FILE" 2>/dev/null) || STATE="{}"
  [[ -z "$STATE" ]] && STATE="{}"
fi

# Update and persist
printf '%s' "$STATE" > "$STATE_FILE" 2>/dev/null || true
```

**Error handling**

```bash
# Validate JSON; reset to {} on parse error
if ! printf '%s' "$STATE" | jq empty 2>/dev/null; then
  STATE="{}"
fi
```

**Application gotchas**

- Use `${TMPDIR:-/tmp}` not `/tmp` directly (sandbox constraint).
- The debounce count file for the output-compressor should use a simple integer file (`echo "$count" > "$DEBOUNCE_FILE"`) rather than a JSON file, matching the octopus output-compressor reference, not the strategy-rotation JSON pattern -- the two have different state shapes.

---

## Concept: JSONL append with FIFO cap

**Closest analog:** `hooks/team/stop-revalidate-user-gates.sh` (python3 JSONL parsing inline) + `/Users/cbobrowitz/Projects/_reference/claude-octopus/hooks/session-end.sh:182-189`

**Why this analog (one line):** Octopus session-end shows the FIFO prune pattern (find + xargs ls -t + tail + xargs rm -f) for capping a file at N entries; the project uses python3 for JSONL parsing inline.

**Core pattern**

```bash
# Append JSONL line
printf '%s\n' "$JSON_LINE" >> "$LEARNINGS_FILE" 2>/dev/null || true

# FIFO cap: keep last 50 lines (oldest dropped)
LINE_COUNT=$(wc -l < "$LEARNINGS_FILE" 2>/dev/null || echo 0)
if [[ "$LINE_COUNT" -gt 50 ]]; then
  TMPFILE=$(mktemp)
  tail -n 50 "$LEARNINGS_FILE" > "$TMPFILE"
  mv "$TMPFILE" "$LEARNINGS_FILE"
fi
```

**Error handling**

```bash
# Wrap all IO in || true to ensure fail-open
printf '%s\n' "$JSON_LINE" >> "$LEARNINGS_FILE" 2>/dev/null || true
```

**Application gotchas**

- The SPEC says cap at 50 JSONL entries, not 50 lines as in the octopus markdown format; use `wc -l` on the `.jsonl` file directly since each line is one record.
- Do NOT use `find ... | xargs ls -t | tail | xargs rm` (octopus pattern); for JSONL the `tail -n 50` rewrite approach is cleaner and avoids xargs on Windows-incompatible paths.

---

## Concept: Bash remediation loop with completion signal

**Closest analog:** `/Users/cbobrowitz/Projects/_reference/ralph/ralph.sh:84-108`

**Why this analog (one line):** Ralph's `for i in seq 1 $MAX_ITERATIONS` loop with `grep -q "<promise>COMPLETE</promise>"` is the exact pattern the SPEC mandates for lib/ralph-remediation.sh.

**Core pattern**

```bash
MAX_ITERATIONS=5
for i in $(seq 1 $MAX_ITERATIONS); do
  OUTPUT=$(claude --dangerously-skip-permissions --print < "$PROMPT_FILE" 2>&1) || true

  if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
    echo "Completed at iteration $i"
    exit 0
  fi
done

echo "Reached max iterations ($MAX_ITERATIONS) without completing."
exit 1
```

**Error handling**

```bash
# Capture output before checking -- || true prevents set -e from aborting on non-zero exit
OUTPUT=$(claude ... 2>&1) || true
```

**Application gotchas**

- Ralph uses `sleep 2` between iterations; the SPEC does not require a sleep and the project's CLAUDE.md warns against unnecessary sleeps. Omit the sleep.
- Ralph reads a static `prompt.md` file; the super-spec adapter must dynamically build the prompt from the remediation task object each iteration.
- Ralph uses `--dangerously-skip-permissions`; the lib/ralph-remediation.sh wrapper MUST use the `Agent(...)` harness call (dispatched from within a skill, not a raw `claude` CLI invocation).

---

## Concept: Atomic write of structured state file

**Closest analog:** `lib/feature-write.sh:77-91`

**Why this analog (one line):** Canonical project pattern for writing state files: write to `.tmp`, `sync`, rotate `.bak`, rename.

**Core pattern**

```bash
tmp="$feature_dir/feature.json.tmp"
final="$feature_dir/feature.json"
bak="$feature_dir/feature.json.bak"

{
  printf '%s\n' "$feature_json" > "$tmp"
  sync
  if [[ -f "$final" ]]; then
    mv "$final" "$bak"
  fi
  mv "$tmp" "$final"
} || {
  echo "feature-write: io failure" >&2
  exit 2
}
```

**Application gotchas**

- HANDOFF.json and learnings.jsonl do NOT need the full atomic-write ceremony from feature-write.sh. HANDOFF.json is a diagnostic artifact (loss is recoverable); learnings.jsonl appends atomically via `>>` which is sufficient. Use `printf '%s\n' "$JSON" > "$FILE"` for HANDOFF.json.
- Do NOT use `lib/feature-write.sh` for the new artifacts; it is scoped to `feature.json` only.

---

## Concept: Python3 inline JSON parsing in bash hook

**Closest analog:** `hooks/team/task-completed.sh:39-47`

**Why this analog (one line):** The canonical project pattern for parsing JSON in hooks: pass the file path as `sys.argv[1]` to avoid interpolation issues.

**Core pattern**

```bash
CURRENT_PHASE=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(d.get('currentPhase', ''))
except Exception:
    print('')
" "$FEATURE_JSON")
```

**Error handling**

```bash
# Broad except: print empty string and continue
except Exception:
    print('')
```

**Application gotchas**

- Do NOT interpolate JSON strings directly into the python3 `-c` string (shell injection risk flagged in CONCERNS.md). Pass file paths as `sys.argv[1]`, or read from stdin via `printf '%s' "$VAR" | python3 -c "..."`.
- Hooks that parse hook payload JSON (from stdin) should use `INPUT=$(cat); printf '%s' "$INPUT" | python3 -c "import json, sys; d = json.load(sys.stdin); ..."`.

---

## Concept: Compound task detection heuristics (UserPromptSubmit)

**Closest analog:** `/Users/cbobrowitz/Projects/_reference/claude-octopus/hooks/done-criteria.sh:53-71`

**Why this analog (one line):** The three heuristics (numbered list, multi-verb conjunction, bullet list count) are directly specified by the SPEC and implemented in the octopus reference.

**Core pattern**

```bash
compound=false

# Pattern 1: Numbered lists
if printf '%s' "$prompt" | grep -qE '(^|[[:space:]])[0-9]+[.)][[:space:]].*[0-9]+[.)][[:space:]]'; then
    compound=true
fi

# Pattern 2: Multiple action verbs connected by conjunctions
verb_pattern='(add|create|fix|update|implement|remove|delete|change|modify|...)'
if printf '%s' "$prompt" | grep -qiE "${verb_pattern}.*(and|then|also).*${verb_pattern}"; then
    compound=true
fi

# Pattern 3: Bullet lists (2+ bullets)
bullet_count=$(printf '%s' "$prompt" | grep -cE '(^|\\n)[[:space:]]*[-*][[:space:]]' || echo "0")
if [[ "$bullet_count" -ge 2 ]]; then
    compound=true
fi
```

**Application gotchas**

- Strip the octopus emoji from the injected directive; the project CLAUDE.md prohibits emojis in output.
- The kill switch variable must be `SUPER_SPEC_DONE_CRITERIA=0` (not `OCTO_DONE_CRITERIA=off`).

---

## Concept: Conf-file-driven feature toggle (discipline mode)

**Closest analog:** `/Users/cbobrowitz/Projects/_reference/claude-octopus/hooks/discipline-inject.sh:14-21`

**Why this analog (one line):** Reads a local conf file to decide whether to inject a directive, matching the SPEC's `.super-spec/discipline.conf` with `ENABLED=1`.

**Core pattern**

```bash
DISCIPLINE_CONF=".super-spec/discipline.conf"

if [[ ! -f "$DISCIPLINE_CONF" ]] || ! grep -q "ENABLED=1" "$DISCIPLINE_CONF" 2>/dev/null; then
    echo '{}'
    exit 0
fi
```

**Application gotchas**

- The octopus conf file lives in `${HOME}/.claude-octopus/config/discipline.conf`; the SPEC requires it at `.super-spec/discipline.conf` (project-relative, not global). Use `CLAUDE_PROJECT_DIR` or CWD-relative path.
- The octopus pattern checks `OCTOPUS_DISCIPLINE=on`; the SPEC requires `ENABLED=1`. Do not carry over the octopus key name.

---

## Concepts with no clear analog

- `lib/pause-snapshot.sh` -- HANDOFF.json + .continue-here.md dual-artifact generation on `/super-spec:pause`. No existing pause/snapshot lib in the project. The feature-write.sh atomic write pattern applies to HANDOFF.json; the .continue-here.md format (severity tags: `blocking`, `advisory`) has no prior implementation.
- `skills/forensics/SKILL.md` -- read-only 7-pattern anomaly diagnostic. The VERIFY marker scan (`git diff --diff-filter=ACMR ... | xargs grep`) is an analogous read-only git scan, but no structured report writer or multi-pattern probe exists.
- `lib/regression-scan.sh` -- cross-feature test suite runner. Reads VERIFICATION.md files to extract test commands; no prior cross-feature test orchestration in the codebase.
- `lib/checkpoint.sh` -- git tag management for checkpoint/rollback. `lib/git-ops.sh` has `current-sha` and `slugify` helpers but no tag creation or `git checkout TAG -- .` rollback.
- `skills/rollback/SKILL.md`, `skills/pause/SKILL.md`, `skills/discipline/SKILL.md` -- new skills with no direct skill-level analog (the existing skill structure in `skills/{name}/SKILL.md` is the structural analog).
