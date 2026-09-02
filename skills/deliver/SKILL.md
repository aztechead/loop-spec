---
name: deliver
description: DELIVER phase - deterministic exact-SHA push, idempotent PR reconciliation, required-check wait, and draft-to-ready after ITERATE converges. Cycle-internal - invoked by /loop-spec:cycle at currentPhase=deliver.
allowed-tools: Bash Read Write Edit
---

# DELIVER

Main thread, no agents: GitHub delivery is a transport transaction, not a judgment.
The invariant for every changed repository:

```text
local candidate SHA == remote branch SHA == PR head SHA
required checks all pass/skipping (or none configured)
PR metadata reflects final artifacts; PR is no longer a draft
```

`lib/deliver.sh` is the implementation (one blocking call; the required-check wait is
inside it, bounded by `LOOP_SPEC_CHECKS_TIMEOUT_SECONDS`, default 900). It delegates
each changed repo to `lib/pr-delivery.sh`, refuses any dirt or branch/base mismatch
before touching GitHub, binds hard-failure retries to the exact `targetSha`, and holds
multi-repo PRs as drafts until every repo is green. `lib/finalize-delivery-candidate.sh`
(called by the controller) is the only pre-delivery mutation; never commit here
yourself. A PR opened with `gh` outside the controller is reconciled at terminal result
time by `lib/delivery-reconcile.sh`.

## 1. Run the controller

```bash
delivery_rc=0
delivery_json="$(bash "${CLAUDE_SKILL_DIR}/../../lib/deliver.sh" run "$feature_dir")" || delivery_rc=$?
```

Never AskUserQuestion as a wait and never background the call. **Exit 3** is a
self-authored deferral in the PR body or `warnings[]` (`lib/deferral-lint.sh`,
`skills/shared/no-deferral.md`): scope was dropped, not worded badly. Unimplemented spec
scope becomes a FULL-SHAPE remediation task; a bounded-gate line missing its
`iterate-budget-spent:` / `iterate-terminal:` / `verify-deferred` marker gets the marker
restored at its source. Then run DELIVER again. `LOOP_SPEC_CREDENTIAL_REFRESH_CMD`, when
set, runs before every push and API stage and retries one auth failure.

## 2. Route by the sidecar

The controller persists `.loop-spec/features/{slug}/delivery.json`; its `nextPhase` is
the route. Obey it; never reclassify a failure from prose.

- **`completed`** (`status == "ready-for-review"` or `"delivered-draft"`): run step 3,
  then return. Do not commit or push afterwards; the proven head SHA is immutable and
  `feature.json.currentPhase` stays `deliver` (a clone re-proves the external state).
- **`execute`** (required checks failed): the PR stays a draft and the controller has
  appended one `task-delivery-ci-remediation` task per failed target to
  `pendingRemediationTasks[]`, with the failed check names in its notes. Return; the
  CI-remediation route declared on `graph/cycle.graph.json`'s `deliver -> execute` loop
  edge (bounded by `ciRemediationAttempts`) re-enters EXECUTE
  and a new SHA comes back through VERIFY, ITERATE, DELIVER.
- **`deliver`** (transport, timeout, identity, `no-changes`, `partial`, ambiguous PR,
  moved head, unsupported checks): do not claim completion and do not re-run DELIVER in
  this loop. Return; the cycle driver writes the escalated or no-change result from the
  sidecar, and a resume re-runs the transaction idempotently against the same SHA once
  the external condition changes. Autonomous mode cannot self-approve past any of these.

## 3. Terminal PR feedback check (ready-for-review only)

Every cycle ends by opening a PR and checking it for reviews, comments, and requested
changes (`skills/shared/pr-feedback-check.md`):

```bash
feedback_rc=0
while read -r t; do
  args=("$(jq -r '.prNumber' <<<"$t")"); repo="$(jq -r '.repo // empty' <<<"$t")"; [[ -n "$repo" ]] && args+=(--repo "$repo")
  fb="$(bash "${CLAUDE_SKILL_DIR}/../../lib/pr-feedback.sh" check "${args[@]}")" || { feedback_rc=1; break; }
  bash "${CLAUDE_SKILL_DIR}/../../lib/pr-feedback.sh" record "$feature_dir/delivery.json" "$(jq -r '.name' <<<"$t")" "$fb" || { feedback_rc=1; break; }
  printf '%s\n' "$fb"
done < <(jq -c '.targets[] | select(.prNumber != null)' "$feature_dir/delivery.json")
[[ "$feedback_rc" -eq 0 ]] || { echo "DELIVER: feedback persistence failed; completion blocked" >&2; false; }
```

The check is read-only; a check or recording failure blocks completion.

## Resume

Run step 1 again. The controller pushes the same SHA, finds the existing PR, updates
metadata only when changed, never duplicates, and a ready PR with green checks is a
no-op success whose feedback check still runs.
