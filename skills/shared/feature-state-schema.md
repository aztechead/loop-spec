# Feature State Schema

Per-feature runtime state lives at `.super-spec/features/{slug}/feature.json` (gitignored). Atomic write pattern: write `feature.json.tmp`, fsync, rename. Backup `feature.json.bak` updated on each successful write. All writes go through `lib/feature-write.sh`.

Tasks and waves are managed by the harness task list (`TaskCreate` / `TaskUpdate` / `TaskList` / `TaskGet`) per phase team, not in `feature.json`. See "Harness task list usage" below.

## Schema (v6)

```json
{
  "schemaVersion": 6,
  "slug": "string (kebab-case)",
  "createdAt": "ISO-8601 timestamp",
  "updatedAt": "ISO-8601 timestamp",
  "tier": "quality | balanced | quick",
  "execStyle": "auto | step | interactive | review-only",
  "currentPhase": "spec | discuss | plan | execute | verify | completed",
  "completedPhases": ["array of phase names"],
  "branch": "string (feat/{slug})",
  "worktreePath": "string (.claude/worktrees/{slug}); absent => legacy in-place",
  "baseSha": "git sha at branch creation",
  "baseBranch": "string (e.g., main)",
  "models": {
    "specWriter": "claude-opus-4-8 (fixed)",
    "planner": "claude-opus-4-8 (fixed)",
    "advocate": "claude-opus-4-8 (fixed)",
    "challenger": "claude-opus-4-8 (fixed)",
    "specComplianceReviewer": "claude-opus-4-8 (fixed; Ralph loop)",
    "implementer": "claude-sonnet-4-6 (fixed)",
    "codeReviewer": "claude-sonnet-4-6 (fixed)",
    "verifier": "claude-sonnet-4-6 (fixed)",
    "mapper": "claude-sonnet-4-6 (fixed)",
    "patternMapper": "claude-sonnet-4-6 (fixed)"
  },
  "artifacts": {
    "specInterview": "path or null (.super-spec/features/{slug}/spec-interview-transcript.md)",
    "spec": "path or null",
    "patterns": "path or null (docs/super-spec/features/{slug}/PATTERNS.md, written at PLAN Step 0)",
    "patternsSource": "gsd-ingest | pattern-mapper | manual | null",
    "plan": "path or null",
    "execution": "path or null",
    "verification": "path or null",
    "codebaseSource": {
      "tech": "gsd-ingest | mapper | manual | null",
      "arch": "gsd-ingest | mapper | manual | null",
      "quality": "gsd-ingest | mapper | manual | null",
      "concerns": "gsd-ingest | mapper | manual | null",
      "domain": "gsd-ingest | mapper | manual | null"
    }
  },
  "currentTeamName": "string or null (e.g., super-spec-execute-{slug}); null between phases",
  "currentTeammates": ["array of teammate names currently spawned, e.g., implementer-1, reviewer-1; empty between phases"],
  "currentGate": {
    "phase": "string or null",
    "gate": "string or null",
    "round": "integer (current round of advocate/challenger debate, 0 if no gate active)",
    "advocateName": "string or null (e.g., advocate-1)",
    "challengerName": "string or null (e.g., challenger-1)",
    "startedAt": "ISO-8601 timestamp or null"
  },
  "retryBudget": {
    "perGate": 3,
    "perPhase": {"spec": "integer (tier-dependent, mirrors discuss budget)", "discuss": 3, "plan": 4, "execute": null, "verify": 4},
    "perGateUsed": {},
    "perPhaseUsed": {"spec": 0, "discuss": 0, "plan": 0, "execute": 0, "verify": 0},
    "global": 30,
    "globalUsed": 0
  },
  "commands": {
    "test": "string (e.g., npm test)",
    "lint": "string",
    "typecheck": "string"
  },
  "stalenessHours": 48,
  "warnings": ["array of strings"],
  "mergeQueue": ["array of task ids in FIFO arrival order awaiting merge to feat/{slug}; empty between phases and at EXECUTE exit"],
  "pendingRemediationTasks": ["array of remediation task objects appended by VERIFY (lib/feature-write.sh append) and consumed+cleared by EXECUTE Step 2a; empty between phases"],
  "bootstrapPendingDomains": ["array of codebase domain names whose background mappers were fired in cycle Step 5.5b; consumed and cleared in the DISCUSS phase; empty if codebase docs pre-existed or were GSD-ingested"],
  "activeWorkflow": {
    "scriptPath": "string or null",
    "args": "object or null",
    "sessionId": "string or null",
    "runId": "string or null",
    "startedAt": "ISO-8601 timestamp or null (set before a dispatched Workflow call per dispatch-fanout.md; cleared once the skill consumes the result; null when no workflow is in flight)"
  },
  "harnessTaskMetadataMode": "string or null (reserved for future harness capability negotiation)",
  "harnessStatusMode": "string or null (reserved for future harness capability negotiation)",
  "fileConflictExcludeGlobs": ["optional array of globs excluded from EXECUTE pre-task file-conflict detection"],
  "gateHistory": [
    {
      "phase": "string",
      "gate": "spec-critique | plan-critique | plan-feasibility | spec-compliance | acceptance | code-review",
      "attempt": "integer",
      "result": "pass | fail",
      "advocateModel": "string or null",
      "challengerModel": "string or null",
      "rounds": "integer (rounds the debate ran)",
      "convergence": "mutual-done | cap-reached | one-sided",
      "findingsAddressed": ["string", "..."],
      "notes": "string or null"
    }
  ]
}
```

