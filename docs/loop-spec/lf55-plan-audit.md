# LF-55 plan audit

Reviewed at 9fc76e9 on 2026-09-22 against the supplied plan-lf55.md and current
controller, EXECUTE/VERIFY, postconditions and schemas. Accept D1–D4 as settled:
ITERATE may create execute close-outs, proof is review rather than a new task command,
no additional size limit, and no generic no-change rewind guard.

**Disposition: revise before implementation.** The close-out design can fit those
decisions, but the current map does not yet establish mandatory completion and review.

## F1 — Make accepted close-outs mandatory at the boundary

E2 currently walks only PLAN tasks. Merely teaching E4/E5 where to find C-n's repo
allows a product to omit every close-out: no new commits exist, old plan coverage
still holds, and none of E5/E6/E7 loops over the absent tasks. That reproduces false
EXECUTE completion despite an accepted ITERATE request.

Register accepted close-outs in controller-owned durable state, with source accepted
ITERATE attempt, gap identity/text, resolved repo and input revisions. Register once
when the transition is accepted, or otherwise make the boundary independently derive
the required set. Do not make this exist only when default execute._handle_rewind
happens to run: external EXECUTE implementations must face the same obligations.
E2 must require each active registered close-out exactly once, reject unknown IDs,
and enforce its allowed completion disposition. Preserve integrated history through
PLAN reconciliation and subsequent rewinds. E7 exemption must use that authoritative
registration, never an arbitrary C-prefix or worker-controlled marker.

Add a product omitting C-1, a duplicate/unknown C id, and an external implementation
omitting the registered close-out: all must fail with actionable boundary messages.
The default trailing wave alone cannot enforce the phase interface.

## F2 — The existing no-change path bypasses the promised review

execute._on_implement_submit accepts an already-satisfied report at a clean unchanged
fork. _final_product emits already-satisfied with no review; E5/E6 only check done and
adopted. Applying those paths unchanged to C-n permits an implementer's claim alone
to close review-only work. E2 currently checks even already-satisfied evidence only
for PLAN tasks.

Specify close-out review for no-change claims too. Either permit a no-change closure
with an attested review of the gap against the current head, or require an actionable
blocked/escalated outcome when it cannot be established. Do not require a meaningless
commit solely to get review. E5/E6 must cover every accepted close-out disposition.
Review inputs must explicitly ask whether the gap is closed, not just whether the
diff is acceptable. Include the gap and source provenance in the persisted product
or its authoritative context so boundary reviewers can inspect that obligation.

Test no-change implementer claim without review fails, accepted attested no-change
review if supported, failing/unattested review, and normal committed closure.

## F3 — Finish producer schemas and task-derived inputs

The plan updates schemas/iterate.json but omits
skills/loop-spec/roles/iterate-judge/schema.json. That role schema has
additionalProperties=false on gaps and does not allow repo. A judge following the
new prompt would be rejected before the phase product exists. Update both schemas.
Validate an explicitly provided repo even in a single-repo run; default only an
omitted repo. Automatic ledger-derived gaps with missing repo in a workspace must
fail with a repair path, never select an arbitrary repository.

The proposed _TASK_ID_RE replacement [TC]-\d+ drops valid R-n PLAN IDs: plan.json
allows [TR]-[0-9]+. Preserve T/R and add C, with exact identity matching where feasible.

Adding stand-ins with files=[] to VERIFY's tasks does not make probes see their
files: verify._init unions each task's files. Derive actual changed paths for the
close-outs before composing VERIFY/probe inputs and before reviewer security inputs,
not only inside E11. Keep task ownership/repo and source gap in those inputs. Include
newly introduced sensitive paths, not only paths named by the original PLAN.

The ordinary controller execute rerun loop already skips IDs absent from PLAN;
retain that deliberate skip and enforce its exemption at the boundary as above.
No new verification command is required for C-n.

## Answers to the four questions

1. **Mixed targets:** do not erase accepted execute gaps and hope a future judge
   remembers them. Carry them durably through the earlier SPEC/PLAN route, then
   reconcile against current revisions before scheduling. A superseded gap can be
   explicitly dispositioned with reason; retain the accepted obligation and history.
   This does not route a pure execute gap to PLAN or change D1.
