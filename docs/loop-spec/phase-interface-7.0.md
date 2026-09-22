# loop-spec 7.0 phase interface: route matrix

Reference for the M1 implementer writing the boundary checks and for a reviewer trying
to break them. For each phase it lists the inputs, the product fields, the
preconditions, the numbered postconditions the program checks, the exits, and which
postconditions gate each exit. Where [ROADMAP-7.0.md](ROADMAP-7.0.md) leaves a route
unspecified, the row says so instead of choosing.

Derived from the roadmap at `98e3288`: section 4 (phase table), section 5
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
(SDK runner), `host-attested` (native dispatch with a checked transcript),
`human-attested` (external phase, answer recorded against a question id),
`unattested` (everything else). Review steps accept `controller-observed` and
`host-attested`; `unattested` is accepted only under `evidence.review.accept:
unattested` in config, and the result then carries `weakenedAssurance`.

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
| P7 | the critic pass ran and recorded either no Critical finding or a disposition for each | `ready` |

| Exit | Requires | Route |
|---|---|---|
| `ready` | P1 to P7 | EXECUTE, `fresh` |
| `spec gap` | P1 | SPEC, `remediation`, with the gap named |

## EXECUTE

| | |
|---|---|
| Inputs | PLAN product; baseline; ledger; on `remediation`, the tasks or gaps to close; on `rewind`, the findings |
| Product | per task a `disposition` of `done`, `already-satisfied` with evidence, or `removed` by an approved plan amendment; `commits[]` per task; `issues[]` unresolved; per-repo `head` |
| Preconditions | PLAN bound to the current requirements revision; baseline present |
| Runs as | program-run: waves of at most three, one worktree per task, implement step, then the diff-mode probes on the task's commits, then the review step with the probe findings as inputs |

| Id | Postcondition | Gates |
|---|---|---|
| E1 | product validates; bound to the plan and requirements revisions per repo | every exit |
| E2 | every required task has an accepted disposition | `integrated`, `no change` |
| E3 | for every task, its dependencies completed before it was dispatched | `integrated` |
| E4 | every commit in `base..head` maps to exactly one `done` task | `integrated` |
| E5 | every `done` task has a review record whose reviewed range covers all of that task's commits | `integrated` |
| E6 | every such review record's evidence level meets the accepted class for review steps; otherwise the task is listed in `unreviewed` | `integrated` |
| E7 | each task's verify command produced no new failure identity against its baseline; a `featureAdded` command had a meaningful first success (exit zero, at least one parsed identity where a parser exists) that became its task-local baseline | `integrated` |
| E8 | the feature head is reachable from base and was not moved out of band | `integrated`, `no change` |
| E9 | `base..head` is empty and every task is `already-satisfied` or `removed` | `no change`; forbids `integrated` |
| E10 | a rejected step was re-issued with its reason up to the per-step retry limit before `blocked` is claimed | `blocked` |
| E11 | for a task touching a file with a security signal, the review record carries a disposition per signal | `integrated` |

| Exit | Requires | Route |
|---|---|---|
| `integrated` | E1 to E8, E11; E9 false | VERIFY at the integrated head |
| `no change` | E1, E2, E8, E9 | VERIFY at base |
| `blocked` | E1, E10 | terminal `escalated` unless an operator answer re-enters EXECUTE; unspecified, settle at M1 |
| `plan gap` | E1 | PLAN, `remediation` |

An out-of-band change to the feature branch pauses the phase for reconciliation; it is
never reset. `already-integrated` (the commit is already an ancestor of the head) is an
integration reason code, not an exit.

## VERIFY

| | |
|---|---|
| Inputs | requirements revision; EXECUTE product and head; baseline; ledger; on re-entry, the prior VERIFY product |
| Product | per criterion a `verdict` of `pass`, `fail`, or `blocked` with `evidence` (command, SHA, exit status, parsed failure identities, raw output digest); `findings[]` with dispositions and typed `supersedes`; `remediationTasks[]`; `reviewedRange` |
| Preconditions | EXECUTE exited `integrated` or `no change` at the current revisions; the verified head equals the integrated head, or base for `no change` |
| Runs as | the probes once over `base..head`; verifier and reviewer as fresh contexts with those findings; the program re-runs every cited command |

| Id | Postcondition | Gates |
|---|---|---|
| V1 | product validates; bound to both revisions | every exit |
| V2 | every criterion id in the requirements revision has exactly one verdict | every exit except `evidence incomplete` |
| V3 | every evidence SHA equals the verified head | `passed` |
| V4 | the program re-ran every cited command in a clean checkout of that SHA that it created, with prepare fixtures applied, and command identity, exit status, parsed failure identities, and normalized output digest matched | `passed` |
| V5 | a criterion skipped V4 only under an exception declared in the PLAN product and approved with it, or granted by an operator answer at VERIFY; its verdict is recorded at assurance `claimed` and listed under `weakenedAssurance` | `passed` |
| V6 | a `blocked` verdict cites a cause the program observed, in the baseline record or in its own re-run | `blocked` |
| V7 | every verdict is `pass` and the review policy holds: first and final passes saw the full diff, other passes the delta since the last reviewed SHA, no Critical finding open | `passed` |
| V8 | a finding on cleared code carries a typed `supersedes` naming a finding id or a reviewed-range id | every exit |
| V9 | `blocked` for an offline-unavailable dependency was claimed only after a stand-in was tried | `blocked` |