### Field notes

- The `tasks` and `waves` arrays from v2 are gone. Live task state lives in the harness task list, not in `feature.json`.
- `retryBudget.perPhase.execute: null` means unlimited at the phase level. The per-task cap (`tier.execute.maxRetriesPerTask`) is the operative limit during EXECUTE; a phase-level cap is intentionally omitted because EXECUTE's progress is bounded by the task DAG, not gate retries.
- `retryBudget.perGateUsed` is a map keyed by `{phase}.{gate}` (e.g., `discuss.spec-critique`) of integer retry counts. It is persisted via `lib/feature-write.sh` on every gate failure so a kill mid-gate does not reset the budget.
- `currentTeamName`, `currentTeammates`, and `currentGate` are the rapidly-mutating fields. All three are reset (`null` / `[]` / zeroed) after `TeamDelete`.
- `mergeQueue` is the FIFO merge queue for EXECUTE. The lead appends a task id when a reviewer marks it `completed`, then processes the queue sequentially in dependency-aware FIFO order.
- `fileConflictExcludeGlobs` provides per-feature overrides for file-conflict detection. Repo-wide overrides live in `.super-spec/file-conflict-exclude.txt` (one glob per line). Both sources are unioned.
- `harnessTaskMetadataMode` and `harnessStatusMode` are reserved for future capability negotiation. Set to `null` unless the cycle's Step 2 capability probe signals a specific mode.
- Schema version 4 adds the `spec` phase fields. `currentPhase` gains `"spec"` as the first value; `retryBudget.perPhase` and `retryBudget.perPhaseUsed` each gain a `"spec"` field; `artifacts.specInterview` is added as a nullable path field pointing to the interview transcript written by the spec phase orchestrator (main thread). Migration from v3 to v4 is opt-in via `lib/migrate-schema-v3-to-v4.sh`. In-flight v3 features continue on v3 unless the user explicitly migrates.
- `pendingRemediationTasks`, `bootstrapPendingDomains`, and `activeWorkflow` are runtime-only working fields written by the code (VERIFY remediation routing, cycle Step 5.5b background mapping, and the workflow dispatch contract in `dispatch-fanout.md`). They are documented here so validators and migrations treat the v4 shape as complete; all three are absent or empty/null between phases.
- `baseBranch` is initialized at feature creation (cycle Step 5, via `lib/git-ops.sh detect-base-branch`) so a plan-only or early-exit feature opens its PR against the correct base; EXECUTE Step 1 still records it idempotently for resumed v3 features.
- `models` is a fixed per-role map (no preset axis), written ONCE at cycle Step 5 as a mirror of `skills/shared/model-matrix.md`, and is the single source of truth for per-role model IDs. Every phase skill passes `model: feature.models.<role>` on each spawn rather than re-deriving, so teammates never silently inherit the orchestrator's session model. opus runs spec-writer, planner, advocate, challenger, and spec-compliance-reviewer; sonnet runs implementer, code-reviewer, verifier, mapper-*, and pattern-mapper. Cycle Step 5.9 normalizes this block idempotently on every resume, so pre-v2.3.0 features (no block) and features carrying a stale preset-era block are migrated to the fixed map before routing to any phase.
- Schema version 5 removes the `preset` field (model selection is fixed; see `model-matrix.md`) and rewrites `models` to the fixed map. Migration is automatic and lossless: cycle Step 5.9 drops `preset` and normalizes `models` on the next resume of any in-flight feature. `tier` is unaffected.
- Schema version 6 introduces `worktreePath`. Each new feature runs inside a dedicated git worktree created at cycle Step 5 via `lib/git-ops.sh create-feature-worktree`; all state, docs, and code live on `feat/{slug}` inside that worktree. Resume discovers feature worktrees via `git worktree list` (specifically `git-ops.sh list-feature-worktrees`). Back-compat: features without `worktreePath` (schema version 5 and earlier) continue to run legacy in-place; there is no forced migration of in-flight features into worktrees.
- Schema version jumps from 2 to 3 (no migration from v2, clean break). Features on v0.3.x must be completed or restarted on v1.0.0. Schema version 3 to 4 is an opt-in migration (see above).

