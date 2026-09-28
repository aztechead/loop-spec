# Audit of the LF-49–LF-51 fix proposal

For the implementing agent. Reviewed the scratchpad proposal
`/private/tmp/claude-501/-Users-aztechead-Projects-loop-spec/d88e29ac-3fe5-4d45-85ae-630e43c61935/scratchpad/plan-lf49-51.md`
against v7 at `7d4f1a5` and the supplied failed-run state. No implementation was changed.

**Verdict: the diagnoses are sound; revise the proposed fixes before proceeding.**
LF-49's fall-through direction is right. LF-50 needs a narrower identity rule.
LF-51 must include fresh verification state and safe remediation worktree/history
handling; merely setting tasks pending is insufficient.

## LF-49: fall through on real commits, but do not certify an unknown fork

Accept the fall-through approach. When Git proves that the task branch contains work
past its recorded fork, probe/review/integrate that work instead of spending another
worker session just to restate a malformed commit list. Record the discrepancy in an
event and retain the normal clean-tree, ancestry and review checks.

Change the proposed `forkedFrom in (None, task_head)` condition. `None` means unknown,
not no work. It preserves the original defect for legacy state. Also require an
existing branch SHA and a clean worktree before accepting already-satisfied. The
current prefix branch returns before `is_clean`, so the SHA check alone would still
accept an uncommitted implementation as already present.

For legacy state, recover the fork from trustworthy recorded dispatch/history
metadata. If it cannot be established, take a diagnostic review/reconciliation path;
do not certify no work. Do not use the current feature head as an assumed historical
fork after siblings have merged.

Required cases: known clean fork accepts; commits past fork fall through; dirty tree
at the fork refuses; missing branch/fork does not auto-accept; merged siblings do not
cause the task's existing commits to disappear. These are deterministic Git/state
unit cases, not a cycle simulator.

## LF-50: carry forward the same open finding, not any known identifier

Preserving stable finding IDs is correct, but the proposed exemption is too broad:
`_check_supersedes` currently puts both finding IDs and reviewed-range IDs in
`known_ids`. A plain membership check would also exempt a closed finding or a range
ID from the new-finding rule.

Use a finding-only lookup. An implicit carry-forward is allowed only for an existing
open finding with matching repository and stable issue identity. Define the identity
fields explicitly, at least the affected code/root cause; legitimate location moves
need a recorded update rather than arbitrary reuse of an ID. A different issue using
a familiar ID is not a carry-forward. Range IDs remain typed supersedes targets only.

Keep one current ledger entry per finding. Update its latest observation and permitted
disposition without duplicating it. Preserve first-raised SHA/range and a history/event
of later observations and disposition changes; replacing all provenance with the
latest SHA would erase the adjudication trail the ledger exists to carry.

For an already closed or deferred entry:

- An exact duplicate observation is an idempotent no-op.
- An attempted reopen or changed issue under that ID should be rejected with an
  actionable reason or represented as a new finding with explicit supersedes.
- Do not silently drop a genuinely new report merely because its author reused an
  existing ID. Do not blindly reopen a previously adjudicated finding either.

Apply the same rule in product assembly, V8, and ledger update. Tests must cover
open carry-forward, close-with-reason, duplicate submission, cross-repo/different-
issue ID reuse, range-ID reuse, closed echo, and explicit reopening. A test checking
only that any known ID passes V8 would encode the new bug.

## LF-51: reopen work by its owner, with a complete handoff

Reopening existing plan tasks is a reasonable default for corrections within their
approved scope. It avoids silently mutating the approved plan and adding R-n tasks
that E2/E4 do not know. However, constrain and complete the proposed handling:

1. **Bind the trigger to the actual incoming transition.** Checking any persisted
   VERIFY product with `exit: implementation gap` is not enough; old products remain
   in state. Pass the source phase/attempt, revisions and gap payload through the
   controller's transition. Key consumption by that accepted source attempt and
   validate its current target context. Persist the task changes and consumed marker
   together. Repeated calls/resume must not reopen the tasks again.
