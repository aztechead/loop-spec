# loop-spec 7.0: phases as interfaces

Reader: the maintainer deciding whether to build 7.x, the engineer building it, and
the reviewers asked to break the argument. One job: say what 7.x is, why, and in what
order it gets built. It is a decision document with one reference section (section 4)
that the decision has to be checkable against. It is not a user guide.

Status: favored plan, 2026-09-22, after two external review rounds. The second,
[phase-interface-review-7.0.md](phase-interface-review-7.0.md), found nine holes in
the first version of the contract below. A re-audit,
[phase-interface-reaudit-7.0.md](phase-interface-reaudit-7.0.md), confirmed three
closed and left six open; this revision addresses those six in the sections they
name. Closure is the re-audit's call, not this document's. The counterexamples from
both reviews are rejection cases on the live checklist. 6.9 stays on
`main` and keeps receiving fixes until 7.0 passes its live gates (M6). Then `main`
becomes 7, a `6.x` branch is cut for maintenance, and the marketplace entry follows
`main`. The runner comparison that fed this plan is in
[runner-decision-7.0.md](runner-decision-7.0.md).

## 1. Why a new line

The 2026-09-21 Cloud Run report (`LOOP_SPEC_IMPROVEMENTS-2026-09-21 2.txt`, headless
Agent SDK, one session per phase) ran 6.9.0 for 2h56m across 9 sessions and 699 tool
calls, rewound from VERIFY to EXECUTE four times, and never converged. The harness
killed it and opened the PR itself with a failure status. The implementation was good
and every gate caught a real defect. The run still failed, for two structural
reasons.

The two VERIFY gates never passed on the same pass. Each pass spawned a fresh reviewer
over the whole cumulative diff with no record of what earlier passes had cleared. Pass
8 returned PASS with zero findings. Pass 10, on a diff that changed by one test line,
returned BLOCK on a query shape written in the first wave and already cleared.
Acceptance and review took turns failing. The run ended with 17 of 17 criteria
passing and two Important findings open, and the only signal available was
"non-converged".

The model drives a deterministic protocol. Skill prose names 139 distinct scripts. The
lead must know each one's path, flag grammar, JSON shape, markdown format, and call
order. The report shows both interface misuse and defects in the helpers themselves: a
worktree not created before dispatch, so two commits merged unreviewed while state said
reviewed; remediation JSON rejected wholesale for a field no usage text names; a
markdown linter tripping on findings from a superseded pass; a re-approval path
reachable only by importing a private module; a raw-log fingerprint that counted a
changed test count as a regression; a baseline the integrator could not see.

