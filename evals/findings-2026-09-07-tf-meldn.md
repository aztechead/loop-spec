# Live headless cycle findings, 7 September 2026: tf-meldn

For the maintainer deciding what a real autonomous run on a real repository still costs.
One cycle, not the fixture eval: plugin 6.2.0 at 964a72f, run as
`claude -p "/loop-spec:cycle autonomous …"` from `~/Projects/meldn/tf-meldn` (a
Terragrunt + OpenTofu repository managing live GCP, checked out as a git submodule), with
this checkout as `--plugin-dir`, Opus for the first 65 minutes and Sonnet after the parent
session killed the first process. The ask: bring the repository onto current Terragrunt
and OpenTofu semantics, align it with Google's Cloud Foundation Toolkit and Fabric FAST
principles, validate with `plan` only, and deliver a pull request. Every finding below
names the transcript event or the offline reproduction behind it; the transcripts are
kept with the session that ran it, not committed.

## The run in numbers

| | |
|---|---|
| Wall clock, first launch to PR ready for review | 3 h 22 min (14:54Z to 18:16Z), of which 65 min Opus before the parent session killed it and 2 h 11 min Sonnet |
| Tool calls | 557 (Opus, SPEC through mid-PLAN) + 994 (Sonnet, PLAN resume through DELIVER) |
| Sonnet round cost | USD 48.80 |
| Pull request | aztechead/tf-meldn#1, 32 commits, 38 files, +2842/-76 |
| Live plans at delivery | static-site unit: `No changes.`; bootstrap unit: `1 to import, 0 to add, 0 to change, 0 to destroy` |
| Background `sleep` waits by the lead | Opus 24, Sonnet 11 |

## Headline

The cycle produced work of a quality the fixture eval never sees: a SPEC that refused to
transplant eight empty CFT stages, protected the live state prefix, and chose an `import`
block so a bootstrap unit is verifiable by `plan` alone; a challenger that found a
locking plan writes to the live bucket, that `import` blocks are rejected inside child
modules, and that two parallel tasks would share one unit's Terragrunt cache. It also lost
roughly a third of its tool calls to the plugin, and every one of those losses is a
deterministic defect with an offline reproduction. The fixes are in this change.

## What the plugin cost the run

