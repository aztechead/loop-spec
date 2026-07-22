# Verification grounding - post-change evidence contract

Every route applies this contract after its final edit, regardless of effort level.
A passing command proves only that the command passed. It does not prove that the
change implements the requested behavior or fits the repository.

## Grounding gate

Before behavioral validation:

1. Inspect the final diff, then re-read every changed file in its final state.
2. Read the nearest affected caller, test, configuration, interface, or documented
   contract. Use Graphify queries too when the full cycle has a graph, but never use a
   graph as a substitute for reading the current files.
3. For every done/acceptance criterion, record repository evidence as `file:line`
   references that show where the behavior is implemented and where it integrates with
   the existing system. When no separate integration site exists, say why instead of
   inventing one.
4. Re-probe any external-system premise affected by the implementation and cite its
   `EVID-NNN`; micro work may record the command and observed output inline instead.

An unsupported assumption, stale pre-edit read, diff-only review, or generic statement
such as "matches existing patterns" fails this gate. Correct the implementation or
escalate it, then repeat the grounding gate after the new final edit.

## Validation gate

Only after grounding passes, run the strongest applicable behavioral command for every
criterion and capture the command output and exit status. Run the project suite, lint,
build, or typecheck as applicable. If there is genuinely no behavioral runner, use the
strongest static check available (at minimum `git diff --check`) and state the limitation.

Grounding evidence and validation evidence are both mandatory and non-interchangeable:

- Repository reads cannot substitute for an executed validation command.
- A green test, lint, build, or typecheck cannot substitute for repository grounding.
- Evidence gathered before the final edit is stale and must be gathered again.

Any failed gate routes back to implementation/remediation. A route may report a failed
or blocked outcome, but it may not report verified/converged until both gates pass.
