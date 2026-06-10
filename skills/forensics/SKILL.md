---
name: forensics
description: Read-only diagnostic that detects 7 anomaly patterns in a stuck or failed feature workflow and writes a structured report to .super-spec/forensics/.
argument-hint: "[feature slug or description of the stuck/failed workflow]"
---

# Forensics Diagnostic

Invoked as `/super-spec:forensics [problem description]`.

This skill is strictly read-only. It makes no changes to project state, feature.json,
PLAN.md, SPEC.md, or any other file. The only write is the structured report at
`.super-spec/forensics/report-{ISO-8601}.md`.

## Inputs

- `$ARGUMENTS` (optional): free-text description of the problem the user observed.
- Feature state read from `.super-spec/features/*/feature.json` (all active features).
- Git history and working-tree state via read-only git commands.

## Read-only constraint

All bash commands below use read-only git operations (`git log`, `git diff --name-only`,
`git status`, `git worktree list`). Do NOT run `git add`, `git commit`, `git checkout`,
`git reset`, or any write operation during this skill. Do NOT modify feature.json,
PLAN.md, SPEC.md, VERIFICATION.md, or any project file.

Permitted writes: `.super-spec/forensics/report-{ISO-8601}.md` only.

## Procedure

### Step 1 - Detect anomalies

Run all 7 detection checks below. Collect findings as a list of anomaly objects, each
with: `pattern`, `confidence` (HIGH / MEDIUM / LOW), `evidence`, and `interpretation`.

Missing files or commands returning non-zero are not errors; treat them as "no evidence
for this pattern" and continue.

#### Pattern 1: Stuck loop

**Detection:** Same file appears in 3 or more consecutive commits.

```bash
# Get per-commit file lists with commit boundaries
git log --name-only --format="---COMMIT--- %H %s" -30
```

Parse the output: for each file, track how many consecutive commits (reading from newest
to oldest) it appears in. If any file appears in 3 or more consecutive commits, flag it.

- Confidence HIGH: commit messages are similar (e.g., repeated "fix:", "update:" on the
  same file).
- Confidence MEDIUM: file appears frequently but commit messages vary.

#### Pattern 2: Missing artifact

**Detection:** `currentPhase` in feature.json does not match the committed artifacts
on disk.

For each feature found in `.super-spec/features/*/feature.json`:

```bash
# Read currentPhase and slug
python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get('currentPhase',''), d.get('slug',''))
" .super-spec/features/{slug}/feature.json
```

Then check expected artifact paths for that phase:
- discuss phase complete: `docs/super-spec/features/{slug}/SPEC.md` must exist.
- plan phase complete: `docs/super-spec/features/{slug}/PLAN.md` must exist.
- verify phase complete: `docs/super-spec/features/{slug}/VERIFICATION.md` must exist.

If `currentPhase` is past a phase boundary but the expected artifact is absent, flag
as missing artifact.

- Confidence HIGH: phase is marked completed but artifact file does not exist.
- Confidence MEDIUM: phase is in-progress but artifact file has no content.

#### Pattern 3: Partial plan drift

**Detection:** Task count in PLAN.md does not match the sum of completed and pending
tasks tracked by the harness.

```bash
# Count tasks in PLAN.md (lines matching "| task-" in the DAG table)
grep -c "^| task-" docs/super-spec/features/{slug}/PLAN.md 2>/dev/null || echo 0
```

Compare against `completedTasks` and `pendingTasks` arrays in feature.json:

```bash
python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
completed = len(d.get('completedTasks', []))
pending = len(d.get('pendingTasks', []))
print(completed + pending)
" .super-spec/features/{slug}/feature.json
```

If the PLAN.md count differs from `completedTasks + pendingTasks`, flag as partial plan
drift. This commonly indicates an executor was interrupted mid-task-list update.

- Confidence HIGH: counts differ by more than 1.
- Confidence MEDIUM: counts differ by exactly 1.

#### Pattern 4: Abandoned work

**Detection:** Commits exist on the feature branch but there has been no activity for
more than N hours (default 2 hours).

```bash
# Timestamp of last commit
git log -1 --format="%ai"

# Current time for comparison
date -u +"%Y-%m-%dT%H:%M:%SZ"
```

If the feature branch has commits (branch exists, `git log` is non-empty) and the last
commit timestamp is more than 2 hours before the current time, flag as abandoned work.

- Confidence HIGH: last commit is more than 8 hours ago with no uncommitted changes.
- Confidence MEDIUM: last commit is 2-8 hours ago or uncommitted changes exist.

#### Pattern 5: Crash or interruption

**Detection:** `feature.json` `updatedAt` exceeds the staleness threshold (default 2
hours) AND `currentPhase` is not `completed`.

```bash
python3 -c "
import json, sys
from datetime import datetime, timezone
d = json.load(open(sys.argv[1]))
updated_at = d.get('updatedAt', '')
current_phase = d.get('currentPhase', '')
print(updated_at, current_phase)
" .super-spec/features/{slug}/feature.json
```

Combine signals:
- `git status --short` shows modified or staged files (uncommitted changes).
- `git worktree list` shows worktrees beyond the main one (orphaned agent worktrees).
- feature.json `updatedAt` is stale and `currentPhase` is not `completed`.

If any two of these three signals are present, flag as crash or interruption.

- Confidence HIGH: all three signals present.
- Confidence MEDIUM: two of three signals present.

#### Pattern 6: Scope drift

**Detection:** Recent commits touch files outside the `files[]` listed in PLAN.md tasks.

Read the current feature's PLAN.md to extract expected file paths from the Files column
of the task DAG table. Then compare against files actually modified in recent commits:

