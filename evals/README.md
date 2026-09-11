# Outcome eval

For the maintainer deciding whether a plugin change made cycles better, cheaper, or
worse. This directory runs live cycles against a real model and measures what came out.
It spends money. It is not part of `tests/run-all.sh`, and an agent working in this
repository must not run it unless the user asked for a live eval in the current session.

## Why it exists

The shipped test tree is offline and checks that the machinery behaves. It cannot see
whether a cycle produced the right code at a sane cost. The first live runs recorded in
`docs/loop-spec/supervisor-interface.md` show the gap: one run passed every gate and
committed no application files. This eval is the measurement that gap was missing.

## What it measures

One fixed task set, each task a small fixture repository plus a deterministic
acceptance script:

| task | size | kind | what it catches |
|---|---|---|---|
| `fib-cli` | trivial | greenfield | the recorded baseline task; cost and time for the smallest ask |
| `wc-json` | small | feature on existing code | a cycle that ships artifacts but no code |
| `slugify-bug` | trivial | bug fix with a red test | tampering with the protected test file |
| `todo-due` | medium | multi-file feature | plan, dependencies, new tests |
| `readme-sync` | trivial | docs only | over-building: code written for a docs ask |
| `fastapi-items` | small | greenfield, runtime absent | a Python 3.14 FastAPI service in a container that ships no 3.14: environment recovery, dependency install, one PLAN review round |
| `fastapi-echo` | small | greenfield, runtime absent | the smallest 3.14 FastAPI ask (a GET and a POST that echo a string): how much plugin ceremony the cycle spends on a two-endpoint service |

Per task the driver records: rounds, turns, subagents, cost, wall-clock, tokens, terminal
result, project diff versus artifact diff, an over-build ratio (project lines added over
a hand-written reference), protected files touched, `check.sh` results, and a cheap
over-build ratio (app lines added over `reference_app_lines`). `check.sh` is the acceptance; a judge model that scored every run 3 of 3 was removed.

## Run it

```bash
LOOP_SPEC_EVAL_LIVE=1 bash evals/run.sh --model haiku --parallel 5 --confirm-spend
LOOP_SPEC_EVAL_LIVE=1 bash evals/run.sh --model sonnet --parallel 5 --confirm-spend
```

Both guards are required. Every phase runs in a fresh lead context (one round per phase,
the largest cost lever measured so far). Options: `--round-timeout-mins N` (default 150), `--tasks a,b`, `--budget-usd N` per task (default
8 haiku, 40 sonnet), `--run-id NAME`, `--preflight-only`, `--measure-only` (re-score an
existing run for free).

Every run starts with a preflight that proves, for a few cents, each condition whose
failure cost a re-run on 6 September: the CLI is signed in, a tool call runs under the
permission mode the driver uses (bypass is refused for root), the fixtures carry no compiled files, the plugin checkout is committed
(the snapshot and the record's `plugin_commit` must agree), and there is disk. A failed
check refuses to start. Do not edit the driver or the plugin while cycles are in flight:
the running processes keep the old code and the records stop agreeing with the tree. Needs `claude` on PATH with a login, `git`, and
`python3`. There is no `gh` requirement: the fixture has a bare `origin`, so DELIVER
pushes and then stops at the pull-request step. That stop is expected and recorded.

Run one model at a time. Ten concurrent cycles (haiku and sonnet together) spent the
account's usage window eleven minutes in, every round ended with the CLI's limit text,
and every record read as a plugin failure. The driver now marks such a round `cut_off`
and the summary says so; preflight refuses while the limit is active. A cut-off record
measures the account, not the plugin: re-run it after the window resets.

Results land in `evals/results/<run-id>/` as one JSON per task plus `summary.md`, and
workspaces in `evals/.runs/`. Both are ignored: a run's records are thousands of lines
that belong with the run, not in a code review. Keep them locally, attach them to the
pull request, and write what they showed into a findings document that cites run ids
and record fields; findings documents stay out of the tree.

Launching a single cycle by hand from inside another Claude Code session (an agent
observing a run) meets that session's auto-mode classifier: a prompt that says "push a
branch and open a PR" or "never apply" was refused, and so was every detached form
(`nohup`, `&`, a launcher script). What passed: the harness's own background task,
this driver's flag set, and the ask worded "Deliver the result as a pull request" /
"Validate with plan only; do not run apply". The harness kills that background task
under memory pressure (a 65-minute Opus cycle was), so a long run is safer launched from
a plain terminal.

## Read the results

`tests/oneshot-artifact-budget.test.sh` checks the filled short-route records
against the task files' 50-line and 100-line limits using real local test output.
The driver omits repeated metadata, uses compact heading spacing, and records
an identical command once per verification pass; other rows and the final suite
refer to that result. Output inside evidence fences is preserved. This offline
check measures artifact size, not model cost, latency, or live delivery.

- `accepted` is true only when every `check.sh` line passed and no protected file
  changed. A green cycle with `accepted: false` is the failure this eval exists to find.
- `overbuild_ratio` above about 3x on a trivial task means the cycle wrote far more
  than the ask needed.
- `artifact_diff.added` is the prose the cycle wrote about the change. Compare it with
  `app_diff.added`.
- `rounds` above 1 means the cycle paused and was re-issued; each round reloads context.
- `forged_result` is true when `last-result.json` lacks the `schema` and
  `loopSpecVersion` stamps only `cycle-result.sh` writes: the lead wrote it by hand, and
  its status is untrusted.
- `cut_off` names an account outcome (`usage-limit`) that ended the round; the row is
  not a plugin result.
- Compare runs of the same task and model across plugin versions before trusting a
  change. Model output varies between runs, so one run is a signal, not a verdict.

## Add a task

Create `evals/tasks/<id>/` with `task.json` (`id`, `size`, `kind`, `prompt`,
`reference_app_lines`, `protected`), a `fixture/` directory that is a complete small
project, and `check.sh` that prints one `CHECK <name> PASS|FAIL [note]` line per
criterion. Keep fixtures small: cost scales with the tree the cycle reads.

## REDO rounds in the record

`cycle-driver.sh next` emits a `redo` event into the feature's `events.jsonl` for every
REDO answer, with the bracketed class of each FLAG line. The record sums them as `redo`
(`rounds`, `by_class`, and `events` with phase, attempt, classes, and full FLAG messages) and `format_redo`, the rounds spent on the classes a
driver-written shape makes impossible (`artifact-lint`, `verification-grounding`,
`misplaced`, `oneshot-shape`, `review-triage`, `converged-floor`); the summary prints
the same per task. A live bug-fix run on the short route is at its done condition for
`port audit 3` N1 when `format_redo` is zero.

`first_turn_input_tokens` is the context the first assistant turn read (cache creation,
cache read, and input tokens from the CLI's transcript of the session): what every later
turn re-reads, and the number the bill is made of once the format rounds are gone. The
summary prints it per task. `bar.rounds` (1 for both tasks) is the round figure the
verdict reads.
