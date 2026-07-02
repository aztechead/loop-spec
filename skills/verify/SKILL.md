---
name: verify
description: VERIFY phase - acceptance gate, code-review HARD-GATE via the verify team (explicit, implicit, or no-teams dispatch), map-codebase refresh, branch finish (push + PR).
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet ToolSearch Workflow
---

# VERIFY Phase

Invoked when feature.json currentPhase == "verify".

> **No-teams fallback:** if `.loop-spec/runtime.json.teamsAvailable == false`, do NOT
> call `TeamCreate`/`TeamDelete`/`SendMessage` (they throw). Run verifier and
> code-reviewer as sequential one-shot `Agent` calls with the same agent types, models,
> and prompt templates, per `skills/shared/no-teams-fallback.md`. The acceptance gate and
> code-review HARD-GATE semantics are unchanged.

> **Implicit-team harness:** if `.loop-spec/runtime.json.teamsMode == "implicit"` (CC >= 2.1.178),
> do NOT call `TeamCreate`/`TeamDelete` (they were removed and throw). The team already exists:
> spawn verifier and code-reviewer with `Agent({name, description, subagent_type, model, prompt})`, folding
> each one's work prompt into the spawn, and use `SendMessage` for any follow-up. Per
> `skills/shared/implicit-team-mode.md`. The acceptance gate and code-review HARD-GATE
> semantics are unchanged.

> **Autonomous mode** (`feature.json.autonomous == true`): no escalation in this phase
> may wait on a human — pause-and-escalate points halt with evidence in `warnings[]`
> instead, per `skills/shared/autonomous-mode.md`. The acceptance gate, code-review
> HARD-GATE, and test-tamper scan are safety gates and are NEVER self-answered past.

## Inputs

- `feature_path` (path to `.loop-spec/features/{slug}/feature.json`)
- `spec_path`, `plan_path`
- `branch`, `baseSha`
- `slug`

## Procedure

### Step 0 - Regression gate (opt-in)

This scan re-runs every prior completed feature's test commands serially and is **advisory only** (it can never block VERIFY). Because that serial cost sits in front of the fail-fast marker scan and the parallel team, it is **off by default**; enable it with `LOOP_SPEC_REGRESSION_SCAN=1`.

```bash
if [[ "${LOOP_SPEC_REGRESSION_SCAN:-0}" != "1" ]]; then
  echo "Regression scan skipped (set LOOP_SPEC_REGRESSION_SCAN=1 to enable)"
else
  REGRESSION_JSON=$(bash "${CLAUDE_SKILL_DIR}/../../lib/regression-scan.sh" .)
fi
```

When enabled:

Parse the JSON output:

```bash
PRIOR_COUNT=$(echo "$REGRESSION_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('prior_features', [])))")
FAILED_COUNT=$(echo "$REGRESSION_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('failed_tests', [])))")
```

This gate is **advisory only**: a non-zero `failed_tests` count does NOT block VERIFY. Log the result to VERIFICATION.md:

```
Regression scan complete: {PRIOR_COUNT} prior features checked, {FAILED_COUNT} test failures (advisory)
```

If `regression-scan.sh` itself fails (exits non-zero or produces invalid JSON), log a warning and continue without blocking:

```
Warning: regression-scan.sh failed to run; skipping advisory regression gate
```

### Step 1 - Unresolved marker scan

Before spawning any teammates, scan source files on `branch` for unresolved markers:

**Single-repo mode (unchanged):**

```bash
git diff --diff-filter=ACMR {baseSha}..HEAD --name-only \
  | grep -E '\.(py|ts|js|go|rs|java|rb|sh)$' \
  | xargs grep -wn 'TBD\|FIXME\|XXX' 2>/dev/null || true
```

**Workspace mode (additive):** apply the workspace variant for this step verbatim from `${CLAUDE_SKILL_DIR}/references/workspace-mode.md` ("Step 1 - Unresolved marker scan").

If any matches (in either mode): VERIFY fails immediately. List each `file:line: match` to the user.
Do not spawn verifier or code-reviewer until all markers are resolved.

Notes:
- `--diff-filter=ACMR` excludes deleted files (avoids "no such file" errors on xargs)
- `.md` excluded from filter: prose descriptions of markers are not unresolved code
- `-w` (word boundary) avoids false positives on identifiers like `STBD`, `XXXL`

Rationale: unresolved markers indicate incomplete implementation; running acceptance
gates against incomplete code wastes agent budget.

### Step 1.5 - Test-tamper scan (anti-reward-hacking, fail-fast)

