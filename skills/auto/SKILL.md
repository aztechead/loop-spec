---
name: auto
description: Autonomous entry point for Claude Code, OpenCode, ADK, and Codex SDK/headless requests. Use when a script or SDK has a grounded task and has not named cycle, debug, or micro; routes to micro, debug, compact, or full, failing upward when uncertain. Do not use from an interactive session when the user already named a skill - run that skill instead.
argument-hint: "<task description>"
allowed-tools: Bash Read Glob Grep Skill
---

# loop-spec:auto

Question-free autonomous router. This skill decides how much process the request
needs; it does not implement the request itself. Preserve the request verbatim when
delegating and always include the `autonomous` token.

## Entry Contract

- `/loop-spec:auto <description>` is autonomous by definition. A redundant inline
  `autonomous` token may be stripped from the description.
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

- **micro**: direct, well-understood maintenance with at most 3 criteria and about 5
  reviewable edited files. Generated lockfiles do not count toward that edit surface.
  Examples include a focused documentation refresh, config adjustment, an update to
  already-present dependency versions, a rename, a localized fix whose mechanism is
  already known, a merge-conflict resolution, a PR sync/rebase, a re-review against
  the default branch, or a one-command chore — all `taskKind: maintenance`, all work
  to execute (micro owns the current checkout and will reuse the branch's existing
  PR). No subagents or design
  phases. The micro skill inherits the session model in Claude Code and OpenCode;
  classification stays on that same parent model.
- **debug**: a bounded bug or unexplained behavior that needs reproduction, hypotheses,
  and a sibling sweep. This is the middle route: more rigor than micro without a
  feature SPEC/PLAN DAG.
- **compact**: a bounded feature or refactor that stays in the cycle. The classifier
  supplies a durable typed `gatePlan` for every adaptable gate. Read
  `skills/shared/compact-profile.md` before proposing compact: all ten entries are
  required, each exactly `{run:boolean, reason:nonblank string}`. A confident compact
  classification may handle security, migration, multi-repository, dirty-worktree,
  interface, seam, or dependency work; destructive work is always full.
- **full**: greenfield or unknown work, destructive work, broad or unclear requests, and
  features/refactors the classifier cannot confidently authorize as bounded compact work.
  Maintenance that exceeds micro bounds (a large conflict resolution or a wide re-review)
  is also `full`. A seam, interface, security, migration, multi-repository, dependency,
  or dirty-worktree signal belongs here unless the grounded compact classification explains
  its bounded handling in the durable plan — fail-closed promotion, not a
  `protocol-mismatch`.

Compact reuses the existing cycle and its terminal delivery contract. The gate plan
changes only adaptable gate choices; it does not create a separate protocol.

## Step 2 - Validate Fail-Closed

The semantic proposal does not authorize itself. Validate it through the deterministic
boundary:

```bash
decision="$(printf '%s\n' '<one-line candidate JSON>' | \
  bash "${CLAUDE_SKILL_DIR}/../../lib/task-route.sh" validate -)"
```

Use `.route` from the normalized output, never the proposed route. The validator
promotes malformed compact gate plans, confidence below 0.7, high ambiguity, more than
12 reviewable files, more than 6 criteria, destructive compact work, and invalid
micro/debug classifications to `full`. Working-tree conflict is measured by the script
from the current execution root with the cycle's canonical clean-base rules; it is not
accepted as a path or field from the semantic proposal. It remains a full promotion for
micro/debug, but a confidently classified compact proposal may carry it in its gate plan.

Set `introducesDependency` for compatibility whenever either dependency field is true.
Set `introducesNewDependency` only when the change adds a dependency edge; a version-only
change sets `updatesDependencyVersion` instead. `generatedFiles` counts generated outputs
such as lockfiles within `estimatedFiles`, never hand-maintained manifests.

A `full` route still carries the classification's own risk picture, so resolve the
execution profile from the SAME normalized decision and pass it to the cycle:

```bash
profile_line="$(printf '%s' "$decision" | \
  bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-profile.sh" select -)"
profile="${profile_line#profile=}"; profile="${profile%% *}"
```

Keep `profile_line` internal to routing. The route decision is the sole router output:
one `AUTONOMOUS_ROUTE ` line containing the normalized decision.

`profile=compact` applies the validated compact gate plan; `profile=maintenance` retains
the existing maintenance short path; `profile=standard` is the unchanged full ladder.
The logged line carries its own reason, so a run says why its profile was allowed.

Print exactly one concise, SDK-readable JSON line containing the normalized decision,
prefixed with `AUTONOMOUS_ROUTE `. Do not write routing state into the target repository's
tracked tree; that would dirty a clean base before cycle or delivery guards run. The
validator's own record (`.loop-spec/active-run.json`) is git-ignored: it arms the run so
an exit without a terminal result is detectable from Step 4 on.

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
bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-reconcile.sh" --result-root "$repo_root" \
  --reason "routed skill ended without emitting a terminal result"
```

Reconciliation is a no-op when the route published normally — it re-prints the existing
`LOOP_SPEC_RESULT` line and exits 0. When the route ended without one, it writes the
terminal result from the armed run so the contract holds anyway. Run it on every route,
including the ones you believe succeeded, and report its output as the run's result.
