# LF-53 plan audit

Audit date: 2026-09-22. Reviewed the supplied `plan-lf53.md` and current command,
controller, debug, and postcondition code. This is a fix-plan review for the
implementing agent, not release sign-off.

**Disposition: revise the parser and command coverage before implementing the exact
plan.** Keep the no-shell runner and extend P3. The diagnosis is substantially right;
the proposed lexer does not yet enforce the intended contract correctly.

## A1 — Preserve quoting and escaping; use the runner's lexical semantics

The proposed `shlex.shlex(..., punctuation_chars=True)` discards the information
needed to distinguish shell operators from literal arguments. Its default comment
handling also differs from `shlex.split(command)` in run_command, where comments
are disabled. Targeted probes of the exact proposed helper produced:

| Command | Proposed result | Problem |
| --- | --- | --- |
| `pytest -k ""` | rejects operator `''` | Empty argument is valid; the empty set passes the subset test. |
| `rg 'a$' file.txt` | rejects expansion | Single-quoted regex dollar is literal. |
| `python -c 'print("$HOME")'` | rejects expansion | Dollar is literal within the single-quoted argument. |
| `echo \&` | rejects operator | Escaped ampersand is a literal argument. |
| `echo ok # note && false` | accepts | Validator treats the rest as a comment; runner passes it as arguments. |
| newline between `pytest` and `false` | accepts | Shell command separator becomes argv whitespace. |

Rejecting valid literals is not an acceptable undocumented casualty of this fix.
The plan acknowledges quoted operators but underestimates the effect on Python code,
regular expressions, empty arguments, and ordinary escaped filenames. "Rewrite the
argument" may not preserve the command's meaning.

Use a small quote/escape-aware validation scan alongside `shlex.split` rather than
classifying only the quote-stripped tokens. Define the rules explicitly: active shell
operators and unquoted command-separator newlines are rejected; operators inside
quotes or escaped as literals are allowed; expansion markers are treated according
to their quote/escape context. Single-quoted dollar/backtick text is literal;
double quotes do not suppress shell expansion. Recognize actual expansion forms,
not every dollar character. Keep comment treatment consistent with the runner
(comments disabled); it must not hide a later operator. Reject empty commands and
malformed quoting, while allowing empty arguments after a valid executable.

Do not add shell execution. This is a command-format validator, not a sandbox:
explicit interpreter commands are already executable argv commands. Document that
limit rather than claiming this helper prevents an agent from invoking a shell.

## A2 — Validate claimed evidence too, as command validity rather than attestation

Include `controller._run_verify_reruns` and the corresponding V4 check/schema text.
The claimed command is independently supplied and can contain the same operators.
Re-running the same mistaken argv interpretation does not establish the meaning of
the intended command. It can match even though only the first command's behavior
was observed. `evidence_matches` compares claims to that same rerun; it does not
validate command syntax. Nor is verifier evidence inherently host-attested: verifier
is not among `ATTESTATION_REQUIRED_ROLES` in steps.py.

Reject invalid command form with a criterion-specific product/evidence validation
message. Do not call it an attestation refusal: authentic provenance and valid command
semantics are different checks. Check before cached-rerun reuse as well as fresh
execution. Invalid claimed evidence must not become acceptable via an evidence
exception that skips the rerun.

Malformed quotes also matter here: run_command catches splitting errors, but
`evidence_matches` subsequently calls `shlex.split` without handling ValueError.
Make this path return a useful validation failure instead of crashing. As a precision
correction, evidence_matches joins split tokens into a string; that is not literally
token-for-token comparison. The syntax fix need not redesign evidence comparison,
but its rationale must not rely on a stronger comparison than the code implements.

## A3 — Perform preflight before execution, then report through the boundary

P3 and B1/B2 run after baseline/debug commands have already been executed. "Before
anything else" inside P3 does not mean before baseline capture. Retain the named
postconditions for actionable task/field errors, but also guard execution: either
preflight those commands before capture/rerun or let run_command return a structured
invalid-command error without spawning. The latter preserves its existing no-raise,
data-returning contract and does not require shell=True. Use one validator everywhere.

This is especially relevant for prepare: a command can run its first program with
operator tokens as arguments before P3 eventually rejects it. A rejected plan should
not needlessly run a command already known to violate the execution contract.
Ensure featureAdded commands are validated even though base execution is skipped.

## Answers to the plan's questions

1. **Extend P3.** Its runnable-command contract is the right place. A new P8 adds no
   useful distinction here. Keep phase-interface and external.POSTCONDITION_TEXT
   aligned, and cover original-command B2 explicitly as well as B1.
