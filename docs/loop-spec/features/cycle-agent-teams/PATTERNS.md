# PATTERNS.md - cycle-agent-teams

> Produced by `loop-spec-pattern-mapper`. Read by `loop-spec-planner` before drafting tasks.
> One section per **concept** the upcoming feature will need. Concepts are system-design nouns/verbs, not file paths.

## Codebase context consulted

- `docs/loop-spec/codebase/TECH.md`
- `docs/loop-spec/codebase/ARCH.md`
- `docs/loop-spec/codebase/QUALITY.md`
- `docs/loop-spec/codebase/CONCERNS.md`
- `docs/loop-spec/codebase/DOMAIN.md`

---

## Concept: Atomic state file write with .bak rotation

**Closest analog:** `lib/state-write.sh:1-53` (the entire file)

**Second analog:** `skills/cycle/SKILL.md:158-200` (the `jq -n` block that constructs and writes initial `state.json`)

**Why this analog:** `lib/state-write.sh` IS the exact pattern to clone for `lib/feature-write.sh`. The new file changes two things only: the file name (`feature.json` instead of `state.json`) and the target directory (`.loop-spec/features/{slug}/` stays the same). The write protocol -- validate JSON, write to `.tmp`, `sync`, rotate `.bak`, rename -- is unchanged.

**Core pattern**

```bash
#!/usr/bin/env bash
# lib/state-write.sh:17-53
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: state-write.sh <feature_dir> <state_json_string>" >&2
  exit 1
fi

feature_dir="$1"
state_json="$2"

if [[ ! -d "$feature_dir" ]]; then
  echo "state-write: feature_dir does not exist: $feature_dir" >&2
  exit 1
fi

if ! printf '%s' "$state_json" | jq -e . >/dev/null 2>&1; then
  echo "state-write: invalid JSON input" >&2
  exit 1
fi

tmp="$feature_dir/state.json.tmp"
final="$feature_dir/state.json"
bak="$feature_dir/state.json.bak"

{
  printf '%s\n' "$state_json" > "$tmp"
  sync
  if [[ -f "$final" ]]; then
    mv "$final" "$bak"
  fi
  mv "$tmp" "$final"
} || {
  echo "state-write: io failure" >&2
  exit 2
}
```

**Error handling**

```bash
# Exit codes mirror state-write.sh exactly:
#   0 = success
#   1 = bad invocation (wrong arg count, missing dir, invalid JSON)
#   2 = io failure during write/rotate
# Callers check exit code; no try/catch needed in bash with set -euo pipefail.
```

**Test analog**

```bash
# tests/lib/state-write.test.sh -- 8 test cases covering:
# - rejects missing dir
# - rejects invalid JSON
# - writes valid JSON
# - rotates .bak on second write
# - produces .bak on parse
```

**Application gotchas**

- The new `lib/feature-write.sh` changes only the `tmp`/`final`/`bak` variable names from `state.json*` to `feature.json*`. Do not rename the script's internal logic or change the `sync` call to `fsync` -- CONCERNS.md flags the `sync` vs `fsync` mismatch but it is known-accepted.
- The `jq -e .` validation must remain; it is the only guard against writing corrupt JSON that would break resume detection.
- Do not add `schemaVersion` validation inside the writer; that is the caller's responsibility (as it is today).

---

## Concept: Phase skill structure (frontmatter + Procedure steps)

**Closest analog:** `skills/discuss/SKILL.md:1-127` (full DISCUSS phase skill)

**Second analog:** `skills/plan/SKILL.md:1-135` (PLAN phase skill)

**Why this analog:** Every phase skill in loop-spec follows the identical markdown structure: YAML frontmatter (`name`, `description`), an `## Inputs` section, a `## Procedure` section with numbered steps, a `## Resume` section at the end. The team-based rewrite must emit the same shape per SPEC.md CONSTRAINTS: "Skills are code."

**Core pattern**

```markdown
---
name: discuss
description: DISCUSS phase - ...
---

# DISCUSS Phase

You are the DISCUSS phase orchestrator. Invoked by `loop-spec:cycle` after ...

## Inputs (from cycle skill via state.json)

- `slug`, `tier`, `execStyle`, `feature_title`
- `state_path`: `.loop-spec/features/{slug}/state.json`

## Procedure

### Step 1 - ...

### Step 2 - ...

## Resume

If invoked with `currentPhase == "discuss"` already in state.json:
- Read state, see what subphase: ...
```