## Schema (v3 - legacy)

```json
{
  "schemaVersion": 3,
  "slug": "string (kebab-case)",
  "createdAt": "ISO-8601 timestamp",
  "updatedAt": "ISO-8601 timestamp",
  "tier": "quality | balanced | quick",
  "preset": "quality | balanced | fast",
  "execStyle": "auto | step | interactive | review-only",
  "currentPhase": "discuss | plan | execute | verify | completed",
  "completedPhases": ["array of phase names"],
  "branch": "string (feat/{slug})",
  "baseSha": "git sha at branch creation",
  "baseBranch": "string (e.g., main)",
  "artifacts": {
    "spec": "path or null",
    "patterns": "path or null (docs/super-spec/features/{slug}/PATTERNS.md, written at PLAN Step 0)",
    "patternsSource": "gsd-ingest | pattern-mapper | manual | null",
    "plan": "path or null",
    "execution": "path or null",
    "verification": "path or null",
    "codebaseSource": {
      "tech": "gsd-ingest | mapper | manual | null",
      "arch": "gsd-ingest | mapper | manual | null",
      "quality": "gsd-ingest | mapper | manual | null",
      "concerns": "gsd-ingest | mapper | manual | null",
      "domain": "gsd-ingest | mapper | manual | null"
    }
  },
  "currentTeamName": "string or null (e.g., super-spec-execute-{slug}); null between phases",
  "currentTeammates": ["array of teammate names currently spawned, e.g., implementer-1, reviewer-1; empty between phases"],
  "currentGate": {
    "phase": "string or null",
    "gate": "string or null",
    "round": "integer (current round of advocate/challenger debate, 0 if no gate active)",
    "advocateName": "string or null (e.g., advocate-1)",
    "challengerName": "string or null (e.g., challenger-1)",
    "startedAt": "ISO-8601 timestamp or null"
  },
  "retryBudget": {
    "perGate": 3,
    "perPhase": {"discuss": 3, "plan": 4, "execute": null, "verify": 4},
    "perGateUsed": {},
    "perPhaseUsed": {"discuss": 0, "plan": 0, "execute": 0, "verify": 0},
    "global": 30,
    "globalUsed": 0
  },
  "commands": {
    "test": "string (e.g., npm test)",
    "lint": "string",
    "typecheck": "string"
  },
  "stalenessHours": 48,
  "warnings": ["array of strings"],
  "mergeQueue": ["array of task ids in FIFO arrival order awaiting merge to feat/{slug}; empty between phases and at EXECUTE exit"],
  "harnessTaskMetadataMode": "string or null (reserved for future harness capability negotiation)",
  "harnessStatusMode": "string or null (reserved for future harness capability negotiation)",
  "fileConflictExcludeGlobs": ["optional array of globs excluded from EXECUTE pre-task file-conflict detection"],
  "gateHistory": [
    {
      "phase": "string",
      "gate": "spec-critique | plan-critique | plan-feasibility | spec-compliance | acceptance | code-review",
      "attempt": "integer",
      "result": "pass | fail",
      "advocateModel": "string or null",
      "challengerModel": "string or null",
      "rounds": "integer (rounds the debate ran)",
      "convergence": "mutual-done | cap-reached | one-sided",
      "findingsAddressed": ["string", "..."],
      "notes": "string or null"
    }
  ]
}
```

