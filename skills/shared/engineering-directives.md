# Engineering directives — canonical index

Reader: an agent about to write, plan, or review code under loop-spec (implementer,
planner, code-reviewer, or the main thread), and the maintainer editing a dispatch prompt.
This is the one file every code-producing dispatch names. It does not restate the
contracts it indexes; each row says when the directive fires, what you do, what artifact
proves it, and which probe checks it. Enforced by `tests/engineering-directives-coverage.test.sh`.

The four quality contracts stay where they are: `laziness-ladder.md` (how much code),
`design-for-change.md` (where the boundaries sit), `human-code.md` (how it reads),
`writing-good-tests.md` (what a test is for). This file adds the directives that had no
home — version lookup, idiom, scale-before-code, test scope, phase handoff — and binds the
set in one place so a new rung copies from here.

## Code directives

Read `skills/shared/approach-selection.md` before planning, implementing, or reviewing
a requested method. It binds the EXECUTE and VERIFY paths below: improve internal
choices from evidence, preserve explicit constraints, and escalate changes to settled
design or task boundaries through the existing phase path.

| Fires when | Do | Artifact | Probe |
|---|---|---|---|
| You are about to write a line | Read the neighbors first; the surrounding code is the style guide (`human-code.md` §1). Where the repo has an analog, mirror it (`PATTERNS.md`). | The diff looks like the file it lands in | `lib/house-style.sh compare` |
| Two solutions both work | Take the one the next reader decodes without a comment. Clever is a construct that needs an explanation; simple is the construct the language documents for this job. | No `simplicity:` marker needed | `lib/indirection-scan.sh scan` |
| You reach for a comment | Say why, never what: the constraint, the decision and the alternative it beat, the landmine (`human-code.md` §2–§4). A name that states intent deletes the comment. | Comments the file's density allows, spent on why | `lib/comment-tells.sh scan` |
| You use a language feature or library call | Use the idiom the language's current documentation recommends for the version the repo pins (the manifest, lockfile, `.tool-versions`, CI matrix). An older idiom the neighbors use outranks a newer one you prefer; note the newer one in the report. | The construct a maintainer of that language expects | `lib/house-style.sh compare` |
| You are unsure how a dependency the file imports does something | Fetch the dependency's current documentation before writing the call: any web search or URL-fetch tool the session provides, `curl -s <url>` through Bash as the floor. Model memory of a fast-moving framework is a hypothesis; the current docs are the fact (`skills/shared/grounding-protocol.md`, "Current documentation"). | The doc-backed idiom in the diff; in design phases, an `EVID-NNN` ledger cite | `lib/doc-deps.sh gate` (PLAN exit) |
| You name a language, runtime, or package version | Ask a tool, never recall: the repo's manifest first, then the package manager (`npm view <pkg> version`, `pip index versions <pkg>`, `cargo search <crate>`, `go list -m -versions <mod>`, `gem info <gem>`), then any web or registry tool the harness offers. Check advisories the same way (`npm audit`, `pip-audit`, `cargo audit`, `govulncheck`, `gh api /advisories`). Model knowledge is a hypothesis; the tool's answer is the fact. | One line in the report per version chosen: `version: <name>@<v> source: <command or URL>`; `unverified` when no tool answered, pinned to what the repo already uses | `lib/grounding-lint.sh` (an unverified version is an `ASSUMPTION ... \| verify:` line) |
| You add a boundary, helper, or second implementation | Design to an interface; one unit, one reason to change; receive collaborators (`design-for-change.md`). Then the four questions (`implementer-contract.md`). | A seam the next change can use | — |
| The change has an input the deployment controls | Name it (rows, files, events, concurrent callers) and bound memory and work against it before writing the code, not after the test passes (`implementer-contract.md` Q4). | The bound stated in the task report | — |

## Test directives

| Fires when | Do | Artifact | Probe |
|---|---|---|---|
| A task produces code | Write the failing test first, run it, confirm red, then the minimal green (`writing-good-tests.md` TDD). Skill, config, and docs tasks are excluded; a missing TDD label does not exempt a code task. | Red output, then green output, in the report | — |
| You write a test | One test, one break. Name the production change that fails it. Use the smallest input that exercises that break and set up only the state that break needs. A test that needs unrelated state is testing scope it does not own — split it. Size the file like its neighbors. | A test whose name is the break it catches | `lib/test-tamper-scan.sh` (deleted or skipped tests) |
| A test would assert on source text | Run the artifact and assert its effects instead (`writing-good-tests.md` gate). The one carve-out is a `tests/*-coverage.test.sh` coupling pin. | Exit code, stdout, or a file the artifact wrote | — |

