# Feature State Schema

Per-feature runtime state lives at `.loop-spec/features/{slug}/feature.json`.
The driver saves resume snapshots, including `PROGRESS.md`, on `refs/loop-spec/state/{slug}` through `lib/state-ref.sh`.
Do not commit runtime state on the feature branch.
Backups, locks, gate logs, and transcripts remain local.

Write state through `lib/feature-write.sh`. It locks before reading, saves the prior state to `feature.json.bak`, and atomically replaces the live file.
It flushes a unique temporary file before replacement. The live path remains present throughout the write.

**Writing rules (every phase, no exceptions):** never mutate `feature.json` with raw `jq`/`python3` — that bypasses the atomic write and `.bak` rotation that resume depends on. `feature-write.sh set` takes **nested dot paths** (object keys only, no array indices) and a **JSON value** (strings must be quoted):

```bash
bash "${LOOP_SPEC_SKILL_DIR}/../../lib/feature-write.sh" set "$fdir" artifacts.patterns '"docs/loop-spec/features/'"${slug}"'/PATTERNS.md"'
bash "${LOOP_SPEC_SKILL_DIR}/../../lib/feature-write.sh" append "$fdir" warnings '"some warning"'
```

If `set` or `append` fails, read the error and correct the call.
Quote JSON strings. Replace an array through `set` on its parent path instead of using an array index.
Never bypass the writer with raw jq.

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
  "executionProfile": "standard | maintenance | compact",
  "autonomousClassification": "normalized active-run classification object | absent on legacy runs",
  "gatePlan": {
    "specInterview": {"run": "boolean", "reason": "nonblank classifier reason"},
    "discuss": {"run": "boolean", "reason": "nonblank classifier reason"},
    "specCritique": {"run": "boolean", "reason": "nonblank classifier reason"},
    "planCritique": {"run": "boolean", "reason": "nonblank classifier reason"},
    "repositoryValidation": {"run": "boolean", "reason": "nonblank classifier reason"},
    "placeholderScan": {"run": "boolean", "reason": "nonblank classifier reason"},
    "tamperScan": {"run": "boolean", "reason": "nonblank classifier reason"},
    "acceptance": {"run": "boolean", "reason": "nonblank classifier reason"},
    "codeReview": {"run": "boolean", "reason": "nonblank classifier reason"},
    "iterate": {"run": "boolean", "reason": "nonblank classifier reason"}
  },
  "currentPhase": "a phase id of lib/graph/phases.sh list (spec | oneshot | discuss | plan | execute | verify | iterate | deliver) | completed",
  "currentPhaseStartedAt": "ISO-8601 timestamp or null; set by cycle-driver.sh next when it answers NEXT for a phase (the watchdog reads it)",
  "completedPhases": ["array of phase names"],
  "specApproval": {"sha256":"approved Goal and Boundary digest", "source":"human | supervised | autonomous", "approvedAt":"ISO-8601 timestamp"},
  "instructionSnapshots": [{"phase":"phase id", "manifest":"absolute path", "sha256":"manifest digest", "prompt":"absolute path", "promptSha256":"rendered body digest"}],
  "reviewRouting": {"route":"intent-gap | bad-spec", "used":0, "pending":false, "reportSha256":"review digest", "findings":[]},
  "branch": "string (feat/{slug})",
  "worktreePath": "string (absolute path of the created feature worktree, .claude/worktrees/{slug} by default) in single-repo mode; null in workspace mode",
  "executionRootMode": "worktree | in-place | workspace",
  "baseSha": "git sha at branch creation",
  "baseBranch": "string (e.g., main)",
  "models": {
    "specWriter": "effective alias for the active phase",
    "planner": "effective alias for the active phase",
    "advocate": "effective alias for the active phase",
    "challenger": "effective alias for the active phase",
    "specComplianceReviewer": "effective alias for the active phase",
    "iterateJudge": "effective alias for the active phase",
    "implementer": "effective alias for the active phase",
    "codeReviewer": "effective alias for the active phase",
    "verifier": "effective alias for the active phase",
    "patternMapper": "effective alias for the active phase"
  },
  "phaseModels": {
    "spec": "Claude selector | null",
    "oneshot": "Claude selector | null",
    "discuss": "Claude selector | null",
    "plan": "Claude selector | null",
    "execute": "Claude selector | null",
    "verify": "Claude selector | null",
    "iterate": "Claude selector | null",
    "deliver": "Claude selector | null"
  },
  "artifacts": {
    "spec": "path or null",
    "patterns": "path or null (docs/loop-spec/features/{slug}/PATTERNS.md, written at PLAN Step 0)",
    "patternsSource": "gsd-ingest | pattern-mapper | manual | null",
    "plan": "path or null",
    "tasks": "path or null (.loop-spec/features/{slug}/tasks.json — gate-validated tasks[] JSON persisted at PLAN Step 6; EXECUTE Step 2a's preferred task source, validated by lib/artifact-lint.sh tasks; optional per-task status pending|done is the resume ledger — cycle resume and EXECUTE read it via lib/task-progress.sh)",
    "execution": "path or null",
    "verification": "path or null",
    "iteration": "path or null"
  },
  "currentTeamName": "string or null (e.g., loop-spec-execute-{slug}); null between phases",
  "currentTeammates": ["array of teammate names currently spawned, e.g., implementer-1, reviewer-1; empty between phases"],
  "currentGate": {
    "phase": "string or null",
    "gate": "string or null",
    "round": "integer (current single-critic / delta round, 0 if no gate active)",
    "advocateName": "string or null (always null; retained for resume schema)",
    "challengerName": "string or null (e.g., challenger-1)",
    "startedAt": "ISO-8601 timestamp or null",
    "_writer": "lib/graph/gate.sh only (open|round|fail|pass); feature-write.sh refuses currentGate and gateHistory to every other caller"
  },
  "commands": {
    "prepare": "string (deterministic environment setup; empty means no setup)",
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
        "commands": {"prepare": "", "test": "", "lint": "", "typecheck": ""},
        "verificationBaseline": "same compact baseline object as the top-level field, or null"
      }
    ]
  },
  "stalenessHours": 48,
  "prUrl": "string or null (legacy/tracked remediation shortcut; successful delivery URLs live in ignored delivery.json)",
  "checkpointPrUrl": "string or null (draft PR URL set by lib/checkpoint-pr.sh on pause/escalation/terminal salvage; null otherwise)",
  "delivery": {
    "status": "pending | ready-for-review | delivered-draft | checks-failed | checks-timeout | partial | no-changes | another structured delivery error",
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
        "outcome": "delivered | delivered-draft | skipped-no-commits | blocked",
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
  "verificationBaseline": {
    "schemaVersion": 1,
    "baseSha": "exact full base commit ID",
    "prepareKey": "preparation key from lib/prepare-environment.sh",
    "commands": {
      "test": {"command": "", "status": "pass | fail | skipped | infra_error", "exitCode": 0, "fingerprints": []},
      "lint": {"command": "", "status": "pass | fail | skipped | infra_error", "exitCode": 0, "fingerprints": []},
      "typecheck": {"command": "", "status": "pass | fail | skipped | infra_error", "exitCode": 0, "fingerprints": []}
    }
  },
  "warnings": ["array of strings"],
  "driverNext": {"phase": "string; the phase cycle-driver.sh last answered NEXT with", "at": "ISO-8601"},
  "driverRedo": {"phase": "string", "hash": "string; the FLAG lines of the last REDO", "count": "integer; identical REDO rounds so far, capped by LOOP_SPEC_REDO_MAX"},
  "handoffSession": {"id": "string; the harness session id that answered HANDOFF, or empty", "from": "string; the phase that closed", "next": "string; the phase a fresh invocation enters", "at": "ISO-8601"},
  "iterate": {
    "maxIterations": "integer (LOOP_SPEC_ITERATE_MAX_ITERATIONS)",
    "used": "integer",
    "confirmationUsed": "boolean",
    "lastVerdict": "judge verdict object or null",
    "feedback": "{type: execute | plan | spec | verify, description, fix_first} on a rewind; null when converged",
    "history": ["array of past verdicts"]
  },
  "greenfield": "boolean; set by lib/feature-bootstrap.sh when the repository has no code yet",
  "protected": "array of repository-relative paths the task forbids the change to touch (the invocation token `protected:a,b`); the one source of a read-only footprint file (lib/footprint.sh list)",
  "autonomous": "boolean; set by lib/feature-bootstrap.sh for an unattended run",
  "backlogEntry": "string or null; the backlog text a cycle started from (cycle backlog)",
  "backlogEntryId": "string or null; its id, so DELIVER can close the entry",
  "artifactSink": "{mode: store, manifest: <slug>/<sha>/manifest.json} once lib/artifact-sink.sh moved the artifacts to a store; absent otherwise",
  "mergeQueue": ["array of task ids in FIFO arrival order awaiting merge to feat/{slug}; empty between phases and at EXECUTE exit"],
  "pendingRemediationTasks": ["array of remediation task objects appended by VERIFY (lib/feature-write.sh append) and consumed+cleared by EXECUTE Step 2a; empty between phases"],
  "activeWorkflow": {
    "scriptPath": "string or null",
    "args": "object or null",
    "sessionId": "string or null",
    "runId": "string or null",
    "startedAt": "ISO-8601 timestamp or null (set before a dispatched Workflow call per dispatch.md; cleared once the skill consumes the result; null when no workflow is in flight)"
  },
  "harnessTaskMetadataMode": "string or null (reserved for future harness capability negotiation)",
  "harnessStatusMode": "string or null (reserved for future harness capability negotiation)",
  "fileConflictExcludeGlobs": ["optional array of globs excluded from EXECUTE pre-task file-conflict detection"],
  "gateHistory": [
    {
      "phase": "string",
      "gate": "spec-critique | plan-critique | spec-compliance | acceptance | code-review",
      "attempt": "integer",
      "result": "pass | fail",
      "advocateModel": "string or null",
      "challengerModel": "string or null",
      "rounds": "integer (rounds the debate ran)",
      "convergence": "single-critic | delta-verified | cap-reached",
      "findingsAddressed": ["string", "..."],
      "notes": "string or null"
    }
  ]
}
```

### Field notes

- The `tasks` and `waves` arrays from v2 are gone. Live task state lives in the harness task list, not in `feature.json`.
- There is no `retryBudget` block: every attempt is recorded in `gateHistory[]`, and the critique gates' delta rounds are bounded by the loop ceiling `graph/critique.graph.json` declares, read by `lib/graph/gate.sh next` (a `cap-reached` pass entry carries the surviving findings in `notes`). The cycle's other bound is `iterate.maxIterations`. During EXECUTE, the per-task rework cap (`maxRetriesPerTask`, default 6: one initial attempt plus five fix rounds; `lib/fix-loop.sh max` prints that default) routes a repeatedly-failing task to the lead for escalation rather than looping it forever between the same implementer and reviewer. EXECUTE reads the overlay at dispatch (`lib/tuning.sh get executeMaxRetriesPerTask 6`) so a `raise-gate-rounds-execute` tightening actually moves the cap.
- `currentTeamName`, `currentTeammates`, and `currentGate` are the rapidly-mutating fields. After `TeamDelete`, `currentTeamName` becomes `null` and `currentTeammates` `[]`. `currentGate` is NEVER nulled — it is closed by `lib/graph/gate.sh pass`, which writes a zeroed object, because `graph/cycle.graph.json` declares it in the `reads[]` of both critique nodes and `lib/graph/state.sh assert-reads` fails a node whose declared read is null.
- `executionProfile` is the gate ladder the whole cycle runs, resolved once at Step 3 by
  `lib/cycle-profile.sh` and persisted so a resume keeps the same shape. `standard` is the
  default and today's full ladder. `maintenance` is earned only by a validated low-risk
  classification (or an explicit operator override): SPEC synthesizes its spec instead of
  interviewing, and the graph short path skips DISCUSS, spec-critique, and the
  code-review agent when `lib/security-signal.sh` reports no match. PLAN critique skip is
  `plan-critique.sh` / the skill fast-path, not that short path. The question gate, the
  feasibility check, and the deterministic VERIFY gates stay; code review is the one
  quality gate the short path drops, and only behind this classification.
- `compact` is a separate, classifier-authored ladder. Bootstrap records the normalized
  input in `autonomousClassification` and persists `gatePlan` only when the normalized
  compact decision passes `lib/cycle-profile.sh`: all ten named gates must have exactly a
  boolean `run` and a nonblank, single-line reason of at most 240 characters; see
  `skills/shared/compact-profile.md`. Graph and phase skills read that committed plan on
  every entry, so a resume never recalculates or silently widens a skip. Missing or
  malformed compact state fails upward by running the affected gate. A false gate remains
  observable through its persisted classifier reason; VERIFY also records skipped
  verification gates in `VERIFICATION.md`.
- Full-route phase boundaries hand off through a paused `phase-handoff` result.
  A fresh invocation resumes at `currentPhase`. Graph edges with `sameSession` continue in the current invocation. A feature
  written before 6.4.0 may carry a `phaseHandoff` key; the driver drops it as a stray.
- `mergeQueue` is the FIFO merge queue for EXECUTE. The lead appends a task id when a reviewer marks it `completed`, then processes the queue sequentially in dependency-aware FIFO order.
- `fileConflictExcludeGlobs` provides per-feature overrides for file-conflict detection. Repo-wide overrides live in `.loop-spec/file-conflict-exclude.txt` (one glob per line). Both sources are unioned.
- `harnessTaskMetadataMode` and `harnessStatusMode` are reserved for future capability negotiation. Set to `null` unless the cycle's Step 2 capability probe signals a specific mode.
- `artifacts.specInterview` is a nullable path to the SPEC-phase interview transcript (written by the spec orchestrator on the main thread). `currentPhase` includes `"spec"` as its first value.
- `pendingRemediationTasks` carries remediation tasks until EXECUTE consumes them. `activeWorkflow` records an active workflow under `skills/shared/dispatch.md`.
  Both are runtime state. Do not clear pending remediation merely because the phase changes.
- `commands.prepare` is persisted beside the quality commands. Resolution precedence is an already-persisted explicit command, `LOOP_SPEC_CMD_PREPARE` (including an explicit empty value), `.loop-spec/workflow.json.prepareCommand`, then conservative lockfile detection by `lib/prepare-environment.sh`; ambiguous lockfiles produce an empty command rather than a mutable install guess. Detection covers workspace layouts: when the root carries no lockfile for an ecosystem, a single tracked `manifest + lockfile` pair within three directories of the root resolves to the same frozen install scoped to that directory (`(cd webapp/frontend && npm ci)`), and the preparation key hashes that directory's manifests alongside the root's. In workspace mode each repo owns its command and preparation key independently.
- `verificationBaseline` is `null` unless `LOOP_SPEC_STARTUP_BASELINE=1` opted the cycle into a clean, exact `HEAD == baseSha` capture at startup. Default runs never capture one: the cycle spends no fresh-checkout time on repository-wide validation before the feature exists, and VERIFY's end-of-cycle comparison blocks on every failure it observes. Single-repo mode uses the top-level field; workspace mode leaves that field null and uses `workspace.repos[].verificationBaseline`. Its compact JSON is committed with feature state, but command logs remain machine-local. Comparison requires matching `baseSha`, preparation key, and test/lint/typecheck command strings. Pass-to-fail and added fingerprints are regressions; unchanged or subset known failures are accepted; command/runtime infrastructure errors are distinct. Criterion-specific acceptance commands are never included. A missing baseline on an older feature is strict: current failures regress and are never learned from the modified feature head.
- `baseBranch` is initialized at feature creation (cycle Step 5, via `lib/git-ops.sh detect-base-branch`) so a plan-only or early-exit feature opens its PR against the correct base.
- `models` is the effective per-role map for the active phase (no preset axis).
  `lib/feature-init.sh activate <feature-dir> <phase>` rewrites it immediately
  before every phase invocation, including continuous transitions and resumes.
  Every phase skill reads `feature.models.<role>` rather than re-deriving it.
  It adds an Agent `model` key only for one of the four aliases on a **nameless**
  spawn and omits the key for `inherit` (the Agent tool rejects that literal).
  Named implicit-team spawns omit `model` even when the map holds an alias —
  they inherit the session (`skills/shared/dispatch.md`). The
  authoritative precedence is in `skills/shared/model-matrix.md`.
- `phaseModels` is the persisted seven-phase override map from
  `LOOP_SPEC_PHASE_MODEL_<PHASE>`; null means no override. It lets a fresh Claude
  CLI/Agent SDK phase handoff choose its main model, while `models` guarantees
  the same phase default reaches explicit teams, nameless implicit-team
  oneshots, one-shot fallbacks, and phase gates. Named implicit teammates still
  inherit the session. Both maps come from `feature-init.sh`.
- `worktreePath` points at the dedicated single-repo git worktree created at cycle
  Step 5 via `lib/git-ops.sh create-feature-worktree`. Its location is resolved by
  `lib/worktree-base.sh`: `<repo>/.claude/worktrees/{slug}` by default, relocated
  outside the repository when that base cannot hold the checkout or when
  `LOOP_SPEC_WORKTREE_DIR` is set. Record what the helper printed; never assume the
  default. Features created before 2.30.0 may carry the repo-relative
  `.claude/worktrees/{slug}` form, which still resolves against the repo root. It is
  null for `LOOP_SPEC_WORKTREES=0`, OpenCode/ADK, and workspace execution. Resume
  discovers recorded feature worktrees via `git-ops.sh list-feature-worktrees`.
- `executionRootMode` is `worktree` for Claude's default native feature worktree,
  `in-place` for `LOOP_SPEC_WORKTREES=0` and the additive OpenCode/ADK path (those
  harnesses cannot switch a live session root), and `workspace` for multi-repo mode.
- Tracked `delivery` initializes to `pending` (absent on pre-DELIVER schema-7 features; tolerated) and mutates only when failed checks route durable remediation back to EXECUTE. Everything else — the ignored `delivery.json` sidecar (schema 1), status meanings, SHA invariants, and the CI-remediation cap — is DELIVER's contract: see `skills/deliver/SKILL.md` and `lib/pr-delivery.sh`. Keeping success out of tracked state prevents a post-CI commit from changing the exact checked SHA.
- The optional `workspace` block enables multi-root workspace mode. Rules: (1) `workspace` absent or null means single-repo mode (`worktreePath` set). (2) In workspace mode the top-level `branch`, `baseSha`, `baseBranch`, and `worktreePath` are null; per-repo values in `workspace.repos[]` are authoritative. `lib/graph/state.sh assert-reads` honors that relocation, so a declared read of `branch` (or `baseSha`/`baseBranch`) is satisfied by every `workspace.repos[]` entry rather than the null top-level field. `worktreePath` is not relocated and has no per-repo equivalent; a node that needs it in workspace mode declares it in `optionalReads[]`. (3) The top-level `commands` block holds empty strings (per-repo commands live in `workspace.repos[].commands`). (4) State and artifact dirs are rooted at `workspace.root`. (5) Resume requires the session cwd to be `workspace.root`; the cycle skill instructs the user to cd there before re-invoking.
- **Schema is 7-only.** A `feature.json` with `schemaVersion != 7` is unsupported and skipped on resume with a warning; there is no in-place migration path for older schemas. New features are always created at schema 7 by `lib/feature-init.sh`.

- `handoffSession` is written by `lib/cycle-driver.sh next` each time it answers `HANDOFF`
  or `REWIND`. While the session named by `id` is the one calling, `next` repeats the
  handoff answer, and `begin` or `phase-begin` of any other phase exits 4; each writes
  the paused result again, since `begin`'s preflight clears it. The next phase starts in
  a fresh invocation, whatever tool the lead reaches for. An empty `id` (a harness that
  stamps no session id) enforces nothing. A graph edge carrying `sameSession` (the
  `human.after-spec` to `oneshot` route) writes no record: the driver answers `NEXT`
  and the phase runs in the session that closed SPEC.
- `driverNext` is written by `lib/cycle-driver.sh next` each time it answers `NEXT`.
  `lib/cycle-result.sh write` reads it: publishing `failed`, `terminal`, or `escalated`
  while it is set needs `--reason`, because a lead that was told to run a phase and
  published a failure instead ends a run a supervisor treats as dead.

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
- `repos[].path`: path to the repo, relative to the workspace root. The resolved path must exist and equal that repository's git toplevel (a nested directory is rejected); invalid entries cause `lib/workspace.sh detect` to exit 1 with a clear message.
- When to pin: (a) the workspace parent directory is itself a git repo (detection defaults to single mode; the pin overrides this), or (b) you want to use only a subset of the child repos discovered by depth-1 scan. The workspace root is always orchestration-only and cannot be listed as a target; use single-repo mode when the root itself is the delivery repository. Cycle/VERIFY/ITERATE never commit workspace state or evidence to the parent.
- When not to pin: the workspace parent is not a git repo and you want all immediate child git repos included (auto-discovery covers this without a pin file).

## Harness task list usage

Each phase team maintains its own harness task list via `TaskCreate` / `TaskUpdate` / `TaskList` / `TaskGet`. The following fields are set on task `metadata` at creation time and updated through the task lifecycle:

| Field | Type | Set by | Description |
|---|---|---|---|
| `retries` | integer | Reviewer (`team-prompts/reviewer.md` On Fail rework) / EXECUTE SKILL Step 6 | Per-task retry counter. Capped by `maxRetriesPerTask` (default 6; overlay may raise). Initialized to 0 at `TaskCreate`. Resets to 0 on EXECUTE resume (harness task list is recreated from `PLAN.md`). |
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
| `model` | string | `specifying-gates` skill at gate specification | Optional explicit model selector for the dispatched subagent. Omit to inherit. |
| `dispatchBrief` | string | `specifying-gates` skill at gate specification | Optional. Freeform brief passed to the dispatched subagent describing what to verify. |
| `failurePolicy` | string enum | Lead at `TaskCreate` or `specifying-gates` skill | Optional. Controls what happens when a gate check fails. One of: `stop-plan` (halt the plan and block further progress), `reopen-continue` (reopen the task and continue other tasks), `log-continue` (log the failure and continue without blocking). |
| `gateScope` | string enum | `specifying-gates` skill at gate specification | Optional. Controls how many times the gate is evaluated across targets. One of: `once` (checked a single time), `per-target` (checked once per verification target), `one-then-all` (one check then all in parallel), `custom` (custom scope defined in `dispatchBrief`). |
| `requiresUserSpecification` | bool | Lead at `TaskCreate` or planner | Optional. When true, the `checking-gates` skill routes to `specifying-gates` before running the gate check, to collect missing verification mechanics from the user. Removed from metadata after `specifying-gates` completes. |
| `repo` | string | Lead at `TaskCreate` (planner-supplied) | Optional. Workspace mode only. The name of the participating repository this task targets, matching a `workspace.repos[].name` value in `feature.json`. One task targets exactly one repo; cross-repo work is expressed as multiple tasks with `blockedBy` edges. Absent in single mode. |

### Per-phase harness task list notes

**DISCUSS.** No harness task list. The challenger (and spec-writer only when SPEC.md was missing) communicate via `SendMessage`; the lead tracks gate state in `feature.json.currentGate` and appends round-end messages to `.loop-spec/features/{slug}/gate-logs/`.

**PLAN.** No harness task list for PLAN's internal teammates (pattern-mapper, planner, challenger). PLAN derives the validated `tasks[]` JSON from PLAN.md's task blocks (`lib/plan-tasks.sh extract`) into `tasks.json`; the EXECUTE team's harness task list is created from it later, by `TaskCreate` calls in EXECUTE Step 3 (one task per planned task), populated with `blockedBy`, `files`, `verifyCommand`, `acceptanceCriteria`, `readFirst`, and `specPath` in task `metadata`. It is not pre-created at PLAN exit and there is no EXECUTE Step 0.

**EXECUTE.** One task per planned task. Implementers self-claim by calling `TaskUpdate({taskId, status: "in_progress", owner: "<own-name>"})`. The harness serializes concurrent claims on the same task id; the losing implementer must re-query and retry. Task lifecycle: `pending -> in_progress -> awaiting_review -> completed | needs_rework`. Per-task `retries` in metadata is the retry counter; `claimedBy` identifies the owner for reviewer-to-implementer messaging.

**VERIFY.** No per-task harness task list for the verifier or code-reviewer teammates. Those teammates are single-instance; the lead tracks their completion via `TeammateIdle` and direct `SendMessage` to `lead`.

## Atomic write

All `feature.json` mutations go through `lib/feature-write.sh`. `set` and `append`
serialize the complete read/modify/write transaction per feature, including store
persistence. Readers see either the old or new complete file. The kernel releases
the lock when the writer dies; do not delete the lock file while writers may exist.
Whole-object replacement remains an explicit overwrite: a caller holding an old
snapshot must not use it to merge concurrent changes. Prefer targeted field updates.
The writer accepts one JSON object for replacement and rejects malformed or multiple
documents. Never write the file directly.

## Resume

On `cycle` skill startup, candidate `feature.json` files are enumerated, filtered (completed/stale skip, `TaskList({team: currentTeamName})` live-team probe — explicit teams mode only), and routed back into their phase. The full algorithm, the orphan/stale-team handling, worktree/workspace re-entry, and `currentGate` transcript reload are documented authoritatively in `lib/cycle-driver.sh` (resume).

## Approved full-spec intent

`specApproval` records `sha256`, `source` (`human`, `supervised`, or `autonomous`),
and `approvedAt`. `cycle-driver.sh spec approve --feature-dir DIR --source SOURCE`
creates it after the questions are resolved and the Goal and Boundary are approved.
The state writer refuses replacement or deletion. Phase exit passes the feature dir
to artifact lint, which compares those sections with the approved digest even after
intervening commits. Implementation and acceptance details remain editable.