**Error handling**

```markdown
# Phase escalation pattern (from skills/cycle/SKILL.md:284-296):
# On gate failure exceeding budget:
#   Print escalation reason
#   Show state.gateHistory tail (last 3 attempts)
#   Show partial artifacts (spec/plan/execution/verification paths)
#   Return control to user
```

**Test analog**

```bash
# smoke.sh covers each phase skill end-to-end.
# validate-agents.sh covers agent frontmatter only; skill bodies have no unit tests.
# Per QUALITY.md: skill SKILL.md files are prose-format prompts -- not unit-testable.
```

**Application gotchas**

- The rewritten phase skills must keep the same `name:` and `description:` frontmatter values so `Skill(loop-spec:{name})` invocations in `skills/cycle/SKILL.md` continue to resolve. Do not rename skills.
- The `## Resume` section MUST be updated for each phase: v1 read `state.json` tasks; v2 reads `feature.json` + calls `TaskList({team: currentTeamName})` to probe liveness. The resume logic is structurally different even though the section heading stays.
- Do NOT add `skills:` or `mcpServers:` keys to frontmatter -- those are no-ops when agents run as teammates and `tests/validate-agents.sh` will enforce this after the new frontmatter rule is added.

---

## Concept: One-shot Agent dispatch (the pattern being REPLACED)

**Closest analog:** `skills/discuss/SKILL.md:32-46` (Agent dispatch of spec-writer)

**Second analog:** `skills/execute/SKILL.md:72-87` (parallel implementer dispatch)

**Why this analog:** The current dispatch shape -- `Agent({subagent_type, model, description, prompt})` -- is the pattern EVERY phase uses today. The SPEC replaces this with `TeamCreate` + `SendMessage` for teammate communication, but the agent definition files (`agents/loop-spec-*.md`) remain the behavioral specification for what each role does. The pattern-mapper documents it so the planner knows what is being replaced and where.

**Core pattern**

```
# Current one-shot pattern (skills/discuss/SKILL.md:32-46):
Agent({
  subagent_type: "loop-spec-spec-writer",
  model: model,
  prompt: """
    slug: {slug}
    feature_title: {title}
    tier: {tier}
    conversation_transcript: read .loop-spec/features/{slug}/discuss-transcript.md
    project_context_summary: {brief read of repo state}

    Produce SPEC.md per your role definition.
  """
})

# Current parallel dispatch pattern (skills/verify/SKILL.md:41-55):
Parallel:
  Agent({subagent_type: "loop-spec-verifier", model: ..., prompt: ...})
  Agent({subagent_type: "loop-spec-code-reviewer", model: ..., prompt: ...})
```

**Error handling**

```
# On NEEDS_CONTEXT (from skills/plan/SKILL.md:62):
# "gather and re-dispatch (fresh Agent({subagent_type: ...}) call with
#  extra context appended -- never SendMessage)"
#
# On BLOCKED: pause + escalate to user via AskUserQuestion.
```

**Application gotchas**

- The replacement is `TeamCreate({name, teammates: [{name, agent, model, prompt}]})`. The `agent` field maps to the existing `subagent_type` value (e.g., `"loop-spec-spec-writer"`). Model and prompt move inside the teammate spec rather than the outer Agent call.
- `SendMessage({to: "<name>", body: "..."})` replaces "re-dispatch with fix-list in prompt" for DISCUSS and PLAN critique loops. But EXECUTE implementer re-dispatch on `needs_rework` is NOT a new SendMessage -- it is the reviewer calling `TaskUpdate` to set status `needs_rework` and then any implementer self-claiming the task via `TaskUpdate` again.
- The explicit `description:` field on Agent calls (to avoid safety-filter trips on charged language) has no direct equivalent in TeamCreate spawn prompts. If the harness applies the same filter at TeamCreate time, the spawn prompt itself must avoid charged language in its opening line.
- The tool whitelist in `skills/cycle/SKILL.md:12-33` explicitly bans `TeamCreate`, `TeamDelete`, `SendMessage`, `TaskCreate`, `TaskUpdate`, `TaskList`, `TaskGet`. This section must be rewritten to INVERT the ban -- adding these tools and removing `Agent` from the allowed list (or documenting that `Agent` is only used for the startup health-check model probes).

