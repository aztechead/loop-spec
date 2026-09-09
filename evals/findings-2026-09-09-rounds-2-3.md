# Outcome eval findings, 9 September 2026, rounds two and three

For the maintainer deciding what to fix first after the fixes in
`evals/findings-2026-09-09.md`. Same task (`fastapi-items`: a Python 3.14 FastAPI
service in a container that ships no 3.14 and a uv whose catalog stops at 3.14.0rc2),
same model (sonnet), same driver. Round two ran on plugin commit 318dd61 and was stopped
by hand in PLAN after 20 minutes (its record in `evals/results/20260909-sonnet-fastapi-2/`
measures the kill, not the plugin; disregard it). Round three ran on e994082, which
adds `lib/docs-probe.sh` and the self-scored-gate rule. Record:
`evals/results/20260909-sonnet-fastapi-3/` (ignored). Token sums below are read from
the session and subagent transcripts, priced at the Sonnet 5 rates on the pricing page
(2 / 2.50 / 0.20 / 10 USD per million for input, 5-minute cache write, cache read,
output); the driver could not report a cost because it killed the round first.

## Headline

Round three built the right thing and was killed by the eval itself: accepted 7 of 7,
one rework round, three integrate refusals on the first task, and the driver's
90-minute round timeout fired during VERIFY, so ITERATE and DELIVER never ran and the
record says `delivered: false`. The 6.3.0 changes held for a second time, the
spec critique ran for the first time and caught the release-candidate trap before
PLAN, the probe answered every library version from the registry, and the lead
followed the version rule. What it paid for was context: the lead alone cost an
estimated 37.87 of 53.26 USD, re-reading about 277k tokens on each of 569 calls.

## Numbers

| round | plugin | accepted | delivered | phases reached | lead calls | agents | est. cost USD | minutes |
|---|---|---|---|---|---|---|---|---|
| one (`-fastapi`) | 1d8da4e | yes | yes | all seven | 51 turns | 22 | 24.39 (driver) | 65.5 |
| three (`-fastapi-3`) | e994082 | yes | no (killed in VERIFY) | five | 569 messages | 25 | 53.26 (transcripts) | 90.0 |

Phase wall-clock in round three: SPEC 7 min, DISCUSS 14 (the critique ran), PLAN 30,
EXECUTE 35 (six tasks, one rework, three refusals), VERIFY killed at 4. Cost by
transcript: lead 37.87; the eight implementer and reviewer pairs 0.5 to 1.5 each; the
whole subagent population about 15.

## What held

- Startup was five tool calls: no plugin reading, no `--help` probe, no spec-file
  workaround (findings 1 and 2 of the first record).
- `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` worked: every Agent call returned its report
  in the tool result, zero launch stubs, zero wait turns (finding 4).
- `docs-probe.sh latest` answered fastapi, pydantic, uvicorn, and httpx from PyPI and
  `docs fastapi --topic testing` returned the TestClient section; `latest python
  --ecosystem runtime` answered `unverified` because this container blocks
  endoflife.date, and the lead then ran the web search the rule requires.
- The spec critique ran (self-scored gate rule): nine findings, six major, two of them
  the release-candidate trap and the missing pydantic wheel, five minutes.
- PLAN was one review round: a 23-item union fix-list, one revision, one delta whose
  single `introduced:` line the lint dropped, closed delta-verified by the step. No
  FLAG-only planner round (first record, finding 5).
- `task_start` and `task_end` once per task (finding 6); a refusal named
  `dirty-worktree: ?? uv.lock` (finding 7).
- The implementer upgraded uv before installing 3.14 and got 3.14.7 with a clean
  pydantic import, because the spec critique's finding reached the plan.

## Findings

### 1. Knowing the current version was not enough; the installer stayed stale

SPEC's EVID-007 recorded both facts: 3.14.7 is current per python.org, and this uv can
only install rc2. The constraint it wrote pinned rc2. The plan's critique, not the
lead, moved the uv upgrade ahead of the install. Fixed: the version row of the
directives and SPEC's greenfield lookup say an installer whose catalog lacks the
probe's version is stale and is upgraded first, never worked around with an older
build or a pre-release.

### 2. The dispatch carried neither `model` nor `run_in_background`

`feature.json.models.challenger` was `sonnet` and both challenger calls omitted the
key; on an Opus session the default would have been lost. Fixed: `critique open`
answers `model` (the alias, or null for inherit) and the protocol's call shape copies
it. Offline: `tests/lib/critique-step.test.sh`.

### 3. The lead is the author in DISCUSS, and the snapshot came too late

It fixed SPEC.md, then learned `critique fail` snapshots at fail time, restored the
committed file from git, ran `fail`, and put the fix back: five calls. Fixed:
`findings` snapshots the artifact the challenger read; `fail` no longer depends on
edit order.

### 4. The diff rode in the lead's context twice

`critique revised` returned the whole diff in its JSON and the lead pasted it into
the delta brief. Fixed: `revised` answers `diffPath` and a line count, the brief tells
the challenger to Read the file, and the diff never enters the lead's context.

### 5. A verify command that installs

Task-001's verify command was the whole bootstrap: install uv, install 3.14, create
the venv, install the package, run one test. Against the integration candidate it
failed on the venv that already existed; the lead edited PLAN.md to add `--clear`,
re-extracted `tasks.json`, re-ran the gate, and retried. Fixed:
`lib/phase-exit.sh plan` flags a verify command that carries an install or
environment-creation verb and names `commands.prepare` as the home. Offline:
`bash tests/lib/phase-exit.test.sh`.

### 6. `verify-failed` said only `command-exited-nonzero`

The lead reproduced the command to learn which step failed. Fixed:
`lib/integrate-task.sh` carries the last five lines of the verify output in the
detail.

### 7. A lockfile the plan did not name

The implementer committed exactly the plan's `files[]`, `uv run` had written
`uv.lock`, and integration refused the untracked file. Fixed: `agents/implementer.md`
says a lockfile written next to a manifest the task changed is part of the task, and
PLAN's greenfield scaffold names it.

### 8. My probe reason broke the mode line

`discuss-critique.sh` answered a reason containing `oracle=self`; the driver splits a
mode line on `=` and cut the reason short. Fixed and pinned in
`tests/lib/graph-probes.test.sh`.

### 9. The eval killed a run three phases from done

`ROUND_TIMEOUT_S` was 90 minutes. Fixed: 150 by default, `--round-timeout-mins`
overrides.

### 10. The lead's context is the bill

569 lead messages at about 277k tokens each is 158 million cache-read tokens, 71
percent of the run. The plugin already has the lever: `phase:fresh` returns after each
durable phase, and the driver re-issues the prompt, so each phase's lead starts near
zero. The `cloud` and `supervised` presets set it; the eval's `autonomous` preset does
not. Fixed in the driver: `--phase-fresh` adds the token. Not yet measured: the cost
of the same task under it. That measurement is the next run.

## What the runs did not show

- The `sonnet` challenger default did nothing measurable here: the session model was
  already sonnet. Its effect is an Opus-session measurement.
- The DISCUSS critique's one delta survivor disputed a fact the lead had grounded
  (starlette 1.6.0 lists `httpx2` as an alternative to `httpx`); the stricter-only rule
  carried it into the residue, which is the design, and the residue file is where a
  probe-backed rebuttal belongs.
