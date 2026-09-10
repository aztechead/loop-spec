# Compact route and profile contract

`/loop-spec:auto` may select `route: "compact"` for a confidently classified,
bounded feature or refactor. Compact stays inside the existing cycle with
`autonomous profile:compact`; it is not a separate lifecycle.

The classifier proposes the route from repository evidence.
The validator requires confidence of at least `0.7`, ambiguity below `high`, at most 12 reviewable files, and at most 6 criteria.
Destructive compact proposals promote to `full`.
Security, migration, multi-repository, dirty-worktree, interface, seam, and dependency signals do not automatically exclude compact.
The gate plan must explain how the bounded change handles those concerns, using repository evidence.

## `gatePlan` schema

Every compact proposal carries `gatePlan` with exactly these ten entries:

```json
{
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

Each entry is exactly `{run:boolean, reason:nonblank single-line string of at most 240
characters}`. The plan is durable:
the normalized classification persists it so execution can apply the classifier's
decisions and record why each adaptable gate ran or did not run. A malformed or
incomplete plan promotes the route to `full`.

`specCritique` depends on `discuss`: its `run` value may be `true` only when
`discuss.run` is also `true`. The verification gates remain independently selectable.

Compact does not waive integrity or delivery requirements. Repository validation,
placeholder and tamper scans, acceptance evidence, review, iteration, and Exact-SHA
delivery remain represented explicitly in the cycle contract.

`lib/cycle-profile.sh` selects `compact` only from a valid normalized compact decision.
It continues to support `maintenance` and `standard` as explicit operator overrides;
`profile:compact` and `LOOP_SPEC_CYCLE_PROFILE=compact` must still be paired with the
persisted normalized compact classification. Without it, they resolve `standard`.