The implementer may have edited the very suite the acceptance gate is about to trust. Before spawning teammates, scan the diff for oracle tampering — deleted test files, newly-added skip/focus annotations (`.skip`, `.only`, `xit`, `@pytest.mark.skip`, `t.Skip`, ...), and `|| true` swallowing a test command's exit code:

**Single-repo mode:**

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/test-tamper-scan.sh" "{baseSha}" .
```

**Workspace mode:** run once per participating repo with that repo's `baseSha` and absolute path.

Exit 1 = signals found: VERIFY fails immediately. Print the listed signals verbatim. This is NOT auto-remediable by re-running EXECUTE with a generic brief — the remediation task must state the specific tampering (`subject = "Fix: restore tampered test — {signal}"`) so the implementer un-tampers rather than re-tampers. A legitimate skip (e.g. a platform-gated test) is the HUMAN's call: in `step`/`interactive` styles ask; in autonomous styles treat as tampering and remediate — a real platform gate will come back with justification in the task notes and can be accepted on the next pass by recording it in `warnings[]`.

### Step 2 - TeamCreate verify team

Create the verify team with verifier and code-reviewer as parallel teammates:

```
TeamCreate({
  name: "loop-spec-verify-{slug}",
  teammates: [
    {
      name: "verifier-1",
      subagent_type: "loop-spec:verifier",
      model: feature.models.verifier
    },
    {
      name: "code-reviewer-1",
      subagent_type: "loop-spec:code-reviewer",
      model: feature.models.codeReviewer
    }
  ]
})
```

Update `feature.json` via `lib/feature-write.sh`:
- `currentTeamName = "loop-spec-verify-{slug}"`
- `currentTeammates = ["verifier-1", "code-reviewer-1"]`

### Step 3 - Acceptance gate (workflow path or fallback)

Read `.loop-spec/runtime.json`. If `workflowsAvailable=true`, dispatch:

```text
Workflow({
  scriptPath: "${CLAUDE_SKILL_DIR}/../../lib/workflows/acceptance-verify.js",
  args: {
    criteria: <parsed from PLAN.md acceptance section>,
  }
})
```

Persist `feature.json.activeWorkflow` before the call; clear after.
Result shape: `{criteria: [{id, verdict, evidence, testSuiteStatus, refutes, upheld}], allPass}`.
Skill writes VERIFICATION.md from this structure (one section per criterion).

Test-regression remediation routing is preserved by reading
`criteria[].testSuiteStatus`: any `"FAIL"` → trigger the same remediation branch
that today's verifier triggers on `Test suite status: FAIL`.

If `workflowsAvailable=false`, fall through to the existing verifier-1 spawn
below.

### Step 4 - Spawn verifier-1

Send verifier-1 its work prompt via SendMessage:

Resolve the test/lint/typecheck commands from `feature.json.commands` and pass them in the brief so the verifier (the authoritative test runner) never has to guess or report a false "no command found" FAIL.

**Single-repo mode (unchanged):**

```
SendMessage({
  to: "verifier-1",
  body: "Run every acceptance criterion's verify command from PLAN.md. Gate ONLY on the SPEC 'Good Enough' success criteria; report 'Exceptional' (stretch) criteria as informational, never as a FAIL. Write VERIFICATION.md to docs/loop-spec/features/{slug}/VERIFICATION.md. When complete, SendMessage({to: 'lead', body: 'VERIFIER DONE: <ALL_PASS|FAIL> <Test suite status: PASS|FAIL|N/A> <summary>'})."
  // also include: slug, spec_path, plan_path, branch, baseSha,
  //   and the resolved commands: test="<feature.commands.test>", lint="<feature.commands.lint>", typecheck="<feature.commands.typecheck>"
})
```

**Workspace mode (additive):** apply the workspace variant for this step verbatim from `${CLAUDE_SKILL_DIR}/references/workspace-mode.md` ("Step 4 - Spawn verifier-1").

### Step 5 - Code-review HARD-GATE (workflow path or fallback)

Read `.loop-spec/runtime.json`. If `workflowsAvailable=true`:

```text
Workflow({
  scriptPath: "${CLAUDE_SKILL_DIR}/../../lib/workflows/code-review-dimensions.js",
  args: {
    baseSha: feature.baseSha,
  }
})
```

Result shape: `{findings: [{file, line, dimension, severity, claim, refuteVotes, upheld}], critical, important}`.

**Skill (not workflow) converts findings to pendingRemediationTasks[]** by
filtering `upheld=true` and mapping each to a remediation task. The existing
RALPH_THRESHOLD comparison logic (skill-side, unchanged) then decides
Ralph-loop vs full EXECUTE re-entry.

If `workflowsAvailable=false`, fall through to the existing code-reviewer-1
spawn below.

### Step 6 - Spawn code-reviewer-1

Send code-reviewer-1 its work prompt via SendMessage:

Pass `spec_path` so the reviewer can check each SPEC Boundary / anti-goal against the diff (the "must never produce" behaviors most worth catching at a HARD gate), and echo the blocking-severity rule (Critical + Important block; Minor is recorded, backlogged, and never blocks) so the reviewer self-prioritizes blocking findings.

**Single-repo mode (unchanged):**

```
SendMessage({
  to: "code-reviewer-1",
  body: "Review the feature branch diff against SPEC.md and PLAN.md acceptance criteria. Check each SPEC '## Boundaries (what NOT to do)' anti-goal against the diff; flag any violation Critical. Rank findings by the fixed rule: Critical + Important block; Minor is recorded but never blocks. When complete, SendMessage({to: 'lead', body: 'CODE-REVIEWER DONE: <PASS|PASS_WITH_MINOR|BLOCK> <summary of findings>'})."
  // also include: slug, branch, baseSha, spec_path, plan_path
})
```

**Workspace mode (additive):** apply the workspace variant for this step verbatim from `${CLAUDE_SKILL_DIR}/references/workspace-mode.md` ("Step 6 - Spawn code-reviewer-1").

### Step 7 - Acceptance gate

Wait for both `VERIFIER DONE` and `CODE-REVIEWER DONE` messages from teammates before proceeding.

#### verifier-1 gate

**If verifier reports `ALL_PASS` AND `Test suite status: PASS` (or `N/A`):** proceed to code-reviewer gate below.

**If verifier reports `ALL_PASS` but `Test suite status: FAIL`:**
- Generate a remediation task: `subject = "Fix: test suite regression"`, `verifyCommand = feature.commands.test`.
- Append the remediation task to `feature.json.pendingRemediationTasks[]` via `lib/feature-write.sh append`. EXECUTE Step 2a reads this array alongside PLAN.md tasks on next entry. Using feature.json (not `TaskCreate` on the verify team) is critical: the verify team's task list is destroyed by the `TeamDelete` later in this step, so any `TaskCreate` calls on it would be lost.
- Update `feature.json` via `lib/feature-write.sh`:
  - Increment `retryBudget.perPhaseUsed.verify` and `retryBudget.globalUsed`.
  - Append entry to `gateHistory[]` (`phase: verify`, `gate: acceptance`, `result: fail`).
  - Check budgets. If either `perPhaseUsed.verify >= retryBudget.perPhase.verify` or `globalUsed >= retryBudget.global`: pause and escalate to user.
  - Else: set `currentPhase = "execute"`.
- Call `TeamDelete({name: "loop-spec-verify-{slug}"})`.
- Update `feature.json` via `lib/feature-write.sh`: `currentTeamName = null`, `currentTeammates = []`.
- Discard code-reviewer output for this iteration (will re-run when verify loops back after remediation).
- Route to `loop-spec:execute`.

**If verifier reports `FAIL`:**
- Discard code-reviewer output for this iteration.
- For each failed criterion, generate a remediation task:
  ```json
  {
    "id": "task-NNN+remediate-M",
    "subject": "Fix: {criterion}",
    "files": ["...derived from failure"],
    "verifyCommand": "criterion's verify command",
    "acceptanceCriteria": ["criterion"],
    "blockedBy": [],
    "retries": 0
  }
  ```
- Append each remediation task to `feature.json.pendingRemediationTasks[]` via `lib/feature-write.sh append`. EXECUTE Step 2a reads this array alongside PLAN.md tasks on next entry. Using feature.json (not `TaskCreate` on the verify team) is critical: the verify team's task list is destroyed by the `TeamDelete` later in this step.
- Update `feature.json` via `lib/feature-write.sh`:
  - Increment `retryBudget.perPhaseUsed.verify` and `retryBudget.globalUsed`.
  - Append entry to `gateHistory[]` (`phase: verify`, `gate: acceptance`, `result: fail`).
  - Check budgets. If exceeded: pause and escalate to user.
  - Else: set `currentPhase = "execute"`.
- Call `TeamDelete({name: "loop-spec-verify-{slug}"})`.
- Update `feature.json` via `lib/feature-write.sh`: `currentTeamName = null`, `currentTeammates = []`.
- Route to `loop-spec:execute`. When execute completes, re-invoke verify from Step 1.

#### code-reviewer-1 HARD-GATE

Use the `CODE-REVIEWER DONE` message already received from Step 6.

Fixed gate rule (single-tier operation): **BLOCK on Critical OR Important. PASS_WITH_MINOR proceeds; every Minor is backlogged below.**

**If BLOCK:**
- Generate one remediation task per blocking finding (same remediation task shape as verifier FAIL above).
- Append each remediation task to `feature.json.pendingRemediationTasks[]` via `lib/feature-write.sh append`. EXECUTE Step 2a reads this array alongside PLAN.md tasks on next entry.
- Update `feature.json` via `lib/feature-write.sh`:
  - Increment `retryBudget.perPhaseUsed.verify` and `retryBudget.globalUsed`.
  - Append entry to `gateHistory[]` (`phase: verify`, `gate: code-review`, `result: fail`).
  - Check budgets. If exceeded: pause and escalate to user.
  - Else: set `currentPhase = "execute"`.
- Call `TeamDelete({name: "loop-spec-verify-{slug}"})`.
- Update `feature.json` via `lib/feature-write.sh`: `currentTeamName = null`, `currentTeammates = []`.
- **Ralph remediation routing:** Check `pendingRemediationTasks.length` from `feature.json`.
  - `RALPH_THRESHOLD="${LOOP_SPEC_RALPH_THRESHOLD:-3}"` (default 3).
  - If `pendingRemediationTasks.length <= RALPH_THRESHOLD`: invoke `bash "${CLAUDE_SKILL_DIR}/../../lib/ralph-remediation.sh" "$feature_dir"` and use its output to drive the remediation loop instead of the full EXECUTE team. If `ralph-remediation.sh` exits 1 (max iterations reached), fall through to the full EXECUTE team path.
  - Else (task count exceeds threshold): route to `loop-spec:execute` (existing behavior). When execute completes, re-invoke verify from Step 1.

**If PASS or PASS_WITH_MINOR:**
- Append code-review section to VERIFICATION.md.
- **Backlog the deferred findings (they must not evaporate):** every Minor finding in a PASS_WITH_MINOR is appended to the project backlog:
  ```bash
  bash "${CLAUDE_SKILL_DIR}/../../lib/backlog.sh" add "{slug}" verify-deferred "{finding: file:line — claim}"
  ```
  Deferral means "not this feature", not "never" — the backlog is where `/loop-spec:cycle backlog` picks them up.
- Proceed to Step 8.

**Self-learning writer (repeat failures become rules):** whenever this step appends a `result: fail` entry to `gateHistory[]`, check whether the SAME criterion or finding already failed in a prior entry (same `gate`, matching criterion/finding text). On the second failure, record the lesson as a deterministic rule so future runs cannot repeat it:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/rules.sh" add "VERIFY repeat-fail on '{criterion}' ({slug}): check this before EXECUTE completes" --check "{the criterion's verify command}"
```