| # | Where | What happened | Cost | Fix |
|---|---|---|---|---|
| 1 | `begin`, autonomous | The title was the entire 60-word prose; the slug was 400 characters; `git worktree add` failed with "File name too long" on the ref lock | 6 turns; the lead set a title by hand | `git-ops.sh slugify` caps at 60 chars on a word boundary |
| 2 | `start` | `LOOP_SPEC_ANSWER_TITLE` was ignored under the inline `autonomous` token (only the env var was read), so the lead's first recovery did nothing | 2 turns | `cycle-driver.sh start` reads the answers under `$non_interactive` |
| 3 | `init` on a submodule | git created the worktree; Claude Code's `EnterWorktree` refused it ("not a linked worktree of <repo>") because the main worktree lives under the parent's `.git/modules` | 4 turns to tear down and re-init in place | a gitfile checkout works in place with a notice |
| 4 | state commit | The `.gitignore` negations were appended directly under the user's lock-file comment; the PLAN spent a task undoing it | 1 task in the user's PR | `owned-gitignore.sh ensure` writes a delimited block |
| 5 | DISCUSS | The lead hand-edited feature.json (guard denied it, correctly), then guessed `feature-write.sh` syntax three times | 4 turns | the skill names the exact command; the guard's deny text carries the usage |
| 6 | pattern-mapper | The charter cites the template plugin-relative; a subagent has no plugin root, so it ran `find /`, then `find ~/.claude`, gave up, wrote from memory, and the `find` had to be killed later | 6 turns and a runaway process | dispatches carry the template's absolute path; charters say never to search |
| 7 | planner | Neither `agents/planner.md` nor `skills/plan/SKILL.md` names `PLAN.md.template`; the plan came back in the planner's own shape and the artifact lint flagged every task block | a full planner re-dispatch | the brief carries `template_path` and the three labels the lint parses |
| 8 | PLAN exit gate | `acceptance-lint.sh` pegged a core for minutes: the empty-input check `${input//[[:space:]]/}` is superlinear on bash 3.2 (the declared floor) and the tasks file was 17 KB | ~25 turns and ~25 minutes; the lead shortened its own criteria to get under the bug | a regex test; four sibling call sites swept; a 20 KB timing test |
| 9 | every SendMessage join | The lead did not believe "dispatch, then stop" holds under `claude -p` and ran background `sleep` loops, reading their empty output and launching another: 24 by the end of PLAN | the dominant token cost of PLAN | the contract states the headless case as verified fact; `busy-wait-guard.sh` denies a sleep-only Bash call |
| 10 | evidence ledger | EVID-002 recorded the operator's email and the ADC credential path, then SPEC copied it; both were pushed in the checkpoint PR | a privacy leak in a public PR | `evidence.sh add` refuses email addresses and credential paths |
| 11 | resume after the kill | `begin` warned "headless invocation without autonomous mode" (preflight only sees the env var), listed the one resumable feature without picking it (the prose no longer slugified to its slug), and `init` refused the checkout because the plugin's own uncommitted artifacts made it dirty | 5 turns; Sonnet committed the state by hand and called `resume --slug` | the warning is dropped once the token is parsed; one candidate is auto-picked; `.claude/agent-memory/` is not dirt |
| 13 | phase close | Each re-entry of PLAN after an interrupted round appended it again: `completedPhases` read `spec,discuss,plan,plan,plan` | state a later reader cannot trust | `phase-exit.sh close_phase` records a phase once |
| 14 | EXECUTE dispatch | The lead wrote each implementer brief to `/tmp` and called `Agent({prompt: "$(cat /tmp/prompt-task-001.txt)"})`; the Agent tool runs no shell, so both implementers began with a 31-character substitution and recovered only by guessing to `cat` the file | luck | `hooks/team/dispatch-prompt-guard.sh` denies a substitution or sub-40-character prompt |
| 15 | EXECUTE dispatch | A diagnostic `task dispatch` on a still-blocked task created a real worktree the lead then tore down | 3 turns | `execute-step.sh dispatch` refuses a task whose blockers are not done |
| 17 | EXECUTE integrate, VERIFY baseline, DELIVER finalize | Every dispatch and phase-begin rewrites the tracked feature.json, and VERIFY and ITERATE write into the artifact directory; `integrate-task`, `verification-baseline`, and `finalize-delivery-candidate` each read that as user dirt and refused, so the lead hand-committed "state @ execute", "state @ verify", and "state @ deliver" checkpoints four times | 8 turns | `execute-step integrate` commits tracked `.loop-spec` state first; the baseline status read excludes `.loop-spec`; finalize stages feature.json, PROGRESS.md, and the artifact directory in every state-commit mode |
| 16 | EXECUTE review | The review packet named the diff, the brief, and the report but not the task worktree, so a reviewer ran `git worktree add /tmp/review-task-003` for a commit already checked out | 3 turns and a stray worktree | `task package` returns `.worktree`; the reviewer prompt names it |
| 12 | critique gate ceiling | The gate closed with two accepted `[minor]` items unapplied because the round budget ran out | two agreed fixes lost | the protocol applies accepted minors as lead edits before closing |

The structural cause behind rows 7 and 8, and the largest share of PLAN's 92 minutes:
every artifact lint ran only at phase exit, after the author had written the whole
artifact and reported DONE, so each deterministic 20-millisecond check cost a full
lead-to-subagent round trip (six planner round trips for one plan, three of them lint
shape). `hooks/team/artifact-lint-feedback.sh` now runs the matching lint on every
Write or Edit of a cycle artifact and returns the flags to whoever wrote it; the exit
gate remains the backstop. One step further, the plan's structured half is now produced
rather than checked: `lib/plan-render.sh` renders `## Task DAG` and `## Tasks` from
tasks.json, so the shape cannot miss the template and a task fix is one edit (the
planner applied its thirty-six anchoring fixes twice, once per file). The critique
rounds, by contrast, earned their time.