### Field notes (v3)

- The `tasks` and `waves` arrays from v2 are gone. Live task state lives in the harness task list, not in `feature.json`.
- `retryBudget.perPhase.execute: null` means unlimited at the phase level. The per-task cap (`tier.execute.maxRetriesPerTask`) is the operative limit during EXECUTE; a phase-level cap is intentionally omitted because EXECUTE's progress is bounded by the task DAG, not gate retries.
- `retryBudget.perGateUsed` is a map keyed by `{phase}.{gate}` (e.g., `discuss.spec-critique`) of integer retry counts. It is persisted via `lib/feature-write.sh` on every gate failure so a kill mid-gate does not reset the budget.
- `currentTeamName`, `currentTeammates`, and `currentGate` are the rapidly-mutating fields. All three are reset (`null` / `[]` / zeroed) after `TeamDelete`.
- `mergeQueue` is the FIFO merge queue for EXECUTE. The lead appends a task id when a reviewer marks it `completed`, then processes the queue sequentially in dependency-aware FIFO order.
- `fileConflictExcludeGlobs` provides per-feature overrides for file-conflict detection. Repo-wide overrides live in `.super-spec/file-conflict-exclude.txt` (one glob per line). Both sources are unioned.
- `harnessTaskMetadataMode` and `harnessStatusMode` are reserved for future capability negotiation. Set to `null`.
- Schema version jumps from 2 to 3. There is no migration from v2 (clean break). In-flight features must be completed on v0.3.x or restarted on v1.0.0.

## Harness task list usage

Each phase team maintains its own harness task list via `TaskCreate` / `TaskUpdate` / `TaskList` / `TaskGet`. The following fields are set on task `metadata` at creation time and updated through the task lifecycle:

