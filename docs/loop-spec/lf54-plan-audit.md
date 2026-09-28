# LF-54 plan audit

Reviewed at 9fc76e9 on 2026-09-22. Scope: the supplied plan-lf54.md, critic issue/cache
and question handling, and baseline comparison. Treat the plan's stated user decisions
D1/D2 as settled. No implementation or memory changes.

**Disposition: go to implementation with the following corrections incorporated.**
Prompt plus baseline facts and an explicit-policy question default are consistent
with the chosen design. Do not implement the literal plan's incomplete cache claim.

## Required corrections

1. **Include the facts the comparator actually uses.** The proposed failingAtBase
   contains only failureIdentities. Unknown runners use fingerprints, so the critic
   would otherwise see an empty list for a real failing baseline. Include fingerprints,
   errorClass, testsRan, repo/base SHA and the task's comparison mode (normal,
   featureAdded, mustFlip). Distinguish missing, no-baseline, and an incomplete run.
   Explain normal no-new-failure comparison, mustFlip's required fail-to-pass change,
   and featureAdded's successful meaningful first run. "Exit status alone never
   decides" is not universal: mustFlip and featureAdded explicitly inspect it.
   Also distinguish regression evidence from proof of the task's claimed behavior:
   a suite's unchanged failure set does not itself prove that a particular file
   stayed untouched. The critic may still question an inadequate command for that
   reason, even though nonzero exit alone is not a valid objection.

2. **Invalidate actual critic reuse on changed inputs.** Adding baseline to the
   issued step's inputsDigest does not itself cause reissue. The controller returns
   an accepted critic by planRevision, and _critic_submission reuses a submitted
   step by criticStepRevision. Both checks ignore baseline/spec input changes.
   Store and compare the relevant input identity in both paths, including missing
   legacy identities. Include plan, spec and the baseline facts actually presented.
   Decide how a fresh identity affects the existing two-pass accounting without
   resetting it on every call. Test unchanged plan + changed baseline facts and
   unchanged plan + changed requirements: neither may reuse the old judgment.

3. **Keep custom critics and in-flight records usable in a patch release.** Prefer
   optional recommendation in the public schema for 7.0.x, with the built-in prompt
   requiring it. A missing recommendation on any open Critical must preserve a null
   default/manual decision, unless another finding explicitly recommends spec gap.
   Never invent a reject reason for a legacy/custom result. If required schema is
   deliberately chosen instead, document the breaking custom-role migration and
   handle existing accepted/submitted findings without KeyError. Do not silently
   weaken a missing recommendation into automatic rejection.

## Answers to the three questions

- One explicit spec-gap recommendation should take precedence; there is one phase
  route and one answer today. Retain each finding's individual recommendation and
  reason in the question payload for inspection.
- Yes, include recommendations in first-pass remediation. They advise the planner;
  they do not close the finding before the policy/operator answer is recorded.
- Prefer the backward-compatible optional-field approach above for 7.0.3. New built-in
  output should supply recommendations; old/custom output should pause safely.

## Verification expected

Deterministic cases: parsed failures; fingerprint-only failures; no-baseline and
incomplete baseline; mustFlip facts; input-identity invalidation; mixed recommendations;
all-reject joined reasons; missing legacy recommendation; policy answer provenance and
P7 closure. Exercise policy helpers directly, not a fake-runner cycle. Record a live
known-failing-suite run afterward. The live judgment must test whether the command
measures its task, not merely whether it tolerates the pre-existing failure.

No unit suite or live run was performed for this unimplemented plan. Source inspection
establishes the cache mismatch and omitted comparison facts. Only this local audit
file was written. No commits, pushes, PR comments, or running consumer changes.


## Implementation review: 41e74e5

The commit addresses the audit conditions: baseline facts include fallback
fingerprints, completion/error information and comparison mode; both submitted and
accepted critic reuse check the new input identity; recommendations remain optional
with a safe missing-recommendation default. The prompt distinguishes regression
comparison from proof of the claimed behavior. No new blocking finding in this diff.

Validation: five CriticFactsAndDefaultTests, four controller tests selected by
`-k critic` (one overlaps that class), and all 15 role tests passed. These are focused
deterministic checks, not a full-suite or live-run result. The known-failing-repo
live validation remains pending; this review does not close that gate. No source,
commits, pushes, or running consumer worktrees changed.