---

## Concept: Hook registration and PreToolUse enforcement

**Closest analog:** `hooks/hooks.json:1-15` (full file)

**Second analog:** `hooks/restrict-agent-paths.sh:1-108` (full file -- the only existing hook script)

**Why this analog:** `hooks/hooks.json` is the single source of truth for hook registration. The new `TeammateIdle`, `TaskCreated`, and `TaskCompleted` entries follow the identical JSON structure. `restrict-agent-paths.sh` is the template for the three new hook scripts under `hooks/team/`.

**Core pattern**

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/restrict-agent-paths.sh"
          }
        ]
      }
    ]
  }
}
```

**New entries to add (from SPEC.md):**

```json
{
  "TeammateIdle":  [{"command": "bash hooks/team/teammate-idle.sh"}],
  "TaskCreated":   [{"command": "bash hooks/team/task-created.sh"}],
  "TaskCompleted": [{"command": "bash hooks/team/task-completed.sh"}]
}
```

**Error handling**

```bash
# restrict-agent-paths.sh exit-code contract (lines 1-9):
# exit 0 = allow
# exit 2 = block (stderr shown to user)
#
# New hook scripts should follow the same contract.
# TeammateIdle nudge hook: exit 0 always (nudge is advisory, never blocks).
# TaskCreated validator: exit 2 if metadata shape invalid.
# TaskCompleted quality gate: exit 2 to re-open task with needs_rework status.
```

**Test analog**

```bash
# hooks/restrict-agent-paths.test.sh -- 12 cases, the full unit test template:
# check() helper compares expected vs actual, accumulates PASS/FAIL, exits 1 on any failure.
# New hook scripts under hooks/team/ should get sibling .test.sh files using the same check() pattern.
```

**Application gotchas**

- CONCERNS.md flags two risks in `restrict-agent-paths.sh`: (1) `TRANSCRIPT_PATH` injection from untrusted input (medium), and (2) the final `*)` case allows any unknown subagent_type unrestricted (low). The new hook scripts read `feature.json` to determine current phase -- they must handle missing/corrupt `feature.json` gracefully (default to phase-agnostic behavior, never crash with a non-zero exit that would block the tool call unintentionally).
- The `${CLAUDE_PLUGIN_ROOT}` env var is used for absolute path in the existing hook command. New hooks under `hooks/team/` should use the same `${CLAUDE_PLUGIN_ROOT}/hooks/team/` prefix for consistency, not a relative `bash hooks/team/...` path (even though the SPEC's JSON snippet uses the relative form -- prefer the absolute form to match the existing entry).
- Hook scripts run with `set -euo pipefail` by convention. Any `jq` or `python3` call that fails must not propagate as a blocking exit 2 unless the hook explicitly intends to block.

---

## Concept: Agent frontmatter validation (structural check)

**Closest analog:** `tests/validate-agents.sh:1-43` (full file)

**Why this analog:** This script is the direct analog for the new frontmatter structural check the SPEC adds: detecting `skills:` or `mcpServers:` keys in any agent frontmatter. The existing script already parses frontmatter with `awk`, extracts fields with `grep`/`sed`, and fails with a descriptive message.

**Core pattern**

```bash
#!/usr/bin/env bash
# tests/validate-agents.sh:1-43
set -euo pipefail
EXPECTED=14
ALLOWED_MODELS="claude-opus-4-7 claude-sonnet-4-6 claude-haiku-4-5"
RESTRICTED_AGENTS="spec-compliance-reviewer code-reviewer advocate challenger"

count=$(ls agents/loop-spec-*.md 2>/dev/null | wc -l | tr -d ' ')
[[ "$count" == "$EXPECTED" ]] || { echo "FAIL: expected $EXPECTED agent files, found $count"; exit 1; }

for f in agents/loop-spec-*.md; do
  # Extract frontmatter block (between first two ---)
  fm=$(awk '/^---$/{c++; next} c==1{print} c==2{exit}' "$f")
  [[ -n "$fm" ]] || { echo "FAIL: $f missing frontmatter"; exit 1; }

  # name: must match filename
  fm_name=$(echo "$fm" | grep '^name:' | sed 's/^name: *//')
  [[ "$fm_name" == "$basename" ]] || { echo "FAIL: $f name '$fm_name' != filename '$basename'"; exit 1; }

  # Restricted agents must have NO Write/Edit
  role="${basename#loop-spec-}"
  if echo "$RESTRICTED_AGENTS" | grep -wq "$role"; then
    if echo "$fm" | grep -qE '^  - (Write|Edit)$'; then
      echo "FAIL: $f is restricted role but has Write/Edit in tools"
      exit 1
    fi
  fi
