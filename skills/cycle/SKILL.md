---
name: cycle
description: "ENTRY POINT for loop-spec. Give it a feature description OR a path to a pre-authored spec .md file. Runs SPEC -> DISCUSS -> PLAN -> EXECUTE -> VERIFY -> ITERATE -> DELIVER; resumes incomplete features automatically. Do not use for a pasted stack trace (that's /loop-spec:debug) or a one-file ad-hoc fix (that's /loop-spec:micro)."
argument-hint: "[new] [feature description | path/to/spec.md | backlog]  (optional inline overrides: style:auto|step|interactive|review-only, autonomous, profile:compact|maintenance|standard, phase:fresh|continuous)"
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet EnterWorktree ExitWorktree ToolSearch Workflow
---

# loop-spec:cycle

You are the lead. `lib/cycle-driver.sh` owns every mechanical step of the loop and
answers each call with one JSON object or one line. Your job is the parts that need a
harness tool or a human: answer questions, enter and leave the worktree, dispatch
mapper agents, and invoke each phase skill when the driver names it. Do not
re-derive state, re-scan directories, or narrate the preflight.

```bash
DRV="${CLAUDE_SKILL_DIR}/../../lib/cycle-driver.sh"
```

Tools this skill and its phase skills may use: the list in the frontmatter. `WebFetch`,
`WebSearch`, and the scheduling tools are not permitted (offline, synchronous by
design). A step that seems to need another tool means the instruction was misread.

## 1. Start

```bash
st="$(bash "$DRV" start -- "$ARGUMENTS")"
```

Print each line of `.notices[]` and `.warnings[]`, nothing else. Exit 3 is an abort
whose message is already on stderr: relay it and stop. Then resolve `.decisions[]`,
in order, with ONE `AskUserQuestion` per entry (`question`, `options`; `title` is free
text; the driver has already self-answered everything when the run is autonomous or
non-interactive, so the list is usually empty):

| id | On the answer |
|---|---|
| `greenfield` | "Abort" ends the run. "Start new project here" sets `greenfield=1` for step 2. |
| `resume` | A "Resume <slug>" pick jumps to step 3 with that candidate's `featureRoot`. "New feature" continues. |
| `repos` | "Customize": ask for a comma-separated repo list and filter `.workspace.repos` to those names. |
| `title` | The answer is the title; slug it with `lib/git-ops.sh slugify`. |
| `commands` | "Customize": ask for each of prepare/test/lint/typecheck and replace `.commands`. |

The grill directive (`hooks/team/grill-inject.sh`) may already have elicited
disambiguating answers; feed them into the title and scope. SPEC's interview continues
the grill and DISCUSS still runs its design-shape grill afterward unless the run is
autonomous (`execStyle: auto` is not autonomous).

`.resume.autoPick` non-null means the driver already chose a feature to resume:
go to step 3. `.resume.cleanup[]` lists explicit-mode teams that may still be live;
probe each with `TaskList({team})`, and if it answers, tell the user to `TeamDelete`
that team before resuming (those features are not offered).

## 2. Initialize a new feature

```bash
init="$(bash "$DRV" init --dir "$(jq -r '.workspace.root' <<<"$st")" \
  --slug "<slug>" --title "<title>" --style "$(jq -r '.invocation.style' <<<"$st")" \
  --profile "$(jq -r '.profile' <<<"$st")" --classification "$(jq -c '.classification' <<<"$st")" \
  --autonomous "$(jq -r 'if .autonomous then 1 else 0 end' <<<"$st")" --greenfield "<0|1>" \
  --spec-file "$(jq -r '.invocation.spec_path // ""' <<<"$st")" \
  --commands "$(jq -c '.commands' <<<"$st")" --repos "$(jq -c '.workspace.repos' <<<"$st")" \
  --phase-mode "$(jq -r '.invocation.phase_mode // ""' <<<"$st")" \
  --backlog-entry "$(jq -c '.invocation.backlogEntry // empty' <<<"$st")")"
```