2. **Match repository as well as criteria.** A criterion can be covered by multiple
   tasks or repositories. Validate every remediation maps to an eligible owner; an
   unmapped gap must route to PLAN, not be marked handled with no work. If the repair
   requires new scope/dependencies, amend PLAN explicitly rather than force it into
   an unrelated original task. Reopening every matching task should not be assumed
   to be the minimal required change.
3. **Give the worker the actual remediation contract.** Carry the failed criterion,
   cause, requested files and evidence command, not just a status change. Do not
   silently discard a remediation check that is more specific than the old whole-
   suite command. Decide whether it is supplemental evidence or a plan amendment.
4. **Invalidate stale accepted evidence for affected work.** Clear/recompute its
   current review, probes, already-satisfied evidence and executeRuns entries as
   needed, while preserving historical commit ownership and review records. Define
   the per-task retry counter's scope: not charging the transition as a retry is
   correct, but retaining an exhausted previous attempt counter is not a fresh
   remediation attempt. Preserve total history even if the new attempt has a fresh
   bounded worker-retry allowance.
5. **Do not assume the old task branch contains the current integrated feature.**
   Parallel siblings and later waves make that false. Run remediation against the
   current accepted feature head. Use a new remediation branch/worktree when needed,
   preserving the original task's historical commits and recording the new attempt's
   fork separately. Reuse is acceptable only when Git proves it has the required
   ancestry and it does not have an active writer.
6. **Handle adopted tasks explicitly.** Adopted tasks can have `branch=None` and
   `worktree=None`. New repair work must not replace their adopted-range ownership or
   inherit its review as proof of the new commits. Test a revise remediation rather
   than assuming the ordinary done-task branch path covers it.
7. **Refresh VERIFY after repair.** The current `verify.step()` reuses its module
   state whenever it exists; it does not compare accepted EXECUTE heads or revisions.
   Reinitialize stale checkouts, ranges, verifier/reviewer results and probe inputs
   on a changed candidate. Preserve the finding ledger separately. Rejection within
   the same candidate may retain the current retry machinery. ITERATE likewise must
   not reuse a verdict after relevant input/revision changes.

The seventh point is necessary to show the proposed LF-51 repair worked. Otherwise
the next VERIFY can simply return the pre-repair failure again.

### Two assumptions checked directly

Using the existing `VerifyTests` Git fixture without changing production code:

```text
complete a failing VERIFY at H
commit a repair at H2; replace accepted EXECUTE heads with H2
enter VERIFY with a new attempt
observed: Product, exit implementation gap
observed: evidence SHA and reviewed-range end still H
```

A separate disposable Git fixture created sibling branches A and B, merged both into
feature, then added a repair to the old A branch:

```text
is_ancestor(current feature head, reopened A task head): false
```

Therefore the proposal's statement that re-integration is necessarily fast-forward
is false even in the already-supported parallel-wave arrangement. The existing merge
fallback may combine the branches, but it does not make the worker's old checkout
contain the integrated behavior it was supposed to repair.

## Answers to the proposal's numbered questions

1. **Fall through**, when Git proves there are task commits. Do not charge a retry
   solely to correct the prose/commit-list claim. Unknown fork or dirty state is a
   separate diagnostic condition, not already-satisfied.
2. **Update the same open finding idempotently.** Closed duplicates may be no-ops;
   actual reopening needs explicit supersedes. Never skip V8 for arbitrary known IDs.
3. **Reopen the owning task for in-scope repair.** New scope/dependencies need an
   approved plan amendment. Preserve old commit ownership and use current-head
   remediation attempts; adopted tasks need their own regression case.
4. **Source VERIFY attempt ID is a good deduplication key**, provided the actual
   transition and revisions are checked and the consumed marker is persisted with
   the reopening. Do not trigger from an unrelated stale VERIFY product.
5. **The proposed tests are insufficient for the stated fixes.** Add the cases above,
   especially repaired-head VERIFY re-entry and parallel/adopted history. The file
   says six questions but enumerates five; this audit answers those five.

## Scope and re-run advice

Adding `.gitignore` to the fixture is reasonable. Commit it before recording the new
baseline and use a fresh slug, as proposed. Keep the pre-existing failing test intact:
fixing that test merely to make the fixture green would remove the scenario the run
is intended to exercise. The earlier out-of-scope edit should remain visible in the
failed-run evidence.

