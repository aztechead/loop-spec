# LF-60 attestation exhaustion audit

Reviewed against current steps.submit and judgment postconditions. **Revise the
coverage and recovery specification before implementation.** The central policy is
right: exhaustion must not automatically authorize weaker judgment evidence.

## Required corrections

1. Make the policy mapping unambiguous. The plan first says evidence.judgment.accept
   governs all three roles, then says it covers only critic and judge. Preserve
   evidence.review.accept for code-reviewer, and use judgment.accept for plan-critic
   and iterate-judge. Test the four combinations of these keys so one cannot weaken
   the other role accidentally. Validate/document the new config key.
2. Enforce evidence acceptance for EVERY required role's submission, not just inside
   the existing retry conditional. That condition requires host is not None and no
   receipt file exists. Missing host, missing dispatch, or an invalid/stale SDK receipt
   can therefore skip it. First derive evidence level from the available evidence;
   then apply role policy. Missing evidence cannot make a submission acceptable.
   Valid controller-observed receipts and approved external human attestation retain
   their existing semantics. Add no-host, invalid receipt, missing dispatch cases.
3. Separate refused evidence from an accepted submission. Do not call a role module's
   on_submit or advance its product/ledger/judgment state while the question is open.
   Keep the candidate result as diagnostic evidence, not an accepted result. Pause
   exactly once across repeated calls/resumes. The controller should own question
   routing; steps.submit can report a typed blocked-evidence outcome rather than
   acquiring phase orchestration responsibilities.
4. Define recovery for each role, including its cached step reference. Merely retiring
   the open step can strand criticStepId, reviewer state or judgeStep. Fix-and-re-enter
   issues a fresh step/result/instruction path and rebinds the module's pending step,
   with current input identity. Late results from retired attempts cannot satisfy it.
   Retirement does not prove worker termination: preserve/quarantine its worktree,
   and do not delete or reuse it without the established termination checks.
5. Define rollout for already accepted unattested judgments. The new submit gate alone
   does not invalidate cached critic/judge products accepted under old auto-waiver
   behavior. Check required evidence when consuming cached judgments or resuming a
   phase; require fresh evidence or explicit applicable opt-in. Do not retroactively
   relabel a completed run as attested. Record policy source and affected role/step
   for every accepted weakened-assurance entry, idempotently.

No default on the question is appropriate. The program's default-answer policy will
pause. An external supervisor that explicitly chooses the first option is a different
policy: do not claim every headless harness will stop automatically. Audit/example
documentation should keep that distinction clear.

Tests should cover each role's pause/opt-in matrix, zero advancement, repeated resume,
fresh recovery with stale module cache, late retired submission, and stop preserving
any existing delivery facts. Run deterministic module cases and then the proposed
live refusal/explicit-opt-in cases. A Unicode trigger may cease being unattestable
under LF-59 file transport; arrange a real deliberate evidence mismatch for that
validation instead of assuming reverting LF-57 still triggers it.

No code, config, memory, commits, pushes or running consumer processes changed.


## Second pass: revision 1

**Revise the cached-evidence and recovery details before coding.** Role-specific
policies, evidence-first submission handling, controller-owned questions, and the
explicit headless distinction address most first-pass concerns. Three source-level
mismatches remain.

### 1. Accepted critic shortcut bypasses the proposed cache check

R5 adds evidence validation in _critic_submission, but
_handle_plan_baseline_and_critic returns ready for an existing critic with matching
planRevision and inputsIdentity BEFORE calling _critic_submission. A judgment accepted
under the old waiver can therefore bypass the new check. Validate evidence at both
accepted-critic reuse and submitted-step reuse, with a recorded step identity on the
accepted critic. Missing legacy provenance must cause fresh evidence, not acceptance.
Test a cached accepted critic (not only a submitted step) with matching identity and
unattested evidence. Cover the same-identity VERIFY module state as well as _init;
otherwise an already-populated cached reviewer result can avoid the new init check.

### 2. VERIFY range provenance currently cannot support the new rule

_record_accepted_product reads state.verify.reviewerStep (singular), while verify.py
stores reviewerSteps[repo] (plural). Consequently byStep on recorded ranges can be
None even for a newly attested review. Correct per-repo provenance writing and retain
the original evidence link when a range is reused. For legacy missing links, require
fresh review. Do not guess that a missing link means accepted evidence.

If an old untrusted range ended at the current head, refusing reuse alone is not
sufficient: the current fallback computes prior.to..head, an empty range. Re-review
the actual untrusted range/full base..head, and ensure continuity checks accept that
full re-review. Otherwise LF-60 merely obtains an attested judgment of an empty diff
while leaving the original unreviewed changes unexamined. Test two repos with distinct
step ids, reused provenance, and same-head replacement of an untrusted full range.

### 3. Recovery must cover the real state and suspension boundaries

Adopted full-range code-reviewer steps used by revise are also required evidence;
R4 omits their owning controller state. Add that route to the reset table. VERIFY's
reviewerSteps is filled after submission, so refusal handling must identify the repo
from its issued request/cwd and current pending state, not assume a stored reviewer
step id always exists.

