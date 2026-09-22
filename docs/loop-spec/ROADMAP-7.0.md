# loop-spec 7.0: phases as interfaces

Reader: the maintainer deciding whether to build 7.x, the engineer building it, and
the reviewers asked to break the argument. One job: say what 7.x is, why, and in what
order it gets built. It is a decision document with one reference section (section 4)
that the decision has to be checkable against. It is not a user guide.

Status: favored plan, 2026-09-22, after one external review round. 6.9 stays on
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
  skill someone else ships. Binding is described in section 7.
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
- The postconditions in section 4 and the checks the program runs for them.
- The carried state every implementation receives and must honor: the approved spec
  digest, the baseline, the finding ledger, the rewind count and budget, and the entry
  mode.
- The output stream (section 14): the phase markers on stdout, the phase console lines
  on stderr, the events ledger, the terminal result, and the chat shape. An
  implementation emits its events through the program, so the lines exist because
  the mechanism ran and never because prose asked for them.
- Rewind accounting, the budget, and the terminal results.
- Never overriding a value the host already exposes to the user. Model, permission
  mode, settings sources, and hooks are the user's. Tool availability and permission
  approval are separate; an auto-approve list is never used as a restriction boundary.
  `LOOP_SPEC_MODEL_<ROLE>` stays as the one operator override, unset by default.

## 4. The phase interface

This section is reference. It is the part a reviewer should try to break. The full
contract, with field lists and schemas, becomes its own reference page when the code
lands in M1; this table is the shape it has to have.

Every phase receives the same envelope: the products of prior phases, the carried
state (section 3), and an entry mode of `fresh`, `remediation` with the gaps to close,
or `rewind` with the findings that sent it back. Every phase returns a product and one
named exit outcome from its route list.

| Phase | Product | Preconditions | Postconditions the program checks | Exits |
|---|---|---|---|---|
| SPEC | goal, boundaries, acceptance criteria, decisions, open questions | request text | approval recorded with a digest of goal and boundaries; a later change to either reopens approval as a question to the human | approved, needs answer |
| PLAN | tasks with dependencies, files, repo, verify command; criterion coverage; prepare command | approved SPEC | every criterion is covered by at least one task; every verify command runs at the base SHA from a bare worktree root; baseline captured (section 10) | ready, spec gap |
| EXECUTE | per-task commits and evidence; unresolved issues | PLAN, baseline | feature head is reachable from base; every commit in `base..head` belongs to an accepted task whose review verdict names a SHA covering it; each task's verify command produced no new failure identity against the baseline; no unreviewed commit is marked done | integrated, blocked, plan gap |
| VERIFY | per-criterion verdict with evidence at a SHA; review findings with dispositions; remediation tasks | integrated head | evidence SHA equals the integrated head; every criterion has a verdict; a `blocked` verdict cites a cause the baseline recorded; the program re-runs a sample of cited evidence commands and their status agrees; every finding on cleared code names what it supersedes | passed, implementation gap, plan gap, intent gap, evidence incomplete, blocked |
| ITERATE | goal verdict against the original request; gaps; proposed route | VERIFY passed | verdict names the current SHA and the current spec digest; a gap routes to SPEC, PLAN, or EXECUTE and the rewind counter advances | converged, converged with caveats, rewind, escalated |
| DELIVER | PR targets, delivered SHA, caveats | ITERATE converged | remote head of each touched repo equals the verified SHA; one PR exists per touched repo; a caveats result opens a draft | delivered, delivery blocked |
| debug | failing reproduction, diagnosis, repair, post-fix evidence | error report | the reproduction failed before the repair and passes after; then the VERIFY, ITERATE, and DELIVER postconditions | as VERIFY onward |

The VERIFY row carries the strongest check available from outside an implementation:
the program re-executes cited evidence commands and compares. An implementation that
rubber-stamps gets caught by the spot check, whoever wrote it.

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
  entry mode, the repository or workspace map, the state directory, and the paths the
  implementation may write to.
- `product.json` is the phase product. The program validates it against the schema on
  return and then checks the postconditions.
- Events go through `loop-spec emit`, which appends to the ledger and prints the
  console line. That is how an implementation discharges its observability duty.
- A question for the human is a `question.json` in the state directory and exit
  code 3. The program surfaces it, records the answer, and re-invokes with the answer
  in context.
- A request for the lead to execute something is a `step.json` and exit code 2. This
  is how the default implementation dispatches a worker on hosts where the program
  cannot spawn one itself (section 8). The step names a role, a working directory, a
  prompt, an output schema, and a result file the worker writes.
- Exit 0 means the product is ready. Exit 1 is a program error with the repair
  named. No other exit code advances anything.

