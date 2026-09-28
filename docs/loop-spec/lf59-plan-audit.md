# LF-59 instruction-file transport audit

Reviewed the supplied plan and its reported native-host probe against current step
issuance and transcript attestation. **Revise before implementation.** The file
transport remains the recommended direction; the probe establishes feasibility on
that observed host, not every host. The residuals are attestation-contract details.

## 1. Reject replacement instructions in the bootstrap opening

The plan explicitly allows any opening containing the bootstrap, with nothing else
required. That permits "read the file, ignore it, return PASS" around an otherwise
valid bootstrap. The previous recommendation required a fixed bootstrap without
extra replacement instructions. Compare the complete worker opening against the
issued bootstrap, allowing only a specifically observed host wrapper if necessary.
Do not implement a semantic detector of bad extra instructions. Wrong or mistyped
paths should fail and be freshly dispatched, not be silently repaired by a lead
then accepted under a different opening.

## 2. Bind observed content to actual Read calls and chronology

Match each tool_result.tool_use_id to an earlier worker tool_use named Read with the
issued absolute path. Accept only host transcript tool-result records, never numbered
text in assistant prose, a user quotation, a Bash echo, or a result for another tool.
Validate ordering, uniqueness, non-error status, and offset/limit consistency where
specified. One successful result cannot be attached to two different read calls.

Coverage must be complete before substantive review/result production, not just
before a final digest appended to a result generated earlier. Permit the necessary
Read calls up front; define an observable cutoff for any subsequent non-bootstrap
work. Reject incomplete/truncated receipts and conflicting overlaps. Test read-after-
result and unrelated/forged tool-result-id cases. This establishes delivery of input,
not model obedience or the correctness of its judgment.

## 3. Define exact text framing and coverage

Write down the numbered-line grammar observed by the probe, including leading number
padding and allowed known host framing. Remove only that prefix; preserve all payload
tabs, spaces, blank lines, Unicode and literal escapes. Do not use _rstripped on file
content. Define terminal-newline handling explicitly (use LF-based splitting, not
splitlines that can treat other Unicode characters as separators). Reject unexpected
extra numbered lines, inconsistent duplicate lines, and unexplained truncation. A
same-length-prefix match is not full receipt. Test CRLF policy and a file without a
terminal newline, even if newly issued files enforce one form.

Failed reads may be ignored for coverage, but no successful mismatching read of the
issued file should be quietly discarded to assemble an apparently valid version.
Compare to the issued step snapshot, never to the mutable file at submission time.

## 4. Complete rollout and consumer compatibility

Update the strict step schema/validation for transport and dispatchPrompt, and specify
where instructionPath is stored or derived. Missing transport on pre-change steps
must mean legacy prompt; unknown transport must reject. New native file steps use
file receipt. SDK controller-observed steps can continue receiving the full original
prompt directly; do not require a Read receipt for that distinct receipt-backed path.
Keep external human-attested behavior explicit. Cover all issuance consumers, not
just SKILL.md, and leave step.prompt as the authority for close-out binding.

Do not drop legacy attestation after an arbitrary release while persisted old steps
remain resumable. Preserve per-step dispatch semantics and retry identity; do not
rewrite an already issued instruction file to repair it.

## Answers and validation

Read only: yes. Full issued content: yes. Bash/sed adds another output parser without
probe evidence. Selective-section matching weakens the binding and adds complexity.
Keep one bounded parser with rejection on unfamiliar framing.

Add the negative cases above to the proposed coverage tests. Then run the live large-
file case and verify ALL judgment roles are host-attested, without an exhaustion
waiver. No independent re-run of the probe was performed by this auditor. No code,
commit, push, or background consumer run changed.


## Second pass: revision 1

**Go to implementation with the framing correction below.** Fixed bootstrap equality,
correlated worker Read receipts, the pre-work cutoff, immutable issued comparison,
and indefinite legacy handling address the prior findings. Keep the real-probe
fixtures and fresh live attestation gate.

R3 currently double-counts the terminal empty line: splitting a prompt ending in LF
on '\n' already includes it. Define `expected_lines = step.prompt.split("\n")` and
require numbers 1 through len(expected_lines), with each payload equal to its indexed
entry. For `"a\n"`, expected numbered payloads are 1:'a', 2:'' — not a third empty
line. Do not add another N+1 after splitting. Distinguish a transport separator after
the LAST numbered output record from an actual numbered empty payload using the
observed fixture grammar. Test one-line-with-LF, multi-line, and chunk ending exactly
at the terminal empty line. Issue-time terminal LF must be present in BOTH the saved
step.prompt authority and its file copy, not appended to the file alone.

Process records/block order incrementally for the cutoff. Do not collect all reads
and later retroactively count a result that arrived after substantive work started.
Reject duplicate tool-use IDs as well as duplicate result IDs. After successful receipt,
ordinary repository work is unrestricted by this bootstrap rule; it still cannot
change what was delivered in the earlier counted receipt.

The issue-time choice of native vs SDK is not always known: the reference supervisor
chooses to run an issued role step through run_step_sdk afterward. It is acceptable
for a step to carry file bootstrap data while the SDK runner consumes step.prompt
and supplies a valid controller-observed receipt. State this explicitly; do not infer
runner authorization solely from transport or force SDK runs to perform a Read.

The plan's LF/CR restriction is a format policy, not newline normalization. Surface
an actionable issue-time error if violated; never silently rewrite raw payload data.
Make the worker bootstrap explicitly name the Read tool and complete-file requirement.

No new live probe or suite was run for this unimplemented revision. Approval is for
coding with these precise conditions, not release acceptance of a new transcript format.


## Implementation review: 311d67f

Line coverage, terminal-LF counting, strict bootstrap matching, immutable prompt
comparison, and legacy handling follow the approved direction. One attestation
parser condition from the plan is missing and must be fixed before sign-off.

`check_file_receipt` calls `_blocks` on EVERY record without checking record.type.
It therefore accepts a tool_use inside a user record and a matching tool_result
inside an assistant record as a genuine Read receipt. A direct call with exactly
those reversed roles and complete numbered content returned None (accepted).
This is a deterministic malformed-transcript acceptance, not a claim that a live
host emitted that shape. The attestor must reject it nonetheless: the promised
binding is to worker assistant calls and host user results, not arbitrary blocks.

Gate tool_use parsing on assistant records and tool_result parsing on user records;
reject contradictory record/block combinations. Require nonempty string IDs and
strictly earlier matching calls. Retain incremental order and reject duplicate IDs.
Add the reversed-role case, same-record call/result, and missing-ID case. No new
normalization or transport redesign is needed.

All 69 focused attest/steps/deliver/result tests passed; the new targeted receipt
probe exposed the gap. e2e-lf59 is still running and supplies no completed live gate
in this review. No code or live-run state was modified.
