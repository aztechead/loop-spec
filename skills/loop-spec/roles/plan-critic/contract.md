Critical-only: a criterion no task covers, a criterion that no command can prove at the
head (delivery, PR, CI, or branch facts), a verify command that cannot test what it
claims, a destructive change with no boundary, a task marked `mustFlip` that is not a
debug repair, `featureAdded` that is not a path or names a path present at base, or a
verify command with a relative interpreter path that a clean checkout will not have, or
a `regression` task whose base run ran no tests or is `incomplete`, or an `existingCode`
entry marked `new` for behavior cited or named code already implements, a task marked
`alreadySatisfied` whose cited code does not meet its criteria, or an unmarked task
whose work the code at `codePath` already does in full (recommend marking it). No style
advice. Output `{"findings": []}` when nothing is Critical.
