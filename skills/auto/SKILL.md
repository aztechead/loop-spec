---
name: auto
description: Preferred autonomous entry point for Claude Code, pi, and OpenCode SDK/headless requests. Semantically routes a grounded task to the micro cycle, bounded debug loop, or full seven-phase cycle; uncertain or risky work always fails upward to the full cycle.
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
  "criteriaCount": 1,
  "ambiguity": "low | medium | high",
  "introducesSeam": false,
  "introducesDependency": false,
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
  edited files. Examples include a focused documentation refresh, config adjustment,
  rename, or localized fix whose mechanism is already known. No subagents or design
  phases.
- **debug**: a bounded bug or unexplained behavior that needs reproduction, hypotheses,
  and a sibling sweep. This is the middle route: more rigor than micro without a
  feature SPEC/PLAN DAG.
- **full**: features, refactors, greenfield work, broad or unclear requests, or any
  work involving a new seam/dependency, interface or schema behavior, security,
  destructive/data migration operations, multiple repositories, or conflicting
  uncommitted changes.

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

Print exactly one concise, SDK-readable JSON line containing the normalized decision,
prefixed with `AUTONOMOUS_ROUTE `. Do not write routing state into the target repository;
that would dirty a clean base before cycle or delivery guards run.

## Step 3 - Delegate Once

Delegate exactly once, then let that protocol run through verification, commit, PR
creation/reconciliation, and terminal PR feedback checking:

- `micro` -> `Skill(loop-spec:micro)` with `autonomous <verbatim request>`.
- `debug` -> `Skill(loop-spec:debug)` with `autonomous <verbatim request>`.
- `full` -> `Skill(loop-spec:cycle)` with `autonomous <verbatim request>`.

Do not call intake first; cycle already accepts prose. Do not perform implementation
work in this skill. The delegated protocol owns runtime scope tripwires: micro promotes
losslessly when its bounds are crossed, and debug promotes when the confirmed fix is
feature-scale.