2. **Do not blanket-ban `*`, `?`, or `~` characters.** Programs may legitimately
   interpret pattern arguments themselves; quoted/escaped forms must remain usable.
   Prefer rejecting unquoted shell glob syntax (`*`, `?`, bracket patterns) and a
   leading shell tilde form under the explicit plain-argv contract, with guidance to
   quote literals/program-owned patterns or supply explicit paths. This requires the
   quote-aware scanner from A1. Treat this as an explicit format policy, not proof of
   the author's intent. If deferred, document that literals are passed unchanged and
   stop claiming the helper detects every reliance on expansion.
3. **Yes, include claimed evidence now**, with the V4 validation behavior in A2.
   Otherwise the same defect remains in another evidence-producing path.

## Required deterministic checks

Expand the test table, rather than counting test functions:

- Original featureAdded LF-53 command; ordinary verify; prepare; B1 reproduction;
  B2 original; claimed VERIFY evidence, including the cached-rerun path.
- Adjacent operators, redirections, expansion contexts, newline separators, and
  comment-marker cases using the same lexical rules as execution.
- Valid quoted/escaped operators, single-quoted dollar/backtick text, regex literals,
  empty arguments; malformed quotes and truly empty commands rejected.
- Invalid syntax never spawns a process and produces the intended field/task/criterion
  error. Claimed evidence with malformed quotes does not crash.

These are deterministic module tests, not an offline cycle suite. After implementation
review, retain the planned recorded workspace re-run and remaining live cases.
No new live cycle or full suite was run for this audit. The lexer probes above were
executed locally without running their example commands. No production code, version,
plan, or failed-run evidence was modified. This audit file is local and untracked;
nothing was committed or pushed.

## Outstanding operator choices

Leave `lf49-51-plan-audit.md` intact and untracked until the user chooses its disposition.
Do not delete or commit it as a side effect of LF-53. Keeping the plan/audit checkpoint
for live-run fixes is reasonable; no memory setting was changed by this review.


## Second pass: revision 1 (2026-09-22)

**Disposition: go to implementation.** The revised design addresses A1–A3. This is
approval of the fix plan, not release sign-off; implementation review, deterministic
checks, and the recorded live re-run remain necessary. No additional plan revision
is required before coding.

Read the revised plan and `scratchpad/probe_lf53.py`, checked the controller's PLAN,
DEBUG and VERIFY paths, and reran the supplied probe. All 30 rejection cases were
rejected and all 20 accepted cases were accepted. The probe only checks strings; it
does not execute the example commands. No full suite or live cycle was run.

### Findings closed

- A1: the raw quote/escape-aware scan preserves valid literals and empty arguments,
  catches the original command and comment/newline cases, and uses shlex to reject
  malformed splitting. The named limits are acceptable for this bounded fix.
- A2: V4 checks supplied evidence command syntax before evidence exemptions; invalid
  commands cannot pass on a matching cached execution. Malformed quote handling in
  evidence_matches avoids the existing uncaught ValueError.
- A3: PLAN/DEBUG preflight rejects before capture; run_command adds a no-spawn
  backstop without changing to shell execution or abandoning its data-returning API.

### Implementation notes to retain

1. Exit 127 is acceptable with `errorClass: invalid-command`. This is a synthetic
   refusal result, not an observed child-process exit. Preserve the diagnostic reason
   and the distinct error class; do not describe every 127 as a missing executable.
   The revised V4 form check should take precedence over its old generic 127 note.
2. Move invalid-command cache clearing ahead of the exemption skip in
   `_run_verify_reruns`. The revision's snippet is placed after evidence extraction,
   but today's loop skips exempt criteria before that point. V4 still rejects the
   invalid exempt claim, so this does not defeat the gate; it does mean the stated
   guarantee that stale matched records are removed would otherwise be false. Add
   the exempt-criterion plus existing matched-record case to the controller test.
   Valid exempt commands must still never be re-run.
3. Describe the scanner as quote-aware validation of the documented supported
   command format, not exact shell emulation. The plan explicitly admits brace and
   double-quoted backslash-dollar differences. Keep those limits in the Commands
   reference. No need to expand this fix into a complete shell parser.
4. Preserve the existing blocked-reproduction branch: B1/B2 form preflight belongs
   in the reproduced path, where reproduction exists, as the proposed insertion
   location already indicates. Keep the schema and named boundary diagnostics in
   sync with the validator.

Proceed with the planned implementation and review its actual diff before treating
LF-53 as closed. Keep the live-run evidence separate from the string probe and module
tests. Only this audit file was appended; no source, plan, memory, version, commit,
or remote was changed. Both audit files remain untracked.