done
```

**New check to add (from SPEC.md):**

```bash
  # skills: and mcpServers: are inert when agent runs as a teammate -- forbid them
  if echo "$fm" | grep -qE '^(skills|mcpServers):'; then
    key=$(echo "$fm" | grep -oE '^(skills|mcpServers):' | head -1 | tr -d ':')
    echo "FAIL: $f declares ${key}: which is inert when agent runs as a teammate; remove the key"
    exit 1
  fi
```

**Error handling**

```bash
# Pattern: inline { echo "FAIL: ..."; exit 1; } after every assertion.
# No try/catch needed. set -euo pipefail catches unexpected errors.
# Script exits 0 with "All N agents validated." on full success.
```

**Test analog**

```bash
# validate-agents.sh is itself the test. It is invoked from tests/run-all.sh.
# The SPEC requires a negative test: inject `skills: [foo]` into a temp copy
# of one agent file and assert the script exits non-zero.
# Model: copy fixture agent to $TMPDIR, inject key, run script against $TMPDIR copy, assert exit 1.
```

**Application gotchas**

- `EXPECTED=14` is hard-coded. When the new feature adds agents (none are planned in this SPEC; all existing agents are reused as teammates), this count must be updated. Failing to update it causes a confusing "expected 14, found N" failure.
- The frontmatter awk extractor (`awk '/^---$/{c++; next} c==1{print} c==2{exit}'`) depends on `---` appearing as a standalone line. Any frontmatter fence that has trailing whitespace will silently not match, and `fm` will be empty, causing `FAIL: missing frontmatter`. New agent files must use bare `---` with no trailing spaces.
- CONCERNS.md flags that `ls agents/loop-spec-*.md` uses a relative path with no `cd` guard. The script must be run from repo root. The new rule inherits this fragility. The SPEC does not ask for a fix here; document the constraint in the script's usage comment.

---

## Concept: Git worktree lifecycle (create, merge, prune)

**Closest analog:** `skills/execute/SKILL.md:57-165` (Steps 2c through post-wave cleanup)

**Why this analog:** The EXECUTE rewrite keeps the raw `git worktree add` / `git merge --ff-only` / `git worktree remove` / `git branch -D` flow verbatim. The SPEC explicitly says: "Re-architecting the worktree merge model" is out of scope; `lib/git-ops.sh` stays. The worktree pattern is the unchanged substrate that self-claim parallelism runs on top of.

**Core pattern**

```bash
# skills/execute/SKILL.md:63-68 -- worktree creation
worktree_path=".loop-spec/worktrees/{slug}/task-NNN/"
worktree_branch="task/NNN-{slug}"

git worktree add -b {worktree_branch} {worktree_path} {branch}

# skills/execute/SKILL.md:140-153 -- merge (inside feature branch, not worktree)
git checkout {branch}
git merge --ff-only {task.worktree_branch}
# If non-fast-forward:
#   cd {worktree_path}; git rebase {branch}
#   if rebase fails: pause + escalate
#   cd {project root}; git merge --ff-only {task.worktree_branch}

# skills/execute/SKILL.md:160-164 -- post-task cleanup
git worktree remove {task.worktree_path}
git branch -D {task.worktree_branch}
```

**Orphan pruning pattern**

```bash
# skills/execute/SKILL.md:222-243
registered=$(git worktree list --porcelain | awk '/^worktree /{print $2}' \
  | grep -F ".loop-spec/worktrees/{slug}/")

for wt_path in $registered; do
  if [ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ]; then
    echo "WARN: orphaned worktree $wt_path has uncommitted changes - skipping prune"
    continue
  fi
  wt_branch=$(git -C "$wt_path" branch --show-current 2>/dev/null)
  if git merge-base --is-ancestor "$wt_branch" "{branch}" 2>/dev/null; then
    git worktree remove "$wt_path" --force
    git branch -D "$wt_branch" 2>/dev/null || true
    echo "Pruned orphaned worktree: $wt_path"
  fi
