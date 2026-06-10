# Cycle resume + escalation (reference)

Reference procedures the `loop-spec:cycle` skill follows. Step 1 (Resume detection) contains the inline fast-path; this file is the full algorithm and the pause/escalation handling.

## Resume strategy

The full resume algorithm (used at Step 1 and when the user selects a feature to resume):

### 1. Enumerate feature worktrees (schemaVersion 6+)

Run:
```bash
bash lib/git-ops.sh list-feature-worktrees
```
This prints one line per worktree under `.claude/worktrees/`: `<path>\t<branch>`. For each line, read `<path>/.loop-spec/features/*/feature.json` to discover in-progress features living in their own worktree.

Features found here are **worktree-mode** (schemaVersion 6). They are collected alongside any legacy candidates (see step 2 below) into a single candidate list.

### 2. Enumerate legacy feature.json files (schemaVersion 5 or earlier)

Read `.loop-spec/features/*/feature.json` from the **main checkout**. A feature is **legacy** if:
- `schemaVersion` is absent or <= 5, OR
- `worktreePath` is absent or empty.

Legacy features resume **in-place in the main checkout** exactly as before. No worktree is entered. Document this to the user when presenting the selection list (e.g., append `"(in-place)"` to the label).

### 3. Filter candidates

For each candidate (worktree or legacy):

1. **Load feature.json.** On parse error, try `feature.json.bak`. On both failing, skip.
2. **Skip completed features.** If `currentPhase == "completed"`, skip.
3. **Probe team liveness.** If `feature.json.currentTeamName` is non-null:
   - Call `TaskList({team: currentTeamName})`.
   - If `TaskList` succeeds (no error): the team is live (orphaned). Present the orphan-cleanup message:
     ```
     Previous team {currentTeamName} for feature {slug} was orphaned and is still live in the harness.
     Run TeamDelete for team {currentTeamName} (e.g., via the harness CLI or by re-invoking cycle in cleanup mode), then restart cycle to resume feature {slug}.
     ```
     Add to the "needs cleanup" sub-list. Do NOT offer resume for this feature.
   - If `TaskList` errors (team not found): the prior team is gone. Print `"feature {slug} had stale team reference {currentTeamName}; cleared and ready to resume"`. Clear `currentTeamName` in `feature.json`. The feature is now resumable.
4. **Staleness check.** If `currentTeamName == null` AND `(now - updatedAt) >= stalenessHours * 3600`: skip (too stale).

### 4. Present resume options

The resume option label is: `"Resume {slug} - phase {currentPhase} (last updated {ago})"`. Append:
- `" (in-place)"` for legacy features.
- `" (worktree: {worktreePath})"` for schemaVersion 6 features.
- `" (prior team {oldName} was stale and cleared)"` if a stale team was cleared.

### 5. On resume selection

**Worktree-mode features (schemaVersion 6, worktreePath present):**

First confirm the worktree still exists on disk before entering it. Step 1 already ran `git-ops.sh list-feature-worktrees`; the chosen feature's `worktreePath` MUST appear in that listing. If it does NOT (the directory was deleted or `git worktree prune`d), do not call `EnterWorktree` (it would error). Instead warn the user and offer to recreate it from the recorded base:
```
# recovery: branch feat/{slug} may still exist; recreate the worktree dir
git worktree add "{feature.worktreePath}" "{feature.branch}"   # if branch exists
# else recreate branch + worktree from baseSha:
bash "${CLAUDE_SKILL_DIR}/../../lib/git-ops.sh" create-feature-worktree "{slug}" "{feature.baseSha}"
```
Once the worktree is confirmed present:
```
EnterWorktree({ path: feature.worktreePath })
```
Call this BEFORE routing to the current phase. All subsequent phase work runs inside the worktree with the feature branch already checked out. Subagents dispatched from phase skills must receive absolute paths (resolve via `git rev-parse --show-toplevel` from inside the worktree).

**Legacy features (schemaVersion <= 5 or no worktreePath):**
No worktree is entered. Resume proceeds in the main checkout exactly as before.

**Both paths then:**
Load feature state into memory. Jump directly to Step 6 (phase routing) with `state = loaded feature.json`. Do not re-run Steps 2-4. The phase team is re-created fresh via `TeamCreate` (the harness does not support in-process teammate resume). If `currentGate` in `feature.json` is non-null with a non-zero round, load prior debate transcript from `.loop-spec/features/{slug}/gate-logs/` into the spawn prompt so the resumed advocate/challenger have prior context.

The `TaskList` probe is the sole mechanism for detecting live teams. The harness exposes no `TeamList` tool, and the probe is non-destructive (it reads only, cannot create or delete teams).

## On phase pause / escalation

If a phase pauses + escalates (budget exhausted, NEEDS_CONTEXT, etc.):

1. Call `TeamDelete({name: feature_json.currentTeamName})` (if `currentTeamName` is non-null) before returning control to the user.
2. Clear `currentTeamName` and `currentTeammates` in `feature.json` via `lib/feature-write.sh`.
3. Print escalation reason.
4. Read `retryBudget` from `feature.json` (`.loop-spec/features/{slug}/feature.json`) and show `gateHistory` tail (last 3 attempts from `feature.json.gateHistory`).
5. Show partial artifacts (spec/plan/execution/verification paths from `feature.json.artifacts`).
6. **Worktree-mode only (schemaVersion 6):** after snapshotting (step 5 above), call `ExitWorktree({action: "keep"})` to return the session to the main checkout. The worktree and branch are preserved on disk; the next resume will re-enter via `EnterWorktree`. Legacy (in-place) features skip this step.
7. Return control to user.

User options:
- Edit artifacts manually + re-invoke cycle (resume continues)
- Reset retry counters: edit `feature.json` directly (`globalUsed = 0`, `perPhaseUsed.{phase} = 0`); resume
- Rollback: the `loop-spec:rollback` skill operates inside the worktree (cwd is already the worktree when the session is active inside it). On pause the session has exited the worktree, so re-enter via `EnterWorktree({path: feature.worktreePath})` first, then invoke rollback.
- Abort: delete `.loop-spec/features/{slug}/`; new branch state up to user
