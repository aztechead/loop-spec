# 7.0 M1 fixtures specification

Reference for the agent implementing the 7.0 contract, and the live checklist the
maintainer ticks while using the plugin. Prepared from `c8b6d72`, including the
thirteen accepted migration decisions. Decided 2026-09-22: 7.x unit-tests only its
deterministic Python modules; no case below becomes an automated test, because every
case here is cycle-level behavior. A case is done when a live run has shown its
expected outcome and that run's result and events are recorded next to the case id. This is a specification, not evidence that any case has passed.

Sources: [roadmap](ROADMAP-7.0.md), [route matrix](phase-interface-7.0.md),
[migration inventory](migration-inventory-7.0.md), and the two
[interface](phase-interface-review-7.0.md) / [follow-up](phase-interface-reaudit-7.0.md)
reviews. This file adds no runtime command or configuration spelling. M1 schemas
must supply those names and update the [migration how-to](migrating-6-to-7.md).

## Ownership and staging

This specification is an independent contribution for the implementing agent and
the maintainer. The roadmap, route matrix, migration decisions, and runner choice are
unchanged. The native attestation probe is done (`native-attestation-probe-7.0.md`);
host versions are recorded per live run, not pinned. Do not infer host support from a
case shown on one host.

At M1, implement the shared protocol, the external placeholder implementation, and
the boundary code, then show the M1 cases live. Later-phase cases are shown at their
target milestone. A case that has not been run live is not a passing case, and M1
completion does not imply M3–M6 behavior exists.

| Target | Required evidence |
|---|---|
| M1 | shared identity/lifecycle checks; schema and route cases; compatibility cases; a live empty-cycle traversal with every phase external; the host-probe record with its versions |
| M2 | real SPEC/PLAN boundary behavior, answer scopes, approvals and critic admission |
| M3 | real worktree/dispatch/integration behavior, probe placement and external EXECUTE |
| M4 | real verification, intent judgment, baseline comparison and bounded remediation |
| M5 | real delivery orchestration against a local remote or a throwaway GitHub repository; workspace and revise cases |
| M6 | independent live native-Claude-Code and direct-SDK records, each naming the versions it ran on |

## Fixture mechanics

Use a temporary consumer repository with two tasks, two acceptance criteria, one
pre-existing failing test, and known base/task commits. Add a second repository for
workspace cases. Use real Git operations and small local test commands for checks
that purport to observe the world. A canned PASS result must not supply the oracle
for whether a Git ref moved, a command ran, or a checkout is clean.

Model execution is real: the case is shown by running the plugin. For M1 cases
every phase is the external placeholder, so no model is dispatched and the boundary
machinery is what is observed. The program's events ledger is the dispatch log:
attempt, role, method and input digests, repository, range, lifecycle, and output.
Delivery cases use a local bare remote or a throwaway GitHub repository the
maintainer owns; the PR service is real.

Every case declares: stable case ID, source predicate, target milestone, setup,
stimulus, observable assertions, and whether a decision below blocks its expected
outcome. A shown case records the run id, the result file, and the events ledger
next to its ID. Error-code spelling remains M1 work. Assert semantic failure class and state
until the public codes exist, then freeze those codes in the reference.

For every rejected submission assert that the next phase did not open, the feature
and remote refs did not advance, no successful terminal result was published, and
accepted state was not overwritten. Diagnostic events and bounded retry bookkeeping
may legitimately change. For accepted submissions assert the expected transition,
artifact, event, and repository result rather than just an exit code.

Timeouts and missing host handles must never be interpreted as proof of successful
termination.

## Shared protocol and host boundary cases