The three kinds map onto this contract as follows. The default is a Python entry in
the program's own tree, invoked in-process for speed and exposed through the same
command for parity. A bound implementation is the default with the roles named in the
binding config resolved to other skills; the contract is unchanged. An external
implementation is a placeholder that exits 2 with a step of kind `external`, listing
the postconditions; `submit` with that step id tells the program the phase is done,
and the postconditions decide.

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

## 6. The default implementations

These are what 7.0 builds. They are the reference implementations of section 4, and
the parts of 6.9 worth keeping live here.

SPEC and PLAN run in the lead session, in-context. The spec role interviews with
`AskUserQuestion` natively, exactly as 6.9 does. In Claude Code that reaches the
person. Under the SDK the supervisor's `can_use_tool` answers it by policy, which
`examples/supervisor` already does. The lead submits each product; the program records
the approval digest for SPEC. Both roles may need a human, which is why they run where
questions are cheap.

EXECUTE is program-run. The program resolves the task DAG into waves of at most three,
creates a worktree per task before anything is dispatched, and hands out one step at a
time: implement, then review, for each task. Each worker runs as a fresh context in
its worktree and writes its JSON result to the file the step names. The lead submits
only the step id. The program validates the JSON, checks that the commit is on the
task branch in that worktree and that the feature head has not moved out of band,
runs the task's verify command against the baseline, and integrates by fast-forward.
A rejected step is handed out again with the reason attached, up to a per-step retry
limit, after which the phase exits `blocked`. An out-of-band change to the feature
branch pauses for reconciliation and is never reset automatically.

VERIFY dispatches a verifier and a reviewer as fresh contexts with the ledger as
input. The reviewer sees the full diff on the first pass and on an explicit final
pass, and the delta since the last reviewed SHA otherwise. The verifier is told to try
an offline stand-in before marking a criterion blocked, and may mark it blocked only
for a cause the baseline recorded. Section 9 has the convergence rules.

ITERATE is a fresh goal-judgment role. Its input is the immutable original request,
the approved spec, the integrated diff, the acceptance evidence, and prior gaps. It
judges whether the delivered behavior satisfies the request, including scope the
checklist missed, and routes gaps.

DELIVER is program code: push, one PR per touched repo with the rendered summary,
draft when caveats remain, reconciled against existing remote state before any
external write is retried.

debug keeps the 6.9 loop-debug principles as role input flags: a failing
reproduction before any repair, bounded retries, and a blocker recorded when no
reproduction is available rather than a false pass.

## 7. Roles as bound skills

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

A borrowed skill cannot change the schema, skip the contract, or reach the state. If
it never writes the result file, the retry limit ends the phase as blocked. The damage
a bad method can do is a bad judgment, which is the same risk as a bad default.

## 8. How a worker runs

This was the headline decision in the first draft. Under the interface model it is a
detail of the default EXECUTE and VERIFY implementations, and the
[runner comparison](runner-decision-7.0.md) is the evidence.

The default hands the worker to the lead as a step, and the lead runs it with its
host's own mechanism: the Agent tool in Claude Code and under the SDK, the
equivalent elsewhere. The program owns the worktree, the ordering, the schema, and the
checks on the repository afterward. The lead never carries the payload, because the
worker writes its result to a file the step names, and the file's existence,
timestamp, and step nonce are the execution receipt. This works on every host that
can run a command, edit files, and spawn a fresh context, and it needs nothing beyond
the standard library.

A second runner, in which the program spawns each worker itself through the Python
Agent SDK, holds the working directory and ordering by construction and validates the
schema before the program sees the output. It is Claude only. SDK applications must
use API or provider authentication, and a third party cannot assume a Claude.ai login
carries over, so this runner can never be the interactive default. It can serve an
unattended SDK deployment that has configured its own credentials.

Open decision for the maintainer: the reviewers recommend shipping both runners before
cutover, the native one for interactive Claude Code and the SDK one for unattended
deployments. The alternative is to ship the native runner on both hosts and add the
SDK runner only if the native one fails its SDK live gate (section 16), since a lead
that executes one program-issued step at a time and never carries the payload is not
the 6.9 lead driving a protocol. Both positions agree the runner sits behind one
function, `execute_step(step) -> result`, with the same validator, ledger, retry
limits, and integrator on either side.

## 9. Convergence

- Every review finding is a ledger record: location, cause, severity, the SHA it was
  raised against, and a disposition of `fixed`, `rejected` with reason, or `deferred`
  to the backlog. The ledger is part of the reviewer's input on every pass.
