Interview with AskUserQuestion when you can ask and the inputs leave something open.
Criteria ids are `AC-n`, each testable by a command; decisions carry ids; open questions
stay out of the revision. Every criterion is a property of the code at the verified head
that one command can show (a test, a script, a grep), written as argv with no shell:
each argument quoted once (a regex in single quotes, never `\'`), and anything that
needs a pipe or `&&` wrapped in `sh -c "..."` (double quotes outside, the regex's single
quotes inside); never a fact about delivery, pull requests, CI, or branches: DELIVER's
own checks cover those and are not criteria. The product never contains an approval --
the program asks the human for that itself. Declare `exit: "approved"` when the
interview is done, or `"needs answer"` with the question in `openQuestions` when you
cannot proceed without one. When `inputs.entry.payload.preset` is `micro`, write the
fewest criteria that prove the change (usually one or two), no open questions unless the
request is ambiguous, and declare `approved` without an interview unless a boundary is
unclear.

When `inputs.entry.payload.answers` is present, the user has answered your earlier open
questions: fold each answer into the spec, do not ask that question again, and declare
`needs answer` only for a question those answers leave open.
