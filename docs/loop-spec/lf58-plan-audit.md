# LF-58 plan audit

Reviewed against 36ae40e. **Go with option A: record rejected pushes per repo and
continue attempting the remaining repos.** Keep credential preflight distinct.
Incorporate the following into implementation; no new delivery protocol is needed.

1. Specify the exit selector explicitly. Removing blocked=True/break alone leaves
   today's final expression returning partially delivered whenever ANY row failed,
   including when ALL failed. For the plan's stated semantics: mixed delivered/failed
   is partially delivered; no successful delivery is delivery blocked (with a useful
   cause); all successfully delivered is delivered. Untouched/skipped repos do not
   turn successful delivery into partial delivery.
2. Derive partial-delivery facts consistently in terminal-result assembly, not only
   one stop branch. A pause/stop/error after publication must retain the latest
   authoritative per-repo outcomes, including touched-but-not-attempted repos when
   a credential gate interrupts the loop. Do not use unrelated untouched repos as
   missing deliveries. Preserve successful publication and its SHA/PR on re-entry.
3. Keep raw push stderr; make suggested repairs conservative when the cause is
   ambiguous. Never force-push to resolve this. A nonzero push is not always a
   non-fast-forward conflict, as this run demonstrated.
4. Specify push-success/PR-creation-failure separately: a remote branch was published
   even though no delivered PR row exists. Do not describe that state as no remote
   write. Record its published SHA and failure stage, or explicitly track it as a
   separate delivery-fact issue if existing schema compatibility prevents doing it
   here. The proposed delivered-row predicate alone does not capture that case.

Tests: failed FIRST repo followed by successful second (proves continuation), failed
last repo, all pushes failed, credential refusal, untouched skipped repo, stop after
one published repo, and push success followed by PR failure. Use real local bare
remotes for Git behavior and focused deterministic result/classification tests; no
fake full-cycle PR service. Recorded live partial-delivery evidence remains required.

The observed e2e-t2b result supports the defect report, not a passing handoff test.
No source, running consumer, push URL, commit or remote was modified by this audit.


## Implementation review: 90280b5

Twenty focused deliver/result tests pass. Credential preflight, continuation after
push/PR failure, all-failed vs mixed selection, and publishedSha recording implement
the main fix. Two residuals remain; no source was edited by this review.

**Publication history must survive DELIVER re-entry.** deliver.run builds every row
from scratch, and the credential-refused branch emits failed rows with no publishedSha
and says DELIVER wrote to no remote. That only establishes no NEW write this attempt.
If a prior attempt pushed a branch but PR creation failed, fix-and-re-enter followed
by a credential failure overwrites the accepted delivery product and loses the prior
publishedSha. The same applies to an earlier delivered PR if delivery is re-entered.
result.write reads only the latest accepted product, so its new derivation cannot
recover discarded facts. Persist/reconcile known publication facts across attempts;
record current attempt failure separately from cumulative publication. Test publish ->
PR failure -> re-enter -> credential refusal -> stop, preserving the remote SHA.

**Repair diagnosis is still overbroad.** _push_repair treats any '[rejected]' as proof
of diverged commits. Git also uses that label for other conditions, such as a tag
already existing. Match explicit non-fast-forward/fetch-first causes; otherwise keep
the raw error with the general remote/access repair. This is diagnostic severity,
not permission to force anything.

The initial two-repo mixed delivery behavior is supported by the tests. The claim
that partial-publication facts are truthful on every route needs the re-entry fix.
The existing workDelivered meaning (a delivered target) and branch-only publishedSha
should remain distinguishable; do not silently change schema-1 meaning to paper over
history loss. Live handoff acceptance remains separate. No full suite or new live
session was run.


## Follow-up implementation review: 7747bf3

The earlier-fact overlay and explicit divergence matching address the reviewed paths,
but one publication-history overwrite remains. `_record_published` replaces the
entire per-repo record. On re-entry, a successful push calls it with pr=None BEFORE
PR reconciliation. If that PR operation fails, a previously known PR has been erased
again. A direct deterministic probe recorded PR #13, then recorded a successful retry
push with pr=None; the stored PR became None.

Preserve known PR identity/history across the intermediate push record. Distinguish
its last observed head from the newly pushed SHA rather than falsely asserting a
previous PR snapshot was freshly verified. Include that preserved identity in the
failed PR row, which currently bypasses `_published`. Add prior PR -> successful push
retry -> PR lookup failure -> stop. Cumulative publication facts and latest-attempt
success are different fields; do not reset either by accident.

Validation this turn: 69 tests across attest, steps, deliver and result passed. The
publication overwrite probe is additional evidence not covered by that suite. No live
session or remote write was started by this audit.
