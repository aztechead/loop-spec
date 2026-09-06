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

Per task the driver records: rounds, turns, subagents, cost, wall-clock, tokens, terminal
result, project diff versus artifact diff, an over-build ratio (project lines added over
a hand-written reference), protected files touched, `check.sh` results, and a cheap
judge's match and over-build scores. `check.sh` is the acceptance; the judge is advisory.

## Run it

```bash
LOOP_SPEC_EVAL_LIVE=1 bash evals/run.sh --model haiku --parallel 5 --confirm-spend
LOOP_SPEC_EVAL_LIVE=1 bash evals/run.sh --model sonnet --parallel 5 --confirm-spend
```

Both guards are required. Options: `--tasks a,b`, `--budget-usd N` per task (default
8 haiku, 40 sonnet), `--run-id NAME`, `--preflight-only`, `--measure-only` (re-score an
existing run for free).

Every run starts with a preflight that proves, for a few cents, each condition whose
failure cost a re-run on 6 September: the CLI is signed in, a tool call runs under the
permission mode the driver uses (bypass is refused for root), the judge answers JSON
without tools, the fixtures carry no compiled files, the plugin checkout is committed
(the snapshot and the record's `plugin_commit` must agree), and there is disk. A failed
check refuses to start. Do not edit the driver or the plugin while cycles are in flight:
the running processes keep the old code and the records stop agreeing with the tree. Needs `claude` on PATH with a login, `git`, and
`python3`. There is no `gh` requirement: the fixture has a bare `origin`, so DELIVER
pushes and then stops at the pull-request step. That stop is expected and recorded.

Results land in `evals/results/<run-id>/` as one JSON per task plus `summary.md`.
Commit them; they are the evidence. Workspaces land in `evals/.runs/` and are ignored.

## Read the results

- `accepted` is true only when every `check.sh` line passed and no protected file
  changed. A green cycle with `accepted: false` is the failure this eval exists to find.
- `overbuild_ratio` above about 3x on a trivial task means the cycle wrote far more
  than the ask needed.
- `artifact_diff.added` is the prose the cycle wrote about the change. Compare it with
  `app_diff.added`.
- `rounds` above 1 means the cycle paused and was re-issued; each round reloads context.
- Compare runs of the same task and model across plugin versions before trusting a
  change. Model output varies between runs, so one run is a signal, not a verdict.

## Add a task

Create `evals/tasks/<id>/` with `task.json` (`id`, `size`, `kind`, `prompt`,
`reference_app_lines`, `protected`), a `fixture/` directory that is a complete small
project, and `check.sh` that prints one `CHECK <name> PASS|FAIL [note]` line per
criterion. Keep fixtures small: cost scales with the tree the cycle reads.