Print `Launching: style=<style> title="<title>".` (spec file: `Launching from spec
file: <path> — ...`). If `.enterWorktree` is non-null, call
`EnterWorktree({path: .enterWorktree})` now; every later path is relative to it.
`.featureDir` is the feature directory for the rest of the run. A non-zero exit
already wrote a terminal result: relay stderr and stop.

Then the one-time codebase map:

```bash
map="$(bash "$DRV" map --feature-dir "$featureDir")"
```

For each domain in `.dispatch[]`, fire ONE background `Agent` call, all in the same
message (respect `LOOP_SPEC_MAX_PARALLEL_SUBAGENTS` as wave size and await each wave
when it is set):

```
Agent({
  subagent_type: "loop-spec:mapper-<domain>",
  description: "Bootstrap codebase map: <domain>",
  prompt: "Produce <root>/docs/loop-spec/codebase/<DOMAIN>.md per your role definition.
           Working directory (absolute): <root>. <workspace: Repos: name=abs-path, ...;
           cover each repo in its own section.> Use absolute paths. Do NOT commit.
           Reply DONE: <domain> when finished."
})
```

Do not wait for them; DISCUSS joins them before PLAN needs the docs.

## 3. Resume an existing feature

```bash
rs="$(bash "$DRV" resume --dir "$PWD" --feature-root "<featureRoot>" \
  --phase-mode "$(jq -r '.invocation.phase_mode // ""' <<<"$st")")"
```

Exit 1 means the feature must be resumed from another directory; relay the message and
stop. Call `EnterWorktree({path: .enterWorktree})` when non-null. Print `.watchdog`
when non-null, then `.progressTail`, and `[RESUME] tasks done/remaining` from
`.tasksDone` / `.tasksRemaining` when either is non-empty. When
`.recoverCompletion` is true the PR was already proven: skip to step 5 and run only
DELIVER's feedback check on the existing targets before finishing; recovery
must not skip terminal feedback observation. Otherwise continue to step 4; never re-run
project tests here (VERIFY is the only place that suite runs).

## 4. Phase loop

```bash
ans="$(bash "$DRV" next --feature-dir "$featureDir")"                       # first entry
ans="$(bash "$DRV" next --feature-dir "$featureDir" --returned-from "<phase>" \
      --note "<one line: what the phase produced>")"                          # after each return
```

Act on the first line of `ans`:

- `NEXT phase=<p> ...` — print it, treat every following `EXT ...` line as a standing
  directive or fact file for this phase, then invoke `Skill(loop-spec:<p>)` and, when it
  returns, call `next --returned-from <p>` again. `effort=system1` means keep the phase
  direct; `system2` means state assumptions and check their evidence first.
  Never AskUserQuestion as a wait while a phase agent or the DELIVER controller runs.
- `PAUSED node=...` — a human gate (`style:step|interactive`). Print
  `loop-spec: paused at <node>; re-invoke /loop-spec:cycle to continue.` and, for a
  Claude worktree feature, `ExitWorktree({action:"keep"})`. Stop.
- `HANDOFF next=<p> model=<m>` — print
  `LOOP_SPEC_PHASE_HANDOFF {"slug":..,"next":"<p>","model":"<m>"}` and stop; a fresh
  session (`/loop-spec:cycle phase:fresh`) enters the next phase.
- `REWIND next=<p>` — print `fresh-context rewind: state committed; relaunch
  /loop-spec:cycle to re-enter <p>.` and stop.
- `DONE status=completed` — go to step 5. `DONE status=completed
  reason=already-satisfied` — print the result summary, exit the worktree, stop.
  `DONE status=escalated|paused ...` — print the reason, exit the worktree, stop.
- `ABORT ...` (exit 1) — relay stderr and stop.

The driver owns `currentPhase`, the model map, the watchdog, `PROGRESS.md`, the state
commit, and the autonomous checkpoint PR; phase skills never write `currentPhase`.
When a phase pauses or escalates on its own (iteration limit spent, NEEDS_CONTEXT):

