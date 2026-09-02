---
name: verify
description: VERIFY phase - acceptance gate, code-review HARD-GATE via the verify team, evidence commit, and map-codebase refresh. Cycle-internal - invoked by /loop-spec:cycle; not for ad-hoc invocation (start there).
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet ToolSearch Workflow
---

# VERIFY

You prove the integrated branch meets SPEC's `### Good Enough` criteria with
post-change `file:line` evidence, and that a reviewer would merge it. Dispatch follows
`skills/shared/dispatch.md`. Gates are satisfied by remediation, never self-answered
past, in every mode. Your inputs are the entry packet and nothing else:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/phase-entry.sh" verify --feature-dir "$feature_dir"
# fields=<the feature.json keys this phase consumes>  read=<each file to read>  FLAG on a missing ingress
```

```bash
gates="$(bash "${CLAUDE_SKILL_DIR}/../../lib/phase-mode.sh" verify --feature-dir "$feature_dir")"
# placeholder=run|skip tamper=... validation=... acceptance=... codeReview=... regression=... reason=...
```

A `skip` (compact gate plan) is recorded in VERIFICATION.md as
`- Compact gate skipped: <name> | reason: <classifier reason>` and never described as
a pass.

## 1. Pre-team scans (fail fast, no agents yet)

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-scan-each.sh" "${CLAUDE_SKILL_DIR}/../../lib/placeholder-scan.sh" --feature-dir "$feature_dir"   # placeholder
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-scan-each.sh" "${CLAUDE_SKILL_DIR}/../../lib/test-tamper-scan.sh" --feature-dir "$feature_dir"   # tamper
VALIDATION_JSON="$(bash "${CLAUDE_SKILL_DIR}/../../lib/feature-validation.sh" compare "$feature_dir")"   # validation; exit 20 regression, 21 infrastructure
```

`feature-scan-each.sh` walks every git target (single-repo toplevel or each workspace
repo with its own `baseSha`); never pass `.` or a top-level SHA yourself. Placeholder
signals (TODO, FIXME, "not implemented" in ADDED lines) and tamper signals (deleted
tests, new skip/focus annotations, `|| true` on a test command) each fail VERIFY at
once: print the `file:line: signal` lines, emit `verify_failure` with class `marker` or
`tamper`, and go to **Remediation** with one full-shape task per signal (a tamper task
names the specific tampering; a legitimate skip is the human's call in
`step`/`interactive` and is treated as tampering when autonomous). The validation
adapter is the ONLY place the repository-wide test/lint/typecheck suite runs: exit 20
is a suite regression (class `suite-regression`, one remediation task, no agents);
exit 21 is infrastructure (escalate; never relabel setup repair as implementation
work). `regression=run` first runs the advisory `lib/regression-scan.sh .` and logs
its counts.

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

Run the exit command first; it is the deterministic half of the acceptance gate:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/phase-exit.sh" verify --feature-dir "$feature_dir"
```

A `[verification-grounding]` FLAG (`lib/verification-grounding-lint.sh`: a criterion
row without post-change `repositoryEvidence`, a missing file, an out-of-range line) is
a verifier FAIL regardless of green commands.
Then:

- Verifier `FAIL`, or `ALL_PASS` with `Test suite status: FAIL`: class `acceptance`
  (or `suite-regression`), one remediation task per failed criterion, **Remediation**.
- Reviewer `BLOCK`: class `code-review`, one task per blocking finding, **Remediation**.
- `PASS_WITH_MINOR`: append every Minor to the backlog
  (`lib/backlog.sh add {slug} verify-deferred "<file:line — claim>"`) and the
  code-review section to VERIFICATION.md.
- Second failure of the same criterion or finding across `gateHistory[]`: record the
  lesson once, `lib/rules.sh add "VERIFY repeat-fail on '<criterion>' ({slug}): ..."
  --check "<verify command>"`.

**Remediation** (shared by every failing gate): append each FULL-SHAPE task
(`{id: "task-NNN+remediate-M", subject: "Fix: ...", files, verifyCommand,
acceptanceCriteria, blockedBy: [], retries: 0}`) to `pendingRemediationTasks[]` via
`lib/feature-write.sh append`, append a `gateHistory[]` fail entry (`phase: verify`,
`gate: <acceptance|code-review|live-verify>`), discard the reviewer's output when the
verifier failed, tear the team down (explicit mode `TeamDelete`; clear
`currentTeamName`/`currentTeammates`), and return to the cycle. The remediation route
declared in `graph/cycle.graph.json` (`lib/ralph-remediation.sh`) selects the bounded
fix loop or a full EXECUTE re-entry from the recorded tasks; VERIFY re-enters at step 1
afterwards.

## 4. After both gates pass

- **Live run** (`.loop-spec/workflow.json` `verifyCommands` configured):
  `lib/verify-live.sh run --evidence docs/loop-spec/features/{slug}/EVIDENCE.md`. Exit 1 is
  class `live-probe`, one task per failed probe, **Remediation**. Unconfigured is
  suite-only; never guess a launch command (`verify-live.sh detect .` may suggest one
  once in interactive styles).
- **Verification-gap pass**: `bash "${CLAUDE_SKILL_DIR}/../../lib/verification-gap-scan.sh" "$baseSha" HEAD`; exit 1 means
  no non-test definition changed. Otherwise ONE fresh reviewer carrying
  `skills/shared/review-prompts/verification-gap.md` plus the probe output. Findings are
  advisory: `## Verification gaps` in VERIFICATION.md and the backlog.
- **Plain language** (advisory): `bash "${CLAUDE_SKILL_DIR}/../../lib/plain-language-lint.sh" prose docs/loop-spec/features/{slug}/*.md --max-flags 40`
  and `comments` over changed `.sh`/`.py`; record counts under `## Plain language`.
- **Docs-for-humans pass**: `bash "${CLAUDE_SKILL_DIR}/../../lib/doc-tells.sh" diff "$baseSha" HEAD`; exit 1 lists fixable
  `file:line` findings; fix and re-run until clean (a documented misfire is recorded
  under `## Docs for humans` instead).
- **Project review layers**: `bash "${CLAUDE_SKILL_DIR}/../../lib/extension-points.sh" layers verify`; one reviewer per
  emitted layer, findings recorded alongside the gap findings. Layers add, never remove.
- **Reviewer's guide**: `skills/walkthrough/SKILL.md` in `--write` mode produces
  `docs/loop-spec/features/{slug}/REVIEW-ORDER.md`; lint with
  `bash "${CLAUDE_SKILL_DIR}/../../lib/review-trail.sh" lint <path> "$baseSha" HEAD` until
  clean; the exit records it as `artifacts.reviewOrder` for DELIVER. Never a delivery gate.
- **Map refresh**: unless `lib/map-policy.sh refresh` says `skip`,
  `Skill(loop-spec:map-codebase) mode: incremental, since_sha: baseSha` (`--full` for
  greenfield; workspace passes `name=abs-path` repo list). A failure is a warning, not a
  gate.

## 5. Exit

Run the exit command from step 3 again on the final VERIFICATION.md; it must print
`phase-exit: ok (verify)`. That commits VERIFICATION.md and REVIEW-ORDER.md, tags
`post-verify`, and closes the phase. VERIFY never pushes, opens a PR, or leaves the
feature root; ITERATE judges next and only DELIVER ships.

## Resume

Continue from the first incomplete step (scans, team, gates, passes, commit). Teammates
never survive a session; spawn fresh.