A whole-suite command declared featureAdded despite a known existing failure is an
invalid plan choice. Deferring a broader critic-quality change is reasonable, but the
re-run must correct the plan's command semantics; LF-49–51 do not make that command
succeed. Keep the existing suite baselined and use a focused new check where a
featureAdded first-success rule is intended. Do not loosen clean-tree checks for
Python cache files.

Task file scope deserves an explicit policy later; a `files` list is not necessarily
a strict edit allowlist without that decision. The attestation refusals described in
the report are expected enforcement, not a prompt-tolerance defect to weaken now.

One commit per defect remains a good implementation split. Version 7.0.1 is fine once
the changes are ready. The contributor rule names four categories, not literally
four files: update plugin.json, marketplace.json, README, and every skill manifest.
The program reads its VERSION from the hub manifest. Keep the detached plugin pinned
during a live run; refresh it between runs only. Passing these code-level checks is
not a substitute for the fresh-slug workspace run and remaining handoff cases.

## Evidence and edits

Read the proposal, the current implementation and the supplied run's state. The
stored state confirms T-1 is already-satisfied with retries=3, calc's EXECUTE head
still at base, one open textutil finding, and a prior accepted VERIFY implementation
gap. The two targeted checks above used disposable local Git/state only. No full
suite or live model run was performed for this proposal audit. No source, fixture
repository, failed-run state, proposed plan, or version file was modified. Only this
audit file is added locally; nothing is committed or pushed.


## Second audit: revision 2 (2026-09-22)

**Disposition: revise before implementing the exact specs.** The direction is sound,
but four remaining gaps need explicit treatment. This reviews the revised scratchpad
plan against source at `7d4f1a5`; it does not claim to validate an implementation.

### Accepted choices

- LF-49's branch/fork/clean checks and ordinary-path fallback are reasonable. A
  contradicted prose claim need not itself consume a retry; ordinary checks still do.
- LF-50 can use id + repository + file identity without exact cause equality. Keeping
  cause observations is better than treating routine rephrasing as a new finding.
  This identifies a carry-forward; it does not mechanically prove semantic sameness.
- LF-51 can fail closed on an unmapped default-generated remediation. For externally
  supplied products, report invalid remediation with an actionable error rather than
  assuming every such input establishes internal corruption. P2's criterion coverage
  alone does not validate arbitrary external repository references.
- A cumulative `reviewFrom` is a reasonable way to retain one review per task and
  avoid a review-history schema change. Including sibling changes is acceptable.

### S1 — V7 must evaluate validated closures, not the old and new entries together

`postconditions.py::_v7` concatenates product findings and ledger findings. A product
that closes Critical F as fixed still fails because ledger F remains open. The
proposed ledger update happens only after acceptance, so it cannot unblock that gate.
This leaves precisely the repair loop LF-50 is intended to close.

Specify an effective finding set for boundary evaluation: overlay validated same-
identity updates on the existing ledger, then check for open Critical findings.
Validate identity and the allowed disposition/reason transition before applying the
virtual overlay. A different repo/file or invalid closure must not hide the old
finding. Persist changes only after the whole product is accepted; rejection must
leave the ledger untouched.

Required cases: valid Critical closure passes the open-finding check; unrelated or
invalid closure still blocks; another boundary failure does not persist the closure.
A targeted call to the existing V7 confirmed that an otherwise passing verdict plus
same-ID fixed product entry returns `a Critical finding is open` against the open
ledger entry. This was a function-level check, not a full cycle.

### S2 — Re-forking must preserve dirty or potentially active old worktrees

Section 4.5 refuses reuse when the old worktree is dirty, then says the old worktree
is removed. A retained branch preserves committed history, not uncommitted edits or
untracked files. Removing that worktree can destroy the very work that made reuse
unsafe. Also, a completed result is not necessarily confirmation that its writer has
terminated.

