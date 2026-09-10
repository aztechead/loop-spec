---
name: cycle
description: "Use when starting or resuming repository work from a feature description or spec file. Runs SPEC -> DISCUSS -> PLAN -> EXECUTE -> VERIFY -> ITERATE -> DELIVER, one phase per invocation. Use /loop-spec:debug for stack traces and /loop-spec:micro for one-file fixes."
argument-hint: "[new] [feature description | path/to/spec.md | backlog]  (optional inline overrides: style:auto|step|interactive|review-only, autonomous, profile:compact|maintenance|standard)"
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet EnterWorktree ExitWorktree ToolSearch Workflow
---

# loop-spec:cycle

Lead the phase that the driver selects. `lib/cycle-driver.sh` controls the loop and returns JSON or protocol lines.
Full-route phases start in fresh invocations. Only saved state passes between invocations.

Resolve the driver's questions. Enter or leave the worktree when directed.
Run the phase instructions that the driver selects. Stop at the phase boundary.

Do not reconstruct state, scan directories again, or narrate startup checks.

```bash
DRV="${LOOP_SPEC_SKILL_DIR}/../../lib/cycle-driver.sh"
```

Run the driver directly. Do not check its path with `ls`, `stat`, or `cat` first.

The frontmatter lists the tools this skill and its phase skills use.
Phases may use other available tools, subject to their role instructions.
The generated adapters prepend `opencode-harness.md` or `codex-harness.md` from `skills/shared/`.
Claude Code hooks supply its contract.

## 1. Start

Rewrite only the prose in `$ARGUMENTS`, following `skills/shared/prompt-normalize.md`.
Keep tokens, file paths, and `backlog` unchanged and in place.
Use the resulting string as `$ARGUMENTS` below. If the arguments contain no prose, use them unchanged.

```bash
st="$(bash "$DRV" begin -- "$ARGUMENTS")"
```

`begin` runs `start`, then `init` or `resume` when no user decision is pending.
This includes autonomous runs and invocations that continue a feature.
Print only the lines from `.notices[]` and `.warnings[]`.
On exit 3, relay the abort message from stderr and stop.
Otherwise, read `.action`:

- `init` or `resume`: use `.featureDir` as the feature directory for this run.
  If `.enterWorktree` is non-null, call `EnterWorktree({path: .enterWorktree})`.
  Print `Launching: style=<style> title="<title>".`
  On resume, print `.watchdog` when non-null and `.progressTail`.
  Print `[RESUME] tasks done/remaining` from `.tasksDone` and `.tasksRemaining` when either is non-empty.
  Continue to step 3 unless `.recoverCompletion` is true.
  When `.recoverCompletion` is true, skip to step 4. Run only DELIVER's feedback check on the existing targets before finishing.
  Recovery must not skip terminal feedback observation. Never re-run project tests here. VERIFY is the only place that suite runs.
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

Run this step only when `begin` returned `decisions` and the user answered.
If `.action` was `init` or `resume`, initialization is complete. Do not call `init` again.

Use `.next.init` for a new feature. Replace its `<slug>`, `<title>`, and `<0|1>` placeholders with the answers.
Use `.next.resume` for the selected existing feature. Run the selected command.

Handle its answer as step 1's `init` or `resume`.
A non-zero exit means the driver wrote a terminal result. Relay stderr and stop.

## 3. One phase

```bash
ans="$(bash "$DRV" next --feature-dir "$featureDir")"
```

Handle the first line of `ans` using these rules. Stop when the selected rule requires it.

- `NEXT phase=<p> label="..." effort=<system1|system2>` — print it, treat every
  following `EXT instructions=<path> sha256=<hash>` line as the phase's rendered
  instruction file. Read and follow that snapshot for this phase. `EXT skill` names
  its role; the snapshot already contains the selected body and harness contract.
  When it returns, close it:

  ```bash
  ans="$(bash "$DRV" next --feature-dir "$featureDir" --returned-from "<p>" \
        --note "<one line: what the phase produced>")"
  ```

  and act on that answer with the same list.
- `REDO phase=<p> flags=<n>` followed by `FLAG ...` lines — `next` ran the phase's exit
  gates (`lib/phase-exit.sh`) and the artifact is not ready.
  Follow the same instruction snapshot again with the FLAG lines.
  The phase fixes its artifact in place and returns.
  Then call `next --returned-from <p>` again. Phase skills never run the exit themselves.
- `HANDOFF next=<p> model=<m>` or `REWIND next=<p>` — the driver saved the next phase and closed this phase. Print
  `LOOP_SPEC_HANDOFF {"slug":..,"next":"<p>","model":"<m>"}` and stop. The caller
  re-invokes `/loop-spec:cycle`, and that invocation enters `<p>` with
  `lib/phase-entry.sh <p>` as its whole ingress. Do not invoke `Skill(loop-spec:<p>)`
  from here (`hooks/team/phase-handoff-guard.sh` denies a second phase in one
  invocation). Never launch the next invocation yourself, directly or through a script.
  `hooks/team/nested-session-guard.sh` blocks nested sessions because they spend this invocation's budget again. For a Claude worktree
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
fin="$(bash "$DRV" finish --feature-dir "$featureDir" --completed <N>)"
```

`N` is the number of features this invocation completed, including this feature. Use `1` for a single-feature run.

On exit 1 (`delivery-incomplete`), relay the error and stop without changing state.
Otherwise, print `.report` unchanged.
It gives the outcome, target details, warnings, elapsed time, and backlog count.
Target details include the repo, PR URL, exact SHA, checks, review decision, and unresolved count.
For `changesRequested`, the report ends with `/loop-spec:revise <pr>`.

If `.exitWorktree` is true, call `ExitWorktree({action:"keep"})`. Keep the worktree until merge.
If `.chain.chain` is true, start the next feature at step 1 with `.chain.entry.text` as its description.
This drains the autonomous backlog within `LOOP_SPEC_MAX_FEATURES`. Stop on any paused or escalated feature.

## Route exit

The driver writes `.loop-spec/last-result.json` for every DONE, HANDOFF, REWIND, PAUSED, and escalate answer.
Before `begin`, decline requests outside repository work, such as pure questions or work that needs another product.
Use the driver to write the protocol-mismatch result:

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