One rule per repeated criterion (rules.sh add is idempotent). Do not write rules for first-time failures — one failure is remediation's job; a repeat is a pattern.

### Step 8 - TeamDelete verify team

```
TeamDelete({name: "loop-spec-verify-{slug}"})
```

Update `feature.json` via `lib/feature-write.sh`: `currentTeamName = null`, `currentTeammates = []`.

### Step 9 - map-codebase refresh

**Single-repo mode (unchanged):**

Before invoking the map-codebase skill, run an incremental graphify update via the preflight lib (`graphify . --update`). graphify is a hard requirement, so it is present; this post-merge refresh is nonetheless best-effort:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/graphify-preflight.sh" build . \
  || echo "Warning: graphify refresh failed; continuing (non-blocking at verify stage)" >&2
```

Failure of the graphify refresh is non-blocking here: VERIFY runs after the design phases, so a stale graph does not affect this phase's gates. Log a warning and continue.

**Greenfield (`feature.json.greenfield == true`):** this is where the project's FIRST graph and FIRST codebase map get built (cycle Steps 5.4/5.5 deferred them — an empty repo grounds nothing). The `graphify-preflight.sh build` above creates the initial graph; then invoke map-codebase with `--full` instead of incremental, since there are no existing domain docs to refresh.

Invoke the map-codebase skill for an incremental refresh:

```
Skill(loop-spec:map-codebase) with mode: "incremental", since_sha: feature.baseSha
```

Note: the map-codebase skill runs inside the feature worktree (cwd is already there). Any mapper subagents it spawns do NOT inherit the cwd and must receive an absolute repo path. Resolve it once and pass it through -- only in single-repo mode (workspace root may not be a git repo):

```bash
# Single mode only -- do NOT run this at a workspace root:
WORKTREE_ABS="$(git rev-parse --show-toplevel)"
# pass WORKTREE_ABS to each mapper subagent as its working directory
```

If map-codebase fails: log warning to `feature.json warnings[]` via `lib/feature-write.sh` and continue (non-blocking; map failure is not a release gate).

**Workspace mode (additive):** apply the workspace variant for this step verbatim from `${CLAUDE_SKILL_DIR}/references/workspace-mode.md` ("Step 9 - map-codebase refresh").

### Step 10 - Branch finish

**Single-repo mode (unchanged):**

Push and PR creation execute from inside the feature worktree (cwd is already on `feat/{slug}`), so no branch checkout is needed. If any branch-finish step delegates to a subagent, pass the worktree's absolute path explicitly (subagents do not inherit cwd).

```bash
# Push (runs from feature worktree; cwd is already on feat/{slug})
git push -u origin {feature.branch}

