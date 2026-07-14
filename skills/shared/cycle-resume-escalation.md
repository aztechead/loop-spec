# Cycle resume + escalation (reference)

Reference procedures the `loop-spec:cycle` skill follows. Step 1 (Resume detection) contains the inline fast-path; this file is the full algorithm and the pause/escalation handling.

## Resume strategy

The full resume algorithm (used at Step 1 and when the user selects a feature to resume).
loop-spec is **schema-7 only**: a resumable feature is single-repo **worktree mode**
(`executionRootMode=worktree`, Claude), single-repo **in-place mode**
(`executionRootMode=in-place`, OpenCode/pi), or **workspace mode**. Any
`feature.json` with `schemaVersion != 7` is skipped with a one-line warning.

### 1. Enumerate feature worktrees (single-repo mode)

`lib/cycle-preflight.sh` runs:
```bash
bash lib/git-ops.sh list-feature-worktrees
```
This prints one line per worktree under `.claude/worktrees/`: `<absolute-path>\t<branch>`.
Preflight reads each `<path>/.loop-spec/features/*/feature.json` and returns the absolute
`featureRoot`; cycle must not rescan only the control checkout.

### 2. Enumerate workspace features

Read `.loop-spec/features/*/feature.json` from the workspace root. Features with a non-null
`workspace` block are workspace-mode (resume in place; see "Workspace features" below). Both
sources feed a single candidate list. Skip any candidate whose `schemaVersion != 7`
(`feature {slug}: unsupported schemaVersion {n} (schema 7 only); skipping`).

### 3. Filter candidates

For each candidate (worktree or workspace):

1. **Load feature.json.** On parse error, try `feature.json.bak`. On both failing, skip.
2. **Skip completed features.** If `currentPhase == "completed"`, skip.
3. **Probe team liveness.** If `feature.json.currentTeamName` is non-null:
   - **Mode guard (read `.loop-spec/runtime.json.teamsMode`).** When `teamsMode != "explicit"`
     (i.e. `implicit` or `none`), there is no cross-session team to orphan: in `implicit` mode
     named teammates are session-scoped subagents that did not survive, and in `none` mode no
     team was ever created. Skip the `TaskList` liveness probe entirely — treat the team as gone:
     clear `currentTeamName` in `feature.json`, print `"feature {slug} had stale team reference {currentTeamName}; cleared and ready to resume"`, and mark the feature resumable. Only `explicit`
     mode runs the live-orphan probe below.
   - In `explicit` teams mode only, call `TaskList({team: currentTeamName})` (modern `TaskList` takes no parameters; in `implicit`/`none` skip the probe, clear `currentTeamName`, mark resumable).
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
- `" (worktree: {worktreePath})"` for single-repo worktree features.
- `" (workspace: {N} repos)"` for workspace features.
- `" (prior team {oldName} was stale and cleared)"` if a stale team was cleared.

### 5. On resume selection

**Single-repo worktree features (worktreePath present):**

First confirm the worktree still exists on disk before entering it. Step 1 already ran `git-ops.sh list-feature-worktrees`; the chosen feature's `worktreePath` MUST appear in that listing. If it does NOT (the directory was deleted or `git worktree prune`d), do not call `EnterWorktree` (it would error). Instead warn the user and offer to recreate it from the recorded base:
```
# recovery: branch feat/{slug} may still exist; recreate the worktree dir
git worktree add "{feature.worktreePath}" "{feature.branch}"   # if branch exists
# else recreate branch + worktree from baseSha:
bash "${CLAUDE_SKILL_DIR}/../../lib/git-ops.sh" create-feature-worktree "{slug}" "{feature.baseSha}"
```
Once the worktree is confirmed present, use the absolute candidate path:
```
EnterWorktree({ path: candidate.worktreeAbs })
```
Call this BEFORE routing to the current phase. All subsequent phase work runs inside the worktree with the feature branch already checked out. Subagents dispatched from phase skills must receive absolute paths (resolve via `git rev-parse --show-toplevel` from inside the worktree).

**Workspace features (`workspace` block non-null):**
No worktree is entered. Resume proceeds in place at the workspace root (see "Workspace features" below).

**OpenCode/pi in-place features (`executionRootMode == "in-place"`):**
No worktree tool exists. Resume only when the session root equals `candidate.featureRoot`
and the checked-out branch equals `feature.branch`; otherwise print the absolute root and
ask for relaunch there. Never substitute another `git worktree add` for changing cwd.

**Both paths then:**
Load feature state into memory. Jump directly to Step 6 (phase routing) with `state = loaded feature.json`. Do not re-run Steps 2-4. The phase team is re-created fresh via `TeamCreate` (the harness does not support in-process teammate resume). If `currentGate` in `feature.json` is non-null with a non-zero round, load prior debate transcript from `.loop-spec/features/{slug}/gate-logs/` into the spawn prompt so the resumed advocate/challenger have prior context.

The `TaskList` probe is the sole mechanism for detecting live teams. The harness exposes no `TeamList` tool, and the probe is non-destructive (it reads only, cannot create or delete teams).

## Workspace features

Features with a non-null `workspace` block are workspace-mode features. They resume IN PLACE at the workspace root -- no worktree, no `EnterWorktree` call.

Resume rules for workspace features:

1. **Assert cwd == workspace.root.** Before routing to any phase, check that the current session working directory equals `feature.workspace.root`. If it does not match, print:
   ```
   loop-spec: this workspace feature must be resumed from its workspace root.
   cd to {feature.workspace.root} and re-invoke cycle.
   ```
   Then abort (do not attempt phase routing from the wrong directory).