| Field | Type | Set by | Description |
|---|---|---|---|
| `retries` | integer | Reviewer (`team-prompts/reviewer.md` On Fail rework) / EXECUTE SKILL Step 6 | Per-task retry counter. Capped by `tier.execute.maxRetriesPerTask`. Initialized to 0 at `TaskCreate`. Resets to 0 on EXECUTE resume (harness task list is recreated from `PLAN.md`). |
| `claimedBy` | string or null | Implementer, after successful `TaskUpdate` status claim | Teammate name of the implementer that claimed this task (e.g., `implementer-2`). Kept for reviewer addressing: reviewer reads `claimedBy` to direct `needs_rework` messages via `SendMessage({to: claimedBy, ...})`. Redundant with the harness `owner` field; both are set. |
| `blockedBy` | array of task ids | Lead at `TaskCreate` | Tasks that must be `completed` before this task can be claimed. Used by implementers to filter available tasks. Synthetic `blockedBy` edges for file-conflict detection are added by the lead before calling `TaskCreate`. |
| `files` | array of paths | Lead at `TaskCreate` | Files the task is expected to touch. Used for pre-task file-conflict detection and for the post-merge heuristic on EXECUTE resume. |
| `verifyCommand` | string | Lead at `TaskCreate` | Shell command the implementer runs to verify the task. Must be shell-parseable (validated by the PLAN hook). |
| `acceptanceCriteria` | array of strings | Lead at `TaskCreate` | Per-task acceptance criteria from `PLAN.md`. Reviewer uses these for spec-compliance review. |
| `specPath` | path or null | Lead at `TaskCreate` | Path to a per-task spec file when one exists (written by the planner for complex tasks). Null otherwise. When null, implementers/reviewers fall back to the feature SPEC.md. |
| `readFirst` | array of paths | Lead at `TaskCreate` | Concrete files the implementer must read before starting, carried from the planner's `read_first` list. May be empty. |
| `userGate` | bool | Lead at `TaskCreate` | Optional. Set by the planner when the task requires a user-verified gate before it can be considered done. When true, `checking-gates` skill enforces evidence presence at task close. |
| `requireEvidenceTokens` | array of arrays | Lead at `TaskCreate` | Optional. Set by the planner or `specifying-gates` skill. Each inner array is a set of token strings (e.g., `["AC:", "PROVEN BY"]`); at least one token from each inner array must appear in the transcript evidence window. |
| `requireABCompare` | bool | Lead at `TaskCreate` | Optional. Set by the planner when the gate requires an A/B comparison between two subagent outputs before the task can close. |
| `subagentType` | string | `specifying-gates` skill at gate specification | Optional. Identifies the type of subagent to dispatch for automated gate checking (e.g., `"checker"`, `"reviewer"`). |
| `model` | string | `specifying-gates` skill at gate specification | Optional. Model alias for the dispatched subagent (e.g., `"sonnet"`, `"opus"`). |
| `dispatchBrief` | string | `specifying-gates` skill at gate specification | Optional. Freeform brief passed to the dispatched subagent describing what to verify. |
| `failurePolicy` | string enum | Lead at `TaskCreate` or `specifying-gates` skill | Optional. Controls what happens when a gate check fails. One of: `stop-plan` (halt the plan and block further progress), `reopen-continue` (reopen the task and continue other tasks), `log-continue` (log the failure and continue without blocking). |
| `gateScope` | string enum | `specifying-gates` skill at gate specification | Optional. Controls how many times the gate is evaluated across targets. One of: `once` (checked a single time), `per-target` (checked once per verification target), `one-then-all` (one check then all in parallel), `custom` (custom scope defined in `dispatchBrief`). |
| `requiresUserSpecification` | bool | Lead at `TaskCreate` or planner | Optional. When true, the `checking-gates` skill routes to `specifying-gates` before running the gate check, to collect missing verification mechanics from the user. Removed from metadata after `specifying-gates` completes. |

### Per-phase harness task list notes

**DISCUSS.** No harness task list. The spec-writer, advocate, and challenger communicate via `SendMessage`; the lead tracks gate state in `feature.json.currentGate` and appends round-end messages to `.super-spec/features/{slug}/gate-logs/`.

**PLAN.** No harness task list for PLAN's internal teammates (pattern-mapper, planner, advocate, challenger). PLAN emits the validated `tasks[]` JSON in the planner's completion message; the EXECUTE team's harness task list is created from it later, by `TaskCreate` calls in EXECUTE Step 3 (one task per planned task), populated with `blockedBy`, `files`, `verifyCommand`, `acceptanceCriteria`, `readFirst`, and `specPath` in task `metadata`. It is not pre-created at PLAN exit and there is no EXECUTE Step 0.

