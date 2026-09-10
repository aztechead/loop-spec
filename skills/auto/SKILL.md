---
name: auto
description: "Route autonomous script or SDK requests to micro, debug, compact, or full based on repository evidence. Use when the caller has not selected a route. Do not replace a skill the user named in an interactive session."
argument-hint: "<task description>"
allowed-tools: Bash Read Glob Grep Skill
---

# loop-spec:auto

Select a route without asking questions or implementing the request.
Preserve the request verbatim when delegating. Always include the `autonomous` token.

## Entry Contract

- `/loop-spec:auto <description>` is autonomous by definition. You may remove a redundant inline `autonomous` token from the description.
- A bare invocation aborts with usage guidance; there is no goal to infer.
- `new`, `backlog`, a SPEC `.md` path, and requests to resume an existing cycle are
  always full. Skip broad grounding, but still validate/output a `full` decision before
  calling `Skill(loop-spec:cycle)` with `autonomous`; do not classify them down.
- Explicit `/loop-spec:cycle`, `/loop-spec:micro`, and `/loop-spec:debug` invocations
  keep their existing semantics. This router does not change those contracts.

## Step 1 - Ground the Decision

Before choosing a route, use only read-only probes:

1. Inspect repository/workspace shape and `git status`.
2. Resolve the likely target files with `Glob`/`Grep`, then read enough surrounding
   code and tests to estimate the actual edit surface. Do not classify from prompt
   keywords alone.
3. State no implementation plan and make no edits. The only output before delegation
   is the final one-line route decision.

Propose exactly one JSON object with this schema:

```json
{
  "route": "micro | debug | compact | full",
  "taskKind": "docs | config | maintenance | bug | feature | refactor | greenfield | unknown",
  "confidence": 0.0,
  "estimatedFiles": 0,
  "generatedFiles": 0,
  "criteriaCount": 1,
  "ambiguity": "low | medium | high",
  "introducesSeam": false,
  "introducesDependency": false,
  "introducesNewDependency": false,
  "updatesDependencyVersion": false,
  "changesInterface": false,
  "securitySensitive": false,
  "dataMigration": false,
  "multiRepo": false,
  "destructive": false,
  "reason": "one concrete sentence grounded in the inspected request and files"
}
```

Include `gatePlan` **only** when `route` is `compact`; omit it for `micro`,
`debug`, and `full` rather than emitting `null` or an unapplied plan. For compact,
replace the omitted field with exactly these ten entries:

```json
"gatePlan": {
  "specInterview": {"run": false, "reason": "nonblank explanation"},
  "discuss": {"run": false, "reason": "nonblank explanation"},
  "specCritique": {"run": false, "reason": "nonblank explanation"},
  "planCritique": {"run": true, "reason": "nonblank explanation"},
  "repositoryValidation": {"run": true, "reason": "nonblank explanation"},
  "placeholderScan": {"run": true, "reason": "nonblank explanation"},
  "tamperScan": {"run": true, "reason": "nonblank explanation"},
  "acceptance": {"run": true, "reason": "nonblank explanation"},
  "codeReview": {"run": true, "reason": "nonblank explanation"},
  "iterate": {"run": true, "reason": "nonblank explanation"}
}
```

Route semantics:

- **micro**: well-understood maintenance with at most 3 criteria and about 5 reviewable edited files.
  Do not count generated lockfiles toward this limit.
  Examples include focused documentation or config changes, existing dependency updates, renames, and localized fixes with known causes.
  Use `taskKind: maintenance` for merge-conflict resolution, PR sync or rebase, re-review against the default branch, and one-command chores.
  Micro uses the current checkout and reuses the branch's existing PR.
  It uses no subagents or design phases. Classification and micro execution inherit the session model in Claude Code and OpenCode.
- **debug**: a bounded bug or unexplained behavior that needs reproduction, hypotheses,
  and a sibling sweep. This is the middle route: more rigor than micro without a
  feature SPEC/PLAN DAG.
- **compact**: a bounded feature or refactor that stays in the cycle. The classifier
  supplies a durable typed `gatePlan` for every adaptable gate. Read
  `skills/shared/compact-profile.md` before proposing compact: all ten entries are
  required, each exactly `{run:boolean, reason:nonblank string}`. A confident compact
  classification may handle security, migration, multi-repository, dirty-worktree,
  interface, seam, or dependency work; destructive work is always full.
- **full**: new projects, unknown or destructive work, broad requests, and work without enough evidence for compact.
  Maintenance beyond micro's limits also uses `full`, including large conflict resolutions and broad re-reviews.
  Seam, interface, security, migration, multi-repository, dependency, and dirty-worktree concerns default to `full`.
  Compact may handle these concerns only when its saved plan explains their bounded scope using repository evidence.
  Promote uncertain work to `full`. Do not classify it as `protocol-mismatch`.

