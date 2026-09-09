---
name: oneshot
description: ONESHOT phase - implements a change whose SPEC footprint is at most three files in one pass (implement, one code review, verify, record), then the cycle delivers. Cycle-internal - entered only when lib/graph/probes/oneshot.sh routes to it; not for ad-hoc invocation (start at /loop-spec:cycle).
allowed-tools: Bash Read Write Edit Glob Grep Agent
---

# ONESHOT

You run on the main thread and do the work yourself: the SPEC footprint names at most
three files, so a task DAG, a planner, and an implementer wave would cost more than the
change. What the full path spreads over four phases, this one does in four steps against
the same gates. `feature_dir` is `.loop-spec/features/{slug}`. Your inputs are the entry
packet and nothing else; a FLAG is a prior phase's failure, relay it:

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

Read SPEC.md (the ask inside the frozen `## Intent` block, then Implementation notes
and Good Enough criteria, each with its check command) and every file in its
`footprint:`. Follow callers and imports far enough to know the change stays inside it.

Escalate, and only escalate, when the code shows one of these:

- the change needs a fourth file, or a file the footprint does not name;
- a Good Enough criterion cannot be checked by a command you can run here;
- a question the spec leaves open changes what you would write;
- the footprint or the spec touches a security surface the probe could not see.

To escalate, run
`bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-driver.sh" spec escalate --feature-dir "$feature_dir" --reason "<why>"`
and return. The cycle routes the run to DISCUSS on the full path
(`lib/graph/probes/oneshot.sh --after`); nothing you found is lost. A oneshot never
turns a full run into a oneshot, and you never pick the next phase. You never open
SPEC.md or VERIFICATION.md to write: the driver is their only writer on this route
(`hooks/restrict-agent-paths.sh` denies the Write), and every driver answer carries
the gate flags the file has so far.

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

Commit once on the feature branch with a conventional subject (`fix: <what>` for a
bug, `feat: <what>` otherwise), the footprint files only. Run the two deterministic
scans the full path runs at VERIFY and fix what they name before going on:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-scan-each.sh" "${CLAUDE_SKILL_DIR}/../../lib/placeholder-scan.sh" --feature-dir "$feature_dir"
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-scan-each.sh" "${CLAUDE_SKILL_DIR}/../../lib/test-tamper-scan.sh" --feature-dir "$feature_dir"
```

## 3. One review pass

Where the session layer answers, the driver runs this pass itself at the phase
boundary: return after step 2 with the verification rows filled (step 4), and the
cycle's `next --returned-from oneshot` comes back once with `REDO` and the report
path; record each finding as below, then return again. In-harness (the `REDO` never
comes; an attended session), dispatch `loop-spec:code-reviewer` once (`Agent`,
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

Fix every Critical and Important finding in the footprint and commit; a finding that
needs a file outside the footprint is an escalation (step 1). Minor findings never
block. Record every finding with your verdict in one call, one bullet per finding:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-driver.sh" verification fill --feature-dir "$feature_dir" \
  --reviewer-model "<models.codeReviewer>" \
  --review '- <file>:<line> — <claim> | verdict: true — <commit or fix>
- <file>:<line> — <claim> | verdict: false — <disproof: what shows it wrong>'
```

(`<claim>` is the finding in the reviewer's words; `none` when there is no finding;
`lib/review-triage-lint.sh` rejects a bullet without a location, without a verdict, or
a `false` without its disproof, and the answer's `flags` say so at once). There is one review pass: a second BLOCK after your fix is an
escalation, not a third round.

## 4. Verify and record

Run each Good Enough criterion's check command exactly as SPEC.md writes it and keep
the output. `phase-begin` wrote `docs/loop-spec/features/{slug}/VERIFICATION.md`
(`.skeletons[]` in the packet) with one grounding row and one acceptance row per
criterion, keyed `GE-NNN` in SPEC order. Fill it through the driver, one criterion per
call, then the test suite output:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-driver.sh" verification fill --feature-dir "$feature_dir" \
  --row GE-001 --implementation <file>:<line> --proof "<what that line proves>" \
  --integration <test file>:<line> --integration-proof "<what it proves>" \
  --evidence "<command> -> <output summary>" --output "$(<the check command>)"
bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-driver.sh" verification fill --feature-dir "$feature_dir" --tests "$(<commands.test>)"
```

`--integration none` names the criterion's own command as the end-to-end proof. Each
answer's `flags` are the four exit lints over the file as it stands. A criterion that
does not pass is never recorded as `FAIL` and worked around: fix it, or escalate.

Return to the cycle; never invoke a successor phase and never run the exit yourself.
The cycle's `next --returned-from oneshot` runs `lib/phase-exit.sh oneshot`
(`lib/oneshot-exit-gate.sh`: the two scans, every footprint file in the diff, the
Intent block unchanged since SPEC committed it, the recorded reviewer dispatch,
`artifact-lint verification`, `verification-grounding-lint`, `review-triage-lint`,
and the converged floor over the acceptance table), commits
SPEC.md and VERIFICATION.md, tags `post-oneshot`, and routes to DELIVER; `REDO` with
`FLAG` lines means fix the change, or the value a flag names through `verification
fill`, and return again. An escalated spec passes the exit with nothing to check and
routes to DISCUSS.

## Resume

`artifacts.verification` set: VERIFICATION.md exists, return. A commit on the branch
and no VERIFICATION.md: continue at step 3. Otherwise start at step 1.
