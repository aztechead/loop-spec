---
name: deliver
description: "Push the verified SHA, update its PR, check required CI results, and mark the PR ready after ITERATE converges. Internal phase of /loop-spec:cycle at currentPhase=deliver."
allowed-tools: Bash Read Write Edit
---

# DELIVER

Run delivery in the main thread without agents.
Every changed repository must meet these conditions:

```text
local candidate SHA == remote branch SHA == PR head SHA
required checks all pass/skipping (or none configured)
PR metadata reflects final artifacts; PR is no longer a draft
```

`lib/deliver.sh` controls delivery through one blocking call.
It waits for required checks for up to `LOOP_SPEC_CHECKS_TIMEOUT_SECONDS` (default 900).
It delegates each changed repository to `lib/pr-delivery.sh`.
Before changing GitHub, it rejects dirty trees and branch or base mismatches.
It retries hard failures only for the same `targetSha`.
For multiple repositories, it keeps PRs as drafts until every repository passes.

The controller calls `lib/finalize-delivery-candidate.sh` for pre-delivery changes. Never commit here yourself.
At terminal-result time, `lib/delivery-reconcile.sh` reconciles PRs opened with `gh` outside the controller.

Use only the entry packet as input. The controller reads all other inputs.
Load the entry packet, then call delivery. That call includes `lib/deliver.sh run` and step 3's feedback check:

```bash
pb="$(bash "${LOOP_SPEC_SKILL_DIR}/../../lib/cycle-driver.sh" phase-begin deliver --feature-dir "$feature_dir")"
dl="$(bash "${LOOP_SPEC_SKILL_DIR}/../../lib/cycle-driver.sh" deliver --feature-dir "$feature_dir")"
# .rc .status .nextPhase .route=completed|execute|deliver|deferral|feedback-failed .targets[] .feedback[] .stderr
```

## 1. Run the controller

Never AskUserQuestion as a wait. Never run the call in the background.
`.route == "deferral"` (exit 3) reports a self-authored deferral in the PR body or `warnings[]`.
Follow `lib/deferral-lint.sh` and `skills/shared/no-deferral.md`.
Create a FULL-SHAPE remediation task for unimplemented spec scope.
For a bounded gate, restore any missing `iterate-budget-spent:`, `iterate-terminal:`, or `verify-deferred` marker at its source.
Then call `deliver` again.

`LOOP_SPEC_CREDENTIAL_REFRESH_CMD`, when set, runs before every push and API stage and
retries one auth failure.

## 2. Route by the sidecar

The controller saves `.loop-spec/features/{slug}/delivery.json`.
Its `nextPhase` selects the route, which the call reports as `.route`.
Follow that route. Never infer a different failure type from prose.

- **`completed`**: run step 3, then return.
  Status is `ready-for-review`, `delivered-draft`, or `pushed-no-pr`.
  `pushed-no-pr` means the host has no `gh`: the verified SHA reached the remote, but no PR exists to check.
  Do not commit or push afterwards. Keep the verified head SHA unchanged.
  `feature.json.currentPhase` stays `deliver` so a clone can check external state again.
- **`execute`**: required checks failed, so the PR remains a draft.
  The controller adds a `task-delivery-ci-remediation` task per failed target to `pendingRemediationTasks[]`.
  Task notes list the failed checks. Return to the cycle.
  The `deliver -> execute` loop in `graph/cycle.graph.json` limits retries through `ciRemediationAttempts`.
  The new SHA must pass VERIFY, ITERATE, and DELIVER.
- **`deliver`**: report the transport, timeout, identity, no-change, partial, ambiguous-PR, moved-head, or unsupported-check result.
  Do not claim completion or retry DELIVER in this loop. Return to the cycle.
  The driver writes the escalated or no-change result from the sidecar.
  Resume after the external condition changes. The controller safely retries the same SHA.
  Autonomous mode cannot override these failures.

## 3. Terminal PR feedback check

Check PR reviews, comments, and requested changes under `skills/shared/pr-feedback-check.md`.
The `deliver` call runs `lib/pr-feedback.sh check` and `lib/pr-feedback.sh record` for every target with a PR number.
Targets with `pushed-no-pr` have no PR to check. Print the observed `.feedback[]` results.

The check reads GitHub without changing it.
`.route == "feedback-failed"` means the check or its local record failed. This blocks completion.
Report `DELIVER: feedback persistence failed; completion blocked` and return without claiming completion.

## Resume

Call `deliver` again. The controller pushes the same SHA and finds the existing PR.
It updates metadata only when needed and never creates a duplicate PR.
A ready PR with passing checks needs no changes, but the feedback check still runs.
