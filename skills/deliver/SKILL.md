---
name: deliver
description: DELIVER phase - deterministic exact-SHA push, idempotent PR reconciliation, required-check wait, and draft-to-ready transition after ITERATE converges. Cycle-internal - invoked by /loop-spec:cycle against an active feature at currentPhase=deliver.
allowed-tools: Bash Read Write Edit
---

# DELIVER Phase

Invoked only when `feature.json.currentPhase == "deliver"`. This phase runs on the
main thread and launches no agents or teams. GitHub delivery is a transport/state
transaction, not an LLM judgment.

## Contract

DELIVER owns every normal push and final PR mutation. VERIFY and ITERATE must have
finished first. It never merges or enables auto-merge.

A successful result means all changed repositories satisfy the same invariant:

```text
local candidate SHA == remote branch SHA == PR head SHA
required checks are all pass/skipping (or none are configured)
PR metadata reflects final artifacts
PR is no longer a draft
```

The deterministic implementation is `lib/deliver.sh`, which delegates each changed
repository to `lib/pr-delivery.sh`. Both use explicit repository paths, so this phase
is identical under Claude Code, pi, and OpenCode.

Three invariants the controller enforces so retries and multi-repo features stay safe:

- **Candidate preflight.** Every target — single-repo and each workspace repo — must be
  a clean git work tree at the repository root, on the recorded feature branch, with its
  recorded base as an ancestor and at least one commit past it, before any push. All
  workspace targets preflight before any sibling touches GitHub. A mismatch is a
  structured block, never a silent delivery of the wrong or incomplete `HEAD`.
- **SHA-bound hard retries.** A hard failure (transport, identity, timeout) leaves
  `delivery.json.nextPhase = "deliver"` with the exact `targetSha` it tried. A resumed
  attempt re-delivers that same SHA; if `HEAD` has drifted it fails closed with
  `candidate_sha_drift` rather than delivering an unverified commit. A remediation route
  (`nextPhase = "execute"`) intentionally produces a new SHA, so binding is skipped there.
- **Staged workspace readiness.** With two or more changed repos, the controller holds
  every repo's draft (push + reconcile + green required checks, `--hold-ready`) and
  promotes them to ready only after all repos have cleared checks. One repo's CI failure
  therefore never leaves a half-ready set of PRs; the feature routes to remediation with
  the passing repos still held as drafts. If a held PR was externally promoted, staging
  fails closed instead of falsely claiming it remains draft. If a later promotion fails,
  the controller restores already-promoted siblings to draft before the retry.

## Procedure

### Step 1 - Final-candidate guard

The cycle committed the terminal ITERATE transition before entering this phase. Do
not modify source, artifacts, state, rules, telemetry digests, or commits before the
controller call. If intended tracked changes remain uncommitted, stop and route back
to the owning phase instead of delivering an incomplete `HEAD`.

`lib/deliver.sh` enforces the clean-tree, branch, root, and ancestry checks. No tracked or
untracked dirt is tolerated in a delivery target; every implementation/artifact change
must already be committed. In workspace mode it validates every repo before calling any
controller.

### Step 2 - Run the controller

```bash
fdir=".loop-spec/features/${slug}"
delivery_rc=0
delivery_json="$(bash "${CLAUDE_SKILL_DIR}/../../lib/deliver.sh" run "$fdir")" \
  || delivery_rc=$?
```

`LOOP_SPEC_CHECKS_TIMEOUT_SECONDS` controls the total required-check wait (default
900); `LOOP_SPEC_CHECKS_INTERVAL_SECONDS` controls polling (default 10). Each `gh`
request also has a bounded command timeout via
`LOOP_SPEC_GH_COMMAND_TIMEOUT_SECONDS` (default 60).

The adapter atomically persists the observation to ignored
`.loop-spec/features/{slug}/delivery.json`. That sidecar's `nextPhase` is the
deterministic route (`completed`, `execute`, or `deliver`); obey it rather than
reclassifying failures from prose. Only a failed-check route mutates tracked
`feature.json`, because EXECUTE must receive durable remediation state.

### Step 3 - Route the result

#### Ready for review

When `delivery_rc == 0`, `.status == "ready-for-review"`, and
`.nextPhase == "completed"`:

The adapter leaves tracked `feature.json.currentPhase = "deliver"` and writes logical
completion to `delivery.json`, keeping the checked branch clean. Return to cycle; its
router treats sidecar `nextPhase=completed` as the terminal transition. **Do not commit
or push after the controller succeeds.** The PR head just proved is the immutable delivered SHA;
any post-delivery commit would invalidate both its local verification and CI result.
The local sidecar/result are the observation record. The committed branch remains
resumable at `currentPhase=deliver`, so a clone re-runs this idempotent phase and
re-proves the external state; same-machine completion can resume from the sidecar.

#### Required checks failed

When `delivery.nextPhase == "execute"`, every failed target was deterministically
classified as `checks_failed`. The adapter keeps the PR as a draft, appends one
idempotent FULL-SHAPE task per failed target to `pendingRemediationTasks[]`, and sets
`currentPhase = "execute"`:

```json
{
  "id": "task-delivery-ci-remediation",
  "subject": "Fix: required PR checks failed",
  "files": [],
  "verifyCommand": "<feature.commands.test, or the relevant repo test command>",
  "acceptanceCriteria": ["all required PR checks pass for the delivered SHA"],
  "repo": "<workspace repo name, or null in single mode>",
  "blockedBy": [],
  "retries": 0
}
```

Failed check names/links from `delivery.targets[].checks.required[]` are in the task
notes. Reload the state and return to cycle. The normal
EXECUTE -> VERIFY -> ITERATE -> DELIVER path produces and checks a new SHA. This route
is bounded to two persisted `ciRemediationAttempts`; a third failed delivery remains at
DELIVER and stops for external review rather than looping indefinitely.

#### Transport, timeout, or identity failure

When `delivery.nextPhase == "deliver"`, failures such as `push_failed`,
`remote_sha_mismatch`, `pr_ambiguous`, `pr_head_moved`,
`checks_timeout`, `checks_unsupported`, authentication failures, `partial`, or
`no-changes`, do not claim completion and do not spin by invoking DELIVER again in
the same phase loop. Leave `currentPhase = "deliver"`, write an escalated cycle result
with the structured error, and return control. Resume re-runs the transaction
idempotently after the external condition is corrected. Cycle must not update timestamps,
progress, or tracked state on this route: the sidecar owns the observation and the retry
is bound to the same candidate SHA.

Autonomous mode follows the same fail-closed rule. It may remediate an actual failed
check, but it cannot self-approve a missing remote, ambiguous PR identity, moved head,
or unavailable required-check oracle.

## Resume

Re-run Step 2. The controller pushes the same explicit SHA, finds the existing PR by
branch or persisted URL, updates metadata only when changed, and never creates a
duplicate. A ready PR with the same verified SHA and green required checks is a no-op
success.
