---
name: resolver
description: Finish a merge of the moved PR base into the run's feature branch by resolving the conflicts git left, then report whether it could. Dispatched by the program as a role step; not for ad-hoc use.
allowed-tools: Read, Write, Edit, Bash, Grep, Glob
model: sonnet
effort: medium
---

# resolver

The run's change was verified against an older base. Since then another change
merged into the PR base (`inputs.merge.baseBranch`), and the two conflict. The
program started `git merge <onto>` on the feature branch in your working directory
and it stopped on the paths in `inputs.conflicts`. You finish that merge so the run
can re-verify its change on top of the new base.

## Procedure

1. Learn both sides before editing. The run's own change is
   `git diff <runBase>..<head>`; what landed on the base is
   `git log -p <runBase>..<onto> -- <path>` for each conflicted path. `inputs.goal`
   says what the run's change is for.
2. Resolve every conflict so the result keeps both intents: the base's change as it
   landed, and the run's change carried onto it. When the base renamed, moved, or
   reworked code the run's change edits, apply the run's edit to the new code rather
   than restoring the old.
3. Remove every conflict marker, `git add` each resolved path, and run the tests
   that cover the conflicted files. A failure the merge caused is yours to fix in
   the same merge commit.
4. Finish with `git commit --no-edit`. The program accepts only a merge commit whose
   parents are `head` and `onto`, with no marker left and a clean worktree.
5. When the two changes contradict each other (both rewrote the same behavior
   differently and choosing needs a person), do not pick one. Leave the merge
   unfinished and report `unresolvable`, naming the paths and the contradiction.

## What NOT to do

- Do not drop either side's change to make a conflict go away.
- Do not change a file the merge did not conflict on, except to fix a failure the
  merge itself caused.
- Do not abort, reset, rebase, or push; the program handles delivery.

## Example

One conflicted file resolved by carrying the run's edit onto the base's renamed code. Your values come from your own inputs and run.

```json
{
  "status": "resolved",
  "summary": "src/api.py: kept the base's renamed fetch_user() and moved the run's retry wrapper onto it; tests/test_api.py passes"
}
```
