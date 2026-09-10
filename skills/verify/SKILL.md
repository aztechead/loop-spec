---
name: verify
description: "Check acceptance criteria and code review, record evidence, and route failures for remediation. Internal phase of /loop-spec:cycle. Start there for repository work."
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet ToolSearch Workflow
---

# VERIFY

Check the integrated branch against SPEC's `### Good Enough` criteria using post-change `file:line` evidence.
Obtain a code-review verdict. Follow `skills/shared/dispatch.md` for dispatch.
Resolve failed gates through remediation in every mode. Never bypass them with your own approval.
Read only the entry packet as input. It includes the preliminary scans:

```bash
pb="$(bash "${LOOP_SPEC_SKILL_DIR}/../../lib/cycle-driver.sh" phase-begin verify --feature-dir "$feature_dir")"
# .entry.fields .entry.read[] .entry.flags[] (a missing ingress; relay and return)
# .mode: placeholder=run|skip tamper=... validation=... acceptance=... codeReview=... regression=... reason=...
# .verify = lib/verify-prepare.sh: placeholder{ran,ok,signals}, tamper{...}, validation{rc,outcome,result},
#           regression{...}, route=continue|remediate|escalate, class, remediationTasks[]
```

A `skip` (compact gate plan) is recorded in VERIFICATION.md as
`- Compact gate skipped: <name> | reason: <classifier reason>` and never described as
a pass.

## 1. Pre-team scans (fail fast, no agents yet)

The entry call already ran these checks and stored their results in `.verify`:

1. `lib/feature-scan-each.sh` runs `lib/placeholder-scan.sh` and `lib/test-tamper-scan.sh` on every Git target.
   Each workspace repository uses its own `baseSha`. Never supply `.` or a shared top-level SHA yourself.
2. `lib/feature-validation.sh compare` runs repository validation. Use `.verify.validation.result` as `VALIDATION_JSON`.
3. `lib/regression-scan.sh` runs as an advisory check when `regression=run`.

Placeholder and tamper signals fail VERIFY immediately.
Examples include added TODOs, FIXMEs, or "not implemented" text, deleted tests, new skip or focus annotations, and ignored test failures.
For these failures, `.verify.route` is `remediate`, with class `marker` or `tamper`.
The call emits `verify_failure` and adds one full-shape task per signal to `pendingRemediationTasks[]`.
Each tamper task names the specific change.

Print `.verify.<scan>.signals[]` and return to the cycle. The call already recorded **Remediation**.
In `step` or `interactive` styles, the user decides whether a skip is legitimate.
Autonomous runs treat the skip as tampering.

Only the validation adapter runs the repository-wide test, lint, and typecheck suite.
Exit 20 means a suite regression: class `suite-regression`, one remediation task, route `remediate`, and no agents.
Exit 21 means an infrastructure failure: route `escalate`. Never classify setup repair as implementation work.
Proceed only for `route=continue`.

## 2. Verifier and code reviewer

Spawn `verifier-1` (`loop-spec:verifier`) and `code-reviewer-1` (`loop-spec:code-reviewer`)
in parallel, then stop; never AskUserQuestion as a wait. With `workflowsAvailable` (single-repo only) the acceptance
Workflow `lib/workflows/acceptance-verify.js` and the review Workflow
`lib/workflows/code-review-dimensions.js` replace the agents; their results feed the same
gates.