Create the new branch/worktree independently. Preserve/quarantine the old worktree
when dirty or when writer termination is unconfirmed, and record its path and reason
for cleanup. Remove it only when clean and termination is confirmed. Apply the same
rule to cleanup paths reached during remediation, including conflict recovery.

Required cases: dirty tracked and untracked contents survive re-fork; unconfirmed
writer worktree survives; clean terminated worktree may be removed.

### S3 — Conflict recovery must not erase already-integrated task ownership

Section 4.6 says the conflict re-fork path discards commits and moves both fork fields.
That is not safe after remediation of a previously integrated task. Its earlier owned
commits remain on the feature branch: clearing attribution loses E4 coverage, and
moving `reviewFrom` past those commits invalidates their cumulative E5 coverage.

Preserve already-integrated task commits and the historical review anchor through
all subsequent re-forks. Discard only the unintegrated failed attempt's attribution;
reset the mutable implementation fork to the new feature head. An ordinary task with
no accepted history can still reset both anchors as appropriate. Distinguish these
cases explicitly rather than making all conflict retries discard all task history.

Add a deterministic case with an integrated task, remediation, a concurrent sibling
integration, and conflict recovery; verify historical ownership and the eventual
review range still cover old and repair commits. Re-forking from the current head
makes fast-forward possible at that moment, not guaranteed after another worker
integrates. Keep the merge/conflict path and amend the plan's fast-forward guarantee.

### S4 — Invalidate reused state by its relevant inputs, not just commit heads

LF-52's heads + plan revision check omits requirement changes. `plan_revision()`
excludes `boundTo` and `inputsDigest`, so new requirements can bind the same plan
structure without changing its revision. VERIFY must not reuse its previous evidence
under those requirements. ITERATE's current head-only reset has the same defect,
and can also reuse a judgment after the accepted VERIFY evidence changes at the same
heads.

Use a stored input identity covering requirements revision, plan revision, and heads
for VERIFY. For ITERATE, include the accepted VERIFY product identity as well as the
relevant revisions and heads (or a stable digest of the actual judgment inputs).
Reinitialize missing legacy identities. Preserve historical gaps/ledger history, but
never stamp a cached judgment with revisions it was not made against.

The related LF-51 assertion that a PLAN change produces fresh EXECUTE state is not
implemented: `execute.step` initializes only when `state.execute` is absent, and the
controller transition does not clear it. Therefore `rewind_ignored` on a revision
mismatch is not sufficient protection. Specify how EXECUTE reconciles a changed plan
while preserving integrated history, or fail closed until it can; do not silently run
old tasks as the current plan. Replace/clear entry payloads deliberately on transitions
so a forward entry cannot inherit an unrelated rewind. The actual transition block
is in `controller._finalize`, not `_accept_product` as named in section 4.1.

Required cases: same heads with changed requirements; same heads with changed plan;
same heads with changed accepted VERIFY evidence; PLAN re-entry with old EXECUTE
state; stale rewind payload cannot yield a product represented as current.

A targeted check using the existing IterateTests fixture recorded a `met` judgment,
changed requirements and plan revisions without changing heads, and called
`iterate.step` again. It returned `Product(converged)` bound to the new revisions
while retaining `judgeStep=step-1`: no fresh judgment was requested. This confirms
that "ITERATE needs nothing" is not sound.

### Implementation handoff

Incorporate S1 into LF-50, S2/S3 and EXECUTE handoff handling into LF-51, and complete
input invalidation in LF-52. No objection to the four-fix commit split or to the three
deliberate deviations with these qualifications. These are targeted corrections, not
a request for a new phase model or review-history schema.

The requested cases belong in deterministic module tests on concrete inputs and
outputs. Cycle-level acceptance still requires the recorded fresh-slug live run and
the remaining handoff cases; no fake runner or offline cycle suite is requested.
No full suite or live run was performed for this second plan audit. Only this local
audit file was changed; no implementation, proposed plan, failed-run state, version,
commit, or remote was changed.


## Third audit: revision 3 (2026-09-22)

**Disposition: go to implementation with the conditions below incorporated.** No
further wholesale plan rewrite is needed. This is approval of the approach, not an
unconditional sign-off on revision 3's literal specs or on unimplemented code.
Reviewed the revised scratchpad and source at `7d4f1a5`; no implementation was changed.