| ID | Target | Setup and stimulus | Observable result |
|---|---|---|---|
| ID-01 | M1 | Submit a valid product, then mutate run ID, phase/step attempt, input digest, requirements revision, or plan revision individually. | Positive control advances once; each stale identity is rejected. |
| ID-02 | M1 | Publish half a JSON file at the temporary path; finish and atomically rename it; submit twice, then change its contents under the same attempt. | Partial file is not consumed; identical replay has no repeated effect; conflicting replay rejected. |
| ID-03 | M1 | Process returns 0, 1, 2, 3, or an unknown exit code, with matching and missing files. | Only validated product readiness advances; step/question yields persist pending state; malformed or unknown returns do not advance. |
| ID-04 | M1 | Worker submits a result after cancellation; another worker writes to the retired worktree while the new attempt runs. | Retired result rejected; distinct worktrees; retired commits never integrated. |
| ID-05 | M1 | Grace expires while a host worker remains live; later the host confirms exit. | Cancel requested where supported; quarantine and cleanup backlog first; deletion only after confirmation. |
| ID-06 | M1 | Edit state outside the writer; send a progress event claiming phase completion through the implementation event seam. | State divergence stops continuation; progress cannot create authoritative transition or terminal records. |
| AT-01 | M1 | Place valid review JSON at the expected path without a dispatch; submit an implementer's transcript containing only its digest. | Default review admission fails and task remains unreviewed. |
| AT-02 | M1 | Supply a completed review transcript; alter opening role/method, attempt/input, repo/range, or final result digest separately. | Only the fully bound transcript is host-attested. Native feasibility remains M6 evidence. |
| AT-03 | M1 | No readable transcript; repeat with explicit weaker-review config and with correlated human attestation. | No automatic SDK switch; default refuses review; explicit exception is visible in weakenedAssurance; approved external evidence follows its declared policy. |
| AT-04 | M1 | Direct runner succeeds, errors, omits structured output, exhausts schema retries, or reports permission denial. | Only a valid completed worker produces accepted controller-observed evidence; denial never widens permissions. |
| AT-05 | M1 | Bind a different role skill and revise its content; inspect the issued step. | Resolved method/version is recorded; mandatory contract and result schema stay attached; old input/method evidence cannot be reused. |

## SPEC and PLAN

| ID | Gates | Target | Setup and stimulus | Observable result |
|---|---|---|---|---|
| SP-01 | S1, S2, S3 | M2 | Submit valid SPEC with a product-authored approval, then approve through the question channel. | Product alone cannot approve; correlated human/policy answer enables approved exit. |
| SP-02 | S2, S3 | M2 | Change criteria or decisions with goal/boundaries unchanged; replay an earlier approval. | Requirements digest changes; approval reopens; downstream products are stale. |
| SP-03 | S2, S3 | M2 | Answer a current or retired question with question scope; then test run scope and entry answer policy across two runs. | Question scope affects one ID; run scope answers later questions only in that run and lists them; stale IDs rejected. |
| PL-01 | P1, P2, P5, P6 | M2 | Valid two-task DAG; remove criterion coverage, add cycle/dangling dependency, or name an unresolved workspace repo. | Valid plan accepted; each malformed graph or coverage/repo case rejected. |
| PL-02 | P3, P4 | M2 | Verify command fails from a bare task root due to a wrong path; baseline suite has a known test failure. | Path error is distinct from observed pre-existing failure; prepare precedes base capture and its environment is recorded. |
| PL-03 | P3, P4, E7 | M3 | Feature-added test path absent at base; first candidate run succeeds, collects nothing, or fails. | Base record is no-baseline; only meaningful success establishes task-local baseline. |
| PL-04 | P7 | M2 | Critic has no Critical finding, then an open Critical finding with a disposition such as deferred. | No-finding control passes; a Critical marked `deferred` fails P7; `fixed` passes only after the critic re-ran once on the corrected plan; `rejected` passes only with a stated reason; a Critical still open after the re-run exits `spec gap` or asks a question (DEC-03 resolved). |
| PL-05 | P7 | M2 | Skip critic, forge its completion, or return non-Critical style advice. | Missing execution is not a critic pass; Critical-only review contract is retained; style advice does not create a new blocking gate. |
| PL-06 | envelope probes | M2 | Consumer files contain known conventions, helper duplication, layer count, security signal, and imports. | PLAN receives program probe facts and recorded dependency excerpts for those files, not plugin-source lint results. |

## EXECUTE

