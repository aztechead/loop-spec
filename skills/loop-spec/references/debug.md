# A debug run

For the lead of a loop-spec run of kind `debug`: a reported failure to reproduce and
fix. Read it before the spec; it changes the workflow in SKILL.md as follows, and
everything else stands.

- **Spec:** put the failing command in a criterion's `check`, and confirm it fails
  where the run started: `LS verify --base` runs every check at the base and records
  nothing.
- **Execute:** find the root cause before changing anything, and fix it there, not
  where the symptom shows.
- **Tests:** keep a regression test that fails without the fix.
- **Verify:** the criterion that failed at the base now passes at the feature head.
