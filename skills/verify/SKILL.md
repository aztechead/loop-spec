---
name: verify
description: VERIFY phase - acceptance gate, code-review HARD-GATE via the verify team, and evidence commit. Cycle-internal - invoked by /loop-spec:cycle; not for ad-hoc invocation (start there).
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet ToolSearch Workflow
---

# VERIFY

You prove the integrated branch meets SPEC's `### Good Enough` criteria with
post-change `file:line` evidence, and that a reviewer would merge it. Dispatch follows
`skills/shared/dispatch.md`. Gates are satisfied by remediation, never self-answered
past, in every mode. Your inputs are the entry packet and nothing else, and the pre-team scans come with it:

```bash
pb="$(bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-driver.sh" phase-begin verify --feature-dir "$feature_dir")"
# .entry.fields .entry.read[] .entry.flags[] (a missing ingress; relay and return)
# .mode: placeholder=run|skip tamper=... validation=... acceptance=... codeReview=... regression=... reason=...
# .verify = lib/verify-prepare.sh: placeholder{ran,ok,signals}, tamper{...}, validation{rc,outcome,result},
#           regression{...}, route=continue|remediate|escalate, class, remediationTasks[]
```

A `skip` (compact gate plan) is recorded in VERIFICATION.md as
`- Compact gate skipped: <name> | reason: <classifier reason>` and never described as
a pass.

## 1. Pre-team scans (fail fast, no agents yet)

`.verify` already ran them: `lib/feature-scan-each.sh` over `lib/placeholder-scan.sh`
and `lib/test-tamper-scan.sh` (every git target: single-repo toplevel or each workspace
repo with its own `baseSha`; never pass `.` or a top-level SHA yourself), then
`lib/feature-validation.sh compare` (`VALIDATION_JSON` is `.verify.validation.result`),
then the advisory `lib/regression-scan.sh` when `regression=run`. Placeholder signals
(TODO, FIXME, "not implemented" in ADDED lines) and tamper signals (deleted tests, new
skip/focus annotations, `|| true` on a test command) each fail VERIFY at once:
`.verify.route` is `remediate` with class `marker` or `tamper`, the `file:line: signal`
lines are `.verify.<scan>.signals[]`, `verify_failure` is emitted, and one full-shape
task per signal is already in `pendingRemediationTasks[]` (a tamper task names the
specific tampering; a legitimate skip is the human's call in `step`/`interactive` and is
treated as tampering when autonomous): print the signals and return to the cycle
(**Remediation** below is already recorded). The validation adapter is the ONLY place
the repository-wide test/lint/typecheck suite runs: exit 20 is a suite regression
(class `suite-regression`, one remediation task, no agents, route `remediate`); exit 21
is infrastructure (route `escalate`; never relabel setup repair as implementation
work). `route=continue` proceeds.

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
(absolute `${CLAUDE_SKILL_DIR}/../../lib`, so its code-for-humans and duplication passes
measure instead of guess); check every SPEC `## Boundaries (what NOT to do)` anti-goal
against the diff and flag violations Critical; Critical and Important block, Minor is
recorded and never blocks; include `skills/shared/review-prompts/no-prejudge.md` (never
tell a reviewer what not to flag); report
`CODE-REVIEWER DONE: <PASS|PASS_WITH_MINOR|BLOCK> <findings>`.

## 3. Gates

One call applies both verdicts and the deterministic half of the acceptance gate:

```bash
gate="$(bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-driver.sh" verify gate --feature-dir "$feature_dir" \
  --verifier ALL_PASS|FAIL --suite PASS|FAIL|N/A --reviewer PASS|PASS_WITH_MINOR|BLOCK \
  --remediation-tasks @"$feature_dir/verify-remediation.json" --minors @"$feature_dir/verify-minors.json")"
# Write each to its file first: the minors file is one finding per line (no JSON), the
# tasks file is a JSON array. Both flags also take inline JSON, but a backslash in a
# finding is not a JSON escape and a live call died on `\.github`.
# .exit{ok,flags[]} .route=redo|pass|remediate .class .tasks[] .minorsQueued .repeat
```

It runs `lib/phase-exit.sh verify` first: `.route == "redo"` means VERIFICATION.md
FLAGged (`artifact-lint`, or `[verification-grounding]` from
`lib/verification-grounding-lint.sh`: a criterion row without post-change
`repositoryEvidence`, a missing file, an out-of-range line). Fix the file in place and
call `verify gate` again with the same verdicts; nothing is recorded for a redo, and the
agents are not re-dispatched. A criterion whose evidence cannot be written is a
verifier FAIL regardless of green commands: pass `--verifier FAIL`. Then:

- Verifier `FAIL`, or `ALL_PASS` with `Test suite status: FAIL`: class `acceptance`
  (or `suite-regression`); pass one remediation task per failed criterion.
- Reviewer `BLOCK`: class `code-review`; pass one task per blocking finding.
- `PASS_WITH_MINOR`: pass every Minor in `--minors`; the call appends each to the
  backlog (`lib/backlog.sh add {slug} verify-deferred "<file:line — claim>"`); write the
  code-review section to VERIFICATION.md.
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
`graph/cycle.graph.json` (`lib/ralph-remediation.sh`) selects the bounded fix loop or a
full EXECUTE re-entry from the recorded tasks; VERIFY re-enters at step 1 afterwards.

## 4. After both gates pass

One call runs every advisory pass and hands back their findings:

```bash
passes="$(bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-driver.sh" verify passes --feature-dir "$feature_dir")"
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