**EXECUTE.** One task per planned task. Implementers self-claim by calling `TaskUpdate({taskId, status: "in_progress", owner: "<own-name>"})`. The harness serializes concurrent claims on the same task id; the losing implementer must re-query and retry. Task lifecycle: `pending -> in_progress -> awaiting_review -> completed | needs_rework`. Per-task `retries` in metadata is the retry counter; `claimedBy` identifies the owner for reviewer-to-implementer messaging.

**VERIFY.** No per-task harness task list for the verifier or code-reviewer teammates. Those teammates are single-instance; the lead tracks their completion via `TeammateIdle` and direct `SendMessage` to `lead`. Mapper teammates (incremental codebase refresh) use a small task list with one task per stale domain.

## Codebase index schema (.super-spec/codebase/index.json)

`.super-spec/codebase/index.json` is the file-to-domain mapping used by `map-codebase` and `verify` skills. It is not gitignored (shared across machines).

```json
{
  "file/path.ext": ["arch", "tech", "quality"],
  "another/file.ext": ["domain"],
  "last_refreshed_at": {
    "arch": "ISO-8601 timestamp or null",
    "tech": "ISO-8601 timestamp or null",
    "quality": "ISO-8601 timestamp or null",
    "concerns": "ISO-8601 timestamp or null",
    "domain": "ISO-8601 timestamp or null"
  },
  "graphify": {
    "graph_json_path": "graphify-out/graph.json or null",
    "wiki_path": "graphify-out/wiki/index.md or null",
    "last_updated": "ISO-8601 timestamp or null"
  }
}
```

### index.json field notes

- Keys at the top level (other than `last_refreshed_at` and `graphify`) are file paths mapped to arrays of domain names.
- `last_refreshed_at.{domain}` is set by the map-codebase skill after each mapper completes and reports `DOMAIN_DONE`.
- The `graphify` block is optional. It is present only when graphify has been run at least once. Set `graph_json_path` to the `graphify-out/graph.json` written by `graphify update .` (deterministic AST extraction, no LLM; this is what the cycle Step 5.5.0 bootstrap and map-codebase/verify run). Set `wiki_path` to `graphify-out/wiki/index.md` only when the LLM-backed wiki generation has been run (the plain `graphify update .` bootstrap does not produce a wiki). Set `last_updated` to the ISO-8601 timestamp of the last successful `graphify update .` run.
- In graphify-present mode, only `quality`, `concerns`, and `domain` are updated in `last_refreshed_at` by the map-codebase skill (the `arch` and `tech` mapper agents are removed; their domains are covered by graphify). `last_refreshed_at.arch` and `last_refreshed_at.tech` remain at their last pre-graphify values and are not refreshed by map-codebase.

## Atomic write

```bash
write_feature() {
  local feature_dir="$1"
  local feature_json="$2"
  echo "$feature_json" > "$feature_dir/feature.json.tmp"
  sync  # fsync
  mv "$feature_dir/feature.json" "$feature_dir/feature.json.bak" 2>/dev/null || true
  mv "$feature_dir/feature.json.tmp" "$feature_dir/feature.json"
}
```

Implemented in `lib/feature-write.sh`. Replaces `lib/state-write.sh` (removed in v1.0.0).

## Resume

On `cycle` skill startup: scan `.super-spec/features/*/feature.json`. For any with `currentPhase != "completed"` and `updatedAt` within `stalenessHours`, probe for live team by calling `TaskList({team: currentTeamName})`:

- `TaskList` errors (team not found): clear `currentTeamName` in `feature.json`, recreate the phase team from scratch, replay phase Step 0 from on-disk artifacts.
- `TaskList` succeeds (team still live): print the orphan-cleanup message with the explicit team name; require manual `TeamDelete` before resume.
- `currentTeamName == null` and within `stalenessHours`: standard resumable case; recreate phase team.

If `currentGate` is non-null on resume, load prior debate transcript from `gate-logs/` into the spawn prompts of the new advocate and challenger.
