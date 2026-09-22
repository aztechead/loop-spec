# Re-audit of the 7.0 phase-interface contract

Reviewed revision: `f0a7202`. Scope: the updated [roadmap](ROADMAP-7.0.md), the
current-position section of the [runner document](runner-decision-7.0.md), and all
nine findings in the [previous review](phase-interface-review-7.0.md).

Verdict: substantial progress, but the opening claim that all nine findings are
closed is premature. The phase-interface architecture remains reasonable. The
remaining issues concern its acceptance policy, evidence execution, and consistency.
These are findings about the proposed contract, not tests of implemented 7.0 code.

## Previous findings

| Finding | Current assessment |
|---|---|
| F1: file receipt versus execution | Partial. Transport is correctly distinguished, but acceptance of unattested reviews and dispatch binding remain unspecified. |
| F2: sampling and unsupported PASS | The sampling counterexample and semantic overclaim are addressed. Full re-runs introduce the reproducibility and checkout issues below. |
| F3: missing tasks | Closed in the written contract: required dispositions, dependency completion, and commit mapping are explicit. |
| F4: approval scope | Closed in the written contract: criteria and decisions are revisioned and approval comes from a correlated human/policy answer. |
| F5: wrong PR/readiness | The original PR-identity and check counterexamples are addressed. No-change routing and result compatibility remain incomplete. |
| F6: identity/lifecycle/ownership | Mostly addressed: attempt IDs, atomic publication, stale rejection, idempotence, and cooperative trust are explicit. Retired workers' repository writes still need handling. |
| F7: stream compatibility | Partial: stream exceptions and output style are addressed; schema-1 outcome compatibility is not. |
| F8: missing routes | Partial: new environment failures, VERIFY rewinds, partial delivery, and typed coverage are addressed. No-change and feature-added checks remain inconsistent. |
| F9: context/format-only | Addressed in the roadmap as explicit choices. The runner document's current-position section still contradicts them. |

“Closed” here means that the stated counterexample is rejected by the written
contract. Implementation and live-host evidence remain future work.

## Remaining findings

### R1 — P1: review evidence can still be optional at acceptance

Roadmap lines 221–233 and EXECUTE at line 143.

The EXECUTE row requires an evidence level to be recorded, not an acceptable level.
Section 5 says policy *can* require a minimum. Without one, the original fabricated
review can be recorded as `unattested`, included in `reviewed`, and accepted as
`integrated`. Section 6 still promises no unreviewed commits.

Also, checking that a transcript postdates the step and contains its result digest
does not establish that the requested review role ran against the assigned input
range. An implementation session can contain the same digest.

Specify default accepted evidence classes per role and mode. An unattested review
must not satisfy a guaranteed-review gate by default; an explicit exception must
remain visible as weaker assurance. Host attestation needs to bind the actual
completed dispatch, role/method, attempt/input digest, repository, and reviewed range
to the result. Probe that mechanism in native Claude Code before making the native
path depend on it. An unavailable transcript must not silently force SDK credentials
or claim a review happened.

### R2 — P1: exact output-digest equality recreates a reported failure class

Roadmap VERIFY row at line 144.

Two successful runs of the same test commonly print different elapsed times,
temporary paths, or output order. The proposed raw output digests differ, so the
boundary rejects valid verification. Repeating the step cannot make elapsed times
reliably identical. The report's baseline failure was also caused by treating
incidental output changes as meaningful regressions.

Keep a raw digest for provenance, but compare explicitly defined semantic evidence:
command identity, exit status, parsed test/failure identities, criterion observations,
and a versioned normalization rule where appropriate. State what happens for
nondeterministic commands and commands that cannot safely be repeated. Section 11's
baseline normalization does not currently apply to this new evidence comparison.

### R3 — P1: the evidence SHA does not establish the tested repository contents

Roadmap VERIFY row at line 144 and cancellation at lines 208–210.

The controller re-runs in the implementation-supplied working directory. A checkout
can have HEAD at the expected SHA while uncommitted edits make a failing test pass.
Both the worker and controller can observe the same passing result there, but the
committed and delivered tree remains broken. Neither matching SHA fields nor
matching command output detects that condition.