- The first review pass and an explicit final pass see the full diff. Every other pass
  reviews the delta since the last reviewed SHA. A finding on a line a prior pass
  cleared requires a `supersedes` field naming the earlier finding and why it was
  wrong. The schema makes the field required when the location is inside cleared
  ranges, and the ledger keeps reviewed ranges so a cleared line always has something
  to point at.
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
- Rewinds are counted in state, with a budget of two by default and an operator
  override. When a previously passing criterion fails and `git log --diff-filter=A`
  shows the failing test file was added by a remediation commit, the route first
  decides whether the test or the implementation violates the approved behavior.
  Provenance identifies the case and never authorizes weakening an assertion on its
  own. Past the budget, remediation is restricted to minimal diffs and new broad
  assertions are forbidden by the implement role's input flags.
- Four terminal results. `converged`. `converged-with-caveats`: acceptance and ITERATE
  passed, non-Critical findings remain, delivered as a draft PR that lists them.
  `escalated`: the budget is spent with a criterion or a goal gap still open; the
  verified partial state is delivered as a draft PR and the result names what is
  outstanding, with a reason code for the July report's converged-but-undeliverable
  case. `failed`: a program error, or an environment that cannot run the plan. A
  harness reads the result and applies its own policy.

## 10. Baseline and environment

- The baseline is captured once, after PLAN and before EXECUTE, at the base SHA, in a
  throwaway worktree: every verify command the plan declares plus detected repo checks
  from the manifests present. This also proves each plan command runs from a bare
  worktree root, which retires the report's item 9.
- Failures are keyed on test identity. Per-runner parsers for pytest, vitest and jest,
  go test, and cargo test extract file plus test name. A normalized fingerprint, with
  paths, durations, counts, PIDs, and timestamps stripped, is the fallback for unknown
  output. A summary banner that changes because a passing test was added cannot
  register as a regression.
- Environment health is part of the baseline. A command that cannot collect at all is
  recorded once with its error class. The verifier and the integrator read the same
  record, so a pre-existing failure is litigated zero times instead of eight.
- An optional `prepare` command from the repo config runs before the baseline. This is
  the environment-preparation hook the July and September reports both asked for.
- Integration reason codes distinguish `verify-failed`,
  `verify-failed-at-baseline-too`, `already-integrated` (the commit is an ancestor of
  the feature head and is published normally), and `zero-commit`.

## 11. State and artifacts

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
  else `~/.loop-spec/`. Keyed by repository identity and slug. One `state.json` per
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

## 12. Workspace mode

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

## 13. Entry points

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

Removal of other 6.9 entry points, phase modes, the teams rung, hooks, and output
styles is subject to the migration inventory in section 16.

## 14. The output stream and the result

This is carried from 6.9 as it is today and is not negotiable for any implementation.
The full contract is `docs/loop-spec/agent-output-contract.md` and the phase-line
rules in `skills/shared/report-style.md`; this section names what 7.x keeps.

- stdout carries the machine lines, one JSON object each: `LOOP_SPEC_PHASE_START`,
  `LOOP_SPEC_PHASE_END` with `phase`, `attempt`, `elapsedSeconds`, `verdict` in
  `advanced`, `rewind`, `blocked`, `completed`, `next`, and `headSha`;
  `LOOP_SPEC_HANDOFF` when `run` yields between phases; `LOOP_SPEC_QUESTION` on exit
  3; and `LOOP_SPEC_RESULT` on exit 0.
- stderr carries the human console line for every event, in the `[PHASE] ...` shape.
  `LOOP_SPEC_CONSOLE_STREAM=stdout` moves them for hosts that grade the streams
  differently, and `LOOP_SPEC_CONSOLE_EVENTS=0` silences them without touching the
  ledger. Both switches keep their 6.9 meaning.
- `events.jsonl` is the durable ledger and the source of every line above.
- `LOOP_SPEC_RESULT` gains fields: `rewinds`, `elapsedSeconds`, `prs`, `reviewed`,
  `unreviewed`, `outstanding`, `blocked`, and the resolved implementation and skill
  per phase and role.
- The chat shape is the 6.9 output style: name the phase when it changes, one thought
  per action while working, and an outcome-first close. The implementation contract
  discharges the phase lines by mechanism, and the lead writes only what the mechanism
  cannot know.

## 15. Packaging

The repo is a Claude Code plugin and an Agent Skills repository at once, because both
read `skills/*/SKILL.md`. `npx skills add <owner>/loop-spec` installs the skill
directories into any of that tool's supported agents, symlinked to one canonical copy
by default. The Claude Code plugin adds what only Claude Code has: the manifest, one
hook, and the data directory placeholder.