Verified in the same run: Sonnet ran the PLAN gate as a background task, ended its turn,
and the harness resumed it when the task exited. "Dispatch, then stop" holds under
`claude -p`; the Opus busy-waits were avoidable.

## Where the run excelled

- SPEC scout: probed the installed toolchain, `gh release` for current versions,
  `terragrunt backend|hcl|stack --help` for the CLI surface, and ran a baseline
  `terragrunt plan` before touching anything (26 evidence entries by PLAN).
- DISCUSS grill: built throwaway Terragrunt fixtures in `/tmp` to prove `include … expose`
  and `import` + `for_each` semantics on the installed versions before deciding.
- Challenger rounds (SPEC: 3, PLAN: 2): every finding concrete; the lead probed each
  before accepting and recorded the probe as evidence.
- Recovery: every plugin defect above was diagnosed correctly and worked around in a
  few turns, including the submodule worktree and the lint hang.

## Structural cost, fixed on the same branch

The defect table above is about a third of the tool calls. The rest is shape, and the
second pass on this branch removed the deterministic part of it:

| Cost on the run | Fix |
|---|---|
| 11 tasks, 22 subagent seats, most a one-file HCL edit verified by grep | `task-batch.sh` merges a linear chain of local-verify tasks into one dispatch; `execute-step` dispatches the merged task and marks every member done |
| Every seat re-read SPEC, PLAN, PATTERNS, EVIDENCE (about 100 KB) | the brief carries Global constraints, the cited EVID rows, and the environment; the prompt says not to open the artifacts |
| Every seat re-ran `tofu version`, `terragrunt --version`, `gcloud auth list` | `execute-prepare` probes each verify program once into `dispatch/environment.txt` |
| Reviewers re-ran the full verify, including live `terragrunt plan` | the packet names the verify command; the reviewer prompt forbids running it or anything remote |
| No task ran below the lead's model | doc/config-only tasks with a local verify are tiered `mechanical` (haiku on Claude Code) |
| A three-round critique gate on "no apply-capable credentials in CI" | `security-signal.sh` reads an absence boundary as no signal; a negated action still fires |

## Round 4: the same prompt on the fixed plugin

Sonnet again, plugin at d23c268 (the fixes above), tf-meldn `main`, prompt amended by one
sentence because the first relaunch found PR #1 open with the same scope and stopped as a
duplicate (26 turns, correct). The run ended at ITERATE round 2 without delivering.

| | Round 3 | Round 4 |
|---|---|---|
| Wall clock | about 5 h across three relaunches | 1 h 50 min, one process |
| Cost | $48.80 | $39.74 |
| Tool calls (lead / all) | 994 all | 313 / 776 |
| Subagent seats | 22 in EXECUTE alone | 24 total (12 in EXECUTE) |
| PLAN tasks | 7, then 11 | 6 |
| SPEC / DISCUSS / PLAN | long / long / long | 398 s / 669 s / 2512 s |
| EXECUTE | about 2.5 h | 1284 s + a 97 s remediation |
| Implementer tool calls per task | 25 to 40 | 10 to 17, no artifact reads |
| Ending | PR delivered | escalation owed, question asked instead |

What the fixes bought: EXECUTE fell to 21 minutes for six tasks with no rework round; no
implementer opened SPEC, PLAN, PATTERNS, or EVIDENCE; the security-signal absence rule
held (DISCUSS gate ran in single mode); SPEC and PLAN passed their shape lints on the first
write; the busy-wait guard fired once on a `sleep 1`. PLAN is still the dominant phase:
two lint rounds (a grounding-lint false positive and the bare-grep rule on HCL) and three
critique rounds, each a planner round trip.

