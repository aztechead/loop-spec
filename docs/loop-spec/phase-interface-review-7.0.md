# Review of the 7.0 phase-interface proposal

Reviewed revision: `0da65a0`, 2026-09-22. Scope: the current
[roadmap](ROADMAP-7.0.md), its [runner position](runner-decision-7.0.md), the original
Cloud Run report, and the repository's existing output and delivery contracts.

Verdict: the phase-interface model is a useful architectural separation, but its
stated postconditions do not yet support the claimed completion guarantees. The
runner count is not the only decision left. The findings below are counterexamples
to the written plan, not failures reproduced against a 7.0 implementation.

The roadmap is primarily an explanation/decision document. Its phase table is an
appropriate reference section. The main issue is substantive: the surrounding prose
promises stronger guarantees than that table defines. Keep the structure and make
observable predicates, reported judgments, and unresolved enforcement explicit.

## Findings

### F1 — P1: the result file proves transport, not reviewer execution

Roadmap sections 4 and 8; runner document's new position section.

Counterexample: an implementer or lead writes a valid review result at the requested
path with the current nonce and reviewed SHA. Its timestamp is fresh. No reviewer
was launched. All three proposed receipt properties hold, and the EXECUTE row has
its review verdict. This reproduces the report's central failure: claiming reviewed
completion after skipping a reviewer. No hostile plugin is needed; a lead trying
to recover from a failed dispatch is enough.

A nonce correlates a result with a request. It does not identify its author or prove
that the requested role ran. The same applies to external implementations.

Required correction: separate the worker-written payload from controller/host-
observed execution metadata. Bind a completed dispatch or explicit human review
attestation to run, attempt, role, repository, input SHA, review range, method, and
result digest. Specify what constitutes accepted evidence for native and external
implementations, including what happens when the host cannot provide it. Do not
claim either metadata or a transcript proves the review's semantic quality.

Remove the runner document's claim that a file receipt fully answers the execution
concern. It answers the lead's payload-relay concern only.

### F2 — P1: VERIFY can accept unsupported PASS claims

Roadmap section 4, VERIFY row and the following paragraph.

Counterexample: ten criteria are marked PASS at the current SHA; evidence for nine
is valid and one is unsupported. The sample selects only valid commands. Every
written postcondition passes. Even checking all supplied commands is insufficient
when a criterion is backed by a command that exits zero without testing it.

The row also requires every criterion to have a verdict, but does not explicitly
make PASS versus blocked/failing status control the selected exit. Section 9
implies that distinction; the reference contract must encode it.

Required correction: remove the guaranteed-detection claim about spot checks.
Separate structurally valid evidence, independently observed execution, and the
judgment that evidence proves the criterion. Define exact criterion-ID coverage,
accepted status combinations, mandatory evidence versus optional sampling, command
identity and environment, and who checks relevance. A `passed` outcome requires
all required acceptance conditions and the review policy to pass. Residual model
judgment must be acknowledged; no boundary can mechanically prove every user intent.

### F3 — P1: EXECUTE can complete with planned tasks missing

Roadmap section 4, EXECUTE row.

Counterexample: PLAN contains tasks A and B. Only A is implemented, reviewed, and
verified. Every existing commit belongs to A and satisfies the row. B has no commit,
so no listed postcondition rejects `integrated`. An empty diff is an even smaller
case: the universal statement about commits is vacuously true.

Required correction: check both directions. Every required task must have an
accepted disposition, and every product-changing commit must map to accepted work.
Define task completion, explicit already-satisfied evidence, dependency completion,
and approved plan amendments. Outstanding required work prevents `integrated`.
Review coverage needs a base/head range or equivalent tree identity, not an arbitrary
later SHA described as covering a commit. Bind the integrated result to current
plan and spec revisions per repository.

### F4 — P1: approval identity does not cover the acceptance contract

Roadmap section 4, SPEC and ITERATE rows; section 5 question protocol.

Counterexample: leave goal and boundary text unchanged, but remove or weaken an
acceptance criterion or change a binding decision. The stated approval digest is
unchanged. PLAN and VERIFY use the easier criteria, and ITERATE supplies that same
digest. The rows contain no machine check that invalidates the earlier approval.

This is inherited from 6.9's narrower intent guard, not a newly discovered runtime
regression. The stronger interface claim makes its scope important.

Required correction: distinguish approved intent from versioned execution
requirements. Include binding criteria and decisions in the approval scope, or
explicitly classify which changes need re-approval. Every product must bind to the
current requirement revision even for changes that need no new human approval.
Approval records must come from the actual human/policy response and reference the
question and proposed digest, not an implementation's `approved` field.

### F5 — P1: delivery can succeed against the wrong PR or failed checks

Roadmap section 4, DELIVER row, versus `lib/pr-delivery.sh` and
`agent-output-contract.md`.

Counterexample: the intended remote feature branch has the verified SHA, and a PR
exists in that repository, but its head branch or base target is wrong, it is closed,
or required checks failed. There are no caveats. Each written DELIVER predicate
can still hold. A PR existing per repository does not bind it to the verified target.

Required correction: bind the PR identity to repository, head repository/ref/SHA,
base target, lifecycle state, and the configured readiness policy. Preserve the
existing exact-SHA checks and required-check behavior, or explicitly accept a
migration. Reconcile duplicate/retried creation and record partial workspace
publication without claiming all targets delivered. Define already-satisfied
no-change completion, which currently has no path through the mandatory PR rule.

