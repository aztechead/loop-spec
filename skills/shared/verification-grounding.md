# Verification grounding - post-change evidence contract

Every route applies this contract after its final edit, regardless of effort level.
A passing command proves only that the command passed. It does not prove that the
change implements the requested behavior or fits the repository.

## Grounding gate

Before behavioral validation:

1. Inspect the final diff, then re-read every changed file in its final state.
2. Read the nearest affected caller, test, configuration, interface, or documented
   contract. Search and read as widely as you need, but never use a
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

Derive each criterion's expected observables from SPEC, including its user-facing
behavior and binding decisions. PLAN's commands and existing tests are candidate
checks, not the definition of success. Read their assertions: each required part of
a compound criterion needs evidence. Strengthen a focused probe when the supplied
command can pass while the required behavior is wrong.

For a structured or generated contract (schemas, manifests, configuration, exported
interfaces), inspect the actual representation its consumer receives. Assert the
required fields, types, constraints, relationships, and status/error behavior;
resolve references when present. Runtime values or source declarations do not prove
that an exported contract describes them. Existence, truthiness, a nonempty object,
or a matching name proves only presence. Printing an artifact is not an asserting
probe: execute checks of its required properties before claiming PASS. Do not invent constraints or require a
particular representation unless SPEC requires it.

Check the probe's sensitivity to a concrete contract violation: could a still-present
artifact with a required nested field missing or mistyped pass? If so, strengthen
the assertions. A small in-memory counterexample can test the predicate without
editing the implementation or tracked tests. Record the required observable, actual
observation, and asserting command in the criterion's evidence. A demonstrated
mismatch is a failed criterion, not an advisory coverage improvement.

Only after grounding passes, run the adequate behavioral command for every criterion
and capture the command output and exit status. Run the project suite, lint,
build, or typecheck as applicable. If there is genuinely no behavioral runner, use the
strongest static check available (at minimum `git diff --check`) and state the limitation.

Grounding evidence and validation evidence are both mandatory and non-interchangeable:

- Repository reads cannot substitute for an executed validation command.
- A green test, lint, build, or typecheck cannot substitute for repository grounding.
- Evidence gathered before the final edit is stale and must be gathered again.

Any failed gate routes back to implementation/remediation. A route may report a failed
or blocked outcome, but it may not report verified/converged until both gates pass.
