# Review of v7 at 635bc7c

Scope: 8154715, f0243ec, 5dcb415, and 635bc7c. Local HEAD matched the reported
revision. Reviewed the example implementations, their tests and documentation, and
checked the committed terminal results against the reported outcomes. No remote
mutation or new live cycle was performed.

**Disposition: request changes in the plugin exemplar; no release sign-off yet.**
The StepQueue and RunWatch separation helps direct testing. The current happy-path
checks pass, but the following behavior needs correction.

## R1 — Non-interactive stdin silently enables automatic answers

Priority: high. `examples/sdk-plugin/run_loop_spec.py:206` selects first-option
answers when either --auto is set OR stdin is not a TTY. The README tells operators
to add --auto for unattended answers. Running without that flag under a service,
with redirected input, or with stdin closed therefore changes question policy and
can approve requirements without the explicit option. Piped answers are ignored.

Select the automatic adapter only with an explicit policy/--auto. Without it, read
available input or stop with an actionable message when no interactive answer can
be obtained. Test adapter selection for --auto false with non-TTY stdin, and true
with either kind of stdin. This finding concerns question policy; the example's
separately documented allow-all tool permission callback is not being changed here.

## R2 — Zero-turn errors are mistaken for harmless resume replay

Priority: medium. `run_loop_spec.py:124` ignores every ResultMessage with num_turns
zero. It never considers is_error or subtype. `run` at line 229 supplies no timeout
unless RunWatch.idle is true. A genuine zero-turn execution failure therefore leaves
the observer waiting without its idle timeout if the connected stream stays open.
Even when the stream closes, the failure is flattened into generic missing-result
resume advice rather than an SDK error.

Direct reproduction with the installed real SDK message type:
ResultMessage(subtype='error_during_execution', is_error=True, num_turns=0, ...)
produced observe=False and idle=False. This demonstrates the state-machine gap;
no live SDK failure was induced. Handle terminal SDK errors explicitly and preserve
the error reason, while retaining the special handling for successful resume replay.
Add zero-turn error and failed-turn-with-background-task cases alongside the existing
successful replay case. Do not rely solely on task completion notices arriving after
an SDK failure to allow the driver to finish.

## R3 — Numeric answers can choose the wrong option or abort the callback

Priority: medium. `run_loop_spec.py:140–141` indexes options[int(raw)-1] without range
validation. With two options, input '0' chooses the last option and '3' raises
IndexError. Both were reproduced against the actual adapter with input patched;
no session was started. Validate 1 <= choice <= len(options) and reprompt invalid
numeric choices. Handle EOF deliberately. The input prompt also currently writes to
stdout, contrary to the documented lead-text-only stream; send it to stderr.
Add focused adapter tests; RunWatch tests do not cover question handling.

## Documentation and evidence notes

- supervisor.py's module docstring still says it has NOT run live and no SDK
  credentials are available. That contradicts the new evidence and README. Update
  the header to describe the recorded supervised SDK run and its actual limitations.
- Committed results agree with the reported terminal outcomes: workspace completed
  with caveats (delivered-draft, converged false); supervisor converged; plugin cycle
  converged; consumer rewind run escalated at ITERATE. This checks stored evidence,
  not current PR contents or independent authentication compatibility.
- The plugin micro run is described in the table, but the committed sdk-plugin
  result.json names PR #10 (the cycle). Archive the micro run's own result/events
  separately if its successful post-refactor run is intended as independently
  reviewable release evidence. Do not imply one terminal file proves both runs.
- LF-53's negative rejection path remains unit-only evidence, as the report correctly
  states. The plain-command success runs do not demonstrate live rejection.

## Remaining gates and next work

Keep LF-54 and LF-55 open pending their plans, audits, implementation and live
validation. In particular, LF-55 is a convergence defect, not just a presentation
issue. Do not count the escalated consumer run as proving remediation works.
Handoff cases 2 (remote rejects push) and 3 (revise on live-7#6) remain unrun.
The successful runs support the documented paths, not blanket 7.0 sign-off.

Validation performed: all four supervisor tests passed under default Python. The
plugin tests initially could not import claude_agent_sdk there; rerunning with the
existing scratchpad/sdkvenv interpreter passed all four tests. Two targeted probes
used real SDK types/adapter code for R2 and R3. No fake runner, full offline cycle,
paid SDK session, or full program suite was used for this review.

Only this local audit file was added. Existing audit files remain intact and
untracked. No implementation, commits, pushes, PR comments, or memory edits.


## Fix verification at 9fc76e9

Reviewed the corrective diff and reran tests: all 11 plugin tests and all four
supervisor tests pass using the existing SDK environment where needed. R1–R3 are
closed for the reported cases: explicit answer policy, zero-turn error termination,
and bounded numeric answers/EOF handling. The supervisor header is corrected and
micro-run evidence is separately archived. No new live session was started by this
auditor; sdkp7 remains the implementing agent's reported evidence. LF-54/55/56 and
the still-running delivery/revise cases are separate from these example fixes.