A retired native worker is another source of these changes: rejecting its result
does not stop it editing a worktree reused by the next attempt. The plan explicitly
allows the host process to remain alive.

Bind evidence to controller-resolved repository/worktree identity and a known source
snapshot. Run checks in a clean checkout of the target commit, with declared
environment fixtures, or define equivalent dirty-tree detection before and after.
Keep still-live retired attempts' workspaces separate from new attempts, and do not
integrate or delete them while their lifecycle is unresolved. This is accidental
concurrency handling within the cooperative-worker model, not a hostile-worker
sandbox requirement.

### R4 — P1: “schema 1 kept additively” changes existing result meanings

Roadmap lines 571–577 versus `agent-output-contract.md` lines 88–160.

The existing no-change result uses `outcome: no-change-needed`, an explicit
`noChangeReason`, and validated convergence. The roadmap replaces that outcome with
`no-change` while calling the mapping additive. It likewise introduces `converged`
and `converged-with-caveats` as existing-field outcomes without mapping the current
`converged`, `implementationConverged`, `workDelivered`, verification, draft/readiness,
and retry fields. Existing consumers can misclassify or fail to recognize results.

Deferring a matrix to M1 is reasonable, but does not make the stated mapping
compatible. Preserve the old fields and meanings and add a separate classification,
or declare a versioned migration. Include no-change, delivered draft, caveats,
partial workspace publication, interruption, and delivery-blocked fixtures. Do not
close F7 until the mapping is defined.

### R5 — P2: no-change and feature-added routes still conflict

Roadmap phase table, section 11, and milestone M1.

EXECUTE explicitly prohibits `integrated` for an empty range, while VERIFY requires
an integrated head and ITERATE requires VERIFY passed. DELIVER mentions no-change
but still requires ITERATE. Thus an already-satisfied request has no explicit path
through the required verification and goal checks. M1 asks for an empty cycle,
making this relevant before implementation begins.

Separately, PLAN permits a `feature-added` check that cannot run at base. Section 11
still requires every plan command to run at base, and EXECUTE compares each command
against a baseline that does not exist for that new check. Define a baseline state
for unavailable-at-base checks and require meaningful candidate success at first
integration. Absence at base is neither failure evidence nor automatic tolerance.

Specify a validated unchanged candidate head that can enter VERIFY and ITERATE,
then terminate without a PR. Make no-change eligibility explicit rather than
bypassing those phases. Reconcile the feature-added exception across all three rows.

### R6 — P2: the two documents still contradict their recorded decisions

Runner document lines 19–21 and 38–50; roadmap sections 6, 8, and 18.

The runner document's current-position section still says boundary checks make a
valid product unable to describe false completion and that `external` supplies the
pure instruction-led option. The roadmap now correctly limits semantic guarantees
and explicitly calls external a change from format-only behavior. These are current
claims, not preserved historical review text.

The roadmap also says workers are unsandboxed and can access state in section 6,
then says a borrowed skill cannot reach state in section 8. Milestone M4 still names
a spot check after the contract switched to full re-runs. The runner's pointers to
section 8 as the runner decision are stale; it is now section 9.

Update the current-position text and these stale assertions. Keep the old comparison
as historical evidence if desired, but do not describe conflicting current claims
as resolved.

## Validation

- Read the updated phase table, lifecycle, trust, default implementations,
  convergence, baseline, output contract, live gates, and milestones.
- Compared each prior finding with its proposed correction and the current runner
  position. Checked result mappings against the existing consumer contract.
- Used a disposable Git fixture to confirm that HEAD can remain unchanged while
  modified working-tree content satisfies a check. The fixture was removed.
- Confirmed that identical pass counts with different elapsed-time text produce
  different raw output hashes. This demonstrates R2's equality problem, not the
  behavior of a future 7.0 verifier.

Native Claude Code support remains explicit: existing login, lead interviews,
settings/permissions, output style, and a separate live gate. The new attestation
mechanism must be proven there without silently downgrading acceptance or requiring
SDK authentication. No paid model calls or live compatibility tests were run.