Defects found in round 4, fixed on this branch:

| # | Defect | Fix |
|---|---|---|
| 18 | ITERATE judged a gap only an operator could close (expired gcloud token), rewound EXECUTE once, judged it again, then the lead asked a question in a headless run | judge `needs_operator`; repeated `fix_first` after a round; route `escalate`; `next` ends the run escalated |
| 19 | VERIFICATION.md marked "terragrunt plan succeeds" PASS with evidence "blocked by the reauth lock" | `BLOCKED` status; the floor refuses PASS whose evidence says the check did not run |
| 20 | `grounding-lint` fed "`cmd` (confirmed: ...)" to `bash -n` | lint the backticked span |
| 21 | `acceptance-lint` flagged `grep -qF 'expose = true' root.hcl` again | whole-line or key = value grep on a declarative file is exempt |
| 22 | environment probe split on `\|` inside quoted patterns and ran `/usr/bin/apply --version` | shlex split; program-shaped names only |
| 23 | `task-batch` treated `terragrunt hcl format` as a real run; quoted pipes stopped merges | local subcommand pairs; shlex split |
| 24 | failed integrate labeled `rebase-conflict` for a dirty-after-verify tree | the label is the reason |
| 25 | pattern-mapper memory committed into the PR to clear a dirty check; code-reviewer denied creating its memory dir | agent-memory excluded from dirt; `memory: project` removed from both agents |
| 26 | lead ignored the packet's `model: haiku` and emitted a second dispatch event | contract: pass `.model`, emit nothing |
| 27 | reviewers sent their verdict over `SendMessage` (3 InputValidationErrors each) | contract: the final message is the result |
| 28 | the operator email landed in SPEC.md again; the lead read the ADC credentials file | `hooks/team/secret-guard.sh` |
| 29 | lead re-ran `init` after `begin` with an empty `$st` | cycle skill: `begin` already initialized |
| 30 | interface conflict rows recorded with the file-overlap rationale | rulings loop names the row kind |

## Not fixed here, worth a look

- The planner still added new uncited claims during a critique revision (round 2 of the
  SPEC gate), and a critique revision still costs a planner round trip each; the gate is
  finding real verify-design defects, so this is latency, not correctness.
- The ITERATE judge is right that a plan-only validation never happened when the token is
  expired; the run now ends escalated with the operator action. A future round could let
  DELIVER open a draft PR carrying the BLOCKED rows so the work is not stranded.

- Two parallel PLAN tasks ran `terragrunt plan` in the same unit and would have shared
  its `.terragrunt-cache/`; `dag-width` only sees declared files. A task-level
  `sharedState` declaration would let it serialize them.
- `acceptance-lint.sh` flagged 37 criteria of the shape `grep -qF 'expose = true'
  terragrunt.hcl exits 0` once it could run. On an infrastructure repository with no
  test suite, a fixed-string match on HCL is often the honest check; the rule was written
  for application code. Each rewrite cost a planner round, and the challenger then
  found three of the rewrites wrong: `grep -w` cannot anchor a target that begins with
  `$` or `"`, so the "anchored" verify could never pass. A per-language exemption (HCL,
  YAML, INI, where `-F` on a whole line is behavioral) is worth a probe.
- Artifact volume: PLAN.md reached 643 lines and 79 KB, SPEC 27 KB, PATTERNS 510 lines
  for a repository of eight source files; every challenger and planner dispatch re-reads
  all of it. The standard profile's known cost, now measured on a real repository.
- `tests/lib/pr-delivery.test.sh` hangs on this machine in its "no gh: final mode" section,
  on `main` as well as on this branch, so `tests/run-all.sh` never finishes here. Every
  other registered suite passes under a per-suite alarm. Worth a probe of what that
  section waits on (a `git push` to a bare origin under a restricted PATH).
- The parent Claude Code session's memory watchdog killed the 65-minute Opus process. A
  long observed run belongs in a plain terminal, not a harness background task
  (`evals/README.md`).
