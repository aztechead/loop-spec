# Phase 3: execute the task graph

For the lead of a loop-spec run in EXECUTE. The job: get every task in `plan.json`
built, checked, and merged into the feature branch, running independent tasks in
parallel.

Until every task is done:

1. Run `LS task start` with the tasks the `next` line names. Each gets a worktree with
   `prepare` already run, and a `LOOP_SPEC_TASK {...}` brief: `id`, `worktree`,
   `branch`, `from` (the commit it starts at), `task` (its entry in `plan.json`), the
   spec's `goal`, the `criteria` it covers, the repository's `checks`, and `prepared`
   (false when `prepare` failed there).
2. Dispatch one `loop-spec:implementer` agent per started task, all in one message so
   they run in parallel. Its prompt is the task's brief, plus the conventions you found
   (commit style, house rules) and anything else it needs from you. Do a task yourself
   only when it is a few lines or needs context only you have: work in its worktree,
   commit, and `LS task done` it.
3. While implementers run, end your turn with a line saying `LOOP_SPEC_WAITING`; their
   reports resume you.
4. When an implementer reports, read its report and its commits (`git -C <worktree>
   log -p <from>..`, with `from` from the brief). If the work is sound, `LS task done
   T-n`, which merges it and names the next step. If not, send it back with what is
   wrong, or fix it yourself in the worktree, and read it again.
5. If a task turns out wrong or missing, edit `plan.json` (finished tasks stay
   finished) and run `LS status` to validate it again. A task that cannot proceed gets
   `LS task set T-n --status blocked --note "..."`.

`LS task done` refuses uncommitted work and a merge that conflicts; it says which, and
how to fix it. When every task is done, its `next` line says to verify.