Review refusal currently retires/quarantines the worktree. Resetting EXECUTE to
probing or VERIFY to pendingReviews must not immediately issue a new worker into the
same potentially active/quarantined checkout. Wait for known termination or create
an independent checkout and preserve the old one, following existing lifecycle rules.

Specify atomic/recoverable refusal -> question -> owner reset. Repeated submit is
already rejected as retired, so a crash after retirement but before question creation
needs a resume path that finds the refused record and creates/reattaches exactly one
question. Do not rely on another successful submit of the retired id. Keep a refused
result separate from any previously accepted result record during these transitions.

### Live probe assumption

Do not add a production test-only env that alters attestation trust merely to force
this case. Use an isolated scratch test setup and deliberately wrong dispatch identity
or opening, verifying in the actual run which mismatch the host reports. Never edit
issued evidence to make it appear attested. Testing the launch environment assumption
read-only is fine, but do not claim the negative live case until refusal is observed.

The final test must prove no role handler/phase advancement before explicit policy or
new valid evidence, not just that a question was printed. No implementation or running
consumer changes were made in this audit.


## Third pass: revision 2

**Go to implementation with the persistence/lifecycle corrections below incorporated.**
The revised accepted-critic provenance, per-repo range evidence, full re-review,
adopted-range reset, and explicit live mismatch address the previous design findings.
No further full plan rewrite is required, but the actual helpers do not yet have the
atomicity/reuse properties assumed by S3.

1. `steps.retire` saves internally. To make refusal plus retirement one state write,
   stage both mutations and save once, or add an explicit no-save helper mode with
   unchanged semantics for other callers. Otherwise resume can encounter a retired
   step with no refused record and no question to recover.
2. `questions.ask` saves internally BEFORE returning its question id. A crash after
   that save but before refused[step].questionId is assigned leaves an existing open
   question and a null link. Asking again raises 'a question is already open'. Put the
   refused step id in the question payload and, on resume, adopt the matching already
   created question. Alternatively persist the question and link together. Do not
   overwrite an unrelated open question: defer/queue the refusal until it can be
   addressed. Owner reset and ownerReset=true must likewise be committed together,
   or reset must be idempotent, especially its retry increment.
3. `steps.confirm_terminated` currently REMOVES a clean quarantined worktree after
   recording termination. The plan waits for that confirmation and then reuses the
   EXECUTE review checkout. Those operations conflict: it may no longer exist.
   Separate confirmation from cleanup for a checkout still needed by reviewPending,
   or reconstruct a fresh checkout at the reviewed candidate with correct task/branch
   identity. Never delete then assume the old cwd is reusable. Test actual confirmed-
   termination behavior, not just toggling the known-terminated flag in state.
4. On same-identity VERIFY invalidation, update both the range to full base..head AND
   module phase to reviewing with the relevant pending repo. Dropping cached reviewer
   data alone cannot issue work if phase is still done. Retain prior ledger findings
   until a fully accepted replacement review dispositions them.

Add crash-point tests at the helpers' internal saves, plus confirmation/recovery of
an EXECUTE review and done-state VERIFY invalidation. Keep the explicit policy matrix,
no-handler-before-acceptance tests, and real live refusal/opt-in probe. This is approval
to code with these precise conditions, not evidence that the feature is implemented.

## Test-time ceiling clarification

ROADMAP-7.0.md section 17 explicitly says the 6.9 tests AND their 157-second ceiling
leave with the 6.9 tree. It is not a current 7.x release gate. Keep meaningful module
coverage and add LF-60's cases. Record runtime and investigate avoidable repeated
setup only if profiling warrants it; do not remove failure-path checks or weaken
assertions to fit an obsolete number. No test or policy file was changed by this
review. Any new performance budget should be a separately agreed target measured in
a defined environment, not inferred from 155.8 seconds on this workstation.


## Fresh-checkout recovery check at c7bf51b (implementation e6a3851)

The choice to re-review an immutable candidate in a fresh checkout is reasonable and
avoids waiting for an unavailable CLI termination confirmation. Keep the old worker's
checkout quarantined. There is one important submission-time gap in the current code.

execute.step checks _moved_after_refusal before re-dispatch. However,
_on_review_submit pops reviewCandidate, reads the CURRENT task branch SHA, records
that SHA as reviewedRange.to, and integrates it. on_submit checks feature/default
repo drift but does not call _moved_after_refusal on the task branch. If the retired
worker moves the task branch from H to H2 while the replacement reviewer is reading
its isolated H checkout, the passing review can be relabelled as covering H2.

Before consuming the replacement review, compare the task branch to the saved issued
candidate; retain that binding until integration completes. On movement, block or
re-review as specified, never relabel the old review. Use the captured reviewed SHA
for review range, comparison and merge, rather than a fresh mutable branch read;
this closes the check/use window as well. Bind the candidate at issue, not by reading
a potentially changed task branch later during refusal handling.

Required deterministic case: refuse review at H, issue fresh-checkout review at H,
move the original task branch to H2, submit passing replacement review. H2 must not
be integrated or represented as reviewed. The fixed branch case should still work.
This was source inspection, not a live race reproduction or full LF-60 audit.
