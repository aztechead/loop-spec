# LF-62 plan audit

Reviewed the handoff plan against controller.py and questions.py at the supplied
c68fae2-era implementation. **Go to implementation with the persistence conditions
below.** The missing policy call is confirmed. Centralizing default-policy resolution
is preferable to adding another caller-specific resolve_policy_answer call.

## Accepted direction

Have every normal question use the same default-policy path; remove the two explicit
controller calls so a policy answer cannot be attempted twice. Preserve the current
policy semantics: only policy=default plus a non-null offered default permits an
automatic answer. Missing recommendations/defaults and LF-60 refusals stay open.
Policy disabled/manual must leave even a recommended critic question unanswered.

Use the existing critic answer handler for both branches: spec gap takes the backward
route and its budget checks; a nonempty rejection reason dispositions the findings
through P7. No alternative auto-disposition path belongs in questions.ask. Keeping
questions.py responsible for question facts/policy and the controller responsible for
phase routing is appropriate.

## Implementation conditions

1. **Preserve save=False semantics explicitly.** resolve_policy_answer calls answer,
   which saves, and then saves policyAnswered separately. Calling that unchanged from
   ask(save=False) can violate the caller's atomic-linking contract. Today's refusal
   default is None, so it does not trigger the bug, but a docstring is not enforcement.
   Either propagate deferred persistence through answer/policy resolution, or reject
   unsupported save=False plus auto-answerable-default combinations before side
   effects. Do not silently skip policy for deferred-save questions: that recreates
   this defect for the next caller. Keep the current LF-60 no-default path unchanged.

2. **Link the critic question and its answer recoverably.** ask currently saves before
   returning its id; the critic assigns criticQuestionId only afterward. Adding an
   automatic answer inside ask creates a crash point with an answered question but
   no owning phase link. Save the link and question/answer state together using the
   deferred-persistence mechanism, or recover the exact question by an explicit
   critic purpose/attempt identity on resume. Do not create a second question or
   silently reuse a different question from the same attempt. Keep policyAnswered
   provenance consistent with the recorded answer, including on restart.

3. **Do not treat the earlier hand-written-answer unit test as proof of routing.**
   Exercise the real second-pass question-creation path under policy=default, then
   consume its actual recorded answer through continue_run. A helper-only test of
   _critic_default or _close_critic_rejections cannot reproduce this defect.

## Tests and evidence

The four proposed tests are appropriate. Add manual-policy-with-default stays open;
no-default refusal under default policy stays open with no extra save; policy answer
and policyAnswered recorded once; and interruption between question creation and
phase linkage followed by resume. Verify the spec-gap route spends its normal budget
and rejection reasons remain attached to the intended findings. These are deterministic
module tests; no fake cycle runner is needed.

The operator's manual rejection in e2e-lf59c should be recorded as human/operator
answered, with its actual reason. That run may still validate LF-61's chunked review,
but cannot validate automatic critic recommendation handling. Likewise, e2e-lf54
with no surviving critic finding never exercised this gate. A fresh live run counts
only when an actual second-pass Critical produces a default that policy consumes
without an operator answer; model variability means a clean PLAN is inconclusive.

No code, running session, commits, remote state or evidence files changed. This was
source/plan review, not a new suite or live run. Only this local audit file was added.


## Implementation review: 788c6de

The commit centralizes policy application in ask, propagates deferred state persistence
through answer/resolution, and saves critic judgment/question/answer/link together.
No new blocking finding in this diff. Focused question and PlanCriticTests passed
(the tool result records the count); these exercise actual second-pass routing,
including the crash-before-linking case. No new live validation was performed.

Precision: save=False defers STATE persistence, not every filesystem side effect.
ask/answer still write question.json/answer.json, and ask emits an event/marker before
the state commit. The state is authoritative and the tested recovery regenerates
the question; do not claim nothing reaches disk or that the event ledger is an
atomic transaction with that state write. This wording clarification is not a
request to broaden LF-62 into event-store redesign.
