# Entry routing evals

For a contributor changing an entry skill's `description` (in `skills/<entry>/SKILL.md`
and its mirror in `skills/loop-spec/program/loop_spec/entries.py`). This directory
measures one thing: which entry skill Claude Code invokes for a given request, with
the whole plugin loaded, so a description change can be checked for both missed
triggers and false triggers before it ships.

Nothing here is a unit test or part of the shipped program. Each run calls the live
model and costs usage.

## Run it

```sh
python3 evals/route_eval.py evals/routing-train.json evals/routing-held-out.json
```

`route_eval.py` builds a throwaway fixture repository in a temp directory, runs
`claude -p <query> --plugin-dir <this checkout>` for each query (`--runs` times,
default 5), and stops each process at its first tool call, before any skill runs. A
`loop-spec:<entry>` Skill call scores as that entry; any other first tool scores as
`none`. A run passes when the result is in the query's `accept` list. `--help` lists
the other options (`--model`, `--plugin-dir`, `--out`).

## The query files

- `routing-train.json`: the set the 7.7.1 `cycle` and `debug` descriptions were
  tuned against. It includes near-misses, such as "verify my AWS credentials" or
  "debug my zsh prompt", that share a word with an entry and must not trigger one.
- `routing-held-out.json`: queries written after that tuning. Change a description
  against the train set, then check it here so the change is not fitted to the
  train set alone.

Each entry is `{"query": ..., "accept": [...]}`. List every entry a careful reader
would accept, and include `"none"` when doing the task without loop-spec is also
right.

## Results so far

Opus 5.5, 2 runs per query, 2026-09-28:

| Descriptions | train | held-out |
|---|---|---|
| 7.7.0 | 38/44 | 10/16 |
| 7.7.1 | 44/44 | 10/16 |

Siblings were never confused with each other, and no near-miss triggered an entry in
either version.

A same-day rerun did not reproduce the 7.7.1 train score. The three queries that
7.7.1 targets (a feature request that asks for a pull request, a named failing test,
a pasted traceback) were run again, pooled over every rerun:

| Descriptions | `cycle` on the feature request | `debug` on the two bug reports |
|---|---|---|
| 7.7.0 | 0/7 | 0/14 |
| 7.7.1 | 4/11 | 3/38 |

The 7.7.1 wording helps, but most of these requests are still done inline. Two runs
per query cannot rank two descriptions, so the default is now 5. Results depend on
what else is installed: another skill with an overlapping description took the
failing-test query in some runs. Descriptions reached the model in full; the skill
listing's character budget did not truncate them.
