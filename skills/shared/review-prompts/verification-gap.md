# Verification-gap review — canonical prompt directive

Single source of truth for the verification-gap pass. It answers one question the other
VERIFY gates do not ask:

> If the behavior this change is supposed to produce broke where it is actually used,
> would any verification fail?

The existing scans each answer something else. `lib/test-tamper-scan.sh` defends the tests
that already exist against deletion, skipping, and swallowed exit codes. `lib/criteria-coverage.sh`
checks that every acceptance criterion carries a verify command. `agents/code-reviewer.md`
lists missed coverage as one Important-bucket item among many. None of them traces new
behavior out to the places that observe it, so a change can ship green with its behavior
pinned nowhere.

Ported from [BMAD-METHOD](https://github.com/bmad-code-org/BMAD-METHOD)'s Build review
layer (`src/bmm-skills/ship/bmad-build/review-prompts/verification-gap.md`, v6.10.0), with
its "search the repo by symbol before claiming no test exists" instruction replaced by a
probe — see *Grounding* below.

## Where this runs

- **VERIFY**, as a review layer alongside the code review and security review
  (`skills/verify/SKILL.md`).
- **`/loop-spec:quality-loop`**, in the same round as the other persona passes, under the
  same review-independence rule.

## Grounding — run the probe, do not recall

Before writing a single finding, run:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/verification-gap-scan.sh" <base-sha> <head-sha>
```

It reports, for every definition this change added or edited in a non-test file, whether
any test file in the post-change tree names that symbol, and cites the files it found.
This is the repo-wide symbol search a reviewer would otherwise perform from memory and get
wrong.

Read what it gives you and what it does not:

- `covered=no` is a **starting point, not a finding**. A symbol no test names may still be
  exercised through its caller. Trace it before you report it.
- `covered=yes` is **not proof**. A test that names a symbol may assert nothing about the
  behavior that changed. Open the test and read what it asserts.
- `scanned=0` means no definition changed. The change may still carry a verification gap
  through configuration, data, or a dependency bump — screen for that yourself.

The probe measures reachability of a name. Whether an assertion would actually fail is
your judgment, and it is the whole job.

## The three gap shapes

1. **Regression gap.** The changed code regresses where it is used, and no test covering
   that use would fail.
2. **Missing-adoption gap.** A site that should now use the new behavior does not — it
   handles the same case its own way, or not at all — and no test flags the omission.
   This qualifies only with a *supersession signal*: the change gives clear evidence the
   new behavior is meant to replace the local one (a replaced sibling site, deleted
   duplicate logic, a test defining the new rule, or the spec saying so) **and** the local
   site shares the same observable contract. Without both, it is a refactor suggestion,
   not a finding.
3. **Broken-verification gap.** A test appears to cover the changed behavior but would not
   protect it: skipped, flaky, not run in the project's normal verification command, or too
   weak to observe the regression.

## Evidence rules

These are not style preferences. A verification-gap finding that turns out to be wrong
costs more than the gap it claimed, because it sends EXECUTE to write a test for behavior
that was already pinned.

- Read a test before claiming what it covers, runs, asserts, or misses.
- Never assert what you did not verify. State what you actually checked — "none of the
  three tests naming `renderBody` assert the new branch" — and how far you looked.
- Claim a test does not exist anywhere only when the probe's symbol search backs it.
- Drop any finding you cannot ground. An ungrounded finding is not a weak finding; it is
  not a finding.
- Assign no severity, confidence, priority, or ranking. VERIFY's adjudication owns that.

A test counts as verification only if it runs in the project's normal verification path
**and** an assertion observes the changed output, branch, or contract. These do not count:
source-text assertions that match a file's wording instead of running it; no-throw or
snapshot-only checks; mock-call assertions; tests that mock away the integration under
change; stale fixtures. `expect(x ?? DEFAULT).toBe(DEFAULT)` passes when `x` is missing.

## Screening — what to skip

Screen each part of the change separately and skip the non-behavioral ones: formatting,
comments, pure renames, trivial pass-throughs, type-only changes with no runtime effect.
A part is behavioral if it alters return values, thrown errors, caller-visible side
effects, or observable state. Treat dependency, toolchain, build-config, and data-file
changes as behavioral even when no single line looks important.

Do not report: compiler- or type-checker-enforced cases; behavior already verified by an
integration or e2e test; low coverage or a missing test file on its own; legacy untested
code this change did not touch.

## Output

One block per finding, no severity, no ranking:

```markdown
### <one-line title naming the gap>

- **Gap shape:** regression | missing-adoption | broken-verification
- **Changed surface:** the behavior or contract that changed — `file:line`
- **Impacted site:** named concretely with `file:line`, not "callers of this function"
- **Probe result:** the `verification-gap-scan.sh` line for this symbol, verbatim
- **Existing test evidence:** what the tests you read actually assert, with `file:line` —
  or, if none, the symbol search that backs the absence
- **Demonstration:** the smallest realistic regression this site would observe, and why
  the tests you checked would not fail on it
- **Suggested test shape:** (optional) fitted to how this repo already verifies things —
  never a generic test pyramid
```

Genuine problems noticed while tracing, that are not verification gaps, go under a final
`## Other findings` heading, description only. That permits reporting what you already
reached; it does not license extra hunting.

When there is no gap and nothing else to say, output exactly:

`No verification gaps found.`
