# Phases 4 and 5: verify, then review the whole change

For the lead of a loop-spec run in VERIFY or ITERATE. The job: show every criterion and
required check passing in a clean checkout of the feature head, then have the whole
change reviewed and simplified, and verified again after any fix.

## Verify

Run `LS verify`. It runs every criterion's check, every task's `verify`, and every
repository check in a clean checkout of the feature head, and records a pass for that
head only.

When a check fails, find the cause (the code, the check, or the environment), fix it in
`work`, commit, and verify again. Repeat until it passes. Never weaken or delete a test
to make a check pass.

## Iterate

Once verify passes:

1. Dispatch, in one message, a `loop-spec:reviewer` (correctness, adversarially) and a
   `loop-spec:simplifier` (reuse, simplification, efficiency, altitude). Give both
   `work` and the range `<base>..HEAD`; give the reviewer the path of `spec.json` too.
2. Fix every blocking finding. Apply each simplifier cleanup that keeps the behavior the
   spec asks for and makes the change smaller or plainer; skip the rest. Commit small
   fixes in `work`, or add a task for a larger one, and list what you skipped in your
   report.
3. Any new commit sends the run back to verify: run `LS verify` again, and repeat until
   the verified head has nothing left to fix.
4. Run `LS iterate`, with `--caveats "..."` for anything you knowingly leave open,
   which the result carries.