## Plan directives (PLAN phase, `agents/planner.md`)

| Fires when | Do | Artifact |
|---|---|---|
| You shape a task | Design for scale before code exists: name the scaling input and the bound the implementer must hold, in the task's steps. A task with no stated bound gets one or says `scale: none (fixed-size input)`. | The task block in `PLAN.md` |
| A task touches a stack choice | Name the version source the implementer must consult; never pin a version from recall. | `ASSUMPTION ... \| verify: <command>` or an `EVID-NNN` cite |

## Phase handoff directives (the cycle)

| Fires when | Do | Artifact | Probe |
|---|---|---|---|
| A phase starts or resumes | Read the entry packet and nothing else: `bash lib/phase-entry.sh <phase> --feature-dir DIR` lists the exact fields and files this phase consumes. Do not re-read `feature.json` whole, re-scan the tree, or re-derive what a prior phase already wrote. | The packet's `read=` list is the phase's whole ingress | `lib/phase-entry.sh` (`FLAG` on a missing ingress artifact) |
| A phase ends | Write only the egress artifacts the next phase's packet names, then close with `bash lib/phase-exit.sh <phase> --feature-dir DIR`. Never set `currentPhase`; the driver owns it. | `artifacts.*` pointers and the commit | `lib/phase-exit.sh` (`FLAG` per missing gate; `WARN [egress]` per `feature.json` key changed outside the phase's allow-list, a `FLAG` under `LOOP_SPEC_EGRESS_GUARD=deny`) |
| The driver answers `HANDOFF next=<p>` | Print the line and stop. The fresh session runs `phase-entry.sh <p>` first; nothing from this session's context is needed. | The `LOOP_SPEC_PHASE_HANDOFF` line | `hooks/team/phase-handoff-guard.sh` |
| The cycle starts | `cycle-driver.sh start` is the whole preflight. Print its notices and warnings, resolve its decisions, nothing else. | The `start` JSON | `lib/feature-init.sh validate` (selector routing, fork-free) |

## Stance directives

A stance is a mindset with a deliverable list attached; `skills/shared/engineering-stances.md`
is the single source for the five (build from scratch, system design, refactor, debug,
performance) and names the artifact section each one fills. A stance never selects a
route or a phase.

| Fires when | Do | Artifact |
|---|---|---|
| The phase matches a stance's "fires when" column | Hold the mindset and write every deliverable in that row; a deliverable that does not apply gets `- none` with a reason. | The named section in SPEC.md, PLAN.md, VERIFICATION.md, or BUG.md |

## Canonical compact directive

A dispatch prompt that is the executor's whole contract (the subagent, loop-fleet, and
Workflow rungs) carries the one `ENGINEERING CONTRACT` block; its canonical copy is the
stanza in `skills/shared/execute-subagent.md`, and `lib/plan-to-loop.sh` and
`lib/workflows/execute-dag.js` render the same text with their own path resolution. A
surface whose reader already holds the implementer charter (the team prompt, the
SessionStart hook) inlines only this paragraph:

> ENGINEERING DIRECTIVES (on by default). Read
> `skills/shared/engineering-directives.md` — do not paste it. Simple over clever: the
> construct the next reader decodes without a comment. Idiomatic for the version the repo
> pins. Versions come from a tool (manifest, package manager, registry, advisory check),
> never from recall; report `version: <name>@<v> source: <command>` or `unverified`. Name
> the scaling input before writing code. Tests first; one test, one break, smallest input.

## Where it binds

| Surface | File |
|---|---|
| Subagent rung (both prompt templates) | `skills/shared/execute-subagent.md` |
| Team rung | `skills/shared/team-prompts/implementer.md`, `agents/implementer.md` |
| Loop-fleet rung | `lib/plan-to-loop.sh` |
| Workflow rung | `lib/workflows/execute-dag.js` |
| Inline rung (lead as implementer) | `skills/shared/execute-rungs.md`, `skills/execute/SKILL.md` |
| PLAN | `agents/planner.md` |
| VERIFY | `agents/code-reviewer.md` |
| Main thread (Claude Code SessionStart) | `hooks/team/human-code-inject.sh` |
| Index of every code-producing directive | `skills/shared/implementer-contract.md` |
| The five stances and where each binds | `skills/shared/engineering-stances.md` |