Compact reuses the existing cycle and its terminal delivery contract. The gate plan
changes only adaptable gate choices; it does not create a separate protocol.

## Step 2 - Validate Fail-Closed

The semantic proposal does not authorize itself. Validate it through the deterministic
boundary:

```bash
decision="$(printf '%s\n' '<one-line candidate JSON>' | \
  bash "${LOOP_SPEC_SKILL_DIR}/../../lib/task-route.sh" validate -)"
```

Use `.route` from the validated output, never the proposed route.
The validator promotes the following to `full`:

- Malformed compact gate plans.
- Confidence below 0.7 or high ambiguity.
- More than 12 reviewable files or 6 criteria.
- Destructive compact work.
- Invalid micro or debug classifications.

The script checks working-tree conflicts from the current execution root using the cycle's clean-base rules.
It does not accept a conflict path or field from the proposal.
Conflicts promote micro and debug to full. A confident compact proposal may address conflicts in its gate plan.

Set `introducesDependency` for compatibility whenever either dependency field is true.
Set `introducesNewDependency` only when the change adds a dependency edge; a version-only
change sets `updatesDependencyVersion` instead. `generatedFiles` counts generated outputs
such as lockfiles within `estimatedFiles`, never hand-maintained manifests.

A `full` route still carries the classification's own risk picture, so resolve the
execution profile from the SAME normalized decision and pass it to the cycle:

```bash
profile_line="$(printf '%s' "$decision" | \
  bash "${LOOP_SPEC_SKILL_DIR}/../../lib/cycle-profile.sh" select -)"
profile="${profile_line#profile=}"; profile="${profile%% *}"
```

Keep `profile_line` internal to routing. The route decision is the sole router output:
one `AUTONOMOUS_ROUTE ` line containing the normalized decision.

`profile=compact` applies the validated compact gate plan; `profile=maintenance` retains
the existing maintenance short path; `profile=standard` is the unchanged full ladder.
The logged line carries its own reason, so a run says why its profile was allowed.

Print the normalized decision as one JSON line prefixed with `AUTONOMOUS_ROUTE `.
Keep routing state outside the tracked tree so cycle and delivery guards see a clean base.
The validator records the active run in the Git-ignored `.loop-spec/active-run.json`.
Step 4 uses this record to detect a missing terminal result.

## Step 3 - Delegate Once

Delegate exactly once, then let that protocol run through verification, commit, PR
creation/reconciliation, and terminal PR feedback checking:

- `micro` -> `Skill(loop-spec:micro)` with `autonomous <verbatim request>`.
- `debug` -> `Skill(loop-spec:debug)` with `autonomous <verbatim request>`.
- `compact` -> `Skill(loop-spec:cycle)` with `autonomous profile:compact <verbatim request>`.
- `full` -> `Skill(loop-spec:cycle)` with `autonomous profile:{profile} <verbatim request>`.

Every selected route owns the same `skills/shared/verification-grounding.md` post-change
gate. Routing changes ceremony and orchestration, never the shared verification-grounding contract.

Do not call intake first; cycle already accepts prose. Do not perform implementation
work in this skill. The delegated protocol owns runtime scope tripwires: micro promotes
losslessly when its bounds are crossed, and debug promotes when the confirmed fix is
feature-scale.

The delegated protocol also owns **`skills/shared/route-exit-contract.md`**: it runs to
a published terminal result. `protocol-mismatch` is for a genuine non-task (a pure
question, or work that needs a different product). A task this router accepted —
including a merge-conflict resolution, PR sync/rebase, re-review, or maintenance
chore, even when fail-closed promotion sent it to `full` — is executed, not declined.
When `full` is selected, pass `profile:{profile}` so the maintenance short path can
shrink ceremony; the cycle still walks PLAN → EXECUTE → VERIFY → ITERATE → DELIVER
and publishes on completion. Never leave the protocol and complete the task by hand,
which delivers work no caller can see.

## Step 4 - Confirm the terminal result

The routed skill publishes `.loop-spec/last-result.json`. Confirm it did, because a run
that ends without one reads as a failure to every headless caller:

```bash
repo_root="$(git rev-parse --show-toplevel)"
bash "${LOOP_SPEC_SKILL_DIR}/../../lib/cycle-reconcile.sh" --result-root "$repo_root" \
  --reason "routed skill ended without emitting a terminal result"
```

Reconciliation is a no-op when the route published normally — it re-prints the existing
`LOOP_SPEC_RESULT` line and exits 0. When the route ended without one, it writes the
terminal result from the armed run so the contract holds anyway. Run it on every route,
including the ones you believe succeeded, and report its output as the run's result.