### Closed from the second pass

S1's shared virtual overlay addresses the acceptance-order problem. Keep validation
and persistence on the same semantics and persist only after full acceptance. S3's
preserved integrated commit ownership and historical anchor address conflict recovery.
S4's expanded VERIFY/ITERATE input identities address stale judgments. Copy stored
identity dictionaries so mutations cannot change both sides of a later comparison.

Answers to the two explicit questions:

1. Failing closed on a dropped integrated task is acceptable for this scope. It is a
   deliberately conservative policy: absence of an amendments writer does not itself
   prove all removal is illegitimate (E4 separately exempts adopted commits). No need
   to build an amendments mechanism in this fix.
2. The accepted VERIFY attempt id is a suitable conservative invalidation key:
   `_record_accepted_product` stores it with the accepted product. It may cause extra
   judgments for equivalent products, which is safe. If accepted products ever become
   mutable within one attempt, use a product digest too. Missing legacy identity must
   cause a fresh judgment, as specified.

### Condition A — Absence from open/quarantined does not prove termination

S2 is only partly closed. `steps.submit` removes a step from `steps.open` and appends
its id to `retired` after accepting the result. In particular, implementer results can
be accepted without host attestation; this path does not prove the dispatch ended.
Consequently a clean worktree can satisfy revision 3's retirement AND reuse predicates
while its worker is still capable of writing. Matching the existing terminal R5 rule
is not proof that the predicate supplies the stronger guarantee requested here.

For this fix, preserve the old worktree and use an independent new branch/worktree
unless termination is positively known. Delete or reuse only with actual host/process
termination evidence for its writers, not merely absent open records. A conservative
"preserve when unknown" fallback is sufficient; no broad host redesign is required.
Keep dirty worktrees regardless of termination. If cleanup is deferred, ensure the
terminal cleanup path cannot subsequently delete the retained unknown-writer worktree
merely because it is clean. Carry an effective protection/quarantine record through
that path, not just a descriptive cleanupBacklog entry.

Add a case where a clean worktree's implementer result has been submitted, the open
record is gone, but termination is unknown: it is neither reused nor deleted.
`steps.confirm_terminated` currently force-removes its quarantined worktree; do not
route a retained dirty worktree through that path without preserving the dirty files.

### Condition B — Finish the reconciliation rules for repository and cache ownership

Section 4.8 treats a `repo` change like any changed integrated task. That cannot retain
its old commit list and anchor under the new repo: E4 groups ownership using the new
PLAN repo, and those SHAs belong to the old repository. Fail closed on repo changes
for tasks with integrated commits, with a repair explaining that the old owner must
remain and new-repo work needs its own task. For unintegrated changes, retire using
the OLD repo/path, then create clean task state naming the NEW repo.

Invalidate `executeRuns[task_id]` for reset and dropped tasks as well as reopened
integrated tasks. The cache is outside task state, and `_run_execute_verifications`
reuses entries by id; replacing task state alone cannot invalidate it. Remove stale
active `issues` for reconciled task failures (retain them in history if desired).
A reset must not recreate the same retained branch/worktree names: allocate a new
fork generation when any old path or branch survives.

Legacy snapshots also need a conservative rule. The claim that today's current PLAN
is "the only plan it can have run" is false for a state paused after PLAN was revised
but before this new reconciler ran. If the original task identity cannot be recovered
from recorded history, fail closed or safely revalidate/reopen while preserving owned
commits; do not silently assign today's snapshot to yesterday's completed work.

Add deterministic cases for an integrated task changing repo, an unintegrated task
changing repo, a reset task with an existing executeRuns entry, retained branch/path
name collision, and legacy EXECUTE state after a plan change. These are extensions of
the proposed reconciliation unit cases, not a new offline cycle suite.

### Handoff and validation

Implement the four fixes with A and B above, then review the actual diff. Retain the
planned recorded live acceptance runs. This third pass was static source/plan review;
no new suite or live cycle was run. The prior pass's targeted reproductions remain
recorded above. Only this local audit file was appended; nothing committed or pushed.
