# Terminal PR feedback check (shared contract)

Every cycle type ends the same way: the work lands on a branch, a PR exists for it,
and the flow **checks that PR for reviews, comments, and requested changes** before
claiming done. This file is the single contract; the flows that must apply it are:

| Cycle type | Terminal step that runs the check |
|---|---|
| `/loop-spec:cycle` | DELIVER, after `ready-for-review` (`skills/deliver/SKILL.md` Step 4) |
| `/loop-spec:micro` | Protocol step 6 "Deliver as a PR" (`skills/micro/SKILL.md`) |
| `/loop-spec:debug` | Step 4 "VERIFY and land" (`skills/debug/SKILL.md`) |

`/loop-spec:revise` is the downstream consumer: it ingests the same feedback shape
and folds it back into a cycle. The check itself is **read-only** — it never mutates
the PR, never re-runs checks, and never invalidates a delivered SHA.

## The check

One call per delivered PR:

```bash
feedback_args=("$pr_number")
[[ -n "$repo" ]] && feedback_args+=(--repo "$repo")
fb="$(bash "${CLAUDE_SKILL_DIR}/../../lib/pr-feedback.sh" check "${feedback_args[@]}")"
# {schema, observationStatus: complete|degraded|delegated, owner,
#  reviewDecision, changesRequested, requestedReviewers, unresolved, items, error}
```

`reviewDecision` is GitHub's aggregate (`APPROVED` / `CHANGES_REQUESTED` /
`REVIEW_REQUIRED` / `NONE`); `items` are the unresolved review comments, non-empty
reviews, and issue comments in the `/loop-spec:revise` shape.

Default ownership is `LOOP_SPEC_PR_FEEDBACK_MODE=local`. An external orchestrator that
already owns the review round trip may set `LOOP_SPEC_PR_FEEDBACK_MODE=external` and
`LOOP_SPEC_PR_FEEDBACK_OWNER=<name>`. That returns `observationStatus:"delegated"` and
never claims the PR is clean. There is intentionally no silent `off` mode.

## Routing the result

- **`changesRequested == true`** — a reviewer has blocked the PR. Print every item
  (`author`, `path:line` where present, first line of `body`) and route:
  - **cycle:** recommend `/loop-spec:revise <pr-number>` as the next command; in
    autonomous mode record the unaddressed feedback in the cycle result warnings —
    never self-approve or merge past a CHANGES_REQUESTED decision.
  - **micro / debug:** if the requested change is still micro/bug scale, address it
    now (same protocol, new commit, re-run the check); otherwise hand the items to
    `/loop-spec:revise` (existing feature) or `/loop-spec:intake` (new scope) and say so.
- **`unresolved > 0` without a blocking decision** — early feedback (bot reviews,
  drive-by comments) already exists. List the items and name the follow-up owner;
  informational, not blocking.
- **Clean** (`unresolved == 0`, decision `NONE`/`APPROVED`/`REVIEW_REQUIRED` with no
  items) — print one line: `PR feedback check: clean (decision: <decision>, 0 unresolved items)`.
  A just-opened PR is usually clean; the value is that the claim is checked, not assumed.
- **Delegated** (`observationStatus == "delegated"`) — print the external owner and do
  not run, post, or act on a second review round trip.
- **Degraded** (`observationStatus == "degraded"`) — report the error and never label it clean.

## Degradation (loud, never silent)

- No `gh`, no origin remote, or unauthenticated: the PR step itself already failed —
  print what blocked it, leave the branch pushed/local as far as you got, and record
  the gap (cycle result warnings; micro ledger `--notes`; debug report). Never claim
  a feedback check ran when it could not.
- `gh pr view` metadata failure mid-check: `pr-feedback.sh check` returns a
  machine-readable `observationStatus:"degraded"` record — relay it, never reinterpret
  it as a clean `NONE` decision.

## Recording

- **cycle:** the check result is part of the completion summary printed from
  `delivery.json.targets[]` (per-target: PR URL, decision, unresolved count).
- **micro:** the ledger entry carries the PR (`lib/adhoc-ledger.sh add ... --pr <url>`);
  unaddressed feedback goes in `--notes`.
- **debug:** BUG.md `## Fix` section notes the PR URL and the check outcome.
