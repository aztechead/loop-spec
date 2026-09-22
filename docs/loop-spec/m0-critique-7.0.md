# M0 critique: decision readiness at c8b6d72

Verdict: **hold M0 sign-off; continue the bounded feasibility work.** The migration
choices are recorded and both runners are decided. The phase-interface model is a
reasonable direction. The route matrix still has four substantive acceptance/routing
holes, and the host-version requirement remains outstanding. Those are decisions
needed before implementation, not reasons to reopen the accepted migration scope.

Reviewed: [roadmap](ROADMAP-7.0.md), [route matrix](phase-interface-7.0.md),
[migration inventory](migration-inventory-7.0.md),
[migration how-to](migrating-6-to-7.md), and the prior audit dispositions. The
[M1 fixtures specification](m1-fixtures-7.0.md) is a new, uncommitted companion
contribution; its cases are specifications, not executed acceptance tests.

## M0 acceptance checklist

| Requirement | Current evidence | Assessment |
|---|---|---|
| Roadmap, inventory, route matrix present on v7 | All three present at c8b6d72 | Met as artifacts, not proof their contracts are consistent |
| Migration scope and removal decisions | Thirteen recorded decisions; accepted removal list | Decision coverage is materially improved; do not reopen accepted removals |
| Every new finding closed or explicitly accepted | Four route holes below have neither resolution nor explicit acceptance | Not met |
| Supported host versions | Roadmap section 20 explicitly says pending for M0 | Not met |
| Native attestation feasibility | Probe described; no result recorded in the planning set | Unproven; perform early before depending on native attestation |
| Schema-1 consumer parity | Explicitly deferred to M1 fixtures | Legitimate future evidence obligation, not a reason to claim parity now |
| M6 live gates | Independent native and SDK gates specified | Correct future release obligation; not required to be executed during document review |

The M0 row, the section 19 pre-M1 list, and the handoff should agree on whether the
native probe is a strict M0 prerequisite or the first limited implementation spike.
The user handoff puts it before M0 completion; retain that ordering explicitly.
A version pin alone does not prove attestation, worktree behavior, or question parity.

## Findings to resolve before M0 sign-off

### M0-01 — P1: the main failure loop is still outside the budget

[Route matrix](phase-interface-7.0.md), lines 163–171 and its unspecified-route list.

VERIFY can route straight to EXECUTE in remediation mode. The matrix explicitly
says these entries do not spend the rewind budget, and leaves their bound for M1.
A fresh reviewer can therefore keep causing another EXECUTE/VERIFY round while the
ITERATE counter stays zero. Per-step retries do not help when every individual step
succeeds. This is the original report's headline failure, retained in the new control
flow despite the roadmap's bounded-convergence objective.

Decision needed: one persistent budget for all backward remediation transitions, or
an explicit finite secondary budget with a terminal rule. Count VERIFY→PLAN/SPEC,
evidence-incomplete self-reentry, and resumed attempts consistently; otherwise the
same loop merely moves to another route. Define budget exhaustion before implementation.

Suggested default: share one feature-level remediation budget and preserve it across
sessions, with idempotent accounting per accepted transition. Accept a separate
budget only if its combined bound is explicit. Fixtures: VE-08 and IT-03.

### M0-02 — P1: blocked verification can become converged-with-caveats

[Route matrix](phase-interface-7.0.md), lines 179–196.

ITERATE may receive VERIFY `blocked`. The caveats exit requires only I1 and I6:
current identity, no Critical finding, and non-Critical findings with dispositions.
It does not require I5's VERIFY-passed condition or a satisfied original goal.
A blocked acceptance criterion plus one deferred Important finding can therefore
produce a converged-with-caveats draft. An open goal gap can take the same route.
The roadmap instead requires acceptance and ITERATE to pass for this classification.

Decision needed: a shared convergence predicate for both converged outcomes requiring
VERIFY passed and no open original-goal gap. Caveats add only accepted non-Critical
review findings. Incomplete acceptance may reach a draft solely through the explicit
escalated-partial-delivery policy and must retain that classification.

This is a missing observable route check, not an attempt to mechanically prove model
judgment. Fixtures: VE-07 and IT-02.