| ID | Gates | Target | Setup and stimulus | Observable result |
|---|---|---|---|---|
| EX-01 | E1, E2, E3, E4 | M3 | Implement/review task A only in a plan requiring A and B; dispatch B before dependency A is complete; attach an extra unmapped commit. | Each case prevents integrated exit; complete positive control passes. |
| EX-02 | E5, E6 | M3 | Reviewer names a range omitting a task commit or supplies unattested evidence. | Task remains unreviewed and cannot integrate under default policy. |
| EX-03 | E7 | M3 | Base and candidate have the same failing test identities but different pass counts/timing; then introduce one new failure. | First case is baselined; second is a regression. Shared baseline is used by integration and verification. |
| EX-04 | E8 | M3 | Missing task worktree before dispatch; worker writes on the feature branch; feature head moves out of band. | Missing root prevents launch; other cases pause/reject without resetting user changes. |
| EX-05 | E2, E8, E9 | M3 | Empty range with all tasks already satisfied, then with a required task missing; nonempty range incorrectly claims no change. | Only evidenced no-change reaches VERIFY at base; no case bypasses VERIFY/ITERATE. |
| EX-06 | E10 | M3 | Repeated invalid step results reach the configured limit; repeat after a permission denial. | Bounded re-issue; no success; `blocked` pauses with a question naming the cause and `status: paused`; a fix answer re-enters EXECUTE, a stop answer or `run`-scoped policy yields `status: escalated` (DEC-04 resolved). |
| EX-07 | E11 | M3 | Security signal on task files lacks a disposition; then include a valid disposition. | Missing disposition prevents integration; signal and disposition bind the correct task/range. |
| EX-08 | probe placement | M3 | Implementer commits; record probe calls, reviewer inputs and review dispatch order. | Diff probes run after commit and before review; other probe findings are inputs, not newly invented automatic blockers. |
| EX-09 | E1 to E8, E11 | M3 | External EXECUTE returns correct-shaped output with missing tasks/review, then legitimate human-attested evidence. | External binding uses the same boundary checks and cannot bypass them. |

## VERIFY and ITERATE

| ID | Gates | Target | Setup and stimulus | Observable result |
|---|---|---|---|---|
| VE-01 | V1, V2, V3 | M4 | Duplicate or omit a criterion, use stale revisions or another evidence SHA, then provide a complete current product. | Invalid case cannot pass; current complete positive control may advance. |
| VE-02 | V4 | M4 | Worker dirty checkout passes a check, but the committed source fails. | Controller-created checkout proves the committed failure; worker claim does not become accepted evidence. |
| VE-03 | V4 | M4 | Re-runs differ only in elapsed time/temp paths; then change a substantive parsed observation. | Normalized first case matches; semantic difference rejects comparison; raw digests remain provenance. |
| VE-04 | V4, V5 | M4 | Non-repeatable flag without approval; then approved PLAN exception or current operator answer; then stale approval. | Only correlated approved exceptions skip the re-run and appear in weakenedAssurance. V4 applies to the remaining commands. |
| VE-05 | V6, V9 | M4 | Cloud check becomes unavailable after baseline; offline stand-in proves the behavior and rejects a mutation; alternatively it cannot establish it. | New environment observation retained; genuine substitute can support evidence; unavailable proof stays blocked. |
| VE-06 | V7, V8 | M4 | First/final full review and intermediate delta review; raise a finding on a clean prior range with/without a typed supersedes reference. | Correct ranges/ledger supplied; missing required reference rejected; open Critical cannot pass. |
| VE-07 | V7, I5, I6 | M4 | VERIFY blocked, no Critical finding, an Important finding with a disposition, and ITERATE claims caveats. | Must not classify as converged-with-caveats: I5 requires VERIFY `passed`, so VERIFY `blocked` pauses instead and never reaches ITERATE's convergence exits (DEC-02 resolved). |
| VE-08 | V1, V2, V8, I3 | M4 | Replay report-shaped alternating acceptance/review failures via VERIFY→EXECUTE remediation without ITERATE. | Must terminate within the shared budget T1 (default two backward transitions across VERIFY, PLAN, EXECUTE, and ITERATE routes); the third backward exit is refused and ITERATE exits `escalated`. Fresh phase/step attempts cannot reset it. Add the PLAN, EXECUTE, PLAN loop as a second shape (DEC-01 resolved). |
| VE-09 | whole-range probes | M4 | Two tasks introduce a cross-task issue visible only on the integrated diff. | VERIFY receives whole-range probe findings in addition to task reviews. |
| IT-01 | I1, I2, I3 | M4 | Green checklist but original goal unmet; route gap to SPEC, PLAN, EXECUTE, or VERIFY; stale goal verdict. | Correct rewind and evidence invalidation; stale verdict rejected; counter advances once. |
| IT-02 | I4, I5, I6 | M4 | Goal met with no caveats; goal met with accepted non-Critical caveats; goal unmet at budget exhaustion; open Critical. | Correct full/draft/escalated outcome; no false convergence. Both converged exits require I5; caveats contain only accepted non-Critical review findings (DEC-02 resolved). |
| IT-03 | I3, I4 | M4 | Replay the same rewind submission; restart the program; attempt another rewind after exhaustion. | Idempotent counter, durable budget, and no unbounded new attempt. Minimal repair policy must not reset the budget. |

## DELIVER, debug, revise, and workspace

