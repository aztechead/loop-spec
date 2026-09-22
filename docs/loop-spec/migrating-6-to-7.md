# Migrating a 6.9 setup to loop-spec 7

How-to for someone who runs loop-spec 6.9 today, in Claude Code or from a script, and
wants the same work running on 7.x. Follow the sections in order; each ends with a check
you can run. Why 7.x is shaped this way is in [ROADMAP-7.0.md](ROADMAP-7.0.md). The
full surface-by-surface mapping is
[migration-inventory-7.0.md](migration-inventory-7.0.md).

Status: first version, written at M0 from the inventory. Every value marked *M1* is
fixed when the code lands and this page is updated in the same change. Until then,
treat those values as the shape, not the spelling.

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
| `/loop-spec:revise <pr>` | `/loop-spec:revise <pr>`, now re-entering EXECUTE in remediation mode on the PR branch |
| `/loop-spec:status` | unchanged |
| `/loop-spec:auto`, `oneshot`, `spec-lite` | removed; name the entry you want, `micro` for a small change |
| `assess`, `sentinel`, `watch`, `retro`, `rules`, `forensics`, `walkthrough`, `quality-loop`, `checking-gates`, `specifying-gates`, `onboard`, `settings`, `rollback`, `loop-runner` | removed; see the inventory for what, if anything, replaces each |

Check: each entry you still use appears in the table's right column.

## 3. Move your environment variables into config or flags

Most `LOOP_SPEC_*` variables are gone. Create `.loop-spec/config.json` in the
consumer repository for what remains:

```json
{
  "prepare": "npm ci",
  "commitArtifacts": false,
  "evidence": { "review": { "accept": "attested" } },
  "phases": {},
  "roles": {}
}
```

| 6.9 variable | 7.x |
|---|---|
| `LOOP_SPEC_MODEL_<ROLE>` | unchanged, the one model override |
| `LOOP_SPEC_CMD_PREPARE`, `LOOP_SPEC_CMD_TEST`, `_LINT`, `_TYPECHECK` | `prepare` in config; test, lint, and typecheck commands are detected from the manifests at baseline |
| `LOOP_SPEC_ARTIFACTS_IN_PR` | `commitArtifacts` in config |
| `LOOP_SPEC_NON_INTERACTIVE` | nothing; your harness receives every question as `question.json` on exit 3 and re-invokes with the answer |
| `LOOP_SPEC_AUTONOMOUS` | `--answer-policy default` at entry, or a `run`-scoped answer to any question |
| `LOOP_SPEC_ITERATE_MAX_ITERATIONS` | rewind budget override (*M1* name) |
| `LOOP_SPEC_REDO_MAX`, `LOOP_SPEC_RALPH_THRESHOLD` | per-step retry limit (*M1* name) |
| `LOOP_SPEC_CHECKS_*`, `LOOP_SPEC_GH_COMMAND_TIMEOUT_SECONDS` | DELIVER readiness policy in config (*M1* names) |
| `LOOP_SPEC_WORKTREES`, `LOOP_SPEC_WORKTREE_DIR` | removed; worktrees live in the state home, one per task |
| `LOOP_SPEC_CREDENTIAL_REFRESH_*` | removed; DELIVER checks credentials before its first push and exits `delivery blocked` if they cannot be refreshed |
| `LOOP_SPEC_HARNESS`, `LOOP_SPEC_TEAMS_MODE`, `LOOP_SPEC_EXECUTE_WORKFLOW`, every `*_GUARD` | removed |

Anything not listed here is in the inventory's environment table, each with its fate.

Check: `grep -r LOOP_SPEC_ your-harness/` lists only `LOOP_SPEC_MODEL_`, the stdout
markers, and `LOOP_SPEC_CONSOLE_*`.

## 4. Move the state you read

| 6.9 location | 7.x location |
|---|---|
| `docs/loop-spec/features/<slug>/feature.json` | `<state home>/<repo id>/<slug>/state.json`, program-written only |
| `docs/loop-spec/features/<slug>/*.md` | rendered into the PR body; in the state home; in the repo only under `commitArtifacts: true` |
| `.loop-spec/last-result.json` | `<state home>/.../last-result.json`, beside `state.json` |
| `.loop-spec/events.jsonl` | `<state home>/.../events.jsonl` |
| `refs/loop-spec/state/<slug>` | `loop-spec state push|pull`, when a harness asks for it |

The state home is `${CLAUDE_PLUGIN_DATA}` under a Claude Code plugin install, else
`$LOOP_SPEC_HOME`, else `~/.loop-spec/`. `loop-spec status` prints the resolved path.

Check: after one `micro` run, `state.json` and `last-result.json` exist in the printed
state home and the consumer repository's `git status` is clean.

## 5. Update your result consumer

The terminal result keeps schema 1: every existing field keeps its name and meaning.
One field is added, `result`, with values `converged`, `converged-with-caveats`,
`no-change`, `escalated`, `failed`. Read `result` for the 7.x classification and keep
reading `converged` for what 6.9 meant by it. The stdout markers
`LOOP_SPEC_PHASE_START`, `LOOP_SPEC_PHASE_END`, `LOOP_SPEC_HANDOFF`, and
`LOOP_SPEC_RESULT` are unchanged; `LOOP_SPEC_QUESTION` is added on exit 3.

Check: your consumer accepts a result with an unknown extra field. The M1
compatibility fixtures under `tests/` round-trip each result row.

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

Reinstall the 6.9 plugin from the `6.x` branch. 6.9 ignores the 7.x state home, and
7.x wrote nothing to your repository unless you set `commitArtifacts`.