Verifier brief: `slug`, `spec_path`, `plan_path`, `branch`, `baseSha` (workspace: each
repo's absolute path, branch, and `baseSha`), and `VALIDATION_JSON` verbatim; apply
`skills/shared/verification-grounding.md`; run every `### Good Enough` criterion's verify
command from PLAN.md; do NOT rerun the repository-wide commands; write exactly one row
per criterion `- criterion: GE-NNN | implementation: <file>:<line> - <proof> |
integration: <file>:<line> - <proof>` (`integration: none - <reason>` only when no
separate site exists); Exceptional is informational; report
`VERIFIER DONE: <ALL_PASS|FAIL> <Test suite status: PASS|FAIL|N/A> <summary>`.

Reviewer brief: `slug`, `branch`, `baseSha`, `spec_path`, `plan_path`, and `probe_dir`
(absolute `${LOOP_SPEC_SKILL_DIR}/../../lib`, so its code-for-humans and duplication passes
measure instead of guess); check every SPEC `## Boundaries (what NOT to do)` anti-goal
against the diff and flag violations Critical; Critical and Important block, Minor is
recorded and never blocks; include `skills/shared/review-prompts/no-prejudge.md` (never
tell a reviewer what not to flag); report
`CODE-REVIEWER DONE: <PASS|PASS_WITH_MINOR|BLOCK> <findings>`.

## 3. Gates

One call applies both verdicts and the deterministic half of the acceptance gate:

```bash
gate="$(bash "${LOOP_SPEC_SKILL_DIR}/../../lib/cycle-driver.sh" verify gate --feature-dir "$feature_dir" \
  --verifier ALL_PASS|FAIL --suite PASS|FAIL|N/A --reviewer PASS|PASS_WITH_MINOR|BLOCK \
  --remediation-tasks @"$feature_dir/verify-remediation.json" --minors @"$feature_dir/verify-minors.json")"
# Write each to its file first: the minors file is one finding per line (no JSON), the
# tasks file is a JSON array. Both flags also take inline JSON, but a backslash in a
# finding is not a JSON escape and a live call died on `\.github`.
# .exit{ok,flags[]} .route=redo|pass|remediate .class .tasks[] .minorsQueued .repeat
```

It runs `lib/phase-exit.sh verify` first: `.route == "redo"` means VERIFICATION.md
FLAGged (`artifact-lint`; `[verification-grounding]` from
`lib/verification-grounding-lint.sh`: a criterion row without post-change
`repositoryEvidence`, a missing file, an out-of-range line; `[acceptance-table]` from
`lib/converged-floor.sh --shape`: a criterion with no row, two rows, or a status cell
that does not begin with PASS, FAIL, or N/A; `[misplaced]`: the verifier wrote the file
into another checkout, and the flag names the move). Fix the file in place and
call `verify gate` again with the same verdicts; nothing is recorded for a redo, and the
agents are not re-dispatched. A criterion whose evidence cannot be written is a
verifier FAIL regardless of green commands: pass `--verifier FAIL`. Then:

- Verifier `FAIL`, or `ALL_PASS` with `Test suite status: FAIL`: class `acceptance`
  (or `suite-regression`); pass one remediation task per failed criterion.
- Reviewer `BLOCK`: class `code-review`; pass one task per blocking finding.
- `PASS_WITH_MINOR`: pass every Minor in `--minors`; the call appends each to the
  backlog (`lib/backlog.sh add {slug} verify-deferred "<file:line — claim>"`); write the
  code-review section to VERIFICATION.md.
- Every finding the reviewer reported gets one bullet in that section with your verdict:
  `- <file>:<line> — <claim> | verdict: true — <commit, backlog id, or fix>`, or
  `| verdict: false — <disproof>` naming what you ran or read that shows the finding
  wrong. A finding you cannot place at a `file:line` is not a finding yet: send it back
  to the reviewer. `lib/review-triage-lint.sh` at the exit rejects a bullet without a
  location, without a verdict, or a `false` without its disproof sentence.
  Accepted findings also follow `skills/shared/review-routing.md`: append the routing
  JSON with a root cause and the evidence for intent-gap, bad-spec, patch, or defer.
- Second failure of the same criterion or finding across `gateHistory[]`: the call
  records the lesson once (`lib/rules.sh add "VERIFY repeat-fail on '<criterion>'
  ({slug}): ..." --check "<verify command>"`) and reports `.repeat`.

**Remediation** (`.route == "remediate"`): the call appended each FULL-SHAPE task
(`{id: "task-NNN+remediate-M", subject: "Fix: ...", files, verifyCommand,
acceptanceCriteria, blockedBy: [], retries: 0}`) to `pendingRemediationTasks[]`,
recorded the `gateHistory[]` fail entry (`phase: verify`, `gate: <acceptance|code-review>`),
emitted `verify_failure`, and cleared `currentTeamName`/`currentTeammates`. Discard the
reviewer's output when the verifier failed, tear the team down (explicit mode
`TeamDelete`), and return to the cycle. The remediation route declared in
`graph/cycle.graph.json` returns queued findings to EXECUTE before ITERATE, with a
five-traversal recovery ceiling. Pending bad-spec recovery keeps priority and returns
to DISCUSS. EXECUTE publishes the complete intake before acknowledging it; malformed
tasks or missing verification commands stop preparation and retain the queue for
repair. Fix the named intake error and retry preparation. VERIFY re-enters at step 1
after the remediation tasks are published. Approved Goal/Boundary checks remain hard
failures throughout recovery.

