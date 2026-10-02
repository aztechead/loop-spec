# Migrating a 6.9 setup to loop-spec 7

How-to for a person or agent that runs loop-spec 6.9 today, in Claude Code or from a
script, and wants the same work running on 7.x. Follow the sections in order; each
ends with a check you can run. Sections 1 to 5 apply to everyone. Section 6 is for a
script or service that drove 6.9 itself, and section 7 is for unattended runs. The host-author reference after section 7 lists what a 6.x host read or set and what 7.x does instead. Why
7.x is shaped this way is in [ROADMAP-7.0.md](ROADMAP-7.0.md).

Applies to 7.0.2. Every name, flag, and path below is the shipped one.

## Before you start

- 7.x runs on Claude Code (interactive or `claude -p`) and on the Claude Agent SDK.
  The opencode, Google ADK, and Codex trees are gone. Another agent can install the
  skills with `npx skills add`, but only Claude Code and the SDK are tested.
- Finish or abandon any 6.9 run in flight. 7.x does not read a 6.9 `feature.json`.
- Keep the 6.9 plugin installed until the check at the end of section 4 passes. The
  `6.x` branch stays available for rollback.
- The requirements are `git`, `python3` >= 3.11, and, for DELIVER, an authenticated
  `gh` with an `origin` remote. Nothing else is installed.

## 1. Install and find the launcher

In Claude Code:

```
/plugin marketplace add aztechead/loop-spec
/plugin install loop-spec@loop-spec-marketplace
```

For a skills-only install: `npx skills add aztechead/loop-spec`. 7.x ships no hook,
no agents, and no MCP config.

The skills call one launcher, `skills/loop-spec/program/loop-spec`. It is not put on
`PATH`. A script calls it by path, either from a checkout of this repository pinned to
a release tag or from the installed plugin
(`ls ~/.claude/plugins/cache/loop-spec-marketplace/loop-spec/*/skills/loop-spec/program/loop-spec`).
This page writes it as `$LS`:

```bash
LS=/path/to/loop-spec/skills/loop-spec/program/loop-spec
"$LS" --version
```

Check: `"$LS" status --project-root <repo>` prints `no loop-spec state for <repo>`,
or one slug per line if a 7.x run already exists there.

## 2. Move your invocations

| You ran in 6.9 | Run in 7.x |
|---|---|
| `/loop-spec:cycle <text or spec file>` | `/loop-spec:cycle <text or spec file>`, unchanged |
| `/loop-spec:spec`, `plan`, `execute`, `verify`, `iterate`, `deliver` | same names; each checks its preconditions against state and refuses to run out of order |
| `/loop-spec:debug` | unchanged |
| `/loop-spec:micro` | `/loop-spec:micro`; the `on`, `off`, and `status` modes are gone |
| `/loop-spec:intake <file>` | `/loop-spec:cycle <file>` |
| `/loop-spec:pause` | nothing to run; every run resumes from state, and `status` shows the pending question |
| `/loop-spec:revise <pr>` | `/loop-spec:revise <n-or-url>`. It compacts the PR's review gaps into SPEC and PLAN and runs the cycle forward. EXECUTE reviews the PR's existing commits once before its own tasks |
| `/loop-spec:status` | unchanged |
| `/loop-spec:auto` | `/loop-spec:auto <request>` (7.3.0). A router picks the entry, including `direct` for a mechanical git or PR operation that needs no cycle |
| `oneshot`, `spec-lite` | removed; name the entry you want, `micro` for a small change |
| `assess`, `sentinel`, `watch`, `retro`, `rules`, `forensics`, `walkthrough`, `quality-loop`, `checking-gates`, `specifying-gates`, `onboard`, `settings`, `rollback`, `loop-runner` | removed; 7.x has no command for these (settings live in `.loop-spec/config.json`, see [contract.md](../../skills/loop-spec/references/contract.md)) |

