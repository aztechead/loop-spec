---
name: auto
description: Preferred autonomous entry point for Claude Code, OpenCode, and Google ADK SDK/headless requests. Semantically routes a grounded task to the micro cycle, bounded debug loop, or full seven-phase cycle; uncertain or risky work always fails upward to the full cycle.
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
  "route": "micro | debug | full",
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
- **full**: features, refactors, greenfield work, broad or unclear requests, or any
  work involving a new seam or dependency edge, interface or schema behavior, security,
  destructive/data migration operations, multiple repositories, or conflicting
  uncommitted changes. Maintenance that exceeds micro bounds (a large conflict
  resolution, a re-review whose edit surface is wide, a dirty tree) is still `full`
  with the profile `cycle-profile.sh` selects — fail-closed promotion, not a
  `protocol-mismatch`.

Do not invent a generic `compact` route. The reduced routes must reuse an existing
protocol with established verification and PR delivery. Route telemetry and user
feedback can justify a reusable compact lifecycle later; prompt intuition alone cannot.

## Step 2 - Validate Fail-Closed

The semantic proposal does not authorize itself. Validate it through the deterministic
boundary:

```bash
decision="$(printf '%s\n' '<one-line candidate JSON>' | \
  bash "${CLAUDE_SKILL_DIR}/../../lib/task-route.sh" validate -)"
```

Use `.route` from the normalized output, never the proposed route. The validator
promotes malformed, low-confidence, oversized, ambiguous, mismatched, risky, or
working-tree-conflicted classifications to `full`. Working-tree conflict is measured
by the script from the current execution root with the cycle's canonical clean-base
rules; it is not accepted as a path or field from the semantic proposal. Other semantic
fields remain model judgments, so uncertain evidence must lower confidence and therefore
promote the request.

Set `introducesDependency` for compatibility whenever either dependency field is true.
Set `introducesNewDependency` only when the change adds a dependency edge; a version-only
change sets `updatesDependencyVersion` instead. `generatedFiles` counts generated outputs
such as lockfiles within `estimatedFiles`, never hand-maintained manifests.

A `full` route still carries the classification's own risk picture, so resolve the
execution profile from the SAME normalized decision and pass it to the cycle:

```bash
profile_line="$(printf '%s' "$decision" | \
  bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-profile.sh" select -)"
echo "loop-spec: $profile_line"
profile="${profile_line#profile=}"; profile="${profile%% *}"
```

`profile=maintenance` lightens the SPEC interview and skips the DISCUSS and PLAN critique
gates when no security signal fires (`skills/shared/tier-matrix.md`, "Maintenance
profile"); `profile=standard` is the unchanged full ladder. The logged line carries its
own reason, so a run that took the lightened ladder says why it was allowed to.

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