### M0-03 — P1: a Critical critic finding can be deferred into a ready PLAN

[Route matrix](phase-interface-7.0.md), P7 at line 98.

P7 accepts either no Critical findings or a disposition for every finding. A ledger
value such as `deferred` is a disposition, so a plan with a known Critical defect can
become ready. Nothing specifies accepted dispositions for this new critic. This
conflicts with the stated policy that Critical findings block.

Decision needed: name the dispositions that close a Critical critic finding and the
evidence each needs. A correction must be checked; an explicit reasoned rejection
may close a false positive. An unresolved/deferred Critical cannot advance. Define
how a corrected PLAN is admitted under the chosen single-pass critic design without
silently adding an unbounded critique loop.

The Critical-only critic decision remains intact. This defines its acceptance rule.
Fixtures: PL-04 and PL-05.

### M0-04 — P1: debug and revise do not establish their destination preconditions

[Route matrix](phase-interface-7.0.md), VERIFY preconditions at line 145, debug at
lines 232–254, and EXECUTE preconditions at line 111.

A fresh debug invocation needs only an error report, then sends `repaired` directly
to VERIFY. VERIFY requires an accepted EXECUTE product at current requirements and
plan revisions. The debug path never establishes those inputs.

Similarly, revise adopts an open PR and enters EXECUTE, whose preconditions require
a current approved SPEC, PLAN, and baseline. An externally created PR has none.
Even a prior loop-spec PR can have stale state after human edits. Implementers must
either reject supported entries or invent an unreviewed bypass to make them work.

Decision needed: define how each entry establishes the shared context and approvals.
For debug, an explicit compact diagnostic intent/plan and accepted repair record may
satisfy equivalent gates. For revise, validate/reconstruct the adopted PR's current
requirements, plan and baseline before executing remediation, or explicitly limit
the entry to runs with resumable current state. Choose the behavior; do not fabricate
approval to satisfy a schema. Fixtures: DB-01 and RV-01.

## Tighten the reference while resolving those findings

These are smaller corrections with concrete effects; they do not require a new
architecture discussion.

| Location | Problem | Required correction |
|---|---|---|
| VERIFY V4/V5 and passed exit | V4 requires every command re-run, while V5 allows approved skips; passed lists both unconditionally | Express the predicate per criterion: controller-observed re-run or a valid approved exception. |
| DELIVER D7 versus partially-delivered exit | D7 claims to gate partial delivery, but the exit requires only D4/D5 | Include pre-write credential admission for every target written, regardless of final aggregate outcome. |
| EXECUTE/VERIFY blocked and debug blocked reproduction | Terminal versus pending/resumable behavior is left unspecified | Choose the route at M0; exact serialized codes and fixture implementation can remain M1 work. |
| Matrix source revision | Header says derived from 98e3288 despite later accepted decisions being present | Record the actual reviewed contract revision or a document version. |
| Inventory counts | Text says 149 shell/18 Python files; current top-level counts are 153/19 | Refresh counts or describe exclusions. Names were present, so this is not evidence of unmapped removals. |

## Migration how-to corrections

This is a how-to for a future release, with M1 placeholders openly marked. That is a
reasonable first draft. The following statements need correction before it becomes
consumer guidance; they do not undo the accepted migration decisions.

- Lines 133–134 say 7.x wrote nothing to the repository unless `commitArtifacts` was
  set. That setting controls workflow artifacts. Successful implementation still
  changes source, commits, branches and remote PRs. Reinstalling 6.9 does not undo
  those changes. State that rollback changes the installed tool, preserve any active
  run/worktrees, and have the consumer inspect Git and delivery state separately.
- Lines 79–80 exclude retained `LOOP_SPEC_HOME`, `LOOP_SPEC_PHASE_<NAME>`, and
  `LOOP_SPEC_ROLE_<ROLE>` from the allowed-variable check. A correctly migrated
  harness can fail that check. Use the inventory's actual retained/new surface.
- The config example's `evidence.review.accept: attested` value is not specified by
  the current contract, which only names the explicit `unattested` override. Either
  define the enum at M1 or omit the default-setting example until it is real.