From a script, the same entries are launcher subcommands, each with
`--project-root <repo>`: `"$LS" cycle` and `micro` take `--request <text>` or
`--request-file <path>`, `debug` takes `--request`, `revise` takes `--pr <n-or-url>`,
and `status` and the phase entries take `--slug`. Section 6 covers what to do with
their output.

Check: each entry you still use appears in the table's right column.

## 3. Move your environment variables into config or flags

Most `LOOP_SPEC_*` variables are gone. What remains is optional project config in
`.loop-spec/config.json` in the consumer repository, a few environment variables, and
entry flags. An empty config is valid:

```json
{
  "phases": {},
  "roles": {}
}
```

`prepare` is no longer a config key. PLAN's own product carries a `prepare` command,
written by the planner and applied before every baseline capture and re-verification.

| 6.9 variable | 7.x |
|---|---|
| `LOOP_SPEC_MODEL_<ROLE>` | kept: sets the model for every dispatch of that role (`SPEC_WRITER`, `CODE_REVIEWER`, ...), overriding `roles.<role>.model` in config. Since 7.5.0 a dispatched role with neither set runs at its default: `opus` for router, plan-critic, code-reviewer and iterate-judge, `sonnet` for implementer and verifier |
| `LOOP_SPEC_PHASE_MODEL_<PHASE>` | kept since 7.7.5 (absent 7.0.0 to 7.7.4): the model for every step in that phase unless the role's own model is set (`LOOP_SPEC_MODEL_<ROLE>`, or `roles.<role>.model` in config, which 6.x did not have; an explicit `null` there wins too). SPEC and PLAN run in the lead, so their model takes effect only under an Agent SDK runner that switches the lead's model (`examples/sdk-plugin`, `examples/supervisor`); 6.x's fresh session per phase does not exist in 7.x |
| `LOOP_SPEC_CMD_PREPARE`, `LOOP_SPEC_CMD_TEST`, `_LINT`, `_TYPECHECK` | removed; PLAN names each task's `verify` command and the plan's `prepare` command. Nothing is detected from manifests |
| `LOOP_SPEC_ARTIFACTS_IN_PR` | nothing; the rendered documents go into the PR body and the state home, never into a commit (a docs commit after VERIFY would deliver a head VERIFY never saw) |
| `LOOP_SPEC_NON_INTERACTIVE` | nothing; a question ends the entry with a `question` file to answer (section 6) |
| `LOOP_SPEC_AUTONOMOUS` | `--answer-policy default` at entry, or `--scope run` on any answer |
| `style:auto` (6.x's default), `LOOP_SPEC_ANSWER_STYLE=auto` | 7.x asks for requirements approval by default, which 6.x's `auto` style skipped. Set `spec.approval: "policy"` in config or `LOOP_SPEC_SPEC_APPROVAL=policy` to skip it again; `style:step`/`interactive` behavior (asking) is 7.x's default |
| `LOOP_SPEC_ITERATE_MAX_ITERATIONS` | nothing; since 7.9.0 no count bounds rewinds (see "Rewind progress rule") |
| `LOOP_SPEC_REDO_MAX`, `LOOP_SPEC_RALPH_THRESHOLD` | nothing; a rejection reason that repeats asks the operator (see "Rewind progress rule") |
| `LOOP_SPEC_CHECKS_*`, `LOOP_SPEC_GH_COMMAND_TIMEOUT_SECONDS` | removed; nothing in 7.x waits on CI. `deliver.readiness: "checks"` in config makes one `gh pr checks` call, `deliver.base` sets the PR base, `deliver.branch` (7.9.0) names the feature branch, and there is no configurable timeout in this release |
| `LOOP_SPEC_WORKTREES`, `LOOP_SPEC_WORKTREE_DIR` | removed; worktrees live in the state home |
| `LOOP_SPEC_CREDENTIAL_REFRESH_*` | removed; DELIVER checks credentials before its first push and exits `delivery blocked` if they fail |
| `LOOP_SPEC_HARNESS`, `LOOP_SPEC_TEAMS_MODE`, `LOOP_SPEC_EXECUTE_WORKFLOW`, every `*_GUARD` | removed |

Variables a 6.x host set that have no 7.x equivalent are listed under "For host authors" below.

Commands the program runs are now checked for form. PLAN `verify` and `prepare`, a
debug reproduction, and VERIFY evidence run as argv with no shell. A command using
`&&`, a pipe, a redirect, `$VAR`, or an unquoted glob is rejected before it runs,
with a reason naming the task. If your requests dictate verify commands, write one
plain command each (`.venv/bin/python -m pytest -q tests/test_x.py`, not
`cd tests && pytest`). The rules are under "Commands" in
[phase-interface-7.0.md](phase-interface-7.0.md).

Check: `grep -rho 'LOOP_SPEC_[A-Z_]*' your-harness/ | sort -u` lists only names in the
environment table of
[contract.md](../../skills/loop-spec/references/contract.md#configuration-and-environment)
or the markers in section 6.

## 4. Move the state you read

| 6.9 location | 7.x location |
|---|---|
| `docs/loop-spec/features/<slug>/feature.json` | `<state home>/<repo id>/<slug>/state.json`, program-written only |
| `docs/loop-spec/features/<slug>/*.md` | rendered into the PR body and kept in the state home; never committed |
| `.loop-spec/last-result.json` | `<state home>/<repo id>/last-result.json`, shared by every slug for that repository |
| `.loop-spec/events.jsonl` | `<state home>/<repo id>/<slug>/events.jsonl` |
| `refs/loop-spec/state/<slug>` | not available in 7.0 |

`<repo id>` hashes the repository's first root commit, so it survives new remotes, renames,
and clones. Two clones of one repository therefore share it: the same request run in both
at once shares one run's state. Run concurrent work from different slugs, or give each
scratch repository its own first commit.

The state home resolves in this order: `--state-home`, else `$LOOP_SPEC_HOME`, else
`~/.loop-spec/`. The Claude Code skills pass no `--state-home`, so a script that
inspects or answers a run started in Claude Code finds it with the same default.
Before 7.7.0 the skills passed the plugin's data directory under
`~/.claude/plugins/data/`, which Claude Code's sandbox does not let the plugin write;
finish a run started there by passing that directory as `--state-home`.

`.loop-spec/` still appears in your repository, for a different reason. It holds only
workers' result files, under `.loop-spec/results/<slug>/`, because Claude Code's
default permission mode refuses writes under `~/.claude`. The program adds
`.loop-spec/` to `.git/info/exclude`, so it never shows in `git status` and is never
committed.

Check: after one `micro` run, `state.json` and `last-result.json` exist under the
state home and `git status` in the consumer repository is clean.

## 5. Update your result consumer

The terminal result keeps schema 1: every existing field keeps its name, and all
but the ones listed under "For host authors" below keep their meaning. The object
allows extra fields. One field is added, `result`, with one of `converged`,
`converged-with-caveats`, `no-change`, `escalated`, `failed`, `paused`, and, from
7.3.0, `direct` and `routed`.
Read `result` for the 7.x classification and keep reading `converged` for what 6.9
meant by it. `status` is `completed`, `paused`, `escalated`, or `failed`. A `paused`
result is not mirrored to `last-result.json`, since the run can still resume.

Field list: [contract.md, Result](../../skills/loop-spec/references/contract.md#result).

Check: your consumer parses the `result.json` of the `micro` run from section 4's check
and does not fail on a field it does not know.

## 6. If a script or service drove 6.9

In 6.9 a harness intercepted `AskUserQuestion` or set `LOOP_SPEC_NON_INTERACTIVE`. In
7.x every launcher call runs until the next point that needs something from outside,
prints what that is, and exits 0. A non-zero exit is an error, and stderr carries the
message and a `repair:` hint.

Drive a run with this loop:

1. Start it: `"$LS" cycle --project-root <repo> --request "<text>"` (add
   `--state-home <dir>` and `--answer-policy default` as needed).
2. Read every line of stdout that starts with `LOOP_SPEC_NEXT `, in order. Each is
   followed by JSON: `{"kind": "step"|"question"|"result", "path": ..., "slug": ...}`.
   Keep the `slug`; every later call needs `--slug`.
3. For each `step`, open `path` (`step.json`) and complete it:
   - `kind: "role"`: run a fresh worker on `prompt` verbatim, with `model` when the
     step names one. The worker writes its JSON result to `resultPath`. Then run
     `"$LS" submit --project-root <repo> --slug <slug> --step <stepAttemptId> --dispatch <stepAttemptId>`.
   - `kind: "lead"`: do the work in your own session and write the result to
     `resultPath`, then submit without `--dispatch`.
   - `kind: "external"`: a person or another tool produces the product; nothing can
     be automated here.
4. For a `question`, open `path` (`question.json`), choose a value from `options`
   (or `defaultValue`), and run
   `"$LS" answer --project-root <repo> --slug <slug> --question <questionId> --answer <value>`.
   Add `--scope run` to let the default policy answer every later question that has
   a default.
5. Each `submit` and `answer` prints the next `LOOP_SPEC_NEXT` lines. Repeat from
   step 2 until the kind is `result`, then read `result.json` at `path`.

Three behaviors break a "read the last line" driver:

- An EXECUTE wave issues up to `LOOP_SPEC_EXECUTE_WIDTH` steps at once (default 3),
  one `LOOP_SPEC_NEXT` line each. Dispatch all of them.
- Every call re-announces each step that is still open, including steps you already
  dispatched and have not submitted yet. Track the `stepAttemptId`s you have
  dispatched and skip them; submitting one step twice is refused with
  `a different result was already submitted`. A submit inside EXECUTE can instead
  print `LOOP_SPEC_WAIT {"open": [...]}` and no `LOOP_SPEC_NEXT`; keep submitting the
  steps you hold.
- A submit can answer `unattested` with a new `LOOP_SPEC_NEXT` for the same step.
  The stdout line before it names a new dispatch name, `<stepAttemptId>-<n>`. Run a
  fresh worker on the same prompt and submit with `--dispatch` set to that name.
  This happens only under a Claude Code host, which attests its own dispatches.

The other stdout markers are `LOOP_SPEC_PHASE_START`, `LOOP_SPEC_PHASE_END`,
`LOOP_SPEC_QUESTION` (new in 7.x), and `LOOP_SPEC_RESULT`, all unchanged in form and
all also written to `events.jsonl`. Progress lines (`[PLAN] ...`) go to stderr;
`LOOP_SPEC_CONSOLE_STREAM=stdout` moves them, and `LOOP_SPEC_CONSOLE_EVENTS=0`
silences them.

[examples/supervisor/supervisor.py](../../examples/supervisor/supervisor.py)
implements this loop on the Agent SDK. It is a reference, not a supported surface.

Check: your driver completes a run whose plan has two independent tasks. That is the
case that issues two `LOOP_SPEC_NEXT` lines together.

## 7. If you run unattended

There are two paths. Pick by where the worker sessions run.

**Headless Claude Code.** Run the skill under `claude -p` with a permission mode that
allows edits (the recorded runs use `--permission-mode bypassPermissions`), and tell
the lead in the prompt to pass `--answer-policy default`:

```bash
claude -p "/loop-spec:cycle <request> [Operator: this is a headless run; pass --answer-policy default on the loop-spec cycle command.]" \
  --permission-mode bypassPermissions --output-format stream-json --verbose
```

The lead then auto-approves every question that has a default, including the
requirements approval. A question with no default still stops the run. Answer it
with `"$LS" answer` (section 6), then continue with
`claude -p --resume <session id> "The question was answered; continue the run."`.
`--output-format stream-json --verbose` puts the lead's text, thinking, and tool
calls on stdout. This path is the one the recorded live runs use.

**Agent SDK.** Two reference scripts, both run live on 7.0.2 with a Claude
subscription login. Auth is the SDK's own: a subscription login,
`CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token`, `ANTHROPIC_API_KEY`, or a cloud
provider's variables. The program never switches an interactive user to the SDK.

- [examples/sdk-plugin/](../../examples/sdk-plugin/README.md) loads loop-spec as a
  local plugin in one SDK session and sends `/loop-spec:<entry>`, so the run behaves
  as it does under `claude -p`. `--auto` answers questions with their first option.
  Start here.
- [examples/supervisor/](../../examples/supervisor/README.md) is the section 6 loop
  on the SDK: it drives the launcher and runs each step as its own SDK query.

Issue-to-PR wiring is no longer shipped; compose it around either script.

Check: one headless run on a scratch repository ends with a `result.json` whose
`status` is `completed` and a PR at the verified head, with no prompt answered by
hand.

## For host authors: what a 6.x host reads or sets, and what 7.x does instead

This section is for someone whose program runs loop-spec headless and reads `result.json`. It describes 7.8.2. Field definitions are in [contract.md, Result](../../skills/loop-spec/references/contract.md#result).

### result.json fields and outcomes

| 6.x | 7.x | Host action |
|---|---|---|
| Outcomes `delivery-blocked`, `delivered-unready`, `completed-with-gaps` | Gone. A delivery block ends `escalated` with `retryable: false`. Only a `failed` run has `retryable: true`. | Branch on `result`. A finished run is never resumed; start a new run. |
| `checkpointPrUrl` | Always `null`. 7.x opens no checkpoint PRs. | Stop reading it. |
| `delivery.targets[]` | `{repo, pr, deliveredSha, caveats, state}` per repo. | Read `state` per row. |
| `prUrl` | Set only for a delivered row, or for the PR a `no-change` run adopted. | After a partial or failed delivery, read `delivery.targets[]`. |
| `iterations` | `{used, max}`: `used` is the number of backward transitions the run made, not ITERATE rounds; `max` is `null` since 7.9.0 (no count bounds rewinds). | Do not read `max`. |
| `implementationConverged`: true once the cycle reached delivery; false for a local preflight stop such as a credential failure | True when ITERATE converged (with or without caveats) or the run is `no-change`, including a run that then escalated at DELIVER. A credential failure now reports true. This is a stated divergence from 6.x. | Use it for "the code is done". Use `result` and `workDelivered` for "a PR exists". |
| `feature_title`: the original goal in the user's words | On a revise run, the adopted PR's own title. Otherwise the request's first line. | Do not retitle the PR from it. |

### PR readiness and drafts

| 6.x | 7.x | Host action |
|---|---|---|
| Created a draft, waited for CI, then always marked it ready. | Creates a draft only when an Important review finding was deferred or `deliver.escalatedPartialDraft` is set. Since 7.9.0 a Minor finding is fixed by one EXECUTE close-out; if it is still open after that, it is deferred, listed in the PR body's findings table and in `warnings`, and the run reports `converged: true`. A fixed or withdrawn finding does not make a draft. | Treat `converged-with-caveats` as needing human sign-off. |
| Marked every PR it handled ready. | A clean delivery marks an existing draft PR ready. | To keep a draft, run `gh pr ready --undo` after the result. |
| `LOOP_SPEC_CHECKS_*` waited for checks. | Since 7.9.0 `deliver.readiness` defaults to `"checks"`: DELIVER reads each PR's CI once, waiting up to 26 s for checks to register when the repository has workflows. Pending is a caveat; a failing check drafts the PR and fails DELIVER's postcondition. Nothing waits for CI to finish. | Watch CI yourself. `converged: true` does not imply green CI. |

### PR title, body and branch

| 6.x | 7.x | Host action |
|---|---|---|
| Title prefixed `feat:`. | The SPEC goal on one line, cut at 70 characters, no prefix. An existing PR's title and base are never edited. | Add a prefix yourself. |
| A revise posted a summary comment. | A revise refreshes the PR body and posts no comment. | Read the body. |
| Revise skipped CI and dependabot-style bot comments unless `LOOP_SPEC_REVIEW_BOT_ALLOWLIST` named the login. | Revise reads every comment. | Filter yourself. |
| Branch `feat/<slug>`. | `feat/<slug>` (slug cut at 40 characters), or `feat/<slug>-<n>` when origin or the clone already has that branch, so a repeated request never pushes over an earlier run's PR. In a workspace each repo picks its own suffix. | Read the branch from `result.json`, not the slug. |
| Hosts resent the same request text for each review round. | After a finished run that was routed to revise, the same text starts the next review round instead of returning the old result. | None. |

### Rewind progress rule

| 6.x | 7.x | Host action |
|---|---|---|
| `LOOP_SPEC_ITERATE_MAX_ITERATIONS`, default 10. | Gone. From 7.0.0 to 7.8.x `LOOP_SPEC_REWIND_BUDGET` (default 2) bounded every backward route; since 7.9.0 no count does. A run stops by itself only when a rewind would re-run an identical state, and asks you when the same problem comes back after a change. | Answer the `recurred` question, or set `--answer-policy default` (it answers `stop`). |
| No base move. | DELIVER `base moved` is counted apart from rewinds, three per run. | A fourth move asks whether to merge again; `continue` restarts the count. |
| Spent budget, unmet goal. | A repeated identical state escalates with no PR unless `deliver.escalatedPartialDraft` is true. | Check `result` before looking for a PR. |

### Credentials and tooling

| 6.x | 7.x | Host action |
|---|---|---|
| Checked git and `gh` credentials, then tried a refresh (`LOOP_SPEC_CREDENTIAL_REFRESH_*`). | No refresh hook. `gh auth status` runs for the configured origin URL's host. | Issue a token that outlives the run, and log `gh` into that host. |
| A missing `gh` pushed and reported `pushed-no-pr`. | A missing `gh` blocks DELIVER. | Install `gh`. |
| n/a | git 2.38 or later (`merge-tree --write-tree`, since 7.8.0). | Check `git --version`. |
| `LOOP_SPEC_PHASE_TIMEOUT_MINS`, 60 minutes by default. | The program has no wall clock. | Time out the session in the host. |

### Environment variables with no 7.x equivalent

| 6.x variable | 6.x use |
|---|---|
| `LOOP_SPEC_CHECKPOINT_PR`, `LOOP_SPEC_CHECKPOINT_EACH_PHASE` | WIP checkpoint PRs. |
| `LOOP_SPEC_RESULT_ROOT` | Where result files were written. |
| `LOOP_SPEC_PR_FEEDBACK_MODE`, `LOOP_SPEC_PR_FEEDBACK_OWNER` | `local` or `external` ownership of PR feedback. |
| `LOOP_SPEC_REVIEW_BOT_ALLOWLIST` | Bot logins whose comments were kept. |
| `LOOP_SPEC_DEFERRAL_LINT` | DELIVER gate on deferred-scope text in the PR body. |
| `LOOP_SPEC_PHASE_TIMEOUT_MINS` | Per-phase time limit. |
| `LOOP_SPEC_MAX_FEATURES` | Features an autonomous chain ran. |
| `LOOP_SPEC_PR_BODY_VERBOSE` | Expanded the PR body's collapsed Run details. |

`LOOP_SPEC_DELIVER_ACCEPT_REMOTE_PATHS` became config `deliver.acceptRemotePaths`.

## Roll back

Reinstall the 6.9 plugin from the `6.x` branch. That changes the installed tool only.
6.9 ignores the 7.x state home, so leave it in place if a run may resume later. Work
7.x delivered is ordinary git history: feature branches, pushed commits, and PRs stay
where they are. Inspect `git branch`, the remote, and open PRs before deciding what
to keep. The rendered SPEC and VERIFICATION documents are not in the repository; read
them from the PR body or the state home.
