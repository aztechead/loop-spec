# Feature State Schema

Per-feature runtime state lives at `.loop-spec/features/{slug}/feature.json`. It is the **committed resume contract** (tracked in git so resume survives a clone / hand-off; the cycle commits it on each phase transition). `PROGRESS.md` (the phase-transition journal) is committed alongside it. The remaining siblings -- `feature.json.bak`, `gate-logs/`, transcripts -- stay gitignored as per-machine churn. Atomic write pattern: write `feature.json.tmp`, fsync, rename. Backup `feature.json.bak` updated on each successful write. All writes go through `lib/feature-write.sh`.

**Writing rules (every phase, no exceptions):** never mutate `feature.json` with raw `jq`/`python3` — that bypasses the atomic write and `.bak` rotation that resume depends on. `feature-write.sh set` takes **nested dot paths** (object keys only, no array indices) and a **JSON value** (strings must be quoted):

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set "$fdir" artifacts.patterns '"docs/loop-spec/features/'"${slug}"'/PATTERNS.md"'
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" append "$fdir" warnings '"some warning"'
```

If a `set`/`append` call errors, read the message — the common causes are an unquoted string value or an array-index path (replace the whole array via `set` on its parent instead) — and retry with the corrected call; do NOT fall back to raw jq.

Tasks and waves are managed by the harness task list (`TaskCreate` / `TaskUpdate` / `TaskList` / `TaskGet`) per phase team, not in `feature.json`. See "Harness task list usage" below.

## Schema (v7)

```json
{
  "schemaVersion": 7,
  "slug": "string (kebab-case)",
  "feature_title": "immutable original goal in the user's words",
  "createdAt": "ISO-8601 timestamp",
  "updatedAt": "ISO-8601 timestamp",
  "execStyle": "auto | step | interactive | review-only",
  "currentPhase": "spec | discuss | plan | execute | verify | iterate | deliver | completed",
  "completedPhases": ["array of phase names"],
  "branch": "string (feat/{slug})",
  "worktreePath": "string (.claude/worktrees/{slug}) in single-repo mode; null in workspace mode",
  "executionRootMode": "worktree | in-place | workspace",
  "baseSha": "git sha at branch creation",
  "baseBranch": "string (e.g., main)",
  "models": {
    "specWriter": "opus (fixed alias)",
    "planner": "opus (fixed alias)",
    "advocate": "opus (fixed alias)",
    "challenger": "opus (fixed alias)",
    "specComplianceReviewer": "opus (fixed alias; Ralph loop)",
    "iterateJudge": "opus (fixed alias)",
    "implementer": "sonnet (fixed alias)",
    "codeReviewer": "opus (fixed alias)",
    "verifier": "sonnet (fixed alias)",
    "mapper": "sonnet (fixed alias)",
    "patternMapper": "sonnet (fixed alias)"
  },
  "artifacts": {
    "specInterview": "path or null (.loop-spec/features/{slug}/spec-interview-transcript.md)",
    "spec": "path or null",
    "patterns": "path or null (docs/loop-spec/features/{slug}/PATTERNS.md, written at PLAN Step 0)",
    "patternsSource": "gsd-ingest | pattern-mapper | manual | null",
    "plan": "path or null",
    "execution": "path or null",
    "verification": "path or null",
    "iteration": "path or null",
    "codebaseSource": {
      "tech": "gsd-ingest | mapper | manual | null",
      "arch": "gsd-ingest | mapper | manual | null",
      "quality": "gsd-ingest | mapper | manual | null",
      "concerns": "gsd-ingest | mapper | manual | null",
      "domain": "gsd-ingest | mapper | manual | null"
    }
  },
  "currentTeamName": "string or null (e.g., loop-spec-execute-{slug}); null between phases",
  "currentTeammates": ["array of teammate names currently spawned, e.g., implementer-1, reviewer-1; empty between phases"],
  "currentGate": {
    "phase": "string or null",
    "gate": "string or null",
    "round": "integer (current round of advocate/challenger debate, 0 if no gate active)",
    "advocateName": "string or null (e.g., advocate-1)",
    "challengerName": "string or null (e.g., challenger-1)",
    "startedAt": "ISO-8601 timestamp or null"
  },
  "commands": {
    "test": "string (e.g., npm test)",
    "lint": "string",
    "typecheck": "string"
  },
  "workspace": {
    "root": "absolute path of the workspace parent directory",
    "repos": [
      {
        "name": "frontend",
        "path": "frontend",
        "branch": "feat/{slug}",
        "baseSha": "git sha at branch creation for this repo",
        "baseBranch": "main",
        "commands": {"test": "", "lint": "", "typecheck": ""}
      }
    ]
  },
  "stalenessHours": 48,
  "prUrl": "string or null (legacy/tracked remediation shortcut; successful delivery URLs live in ignored delivery.json)",
  "checkpointPrUrl": "string or null (draft PR URL set by lib/checkpoint-pr.sh on pause/escalation/terminal salvage; null otherwise)",
  "delivery": {
    "status": "pending | ready-for-review | checks-failed | checks-timeout | partial | no-changes | another structured delivery error",
    "attemptedAt": "ISO-8601 timestamp or null",
    "finishedAt": "ISO-8601 timestamp or null",
    "nextPhase": "null before delivery; completed | execute | deliver after an attempt",
    "ciRemediationAttempts": "integer, required-check failures routed to EXECUTE (maximum 2)",
    "ciRemediationLimit": "integer, fixed at 2 in DELIVER observations",
    "targets": [
      {
        "name": "feature slug or workspace repo name",
        "path": "absolute repository path",
        "ok": "boolean",
        "outcome": "delivered | skipped-no-commits | blocked",
        "branch": "feature branch",
        "baseBranch": "PR base branch",
        "targetSha": "exact local candidate SHA or null",
        "remoteSha": "observed remote SHA or null",
        "headSha": "observed PR head SHA or null",
        "prNumber": "number or null",
        "prUrl": "URL or null",
        "isDraft": "boolean or null",
        "checks": "required-check observation object",
        "errorCode": "stable structured failure code or null"
      }
    ]
  },
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
- There is no `retryBudget` block (full-bore operation): gate retries are unbounded, and every attempt is recorded in `gateHistory[]`. The only bound the cycle respects is `iterate.maxIterations`. During EXECUTE, the per-task rework cap (`maxRetriesPerTask`, fixed 2) routes a repeatedly-failing task to the lead for escalation rather than looping it forever between the same implementer and reviewer.
- `currentTeamName`, `currentTeammates`, and `currentGate` are the rapidly-mutating fields. All three are reset (`null` / `[]` / zeroed) after `TeamDelete`.
- `mergeQueue` is the FIFO merge queue for EXECUTE. The lead appends a task id when a reviewer marks it `completed`, then processes the queue sequentially in dependency-aware FIFO order.
- `fileConflictExcludeGlobs` provides per-feature overrides for file-conflict detection. Repo-wide overrides live in `.loop-spec/file-conflict-exclude.txt` (one glob per line). Both sources are unioned.
- `harnessTaskMetadataMode` and `harnessStatusMode` are reserved for future capability negotiation. Set to `null` unless the cycle's Step 2 capability probe signals a specific mode.
- `artifacts.specInterview` is a nullable path to the SPEC-phase interview transcript (written by the spec orchestrator on the main thread). `currentPhase` includes `"spec"` as its first value.
- `pendingRemediationTasks`, `bootstrapPendingDomains`, and `activeWorkflow` are runtime-only working fields written by the code (VERIFY remediation routing, cycle Step 5.5b background mapping, and the workflow dispatch contract in `dispatch-fanout.md`); all three are absent or empty/null between phases.
- `baseBranch` is initialized at feature creation (cycle Step 5, via `lib/git-ops.sh detect-base-branch`) so a plan-only or early-exit feature opens its PR against the correct base.
- `models` is a fixed per-role map (no preset axis), built ONCE at cycle Step 5 from `lib/feature-init.sh` (the single source of truth, mirroring `skills/shared/model-matrix.md`). Every phase skill passes `model: feature.models.<role>` on each spawn rather than re-deriving, so teammates never silently inherit the orchestrator's session model. opus runs spec-writer, planner, advocate, challenger, spec-compliance-reviewer, and iterate-judge; sonnet runs implementer, code-reviewer, verifier, mapper-*, and pattern-mapper. Cycle Step 5.9 re-normalizes this block idempotently on every resume from the same `feature-init.sh` source (forcing canonical IDs, dropping any vestigial `preset` field), so the two construction sites cannot drift.
- `worktreePath` (single-repo mode) points at the dedicated git worktree created at cycle Step 5 via `lib/git-ops.sh create-feature-worktree`; all state, docs, and code live on `feat/{slug}` inside it. Resume discovers feature worktrees via `git-ops.sh list-feature-worktrees`.
- `executionRootMode` is `worktree` for Claude's native feature worktree, `in-place` for the additive OpenCode/pi path (those harnesses cannot switch a live session root), and `workspace` for multi-repo mode.
- Tracked `delivery` is absent on completed schema-7 features created before the DELIVER phase and is tolerated for backward compatibility. New features initialize it to `pending`; DELIVER updates it only when failed checks route durable remediation back to EXECUTE. At most two required-check failures are routed back; a third fails closed at DELIVER instead of creating an infinite CI-remediation loop. Successful or external-failure observations live in ignored `.loop-spec/features/{slug}/delivery.json`, schema 1, with top-level `ok`, `status`, `nextPhase`, `prUrl`, timestamps, CI-remediation counters, and the same `targets[]` records. Keeping success out of tracked state prevents a post-CI commit from changing the exact checked SHA. `ready-for-review` means every changed target has `targetSha == remoteSha == headSha`, required checks passed or none were configured, and the PR is ready rather than draft.
- The optional `workspace` block enables multi-root workspace mode. Rules: (1) `workspace` absent or null means single-repo mode (`worktreePath` set). (2) In workspace mode the top-level `branch`, `baseSha`, `baseBranch`, and `worktreePath` are null; per-repo values in `workspace.repos[]` are authoritative. (3) The top-level `commands` block holds empty strings (per-repo commands live in `workspace.repos[].commands`). (4) State and artifact dirs are rooted at `workspace.root`. (5) Resume requires the session cwd to be `workspace.root`; the cycle skill instructs the user to cd there before re-invoking.
- **Schema is 7-only.** A `feature.json` with `schemaVersion != 7` is unsupported and skipped on resume with a warning; there is no in-place migration path for older schemas. New features are always created at schema 7 by `lib/feature-init.sh`.

## Workspace pin file (.loop-spec/workspace.json)

When a workspace parent directory is itself a git repo, or when the user wants to select a subset of discovered child repos, they create `.loop-spec/workspace.json` at the workspace root. This file pins the workspace mode and participating repo list. It is runtime config and is not committed (`.loop-spec/` is gitignored inside repos; at a non-repo workspace root gitignore is moot).

```json
{
  "schemaVersion": 1,
  "repos": [
    {"name": "frontend", "path": "frontend"},
    {"name": "backend", "path": "backend"}
  ]
}
```

Field notes:
- `schemaVersion`: currently `1`. Unknown extra fields at the top level are tolerated. Missing `schemaVersion` is tolerated (treated as v1).
- `repos[].name`: short identifier used in PLAN task `repo` fields and in summary tables. Must be unique within the list.
- `repos[].path`: path to the repo, relative to the workspace root. The resolved path must exist, be a directory, and pass `git -C <abs-path> rev-parse --is-inside-work-tree`; invalid entries cause `lib/workspace.sh detect` to exit 1 with a clear message.
- When to pin: (a) the workspace parent directory is itself a git repo (detection defaults to single mode; the pin overrides this), or (b) you want to use only a subset of the child repos discovered by depth-1 scan.
- When not to pin: the workspace parent is not a git repo and you want all immediate child git repos included (auto-discovery covers this without a pin file).

## Harness task list usage

Each phase team maintains its own harness task list via `TaskCreate` / `TaskUpdate` / `TaskList` / `TaskGet`. The following fields are set on task `metadata` at creation time and updated through the task lifecycle:

| Field | Type | Set by | Description |
|---|---|---|---|
| `retries` | integer | Reviewer (`team-prompts/reviewer.md` On Fail rework) / EXECUTE SKILL Step 6 | Per-task retry counter. Capped by `maxRetriesPerTask` (fixed 2). Initialized to 0 at `TaskCreate`. Resets to 0 on EXECUTE resume (harness task list is recreated from `PLAN.md`). |
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
| `repo` | string | Lead at `TaskCreate` (planner-supplied) | Optional. Workspace mode only. The name of the participating repository this task targets, matching a `workspace.repos[].name` value in `feature.json`. One task targets exactly one repo; cross-repo work is expressed as multiple tasks with `blockedBy` edges. Absent in single mode. |

### Per-phase harness task list notes

**DISCUSS.** No harness task list. The spec-writer, advocate, and challenger communicate via `SendMessage`; the lead tracks gate state in `feature.json.currentGate` and appends round-end messages to `.loop-spec/features/{slug}/gate-logs/`.

**PLAN.** No harness task list for PLAN's internal teammates (pattern-mapper, planner, advocate, challenger). PLAN emits the validated `tasks[]` JSON in the planner's completion message; the EXECUTE team's harness task list is created from it later, by `TaskCreate` calls in EXECUTE Step 3 (one task per planned task), populated with `blockedBy`, `files`, `verifyCommand`, `acceptanceCriteria`, `readFirst`, and `specPath` in task `metadata`. It is not pre-created at PLAN exit and there is no EXECUTE Step 0.

**EXECUTE.** One task per planned task. Implementers self-claim by calling `TaskUpdate({taskId, status: "in_progress", owner: "<own-name>"})`. The harness serializes concurrent claims on the same task id; the losing implementer must re-query and retry. Task lifecycle: `pending -> in_progress -> awaiting_review -> completed | needs_rework`. Per-task `retries` in metadata is the retry counter; `claimedBy` identifies the owner for reviewer-to-implementer messaging.

**VERIFY.** No per-task harness task list for the verifier or code-reviewer teammates. Those teammates are single-instance; the lead tracks their completion via `TeammateIdle` and direct `SendMessage` to `lead`. Mapper teammates (incremental codebase refresh) use a small task list with one task per stale domain.

## Codebase index schema (.loop-spec/codebase/index.json)

`.loop-spec/codebase/index.json` is the file-to-domain mapping used by `map-codebase` and `verify` skills. It is not gitignored (shared across machines).

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
- The `graphify` block is populated after the first cycle run. graphify is a hard requirement (cycle Step 2 aborts without it unless `LOOP_SPEC_REQUIRE_GRAPHIFY=0`), so the block is absent only before the first run or in the bypass/degraded mode. Set `graph_json_path` to the `graphify-out/graph.json` written by `graphify .` (deterministic AST extraction, no LLM; this is what the cycle Step 5.4 bootstrap and map-codebase/verify build via `lib/graphify-preflight.sh`, using `graphify . --update` for incremental refreshes). Set `wiki_path` to `graphify-out/wiki/index.md` only when the LLM-backed wiki generation has been run (the plain build does not produce a wiki). Set `last_updated` to the ISO-8601 timestamp of the last successful build.
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

On `cycle` skill startup, candidate `feature.json` files are enumerated, filtered (completed/stale skip, `TaskList({team: currentTeamName})` live-team probe — explicit teams mode only), and routed back into their phase. The full algorithm, the orphan/stale-team handling, worktree/workspace re-entry, and `currentGate` transcript reload are documented authoritatively in `skills/shared/cycle-resume-escalation.md`.
