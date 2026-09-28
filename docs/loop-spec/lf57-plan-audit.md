# LF-57 audit and a simpler prompt transport

Reviewed at 48de8f0. Scope: supplied plan-lf57.md, compose_prompt, step submission,
native attestation, and close-out proof binding. No source or running-run changes.

**LF-57 disposition: go for the narrow rendering patch.** Use one render_json helper
for prompt input/schema rendering and _no_change_proof. Keep transcript attestation
unchanged, and preserve literal backslash-u text: ensure_ascii=False renders a real
em dash directly but must not decode an actual string containing the six characters
\u2014. Add both cases, nested inputs, accented/non-BMP text, and the close-out binding
check to the deterministic tests. Keep canonical input/result digests unchanged unless
their data changes; this patch concerns presentation. Recover persisted old steps with
fresh issuance/run, not retroactive acceptance of a modified opening.

The evidence supports the inspected failures, not a universal claim that non-ASCII
prompts can never attest. A correctly copied escaped prompt still could. The helper
fix removes the observed temptation to decode it during copying; it does not make
model-mediated copying a reliable transport.

## Recommendation: stop asking a model to copy the prompt

LF-56 and LF-57 share a design problem: the program writes precise input, then the
lead reconstructs that input as a large Agent argument, then the program checks its
fidelity. Each harmless-looking rewrite consumes a model dispatch and minutes of
work. Adding more normalization rules will continue to chase this mismatch and can
change meaningful instructions or code.

Prefer a program-written per-step prompt file and a short fixed bootstrap:

    Execute loop-spec step <step-id>.
    Read the complete instruction file at <absolute-path> before working.
    Follow that file and write the result to its specified path.

The existing step record remains the authority for prompt bytes, role/method/input
identity, repository/range, result path and issuance time. The additional file is
only a worker-readable representation of that already composed prompt; it need not
be a second contract, a new graph, or a new runner. Lead dispatches a small instruction
and path; worker reads the authoritative content using a tool. Unicode, JSON escapes,
blank lines and code indentation no longer pass through a model's verbatim copy.

Native subagents already support file-reading tools and custom instructions; this
uses existing capabilities, not a claimed Agent prompt-file parameter. Official
reference: https://code.claude.com/docs/en/sub-agents . The documentation supports
those capabilities; it does NOT establish that the current host transcript exposes
the complete file-read result needed below. That is the feasibility probe.

## Attestation must follow the new transport

This is an intentional evidence-contract change, not a one-line relaxation of
check_transcript. A digest echoed by the worker proves nothing about whether the
worker received the input. A read call's filename alone is also insufficient.

Keep the new invariant small and explicit:

- A fresh worker receives the expected fixed bootstrap, step id and path; reject
  extra replacement instructions rather than accepting any opening mentioning an id.
- Its host transcript records a successful read delivering the entire instruction
  payload, associated with that tool call and that worker, before the review result.
  Verify observed content against the controller's saved prompt, including handling
  known tool framing. Reject partial/truncated reads unless complete ordered chunks
  can be established. Do not trust a later worker assertion that it read the file.
- Controller records must detect mutation of the worker-readable copy. Check content
  delivered at read time against the issued bytes; hashing whatever is on disk only
  at submission time is insufficient. Use per-attempt paths; do not overwrite inputs
  for an already issued step. This assumes the existing controller/state trust model,
  not a new claim of OS isolation between same-user processes.
- Keep the current fresh-session/timestamp and final result-digest checks. Bind the
  same repo, reviewed range, role/method and input identity as before.

What this establishes is delivery of the correct instructions to the reviewing worker,
not proof that the model obeyed or understood them. The current exact-opening test
cannot prove obedience either. No stronger assurance claim is needed.

Probe one real native dispatch containing Unicode, literal escapes, multiline JSON,
blank lines and a diff. Inspect full-read visibility, truncation, and permission
behavior before adopting the path. Include a changed-file payload, partial read and
wrong-step negative case in deterministic transcript-parser checks. If the host
cannot expose receipt reliably, keep this path unaccepted; do not pretend an echoed
hash fixes it. A controller-owned SDK dispatch already transports prompt bytes
without a copying lead and remains an explicit alternative, not an automatic switch
for interactive users. No hooks are required for the proposed file/read design.

This is simpler for the lead and worker. It does add one bounded attestor rule; if
that rule needs many heuristics for tool-output reconstruction, prefer the existing
controller-owned runner for deployments needing that assurance rather than building
a large transcript-normalization framework. Fixed custom role agents can reduce
boilerplate but do not by themselves prove receipt of dynamic diff/input content.

## Separate issue: exhausting retries currently waives attestation

steps.submit increments attestationAttempts, re-dispatches, then appends an
attestationWaivers entry and accepts an unattested submission when attempts run out.
result.py exposes those entries under weakenedAssurance. EXECUTE E6 can still reject
unattested review. ITERATE's boundary has no corresponding judge-evidence acceptance
gate; it can progress with the waived judgment, as the reported LF-54 run did.

Recording reduced assurance is useful, but retry exhaustion is not operator consent
and does not improve evidence. Recommend one shared judgment-evidence acceptance
rule for the critic, code reviewer and ITERATE judge: either the required evidence
exists, or the operator explicitly chose a documented weaker policy. Exhaustion
should pause/escalate with a recovery action, not silently choose that policy. Keep
this separate from LF-57's rendering patch so each behavior is reviewable.

Do not count an unattested-but-delivered run as proof that LF-57 or the transport
problem is solved. It can still provide evidence about delivery behavior if its
weakened assurance is stated alongside the result.

## Suggested order

1. Land LF-57's narrow helper/rendering fix and deterministic tests; record fresh live
   attestation evidence when available. No broad Unicode normalization or escape
   decoding in the matcher.
2. Probe the instruction-file transport on the native host. Write a small reviewed
   contract change only if full receipt is observable. Native remains a first-class
   path; no default SDK switch is implied.
3. Align exhaustion behavior across judgment roles under an explicit assurance
   policy. Keep the current background run intact and record its actual evidence.

The simpler long-term contract is "this worker received this issued instruction
artifact and produced this result," not "the lead successfully retyped ten thousand
characters." LF-57 is a reasonable immediate patch, not a complete transport fix.

This audit is source/design review plus official capability documentation. No fresh
model session, full suite, or independent recheck of the reported three transcripts
was performed. Only this local audit file was written; nothing committed or pushed.


## Implementation check: 36ae40e

The shared jsonio.render_json implementation and its three consumers match the
approved design; attestation is unchanged. The role and attestation modules ran
32 tests successfully. The focused non-ASCII close-out binding test also passed.
These are deterministic checks, not a new live-run claim or an independent full-suite
run. No new blocking issue found in this diff.
