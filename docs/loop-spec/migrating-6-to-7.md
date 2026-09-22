# Migrating a 6.9 setup to loop-spec 7

How-to for someone who runs loop-spec 6.9 today, in Claude Code or from a script, and
wants the same work running on 7.x. Follow the sections in order; each ends with a check
you can run. Why 7.x is shaped this way is in [ROADMAP-7.0.md](ROADMAP-7.0.md). The
full surface-by-surface mapping is
[migration-inventory-7.0.md](migration-inventory-7.0.md).

Status: updated at M7 cutover against the shipped 7.0.0 code; every value below is
the real name, not a placeholder.

## Before you start

- 7.x targets Claude Code and the Claude Agent SDK. If you run loop-spec under
  opencode, Google ADK, or Codex, those trees are gone in 7.x; the skills install
  (`npx skills add`) is the path for other agents and is unattended-capable only
  through the SDK runner.
- Finish or abandon any 6.9 run in flight. 7.x does not read a 6.9 `feature.json`.
- Keep the 6.9 plugin installed until the check at the end of this page passes; the
  `6.x` branch stays available.

## 1. Install

Install the 7.x plugin from the marketplace as before, or run `npx skills add
<owner>/loop-spec` for a skills-only install. Nothing else is required: 7.x ships no
hook, no agents, and no MCP config.

Check: `loop-spec status` in a repository prints "no run" and the resolved state home.

## 2. Move your invocations

| You ran in 6.9 | Run in 7.x |
|---|---|
| `/loop-spec:cycle <text or spec file>` | `/loop-spec:cycle <text or spec file>`, unchanged |
| `/loop-spec:spec`, `plan`, `execute`, `verify`, `iterate`, `deliver` | same names; each checks its preconditions against state and refuses to run out of order |
| `/loop-spec:debug` | unchanged |
| `/loop-spec:micro` | `/loop-spec:micro`; the `on`, `off`, and `status` modes are gone |
| `/loop-spec:intake <file>` | `/loop-spec:cycle <file>` |
| `/loop-spec:pause` | nothing to run; every run resumes from state, and `status` shows the pending question |
| `/loop-spec:revise <pr>` | `/loop-spec:revise --pr <n-or-url>`, now compacting the PR's gaps into SPEC and PLAN and running the cycle forward, with one full review pass over the adopted commits before EXECUTE's own tasks |
| `/loop-spec:status` | unchanged |
| `/loop-spec:auto`, `oneshot`, `spec-lite` | removed; name the entry you want, `micro` for a small change |
| `assess`, `sentinel`, `watch`, `retro`, `rules`, `forensics`, `walkthrough`, `quality-loop`, `checking-gates`, `specifying-gates`, `onboard`, `settings`, `rollback`, `loop-runner` | removed; see the inventory for what, if anything, replaces each |

Check: each entry you still use appears in the table's right column.

## 3. Move your environment variables into config or flags

Most `LOOP_SPEC_*` variables are gone. Create `.loop-spec/config.json` in the
consumer repository for what remains:

```json
{
  "commitArtifacts": false,
  "phases": {},
  "roles": {}
}
```

`prepare` is no longer a config key: PLAN's own product carries a `prepare`
command (the planner writes it), applied before every baseline capture and
re-verification.