## 4. After both gates pass

One call runs every advisory pass and hands back their findings:

```bash
passes="$(bash "${LOOP_SPEC_SKILL_DIR}/../../lib/cycle-driver.sh" verify passes --feature-dir "$feature_dir")"
# .live{configured,rc,result} .gaps{rc,lines[]} .plainLanguage{prose,comments} .docTells{rc,lines[]} .layers[] .reviewTrail{present,rc,findings[]}
```

- **Live run** (`.loop-spec/workflow.json` `verifyCommands` configured):
  `lib/verify-live.sh run --evidence docs/loop-spec/features/{slug}/EVIDENCE.md` is
  `.live`; `rc` 1 is class `live-probe`, one task per failed probe, through
  `verify gate` with `--verifier FAIL` and those tasks (**Remediation**). Unconfigured
  is suite-only; never guess a launch command (`verify-live.sh detect .` may suggest one
  once in interactive styles).
- **Verification-gap pass**: `lib/verification-gap-scan.sh "$baseSha" HEAD` is `.gaps`;
  `rc` 1 means no non-test definition changed. Otherwise ONE fresh reviewer carrying
  `skills/shared/review-prompts/verification-gap.md` plus `.gaps.lines[]`. Findings are
  advisory: `## Verification gaps` in VERIFICATION.md and the backlog.
- **Plain language** (advisory): `lib/plain-language-lint.sh prose` over the feature's
  artifacts and `comments` over changed `.sh`/`.py` are `.plainLanguage`; record counts
  under `## Plain language`.
- **Docs-for-humans pass**: `lib/doc-tells.sh diff "$baseSha" HEAD` is `.docTells`; `rc`
  1 lists fixable `file:line` findings; fix and call `verify passes` again until clean (a
  documented misfire is recorded under `## Docs for humans` instead).
- **Project review layers**: `lib/extension-points.sh layers verify` is `.layers[]`; one
  reviewer per layer, findings recorded alongside the gap findings. Layers add, never
  remove.
- **Reviewer's guide**: `skills/walkthrough/SKILL.md` in `--write` mode produces
  `docs/loop-spec/features/{slug}/REVIEW-ORDER.md`; `lib/review-trail.sh lint` is
  `.reviewTrail` on the next `verify passes` call; fix until its `findings[]` is empty.
  The exit records it as `artifacts.reviewOrder` for DELIVER. Never a delivery gate.

## 5. Exit

Return to the cycle; never run the exit yourself. Its `next --returned-from verify`
runs `lib/phase-exit.sh verify` on the final VERIFICATION.md: ok commits
VERIFICATION.md and REVIEW-ORDER.md, tags `post-verify`, and closes the phase; a FLAG
answers `REDO` and you are invoked again to fix the record. VERIFY never pushes, opens a
PR, or leaves the feature root; ITERATE judges next and only DELIVER ships.

## Resume

Continue from the first incomplete step (scans, team, gates, passes, commit). Teammates
never survive a session; spawn fresh.