| ID | Gates | Target | Setup and stimulus | Observable result |
|---|---|---|---|---|
| DE-01 | D1, D2, D3 | M5 | PR has wrong head/base/ref, closed state, wrong SHA, or failed required checks; compare ready target. | Incorrect target never reports delivered; positive control binds repo and exact SHA/readiness. |
| DE-02 | D4 | M5 | PR creation succeeds remotely but its response is lost; resume delivery. | Reconcile by identity; one PR, no duplicate external write. |
| DE-03 | D4, D5, D7 | M5 | Two repos; first publishes, second fails credentials or readiness. | Per-repo result and partial publication are truthful; no all-delivered result; credential check precedes each repo's first write. Resolve DEC-05 row mismatch. |
| DE-04 | D6 | M5 | Already-satisfied request passes VERIFY at base and ITERATE. | No push/PR creation; no-change-needed and already-satisfied fields preserved; new result classification is additive. |
| DE-05 | D7 | M5 | Expired credentials at DELIVER; host refresh succeeds/fails. | Check/refresh before any write; failure names repair and blocks; removed refresh-command env var is never executed. |
| DE-06 | D1 to D7 | M5 | Resume delivered/partially delivered workspace with matching or newly changed remote refs. | Idempotent reconciliation on unchanged targets; changed target revalidated rather than trusted from old output. |
| DB-01 | B1, B2, B3 | M4 | Same reproduction fails before repair and passes after; altered reproduction only; no reproduction. | Reproduction fails at base and is recorded as the `mustFlip` baseline (B1); the repair runs through EXECUTE and E7 proves the flip; a changed reproduction records both runs (B2); no reproduction pauses with a question and a stop answer escalates (B3, DEC-04 resolved). |
| RV-01 | revise entry | M5 | Same-repo open PR with new comments; run remediation through VERIFY/ITERATE/DELIVER. | Adopt branch, compact SPEC and PLAN with one `adopted` range task plus gap tasks, full review step over the adopted range becomes its review record, remediation, VERIFY over the whole PR, same PR identity updated. Assert every adopted commit maps to the `adopted` task (E4) and that task has a review record (E5, E6) (DEC-06 resolved). |
| RV-02 | PR adoption | M5 | SPEC names an open PR; repeat with missing gh, closed PR, or fork head. | Supported PR adopted; documented fallback creates a new execution branch without mutating the unsupported PR. Keep SPEC fallback separate from revise's open-PR precondition. |

## Compatibility and migration fixtures

Freeze the legacy expected results from the 6.9 contract and its writer, reviewed
independently of the new implementation. Exercise the actual consumer behaviors
that branch on fields; JSON round-tripping alone does not test classification.
Unknown additive fields may be ignored. The result pointer relocation is an accepted
migration, so the consumer fixture explicitly changes that lookup path and nothing
else about its legacy interpretation.

| ID | Cases | Observable result |
|---|---|---|
| CO-01 | Ready delivery; clean draft; draft with blocking iteration warnings; delivered-unready; delivery-blocked. | Preserve legacy status/outcome/converged/workDelivered/retry meanings; new result field cannot overwrite them. |
| CO-02 | No-change, failed run, escalated partial draft, outstanding question, interrupted delivery before/after remote creation. | Truthful legacy fields, per-target state, current run identity, and no stale success. A blocked delivery is `status: paused` with the cause in `reason`; a stop answer yields `status: escalated`, `result: escalated`, per-repo state (DEC-04 resolved). |
| CO-03 | Console stream unset/stdout/stderr/invalid; console events on/off; Cloud Run job/service/neither. | Versioned precedence matches retained behavior; ledger independent of console suppression; accepted 7.x markers-on-stdout change explicit. |
| CO-04 | Start, handoff, re-enter, rewind, question, terminal and duplicate submit. | Paired attempt IDs, stable marker JSON, correct phase/next projection, and no duplicate transition on retry. |
| CO-05 | State home resolved through plugin data, LOOP_SPEC_HOME, or fallback; previous successful pointer exists; start another run. | New state-home pointer is atomic and stale success unavailable; consumer repo gets no loop-spec state by default. |
| CO-06 | Native plugin and skill installation; inspect distributed files and relative program paths. | No shipped hook/agents/MCP config; output style retained; entry skills resolve program. Actual host loading is live evidence. |
| CO-07 | Retained cycle/phases/debug/micro/status/revise; removed surfaces; revision-mismatched standalone deliver. | Retained entries preserve their preconditions; no implicit restoration of removed modes; deliver cannot skip gates. |
| CO-08 | question-scoped and run-scoped answers, paused result, explicit entry policy, stale answers, next independent run. | Only current authorized scope applies; policy-answered questions listed; no catch-all tool approval introduced in SDK supervisor. |
| CO-09 | Quarantined worker and explicitly weakened review or verification. | Result exposes cleanup backlog and weakenedAssurance; unknown additive fields do not break the migrated consumer. |