done
git worktree prune
```

**Error handling**

```bash
# On non-ff merge: rebase + retry. On rebase conflict: pause + escalate.
# On worktree with uncommitted changes at prune time: skip with WARN, not error.
# git branch -D uses 2>/dev/null || true so a missing branch does not abort.
```

**Test analog**

```bash
# tests/lib/git-ops.test.sh -- 10 cases for lib/git-ops.sh helpers.
# No dedicated worktree unit tests; covered only by smoke.sh end-to-end.
```

**Application gotchas**

- The SPEC replaces the wave barrier but NOT the worktree pattern. Each implementer teammate still gets its own worktree at `task/NNN-{slug}`. The difference is that worktrees are now created on self-claim (when an implementer picks up a task) rather than at wave-dispatch time. The lead must call `git worktree add` before or immediately after the implementer claims the task, then pass `worktree_path` and `worktree_branch` to the implementer via `SendMessage`.
- CONCERNS.md flags `git branch -D` in a non-recoverable position (medium risk). The merge queue serializes merges sequentially, which makes the race condition less likely than in the old parallel-wave model, but the safety note remains: check `git merge-base --is-ancestor` before `git branch -D`.
- `EnterWorktree` / `ExitWorktree` harness tools are explicitly banned (SPEC Non-goals). Use only raw git commands via `Bash`.

---

## Concept: Retry budget hierarchy and exhaustion escalation

**Closest analog:** `skills/cycle/SKILL.md:155-202` (`jq -n` block that initializes `retryBudget` in `state.json`)

**Second analog:** `skills/discuss/SKILL.md:87-96` (budget increment and cap-check logic in the reconcile step)

**Why this analog:** The retry budget structure in `feature.json` is a direct evolution of the `retryBudget` object in `state.json`. The initialization shape, the increment-and-check pattern, and the escalation response are all carried forward. Only the `executePerTask` field moves to harness task metadata.

**Core pattern**

```bash
# skills/cycle/SKILL.md:185-196 -- retryBudget initialization in jq -n block
retryBudget: {
  perGate: 3,
  perPhase: {discuss: 3, plan: 4, execute: null, verify: 4},
  executePerTask: 3,
  global: 30,
  globalUsed: 0,
  perPhaseUsed: {discuss: 0, plan: 0, execute: 0, verify: 0}
},
```

**Increment-and-check pattern**

```markdown
# skills/discuss/SKILL.md:87-96
- Increment state.retryBudget.globalUsed
- Increment state.retryBudget.perPhaseUsed.discuss
- Check budgets:
  - if globalUsed > global -> pause + escalate
  - if perPhaseUsed.discuss > perPhase.discuss -> pause + escalate
  - if attempt > perGate -> pause + escalate
- Otherwise: re-dispatch spec-writer with fix_list
```

**Error handling**

```markdown
# skills/cycle/SKILL.md:284-296 (escalation response):
# Print escalation reason
# Show state.gateHistory tail (last 3 attempts)
# Show partial artifacts (spec/plan/execution/verification paths)
# Return control to user
# User options: edit + resume, reset counters, abort
```

**Application gotchas**

- `feature.json` removes `executePerTask` from `retryBudget` (it moves to harness task metadata `retries` field). The initialization `jq -n` block in the new cycle skill must omit it. The cap check for per-task retries is now `TaskGet({taskId}).metadata.retries >= tier.execute.maxRetriesPerTask` rather than `task.retries > state.retryBudget.executePerTask`.
- `perPhase.execute: null` in `feature.json` means unlimited -- the `null` check must be explicit: `if perPhaseUsed.execute > perPhase.execute` must short-circuit to false when `perPhase.execute` is `null`. Do not compare a number to `null` as if it were 0.
- The new `perGateUsed` map (keyed by `{phase}.{gate}`) has no analog in the current `state.json`. It must be initialized as `{}` and populated on first gate failure for each gate. The planner must allocate a task for the `lib/feature-write.sh` implementation before any phase skill can use it.
- Budget writes must go through `lib/feature-write.sh` (the atomic writer), not direct in-place JSON edits. The same discipline as `lib/state-write.sh` applies.

---

## Concept: Smoke test assertion pattern

**Closest analog:** `tests/smoke.sh:33-90` (assertion block)

**Why this analog:** The smoke test is the only automated end-to-end gate for this project (QUALITY.md). Its assertion structure -- `assert_file`, inline `jq -e` checks, commit count -- is the exact template for adding the new assertions the SPEC requires (feature.json existence, `currentTeamName == null`, distinct-implementers criterion, team-creation log markers).

**Core pattern**

```bash
# tests/smoke.sh:43-51 -- assert_file helper
assert_file() {
  if [[ -f "$1" ]]; then
    echo "PASS: $1 exists"
  else
    echo "FAIL: $1 missing"
    cat smoke-output.log
    exit 1
  fi
}

