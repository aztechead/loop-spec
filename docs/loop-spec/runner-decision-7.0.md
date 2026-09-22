# 7.0 runner decision: native Agents and direct SDK workers

Status: evidence document, 2026-09-22. This comparison was written during the
review round and updated after reading the original Cloud Run report. The roadmap has
since adopted the phase-interface model, which changes where the runner question
sits. The section below states that position. Everything after it is the reviewers'
comparison and report analysis, kept as written, and is the evidence the position
rests on.
Audience: maintainers and reviewers of [ROADMAP-7.0.md](ROADMAP-7.0.md), sections 5,
6, and 9.

## Where this sits after the phase-interface decision

The roadmap now treats each phase as an interface with postconditions the program
checks against the repository, and lets three kinds of implementation satisfy a
phase: loop-spec's default, the default with roles bound to other skills, and an
external implementation done by a person or another tool. Under that model the runner
is a detail of the default EXECUTE and VERIFY implementations. It decides how a
worker gets started and how its result reaches the program. It no longer decides
whether the report's guarantees hold, because those are boundary checks and apply to
every implementation kind.

Two changes to this document's own analysis follow from the roadmap.

The result-transport concern in the comparison table is answered by the step
contract rather than by the choice of runner. A worker writes its JSON result to a
file the step names, and the lead submits only the step id, so the lead never holds
the payload and cannot summarize it. That answers the relay concern only. The
execution concern this document raised stands, and the
[second review](phase-interface-review-7.0.md) made the counterexample concrete: a
lead can write a valid result file itself. The roadmap now records an execution
evidence level per step, set by the program: controller-observed for a worker the
program spawned, host-attested when the host's transcript for a submitted agent id
can be checked, human-attested for an external phase, and unattested otherwise. Only
the SDK runner gives controller-observed evidence, which is the strongest argument in
this document's favor on the runner count.

Option I is superseded rather than rejected. The roadmap keeps what it was after:
one small product interface per phase, instructions that own the method, and no
helper vocabulary for the model to learn. It adds the piece this document found
missing after reading the report: postconditions the program verifies on the
repository, so a valid product cannot cross a boundary whose postconditions do not
hold. The boundary proves the execution and evidence protocol and nothing about
semantics; the roadmap's section 6 says which judgments stay with a model or a
person. Binding a phase to `external` lets a team do the phase with its own skills,
and the boundary check still runs, so it is a changed boundary compared with the
format-only option this document described, and the roadmap records it as such.

The one recommendation still open for the maintainer is the runner count before
cutover: the native runner alone on both hosts, with the SDK runner added on a
measured failure, or both runners with separate live gates as this document
recommends. The roadmap records both positions in its section 9. The authentication
finding below stands under either: the SDK runner can never be the interactive
default.

## Goal and decision

loop-spec should turn an approved request into a verified deliverable, with bounded
rewinds and durable evidence. The original roadmap proposes program-owned sequencing, state, worktrees,
integration, and delivery. The fourth option below challenges that mechanism.
Models investigate, implement, review, and judge intent in either architecture.
The required workflow is SPEC -> PLAN -> EXECUTE -> VERIFY -> ITERATE -> DELIVER,
plus debug. Claude Code remains a first-class interactive host.

**Direct SDK workers fit unattended execution better. Native Agents fit the existing
Claude Code experience better. Build both against one core protocol.** Recommend
SDK execution for unattended Claude deployments, native execution inside Claude
Code, and native host dispatch for other agents. Do not make SDK installation or
API credentials prerequisites for existing Claude Code users.

This differs from keeping S as an emergency fallback. It also avoids choosing one
transport at the expense of either deterministic execution or interactive support.
It costs two runner implementations and two live compatibility gates. That cost
is justified by the two supported operating environments, not by different cycle
logic: roles, state transitions, approval rules, validators, and integration stay
shared. This is an architectural inference from the capabilities below, not a
measured claim that one runner converges faster.

## Three mechanisms that must not be confused

1. Native: the program issues a step; the lead model calls its host's Agent tool
   and submits the result. Dispatch and result relay remain model actions.
2. SDK-hosted native: an SDK query runs a lead model that calls Agent. This still
   has the same dispatch boundary as native execution.
3. Direct SDK: the controller starts a query for the specific worker and consumes
   its stream and terminal output itself. No model chooses whether to launch that
   worker or copies its output into another call.

