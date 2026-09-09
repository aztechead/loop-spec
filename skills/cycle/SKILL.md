---
name: cycle
description: "ENTRY POINT for loop-spec. Give it a feature description OR a path to a pre-authored spec .md file. Runs SPEC -> DISCUSS -> PLAN -> EXECUTE -> VERIFY -> ITERATE -> DELIVER one phase per invocation; re-invoke it to enter the next phase, and it resumes incomplete features automatically. Do not use for a pasted stack trace (that's /loop-spec:debug) or a one-file ad-hoc fix (that's /loop-spec:micro)."
argument-hint: "[new] [feature description | path/to/spec.md | backlog]  (optional inline overrides: style:auto|step|interactive|review-only, autonomous, profile:compact|maintenance|standard)"
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet EnterWorktree ExitWorktree ToolSearch Workflow
---

# loop-spec:cycle

You are the lead of one phase. `lib/cycle-driver.sh` owns the loop and answers each
call with one JSON object or one line; every phase boundary hands the next phase to a
fresh invocation of this skill, so nothing from this context travels. Your job is the
parts that need a harness tool or a human: answer questions, enter and leave the
worktree, invoke the one phase skill the driver names, and stop. Do not re-derive
state, re-scan directories, or narrate the preflight.

```bash
DRV="${CLAUDE_SKILL_DIR}/../../lib/cycle-driver.sh"
```

Run it; do not `ls`, `stat`, or `cat` it first (two live leads spent their first turn
checking the path exists).

The frontmatter lists the tools this skill and its phase skills use. Any other tool the
harness offers (a web or registry lookup, an MCP server) is available to a phase that
needs it; the plugin restricts nothing beyond what a role's own charter says. On
OpenCode and Codex the generated adapter prepends this harness's contract
(`opencode-harness.md`, `codex-harness.md` under `skills/shared/`); on Claude Code
the hooks carry it.

## 1. Start

Rewrite the free-prose portion of `$ARGUMENTS` per `skills/shared/prompt-normalize.md`
and splice it back between the verbatim tokens and paths; the spliced string is what
`$ARGUMENTS` means in the call below. Tokens, file paths, and `backlog` are grammar,
not prose: an invocation carrying no prose passes through unchanged.

```bash
st="$(bash "$DRV" begin -- "$ARGUMENTS")"
```

`begin` is `start` followed by `init` or `resume` whenever no human decision is
pending (every autonomous run, every re-invocation that continues a feature). Print
each line of `.notices[]` and `.warnings[]`, nothing else. Exit 3 is an abort whose
message is already on stderr: relay it and stop. Read `.action`:

- `init` or `resume`: the feature is ready. `.featureDir` is the feature directory for
  the rest of the run; call `EnterWorktree({path: .enterWorktree})` when non-null; print
  `Launching: style=<style> title="<title>".` (on resume: `.watchdog` when non-null,
  `.progressTail`, and `[RESUME] tasks done/remaining` from `.tasksDone` /
  `.tasksRemaining` when either is non-empty); go to step 3. When
  `.recoverCompletion` is true the PR was already proven: skip to step 4 and run only
  DELIVER's feedback check on the existing targets before finishing; recovery
  must not skip terminal feedback observation. Never re-run project tests here
  (VERIFY is the only place that suite runs).
- `decisions`: resolve `.decisions[]`, in order, with ONE `AskUserQuestion` per entry
  (`question`, `options`; `title` is free text), then step 2.

| id | On the answer |
|---|---|
| `greenfield` | "Abort" ends the run. "Start new project here" is `--greenfield 1`. |
| `resume` | A "Resume <slug>" pick runs `.next.resume` with that candidate's `featureRoot` and `slug`; "New feature" continues. |
| `repos` | "Customize": ask for a comma-separated repo list and pass only those in `--repos`. |
| `title` | The answer is the title; slug it with `lib/git-ops.sh slugify`. |
| `commands` | "Customize": ask for each of prepare/test/lint/typecheck and pass them in `--commands`. |

The grill directive (`hooks/team/grill-inject.sh`) may already have elicited answers;
feed them into the title and scope. SPEC's interview continues the grill and
DISCUSS still runs its design-shape grill afterward unless the run is autonomous
(`execStyle: auto` is not autonomous). `.resume.cleanup[]` lists explicit-mode teams
that may still be live; probe each with `TaskList({team})`, and if it answers, tell
the user to `TeamDelete` that team before resuming.

## 2. Run the command `begin` rendered

Only after `begin` answered `decisions` (a human chose). When `.action` was `init` or
`resume`, the feature is already initialized: do not call `init` again (a live lead
did, with `$st` from a previous Bash call, which is empty, and got the usage text).
`.next.init` is the init call with every value `start` holds in place; put the answers
in its `<slug>`, `<title>`, and `<0|1>` placeholders and run it; `.next.resume` is the
resume call for a pick. Treat the answer as step 1's `init` or `resume`. A non-zero
exit already wrote a terminal result: relay stderr and stop.

## 3. One phase

```bash
ans="$(bash "$DRV" next --feature-dir "$featureDir")"
```

Act on the first line of `ans`, then stop.

