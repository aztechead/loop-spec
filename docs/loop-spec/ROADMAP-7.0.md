# loop-spec 7.0: program-owned cycle

Reader: the maintainer deciding whether to build 7.x, and the engineer building it.
One job: say what 7.x is, why, and in what order it gets built. It is not a user
guide; that gets written with the code.

Status: proposal, 2026-09-21. 6.9 stays on `main` and keeps receiving fixes until
7.0 passes its live gate (M6). At that point `main` becomes 7, a `6.x` branch is cut
for maintenance, and the marketplace entry follows `main`.

## 1. Why a new line

The 2026-09-21 Cloud Run report (`LOOP_SPEC_IMPROVEMENTS-2026-09-21 2.txt`, headless
Agent SDK, one session per phase) ran 6.9.0 for 2h56m, 9 sessions, 699 tool calls,
4 VERIFY to EXECUTE rewinds, and never converged. The harness killed it and opened
the PR itself with a failure status. The implementation was good and every gate
caught a real defect. The run still failed.

Two causes, both structural:

- **The two VERIFY gates never passed on the same pass.** Each pass spawned a fresh
  reviewer over the whole cumulative diff with no record of what earlier passes had
  cleared. Pass 8 returned PASS with zero findings; pass 10, on a diff that changed
  by one test line, returned BLOCK on a query shape written in the first wave and
  already cleared. Acceptance and review took turns failing. The run ended with 17 of
  17 criteria passing and two Important findings open, and the only signal was
  "non-converged".
- **The model drives a deterministic protocol.** Skill prose names 139 distinct
  scripts. The lead must know each one's path, flag grammar, JSON shape, markdown
  format, and call order. Twelve of the report's eighteen items are the lead getting
  one of those wrong: worktree not created before dispatch so two commits merged
  unreviewed while state said reviewed; remediation JSON rejected wholesale for a
  field no usage text names; a markdown linter tripping on findings from a superseded
  pass; a re-approval path reachable only by importing a private module; a baseline
  that exists but that the integrator cannot see.

