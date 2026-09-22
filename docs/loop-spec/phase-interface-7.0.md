# loop-spec 7.0 phase interface: route matrix

Reference for the M1 implementer writing the boundary checks and for a reviewer trying
to break them. For each phase it lists the inputs, the product fields, the
preconditions, the numbered postconditions the program checks, the exits, and which
postconditions gate each exit. Where [ROADMAP-7.0.md](ROADMAP-7.0.md) leaves a route
unspecified, the row says so instead of choosing.

Derived from the roadmap at `98e3288` and revised at `7273b9f` with the decisions of
2026-09-22 (migration inventory, then the M1 fixtures review): section 4 (phase table), section 5
(implementation contract), section 10 (convergence), section 11 (baseline), section 14
(entry points), and section 15 (result). Field lists and JSON schemas land with the
code at M1; this page fixes the shape they must have.

## Shared by every phase

### Envelope (`context.json`)

| Field | Content |
|---|---|
| `run.id`, `attempt.id` | run id; this phase attempt's id |
| `inputs.digest` | digest of every input below; products carry it back |
| `products` | products of prior phases, each with the revisions it was bound to |
| `state` | requirements revision and approval record, plan revision, baseline, finding ledger with reviewed ranges, rewind count and budget |
| `entry` | `fresh`; `remediation` with the gaps to close; or `rewind` with the findings that sent the run back |
| `repos` | repository or workspace map, per-repo base SHA, feature branch, worktree root |
| `paths` | state directory; paths the implementation may write to |
| `answers` | answers recorded against question ids from this attempt, each with scope `question` or `run`; the run's answer policy when a `run`-scoped answer or `--answer-policy` set one |
| `probes` | program probe output for this phase: at PLAN the neighbourhood conventions, existing helpers, base layer count, security signals, and dependency docs per named file; per EXECUTE task the diff-mode findings; at VERIFY the whole-range findings |

### Process contract

| Exit code | File the implementation wrote | Program action |
|---|---|---|
| 0 | `product.json` | validate schema, then check the postconditions for the declared exit |
| 1 | none | program error; the repair named in stderr; nothing advances |
| 2 | `step.json` | hand the step to the lead or the SDK runner; re-invoke on `submit` |
| 3 | `question.json` | surface the question; record the answer against its one-time id; re-invoke |

Any other code advances nothing. An answer to a retired question id is rejected. An
answer scoped `run` answers every later question by the default policy and the result
lists those questions.

### Identities

| Identity | Definition | Effect when stale |
|---|---|---|
| requirements revision | digest of SPEC `goal`, `boundaries`, `criteria`, `decisions`; open questions excluded | approval reopens; every later product bound to the old revision is rejected at its boundary without reading further |
| plan revision | digest of the PLAN product | EXECUTE, VERIFY, ITERATE products bound to the old revision are rejected |
| step attempt id | one per issued step | a result for a retired attempt is rejected by id; timestamps never discriminate |
| question id | one per question asked | an answer to a retired id is rejected |

### Evidence levels