- The refs/state push/pull row reads as an available migration command, while the
  roadmap calls it a seam deferred until needed. Mark that availability explicitly.

## What can safely wait for M1

Field/schema spelling, the exact config keys already marked M1, public error-code
names, test implementation, consumer round-trip fixtures, and the command-runner
implementation can wait. The semantic decisions about accepting incomplete work,
ending a remediation loop, or opening a phase without its inputs cannot.

The no-hook decision and the state-home pointer migration are accepted. Their tests
must demonstrate the replacement behavior; lack of those tests today does not by
itself reopen the decisions. Likewise, both runners are decided. Native transcript
feasibility is an evidence question that may force a maintainer choice, not license
to substitute SDK authentication automatically.

## Teammate handoff

1. Resolve M0-01 through M0-04 in the route matrix and mirror only the resulting
   semantic changes in the roadmap. The fixtures spec already names the regression
   cases; keep the default role implementations downstream of the same rules.
2. Pin the host versions and perform the native attestation probe with the maintainer.
   Record pass/fail, actual capability evidence and any accepted limitation. A fake
   transcript is not native support evidence.
3. Record dispositions for these findings and the smaller reference corrections.
   Keep F7 explicitly pending M1 validation, with that deferral accepted for M0.
4. Then sign off M0 and implement M1. M6 still requires independent live runs.

## Validation performed

Read the decision documents and compared the numbered predicates with their exit
requirements. Checked the inventory for all current top-level `lib/*.sh`,
`lib/*.py`, and `skills/shared/*.md` names: 153, 19, and 36 respectively; none of
those names was absent. This is a limited name-coverage check, not proof of every
inventory row's behavioral equivalence. No paid model calls, host probes, network
writes, or runtime acceptance tests were performed. The favored-plan documents were
left unchanged; this critique and the fixture specification are teammate deliverables.


## Sign-off check at revision 727b2b8

Recommendation: do not sign off either milestone as completed yet. M0 is close at
the design level; M1 has a fixture specification, not an implementation or passing
acceptance evidence. The worktree was clean when this check began.

### Prior finding disposition

| Finding | Evidence in this revision | Disposition |
|---|---|---|
| M0-01 | V10 now bounds VERIFY gap exits and evidence-incomplete re-entry, sharing I3's persistent budget. | Original VERIFY/EXECUTE counterexample addressed; other backward routes still lack budget admission. |
| M0-02 | Both ITERATE convergence outcomes now require I5, including VERIFY passed and no original-goal gap. | Closed in the written contract. |
| M0-03 | P7 rejects deferred Critical findings and allows a bounded corrected-plan recheck or reasoned rejection. | Closed in the written contract. |
| M0-04 | Debug/revise now establish compact SPEC and PLAN. | Partial: revisions are established, but accepted EXECUTE evidence and adopted-commit coverage remain undefined. |

The V4/V5 exception predicate and D7 partial-delivery requirement are corrected.
The migration guide corrects rollback, retained variables, the invented default
evidence setting, and deferred state transport. Those corrections are accepted.

### Remaining M0 contract issues

1. **Backward-budget coverage is incomplete.** PLAN's `spec gap` exit at route-matrix
   line 104 requires only P1; EXECUTE's `plan gap` at line 134 requires only E1.
   A PLAN→EXECUTE→PLAN loop can repeat without V10 or I3 executing. Apply budget
   admission centrally to every backward transition, including these two, and give
   exhaustion an explicit route. Test this cycle alongside the report-shaped one.
2. **Debug still cannot satisfy VERIFY entry.** Its `repaired` exit at line 253
   checks B1/B2 and goes directly to VERIFY. VERIFY at line 146 requires an accepted
   EXECUTE product. Compact SPEC/PLAN alone supplies neither task review nor accepted
   execution. Route repair through normal EXECUTE or explicitly require equivalent
   execution admission before `repaired` can advance.