- `NEXT phase=<p> label="..." effort=<system1|system2>` — print it, treat every
  following `EXT ...` line as a standing directive or fact file for this phase, then
  invoke `Skill(loop-spec:<p>)`, or `Skill(loop-spec:<name>)` when an `EXT skill=<name>`
  line names a lighter skill for the phase. `effort=system1` means keep the phase
  direct; `system2` means state assumptions and check their evidence first. When the
  phase skill returns, close it:

  ```bash
  ans="$(bash "$DRV" next --feature-dir "$featureDir" --returned-from "<p>" \
        --note "<one line: what the phase produced>")"
  ```

  and act on that answer with the same list.
- `REDO phase=<p> flags=<n>` followed by `FLAG ...` lines — `next` ran the phase's exit
  gates (`lib/phase-exit.sh`) and the artifact is not ready. Invoke the phase skill
  again with the FLAG lines; the phase fixes its artifact in place and returns; then call
  `next --returned-from <p>` again. Phase skills never run the exit themselves.
- `HANDOFF next=<p> model=<m>` or `REWIND next=<p>` — the phase is closed and the next
  one is ready in durable state. Print
  `LOOP_SPEC_HANDOFF {"slug":..,"next":"<p>","model":"<m>"}` and stop. The caller
  re-invokes `/loop-spec:cycle`, and that invocation enters `<p>` with
  `lib/phase-entry.sh <p>` as its whole ingress. Do not invoke `Skill(loop-spec:<p>)`
  from here (`hooks/team/phase-handoff-guard.sh` denies a second phase in one
  invocation). Never launch the next invocation yourself either, with no `claude -p`
  and no script around one: a nested session spends this invocation's budget a second
  time (`hooks/team/nested-session-guard.sh` denies the launch). For a Claude worktree
  feature, `ExitWorktree({action:"keep"})` first.
- `PAUSED node=...` — a human gate (`style:step|interactive`). Print `loop-spec: paused
  at <node>; re-invoke /loop-spec:cycle to continue.`, exit a Claude worktree, stop.
- `DONE status=completed` — step 4. `DONE ... reason=already-satisfied` — print the
  result summary, exit the worktree, stop. `DONE status=escalated|paused ...` — print
  the reason, exit the worktree, stop. `ABORT ...` (exit 1) — relay stderr and stop.

Never AskUserQuestion as a wait while a phase agent or the DELIVER controller runs.
Team dispatch inside a phase is the phase skill's contract, not this one's: the probe
is `lib/implicit-team-model.sh spawn-kind`, the row `.loop-spec/runtime.json.teamsMode`.

The driver owns `currentPhase`, the model map, the watchdog, `PROGRESS.md`, the state
snapshot on `refs/loop-spec/state/{slug}` (`lib/state-ref.sh`), the paused result, and
the checkpoint PR; phase skills never write `currentPhase`. When a phase pauses or
escalates on its own (iteration limit spent, NEEDS_CONTEXT):

```bash
esc="$(bash "$DRV" escalate --feature-dir "$featureDir" --reason "<reason>")"
```

In explicit teams mode first `TeamDelete` the phase team. Print the reason, the
`gateHistory` tail and artifact paths from `esc`, then the user's options (edit
artifacts and re-invoke; reset counters in feature.json; `/loop-spec:rollback`; delete
the feature dir to abort). `ExitWorktree({action:"keep"})` when `.exitWorktree`. Stop.

## 4. Finish

```bash
fin="$(bash "$DRV" finish --feature-dir "$featureDir" --completed <N>)"   # N = how many features this invocation completed, counting this one (1 on a single-feature run); a live lead passed the slug
```

Exit 1 is `delivery-incomplete`: relay and stop without touching state. Otherwise print
`.report` as is: the outcome first, then per target (repo, PR URL, exact SHA, checks,
review decision and unresolved count), `.warnings[]`, elapsed time, and
`.backlogCount`; when the feedback check reported `changesRequested` its last line
is `/loop-spec:revise <pr>`. `ExitWorktree({action:"keep"})` when `.exitWorktree` is
true; keep the worktree until merge. When `.chain.chain` is true (autonomous backlog
drain within `LOOP_SPEC_MAX_FEATURES`), start the next feature from step 1 with
`.chain.entry.text` as the description; stop on any paused or escalated feature.

## Route exit

This skill is a route: it ends by publishing `.loop-spec/last-result.json`, which the
driver does on every DONE, HANDOFF, REWIND, PAUSED, and escalate answer. A request that
is genuinely not repository work (a pure question, or work that needs a different
product) is declined BEFORE `begin`, with the protocol-mismatch result the driver
writes:

```bash
bash "$DRV" decline --reason "<why this is not repository work>" --summary "<what the request needs>"
```

A rebase, sync, conflict resolution, re-review, or one-command chore is repository
work and runs the cycle (`profile=maintenance` shortens the path but never skips ITERATE or DELIVER).
Once the tree has changed, mismatch is no longer the honest ending: report what the
run did. One invocation is one phase; a headless caller re-invokes while
`.loop-spec/last-result.json` says `status=paused` with `reason=phase-handoff`
(`docs/loop-spec/cloud-run-autonomous.md`), and `docs/loop-spec/configuration.md`
holds every environment answer a non-interactive run takes.
