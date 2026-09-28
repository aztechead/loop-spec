# LF-56 fix-plan audit

Reviewed the supplied plan at 41e74e5, compose_prompt and native transcript matching.
The supplied seven-dispatch diagnosis is the implementing agent's evidence; this
audit did not independently re-read all seven transcripts or run a model session.

**Disposition: go for the section-boundary fix; do not implement the global collapse
as written.** No attestation relaxation is needed. This is an implementation direction
with a narrow correction, not a claim that partial-delivery validation has passed.

## What the source supports

compose_prompt concatenates raw string input bodies with two newlines. A diff ending
in a newline therefore produces three newlines before the next input header. The
existing attestor normalizes trailing whitespace per line, but preserves the count
of empty lines, so the reported collapse in the opening explains rejection.

The observations support "all seven inspected dispatches failed this way," not
"such prompts can never attest" or a guarantee that future hosts always collapse
newlines. Neither the model nor host responsible for the mutation has been isolated.

## Required scope correction

Remove the accidental extra newline at composer-owned section boundaries. For a
raw diff section, trim its framing trailing newlines before adding the separator.
Keep interior input/role content intact. Do not run a global regex over the finished
prompt: compose_prompt accepts arbitrary raw strings and custom role bodies, which
can contain exact expected output, source code, multiline literals or fixtures where
blank-line count matters. A local string probe confirms the proposed regex changes
an exact-output fenced fixture with two blank lines. JSON escaping protects dict/list
inputs, not these raw string bodies. The claim that blank runs never carry meaningful
content is therefore too broad.

If a raw exact-text field must preserve its terminal newlines too, use a lossless
representation with explicit framing/escaping instead of silently trimming its data.
Do not expand this patch into general whitespace normalization of all role inputs.

## Answers to the two questions

1. **Reissue old steps; do not tolerate a rewritten old prompt.** Preserve the old
   step, transcript and refusal as evidence. Retire/cancel with the existing worker
   termination safeguards, then issue a fresh step id, newly composed prompt and
   result path, and obtain a fresh review. Do not overwrite step.json under the old
   id, accept its old output against the new prompt, or retroactively attest it.
   Specify the supported recovery action for exhausted in-flight review attempts;
   a new program binary alone will not rewrite their persisted prompts. A fresh
   run is acceptable for the planned live reproduction.
2. **Do not collapse whitespace-only diff lines.** A leading space is a unified-diff
   context marker; preserve it and other leading indentation. The existing attestor's
   per-line rstrip behavior is not authority to rewrite the dispatched diff body.
   No supplied evidence establishes a need for broader normalization.

## Tests and live acceptance

Test a diff ending in a newline followed by probes: exactly one blank separator;
unchanged diff context/add/delete lines; preserved interior multi-blank literal data
and whitespace-only context lines. Exercise check_transcript against the newly issued
prompt and unchanged opening, and verify an actually altered interior input remains
rejected. Avoid only testing normalization against itself.

The live rerun must show host-attested review and reach DELIVER. Reaching DELIVER
alone does not complete handoff test 2: also demonstrate the intended textutil push
failure, correct partial-delivery result/backlog, and preservation of the successful
repo's delivery, then restore its push URL. The earlier run did not exercise this
case and must remain recorded as blocked by review attestation.

Only this local audit file was added. No source/attestation changes, commits, pushes,
consumer repo configuration, or running plugin worktree were touched.


## Implementation review: b2c3379

The production change follows the approved narrow direction: strip trailing newline
framing from string input bodies, preserve interior blank lines and diff prefixes,
and leave attestation unchanged. The contract documents fresh-run recovery for old
persisted prompts. No new production-code blocker found in this diff.

**Validation defect:** the new
`test_composed_review_prompt_with_a_diff_before_probes_attests_and_an_altered_input_does_not`
in test_attest.py is indented under `if __name__ == "__main__":`, after unittest.main(),
not inside AttestorTests. Discovery does not define or run it; direct execution also
cannot discover it as a TestCase method. Move it into AttestorTests (it uses that
class's helpers), then verify its name appears in verbose discovery and passes.
Do not count it as a second exercised regression test in the current suite result.

I ran tests.test_roles and tests.test_attest with verbose unittest output: 26 tests
passed, including the new section-boundary role test, but excluding the misplaced
attestation test. This independently confirms the discovery gap. No full suite or
live cycle was run by this auditor. e2e-t2b remains in progress and is not counted as
successful partial-delivery evidence yet. No background processes or consumer repo
configuration were changed.