| Exit | Requires | Route |
|---|---|---|
| `passed` | V1 to V5, V7, V8 | ITERATE |
| `implementation gap` | V1, V2, V8; at least one `fail` with remediation tasks | EXECUTE, `remediation` |
| `plan gap` | V1, V2, V8 | PLAN, `remediation` |
| `intent gap` | V1, V2, V8 | SPEC, `remediation` |
| `evidence incomplete` | V1 | VERIFY re-entry, new attempt |
| `blocked` | V1, V2, V6, V8, V9 | ITERATE, which may escalate; unspecified whether an operator answer can re-enter VERIFY, settle at M1 |

Remediation entries do not advance the rewind counter; only ITERATE's `rewind` does
(section 10). Whether the VERIFY to EXECUTE remediation loop has its own bound is
unspecified; settle at M1.

## ITERATE

| | |
|---|---|
| Inputs | the immutable original request; approved SPEC; integrated diff; VERIFY product; prior gaps; rewind count and budget |
| Product | `verdict` against the original request; `gaps[]`; `route` |
| Preconditions | VERIFY `passed` at the current revisions, including the `no change` head; or VERIFY `blocked` |
| Runs as | a fresh goal-judgment role |

| Id | Postcondition | Gates |
|---|---|---|
| I1 | product validates; the verdict binds the integrated SHA, the requirements revision, and the plan revision | every exit |
| I2 | every gap names a target of SPEC, PLAN, EXECUTE, or VERIFY | `rewind` |
| I3 | the rewind counter advanced and is within budget | `rewind` |
| I4 | the budget is spent, or a criterion or goal gap is open that no route can close | `escalated` |
| I5 | no gap open; VERIFY `passed` | `converged` |
| I6 | no Critical finding open; non-Critical findings remain with recorded dispositions | `converged with caveats` |

| Exit | Requires | Route |
|---|---|---|
| `converged` | I1, I5 | DELIVER |
| `converged with caveats` | I1, I6 | DELIVER as draft |
| `rewind` | I1, I2, I3 | the named phase, `rewind`, with the findings |
| `escalated` | I1, I4 | DELIVER as partial draft when operator policy allows; otherwise terminal `escalated` |

Past the budget, remediation is restricted to minimal diffs and the implement role's
input flags forbid new broad assertions.

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

| Exit | Requires | Route |
|---|---|---|
| `delivered` | D1 to D4, D7 for every repo | terminal `converged` or `converged-with-caveats` |
| `partially delivered` | D4, D5 | terminal; result carries `partiallyDelivered` and per-repo state |
| `delivery blocked` | D4 | terminal; result mapping is an M1 fixture (section 15) |

## debug

| | |
|---|---|
| Inputs | error report |
| Product | `reproduction` as command plus digest; `diagnosis`; `repair` commits; post-fix evidence |
| Preconditions | error report present |

| Id | Postcondition | Gates |
|---|---|---|
| B1 | the program re-ran the recorded reproduction and it failed before the repair and passes after | `repaired` |
| B2 | a changed reproduction states a reason and the original was re-run too | `repaired` |
| B3 | no reproduction exists | `blocked reproduction`; forbids `repaired` |

| Exit | Requires | Route |
|---|---|---|
| `repaired` | B1, B2 | VERIFY, then ITERATE and DELIVER as above |
| `blocked reproduction` | B3 | terminal; result mapping unspecified, settle at M1 |

## Entry points and the order

| Entry | Enters | Preconditions checked at entry |
|---|---|---|
| `cycle` | SPEC, then each phase in order | none beyond request text |
| `spec`, `plan`, `execute`, `verify`, `iterate`, `deliver` | the named phase against durable state | that phase's preconditions above |
| `debug` | debug, then VERIFY onward | error report |
| `micro` | the full order with compact presets | cannot drop a required phase |
| `status` | nothing; read-only | none |
| `revise` | EXECUTE in `remediation` on the adopted PR branch, with PR comments as gaps; then VERIFY onward | an open PR the repo module can adopt |

A standalone `deliver` cannot bypass VERIFY or ITERATE: its preconditions require an
ITERATE exit at the current revisions.

## Terminal results

| Program outcome | `result` | Existing schema-1 fields (section 15) |
|---|---|---|
| DELIVER `delivered` after ITERATE `converged` | `converged` | `status: completed`, `outcome: delivered`, `converged: true`, `workDelivered: true` |
| DELIVER `delivered` after `converged with caveats` | `converged-with-caveats` | `outcome: delivered-draft`, `converged: false`, findings in `warnings` |
| ITERATE `converged` on a `no change` head | `no-change` | `outcome: no-change-needed`, `noChangeReason: already-satisfied`, `converged: true`, `workDelivered: false` |
| ITERATE `escalated`; EXECUTE `blocked` | `escalated` | `status: escalated`, `converged: false` |
| process exit 1; environment cannot run the plan | `failed` | `status: failed`, `converged: false` |
| process exit 3 outstanding | question pending | `status: paused`, `reason` names the question id |

The `last-result.json` pointer is written in the state home beside `state.json`.

## Unspecified routes to settle at M1

Collected from the rows above so none is chosen silently.

- EXECUTE `blocked`: terminal, or re-enterable by operator answer.
- VERIFY `blocked`: whether an operator answer can re-enter VERIFY before ITERATE.
- A bound on the VERIFY to EXECUTE remediation loop, separate from the rewind budget.
- DELIVER `delivery blocked` and debug `blocked reproduction`: their `result` and
  schema-1 mapping, as fixtures in the M1 compatibility matrix.

## Related

- [ROADMAP-7.0.md](ROADMAP-7.0.md) sections 4, 5, and 10: the reasoning behind each row.
- [migration-inventory-7.0.md](migration-inventory-7.0.md): the 6.9 graph probes each route replaces.