# tests/smoke.sh:58-64 -- jq -e inline assertion
if jq -e '.currentPhase == "completed"' "$STATE" > /dev/null; then
  echo "PASS: state.currentPhase == completed"
else
  echo "FAIL: state.currentPhase != completed"
  cat "$STATE"
  exit 1
fi

# tests/smoke.sh:82-88 -- commit count assertion
N_COMMITS=$(git log --oneline | wc -l | tr -d ' ')
if [[ "$N_COMMITS" -ge 4 ]]; then
  echo "PASS: $N_COMMITS commits"
else
  echo "FAIL: only $N_COMMITS commits (expected >=4)"
  exit 1
fi
```

**New assertions to add (from SPEC.md success criteria):**

```bash
# feature.json replaces state.json
FSTATE=".loop-spec/features/$SLUG/feature.json"
assert_file "$FSTATE"

# schema version, phase, team cleanup
jq -e '.schemaVersion == 3' "$FSTATE"
jq -e '.currentPhase == "completed"' "$FSTATE"
jq -e '.currentTeamName == null' "$FSTATE"
jq -e '.currentTeammates == []' "$FSTATE"
jq -e '.currentGate.round == 0' "$FSTATE"

# state.json must NOT exist
if [[ -f ".loop-spec/features/$SLUG/state.json" ]]; then
  echo "FAIL: state.json still present after v3 cycle run"
  exit 1
fi

# distinct-implementers criterion (SPEC.md success criteria)
DISTINCT=$(grep -oE 'implementer-[0-9]+' smoke-output.log | sort -u | wc -l | tr -d ' ')
if [[ "$DISTINCT" -ge 2 ]]; then
  echo "PASS: $DISTINCT distinct implementers ran tasks"
else
  echo "FAIL: only $DISTINCT distinct implementer(s) ran tasks (expected >=2)"
  exit 1