```bash
# Files changed since baseSha (or last 10 commits if baseSha unavailable)
git diff --name-only HEAD~10..HEAD 2>/dev/null || git log --name-only --format="" -10
```

Any file in the git diff output that does not match any path listed in PLAN.md `files[]`
is a scope-drift candidate. Exclude `.super-spec/` state files and docs paths used by
the harness itself (those are expected writes).

- Confidence HIGH: 3 or more out-of-scope files modified.
- Confidence MEDIUM: 1-2 out-of-scope files modified.

#### Pattern 7: Test regression

**Detection:** Prior phase test suites are failing or commit history shows repeated test
fixes.

```bash
# Commits with test-fix signals
git log --oneline -20 | grep -iE "fix test|revert|broken|regression|fail" || true
```

Also check if a VERIFICATION.md exists for the current feature and contains FAIL entries:

```bash
grep -c "FAIL\|failed\|failing" docs/super-spec/features/{slug}/VERIFICATION.md 2>/dev/null || echo 0
```

- Confidence HIGH: VERIFICATION.md explicitly shows FAIL for a previously passing test,
  or 3 or more commits in the recent log match the regression pattern.
- Confidence MEDIUM: 1-2 commits match the regression pattern.

### workflow_orphaned

Trigger: ALL of:
- `feature.json.activeWorkflow` is set
- `activeWorkflow.sessionId` equals the current session id
- `/workflows` lists no run with `activeWorkflow.runId`
- Now - `activeWorkflow.startedAt` > 5 minutes

This is an INTRA-session signal only. Cross-session resume LEGITIMATELY has a
dead runId (workflow runtime cache does not survive session exit) and MUST
NOT trigger this anomaly.

Remediation hint: "re-enter the phase skill to redispatch the workflow."

### Step 2 - Write report

Create the report directory if absent:

```bash
mkdir -p .super-spec/forensics
```

Write the report to `.super-spec/forensics/report-{ISO-8601}.md` where `{ISO-8601}` is
the current timestamp in the format `YYYYMMDDTHHMMSSZ` (e.g., `20260528T142300Z`).

The report must follow this structure:

```markdown
# Forensic Report

**Generated:** {ISO-8601 timestamp}
**Problem:** {user's description from $ARGUMENTS, or "No description provided"}

---

## Evidence Summary

### Git Activity
- **Last commit:** {date} - "{message}"
- **Commits examined:** {count}
- **Uncommitted changes:** {yes - list files | no}
- **Active worktrees:** {count - list if more than 1}

### Feature State
- **Slug:** {slug}
- **Current phase:** {currentPhase}
- **Completed tasks:** {count}
- **Pending tasks:** {count}
- **updatedAt:** {timestamp from feature.json}

### Artifact Completeness
| Phase    | Artifact                  | Present |
|----------|---------------------------|---------|
| discuss  | SPEC.md                   | yes/no  |
| plan     | PLAN.md                   | yes/no  |
| verify   | VERIFICATION.md           | yes/no  |

## Anomalies Detected

### {Pattern Name} - Confidence: {HIGH|MEDIUM|LOW}
**Evidence:** {specific commits, files, or state data}
**Interpretation:** {what this likely means}

{repeat for each anomaly found; omit patterns with no evidence}

## No Anomalies
{include this section only when zero anomalies were found}

## Root Cause Hypothesis

{1-3 sentence hypothesis grounded in the anomalies; if no anomalies: "No anomalies
detected. The feature workflow appears consistent with its recorded state."}

## Recommended Actions

1. {Specific, actionable step - e.g., "Run /super-spec:resume to restart from last
   committed phase" or "Manually inspect .super-spec/features/{slug}/feature.json
   and correct currentPhase"}
2. {Additional step if applicable}

---

*Report generated by /super-spec:forensics. This file is the only artifact written
by this diagnostic run. Report path: .super-spec/forensics/report-{timestamp}.md*
```

**Path redaction rules:**
- Replace absolute paths with paths relative to the project root.
- Do not include API keys, tokens, or credentials found in git diff output.
- Truncate long diffs to the first 50 lines.

### Step 3 - Print summary

After writing the report, print a summary to the user:

```
Forensic report written to: .super-spec/forensics/report-{timestamp}.md

Anomalies found: {count}
{for each anomaly: "  - {pattern name} ({confidence})"}

{if count == 0: "No anomalies detected. The feature workflow appears healthy."}
{if count > 0: "Run /super-spec:rollback or /super-spec:resume to act on findings."}
```

Do not offer to auto-remediate. Offer to explain any finding in more detail if the user
asks follow-up questions.

## Output path format

Reports are always written to:

```
.super-spec/forensics/report-{ISO-8601}.md
```

Example: `.super-spec/forensics/report-20260528T142300Z.md`

The `forensics/report-` path prefix is the unique identifier for this skill's output.
No other path is ever written.

## Pattern reference table

| # | Pattern name      | Primary signal                                               |
|---|-------------------|--------------------------------------------------------------|
| 1 | stuck loop        | Same file in 3 or more consecutive commits                   |
| 2 | missing artifact  | currentPhase does not match committed artifacts on disk      |
| 3 | partial plan drift| PLAN.md task count differs from completedTasks + pendingTasks|
| 4 | abandoned work    | Commits on branch with no activity for more than N hours     |
| 5 | crash or interruption | feature.json updatedAt stale and currentPhase not completed |
| 6 | scope drift       | Commits touch files outside PLAN.md files[]                  |
| 7 | test regression   | Prior phase test suites failing or repeated test-fix commits |
