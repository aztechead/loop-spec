# LF-61 plan audit

Reviewed the handoff plan dated 2026-09-22 against the current issuance/receipt
contract. **Go to implementation with the conditions below; run P1/P2 before freezing
the constants, and retain the full live chunked-read gate.** This approves a bounded
read-scheduling fix, not a complete large-input compatibility claim.

## What is sound

Program-generated contiguous ranges, total line count, a byte budget rather than a
fixed line count, and unchanged full-coverage attestation directly address the failed
run. The host's suggested page is demonstrably not a safe schedule for variable-size
lines. Counting the terminal empty line exactly once matches LF-59. Deferred file
splitting and separate artifact transport need not enter this patch.

## Implementation conditions

1. **16 KB is a provisional engineering budget, not a proven universal token bound.**
   A tokenizer over byte sequences can motivate it, but the host's Read limit may
   include framing, metadata, tokenization details or additional limits. Three sample
   reads cannot prove every input has tokens <= rendered bytes. Describe P2 as empirical
   validation of margin on the tested host. Success without a truncation notice may
   reveal no exact count; verify complete returned line coverage in every probe.
   Include line-number framing and account for observed padding. Keep headroom and
   the adaptive fallback rather than promising every scheduled call must fit.

2. **Make recovery strictly progressing and finite.** A short successful read resumes
   at its last returned line + 1, bounded by the ORIGINAL scheduled range end. An
   over-limit read uses max(1, floor(remaining_lines/2)); after success continue through
   the rest of that original range. If a one-line read errors, yields zero lines, or
   truncates a line, stop and report that receipt cannot be completed—never retry
   offset/limit forever or count a partial line. Full coverage remains mandatory.
   Add a one-line-at-runtime failure case, not only issue-time oversized-line rejection.

3. **Do not call every issue-time budget rejection physically impossible.** A 16,001-
   byte line may be readable under a 25,000-token host limit. The refusal means it
   exceeds the supported conservative line budget (or an observed host line cap).
   Say which constraint failed and what input needs shortening. Do not truncate,
   summarize, or silently split source lines to make the attestor happy.

4. **Preparation must be side-effect safe.** Validate/schedule the final prompt with
   trailer and terminal LF before publishing the step record or adding steps.open.
   Write the instruction copy and schema-valid schedule consistently. Error paths
   must not leave an apparently dispatchable partial step. Include range ordering,
   positive offsets/limits, exact coverage, multibyte UTF-8 and boundary-sized lines
   in deterministic tests. Attestation still proves content receipt, not obedience
   to the suggested schedule.

5. **Bootstrap and fixture precision.** An interpolated absolute path can contain
   Unicode; do not assert the entire bootstrap is ASCII unless the program actually
   guarantees an ASCII path. Preserve the correct path, using the same equality rule
   as LF-59. Keep the schedule compact and list each range unambiguously. Inspect the
   saved failing fixture for secrets before committing it; a synthetic deterministic
   fixture is fine for unit behavior, but retain the actual failed artifact privately
   for the live comparison. Its original provenance/commit must remain recorded.

P1/P2 do not require a full cycle or changes to the production attestor. Record their
actual Read output shapes, caps and coverage. If they contradict the candidate budget
or line assumptions, revise those constants before implementation proceeds further.

## Live acceptance and release order

The listed e2e-lf59c criteria are appropriate: real multiple-Read review receipts,
all judgment steps attested, no waivers/refusals, and an actual terminal result. State
its outcome explicitly; a non-attestation defect ending the run is not convergence
proof. Then run LF-60's deliberate wrong-opening refusal/explicit opt-in case on the
same build. Do not rewrite a persisted old step to apply the new schedule.

Recommendation: finish these fixes/live gates before the next push for review on
PR #109, unless the operator explicitly wants an intermediate checkpoint. A push is
not a release, but the current local stack is close enough to a coherent evidence
update that one reviewed push is clearer. No push was made by this auditor.

This audit read the plan and relevant source; it did not perform the two host probes,
a fresh paid/live run, or a full suite. Only this local audit file was written.