3. **Revise lacks adopted-history coverage.** It starts at the PR's base and creates
   tasks from comments, while E4 requires every commit in `base..head` to belong to a
   done task and E5/E6 require corresponding accepted reviews. On an external PR,
   pre-existing commits are not those comment-remediation tasks. Define adoption
   evidence/tasks for the existing range, or a distinct reviewed starting snapshot
   and verification scope; do not silently exempt those commits from E4/E5/E6.

There are also two consistency fixes for the teammate:

- The terminal table still classifies bare EXECUTE `blocked` as escalated, while its
  updated phase route and another terminal row classify it as paused until a stop
  answer. Remove the unconditional escalated mapping.
- Fixture descriptions still call resolved decisions open and say the old matrix
  admits the caveats counterexample. The appended decision record is useful, but
  update each case's expected outcome to the accepted rule so implementers do not
  have to reconcile contradictory instructions.

### M0 evidence still missing

The roadmap's final pending list still names supported host versions. No named
host-version or attestation-result artifact was found in the inspected documentation
and test trees. Native attestation is still described as a future probe. Complete
those records, or explicitly approve a scoped deferral with the native release gate
intact, before representing M0 as finished. This audit cannot approve that deferral
on the maintainer's behalf.

### M1 evidence still missing

All six changed paths since c8b6d72 are documentation. The planned
`skills/loop-spec/program` directory is absent, and the fixtures document explicitly
says it is not implemented tests or evidence of M1 passing. There is no new M1
empty-cycle run, executable fixture manifest, or native/worktree/receipt probe record
in these changes. Existing 6.9 tests would not establish the new milestone.

To sign off M1, inspect its actual state/repo/baseline/events modules and phase/step
contract implementation, run the fake-runner empty-cycle and required rejection/
compatibility cases, and attach the pinned probe records. A passing documentation
lint is not a substitute. Approval to begin that implementation and milestone
completion are different decisions.

Validation: the five changed/current planning documents passed `lib/doc-tells.py`.
Reviewed the current route predicates and decision deltas; checked changed-file
scope and planned program/evidence locations. No live host or 7.0 runtime tests were
run. Only this review record was amended.


## Re-audit at revision 8d45bbb

The prior debug and adopted-history findings are addressed in the route matrix.
Debug now records a failing reproduction and sends its repair through ordinary
EXECUTE with a `mustFlip` check. Revise creates an adopted-range task with a fresh
full review and subjects it to E4–E7. T1 now covers PLAN→SPEC and EXECUTE→PLAN as well
as the previously bounded transitions. The unconditional blocked-to-escalated
terminal mapping is removed.

The native attestation record reports a positive result and negative controls on
Claude Code 2.1.278, macOS, with bypassPermissions. Accept it as a recorded single-host
feasibility observation. It explicitly does not demonstrate permission denial, SDK
execution, or task-worktree behavior. The raw prompts/results/check script are said
to be session scratchpad files, without exact locators in the record. This re-audit
read the report but did not independently replay those checks; a limited search for
probe-labelled metadata in the repository-specific transcript directory did not
locate their source records. That absence does not contradict the reported run.

The roadmap now records a maintainer decision to use live validation without a test
suite and to record observed versions rather than make version pins an M0 gate.
Those replace the earlier test-suite/version-pin requirements for this review. Do
not restore them implicitly. Live case results and event records remain required
under the new policy; deleting a test requirement is not evidence a case passed.

### Remaining findings

1. **P1 — early budget exhaustion routes to a phase that cannot accept it.** T1 at
   route-matrix line 70 sends exhausted PLAN/EXECUTE gaps to ITERATE. ITERATE at
   lines 187–191 still requires a VERIFY product and permits special entry only with
   VERIFY's gaps. I1 additionally binds an integrated SHA and plan revision. A
   repeated PLAN→SPEC cycle can exhaust the budget before an accepted PLAN or any
   verification exists. The budget is now counted, but its terminal route is not
   executable under the stated preconditions. Prefer controller-owned escalation
   directly from the exhausted phase, recording available state without claiming a
   verified deliverable. Alternatively define an explicit early-failure entry with
   suitable optional inputs and forbid convergence or partial delivery without
   eligible verified targets. This is the last substantive route issue found in
   this revision.