2. **No worktree probe.** Skip `git-ops.sh list-feature-worktrees` for workspace features. The feature has no `worktreePath` (it is null).

3. **Per-repo absolute paths.** All phase work uses absolute repo paths from `feature.workspace.repos[].path` resolved against `feature.workspace.root`. Subagents receive these absolute paths in their prompts.

4. **Pause/escalation:** workspace features skip the `ExitWorktree` call in the pause path (step 6 below) because no worktree was entered.

5. **Resume label:** append `" (workspace: {N} repos)"` to the option label when presenting workspace features in the resume selection list.

## Before escalating: answer from the record first

A coordinator must not escalate a question that is already answered. Before raising any `AskUserQuestion` during a phase:

1. **Consult the decisions record.** Read PLAN.md's `## User decisions (already made)` section (and the SPEC `<decisions>` block). If the question is settled there, resolve it from the record and proceed — do not ask.
2. **Consult the self-learning rules.** Render `.loop-spec/RULES.md` (`bash "${CLAUDE_SKILL_DIR}/../../lib/rules.sh" render`). If a rule already governs the situation, apply it rather than asking.
3. Escalate to the user **only** when neither the record nor the rules answer the question.

When you do escalate, the question must be **self-contained**: name the artifact and its role, state its current verified state, say why the decision is still open, and never recommend an option that contradicts a recorded decision. A question the user cannot answer without re-reading the whole plan is a defect — rewrite it.

When a gate or verifier rejects the **same class** of mistake more than once across runs, append a rule (`bash "${CLAUDE_SKILL_DIR}/../../lib/rules.sh" add "<lesson>" [--check "<cmd>"]`, prefer a deterministic check) so the next loop cannot repeat it, then continue. This is the self-learning loop: one repeated mistake, one permanent check.

## On phase pause / escalation

If a phase pauses + escalates (iteration limit exhausted, NEEDS_CONTEXT, etc.):

1. Tear down the phase team before returning control to the user — **only in `explicit`
   mode** (`.loop-spec/runtime.json.teamsMode == "explicit"`): call `TeamDelete({name: feature_json.currentTeamName})` if `currentTeamName` is non-null. In `implicit` and `none` mode `TeamDelete` does not exist (it throws); skip it — the teammates are session-scoped and end with the turn.
2. Clear `currentTeamName` and `currentTeammates` in `feature.json` via `lib/feature-write.sh`.
3. Print escalation reason.
4. Show the `gateHistory` tail (last 3 attempts from `feature.json.gateHistory` in `.loop-spec/features/{slug}/feature.json`).
5. Show partial artifacts (spec/plan/execution/verification/iteration paths) and, when
   DELIVER was attempted, `delivery.status`, every target PR URL/SHA/check status, and the
   structured error/manual recovery information.
5.5. Write the machine-readable result contract (non-fatal — must not block ExitWorktree):
   ```bash
   bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-result.sh" write ".loop-spec/features/${slug}" \
     --status escalated --reason "<escalation reason>" || true
   ```
   This also emits the `escalated` event to `events.jsonl`.
5.6. Push branch and open/reuse a draft PR to salvage the work product (gated: on by default for autonomous runs, LOOP_SPEC_CHECKPOINT_PR overrides; never blocks escalation):
   ```bash
   bash "${CLAUDE_SKILL_DIR}/../../lib/checkpoint-pr.sh" create ".loop-spec/features/${slug}" \
     --reason "<escalation reason>" || true
   ```
6. **Claude single-repo worktree mode only:** after snapshotting, call
   `ExitWorktree({action: "keep"})`. Workspace and OpenCode/pi in-place features skip it.
7. Return control to user.

User options:
- Edit artifacts manually + re-invoke cycle (resume continues)
- Reset retry counters: edit `feature.json` directly (`globalUsed = 0`, `perPhaseUsed.{phase} = 0`); resume
- Rollback: the `loop-spec:rollback` skill operates inside the worktree (cwd is already the worktree when the session is active inside it). On pause the session has exited the worktree, so re-enter via `EnterWorktree({path: feature.worktreePath})` first, then invoke rollback.
- Abort: delete `.loop-spec/features/{slug}/`; new branch state up to user

## Step 1 orphan detection (moved verbatim from cycle Step 1)

- **Orphan detection (explicit teams mode only):** if `currentTeamName != null` and `teamsMode == "explicit"`, probe team liveness by calling `TaskList({team: currentTeamName})`. (In `implicit`/`none` modes the probe is invalid AND meaningless — modern `TaskList` takes no parameters, and teammates never survive the session: treat the team as gone, clear `currentTeamName`, and add the feature to the resumable list — see `skills/shared/no-teams-fallback.md`.) Otherwise:
  - If `TaskList` returns without error: the team is still live (orphaned). Print:
    ```
    Previous team {currentTeamName} for feature {slug} was orphaned and is still live in the harness.
    Run TeamDelete for team {currentTeamName} (e.g., via the harness CLI or by re-invoking cycle in cleanup mode), then restart cycle to resume feature {slug}.
    ```
    Add to a "needs cleanup" sub-list. Do NOT add to resumable list.
  - If `TaskList` errors (team not found): the prior team is gone. Print `"feature {slug} had stale team reference {currentTeamName}; cleared and ready to resume"`. Clear `currentTeamName` in `feature.json` via `lib/feature-write.sh`. Add to resumable list.
- If `currentTeamName == null` AND `(now - updatedAt) < stalenessHours * 3600`: add to resumable list.

If "needs cleanup" sub-list is non-empty: display it to the user after presenting resume options, so they know which teams require manual `TeamDelete`.