2. **Automatic Critical gaps:** yes, they originate in ITERATE and should receive
   the same close-out handling. Preserve finding ID/repo provenance. A passing task
   review alone must not silently close the ledger finding: VERIFY must establish
   its valid closure through the existing ledger rules. Also verify which routes can
   actually reach ITERATE with an open Critical, since V7 blocks passed VERIFY then.
3. **E11:** use actual changed files, do not skip it. Ensure probe and reviewer
   inputs know those files before demanding their security dispositions.
4. **Scheduling:** choose one close-out per trailing wave initially. These tasks
   have no declared file sets from which independence can be established. Serial
   scheduling is a concurrency choice, not a new size bound. Retain conflict handling
   for other changes and reuse the existing retirement safeguards.

## Required validation and scope

Extend deterministic module cases to cover mandatory close-out membership and
review, external implementation, replay/idempotence, mixed targets through PLAN,
T/R/C rejection targeting, producer repo schema, invalid single-repo name, actual
changed-file probes, security disposition and a close-out-only delivery repository.
Use recorded live evidence for the end-to-end accepted ITERATE gap -> reviewed C-n ->
new-head VERIFY -> converged route. The proposed six broad tests do not cover these
contract edges. Do not add a fake runner or offline cycle suite.

The explicit decisions do not authorize a boundary to skip close-outs or their
review. These amendments preserve the chosen design. No new live run or suite was
performed for this unimplemented plan. Only this local audit was written; no code,
commit, push, memory change, or running consumer modification.


## Second pass: revision 1, at 41e74e5

**Disposition: revise the remaining contract details before coding.** Controller-owned
registration, durable mixed-target obligations, explicit no-change review, serial
waves, both repo schemas, and T/R/C targeting address the first-pass design findings.
The following are concrete residuals, not a request to replace the registry design.

1. **Complete the schemas and product builder.** execute.json currently allows only
   done/already-satisfied/removed/adopted and disallows extra task properties. The
   proposed superseded disposition and reason need schema support, builder support,
   and explicit handling in coverage/result consumers. Automatic gaps add findingId,
   but section 2 only adds repo to schemas that forbid unknown properties. Add the
   provenance field to the phase schema (and producer schema if emitted there), or
   keep it in a separate controller-derived mapping. Include schema tests for both.
   The appendix's claim that execute.json and _final_product are already correct is
   now stale.

2. **Finish the no-change review transition and bind its SHA.** The unchanged
   _on_review_submit integration tail always sets status=done, even with zero commits.
   That contradicts revised E2's done-requires-commits rule. _final_product's current
   already-satisfied branch also emits review=None. Specify the complete path from
   a reviewed no-change claim to an already-satisfied product retaining its review.
   Existing E5 checks each owned commit; with no commits, range coverage is vacuous.
   Require the no-change review's from/to to equal the relevant current repo head,
   and bind its attested request to the registry gap/source. Test a genuine but stale
   attested no-change review at H when the candidate is H2: it must not close the gap.

3. **Keep completion obligations and integrated history across later entries.**
   Registry active -> closed is fine, but later external EXECUTE contexts also need
   closed close-outs that still own commits, not just active entries. Preserve their
   repository, commits and accepted review provenance. Specify which closed entries
   must remain in later products and how E4 prevents history from disappearing.
   A changed SPEC/PLAN must not turn previously accepted closure evidence into proof
   for a different obligation without an explicit policy. Add accept C-1, later
   rewind/re-enter EXECUTE, and external implementation cases.

4. **Make supersession justified, not merely revision-triggered.** Any revision
   moving is not evidence that this particular gap disappeared: changing unrelated
   wording could allow an unreviewed superseded result with any nonempty reason.
   Require explicit accepted SPEC/PLAN evidence that removes/replaces the obligation,
   or an attested review that confirms why it no longer applies. A PLAN task taking
   responsibility is a transfer with a durable link, not immediate closure before
   that task completes. For this patch, keeping EXECUTE acceptance as the sole
   registry status writer is simpler; PLAN may provide the referenced evidence.