| 6.9 variable | 7.x |
|---|---|
| `LOOP_SPEC_MODEL_<ROLE>` | narrower: sets the model on a SPEC or PLAN lead step only (`defaults.py`); other role dispatches do not read it yet |
| `LOOP_SPEC_CMD_PREPARE`, `LOOP_SPEC_CMD_TEST`, `_LINT`, `_TYPECHECK` | removed; PLAN's own product names each task's `verify` command and the plan's `prepare` command directly, nothing is detected from manifests |
| `LOOP_SPEC_ARTIFACTS_IN_PR` | `commitArtifacts` in config |
| `LOOP_SPEC_NON_INTERACTIVE` | nothing; your harness receives every question as `question.json` on exit 3 and re-invokes with the answer |
| `LOOP_SPEC_AUTONOMOUS` | `--answer-policy default` at entry, or a `run`-scoped answer to any question |
| `LOOP_SPEC_ITERATE_MAX_ITERATIONS` | `LOOP_SPEC_REWIND_BUDGET` (the shared T1 budget's limit; default 2) |
| `LOOP_SPEC_REDO_MAX`, `LOOP_SPEC_RALPH_THRESHOLD` | `LOOP_SPEC_STEP_RETRIES` (per-phase retry limit; default 3) |
| `LOOP_SPEC_CHECKS_*`, `LOOP_SPEC_GH_COMMAND_TIMEOUT_SECONDS` | `deliver.readiness`/`deliver.base` in config; no configurable timeout in this release |
| `LOOP_SPEC_WORKTREES`, `LOOP_SPEC_WORKTREE_DIR` | removed; worktrees live in the state home, one per repo under EXECUTE |
| `LOOP_SPEC_CREDENTIAL_REFRESH_*` | removed; DELIVER checks credentials before its first push and exits `delivery blocked` if they cannot be refreshed |
| `LOOP_SPEC_HARNESS`, `LOOP_SPEC_TEAMS_MODE`, `LOOP_SPEC_EXECUTE_WORKFLOW`, every `*_GUARD` | removed |

Anything not listed here is in the inventory's environment table, each with its fate.

Check: `grep -r LOOP_SPEC_ your-harness/` lists only `LOOP_SPEC_HOME`,
`LOOP_SPEC_PYTHON`, `LOOP_SPEC_PHASE_<NAME>`, `LOOP_SPEC_ROLE_<ROLE>`,
`LOOP_SPEC_MODEL_<ROLE>`, `LOOP_SPEC_REWIND_BUDGET`, `LOOP_SPEC_STEP_RETRIES`,
`LOOP_SPEC_EXECUTE_WIDTH`, the stdout markers, and `LOOP_SPEC_CONSOLE_*`. The full
list, grounded in the program's own source, is
[../../skills/loop-spec/references/contract.md](../../skills/loop-spec/references/contract.md#configuration-and-environment).

## 4. Move the state you read

| 6.9 location | 7.x location |
|---|---|
| `docs/loop-spec/features/<slug>/feature.json` | `<state home>/<repo id>/<slug>/state.json`, program-written only |
| `docs/loop-spec/features/<slug>/*.md` | rendered into the PR body; in the state home; in the repo only under `commitArtifacts: true` |
| `.loop-spec/last-result.json` | `<state home>/<repo id>/last-result.json`, one level above `state.json`, shared across every slug for that repository |
| `.loop-spec/events.jsonl` | `<state home>/.../events.jsonl` |
| `refs/loop-spec/state/<slug>` | not available at 7.0; `loop-spec state push|pull` is a seam the roadmap builds only when a harness needs it |

`.loop-spec/` reappears in your repository at 7.x, but for a different reason: it
now holds only a worker's own result files, at `.loop-spec/results/<slug>/`, never
the state itself. This exists because Claude Code's default permission mode
refuses writes under `~/.claude`, where the state home lives on that host; the
program excludes `.loop-spec/` from `git status` itself, via `.git/info/exclude`,
so it is never committed either.

The state home resolves in this order: an explicit `--state-home` flag (the
Claude Code skill stubs pass `${CLAUDE_PLUGIN_DATA}`, substituted by the host),
else `$LOOP_SPEC_HOME`, else `~/.loop-spec/`. `loop-spec status` prints the
resolved path.

Check: after one `micro` run, `state.json` and `last-result.json` exist in the printed
state home and the consumer repository's `git status` is clean.

## 5. Update your result consumer

The terminal result keeps schema 1: every existing field keeps its name and meaning.
One field is added, `result`, with values `converged`, `converged-with-caveats`,
`no-change`, `escalated`, `failed`. Read `result` for the 7.x classification and keep
reading `converged` for what 6.9 meant by it. The stdout markers
`LOOP_SPEC_PHASE_START`, `LOOP_SPEC_PHASE_END`, and `LOOP_SPEC_RESULT` are
unchanged; `LOOP_SPEC_QUESTION` is added on exit 3, and `LOOP_SPEC_NEXT` is new —
the last line of every controller entry, naming the file to read next (`step`,
`question`, or `result`) and the slug every later call needs.

Check: your consumer accepts a result with an unknown extra field. loop-spec's own
unit tests cover its deterministic Python modules only; a result's actual shape is
confirmed by a recorded live run, listed in
[live-runs-7.0.md](live-runs-7.0.md).

## 6. If your harness federates questions

In 6.9 you intercepted `AskUserQuestion`. In 7.x read `question.json` from the state
directory when the program exits 3, post it wherever you like, and re-invoke with
the answer under its id. An answer with scope `run` means "answer this and everything
after it by the default policy for the rest of this run"; the result lists every
question a policy answered. An answer to a question id the program has retired is
rejected, so always answer the id you were given, not a remembered one.

Check: a run under your harness pauses with `status: paused` and the question id in
`reason`, then continues when you answer.

## 7. If you deploy unattended

Use the SDK runner with your own configured API or provider credentials; the program
never switches an interactive user to it. The supervisor example under `examples/`
shows the `can_use_tool` policy for questions. Issue-to-PR wiring is no longer shipped;
compose it around the supervisor.

Check: the SDK gate scenario in roadmap section 17 passes in your environment.

## Roll back

Reinstall the 6.9 plugin from the `6.x` branch. That changes the installed tool only.
6.9 ignores the 7.x state home, so leave it in place if a run may resume later. Work
7.x delivered is ordinary git history: source commits on feature branches, pushed
branches, and PRs stay where they are, so inspect `git branch`, the remote, and open
PRs separately before deciding what to keep. `commitArtifacts` controls only the
rendered SPEC and VERIFICATION documents.