### F6 — P1: attempt and state ownership are asserted without a protocol

Roadmap sections 5, 7, 8, and 11.

Counterexample: an old worker writes after a retry has begun, or a stale question
answer arrives after SPEC changed. The plan does not specify attempt retirement,
answer correlation, atomic file consumption, or duplicate-submit semantics. A fresh
file timestamp alone does not distinguish these cases.

The claim that a bound skill cannot reach state also lacks a mechanism. A directory
path in context and appended prompt text do not restrict a worker's filesystem
access. `loop-spec emit` similarly must not let a worker publish authoritative
completion simply by requesting that event.

Required correction: define versioned run/phase/attempt IDs, immutable input digests,
one-time question identity, atomic result publication, idempotent duplicate submit,
stale-result rejection, cancellation and child cleanup, and a single state writer.
Separate implementation progress events from controller-only transition/result
records. State whether workers are cooperative and trusted or whether access is
actually restricted; do not promise write isolation from instructions alone.
The runner contract needs lifecycle behavior beyond `execute_step -> result`.

### F7 — P1: the promised 6.9 stream compatibility is not specified accurately

Roadmap section 14 versus current `agent-output-contract.md`,
`skills/shared/report-style.md`, and `lib/events.sh`.

Concrete mismatches:

- Current graph `--step` output keeps its descriptor on stdout and sends phase
  markers to stderr. The roadmap says markers are on stdout, without this exception.
- Current `events.sh` selects stdout console output on Cloud Run when neither
  explicit stream is selected. The roadmap's default-stderr description omits it.
- The current contract includes `attemptId`, terminal schema/version fields, an
  atomic `.loop-spec/last-result.json`, stale-result clearing, and delivery/convergence
  distinctions. The new four result labels have no explicit mapping to those fields.
- Cutover deletes the output style while promising its chat behavior. Program console
  lines alone do not establish how the lead's user-visible conversation behaves.

Required correction: publish a compatibility matrix and fixtures covering actual
stream placement, environment precedence, terminal fields and meanings, pointer
behavior, interruption, draft delivery, and versioning. Decide whether to retain the
style or demonstrate its replacement. These changes may be intentional, but cannot
be called a verbatim carryover without resolving the differences.

### F8 — P2: legitimate phase outcomes have no consistent route

Roadmap sections 4, 9, and 10.

Examples:

- DELIVER requires ITERATE converged, while section 9 also delivers an escalated
  partial result as a draft. Converged-with-caveats is not named in the precondition.
- VERIFY can mark blocked only for baseline causes. A credential expires or a
  provider becomes unavailable after baseline: neither that restriction nor treating
  it as an implementation failure gives an honest route.
- PLAN must run every verify command at base, but feature-specific test files may
  not exist there yet. A missing future test is different from a broken environment.
- ITERATE cannot route to VERIFY for missing evidence, although the existing 6.9
  phase explicitly supports that route.
- debug has no explicit blocked-reproduction exit and does not bind its before/after
  check to the same reproduction. Changing the test itself can manufacture red/green.
- Review `supersedes` names an earlier finding, but a clean reviewed range has no
  finding. Adding ranges to the ledger does not define a finding ID for them.

Required correction: write the route matrix before calling the table the interface.
Include partial delivery eligibility, newly observed environment failures,
feature-specific checks, evidence-only rewinds, explicit debug blockers, and typed
review-coverage references. Bind debug evidence to the same reproduction definition
or require an explained, independently checked change to it.

### F9 — P2: fresh phase contexts and format-only compatibility are overstated

Roadmap sections 1, 6, and 19; runner document's new position section.

The report praises separate per-phase sessions. The roadmap promises to keep that,
but specifies SPEC and PLAN in the lead's existing context and tests fresh workers
rather than fresh phase entry. It needs a host-specific account of which contexts
are fresh and how questions and decisions survive the handoff.

Also, `external` does not implement the user's earlier format-only option: the
program still verifies postconditions and controls progression. The interface model
can supersede that preference as a new decision, but it is a changed boundary, not
an equivalent way to obtain pure format-only behavior.

Required correction: state the changed architectural choice and the precise context
lifecycle. Preserve native Claude Code installation, authentication, interviews,
permissions, and cancellation in the live gate; no SDK pass substitutes for these.

## What can and cannot be guaranteed

For ITERATE, a correctly bound verdict can still be a mistaken judgment of the
original goal. That is not a missing hash check. The same is true of review quality
and acceptance relevance. The plan should guarantee the execution/evidence protocol
it can observe and explicitly retain model judgment where it cannot prove semantics.

The challenge “find any false completion that passes the row” is useful, but cannot
be an absolute completeness criterion for arbitrary software. Use it to identify
missing observable checks such as skipped tasks, stale evidence, wrong PR identity,
and unexecuted review. Do not claim the revised boundary proves that every semantic
judgment was correct.

## Recommended disposition

Keep phases as interfaces. Do not approve M0 on the claim that only runner count is
pending. Resolve F1–F7 in the contract and give F8–F9 explicit decisions before
implementation. For each implementation kind, derive rejection fixtures from the
counterexamples above. Then verify real dispatch, fresh context, permissions, and
handoffs separately in interactive Claude Code and the SDK.

The reviewer did not edit the two favored-plan documents or run paid model tests.
This review checks the committed prose against current contracts; it does not claim
that any proposed 7.0 mechanism is implemented or tested.