# PR body: SPEC.md Problem+Goals sections + VERIFICATION.md acceptance table
spec_summary=$(awk '/^## Problem/,/^## (Constraints|User-facing)/' docs/loop-spec/features/{slug}/SPEC.md | head -100)
verify_table=$(awk '/^## Acceptance criteria/,/^## Verify command outputs/' docs/loop-spec/features/{slug}/VERIFICATION.md)
pr_body="$(printf '## Spec summary\n\n%s\n\n## Verification\n\n%s\n' "$spec_summary" "$verify_table")"

# Use baseBranch from feature.json (feature.baseBranch), not hardcoded main
pr_url=$(gh pr create --base "${feature.baseBranch:-main}" --head {feature.branch} --title "feat: {feature_title}" --body "$pr_body")
```

**Workspace mode (additive):** apply the workspace variant for this step verbatim from `${CLAUDE_SKILL_DIR}/references/workspace-mode.md` ("Step 10 - Branch finish").

### Step 11 - Commit VERIFICATION.md

**Single-repo mode (unchanged):**

```bash
git add docs/loop-spec/features/{slug}/VERIFICATION.md
git commit -m "verify: NO_JIRA {slug} (PR: {pr_url})"
```

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/checkpoint.sh" tag post-verify
```

**Workspace mode (additive):** apply the workspace variant for this step verbatim from `${CLAUDE_SKILL_DIR}/references/workspace-mode.md` ("Step 11 - Commit VERIFICATION.md").

