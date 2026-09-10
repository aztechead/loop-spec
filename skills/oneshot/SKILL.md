---
name: oneshot
description: ONESHOT phase - implements a change whose SPEC footprint is at most three files in one pass (implement, one code review, verify, record), then the cycle delivers. Cycle-internal - entered only when lib/graph/probes/oneshot.sh routes to it; not for ad-hoc invocation (start at /loop-spec:cycle).
allowed-tools: Bash Read Write Edit Glob Grep Agent
---

# ONESHOT

You run on the main thread and do the work yourself: the SPEC footprint names at most
three files, so a planner and an implementer wave would cost more than the change; four
steps here stand in for four phases, against the same gates. `feature_dir` is
`.loop-spec/features/{slug}`. Your inputs are the entry packet and nothing else; a FLAG
is a prior phase's failure, relay it:

```bash
pb="$(bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-driver.sh" phase-begin oneshot --feature-dir "$feature_dir")"
# .entry.fields (slug, branch, baseSha, commands, artifacts.spec, models.codeReviewer)
# .entry.read[] (SPEC.md)  .entry.flags[] (a missing ingress; relay and return)
```

Read `skills/shared/engineering-directives.md#Canonical compact directive` and
`skills/shared/human-code.md#Compact directive (read this file; do not paste it into a prompt)`:
the compact directives are the whole contract for a three-file change, and the rest of
each file is the reasoning behind them (`lib/context-load.sh` holds this phase under its
line budget). The work lands on the feature branch the packet names; the cycle already
checked it out.

## 1. Read, then decide whether this is still a oneshot

Read SPEC.md (the ask inside the frozen `## Intent` block, the Implementation notes,
the Good Enough criteria with their check commands) and every footprint file; follow
callers and imports far enough to know the change stays inside the footprint.

You never escalate; a gate does, from evidence, and the run then takes the full path
from DISCUSS with the reason on record: a file outside the footprint in the diff, a
reviewer BLOCK that stands after your fix, or the exit gate held three times on the
same flags. When the change needs a fourth file, make it and return: the gate reads
the diff. When a criterion's command is wrong, the spec's owner is the driver:
`spec fill --command --expect --row GE-NNN` replaces it. A question the spec leaves
open is a decision you record (`decisions.sh add`). A oneshot never turns a full run
into a oneshot, and you never pick the next phase. The driver is the only writer of
SPEC.md and VERIFICATION.md on this route.

## 2. Implement

Make the change in the footprint files, every one of them: the footprint is a promise
the exit gate checks against the diff, so a test file it names gets its test. A file the
change turns out not to need leaves the footprint as a recorded decision,
`bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-driver.sh" spec footprint drop --feature-dir "$feature_dir" --file <path> --reason "<why>"`;
the driver refuses to drop a test module of a file that stays. Keep the
change the size the spec describes: no refactor of neighbors, no new abstraction, no
file the footprint does not name. Match the neighbors' style. Run `commands.test` from the packet (and `commands.lint` when
set) until green. Never edit a test to make it pass; a test that is wrong is an
escalation (step 1).

Commit once on the feature branch with a conventional subject (`fix:` for a bug,
`feat:` otherwise), the footprint files only. Run the two deterministic scans the full
path runs at VERIFY and fix what they name before going on:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-scan-each.sh" "${CLAUDE_SKILL_DIR}/../../lib/placeholder-scan.sh" --feature-dir "$feature_dir"
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-scan-each.sh" "${CLAUDE_SKILL_DIR}/../../lib/test-tamper-scan.sh" --feature-dir "$feature_dir"
```

## 3. One review pass

Where the session layer answers, the driver runs this pass itself at the phase
boundary: return after step 2 with the verification rows filled (step 4), and the
cycle's `next --returned-from oneshot` comes back once with `REDO` and the report
path; record each finding as below, then return again. In-harness (the `REDO` never
comes, or names a failed session), dispatch `loop-spec:code-reviewer` once (`Agent`,
`subagent_type: "loop-spec:code-reviewer"`, model `models.codeReviewer` from the
packet, `run_in_background: false`; then stop and read its result, never
`AskUserQuestion` as a wait). Brief: `slug`, `branch`, `baseSha`, `spec_path`, and
`probe_dir` (absolute `${CLAUDE_SKILL_DIR}/../../lib`); include
`skills/shared/review-prompts/no-prejudge.md`; report
`CODE-REVIEWER DONE: <PASS|PASS_WITH_MINOR|BLOCK> <findings>`. Record the launch as
`skills/shared/dispatch.md#Telemetry (dispatch telemetry contract)` says, in the same
Bash call that reads the result; the exit gate reads this event as the proof:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit "$feature_dir" dispatch \
  --phase oneshot --data '{"role":"code-reviewer","model":"<models.codeReviewer>","rung":"subagent"}' || true
```

The Code review section is written from the reviewer's report, never by you: the
driver does it after its own session; in-harness, save the reviewer's result to
`$feature_dir/dispatch/oneshot.review.md` and run
`bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-driver.sh" verification review --feature-dir "$feature_dir"`
(no finding renders `none`; never invent one). Fix every Critical and Important
finding in the footprint and commit; one outside the footprint is an escalation
(step 1). Minor findings never block. Answer each pending finding once:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-driver.sh" verification verdict --feature-dir "$feature_dir" \
  --finding <file>:<line> --verdict true --reason "<the fix or commit>"      # or --verdict false --reason "<disproof: what shows it wrong>"
```

One review pass: a second BLOCK after your fix is an escalation, not a third round.

## 4. Verify and record

`phase-begin` wrote `docs/loop-spec/features/{slug}/VERIFICATION.md` (`.skeletons[]`
in the packet) with one grounding row and one acceptance row per criterion, keyed
`GE-NNN` in SPEC order, its Status cells empty. You fill what you know, one grounding
row per criterion; the driver observes the rest:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-driver.sh" verification fill --feature-dir "$feature_dir" \
  --row GE-001 --implementation <file>:<line> --proof "<what that line proves>" \
  --integration <test file>:<line> --integration-proof "<what it proves>"
bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-driver.sh" verification run --feature-dir "$feature_dir"
```

`--integration none` names the criterion's own command as the end-to-end proof. `run`
executes each criterion's command (the backticked span of its SPEC line) and the test
command and writes PASS or FAIL from the exit, the evidence, and the output; nobody
writes a status by hand. Each answer's `flags` are the four exit lints over the file
as it stands. A FAIL row is a change to fix, or an escalation, never a row to edit.

Return to the cycle; never invoke a successor phase and never run the exit yourself.
The cycle's `next --returned-from oneshot` runs `lib/phase-exit.sh oneshot`
(`lib/oneshot-exit-gate.sh`: the two scans, every footprint file in the diff, the
Intent block unchanged since SPEC committed it, the recorded reviewer dispatch,
`artifact-lint verification`, `verification-grounding-lint`, `review-triage-lint`,
and the converged floor over the acceptance table), commits
SPEC.md and VERIFICATION.md, tags `post-oneshot`, and routes to DELIVER; `REDO` with
`FLAG` lines means fix the change, or the value a flag names through the driver, and
return again. An escalated spec passes the exit with nothing to check and
routes to DISCUSS.

## Resume

`artifacts.verification` set: return. A commit on the branch and no VERIFICATION.md:
step 3. Otherwise step 1.