Every prior fix round (PRs #93, #100, #106, #108) added a guard, alias, lint, or
usage string for the model to misuse next. Items 5 and 6 were first raised on
2026-07-27 and are still open, because the fix needs one baseline object shared by
many scripts and nothing owns state. That is the impasse, and it is why this is a
new line rather than a fix release.

What the report says to preserve, and 7.x keeps: fresh context per phase; gates that
catch real defects; the verifier's instinct to build an offline stand-in for a
credential-blocked criterion and mutation-check it; the approved-SPEC intent guard;
the machine-readable `LOOP_SPEC_PHASE_END` and `LOOP_SPEC_HANDOFF` lines.

## 2. Principles

1. **The program owns everything deterministic.** Worktrees, baseline, integration,
   rewinds, state, artifacts, markers, delivery. The model never calls a helper to do
   any of these. If the model can skip a step, the step is in the wrong place.
2. **The model does judgment only**, through a small number of roles, each with a
   prompt, an input, and an output schema.
3. **One code path for every host.** Claude Code and the Agent SDK are the same
   runtime and the first-class targets. The only difference between them is who
   answers a question: a person or a policy. Other agents get the same skill and
   program through a skills install; nothing in the tree is per harness.
4. **Never override a value the host already exposes to the user.** Model, permission
   mode, settings sources, and hooks are the user's. The program passes per-call
   options the SDK exposes for exactly that purpose (`cwd`, `allowed_tools`,
   `output_format`) and reads the user's settings through `setting_sources` as the
   SDK loads them by default. `LOOP_SPEC_MODEL_<ROLE>` stays as the one operator
   override, unset by default.
5. **Fresh context needs a carried ledger.** A fresh reviewer with no memory is a
   lottery. Every role gets exactly the state it needs as input, and nothing else.

## 3. Architecture

```
 host (Claude Code or Agent SDK)
 └── lead session                       runs the skill: SPEC and PLAN in-context,
     │                                  then loops on `loop-spec run`, executes
     │                                  each step it hands out, relays questions
     └── loop-spec program (Python)     one state file per feature, one writer
         ├── repo       worktrees, base SHA, ff-only integrate, ancestor checks
         ├── baseline   check commands at base SHA, failure identities, env health
         ├── dag        tasks, waves, per-task implement -> verify -> review -> integrate
         ├── ledger     findings with SHA and disposition; acceptance evidence by SHA
         ├── rewind     counter, budget, self-inflicted detection
         ├── render     state -> SPEC.md / PLAN.md / VERIFICATION.md / PR body
         ├── deliver    push, PR, draft when caveats
         ├── events     JSONL + marker lines
         └── steps      hand out one step; validate its result against the schema
             │          and verify the world before accepting it
             └── roles/  implement.md  review.md  verify.md  (+ spec.md, plan.md for the lead)
```

**Four verbs.** `loop-spec run <feature>` does every deterministic step that is ready
(baseline, integration, rendering, delivery) and then exits: code 2 with one step for
the lead to execute, code 3 with a question for the human, code 0 with a terminal
result, code 1 on a program error with the repair named. `loop-spec submit <feature>
<step-id> <json>` hands back a step's result; the program validates it against the
step's schema and verifies the world (section 4) before accepting it. `loop-spec
answer <feature> <json>` records a human reply. `loop-spec status <feature>` prints
where things stand. Nothing else is exposed to the model.

**Roles that may ask the human run in the lead; roles that never ask run spawned.**
SPEC and PLAN run in the lead session, in-context, and call `AskUserQuestion`
natively, exactly as 6.9 does. In Claude Code that reaches the person; under the SDK
the supervisor's `can_use_tool` answers it by policy, which `examples/supervisor` already
does. The lead submits each artifact; the program validates it against the schema
and records the approval digest. Implement, review, and verify are steps the program
hands out with a working directory, an allow-list, and an output schema, executed as
fresh contexts (section 4), and they never ask. When a spawned role hits an intent gap, `run` exits with the question and the
lead asks it. That round trip is rare by construction, which is why SPEC stays in the
lead where questions are common.

**The skill is the loop.** About thirty lines. Call `run` in the background. On
exit 2, execute the step: SPEC and PLAN in-context, any other role as a fresh
context in the working directory the step names, and `submit` the result. On exit 3
ask the question and `answer`. On exit 0 report the terminal result. Presets
(section 9) are a list of which roles run.

**Hooks go to near zero.** Worker scoping comes from the step the program hands out. The 73 hook
files in 6.9 exist to stop the lead misusing a protocol it no longer drives. One
`SessionStart` hook may remain to print the plugin's version and preflight result.

**Markers stay and gain fields.** `LOOP_SPEC_PHASE_END` and `LOOP_SPEC_HANDOFF` are
printed by the program, so they can carry rewind count, elapsed total, outstanding
findings, and the reviewed and unreviewed task lists for free. `run` is resumable from
state, so a harness that prefers one host session per phase still can.

## 4. The runner: who executes a step

The program always decides the sequence. The open question is who executes each
step. Three options, on a spectrum from prose to program.

**Option P: prose with phase checks.** The lead follows the skill prose through each
phase; a check at each phase exit says what it missed. This is 6.9 with fewer,
lighter checks. It is rejected on the report's evidence: the expensive failures were
not a model misreading prose but a fresh session lacking information a prior session
had (which worktrees exist, what a reviewer already cleared, what the baseline
found). No model quality fixes an information gap, and every check that closes one
needs structured state, at which point it is the program. Kept only as the argument
for why the other two exist.

**Option N: program sequences, lead executes each step natively.** `run` returns one
step: a role, a prompt, a working directory, and an output schema. The lead executes
it with its host's own mechanism (the Agent tool in Claude Code and the SDK; the
equivalent elsewhere) and passes the result to `submit`. `submit` validates the JSON
against the schema and verifies the world: for an implement step, the commit is on
the task branch in the task worktree and the feature branch head has not moved;
for a review step, the verdict names the SHA it reviewed. A step that fails either
check is rejected with the exact reason, and `run` returns it again with the reason
attached. `run` will not return the next step until the current one is accepted.

- Works on every harness that can run a command, edit files, and spawn a fresh
  context. Distributed as a skill, that is the multi-harness story with one code
  base and no per-harness tree.
- No dependency beyond the standard library. The 6.9 runtime rule holds.
- Roles appear as subagents in the interactive session and share its accounting.
- The guarantee is by inspection, not by construction. A subagent that ignores its
  working directory wastes one session before `submit` rejects it, and the program
  must own the feature branch head so out-of-band edits are detected and reset.
  Nothing unreviewed can be marked done, and state cannot claim a review that did
  not happen, which is the property the report's critical item actually needs.
- The "you missed X" the maintainer wants exists, at the one place it matters:
  `submit` rejecting a step with the reason, and the schema naming every required
  field before the role runs.

**Option S: program sequences and executes through the Python Agent SDK.** `run`
awaits `claude_agent_sdk.query(prompt, ClaudeAgentOptions(cwd=worktree,
allowed_tools=[...], output_format={"type": "json_schema", "schema": ...}))` for each
role itself.

- Worktree, working directory, and ordering hold by construction; the schema is
  enforced before the program sees the output. The strongest guarantee available.
- Claude only. Another harness needs its own `run_role` implementation. The SDK
  becomes a hard dependency; the plugin can install it into its own data directory
  (section 5), so the user is not asked to.
- The interactive lead sees the program's progress lines rather than the role's tool
  calls.

**Recommendation: N, with S as the reserve.** The multi-harness requirement decides
it. N keeps every program-owned property (state, sequence, baseline, ledger,
rewinds, delivery) and bounds the cost of a disobedient subagent to one wasted
session, on any harness, with no dependency. The runner is one function either way,
`execute_step(step) -> result`, so if a live run shows inspection is not enough on
Claude, S is added behind that function for Claude without touching the rest.

## 5. State and artifacts

Run state leaves the branch. The report's reviewer saw a 512-line `feature.json`
ahead of the source files and the harness had to strip it at delivery. 6.9 already
has a `refs/loop-spec/state/<slug>` convention, but `docs/loop-spec/features/` is
still committed, so both happen.

What comparable tools do, checked 2026-09-21: spec-kit (`.specify/`, `specs/`),
OpenSpec (`openspec/changes/`, archived by date), BMAD (`docs/`), and ccpm
(`.claude/epics/`) all commit specs and plans as markdown in a tool-named directory
of the user's repo. None has a consistent home for run state: spec-kit ignores its
cache directories, ccpm keeps live status in GitHub Issues, BMAD uses a plain
markdown file, superpowers names nothing. Claude Code itself documents a per-plugin
data directory, `${CLAUDE_PLUGIN_DATA}`, resolving to `~/.claude/plugins/data/<id>/`,
created on first reference, kept across plugin updates, removed on uninstall, and
intended for "Python dependencies" and state that should survive updates. The
placeholder resolves inline in skill content; it is not an environment variable
inside Bash tool calls.

Decision for 7.x:

- **State home** is outside the work tree: `${CLAUDE_PLUGIN_DATA}` when the plugin
  is installed in Claude Code and the skill passes the resolved path to the program,
  else `$LOOP_SPEC_HOME`, else `~/.loop-spec/`. Keyed by repository identity and
  slug. One `state.json` per feature, one writer, plus `events.jsonl`, worktrees,
  and the rendered artifacts. The same directory holds anything the program
  installs for itself, which is what the host documents it for.
- **Nothing is committed to the consumer repo by default.** The PR body carries the
  rendered summary: spec goal and boundaries, acceptance table with evidence, the
  finding ledger, outstanding findings, rewind count. A consumer that wants the
  rendered SPEC and VERIFICATION docs in-tree sets `commitArtifacts` in the repo
  config, and they land in one commit the review package excludes by pathspec.
- **Resumption across clones** is a seam, not a feature: `loop-spec state push|pull`
  onto `refs/loop-spec/state/<slug>` for harnesses whose clone does not outlive the
  run. The report's harness keeps its clone for the whole job, so it is not built
  until a harness needs it.
- **No other host directory is written to.** Not `.claude/` in the project, not
  the projects directory, not the plugin cache. The data directory is the one the
  host offers for this; everything else is the host's.

## 6. Convergence: ledger, delta review, terminal results

- **Finding ledger.** Every review finding is a state record: location, cause,
  severity, the SHA it was raised against, and a disposition of `fixed`, `rejected`
  with reason, or `deferred` to the backlog. It is part of the reviewer's input on
  every pass.
- **Delta review by default.** The first review pass and an explicit final pass see
  the full diff. Every other pass reviews the delta since the last reviewed SHA. A
  finding on a line a prior pass cleared requires a `supersedes` field naming the
  earlier finding and why it was wrong; the schema makes the field required when
  the location is inside cleared ranges.
- **Severity on re-review.** On any pass after the first, only Critical blocks.
  Important on already-cleared code is deferred to the backlog with the ledger entry
  kept.
- **Acceptance evidence keyed by SHA.** A criterion whose evidence command output is
  unchanged at the new head keeps its verdict; only criteria whose evidence changed
  or whose files were touched re-run. Both gates are evaluated at the same SHA, and
  converged means both passed at that SHA.
- **Four terminal results.** `converged`. `converged-with-caveats`: acceptance
  passed, non-Critical findings remain, delivered as a draft PR listing them.
  `escalated`: the rewind budget is spent with a criterion still failing; the
  verified partial state is delivered as a draft PR and the terminal result names
  what is outstanding. `failed`: a program error or an environment that cannot run
  the plan. A harness reads the result and applies its own policy; the July report's
  "converged but undeliverable" case gets its own reason code under `escalated`.

## 7. Baseline and environment

- **Captured once, after PLAN, before EXECUTE**, at the base SHA, in a throwaway
  worktree: every verify command the plan declares plus detected repo checks (lint,
  typecheck, test, build from the manifest files present). This also proves each
  plan command runs from a bare worktree root, which retires the report's item 9.
- **Failure identity, not stack text.** Per-runner parsers for pytest, vitest and
  jest, go test, and cargo test extract file plus test name. A normalized fingerprint
  (paths, durations, counts, PIDs, timestamps stripped) is the fallback for unknown
  output. A summary banner that changes because a passing test was added cannot
  register as a regression.
- **Environment health is part of the baseline.** A command that cannot collect at
  all is recorded once with its error class. The verifier receives that record and
  may mark a criterion `blocked` only for a cause the baseline recorded; the role
  prompt tells it to try an offline stand-in first, which is the behaviour the report
  asked to preserve. The integrator reads the same record, so a pre-existing failure
  is litigated zero times instead of eight.
- **Prepare step.** An optional `prepare` command from the repo config runs before
  the baseline. This is the environment-preparation hook the July and September
  reports both asked for.
- **Integration compares against the baseline.** A task publishes when its verify
  command produces no new failure identity. The reason codes distinguish
  `verify-failed`, `verify-failed-at-baseline-too`, `already-integrated` (the commit
  is an ancestor of the feature head, published normally), and `zero-commit`.

## 8. Rewinds

- Counter in state, budget default 2, operator override by env.
- **Self-inflicted detection.** When a previously passing criterion fails and
  `git log --diff-filter=A` shows the failing test file was added by a remediation
  commit, the route is `narrow-test` with a minimal-diff instruction, not a full
  EXECUTE round.
- Past the budget, remediation is restricted to minimal diffs and new broad
  assertions are forbidden by the implement role's input flags. At exhaustion the
  result is `escalated` or `converged-with-caveats` (section 6), never another loop.

## 9. Entry points

Four skills, each a preset naming which roles run and with what flags:

| Skill | Roles | Notes |
|---|---|---|
| `cycle` | spec, plan, implement, review, verify, deliver | the full loop |
| `micro` | implement, review, verify, deliver | small change; the task description is the spec, one task, one criterion per stated behaviour |
| `debug` | implement (red repro first), review, verify, deliver | the 6.9 loop-debug principles as role input flags |
| `status` | none | prints state |

Dropped from 6.9: revise, onboard, intake, iterate as a separate surface, the route
judge, DISCUSS, phase modes, the teams rung, the harness probes, and `surface.sh`
(there is nothing left to discover).

## 10. Workspace mode, redesigned

Kept as a capability, rebuilt in the repo module rather than as a mode every script
re-detects.

- A workspace is a root with a `.loop-spec/workspace.json` naming repos, or a root
  whose children are git repositories, as in 6.9. The program resolves it once at
  `submit plan` and stores the resolved repo list in state.
- Every repo-scoped thing is per repo in state: base SHA, feature branch, worktree
  root, baseline, and delivery target. A task names its repo; its worktree, verify
  command, and integration run in that repo.
- The DAG is workspace-wide, so a wave may run tasks in different repos in parallel.
- Delivery opens one PR per touched repo, each carrying the workspace-wide summary
  and cross-links. The terminal result lists all of them.
- The intent guard and the ledger are per feature, not per repo.

## 10a. Packaging: one repo, two distribution shapes

The repo is a Claude Code plugin and an Agent Skills repository at once, because
both read `skills/*/SKILL.md`. `npx skills add <owner>/loop-spec` (vercel-labs/skills)
installs the skill directories into any of its supported agents, symlinked to one
canonical copy by default. The Claude Code plugin adds what only Claude Code has: the
manifest, the one hook, and the data directory placeholder.

- The program ships inside the skill tree so a skills install carries it. The
  presets are one skill each and share the program by a relative path; whether
  that path survives a per-skill symlink install on each agent is a verify item
  (section 15). If it does not, the fallback is one skill `loop-spec` with the
  preset as its argument.
- A skill body references the program relative to its own directory, never through
  a host variable, since `${CLAUDE_PLUGIN_ROOT}` is empty in Bash tool calls and other
  agents have no equivalent.
- Hooks, agents, output styles, and MCP config are Claude Code plugin surfaces and
  do not travel with a skills install. 7.x depends on none of them for correctness.

## 11. Result contract for harnesses

Stable stdout lines, one JSON object each, and the same objects in `events.jsonl`:

- `LOOP_SPEC_PHASE_END {phase, attempt, elapsedSeconds, verdict, next, headSha}`
- `LOOP_SPEC_HANDOFF {next}` when `run` yields between phases
- `LOOP_SPEC_QUESTION {id, header, question, options}` on exit 3
- `LOOP_SPEC_RESULT {result, reason, rewinds, elapsedSeconds, prs: [...],
  reviewed: [...], unreviewed: [...], outstanding: [...], blocked: [...]}` on exit 0

## 12. Testing

The runner is the one seam. The offline suite replaces it with a fake that returns
canned role outputs and drives the whole cycle against a scratch git repository:
happy path, a real defect at VERIFY, a review-only rewind, the self-inflicted
regression route, the rewind budget, a blocked criterion, workspace with two repos,
and each terminal result. Baseline parsers get fixture logs per runner. No network,
no model. The 157 s wall-clock ceiling stands. The 6.9 suite goes with the 6.9 tree
at cutover.

The parity gate is the report's own scenario, run live on the maintainer's harness:
a repo with pre-existing failures, a feature that adds passing tests, one real defect
caught at VERIFY, one remediation round, a PR. That run is launched by the
maintainer, not by the test suite.

## 13. The 7.x tree

```
.claude-plugin/plugin.json           version 7.0.0, skills, one hook
skills/loop-spec/program/            the program (stdlib only; SDK runner optional)
  __main__.py  state.py  repo.py  baseline.py  dag.py  ledger.py  rewind.py
  render.py  deliver.py  events.py  steps.py  schemas/  roles/
skills/cycle|micro|debug|status/     each a short SKILL.md
docs/loop-spec/                      architecture, configuration, harness contract
tests/                               pytest over the fake runner + fixture logs
examples/supervisor/                 updated to the new result contract
```

Deleted at cutover: `extensions/`, `hooks/` except the one kept, every `lib/*.sh`
and the graph driver, the 6.9 skills, agents, output-styles, and the 6.9 tests.
`CLAUDE.md` is rewritten for the new tree.

## 14. Milestones

| M | Deliverable | Done when |
|---|---|---|
| M0 | this document merged on `v7` | maintainer sign-off |
| M1 | state, repo, baseline, events, runner seam, fake runner, test harness | offline suite drives an empty cycle end to end |
| M2 | SPEC and PLAN in the lead, `submit`, intent guard, re-approval as a question | a spec change after approval yields exit 3 and an answer re-approves |
| M3 | EXECUTE: dag, worktrees, implement and review roles, integration against baseline | fake-runner suite passes the happy path and the unreviewed-commit case is impossible by construction |
| M4 | VERIFY: verify role, ledger, delta review, rewinds, terminal results | suite passes the report's four-pass sequence and ends `converged-with-caveats` after 2 rewinds |
| M5 | DELIVER, workspace, result contract, supervisor example | two-repo workspace delivers two PRs offline against a local remote |
| M6 | live gate | the report's scenario converges on the maintainer's harness with a PR |
| M7 | cutover | `main` is 7.0.0, `6.x` branch cut, marketplace follows, CHANGELOG written |

## 15. To verify before M1

Recorded so the plan does not lean on memory:

- Whether the Agent tool in Claude Code and in the SDK returns the subagent's final
  message intact enough to carry a JSON object, and whether `isolation: "worktree"`
  exists in the SDK's `AgentDefinition` (it does not appear in the doc; the program
  creates the worktree itself either way).
- Whether a skill directory installed by `npx skills` on each target agent can reach
  a sibling skill's program by relative path, or whether one skill must carry it.
- Whether `${CLAUDE_PLUGIN_DATA}` resolves inside skill content when the plugin is
  loaded through the SDK's `plugins` option, not only from a marketplace install.

- The `ResultMessage` field that carries structured output when `output_format` is
  set, and what the SDK does when the model's output fails the schema.
- Whether `can_use_tool` fires for `AskUserQuestion` inside a session started with
  `plugins=[loop-spec]`, and what `updated_input` shape the tool accepts (the
  supervisor example's shape is the starting point).
- The SDK's minimum Python version and whether `setting_sources` default loads the
  user's project settings when `cwd` is a worktree rather than the main clone.
- Whether a spawned session inherits the interactive session's authentication under
  Claude Code on macOS and Linux, which the 6.9 session rung suggests it does.
