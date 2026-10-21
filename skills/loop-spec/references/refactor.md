# A refactor run

For the lead of a loop-spec run of kind `refactor`: a restructuring that keeps behavior.
Read it before the spec; it changes the workflow in SKILL.md as follows, and everything
else stands.

- **Spec:** criteria that pass both at the base and at the head, each with a `check`.
  `LS verify --base` records the base result, and deliver refuses a refactor run whose
  base record has no passing criterion. For a migration, add a criterion that counts the
  old usages and must reach 0; it fails at the base, which is allowed.
- **Plan:** when the same edit repeats across files, make a codemod or script its own
  task. Migrate the callers and delete the old API in the same run.
- **Verify:** run `LS verify --base` before execute, then verify at the head.
- **Iterate:** the reviewer checks that behavior is preserved. Tests may move but not
  weaken.