### Step 12 - Update feature.json

Update `feature.json` via `lib/feature-write.sh`:
- `completedPhases.append("verify")`
- `currentPhase = "iterate"` — VERIFY's gates passing means the SPEC acceptance checklist is met; the ITERATE phase then judges the integrated result against the **original goal** and decides whether to ship or loop back. (When `feature.iterate.maxIterations` is exhausted on a prior pass, ITERATE ships rather than re-entering; see `skills/iterate/SKILL.md`.)
- `artifacts.verification = "docs/loop-spec/features/{slug}/VERIFICATION.md"`

### Step 13 - Exit feature worktree (schema-6 only)

**Workspace mode:** skip this step entirely when `feature.workspace` is non-null. Workspace features run in-place (no worktree was created and no `EnterWorktree` was called), so there is nothing to exit. Resume continues from the workspace root without any worktree operation.

**Single-repo mode (unchanged):**

In single-repo mode `feature.worktreePath` is always present (set at cycle Step 5), so the session is currently inside the feature worktree. Return to the main checkout while leaving the worktree and branch intact for the open PR:

```
ExitWorktree({ action: "keep" })
```

The worktree is kept on disk until the PR merges. Do NOT auto-remove it. Removal is manual (or handled by a future cleanup skill) once the branch is confirmed merged.

### Step 14 - Summary

**Single-repo mode (unchanged):**

Print to user:
- Feature slug
- PR URL
- Commits added
- Files changed
- Token usage estimate
- Total elapsed time

**Workspace mode (additive):** apply the workspace variant for this step verbatim from `${CLAUDE_SKILL_DIR}/references/workspace-mode.md` ("Step 14 - Summary").

## Resume

If invoked with `feature.json currentPhase == "verify"`: check what completed (team created? verifier ran? acceptance gate? code-reviewer? map-codebase? push? PR?). Resume from first incomplete step.

On resume, if `currentTeamName` is non-null:
- In `explicit` teams mode only: call `TaskList({team: currentTeamName})`; if it errors (team not found), clear `currentTeamName` in `feature.json` and recreate the team via Step 2. In `implicit`/`none` modes skip the probe (modern `TaskList` takes no parameters; teammates never survive the session): clear `currentTeamName` and re-run Step 2's spawn path.
- If it succeeds (team still live): re-attach and resume from the last incomplete step.

If `currentTeamName` is null: recreate the verify team from Step 2 and replay.