- The program ships inside the skill tree so a skills install carries it. The entry
  skills share the program by a relative path. Whether that path survives a per-skill
  symlink install on each agent is a verify item (section 18); if it does not, the
  fallback is one skill `loop-spec` with the entry as its argument.
- A skill body references the program relative to its own directory, never through a
  host variable, since `${CLAUDE_PLUGIN_ROOT}` is empty in Bash tool calls and other
  agents have no equivalent.
- Hooks, agents, output styles, and MCP config are Claude Code plugin surfaces and do
  not travel with a skills install. 7.x depends on none of them for correctness.

## 16. Testing, live gates, and cutover

The implementation contract and the worker runner are the two seams. The offline suite
replaces the runner with a fake that returns canned role outputs, and drives the whole
cycle against a scratch git repository: the happy path, a real defect at VERIFY, a
review-only rewind, the self-inflicted regression route, the rewind budget, a blocked
criterion, a workspace with two repos, every phase entry and debug, a green checklist
with an unmet original goal, each ITERATE route, stale approval, an external
implementation of EXECUTE, a bound role, invalid execution receipts, and each terminal
result. Baseline parsers get fixture logs per runner. No network, no model. The 157 s
wall-clock ceiling stands.

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
rather than widened permissions or false completion. The `claude -p` entry gets a
smoke test for question policy, background execution, markers, and resumption.

Cutover deletes `extensions/`, `hooks/` except the one kept, every `lib/*.sh` and the
graph driver, the 6.9 skills, agents, output styles, and the 6.9 tests, and rewrites
`CLAUDE.md`. Deletion is conditional on a migration inventory that maps each existing
command, environment override, guard, and harness contract to its replacement or to an
explicitly accepted removal. M0 settles that inventory; M7 cannot remove unmapped
behavior.

## 17. Milestones

| M | Deliverable | Done when |
|---|---|---|
| M0 | this document and the migration inventory merged on `v7` | maintainer sign-off; runner count decided |
| M1 | state, repo, baseline, events, the implementation contract, the step seam, the fake runner, host probes | offline suite drives an empty cycle through all seven boundaries; native dispatch, worktree, and receipt probes recorded |
| M2 | SPEC and PLAN defaults in the lead, `submit`, intent guard, re-approval as a question | a spec change after approval yields exit 3 and an answer re-approves |
| M3 | EXECUTE default: dag, worktrees, implement and review roles, integration against baseline | offline suite passes the happy path; an unreviewed commit cannot cross the EXECUTE boundary; an external EXECUTE passes its postconditions |
| M4 | VERIFY and ITERATE defaults: acceptance, ledger, delta review, spot check, goal judgment, bounded rewinds | the report's four-pass sequence terminates `converged-with-caveats` after two rewinds; a green checklist with an unmet goal rewinds |
| M5 | DELIVER, workspace, result contract, role binding, supervisor example | a two-repo workspace delivers two PRs offline against a local remote; a bound review role runs |
| M6 | live gates | section 16 passes in interactive Claude Code and in the SDK; evidence recorded |
| M7 | cutover | `main` is 7.0.0, `6.x` branch cut, marketplace follows, CHANGELOG written |

## 18. To verify before M1

Recorded so the plan does not lean on memory:

- Whether the Agent tool in Claude Code and in the SDK starts a subagent that can be
  told a working directory and honors it, and whether `isolation: "worktree"` exists
  in the SDK's `AgentDefinition`. It does not appear in the documentation; the program
  creates the worktree itself either way, and `submit` checks where the commit landed.
- Whether a skill directory installed by `npx skills` on each target agent can reach a
  sibling skill's program by relative path, or whether one skill must carry it.
- Whether `${CLAUDE_PLUGIN_DATA}` resolves inside skill content when the plugin is
  loaded through the SDK's `plugins` option, and not only from a marketplace install.
- `ResultMessage.structured_output` on the pinned SDK, including missing output on
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

## 19. Decisions and audit notes

Decided by the maintainer on 2026-09-21 and 2026-09-22: 7.x drops the opencode, ADK,
and Codex harness trees; the scope is the seven phases above; workspace mode is
redesigned rather than kept compatible; state is not committed; phases are interfaces
with loop-spec owning the boundaries; the default implementation for each phase is
loop-spec's own, ported from 6.9's charters.

Pending: the runner count (section 8). Pending for M0: supported host versions and the
migration inventory.

Audit notes from the review round: the raw report was read after the first
comparison; the report is one observed run and demonstrates failure modes without
measuring competing 7.0 architectures; no live runs were performed in producing this
plan. The proposed host gates establish actual behavior on pinned releases.