Set by the program per worker step, never by the implementation: `controller-observed`
(the SDK runner itself launched the run and its receipt lives under the state home,
never beside a worker-writable result), `host-attested` (native dispatch with a
transcript checked against the step's entire composed prompt, not just its trailer),
`human-attested` (external phase, answer recorded against a question id),
`unattested` (everything else). Review steps accept `controller-observed` and
`host-attested`; `unattested` is accepted only under `evidence.review.accept:
unattested` in config, and the result then carries `weakenedAssurance`. A judgment
role (`plan-critic`, `code-reviewer`, `iterate-judge`) refuses an `unattested`
submission outright and re-dispatches instead, up to the retry bound; see
`skills/loop-spec/references/contract.md`'s evidence section.

### Backward-transition budget

One postcondition, checked centrally by the program on every exit that routes to an
earlier phase or re-enters the same one. It appears in each such exit's `Requires`.

| Id | Postcondition | Gates |
|---|---|---|
| T1 | the shared feature-level budget has room and this transition was counted once against it; default two, operator override, persisted across sessions, never reset by a fresh attempt. When the budget is spent the program refuses the backward exit and escalates directly from the controller: it writes the terminal `escalated` result itself, naming the refused exit, the gap, and the budget record, without entering any phase. ITERATE is not involved, because its inputs may not exist yet | PLAN `spec gap`; EXECUTE `plan gap`; VERIFY `implementation gap`, `plan gap`, `intent gap`, `evidence incomplete`; ITERATE `rewind` |

## SPEC

| | |
|---|---|
| Inputs | request text; on `rewind`, the intent-gap findings |
| Product | `goal`, `boundaries`, `criteria[]` with ids, `decisions[]`, `openQuestions[]` |
| Preconditions | request text present |
| Runs in | the lead session; interviews with `AskUserQuestion` |

| Id | Postcondition | Gates |
|---|---|---|
| S1 | product validates against the SPEC schema | every exit |
| S2 | an approval record exists, produced from a human or policy answer to a question that names the proposed requirements revision, and the record references that question id | `approved` |
| S3 | the product's own fields did not create the approval record; only the program writes it | `approved` |

| Exit | Requires | Route |
|---|---|---|
| `approved` | S1, S2, S3 | PLAN, `fresh` |
| `needs answer` | S1 | process exit 3; re-enter SPEC with the answer |

## PLAN

| | |
|---|---|
| Inputs | approved SPEC product; program probes on the files the request names; on `rewind` or `remediation`, the plan-gap findings |
| Product | `tasks[]` each with `id`, `dependsOn`, `files`, `repo`, `verify` command, `criteria` covered, optional `featureAdded` target path; `prepare` command; declared evidence exceptions |
| Preconditions | requirements revision approved and current |
| Runs in | the lead session; then one light critic pass over the drafted product for Critical misses only, before submit |

| Id | Postcondition | Gates |
|---|---|---|
| P1 | product validates; bound to the current requirements revision | every exit |
| P2 | every criterion id in the requirements revision is covered by at least one task | `ready` |
| P3 | every verify command either ran at the base SHA from a bare worktree root during baseline capture, or is declared `featureAdded` with a target path that does not exist at base | `ready` |
| P4 | the baseline is captured (section 11) with the prepare command applied; environment health recorded once per failing command | `ready` |
| P5 | the task graph is acyclic and every `dependsOn` names a task in the plan | `ready` |
| P6 | workspace resolved once and the repo list stored in state; every task names a repo in it | `ready` |
| P7 | the critic pass ran and every Critical finding is closed as `fixed` with the critic re-run once on the corrected product, or `rejected` with a stated reason recorded in state; `deferred` is not a disposition for Critical; a Critical finding still open after the one re-run exits `spec gap` or asks a question | `ready` |

| Exit | Requires | Route |
|---|---|---|
| `ready` | P1 to P7 | EXECUTE, `fresh` |
| `spec gap` | P1, T1 | SPEC, `remediation`, with the gap named |

## EXECUTE

| | |
|---|---|
| Inputs | PLAN product; baseline; ledger; on `remediation` from a VERIFY `implementation gap`, the transition carries the failing verdicts and the remediation tasks; EXECUTE re-opens the plan task(s) owning each failed criterion against the current feature head (a clean, terminated worktree that already contains the head is reused, anything else gets a new generation branch and worktree and the old one is kept); `remediationTasks` describe the gap and are not tasks of their own; on `rewind`, the findings |
| Product | per task a `disposition` of `done`, `already-satisfied` with evidence, `removed` by an approved plan amendment, or `adopted` for the one range task a `revise` entry creates; `commits[]` per task; `issues[]` unresolved; per-repo `head` |
| Preconditions | PLAN bound to the current requirements revision; baseline present |
| Runs as | program-run: waves of at most three, one worktree per task, implement step, then the diff-mode probes on the task's commits, then the review step with the probe findings as inputs |

| Id | Postcondition | Gates |
|---|---|---|
| E1 | product validates; bound to the plan and requirements revisions per repo | every exit |
| E2 | every required task has an accepted disposition | `integrated`, `no change` |
| E3 | for every task, its dependencies completed before it was dispatched | `integrated` |
| E4 | every commit in `base..head` maps to exactly one `done` or `adopted` task; in a revise run the adopted PR's own commits count as mapped by the adoption; merge commits the program records during integration are not task commits and are excluded from `base..head` on both sides | `integrated` |
| E5 | every `done` or `adopted` task has a review record whose reviewed range covers all of that task's commits; for an `adopted` task the record comes from a full review step the program ran over the adopted range at entry, never from the PR's own history | `integrated` |
| E6 | every such review record's evidence level meets the accepted class for review steps; otherwise the task is listed in `unreviewed` | `integrated` |
| E7 | each task's verify command produced no new failure identity against its baseline; a `featureAdded` command had a meaningful first success (exit zero, at least one parsed identity where a parser exists) that became its task-local baseline; a `mustFlip` command failed at baseline with the recorded digest and passes at integration | `integrated` |
| E8 | the feature head is reachable from base and was not moved out of band | `integrated`, `no change` |
| E9 | `base..head` is empty and every task is `already-satisfied` or `removed` | `no change`; forbids `integrated` |
| E10 | a rejected step was re-issued with its reason up to the per-step retry limit before `blocked` is claimed | `blocked` |
| E11 | for a task touching a file with a security signal, the review record carries a disposition per signal | `integrated` |

| Exit | Requires | Route |
|---|---|---|
| `integrated` | E1 to E8, E11; E9 false | VERIFY at the integrated head |
| `no change` | E1, E2, E8, E9 | VERIFY at base |
| `blocked` | E1, E10 | pause: a question to the operator naming the cause, with the answers fix-and-re-enter EXECUTE or stop; `status: paused` until answered; a stop answer, or a `run`-scoped default policy, exits terminal `escalated` with the cause |
| `plan gap` | E1, T1 | PLAN, `remediation` |

An out-of-band change to the feature branch pauses the phase for reconciliation; it is
never reset. `already-integrated` (the commit is already an ancestor of the head) is an
integration reason code, not an exit.

A task keeps two anchors: `forkedFrom`, where its current branch forked (moves on every
re-fork, attributes new commits), and `reviewFrom`, its first fork (an adopted task: the
base), which its review record always starts from so one review covers every commit it
owns.

## VERIFY

| | |
|---|---|
| Inputs | requirements revision; EXECUTE product and head; baseline; ledger; on re-entry, the prior VERIFY product |
| Product | per criterion a `verdict` of `pass`, `fail`, or `blocked` with `evidence` (command, repo, SHA, exit status, parsed failure identities, raw output digest); `findings[]` with dispositions and typed `supersedes`; `remediationTasks[]`; `reviewedRanges[]` (one per touched repo) |
| Preconditions | EXECUTE exited `integrated` or `no change` at the current revisions; each repo's verified head equals its integrated head, or its base for `no change` |
| Runs as | the probes once over `base..head`; verifier and reviewer as fresh contexts with those findings; the program re-runs every cited command |

| Id | Postcondition | Gates |
|---|---|---|
| V1 | product validates; bound to both revisions | every exit |
| V2 | every criterion id in the requirements revision has exactly one verdict | every exit except `evidence incomplete` |
| V3 | every evidence SHA equals the verified head of its repo | `passed` |
| V4 | for every criterion without a V5 exception, its cited command was run by the program in a clean checkout of that SHA it created, with prepare fixtures applied (that execution may be reused across submissions naming the same repo, SHA, and command, but is re-matched against each submission's own claim, never a fact an earlier claim left recorded), and command identity, exit status, parsed failure identities, and normalized output digest matched | `passed` |
| V5 | a criterion skipped V4 only under an exception declared in the PLAN product and approved with it, or granted by an operator answer at VERIFY; its verdict is recorded at assurance `claimed` and listed under `weakenedAssurance` | `passed` |
| V6 | a `blocked` verdict cites a cause the program observed, in the baseline record or in its own re-run | `blocked` |
| V7 | every verdict is `pass` and the review policy holds per repo: first and final passes saw that repo's full diff, other passes the delta since its last reviewed SHA, no Critical finding open; evaluated over the ledger with the product's valid same-finding closures applied | `passed` |
| V8 | a finding on cleared code carries a typed `supersedes` naming a finding id or a reviewed-range id; a finding that repeats an open ledger finding by its id, in the same repo and file, is carried forward and needs no `supersedes`; repeating a closed finding is an echo the product drops; reopening one is a new finding with an explicit `supersedes` | every exit |
| V9 | `blocked` for an offline-unavailable dependency was claimed only after a stand-in was tried | `blocked` |

| Exit | Requires | Route |
|---|---|---|
| `passed` | V1 to V5, V7, V8 | ITERATE |
| `implementation gap` | V1, V2, V8, T1; at least one `fail` with remediation tasks | EXECUTE, `remediation` |
| `plan gap` | V1, V2, V8, T1 | PLAN, `remediation` |
| `intent gap` | V1, V2, V8, T1 | SPEC, `remediation` |
| `evidence incomplete` | V1, T1 | VERIFY re-entry, new attempt |
| `blocked` | V1, V2, V6, V8, V9 | pause: a question naming the observed cause, with the answers fix-and-re-enter VERIFY or stop; a stop answer or a `run`-scoped default policy exits terminal `escalated` |

T1 bounds every backward transition, including PLAN to SPEC and EXECUTE to PLAN, so a
PLAN, EXECUTE, PLAN loop spends the same budget as the report's VERIFY, EXECUTE loop
(decided 2026-09-22, coverage completed after the re-audit at `727b2b8`). The review
and verify contract sections say what the budget is for: find show-stoppers and
outright incorrect implementations; the PR review catches the rest.

## ITERATE

| | |
|---|---|
| Inputs | the immutable original request; approved SPEC; integrated diff; VERIFY product; prior gaps; rewind count and budget |
| Product | `verdict` against the original request; `gaps[]`; `route` |
| Preconditions | VERIFY `passed` at the current revisions, including the `no change` head |
| Runs as | a fresh goal-judgment role |

The program, not the judge role, dispositions every non-Critical open finding
before deciding the exit: Minor is always deferred; Important becomes a PLAN gap
while the rewind budget has room, and is deferred once it does not; Critical is
never deferred (decided 2026-09-22, LF-46).

| Id | Postcondition | Gates |
|---|---|---|
| I1 | product validates; the verdict binds every repo's integrated SHA (`boundShas`), the requirements revision, and the plan revision | every exit |
| I2 | every gap names a target of SPEC, PLAN, EXECUTE, or VERIFY | `rewind` |
| I3 | T1 holds for this rewind | `rewind` |
| I4 | a rewind is needed and T1 refuses it, or the verdict is unmet and the judge names no gap any route can close | `escalated` |
| I5 | VERIFY `passed` at this SHA and no open gap against the original goal; the shared convergence predicate | `converged`, `converged with caveats` |
| I6 | no Critical finding open; the caveats list contains only accepted non-Critical review findings, each with a recorded disposition, and nothing else | `converged with caveats` |

| Exit | Requires | Route |
|---|---|---|
| `converged` | I1, I5; no finding open | DELIVER |
| `converged with caveats` | I1, I5, I6 | DELIVER as draft |
| `rewind` | I1, I2, I3 | the named phase, `rewind`, with the findings |
| `escalated` | I1, I4 | DELIVER as partial draft when operator policy allows; otherwise terminal `escalated` |

Past the budget, remediation is restricted to minimal diffs and the implement role's
input flags forbid new broad assertions. A blocked criterion or an open goal gap can
never leave as a caveat: incomplete acceptance reaches a draft PR only through the
explicit escalated partial-delivery policy and keeps the `escalated` classification
(decided 2026-09-22).

## DELIVER

| | |
|---|---|
| Inputs | ITERATE product; per-repo verified SHA; rendered summary; delivery configuration and readiness policy; existing remote state |
| Product | per repo `pr` identity, `deliveredSha`, `caveats[]` |
| Preconditions | ITERATE `converged` or `converged with caveats`; or `escalated` with an operator policy allowing partial delivery as a draft |
| Runs as | program code |

| Id | Postcondition | Gates |
|---|---|---|
| D1 | per touched repo, the remote head ref's SHA equals the verified SHA | `delivered` |
| D2 | per touched repo, the PR is open, its head ref and SHA match, and its base target matches configuration | `delivered` |
| D3 | required checks satisfy the configured readiness policy (6.9's exact-SHA and required-check behavior) | `delivered` |
| D4 | a retried creation was reconciled by identity against existing remote state; no duplicate PR | every exit |
| D5 | partial publication is recorded per repo and never reported as all delivered | `partially delivered` |
| D6 | a `no change` head that ITERATE converged opened no PR and the product says so | terminal `no-change` |
| D7 | before the first remote write the program checked git and `gh` credentials and attempted the host's own refresh; a failure exits `delivery blocked` naming the command | `delivered`, `partially delivered` |
| D8 | the product's repos cover exactly the set of repos EXECUTE touched with an accepted task's commits, no duplicates; a `skipped` row is only valid for a repo EXECUTE did not touch; every row marked `delivered` has a non-null PR | `delivered`, `partially delivered` |

| Exit | Requires | Route |
|---|---|---|
| `delivered` | D1 to D4, D7, D8 for every repo | terminal `converged` or `converged-with-caveats` |
| `partially delivered` | D1, D2, D4, D5, D7, D8 for every repo whose remote write was attempted | terminal `escalated` (never `converged`, whatever ITERATE's own verdict was) with `partiallyDelivered: true`, `workDelivered: true`, and `reason` naming the repos that did not deliver |
| `delivery blocked` | D4 | pause: a question naming the failed command and repair, with the answers fix-and-re-enter DELIVER or stop; a stop answer or a `run`-scoped default policy exits terminal `escalated` with `result: escalated` and per-repo state |

## debug

| | |
|---|---|
| Inputs | error report |
| Product | `reproduction` as command plus failure digest; `diagnosis`; the compact SPEC and PLAN products |
| Preconditions | error report present |
| Establishes | a compact SPEC whose criterion is the reproduction passing, and a compact PLAN with one repair task whose verify command is the reproduction marked `mustFlip`; approval is a question like any other. The repair itself is done by EXECUTE, so it gets an implement step, a review step, and E1 to E11 like any task, and VERIFY receives an ordinary EXECUTE product (decided after the re-audit at `727b2b8`) |

| Id | Postcondition | Gates |
|---|---|---|
| B1 | the program ran the recorded reproduction at base in a clean checkout and it failed with at least one parsed identity or fingerprint; the failure digest it recorded is the `mustFlip` baseline | `reproduced` |
| B2 | a changed reproduction states a reason and the original was run too, with both results recorded | `reproduced` |
| B3 | no reproduction exists | `blocked reproduction`; forbids `reproduced` |

| Exit | Requires | Route |
|---|---|---|
| `reproduced` | B1, B2, S1 to S3, P1 to P7 for the compact products | EXECUTE, `fresh`, with the repair task; then VERIFY, ITERATE, and DELIVER as above. The reproduction passing after the repair is E7's `mustFlip` check, not a debug-local claim |
| `blocked reproduction` | B3 | pause: a question asking for a reproduction or a stop; a stop answer or a `run`-scoped default policy exits terminal `escalated` |

## Entry points and the order

| Entry | Enters | Preconditions checked at entry |
|---|---|---|
| `cycle` | SPEC, then each phase in order | none beyond request text |
| `spec`, `plan`, `execute`, `verify`, `iterate`, `deliver` | the named phase against durable state | that phase's preconditions above |
| `debug` | debug, then EXECUTE with the repair task, then VERIFY onward | error report |
| `micro` | the full order with compact presets | cannot drop a required phase |
| `status` | nothing; read-only | none |
| `revise` | a compact SPEC and PLAN in the lead whose criteria are the PR comments mapped to gaps, with the PR's base as base SHA. The PLAN carries one `adopted` range task for the existing `base..head` commits plus one task per gap. At EXECUTE entry the program runs a full review step over the adopted range, which becomes that task's review record (E5, E6); findings on the adopted code join the gaps. Then EXECUTE on the adopted PR branch, and VERIFY onward over the whole PR | an open PR the repo module can adopt; a PR with no prior loop-spec state gets a fresh run id bound to the PR identity; nothing in the adopted range is exempt from E4 to E7 |

A standalone `deliver` cannot bypass VERIFY or ITERATE: its preconditions require an
ITERATE exit at the current revisions.

## Terminal results

| Program outcome | `result` | Existing schema-1 fields (section 15) |
|---|---|---|
| DELIVER `delivered` after ITERATE `converged` | `converged` | `status: completed`, `outcome: delivered`, `converged: true`, `workDelivered: true` |
| DELIVER `delivered` after `converged with caveats` | `converged-with-caveats` | `outcome: delivered-draft`, `converged: false`, findings in `warnings` |
| ITERATE `converged` on a `no change` head | `no-change` | `outcome: no-change-needed`, `noChangeReason: already-satisfied`, `converged: true`, `workDelivered: false` |
| ITERATE `escalated`; T1 refused at PLAN, EXECUTE, or VERIFY, written by the controller | `escalated` | `status: escalated`, `converged: false` |
| process exit 1; environment cannot run the plan | `failed` | `status: failed`, `converged: false` |
| process exit 3 outstanding, including every `blocked` exit | question pending | `status: paused`, `reason` names the question id and, for a blocked exit, the cause |
| a `blocked` exit answered stop | `escalated` | `status: escalated`, `converged: false`, the cause in `reason` |

The `last-result.json` pointer is written in the state home beside `state.json`.

## Routes settled 2026-09-22

The four routes the first version left for M1, answered from the M1 fixtures review
(`m1-fixtures-7.0.md`, DEC-01 to DEC-06). No route is unspecified.

- Every `blocked` exit pauses with a question and resumes into the same phase or, on a
  stop answer, exits terminal `escalated`. One rule for EXECUTE, VERIFY, debug, and
  DELIVER.
- One shared budget bounds every backward transition (T1, referenced by I3). Exhaustion
  at any exit escalates directly from the controller; only ITERATE's own refused rewind
  goes through I4 (after the re-audit at `8d45bbb`).
- Both converged outcomes share one predicate (I5); caveats hold only accepted
  non-Critical review findings (I6).
- A Critical critic finding closes only as fixed-and-rechecked or rejected-with-reason
  (P7).
- D7 is required for every repo whose remote write was attempted.
- debug and `revise` establish their revisions through a compact SPEC and PLAN; debug's
  repair runs through EXECUTE with a `mustFlip` reproduction, and `revise` reviews the
  adopted range as an `adopted` task before remediation (after the re-audit at
  `727b2b8`).

## Related

- [ROADMAP-7.0.md](ROADMAP-7.0.md) sections 4, 5, and 10: the reasoning behind each row.
- [migration-inventory-7.0.md](migration-inventory-7.0.md): the 6.9 graph probes each route replaces.