2. **P2 — adopted-task acceptance disagrees between the two contract tables.** The
   roadmap's EXECUTE product permits `adopted`, but its postconditions at line 146
   still require every commit to map to a `done` task and require review only for
   `done` tasks. The route matrix's E4/E5 correctly say `done` or `adopted`. Mirror
   those predicates in the roadmap, or make the detailed matrix authoritative and
   remove the duplicate normative table. The revise fix is otherwise accepted.
3. **P2 — the live-only validation decision is only partially applied.** The
   checklist header now says no automated tests, but its staging/mechanics still
   require an offline suite, fake model/PR execution, a 157-second ceiling and pinned
   versions. The inventory still promises a replacement offline suite, and the
   migration how-to points consumers to compatibility tests under `tests/`. M1's
   deliverable still includes a fake runner while its acceptance requires a live
   empty cycle. Rewrite the active validation instructions consistently, explaining
   any retained simulation tool separately from an automated suite. Specify the
   case-to-run/result/events record that proves a manual case passed. Also replace
   the roadmap's claim that the native runner already “shipped” with its actual
   status: feasibility observed, implementation/release still pending.

### Sign-off recommendation

M0: not unconditional sign-off yet. Resolve the early-exhaustion route and reconcile
the two active contract/validation descriptions. The recorded change in validation
policy and the single-host feasibility result need not be relitigated by this audit.

M1: not complete under either the former or revised criteria. The changes since
727b2b8 are documentation and the probe record. There is no new 7.0 program or live
empty-cycle result crossing the seven boundaries. Native attestation is one useful
probe, not the M1 cycle or the M6 compatibility gates.

Validation performed: current diffs and affected source sections reviewed; roadmap,
route matrix, native probe record and checklist pass the shipped documentation lint.
No paid runs, transcript replay, worktree probe or 7.0 execution was performed. Only
this review record was amended.


## Closure and M0 recommendation at revision 17707d4

**Recommend M0 sign-off.** The three findings from the 8d45bbb review are closed
at the written-contract level. No new blocking finding was identified in this change.

| Finding | Current evidence | Disposition |
|---|---|---|
| Early exhaustion entered ITERATE without its inputs | T1 now writes a controller-owned terminal escalation naming the refused exit, gap and budget. ITERATE requires VERIFY passed; I4 handles its own refused rewind or uncloseable gap. The terminal table includes controller escalation from PLAN/EXECUTE/VERIFY. | Closed. |
| Adopted commits rejected by the roadmap's coverage rule | Section 4 now maps commits to done or adopted tasks. The detailed E5/E6 predicates and roadmap section 7 require a fresh full review of the adopted range with accepted execution evidence. | Closed. |
| Conflicting validation policies | Roadmap, checklist staging/mechanics/completion, inventory and migration how-to now use deterministic-Python unit tests plus recorded live cycle cases. M1 uses the external placeholder, not a fake runner; old offline-cycle and version-pin requirements are retired. | Closed. |

One non-blocking summary wording cleanup remains: the roadmap's EXECUTE row says
“every done task” in its review clause, whereas E5 and section 7 expressly include
adopted tasks. Read the summary with those explicit requirements; it is not an
exemption from adopted-range review. Align that phrase when next editing the table.

The accepted validation rule is: unit tests for deterministic Python modules on
their own inputs and outputs; cycle-level behavior demonstrated by recorded live
runs. No offline cycle suite, fake runner, or pinned host-version gate is required.
Each live case records its run ID, result, events, plugin revision and observed host
versions. This audit does not reintroduce the retired testing policy.

M0 sign-off approves the documented architecture and recorded decisions. It does
not certify a working 7.0 release. The native attestation record remains one-host
feasibility evidence with its stated exclusions. F7's result compatibility evidence,
the M1 live empty-cycle and worktree checks, and independent native/SDK release gates
remain implementation-stage obligations. M1 is not complete on the evidence in this
revision.

Validation: reviewed the 17707d4 diff and affected route, task-coverage, validation,
and milestone sections. The five affected planning documents passed the shipped
markdown lint. No live run or runtime compatibility claim was added. The worktree
was clean before this closure record was appended; only the review record was edited.