fi
```

**Error handling**

```bash
# Pattern: if jq -e ... fails, print the file contents for debugging, then exit 1.
# This matches the existing style in smoke.sh:61-64.
```

**Application gotchas**

- The smoke fixture (`tests/fixtures/minimal-py/`) must be extended to >= 4 tasks with at least 2 tasks having empty `blockedBy` and no `files` overlap (to satisfy the distinct-implementers criterion). The current fixture is designed around a single-task "add subtract function" feature. This is a fixture change, not just an assertion change.
- `smoke-output.log` is the `claude --print` stdout. The `[TEAM-EXECUTE] task-NNN claimed by implementer-M` log lines the SPEC requires must be printed to stdout (not stderr) by the cycle skill so they appear in this log file.
- `LOOP_SPEC_ANSWER_TIER=quick` in the existing smoke.sh uses the quick tier (1 critique round, 2 implementers max). The distinct-implementers assertion requires >= 2 implementers. With `tier=quick` and `maxParallelImplementers=2`, having >= 2 tasks with empty `blockedBy` is sufficient -- but the fixture must guarantee this.
- The `STATE=".loop-spec/features/$SLUG/state.json"` variable and all existing assertions against it must be replaced (not supplemented) with `FSTATE` assertions. Leaving the old `assert_file "$STATE"` in place will cause the test to fail since `state.json` no longer exists.

---

## Concepts with no clear analog

- `TeamCreate / TeamDelete` -- No existing code in the codebase creates or tears down agent teams. The cycle currently bans these tools explicitly (`skills/cycle/SKILL.md:24-29`). The harness API shape must be inferred from the SPEC's description and the capability probe. Treat as novel work: the planner must write tasks that define the `TeamCreate` / `TeamDelete` call sites from SPEC.md's architecture tables alone.

- `TaskCreate / TaskUpdate / TaskList / TaskGet` -- Same as above. All four are explicitly banned in the current cycle tool whitelist. No usage analog exists anywhere in `skills/`, `lib/`, `hooks/`, or `tests/`. The harness task metadata field (`retries`, `claimedBy`, `blockedBy`, `files`, `verifyCommand`, `acceptanceCriteria`, `specPath`) is a novel schema the planner must define from the SPEC.

- `SendMessage (lead-to-teammate and teammate-to-teammate)` -- No existing usage. The current codebase has an explicit ban and a comment explaining why (`skills/discuss/SKILL.md:46`: "never use SendMessage to revive a finished one-shot subagent"). The new usage is the opposite: SendMessage to a live persistent teammate. The only transport reference is the SPEC itself. Novel work.

- `Critique debate protocol (multi-round advocate/challenger via SendMessage)` -- The current critique gate dispatches advocate and challenger as two parallel one-shot Agent calls and the lead merges findings in-memory (`skills/discuss/SKILL.md:53-96`). The new protocol is a round-structured debate with `ROUND-{N} DONE:` / `ROUND-{N} DONE-WITH-ISSUES:` signals, gate-logs written to disk, and convergence detection. The round structure and the transcript capture to `.loop-spec/features/{slug}/gate-logs/` are entirely novel; no analog exists.

- `Self-claim race serialization (implementer TaskUpdate contest)` -- The concept that two implementers atomically race to claim the same task via `TaskUpdate` and the harness serializes the winner is entirely new. The current EXECUTE dispatches implementers to pre-assigned tasks (no race). The self-claim loop pattern (query `TaskList`, filter unblocked `pending`, call `TaskUpdate` with `status: "in_progress"`, handle error-means-lost-race) has no codebase analog.

- `Merge queue (FIFO dependency-aware, replacing wave barrier)` -- The current wave barrier is "wait for all tasks in wave to reach `merging` before any merge starts" (`skills/execute/SKILL.md:133-155`). The merge queue (`feature.json.mergeQueue[]`) with dependency-aware FIFO ordering and rotate-to-back logic is a new data structure and algorithm with no existing analog.

- `Resume via live-team probe (TaskList liveness check)` -- Current resume reads `state.json` and inspects `currentPhase` (`skills/cycle/SKILL.md:63-70`). New resume calls `TaskList({team: currentTeamName})` to probe whether a prior team is still live, and branches on success vs error. This two-branch probe pattern (alive = orphan, error = safe to recreate) has no existing analog in the codebase.

- `gate-logs/ directory and per-round transcript capture` -- No existing mechanism persists advocate/challenger round outputs to disk. Currently all critique findings are in-memory and lost on crash. The `gate-logs/{gate}-round-{N}.md` files are a new artifact class with no existing write pattern to follow.

- `Harness capability probe (TeamCreate + TaskUpdate + SendMessage smoke at startup)` -- The current health-check in `skills/cycle/SKILL.md:86-110` probes model availability via 1-token Agent calls. The new capability probe creates a throwaway team, exercises TaskUpdate with `awaiting_review`, writes/reads task metadata, sends SendMessage round-trips, and validates concurrent self-claim serialization. This is an entirely new probe shape. The 1-token Agent probe is the structural ancestor but the content is novel.

---

## Open questions for the planner

- The SPEC says `lib/gsd-ingest.sh` is modified to "emit `INGESTED <DOMAIN>` lines for the lead to update `feature.json`" instead of writing `state.json`. The current `lib/gsd-ingest.sh` already emits `INGESTED`/`SKIPPED`/`NONE` lines; the caller (`skills/cycle/SKILL.md:232-249`) reads stdout and updates state. Whether `lib/gsd-ingest.sh` itself does any `state.json` writes (it does not appear to in the current source -- the state write is done by the caller) needs verification before the planner allocates a "modify gsd-ingest.sh" task. The planner should read `lib/gsd-ingest.sh` in full before sizing this task.

- The SPEC adds `.loop-spec/` to `.gitignore` but `.loop-spec/codebase/index.json` is currently NOT gitignored (it is tracked, per `skills/map-codebase/SKILL.md:84` and ARCH.md). The `.loop-spec/` gitignore entry would shadow `index.json`. The planner must decide whether to add a negation rule (`!.loop-spec/codebase/index.json`) or restructure the gitignore to use per-subdirectory entries (`.loop-spec/features/`, `.loop-spec/worktrees/`). The SPEC does not resolve this conflict explicitly.