Prior fix rounds (PRs #93, #100, #106, #108) expanded guards and helper interfaces.
Items 5 and 6 were first raised on 2026-07-27 and are still open, because the fix
needs one baseline object shared by many scripts and nothing owns state. That is the
impasse, and it is why this is a new line rather than a fix release.

The report also says what to keep, and 7.x keeps all of it: fresh context per phase;
gates that catch real defects; the verifier's instinct to build an offline stand-in
for a credential-blocked criterion and mutation-check it; the approved-SPEC intent
guard; the machine-readable phase markers.

## 2. The model

The six phases SPEC, PLAN, EXECUTE, VERIFY, ITERATE, DELIVER, plus debug, are
interfaces. How a phase is satisfied inside is up to its implementation. The
interface between phases is owned by loop-spec, and the program checks it against the
repository before the next phase opens.

This is the answer to "why not just use BMAD, or Matt Pocock's skills, or spec-kit".
Those are instruction sets, and several of them describe how to do a phase better than
loop-spec's own prose does. None of them can hold a finding ledger across sessions,
refuse to mark a task done without a review, or tell a harness whether a run converged.
Under this model they are implementations of a phase, and loop-spec is what decides
whether a phase's result may cross into the next one.

An interface is a contract on the world. A phase product with a valid shape is
necessary and never sufficient. The report's critical item 3 is the reason: a valid
EXECUTE document could have described the same false completion. So every boundary
has postconditions the program verifies against the repository and the state
directory, and an implementation that produced a correct product and a wrong
repository does not advance.

Three kinds of implementation satisfy a phase, through one pluggable contract
(section 5):

- The default, which loop-spec ships and which 7.0 builds. It is program-run, with
  judgment done by roles.
- A bound implementation, which is the default with one or more roles swapped for a
  skill someone else ships. Binding is described in section 8.
- An external implementation, where a person or another tool did the phase. The
  program pauses at the boundary, lists the postconditions, and checks them when told
  the phase is done.

What the program owns does not depend on which kind ran: state, the sequence, the
baseline, the ledger, rewind accounting, integration, delivery, the output stream, and
every boundary check.

## 3. What is not negotiable

An implementation can change how a phase is satisfied. Nothing can change these:

- The seven phases and their order. A standalone DELIVER cannot bypass VERIFY or
  ITERATE.
- The product schema for each phase, and the fact that the product arrives as JSON
  the program validates. Markdown artifacts are rendered from the product. No
  implementation authors SPEC.md, PLAN.md, or VERIFICATION.md, so their shape is
  guaranteed rather than linted.
- The postconditions in section 4 and the checks the program runs for them, and the
  route matrix that says which exit a product may claim.
- The carried state every implementation receives and must honor: the requirements
  revision and its approval record, the plan revision, the baseline, the finding
  ledger with its reviewed ranges, the rewind count and budget, and the entry mode.
- The identity protocol in section 5: run, phase attempt, and step attempt ids;
  input digests; one-time question ids; atomic result publication; the program as
  the only writer of transitions and results.
- The execution evidence level recorded for every worker step and carried into the
  result (section 5). No implementation can raise its own level.
- The output stream (section 15): the phase markers, the console lines, the events
  ledger, the terminal result in its existing schema, and the chat shape.
- Rewind accounting, the budget, and the terminal results.
- Never overriding a value the host already exposes to the user. Model, permission
  mode, settings sources, and hooks are the user's. Tool availability and permission
  approval are separate; an auto-approve list is never used as a restriction boundary.
  `LOOP_SPEC_MODEL_<ROLE>` stays as the one operator override, unset by default.

## 4. The phase interface

This section is reference. It is the part a reviewer should try to break, and the
second review did: skipped tasks, an empty range, a weakened criterion under an
unchanged digest, a wrong PR, and a review nobody ran all passed the first version.
The rows below are written against those counterexamples. The full contract, with
field lists and schemas, becomes its own reference page when the code lands in M1;
this table is the shape it has to have.

Two identities run through every row. The requirements revision is a digest of the
SPEC product's goal, boundaries, acceptance criteria, and decisions; open questions
are excluded. Any change to those four parts produces a new revision and reopens
approval. The plan revision is a digest of the PLAN product. Every later product binds
to the revisions it was produced against, and a product bound to a stale revision is
rejected at the boundary without reading further.

Every phase receives the same envelope: the products of prior phases, the carried
state (section 3), and an entry mode of `fresh`, `remediation` with the gaps to close,
or `rewind` with the findings that sent it back. Every phase returns a product that
declares one exit from its route list; the program accepts that exit only when the
postconditions for it hold.

| Phase | Product | Preconditions | Postconditions the program checks | Exits |
|---|---|---|---|---|
| SPEC | goal, boundaries, acceptance criteria with ids, decisions, open questions | request text | an approval record exists that was produced from a human or policy answer to a question naming the proposed requirements revision; the record references the question id; the product's own fields cannot create it | approved, needs answer |
| PLAN | tasks with id, dependencies, files, repo, verify command, criteria covered; prepare command | approved requirements revision | every criterion id is covered by at least one task; every verify command either runs at the base SHA from a bare worktree root, or is declared `feature-added` with a target path that does not exist at base and is validated at that task's first integration; baseline captured (section 11); plan bound to the requirements revision | ready, spec gap |
| EXECUTE | per-task disposition of `done`, `already-satisfied` with evidence, `removed` by an approved plan amendment, or `adopted` for the one range task a `revise` entry creates; commits per task; unresolved issues | PLAN at the current requirements revision; baseline | every required task has an accepted disposition, and dependencies are complete before dependents; every commit in `base..head` maps to a `done` or `adopted` task; every `done` task has a review record whose reviewed range covers all of that task's commits and whose execution evidence level meets the accepted class for review steps (section 5); each task's verify command produced no new failure identity against its baseline, or, for a `feature-added` command, a meaningful first success as defined in section 11; feature head is reachable from base; the product binds to the plan and requirements revisions per repo; an empty range exits `no-change` and can never exit `integrated` | integrated, no change, blocked, plan gap |
| VERIFY | per-criterion verdict of `pass`, `fail`, or `blocked`, each with evidence of command, SHA, exit status, parsed failure identities, and raw output digest; findings with dispositions; remediation tasks; reviewed range | an EXECUTE exit of `integrated` or `no-change`, at the current revisions; the verified head is the integrated head, or base for `no-change` | every criterion id in the requirements revision has exactly one verdict; every evidence SHA equals the verified head; the program re-runs every cited command in a clean checkout of that SHA that it creates itself, with the prepare fixtures applied, and compares command identity, exit status, parsed failure identities, and the output digest after the versioned normalization of section 11, keeping the raw digest for provenance only; a criterion may skip the re-run only under an exception approved outside the implementation, either declared in the PLAN product and approved with it or granted by an operator answer to a question at VERIFY time, and never by a flag the implementation sets on its own; its verdict is then recorded at assurance `claimed` and the result lists it under `weakenedAssurance`; a `blocked` verdict cites a cause the program itself observed, in the baseline record or in that re-run; `passed` requires every verdict `pass` and the review policy in section 10 satisfied; a finding on cleared code carries a typed `supersedes` reference | passed, implementation gap, plan gap, intent gap, evidence incomplete, blocked |
| ITERATE | goal verdict against the original request; gaps; route | VERIFY passed at the current revisions, including the `no-change` head | the verdict binds the integrated SHA, the requirements revision, and the plan revision; a gap routes to SPEC, PLAN, EXECUTE, or VERIFY for missing evidence, and the rewind counter advances | converged, converged with caveats, rewind, escalated |
| DELIVER | per-repo PR identity, delivered SHA, caveats | ITERATE `converged` or `converged with caveats`; or `escalated` when the operator policy allows partial delivery as a draft; a `no-change` head that ITERATE converged terminates here without a PR | per touched repo: the remote head ref's SHA equals the verified SHA; the PR is open, its head ref and SHA match, and its base target matches configuration; required checks satisfy the configured readiness policy, carrying 6.9's exact-SHA and required-check behavior; a retried creation is reconciled by identity, never duplicated; partial publication is recorded per repo and never reported as all delivered; a `no-change` result opens no PR and says so | delivered, partially delivered, delivery blocked |
| debug | reproduction as command plus failure digest; diagnosis; a compact SPEC and PLAN whose one repair task carries the reproduction as a `mustFlip` verify command | error report | the program ran the reproduction at base in a clean checkout and it failed, and that digest is the `mustFlip` baseline; a changed reproduction needs a stated reason and both runs are recorded; no reproduction exits `blocked reproduction`; the repair then goes through EXECUTE, where E7 proves the flip, and VERIFY, ITERATE, and DELIVER follow | reproduced, blocked reproduction, then as EXECUTE onward |

The no-change path, made explicit. When the plan's tasks are all `already-satisfied`
with evidence, EXECUTE exits `no-change` with head equal to base. VERIFY still runs,
at base, and every criterion must be proven there rather than assumed; ITERATE still
judges the goal; DELIVER opens no PR and the terminal result carries the existing
`no-change-needed` outcome (section 15). Nothing about an unchanged head bypasses
verification or the goal check.

Routes the first version left implicit, now named. A `blocked` VERIFY verdict may
cite a failure the program observed for the first time at VERIFY, such as an expired
credential, and the observation is recorded next to the baseline's. ITERATE may route
to VERIFY when evidence is incomplete, as 6.9 does. DELIVER accepts an escalated
partial result only under an explicit operator policy, and the result says
`partially delivered`. A review coverage reference is typed: `supersedes` names a
finding id, or a reviewed-range id when the cleared code had no finding; reviewed
ranges get ids when the ledger records them.

The VERIFY row's re-run is the strongest check available from outside an
implementation, and it is a full re-run, not a sample. It proves that the cited
commands produce the cited results at the cited SHA. It does not prove that a command
tests the criterion it is attached to. That remains a judgment, and section 6 says
who makes it.

## 5. The implementation contract

One contract serves all three kinds. It is a process-level contract, because an
external implementation may be a person and a bound one may be a skill written for
another agent. The default implementation conforms to it as well, so it can be
replaced or wrapped without the program knowing.

An implementation is invoked with a context file and must produce a product file:

```
loop-spec phase <name> --context <dir>/context.json --product <dir>/product.json
```

- `context.json` holds the envelope from section 4: prior products, carried state,
  entry mode, the repository or workspace map, the state directory, the paths the
  implementation may write to, and the ids below.
- `product.json` is the phase product. The program validates it against the schema on
  return and then checks the postconditions for the exit it declares.
- Events go through `loop-spec emit`, which appends a progress event to the ledger and
  prints the console line. An implementation can record progress this way and
  nothing else: phase transitions, step acceptance, and results are records only the
  program writes.
- A question for the human is a `question.json` in the state directory and exit
  code 3. The question carries a one-time id. The program surfaces it, records the
  answer against that id, and re-invokes with the answer in context. An answer to a
  retired id, such as one asked before SPEC changed, is rejected. An answer carries a
  scope: `question` answers this id only; `run` answers this id and every later
  question of the run by the default policy, recorded in state. `--answer-policy
  default` at entry sets the `run` scope from the start. The result lists every
  question a policy answered. This is how a harness that federates questions to a
  chat channel lets the person answer, or say "proceed without me" for the rest of
  the run; it replaces 6.9's `LOOP_SPEC_NON_INTERACTIVE` and `LOOP_SPEC_AUTONOMOUS`
  (decided 2026-09-22).
- A request for the lead to execute something is a `step.json` and exit code 2. The
  step names a role, a working directory, a prompt, an output schema, a result path,
  and a step attempt id. This is how the default implementation dispatches a worker
  on hosts where the program cannot spawn one itself (section 9).
- Exit 0 means the product is ready. Exit 1 is a program error with the repair
  named. No other exit code advances anything.

Identity and lifecycle, which the first version asserted and did not specify:

- A run has an id. Each phase entry has an attempt id. Each step has an attempt id.
  Every context file carries a digest of its inputs, and every product and result
  carries the ids and digest it was produced against.
- A worker publishes its result atomically, by writing to a temporary path and
  renaming to the attempt-scoped result path. The program consumes a result once and
  retires the attempt. A result arriving for a retired attempt is rejected by id;
  timestamps are never the discriminator.
- `submit` is idempotent for the same attempt id and result digest, and rejects a
  second, different result for the same attempt.
- Cancelling an attempt retires it, and the program cleans up the children it
  started. A worker the lead started is retired the same way; whether its process is
  stopped depends on the host, and the program does not claim to stop it. Because a
  retired native worker may still be writing, its worktree is never reused: a new
  attempt gets a new worktree and a retired worktree is never integrated. A retired
  worktree is deleted only after termination is confirmed, by the host reporting the
  dispatch ended or by the program observing that a process it started has exited.
  When a grace period the operator sets expires without that confirmation, the
  program requests cancellation from the host where it can, marks the worktree
  quarantined, reports it in the cleanup backlog of the terminal result, and leaves
  it on disk. Expiry never proves a worker stopped and never deletes anything.
- Evidence is bound to a checkout the program resolves, never one the implementation
  supplies. The program's re-runs happen in a clean checkout of the target SHA that
  it creates for the purpose, with the prepare fixtures applied, and the evidence
  record names that worktree. A worker's own run in its working tree is recorded as
  the worker's claim; the program's run in the clean checkout is what the boundary
  compares.
- The program is the single writer of `state.json`. It keeps a digest of the last
  state it wrote and refuses to continue over a file whose digest differs, which is
  how an out-of-band edit is detected.

Execution evidence. A result file proves that a result was published for a step. It
does not prove who produced it. The second review's first finding is the case: a lead
recovering from a failed dispatch writes a plausible review result itself, and every
file property holds. So each worker step records an evidence level, set by the program
and never by the implementation:

- `controller-observed`: the program started the worker itself and consumed its
  stream. Only the SDK runner provides this.
- `host-attested`: the lead dispatched the worker through the host and submitted the
  host's agent or session id; the program checked that the host's transcript for that
  id exists, postdates the step, and contains the result digest. Where the host
  exposes no transcript, the level is `unattested`.
- `human-attested`: an external implementation, attested by a named answer to a
  question, recorded against the question id.

Accepted classes are defined per role and are defaults, not options a policy has to
remember to set. For a review step, `controller-observed` and `host-attested` are
accepted; `unattested` is never accepted by default, so a task whose only review is
unattested is listed in `unreviewed` and EXECUTE cannot exit `integrated`. An operator
may accept `unattested` reviews only by writing `evidence.review.accept: unattested`
in the repo config, and every result produced under that setting carries a
`weakenedAssurance` entry naming it. For an implement step the level is recorded and
nothing gates on it, because the review is the gate. For an external phase,
`human-attested` is accepted.

Host attestation binds more than a timestamp. The program composes every worker
prompt, so it embeds the step attempt id, the input digest, the role and method
digest, the repository, and the reviewed range in the prompt it hands out; the host's
transcript for the submitted dispatch id must contain that opening and must end with
the result digest. A transcript that contains the digest without the matching
opening is an implementer's session and is rejected. Whether native Claude Code
exposes a transcript the program can read this way is a probe in section 19, and the
native path shipped as the default review runner once it passed on 2026-09-22 (the
probe record is `native-attestation-probe-7.0.md`). Where the
host exposes no transcript, a native review is `unattested`, and the operator has
three visible choices: the SDK runner, an external human-attested review, or the
weakened-assurance setting. The program never selects the SDK runner on its own.

The level is stored per step in the ledger, rolled up per task, and carried into the
terminal result's `reviewed` and `unreviewed` lists. No level proves the review was
good.

The three kinds map onto this contract as follows. The default is a Python entry in
the program's own tree, invoked in-process for speed and exposed through the same
command for parity. A bound implementation is the default with the roles named in the
binding config resolved to other skills; the contract is unchanged. An external
implementation is a placeholder that exits 2 with a step of kind `external`, listing
the postconditions; `submit` with that step id tells the program the phase is done,
and the postconditions decide. External is a changed boundary compared with the
earlier format-only idea: the program still verifies and still controls progression.
That is a decision, recorded in section 20, and not an equivalent way to get
format-only behavior.

The binding lives in the consumer repo at `.loop-spec/config.json`, next to
`workspace.json`:

```json
{
  "phases": { "execute": "external" },
  "roles":  { "review": "mattpocock-skills:code-review" }
}
```

`LOOP_SPEC_PHASE_<NAME>` and `LOOP_SPEC_ROLE_<ROLE>` override per run. The program
records the resolved implementation and the resolved skill for every phase and role in
the events ledger at run start, so an audit can say which method produced which
product.

## 6. What is guaranteed and what stays judgment

The postconditions are observable predicates over the repository, the state
directory, and command re-runs. They guarantee the execution and evidence protocol:
no skipped task, no unreviewed commit, no stale evidence, no wrong PR, no result for a
retired attempt, and a recorded answer to who ran each worker. They do not and cannot
prove semantics. Three judgments stay with a model or a person, and the plan says so
rather than hiding them behind a hash:

- Whether a review was thorough. The ledger, the delta rule, and the evidence level
  bound the churn and record the provenance. Quality is the reviewer's.
- Whether an evidence command actually tests its criterion. The re-run proves the
  command's result; relevance is the verifier's, and ITERATE is the second opinion.
- Whether the delivered behavior satisfies the original request. ITERATE's verdict is
  bound to a SHA and a revision, and it can still be wrong.

Trust model. Workers are cooperative and are not sandboxed. A working directory and
an appended contract do not restrict a worker's filesystem access, and the plan does
not promise write isolation. The program detects instead of prevents: an out-of-band
change to the feature branch pauses for reconciliation, a state file whose digest
differs from the last write stops the run, and a result for a retired attempt is
rejected. A hostile implementation can waste a phase. It cannot make the boundary
report a review that has no evidence record, or a task that has no disposition.

## 7. The default implementations

These are what 7.0 builds. They are the reference implementations of section 4, and
the parts of 6.9 worth keeping live here.

SPEC and PLAN run in the lead session, in-context. Before either role drafts, the
program runs its deterministic probes on the files the request or the plan names and
hands the facts in as inputs: neighbourhood conventions (`house-style probe`),
existing helpers near the touched files (`duplication-scan`), the layer count at base
(`indirection-scan`), the security or destructive-change signal per file, and the
third-party dependencies the touched files import together with fetched excerpts of
their current documentation (`doc-deps`, `docs-probe`). After the PLAN product is
drafted and before it is submitted, a light critic role reads it once for Critical
misses only: a criterion no task covers, a task whose verify command cannot test what
it claims, a destructive change with no boundary. It raises Critical findings or
nothing; it does not restyle the plan (decided 2026-09-22). A Critical finding closes
only as fixed, with the critic re-run once on the corrected plan, or rejected with a
stated reason; it cannot be deferred, and one still open after the re-run exits
`spec gap` or asks a question. The spec role interviews with
`AskUserQuestion` natively, exactly as 6.9 does. In Claude Code that reaches the
person. Under the SDK the supervisor's `can_use_tool` answers it by policy, which
`examples/supervisor` already does. The lead submits each product; the program records
the approval digest for SPEC. Both roles may need a human, which is why they run where
questions are cheap. Context lifecycle, stated per host: in interactive Claude Code
the lead's session holds SPEC and PLAN and then a list of step ids, and every worker
is a fresh context. Under the SDK a harness may keep one session per phase, as the
report's did, because `run` is resumable from state and `LOOP_SPEC_HANDOFF` marks the
boundary; the next session enters from state and the answered questions travel in it.
Fresh phase entry is therefore a property of the harness's choice, and fresh worker
context is a property of the design.

EXECUTE is program-run. After an implementer commits and before the review step is
issued, the program runs the same probes in diff mode on that task's commits in its
worktree (`comment-tells`, `failure-tells`, `indirection-scan` against the base
count, `duplication-scan`, `house-style compare`, `doc-tells` on touched markdown)
and hands the findings to the reviewer as inputs. A task touching a file with a
security signal needs a disposition per signal in its review record. The probes are
facts in; the judgment on them is the reviewer's. The program resolves the task DAG into waves of at most three,
creates a worktree per task before anything is dispatched, and hands out one step at a
time: implement, then review, for each task. Each worker runs as a fresh context in
its worktree and writes its JSON result to the file the step names. The lead submits
only the step id. The program validates the JSON, checks that the commit is on the
task branch in that worktree and that the feature head has not moved out of band,
runs the task's verify command against the baseline, records the execution evidence
level, and integrates by fast-forward. The phase exits `integrated` only when every
required task has an accepted disposition, so a plan with two tasks and one commit
cannot exit at all until the second task is done, already satisfied with evidence, or
removed by an approved amendment.
A rejected step is handed out again with the reason attached, up to a per-step retry
limit, after which the phase exits `blocked`. An out-of-band change to the feature
branch pauses for reconciliation and is never reset automatically.

VERIFY runs the probes once more over the whole `base..head` range as a cross-check for
the first and final review pass, then dispatches a verifier and a reviewer as fresh contexts with the ledger as
input. The reviewer sees the full diff on the first pass and on an explicit final
pass, and the delta since the last reviewed SHA otherwise. The verifier is told to try
an offline stand-in before marking a criterion blocked, and may mark it blocked only
for a cause the program observed, in the baseline or in its own re-run at VERIFY. The
program re-runs every cited evidence command before the phase can exit. Section 10
has the convergence rules.

ITERATE is a fresh goal-judgment role. Its input is the immutable original request,
the approved spec, the integrated diff, the acceptance evidence, and prior gaps. It
judges whether the delivered behavior satisfies the request, including scope the
checklist missed, and routes gaps.

DELIVER is program code: push, one PR per touched repo with the rendered summary,
draft when caveats remain, reconciled against existing remote state before any
external write is retried. DELIVER may run hours or days after PLAN, so before its
first remote write it checks the git and `gh` credentials and attempts the host's
own refresh (the credential helper, `gh auth status`); it never runs a configured
refresh command. When credentials cannot be refreshed it exits `delivery blocked`
naming the command and the repair (decided 2026-09-22).

`revise` re-enters after a human has reviewed the delivered PR: the program fetches the
PR comments, maps them to gaps, and enters EXECUTE in `remediation` mode on the PR's
branch; VERIFY, ITERATE, and DELIVER then update the same PR by identity. A request
that names an open PR at SPEC entry adopts that PR's branch as the execution branch
through the repo module, failing safe to a new branch when `gh` is missing, the PR is
closed, or its head is a fork (decided 2026-09-22).

debug keeps the 6.9 loop-debug principles as role input flags: a failing
reproduction before any repair, bounded retries, and a blocker recorded when no
reproduction is available rather than a false pass. debug and `revise` both open with
a compact SPEC and PLAN in the lead so that every later phase sees ordinary revisions
and ordinary products. debug records the reproduction failing at base as a `mustFlip`
baseline and hands the repair to EXECUTE as one task whose verify command is that
reproduction; the repair is implemented, reviewed, and integrated like any task, and
E7 proves the flip. `revise` maps the PR comments to gap tasks and adds one `adopted`
task for the PR's existing `base..head` commits; the program runs a full review step
over that range at EXECUTE entry so the adopted commits carry a real review record
and nothing in the range is exempt from the coverage rules. Every
`blocked` exit in any phase pauses with a question, resumes into the same phase on a
fix, and exits `escalated` on a stop answer (decided 2026-09-22).

## 8. Roles as bound skills

A role is a prompt plus an output schema. The default prompts are ported from the 6.9
`agents/*.md` charters: spec-writer, planner, implementer, code-reviewer, verifier,
and iterate-judge. The port keeps each charter's procedure, engineering principles,
and what-not-to-do sections, drops its script references (the program now hands those
facts in as inputs), and replaces its report format with the schema. The shared
contracts the charters cite, such as engineering stances and the grounding protocol,
fold into the default role bodies. Each default role is a directory in the Agent
Skills format:

```
skills/loop-spec/roles/<role>/SKILL.md   frontmatter: name, description, allowed-tools; then the method
skills/loop-spec/roles/<role>/schema.json
```

A step's prompt is composed from three parts, and only the first is swappable:

1. The method: the bound skill's body, default or borrowed.
2. The contract: a short section loop-spec always appends per role, carrying the gate
   semantics that are not the method's business. For review: which range to read,
   that a finding on cleared code must name what it supersedes, that the verdict names
   the SHA reviewed. For verify: the blocked rule and the stand-in instruction.
3. The inputs and the output instruction: the resolved facts for this step, and the
   result file to write JSON matching the schema to.

With Matt Pocock's code-review skill bound, the reviewer receives his skill body
verbatim, then loop-spec's review contract, then the inputs. The skill supplies how to
review. Loop-spec supplies what to look at and what shape to answer in.

Three rules govern what can be bound where, learned from looking at the candidates:

- The schema decides fit. A skill fits a role when its natural product is close to
  the role's schema. Pocock's grill-with-docs and BMAD's brainstorming end in a domain
  model or ideas, so they fit SPEC. Bound to PLAN they would run and then improvise
  tasks at the contract's finishing step, and quality would drop silently there.
  Pairings that fit today: grill-with-docs or grill-me for SPEC, to-tickets for PLAN,
  tdd for implement, code-review for review. Verify and iterate have no outside
  candidates, because nothing else produces evidence per criterion or a goal verdict.
- Interactive skills bind only to lead roles. A skill that interviews a human works in
  SPEC and PLAN. It cannot bind to implement, review, or verify, which never ask.
  Under the SDK an interview goes to the supervisor's policy, and that is a degraded
  interview; an unattended deployment should know before binding one.
- Skills come from sets with sibling assumptions. Pocock's expect a setup step and an
  issue tracker, and grill-with-docs hands off to to-spec and then to-tickets. A role
  may therefore bind a list, so PLAN can be grill-with-docs then to-tickets. The
  events ledger records which skill at which commit produced each product, since a
  skills update can change a method underneath a repo.

A borrowed skill cannot change the schema or skip the contract. It can touch the
filesystem, including the state directory, because workers are not sandboxed
(section 6); the program detects an altered state file by digest and stops. If the
skill never writes the result file, the retry limit ends the phase as blocked. The
damage a bad method can do is a bad judgment or a wasted phase, which is the same
risk as a bad default.

## 9. How a worker runs

This was the headline decision in the first draft. Under the interface model it is a
detail of the default EXECUTE and VERIFY implementations, and the
[runner comparison](runner-decision-7.0.md) is the evidence.

The default hands the worker to the lead as a step, and the lead runs it with its
host's own mechanism: the Agent tool in Claude Code and under the SDK, the
equivalent elsewhere. The program owns the worktree, the ordering, the schema, and the
checks on the repository afterward. The lead never carries the payload, because the
worker writes its result to a file the step names. That file is transport, and it
records `host-attested` execution only when the program can check the host's
transcript for the submitted agent id (section 5). It is not on its own a proof that
the role ran. This works on every host that
can run a command, edit files, and spawn a fresh context, and it needs nothing beyond
the standard library.

A second runner, in which the program spawns each worker itself through the Python
Agent SDK, holds the working directory and ordering by construction and validates the
schema before the program sees the output. It is Claude only. SDK applications must
use API or provider authentication, and a third party cannot assume a Claude.ai login
carries over, so this runner can never be the interactive default. It can serve an
unattended SDK deployment that has configured its own credentials.

Decided 2026-09-22: ship both runners before cutover. Native execution is the path for
interactive Claude Code and is an independent release gate; direct SDK execution is
the path for unattended deployments with their own configured authentication.
Passing the SDK gate cannot compensate for a broken native path, and the program
never switches an interactive user to SDK credentials on its own. The native
attestation probe (section 19) is an early feasibility gate: if native Claude Code
cannot attest a review, the maintainer decides before release whether the
human-attested or weakened-assurance paths meet the promised native workflow. The
earlier alternative, native alone with the SDK runner added on a measured failure,
was set aside because only the SDK runner yields controller-observed evidence. Both runners sit behind one lifecycle contract of start, progress, result,
cancellation, and recovery, with the same validator, ledger, retry limits, and
integrator on either side.

## 10. Convergence

- Every review finding is a ledger record: location, cause, severity, the SHA it was
  raised against, and a disposition of `fixed`, `rejected` with reason, or `deferred`
  to the backlog. The ledger is part of the reviewer's input on every pass.
- The first review pass and an explicit final pass see the full diff. Every other pass
  reviews the delta since the last reviewed SHA. A finding on a line a prior pass
  cleared requires a `supersedes` field naming the earlier finding and why it was
  wrong. The schema makes the field required when the location is inside cleared
  ranges. The reference is typed: a finding id, or a reviewed-range id when the
  cleared code had no finding, and the ledger assigns range ids as it records them.
- Severity on re-review does not demote every Important finding after the first pass.
  New or changed code and new evidence get substantive review. A repeated finding on
  previously reviewed code needs a reason for reopening. Known Important caveats may
  be deferred with the disposition recorded. Critical always blocks. A prior PASS is
  evidence of a review and no proof that every line was correct.
- Acceptance evidence is keyed by SHA. A criterion keeps its verdict when its evidence
  command's output is unchanged at the new head and none of its files were touched;
  otherwise it re-runs. Reuse has dependency invalidation, so unchanged old output can
  never stand in for a new SHA. Both VERIFY gates are evaluated at the same SHA, and
  convergence also requires an ITERATE verdict for that SHA and the current spec
  digest.
- One budget bounds every backward transition: ITERATE rewinds, VERIFY's routes back
  to EXECUTE, PLAN, or SPEC, and evidence-incomplete re-entry. Default two, operator
  override, counted once per accepted transition, persisted across sessions, never
  reset by a fresh attempt (decided 2026-09-22 from the M1 fixtures review, which
  found the September report's loop intact under a remediation route the budget did
  not count). The review and verify contracts tell the roles what the budget is for:
  show-stoppers and outright incorrect implementations; the PR review catches the
  rest. When a previously passing criterion fails and `git log --diff-filter=A`
  shows the failing test file was added by a remediation commit, the route first
  decides whether the test or the implementation violates the approved behavior.
  Provenance identifies the case and never authorizes weakening an assertion on its
  own. Past the budget, remediation is restricted to minimal diffs and new broad
  assertions are forbidden by the implement role's input flags.
- Four terminal results. `converged`. `converged-with-caveats`: acceptance and ITERATE
  passed, non-Critical findings remain, delivered as a draft PR that lists them. Both
  converged outcomes share one predicate, VERIFY passed and no open goal gap; a
  caveat is only an accepted non-Critical review finding, never a blocked criterion or
  a goal gap (decided 2026-09-22).
  `escalated`: the budget is spent with a criterion or a goal gap still open; the
  verified partial state is delivered as a draft PR and the result names what is
  outstanding, with a reason code for the July report's converged-but-undeliverable
  case. `failed`: a program error, or an environment that cannot run the plan. A
  harness reads the result and applies its own policy.

## 11. Baseline and environment

- The baseline is captured once, after PLAN and before EXECUTE, at the base SHA, in a
  throwaway worktree: every verify command the plan declares, except those marked
  `feature-added`, plus detected repo checks from the manifests present. This also proves each plan command runs from a bare
  worktree root, which retires the report's item 9.
- Failures are keyed on test identity. Per-runner parsers for pytest, vitest and jest,
  go test, and cargo test extract file plus test name. A normalized fingerprint, with
  paths, durations, counts, PIDs, and timestamps stripped under a versioned
  normalization rule, is the fallback for unknown output. A summary banner that
  changes because a passing test was added cannot register as a regression. The same
  parsers and the same normalization rule are what VERIFY's evidence comparison uses
  (section 4), so an elapsed time or a temporary path can never reject a valid
  verification; the raw output digest is kept for provenance and is not compared.
- A command the plan declares `feature-added` has no run at base. The baseline records
  it as `no-baseline`. At the owning task's first integration the command must run and
  succeed meaningfully: exit zero, and at least one parsed test identity where a parser
  exists. That first run becomes the command's task-local baseline for every later
  comparison. Absence at base is neither failure evidence nor automatic tolerance.
- Environment health is part of the baseline. A command that cannot collect at all is
  recorded once with its error class. The verifier and the integrator read the same
  record, so a pre-existing failure is litigated zero times instead of eight.
- An optional `prepare` command from the repo config runs before the baseline. This is
  the environment-preparation hook the July and September reports both asked for.
- Integration reason codes distinguish `verify-failed`,
  `verify-failed-at-baseline-too`, `already-integrated` (the commit is an ancestor of
  the feature head and is published normally), and `zero-commit`.

## 12. State and artifacts

Run state leaves the branch. The report's reviewer saw a 512-line `feature.json`
ahead of the source files, and the harness had to strip it at delivery. 6.9 has a
`refs/loop-spec/state/<slug>` convention and still commits `docs/loop-spec/features/`,
so both happen.

What comparable tools do, checked 2026-09-21: spec-kit, OpenSpec, BMAD, and ccpm all
commit specs and plans as markdown in a tool-named directory of the user's repo. None
has a consistent home for run state. Claude Code documents a per-plugin data
directory, `${CLAUDE_PLUGIN_DATA}`, resolving to `~/.claude/plugins/data/<id>/`,
created on first reference, kept across plugin updates, removed on uninstall, and
intended for Python dependencies and state that should survive updates. The
placeholder resolves inline in skill content and is not an environment variable
inside Bash tool calls.

- The state home is `${CLAUDE_PLUGIN_DATA}` when the plugin is installed in Claude
  Code and the skill passes the resolved path to the program, else `$LOOP_SPEC_HOME`,
  else `~/.loop-spec/`. Keyed by repository identity and slug. The
  `last-result.json` pointer lives here too, beside `state.json`, not in the consumer
  repo (decided 2026-09-22; 6.9 consumers change one path, shown by a live checklist case at M1).
  An empty directory is initialized in place by the repo module, with 6.9's refusals
  to nest a repository or to init inside a workspace. One `state.json` per
  feature with one writer, plus `events.jsonl`, worktrees, per-phase context and
  product files, and the rendered artifacts.
- Nothing is committed to the consumer repo by default. The PR body carries the
  rendered summary: spec goal and boundaries, the acceptance table with evidence, the
  finding ledger, outstanding findings, and the rewind count. A consumer that wants
  the rendered SPEC and VERIFICATION docs in-tree sets `commitArtifacts` in the repo
  config, and they land in one commit the review package excludes by pathspec.
- Resumption across clones is a seam: `loop-spec state push|pull` onto
  `refs/loop-spec/state/<slug>` for a harness whose clone does not outlive the run. The
  report's harness keeps its clone for the whole job, so this is not built until a
  harness needs it.
- No other host directory is written to. The data directory is the one the host offers
  for this.

## 13. Workspace mode

Kept as a capability and rebuilt in the repo module, so nothing else re-detects it.

- A workspace is a root with a `.loop-spec/workspace.json` naming repos, or a root
  whose children are git repositories, as in 6.9. The program resolves it once at PLAN
  submission and stores the resolved repo list in state.
- Every repo-scoped thing is per repo in state: base SHA, feature branch, worktree
  root, baseline, and delivery target. A task names its repo; its worktree, verify
  command, and integration run there.
- The DAG is workspace-wide, so a wave may run tasks in different repos in parallel.
- DELIVER opens one PR per touched repo, each carrying the workspace-wide summary and
  cross-links. The terminal result lists all of them.
- The intent guard and the ledger are per feature.

## 14. Entry points

The required scope is SPEC, PLAN, EXECUTE, VERIFY, ITERATE, DELIVER, plus debug. The
full cycle preserves that order. Each phase is individually addressable, with its
preconditions checked by the program.

| Entry | Behavior |
|---|---|
| `cycle` | SPEC through DELIVER |
| `spec`, `plan`, `execute`, `verify`, `iterate`, `deliver` | enter or resume the named phase against durable state |
| `debug` | triage and red reproduction, repair, then VERIFY onward |
| `micro` | compact preset for a small change; it cannot remove a required phase from a full cycle |
| `status` | read-only state and outstanding decisions |
| `revise` | PR comments after human review become remediation gaps; EXECUTE onward on the PR branch |

Removal of other 6.9 entry points, phase modes, the teams rung, hooks, and output
styles is subject to the migration inventory in section 17.

## 15. The output stream and the result

The first version called this a verbatim carryover from 6.9, and the second review
found four places where that was inaccurate. This section now says what 7.x keeps,
what it changes, and what the live compatibility checklist has to settle at M1.
The current contract is `docs/loop-spec/agent-output-contract.md` with the phase-line
rules in `skills/shared/report-style.md`.

Kept as in 6.9:

- The machine lines on stdout, one JSON object each: `LOOP_SPEC_PHASE_START` and
  `LOOP_SPEC_PHASE_END` with `attemptId`, `phase`, `elapsedSeconds`, `verdict` in
  `advanced`, `rewind`, `blocked`, `completed`, `next`, and `headSha`;
  `LOOP_SPEC_HANDOFF` when `run` yields between phases; `LOOP_SPEC_RESULT` on exit 0.
  6.9's exception, where the graph's `--step` descriptor occupied stdout and pushed
  the markers to stderr, goes away: in 7.x a step is a file, so stdout carries markers
  only.
- The console line per event on stderr in the `[PHASE] ...` shape, with the same
  precedence as `lib/events.sh` today: `LOOP_SPEC_CONSOLE_STREAM` when set; otherwise
  stdout when Cloud Run's `CLOUD_RUN_JOB` or `K_SERVICE` is present, because Cloud
  Logging grades stderr as errors; otherwise stderr. `LOOP_SPEC_CONSOLE_EVENTS=0`
  silences the console lines without touching the ledger.
- The terminal result's schema 1 shape and every existing field's meaning: `schema`,
  `loopSpecVersion`, `cycleType`, `slug`, `status` in `completed`, `paused`,
  `escalated`, `terminal`, `failed`, `outcome` with its existing values including
  `delivered` and `no-change-needed`, `reason`, `summary`, `noChangeReason`,
  `converged`, `workDelivered`, `verification`, `delivery`, `prUrl`,
  `checkpointPrUrl`, `verifiedSha`, `iterations`, `warnings`, plus the atomic
  `last-result.json` pointer and its stale-result clearing, now in the state home
  (section 12). No existing
  value is renamed and no existing field changes meaning. The 7.x classification is
  a new field, `result`, added beside them:

  | 7.x `result` | existing fields it is written with |
  |---|---|
  | `converged` | `status: completed`, `outcome: delivered`, `converged: true`, `workDelivered: true`, `verification.status: passed`, `delivery` filled |
  | `converged-with-caveats` | 6.9's green draft delivery, unchanged: `status: completed`, `outcome: delivered-draft`, `workDelivered: true`, `converged: false`, `phaseReached: completed`; each outstanding finding listed in `warnings`. `converged` stays false because 6.9 consumers read it as end-to-end convergence, and a draft left for human sign-off is not that |
  | `no-change` | `status: completed`, `outcome: no-change-needed`, `noChangeReason: already-satisfied`, `converged: true`, `workDelivered: false`, `verification.status: passed` |
  | `escalated` | `status: escalated`, `converged: false`, `verification` as observed; a partial draft, when policy allowed one, uses the `delivered-draft` fields above inside `delivery` |
  | `failed` | `status: failed`, `converged: false` |
  | question pending | `status: paused`, `reason` names the question id |

  The rule for the whole table: `converged` is true only for a result 6.9 would also
  have called converged, and the new `result` field carries the 7.x classification
  on its own. The live checklist at M1 covers each row plus partial workspace
  publication, `delivered-unready`, interruption during delivery, delivery blocked,
  and a retried creation, each shown by a recorded live run. The second review's F7
  stays open until every row has been produced live and read back by a 6.9 consumer
  unchanged.
- The chat shape, bound by `output-styles/loop-spec.md`, which is kept and not deleted
  at cutover, because it is the only place that shape binds in Claude Code. Other
  hosts follow the shared report-style contract as today.

Added:

- `LOOP_SPEC_QUESTION` on exit 3, carrying the one-time question id.
- `LOOP_SPEC_RESULT` fields: `rewinds`, `prs` with per-repo identity and state,
  `reviewed` with the evidence level per task, `unreviewed`, `outstanding`,
  `blocked`, `partiallyDelivered`, and the resolved implementation and skill per
  phase and role.

Settled at M1 by the live compatibility checklist: exact stream placement per
line under every environment combination, terminal field meanings for every result
and for interruption, pointer behavior on resume, and the version bump policy for
the schema. Until those runs are recorded, no line in this section is a promise of
byte-for-byte compatibility.

## 16. Packaging

The repo is a Claude Code plugin and an Agent Skills repository at once, because both
read `skills/*/SKILL.md`. `npx skills add <owner>/loop-spec` installs the skill
directories into any of that tool's supported agents, symlinked to one canonical copy
by default. The Claude Code plugin adds what only Claude Code has: the manifest and
the data directory placeholder. 7.x ships no hook (decided 2026-09-22).

- The program ships inside the skill tree so a skills install carries it. The entry
  skills share the program by a relative path. Whether that path survives a per-skill
  symlink install on each agent is a verify item (section 19); if it does not, the
  fallback is one skill `loop-spec` with the entry as its argument.
- A skill body references the program relative to its own directory, never through a
  host variable, since `${CLAUDE_PLUGIN_ROOT}` is empty in Bash tool calls and other
  agents have no equivalent.
- Hooks, agents, output styles, and MCP config are Claude Code plugin surfaces and do
  not travel with a skills install. 7.x depends on none of them for correctness.

## 17. Testing, live gates, and cutover

The implementation contract and the worker runner are the two seams. 7.x tests only its deterministic Python modules, with plain unit tests on the module's own inputs and outputs (parsers, digests, the state writer, the route checks); every cycle-level behavior is shown by live runs. There is no
offline cycle suite, no fake runner, and no pinned host version (decided 2026-09-22).
The 6.9 tests and their 157 s ceiling go with the 6.9 tree. The cycle-level cases are
the live checklist, kept in
`m1-fixtures-7.0.md`: the happy path, a real defect at VERIFY, a review-only rewind,
the self-inflicted regression route, the shared budget, a blocked criterion, a
workspace with two repos, every phase entry and debug, a green checklist with an unmet
original goal, each ITERATE route, stale approval, an external implementation of
EXECUTE, a bound role, invalid execution receipts, and each terminal result. A case is
ticked when a live run has shown it and the run's result and events are recorded.

The live gates run separately in interactive Claude Code and in the Python Agent SDK
supervisor. Each runs the report's own scenario: a repo with pre-existing failures, a
feature that adds passing tests, one real defect caught at VERIFY, one remediation
round, a PR. The maintainer launches them. A headless pass cannot substitute for the
interactive pass. Both hosts must also install and invoke the skills, resolve the
program and the state home, ask and answer and reject and re-approve SPEC decisions in
the lead, preserve the user's model, permission policy, project instructions, hooks,
and MCP access in task worktrees, execute a fresh worker in its assigned worktree and
reject a wrong SHA or an out-of-band branch change, survive an interruption during a
worker, a question, and delivery without duplicate integration or PR creation, and
turn permission denial, malformed output, and budget exhaustion into truthful results
rather than widened permissions or false completion. The `claude -p` entry is checked
live for question policy, background execution, markers, and resumption.

Cutover deletes `extensions/`, `hooks/`, every `lib/*.sh` and the
graph driver, the 6.9 skills, agents, and the 6.9 tests, and rewrites `CLAUDE.md`. The
output style stays (section 15). The live checklist includes one rejection case per
counterexample in the second review: a forged review result at the right path, a
sampled-only verify, a plan with a task nobody implemented, an empty range, a weakened
criterion under an unchanged goal, a PR on the wrong base, a result for a retired
attempt, and a stale question answer. Deletion is conditional on a migration inventory that maps each existing
command, environment override, guard, and harness contract to its replacement or to an
explicitly accepted removal. M0 settles that inventory; M7 cannot remove unmapped
behavior.

## 18. Milestones

| M | Deliverable | Done when |
|---|---|---|
| M0 | this document, the migration inventory, and the route matrix merged on `v7` | DONE 2026-09-22: the re-audit recorded closure at `17707d4` and recommended sign-off (`m0-critique-7.0.md`, committed as `146c1c2`); the maintainer's sign-off is the merge of `v7` work continuing into M1 |
| M1 | state, repo, baseline, events, the implementation contract, the step seam, the external placeholder implementation, host probes | a live empty cycle crosses all seven boundaries; native dispatch, worktree, and receipt probes recorded (the attestation probe is done, see `native-attestation-probe-7.0.md`) |
| M2 | SPEC and PLAN defaults in the lead, `submit`, intent guard, re-approval as a question | a spec change after approval yields exit 3 and an answer re-approves |
| M3 | EXECUTE default: dag, worktrees, implement and review roles, integration against baseline | a live happy path integrates; an unreviewed commit cannot cross the EXECUTE boundary; an external EXECUTE passes its postconditions |
| M4 | VERIFY and ITERATE defaults: acceptance, ledger, delta review, full evidence re-run in a clean checkout, goal judgment, bounded rewinds | the report's four-pass sequence terminates `converged-with-caveats` after two rewinds; a green checklist with an unmet goal rewinds |
| M5 | DELIVER, workspace, result contract, role binding, supervisor example | a two-repo workspace delivers two PRs live; a bound review role runs |
| M6 | live gates | section 17 passes in interactive Claude Code and in the SDK; evidence recorded |
| M7 | cutover | `main` is 7.0.0, `6.x` branch cut, marketplace follows, CHANGELOG written; the README carries exemplar Claude Code use cases, an exemplar Agent SDK implementation, and the one-off Claude Code commands each entry supports; [migrating-6-to-7.md](migrating-6-to-7.md) (a how-to for consumers, first version at M0) is updated with the M1 names |

## 19. To verify before M1

Recorded so the plan does not lean on memory:

- Answered 2026-09-22 on Claude Code 2.1.278, macOS: native Claude Code writes a
  per-dispatch transcript under the session's `subagents/` directory, named by the
  dispatch name the lead chose, whose opening record is the composed prompt verbatim
  and whose last record is the worker's final message. Positive, wrong-opening,
  wrong-result, and forged-id cases behaved as the contract requires. Record:
  `native-attestation-probe-7.0.md`. The native path is the default review runner.
- Whether the Agent tool in Claude Code and in the SDK starts a subagent that can be
  told a working directory and honors it, and whether `isolation: "worktree"` exists
  in the SDK's `AgentDefinition`. It does not appear in the documentation; the program
  creates the worktree itself either way, and `submit` checks where the commit landed.
- Whether a skill directory installed by `npx skills` on each target agent can reach a
  sibling skill's program by relative path, or whether one skill must carry it.
- Whether `${CLAUDE_PLUGIN_DATA}` resolves inside skill content when the plugin is
  loaded through the SDK's `plugins` option, and not only from a marketplace install.
- `ResultMessage.structured_output` on the SDK version the live run records, including missing output on
  success and `error_max_structured_output_retries`; both must fail closed, for the
  SDK runner if it is built.
- Whether `can_use_tool` fires for `AskUserQuestion` inside a session started with
  `plugins=[loop-spec]`, and the `updated_input` shape the tool accepts. The
  supervisor example's shape is the starting point, and its catch-all approval of
  every non-question tool must not survive into the example that ships with 7.0.
- The SDK's minimum Python version, and whether the default `setting_sources` loads
  project settings when `cwd` is a worktree rather than the main clone.
- Native Claude Code must work with the user's existing login on macOS and Linux. SDK
  authentication is separately configured; the 6.9 CLI rung does not prove that SDK
  credential reuse is a supported integration.

## 20. Decisions and audit notes

Decided by the maintainer on 2026-09-21 and 2026-09-22: 7.x drops the opencode, ADK,
and Codex harness trees; the scope is the seven phases above; workspace mode is
redesigned rather than kept compatible; state is not committed; phases are interfaces
with loop-spec owning the boundaries; the default implementation for each phase is
loop-spec's own, ported from 6.9's charters.

Decided on 2026-09-22 from the second review: the requirements revision covers
criteria and decisions, not only goal and boundaries; EXECUTE checks both directions;
VERIFY re-runs every cited command; DELIVER binds PR identity and carries 6.9's
readiness checks; execution evidence is a recorded level and never a file property;
`external` is a changed boundary rather than format-only; the output style is kept.
From the re-audit: unattested review never satisfies the review gate by default;
evidence is compared on parsed identities and normalized output, never raw digests;
re-runs happen in a program-owned clean checkout; retired worktrees are never reused;
the schema 1 result keeps every field and value and gains a `result` field; the
no-change head goes through VERIFY and ITERATE and ends without a PR; feature-added
commands get a task-local baseline at first integration.

Decided from the re-audit follow-up: both runners ship, native Claude Code is an
independent release gate; a draft delivery keeps 6.9's `delivered-draft` fields with
`converged: false`; a non-repeatable evidence exception must be approved in PLAN or
by an operator answer, never self-declared; grace expiry quarantines a retired
worktree and never deletes it.

Decided 2026-09-22 from the migration inventory: no hook ships; `revise` is an entry
that enters EXECUTE in remediation mode from PR comments; the critique gate becomes a
light Critical-only critic on the PLAN product; the six code probes run as program
inputs, at PLAN on the named files, per task before review, and once over the range at
VERIFY; dependency docs are program inputs at PLAN; no configured credential refresh,
but DELIVER checks and attempts the host's own refresh before its first remote write;
no unattended flag, answers carry a `question` or `run` scope; the result pointer
moves to the state home; PR adoption stays in the repo module; greenfield keeps only
init-in-place; issue intake is removed; a security signal is a required review input
with a disposition per signal; `inbox/` is deleted; every proposed removal in the
inventory is accepted.

Decided 2026-09-22 from the M1 fixtures review (`m1-fixtures-7.0.md` DEC-01 to
DEC-06, `m0-critique-7.0.md` M0-01 to M0-04): one shared budget for every backward
transition; one convergence predicate for both converged outcomes with caveats
limited to accepted non-Critical review findings; a Critical critic finding closes
only fixed-and-rechecked or rejected-with-reason; every `blocked` exit pauses and
only a stop answer escalates; D7 is required per repo whose remote write was
attempted; debug and `revise` establish their revisions through a compact SPEC and
PLAN. After the re-audit at `727b2b8`: the budget postcondition (T1) covers PLAN to
SPEC and EXECUTE to PLAN as well; debug's repair runs through EXECUTE with a
`mustFlip` reproduction; `revise` reviews the adopted range as an `adopted` task.

Decided 2026-09-22 on M0's last two items: 7.x tests only its deterministic Python
modules with unit tests; there is no offline cycle suite, no fake runner, and no pinned
host version; the maintainer confirms every cycle-level behavior by live use and
iteration, and the fixtures specification is the live checklist. Supported host versions are therefore not pinned as a gate; each live run
records the Claude Code and SDK versions it ran on, starting with Claude Code 2.1.278
from the attestation probe. The native attestation probe ran the same day and passed.

Nothing is pending for M0.

Audit notes from the review round: the raw report was read after the first
comparison; the report is one observed run and demonstrates failure modes without
measuring competing 7.0 architectures; no live runs were performed in producing this
plan. The live gates establish actual behavior on the host versions each run records.