5. **Registration must be part of the accepted transition transaction.** Allocate
   C ids and save the accepted source once, together with route/budget state, so a
   retry/crash cannot spend twice or lose the registered gaps. Clarify refused-rewind
   behavior: no executable close-out should be scheduled after a terminal budget
   refusal. Keep the source/history inspectable. This is idempotency, not a new
   generic no-op rewind guard.

Answers to the new questions: keep one controller acceptance path as status writer;
show active C ids, repo and source in status now so operators can diagnose the new
obligations. This small status addition is useful but not a correctness blocker.

Correction to the plan's reachability claim: current ITERATE has a judge, not an
independent full-range code review that writes ledger findings. _final_product reads
existing ledger findings. Keep automatic-gap support, but do not claim a live route
creates an open Critical there unless evidence establishes it. V7 still blocks open
Criticals on passed VERIFY.

No code or live run changed. This is static plan/source review; the above cases are
required deterministic module checks for implementation, followed by recorded live
validation of the complete rewind/close-out path.


## Third pass: revision 2, reviewed at b2c3379

Reviewed the revision in the d03d3aef-6266-4b86-8a86-6e9d13fe58a4 scratchpad.
The older 56068559 scratchpad still contains revision 1; it was not treated as the
current proposal. Dropping superseded, adding findingId only to the phase schema,
retaining closure history, and binding no-change proof to the head are sound choices.

**Disposition: go to implementation with the following precise corrections.**
No new architectural revision is needed, but the literal R2/R3/R5 rules cannot all
be implemented as written. Carry these corrections into the coding specification.

### 1. Permit validated refresh of a closed no-change review

R3 requires a closed entry's product review to match its old closure's reviewedRange.
R2/R3 simultaneously require a fresh H2..H2 review after the repo moves from H to H2.
That fresh proof would fail E2's old-range equality. Make an explicit exception for
a closed already-satisfied entry: preserve id/repo/text/source and zero commits,
accept a fresh passing attested review bound to that same obligation and current
head, and update the closure only on full product acceptance. Retain prior closure
proof in history. Restore default task state only when absent, rather than overwriting
an in-progress refreshed review from the older closure on every step.

Required case: accept no-change C-1 at H, move to H2, issue refreshed review, and
accept the new EXECUTE product through E2/E5/E6 together; a failure elsewhere must
leave the old closure/history intact. Test both default and external products.

### 2. Detect no-change from the reviewed candidate, not pre-integration ownership

R2 says a passing review of a task with zero commits becomes already-satisfied.
The stored task_state.commits contains integrated commits only; it is empty for a
brand-new C-1 even after its worker committed a real patch, until integration records
that patch. Checking it before integration would discard the first real close-out
implementation as no-change.

Use the LF-49-confirmed no-change state/current branch comparison (and the actual
reviewed range), or decide only after successful integration and attribution. A real
candidate delta must integrate, retain owned commits and emit done. A true no-change
candidate retains its passing review and emits already-satisfied. Test first committed
C-1 separately from a no-change C-1, plus review failure/retry and conflict recovery.

### 3. Make the transition atomic in the actual persistence code

R5 explicitly asks whether spend saves: it does. budget.spend ends with store.save().
Registering immediately after that call leaves an on-disk spent-budget/accepted-
product state without close-outs or a completed route. Replaying the final allowed
rewind may fail I3 before reaching spend's own idempotency check.

Refactor the spend operation so this controller path can stage budget, registration,
accepted product and routing and commit them once, while preserving other callers'
existing persistence semantics. Alternatively implement an explicit recoverable
transition record, but do not assume the current helper already supplies atomicity.
Guard replay before exhaustion-dependent checks for an already accepted transition;
no double spend, duplicate C ids, or lost routing on restart. Test interruption at
the former spend/save boundary and replay of the last allowed rewind using state
module inputs/outputs, not a fake full-cycle runner.

With these corrections, the five second-pass concerns have a concrete implementation
path. Keep the planned boundary/schema/module cases and recorded live close-out
validation. Approval here is to code; actual implementation and live evidence still
need review. No implementation or running consumer worktree was modified.