## Decisions for the implementing agent

These are small contract questions exposed by executable-style cases. They do not
reopen the thirteen accepted migration decisions. Proposed resolutions below are
recommendations, not silently adopted route changes.

| ID | Current gap | Recommendation | Fixtures blocked on exact expected outcome |
|---|---|---|---|
| DEC-01 | Matrix explicitly leaves VERIFY→EXECUTE remediation unbounded; only ITERATE spends rewind budget. This recreates the original report loop. | Count backward remediation transitions against one persistent feature budget, or choose a separate finite persisted cap. No fresh attempt may reset it. | VE-08, IT-03 |
| DEC-02 | ITERATE caveats requires I1 and I6 but not VERIFY passed or goal satisfied; its input may be VERIFY blocked. | Require no open goal gap and VERIFY passed for both convergence outcomes. Caveats may describe only accepted non-Critical review findings; unmet proof escalates/rewinds. | VE-07, IT-02 |
| DEC-03 | P7 allows any disposition for a Critical critic finding. | Require fixed-and-rechecked or explicitly rejected-with-reason; an unresolved/deferred Critical cannot make PLAN ready. Record how the one-pass policy handles a corrected plan. | PL-04 |
| DEC-04 | EXECUTE blocked/resume, VERIFY blocked/resume, debug blocked reproduction, and delivery-blocked classification are explicitly deferred to M1. | Freeze their route and legacy result mappings before asserting fixtures passed; preserve pending versus terminal distinctions and resumable current state. | EX-06, DB-01, CO-02 |
| DEC-05 | D7 says it gates partially delivered, but that exit lists only D4 and D5. | Add D7 to the exit requirements for repos whose remote writes were attempted; assert pre-write credential order via fake service log. | DE-03 |
| DEC-06 | debug goes straight to VERIFY whose prerequisites require EXECUTE; revise can adopt a PR without recorded current PLAN/SPEC. | Define how these entries establish equivalent current requirements, plan, head and approvals before shared gates, including an external PR with no prior loop-spec state. | DB-01, RV-01 |

Resolved by the maintainer on 2026-09-22 and carried into the route matrix: DEC-01,
one shared persistent budget for every backward transition (T1, referenced by I3), with the review
and verify contracts told the goal is show-stoppers and incorrect implementations;
DEC-02, the shared convergence predicate (I5) with caveats limited to accepted
non-Critical review findings (I6); DEC-03, fixed-and-rechecked or rejected-with-reason
(P7); DEC-04, every `blocked` exit pauses with a question and only a stop answer
escalates; DEC-05, D7 required per repo whose remote write was attempted; DEC-06,
debug and `revise` open with a compact SPEC and PLAN. The fixtures named in the last
column now have their expected outcomes.

The other-agent handoff is to implement those resolutions in the M1 schemas. Every
case row above now states its expected outcome under the accepted rule. A fixture that
meets a rule this document does not state exposes the gap explicitly rather than
choosing an outcome or marking the case green.

## Native feasibility and live evidence handoff

The native probe must run inside an actual interactive Claude Code session with the
maintainer. Record CLI/SDK version where relevant, platform, install shape, runner,
permission mode and settings sources. Do not copy credentials or private transcripts
into test fixtures or Git. Produce synthetic transcript fixtures only after the real
structure and accessible fields are observed.

The probe issues a program-shaped review prompt with attempt/input/method identity,
repository/range, and a result file. Capture the real host dispatch ID. Demonstrate
that the program can read and bind the dispatch opening, completion and result
without a lead-authored substitute. Repeat with wrong role/range/result and an
unavailable transcript. Observe question handling, denial and cancellation using
the host's actual behavior. This establishes feasibility only; M6 still runs the
full defect/remediation/PR scenario independently on native Claude Code and SDK.

Each record names the versions it ran on; a documented version or an installed
binary alone says nothing about behavior. A failed native probe must not be
converted into an automatic SDK fallback or called a passed native gate. The first
record exists: `native-attestation-probe-7.0.md`, Claude Code 2.1.278.

## Completion evidence for this specification

The implementing agent should attach a manifest that maps each ID to the live run
that showed it: run id, result file, events ledger, plugin commit, and the host
versions recorded. M1's report separates shown, failed, pending implementation, and
blocked decision. A case with no recorded run is not evidence of anything.