The SDK subagent documentation describes model-invoked Agent calls and notes that
a parent may summarize the returned result. Moving the lead into the SDK therefore
does not by itself create program-owned worker execution.
[SDK subagents](https://code.claude.com/docs/en/agent-sdk/subagents)

## Comparison against the goal

| Concern | Native Agent execution | Direct SDK execution |
|---|---|---|
| Dispatch reliability | Lead must execute the issued step correctly; validate host execution evidence | Controller starts the exact worker and records its lifecycle |
| Fresh context | Use a fresh, non-fork Agent with explicit inputs | Use a new worker session with explicit inputs |
| Task worktree | Native isolation exists; mapping to the program's assigned checkout needs proof | Controller supplies the initial working directory |
| Result transport | Agent result passes through the lead; needs lossless capture and validation | Controller reads structured output directly |
| Human decisions | Existing Claude Code interview and permission UI | Application must bridge questions and permissions |
| Progress and steering | Native worker display and session interaction | Stream events; implement cancellation and question routing |
| Installation | Keeps the host's runtime and login | Adds an SDK environment, compatible CLI, and supported authentication |
| Other agents | Uses each host's available dispatch surface | Claude-specific adapter |
| Convergence logic | Shared ledger, baseline, review coverage, and intent judgment | Same; the SDK does not fix a bad convergence policy |

Native's largest advantage is compatibility. Its largest weakness is that the lead
remains a protocol participant. Rejecting invalid submissions protects state but
does not guarantee progress. Repeated bad dispatches need a retry budget. A verdict
containing the right SHA does not prove a separate reviewer ran; capture a host
execution receipt and bind it to the issued step.

Direct SDK execution removes that model-mediated dispatch and relay from workers.
It also makes fake-runner tests closer to the real controller's lifecycle. Its
largest cost is owning integration details the interactive host already handles.
A background SDK process does not automatically become a visible native Agent or
inherit the live session's model choice and approval state.

Native subagents start in the parent's working directory; native worktree isolation
is a separate feature. A path in a role prompt is insufficient proof of correct
execution. Before implementing N, demonstrate how its actual checkout maps to the
program's task branch. Both runners still need repository postcondition checks;
initial working directory alone is not filesystem confinement.
[Claude Code subagents](https://code.claude.com/docs/en/sub-agents)

## SDK benefits have boundaries

Structured output reduces JSON transport errors. It does not prove review quality,
criterion coverage, or truthful evidence. The SDK can exhaust structured-output
retries, and a successful terminal subtype can still lack structured output.
Reject either case before advancing state.
[Structured output](https://code.claude.com/docs/en/agent-sdk/structured-outputs)

Keep tool availability separate from permission approval. Do not use automatic
approval lists to simulate worker isolation, or approve every non-question request
in a supervisor callback. Explicit denial must preserve the user's policy.
[SDK permissions](https://code.claude.com/docs/en/agent-sdk/permissions)

The SDK exposes questions through a callback; the application must present them or
apply an explicit policy. Keep SPEC and PLAN in the interactive lead, or in an SDK
interview session connected to that callback. A worker's intent gap becomes a
pending controller question. Transport failure or cancellation is not approval.
[User input](https://code.claude.com/docs/en/agent-sdk/user-input)

SDK hosting also adds process lifecycle work. Sessions run in subprocesses and
there is no automatic top-level wall-clock deadline. The controller must own
bounded concurrency, deadlines, cancellation, and recovery of interrupted attempts.
[Hosting](https://code.claude.com/docs/en/agent-sdk/hosting)

SDK cost results help account for workers, but a cycle needs its own accumulated
budget across calls. Missing or crash-affected usage is unknown, not zero. Do not
claim a strict global dollar ceiling from independent worker budgets alone.
[Cost tracking](https://code.claude.com/docs/en/agent-sdk/cost-tracking)

## Authentication changes the recommendation

Anthropic's quickstart directs SDK applications to API/provider authentication. It
states that third-party products cannot offer Claude.ai login or rate limits without
prior approval. Consequently, loop-spec must not promise that an SDK runner can
reuse every Claude Code user's subscription merely because credentials exist on
that machine. Keep native execution available under the user's existing Claude
Code login; configure SDK authentication separately.
[SDK quickstart](https://code.claude.com/docs/en/agent-sdk/quickstart)

This is a concrete reason against making nested SDK execution the universal Claude
Code default. A successful local credential experiment would not establish a
supported distribution contract. Native Claude Code and direct SDK execution can
both remain first-class without pretending their authentication is interchangeable.

## Fourth option: phase instructions with structured products

The user proposed comprehensive phase instructions with structured-output scripts
as the only loop-spec-specific tools. Ordinary host tools still perform research,
editing, tests, git operations, and dispatch. The agent chooses and carries out the
procedure; each output script accepts structured input and deterministically
produces a phase artifact.

This is a separate candidate from the roadmap's Option P. A small, consistent
product interface could remove much of the helper discovery and grammar burden
without moving all execution into a new controller. The cited run does not prove
that this simpler design fails; it describes failures in the existing large
protocol. Nor does it prove that formatting alone was the cause.

Potential advantages:

- Preserves native Claude Code tools, questions, login, and visibility naturally.
- Travels as instructions and portable scripts across hosts; an SDK is unnecessary
  for the core workflow, though an SDK application can still load the skills.
- Keeps implementation methods adaptable to each repository instead of encoding
  every workflow decision as a command or state transition.
- Gives each phase one clear deliverable and removes model-authored document shape
  as a source of lint failures. Shared scripts can return precise field errors.
- Could reduce maintenance and installation cost relative to two execution runners.

Potential disadvantages:

- Formatting guarantees apply only when the agent calls the script. They do not
  ensure that it ran the right reviewer, tests, or prerequisite phase.
- A valid PASS object can refer to stale evidence or a different checkout. A
  renderer cannot establish truth from a model's assertion alone.
- Worktree preparation, ordering, retries, and delivery remain model actions. A
  bad external action can happen before a product validator gets a chance to reject it.
- Fresh contexts need complete inputs: approved intent, baseline, prior findings,
  accepted/rejected changes, and remaining budget. A standard output format helps
  carry these, but instructions must specify that they are actually read next time.
- Interrupt recovery and repeated reviews still need durable records and a stopping
  policy. They are not resolved simply by writing valid markdown.

The user clarified the boundary: **scripts only validate formats and render
documents**. They do not validate evidence, record authoritative approval/phase
state, select routes, or authorize completion. They may render the agent's reported
evidence, approvals, and progress as document fields; those fields remain claims
for the next agent or human to inspect. Renderer success means format success.

This is deliberately a model-led workflow. Evaluate it on that basis instead of
adding a hidden controller to recover guarantees the design does not claim.

Possible phase products:

| Phase | Structured product |
|---|---|
| SPEC | Original request, scope, constraints, acceptance criteria, questions, decisions |
| PLAN | Tasks, dependencies, repository mapping, verification commands, criterion coverage |
| EXECUTE | Changes and commits per task, implementation evidence, unresolved issues |
| VERIFY | Tested SHA, baseline comparison, acceptance evidence, review findings and dispositions |
| ITERATE | Original-goal verdict, uncovered gaps, proposed return phase, remaining work |
| DELIVER | Verified SHA, PR targets, delivery outcome, caveats |
| debug | Failing reproduction, diagnosis, repair, post-fix evidence, goal verdict |

These are candidate contracts, not implemented interfaces. Instructions require
approval claims to cite the actual user/policy decision. Renderers do not certify
that the decision happened.

### Keep the JSON graph as the agent's workflow map

The user's graph suggestion fits this boundary. Keep one versioned JSON file for
the phase topology and links to the phase instructions and product schemas. The
agent reads a node, performs its instructions with host tools, renders the product,
and chooses an outgoing edge based on the observed outcome. No script walks the
graph or evaluates its conditions.

The existing `graph/cycle.graph.json` is not ready to reuse unchanged: its nodes
contain executable probes, gate scripts, commit actions, and state mutations.
Preserve the useful topology while replacing those bindings with instruction and
product references. Keep the current 6.9 graph untouched until a 7.0 candidate is
validated. A node could have this shape (paths illustrate a future layout):

```json
{
  "id": "VERIFY",
  "instructions": "phases/verify.md",
  "inputs": ["SPEC", "PLAN", "EXECUTE", "previous_VERIFICATION"],
  "product_schema": "schemas/verification.json",
  "routes": [
    {"outcome": "passed", "next": "ITERATE"},
    {"outcome": "implementation_gap", "next": "EXECUTE"},
    {"outcome": "plan_gap", "next": "PLAN"},
    {"outcome": "intent_gap", "next": "SPEC"},
    {"outcome": "evidence_incomplete", "next": "VERIFY"},
    {"outcome": "blocked", "next": "BLOCKED"},
    {"outcome": "needs_answer", "next": "PAUSED"},
    {"outcome": "budget_exhausted", "next": "ESCALATED"}
  ]
}
```

Use the same small vocabulary throughout: node ID, instruction reference, inputs,
product schema, and named outgoing outcomes. Define PAUSED, BLOCKED, ESCALATED,
and COMPLETED as explicit terminal/pause records, with resumption instructions.
ITERATE maps goal gaps to SPEC, PLAN, EXECUTE, or VERIFY and permits DELIVER only
when the goal is met. Debug can have a separate entry/subgraph for reproduction,
diagnosis, repair, and the shared verification/goal-check/delivery sequence.

Keep topology authoritative in the graph and phase methods in instructions. Do not
repeat the edge list in every skill. On resumption, the agent reads prior products,
checks the actual repository and PR state, and records its chosen next phase and
reason in its next product. Graph version and product format version make the
handoff interpretable after an upgrade. The graph describes permitted progression;
it does not certify that a transition actually occurred.

A rewind budget belongs in the instructions/graph and is reported in products.
The agent observes it; only the host's existing limits can supply independent
runtime enforcement under this design. Unknown outcomes or conflicting evidence
should instruct the agent to pause, not invent a successful route.

**Assessment after reading the original report:** Option I is a useful simplification
experiment, but is not yet a sufficient unattended replacement. It addresses
protocol complexity while relinquishing enforcement the report explicitly asks
to preserve. Keep the user-selected format-only boundary honest; testing can measure
agent adherence, but cannot turn a renderer into an execution or approval guard. Compare
both on wrong-worktree execution, stale-SHA evidence, missed intent, repeated
findings, interrupted delivery, and actual completion. Count invalid submissions,
manual interventions, cost, and code maintained—not just rendered-document validity.

Anthropic's engineering guidance favors starting with simple compositions and
adding orchestration where measurements justify it. That supports testing this
candidate, without establishing that it meets loop-spec's specific requirements.
[Building effective agents](https://www.anthropic.com/engineering/building-effective-agents)

## Evidence required if program-owned execution is selected

The shared controller issues an immutable step with role, prompt/schema digest,
input SHA, worktree identity, and attempt ID. Each adapter reports start, progress,
result, cancellation, and recoverable failure. The shared validator checks both
payload and repository state before the integrator advances. Delivery reconciles
existing remote state before retrying external writes.

SPEC and PLAN preserve interviews and approval digests. EXECUTE performs task
implementation and review. VERIFY checks evidence and code at the integrated SHA.
ITERATE separately judges the original request and routes remaining gaps to SPEC,
PLAN, or EXECUTE. DELIVER consumes current validated evidence. Debug retains red
reproduction, bounded repair, verification, and a final goal check.

Before M1, collect executable probe evidence for:

- Native dispatch into the assigned worktree, fresh context, result capture, and
  verifiable role execution; repeated invalid dispatch must terminate predictably.
- Direct SDK success, malformed or missing output, denial, interruption, and
  worker cleanup. Do not rely only on fake-runner tests for host semantics.
- Settings, project instructions, MCP access, and user hooks in task worktrees;
  record the tested CLI and SDK versions and selected settings sources.
- Native installation with no SDK dependency or new API credential, and SDK
  installation with explicitly configured provider authentication.

Before M7, run the same defect/remediation scenario independently in interactive
Claude Code and the SDK deployment. Also exercise every required phase and debug,
a green checklist with an unmet original goal, approval rejection, interruption,
and resumption. Record time, invalid submissions, retries, cost where observable,
and terminal correctness. No performance winner is established until these runs.

## What the original report changes

Source: the user-provided `LOOP_SPEC_IMPROVEMENTS-2026-09-21 2.txt`, run
`ea-bab52ab61339d02c81292aa4a6c451805bc233bd`, pinned loop-spec 6.9.0. Read in full
after the initial comparison. The report contains quoted log evidence; the complete
underlying logs were not supplied or independently replayed.

The report strengthens the case for a smaller interface, but weakens the case for
format-only tools as the complete unattended solution. Its most serious finding is
item 3: missing task worktrees, failed packaging, absent reviewer invocations, then
the lead marking both commits done anyway. This was not malformed output. A valid
EXECUTE document could reproduce the same false completion claim.

The first recommendation therefore changes: evaluate I as a deliberate reduction
in enforcement, not as a presumed reliability improvement. For an unattended 7.0
replacement expected to retain the report's guarantees, recommend a small shared
controller with an explicit native Claude Code path and a direct SDK worker path.
That is an alternative to the user's format-only boundary, not permission to add
state mutation or evidence checks to renderers.

The report does not establish that the SDK is the cause or cure. The failed run
already used the SDK. It implicates information loss across phase boundaries,
incorrect or inconsistent guards, missing termination policy, and costly interfaces.
Fixing those matters more than the choice of SDK versus native dispatch.

### Findings mapped to Option I

| Report item | What format-only products and instructions can improve | What remains unproved or unenforced |
|---|---|---|
| 1. Repeated full-diff reviews | Carry findings, dispositions, reviewed SHA, and delta-review instructions forward | Reviewer reads and honors prior adjudication; valid output alone does not establish review coverage |
| 2. Unbounded rewinds | Include attempt history, budget, self-inflicted regression classification, and terminal vocabulary | Agent observes the budget; host deadline is independent, but cannot determine semantic convergence |
| 3. Unreviewed work marked done | Require explicit reviewed/unreviewed fields and worktree checks in instructions | Launch refusal on missing worktree and refusal to publish without review; format validation cannot enforce either |
| 4. False baseline regression | Remove faulty raw-log fingerprinting; instruct comparison by failing-test identity | Agent comparison accuracy; adding passing tests must be tested explicitly |
| 5. Integrator rejects baseline failures | Give implementation and verification the same baseline product | Correct integration and recording after a failed command |
| 6. Environment rediscovered eight times | Carry one baseline/environment product; require reading it and preparing the environment | Fresh phases actually consult it and recognize the same failure |
| 7. Undocumented remediation JSON | Publish schemas and actionable field errors at the product boundary | Registration semantics become agent work; renderer success is not task acceptance |
| 8. Markdown triage lint failures | Render current findings and prior dispositions from structured fields | Agent supplies correct current-versus-superseded status |
| 9. Verify command paths | Instructions require testing commands from the actual task worktree | Correct working directory and command execution |
| 10. Two phase states disagree | Eliminate competing driver/feature phase stores; keep static topology separate from run history | Agent reconstructs the correct current position after interruption |
| 11. SPEC re-approval inaccessible | Explain amendment, confirmation, and replacement-document procedure | The report explicitly wants the intent guard retained; format-only tools cannot enforce it |
| 12. State pollutes the PR | Specify off-branch product storage and focused review inputs | Agent excludes artifacts and inspects the actual delivered diff |
| 13. Ambiguous task-progress path | Retire that helper interface | Agent tracks task completion accurately |
| 14. Blocked criterion vocabulary hidden | Include explicit blocked/environment fields and offline-probe guidance | An offline substitute actually proves the criterion; formatting cannot decide equivalence |
| 15. Helper discovery failures | Ship a small, reliably located renderer interface with examples | Installed skills can actually resolve that interface on both hosts |
| 16. Inconsistent task flags | Retire that helper interface | New renderer interface must stay consistent |
| 17. Tool call after handoff | Explicitly instruct the agent to end the phase at the handoff | The existing guard stopped the call; instructions alone offer weaker enforcement |
| 18. Already-integrated mistaken for empty | Instruct ancestor checks and distinguish outcomes in the product | Agent actually checks ancestry and records the right result |

### Preserve the successful behavior

- Fresh per-phase contexts. The report credits nine separate sessions with avoiding
  context degradation. One long lead session with six instruction files is not the
  observed successful arrangement. Prove an appropriate fresh-context mechanism on
  interactive Claude Code as well as SDK handoffs, without losing human decisions.
- Independent review and acceptance reasoning. The report's defects were semantic,
  not merely schema failures. Preserve both, plus the separately required ITERATE
  judgment against the original request.
- The verifier's offline stand-in and sensitivity check. Keep room for this judgment;
  do not label all unavailable cloud checks either automatic PASS or automatic failure.
- Approved intent and explicit re-approval. Option I preserves these as instructions,
  but gives up the machine guard the report specifically praised. Record that
  difference rather than claiming equivalent protection.
- Stable phase and handoff markers. Format-only scripts can render marker syntax
  from supplied fields, but cannot certify phase completion or make a host stop.
  Preserve the host's handoff behavior and state the provenance of reported fields.

### Corrections to the initial roadmap diagnosis

Section 1 had characterized twelve items as lead misuse. That is too broad. The
report also identifies deterministic implementation defects: faulty fingerprints,
missing worktree launch checks, non-idempotent state transitions, and a re-approval
recorder checking the old digest. These are failures of the tooling itself.

Likewise, the report does not prove that a fresh reviewer cannot find a real defect
in previously reviewed code. A prior PASS is evidence of a review, not proof every
line is correct. Use prior findings, reviewed scope, and explicit reasons for new
findings to control churn. Do not globally suppress Important findings merely to
produce convergence; distinguish new code, new evidence, and known accepted caveats.

The self-inflicted test case also needs care: provenance can identify a remediation
regression, but it does not justify weakening an assertion automatically. Check
whether the test or implementation violates the approved behavior before changing it.

## Audit limits

This comparison uses the current repository, the supplied original report, and
official vendor documentation. No paid model runs or live plugin compatibility
tests were performed. The report is one observed run; it demonstrates concrete
failure modes but does not measure competing 7.0 architectures. The proposed host
gates must establish actual behavior on pinned releases.