```bash
esc="$(bash "$DRV" escalate --feature-dir "$featureDir" --reason "<reason>")"
```

In explicit teams mode first `TeamDelete` the phase team. Print the reason, the
`gateHistory` tail and artifact paths from `esc`, then the user's options (edit
artifacts and re-invoke; reset counters in feature.json; `/loop-spec:rollback`;
delete the feature dir to abort). `ExitWorktree({action:"keep"})` when
`.exitWorktree` is true. Stop.

## 5. Finish

```bash
fin="$(bash "$DRV" finish --feature-dir "$featureDir" --completed "<features completed this invocation>")"
```

Exit 1 is `delivery-incomplete`: relay and stop without touching state. Otherwise write
the completion summary in the report style (`skills/shared/report-style.md`): outcome
first, then per target from `.targets[]` (repo, PR URL, exact SHA, checks, review
decision and unresolved count), `.warnings[]`, elapsed time, and `.backlogCount`. If the
feedback check reported `changesRequested`, end with `/loop-spec:revise <pr>`. The
summary carries no self-authored deferrals; probe it before printing:

```bash
printf '%s' "$summary" | bash "${CLAUDE_SKILL_DIR}/../../lib/deferral-lint.sh" text -
```

A flag is dropped scope, not wording: resume the cycle and ship the flagged item.
`ExitWorktree({action:"keep"})` when `.exitWorktree` is true; keep the worktree until
merge. When `.chain.chain` is true (autonomous backlog drain within
`LOOP_SPEC_MAX_FEATURES`), start the next feature from step 1 with `.chain.entry.text`
as the description; stop on any paused or escalated feature.

## Route exit

This skill is a route: it ends by publishing `.loop-spec/last-result.json`, which the
driver does on every DONE, HANDOFF, PAUSED, and escalate answer. A request that is
genuinely not repository work (a pure question, or work that needs a different product)
is declined BEFORE the tree changes with the `write-terminal` snippet in
`skills/shared/route-exit-contract.md` (`protocol-mismatch`); a rebase, sync, conflict
resolution, re-review, or one-command chore is repository work and runs the cycle
(`profile=maintenance` shortens the path, never skips ITERATE or DELIVER). Once the
tree has changed, mismatch is no longer the honest ending: report what the run did.

## Headless and autonomous runs

`LOOP_SPEC_NON_INTERACTIVE=1` replaces every question with an environment answer:
`LOOP_SPEC_ANSWER_STYLE`, `LOOP_SPEC_ANSWER_TITLE`, `LOOP_SPEC_SPEC_FILE`,
`LOOP_SPEC_ANSWER_REPOS`, `LOOP_SPEC_CMD_{PREPARE,TEST,LINT,TYPECHECK}`. The inline
token `autonomous` (or `LOOP_SPEC_AUTONOMOUS=1`) is stronger: every question
self-answers with the recommended option and the assumption lands in the decisions
record (`skills/shared/autonomous-mode.md`). Headless form:
`claude -p "/loop-spec:cycle autonomous <description>"`; `/loop-spec:auto` picks
micro, debug, or this cycle first. Backlog drain: `/loop-spec:cycle backlog` runs one
entry per invocation (`LOOP_SPEC_MAX_FEATURES` bounds chaining); an outer
`while :; do claude -p "/loop-spec:cycle backlog"; done` is the overnight loop.

Team dispatch inside phases follows `.loop-spec/runtime.json.teamsMode`: `explicit`
creates a per-phase team, `implicit` probes `lib/implicit-team-model.sh spawn-kind` per
teammate (`skills/shared/dispatch.md`), `none` uses one-shot agents
(`skills/shared/dispatch.md`); rework goes to the same teammate. Follow the
harness contract for this harness (`skills/shared/claude-harness.md`,
`opencode-harness.md`, `codex-harness.md`, `adk-harness.md`).
