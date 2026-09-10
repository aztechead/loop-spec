# Critique gate protocol — shared procedure for the DISCUSS and PLAN gates

Use this procedure for DISCUSS's `spec-critique` and PLAN's `plan-critique` gates.
The phase supplies the parameters below and its specific handling rules.
`graph/critique.graph.json` owns routing. `skills/shared/tier-matrix.md` defines skip policy.
Critique is **challenger-only**, without an advocate or debate round.

Contents: parameters · gate open · single-critic pass · adjudication · fix_list
    non-empty / empty · resume.

Delta rounds are bounded. The bound is the loop edge `graph/critique.graph.json`
declares from `critique.adjudicate` back to `critique.challenge`, and
`lib/graph/gate.sh next` is the only thing that reads it: after every fail entry it
answers `ANSWER=rerun` or `ANSWER=close` with a reason. No prose here restates the
number, and no round is counted by hand. The shape it bounds is one exhaustive
findings pass, one revision, one delta re-verify: the challenger raises everything in
the findings pass, and the delta reply passes through `lib/delta-findings-lint.sh`
before the lead adjudicates it, so a delta round cannot open findings the first pass
could have raised. `LOOP_SPEC_CRITIQUE_ROUNDS` outranks the graph
(`0` restores unbounded retries). The probe counts rounds, including loops contained inside a phase.

## Parameters (declared by the invoking phase)

| Parameter | DISCUSS | PLAN |
|---|---|---|
| `{phase}` | `discuss` | `plan` |
| `{gate}` | `spec-critique` | `plan-critique` |
| `{artifact}` | `SPEC.md` | `PLAN.md` |
| `{artifact_path}` | `docs/loop-spec/features/{slug}/SPEC.md` | `docs/loop-spec/features/{slug}/PLAN.md` |
| `{author}` | `spec-writer-1` when SPEC.md was missing; otherwise the LEAD edits directly | `planner-1` |
| `{next_step}` | the phase's exit (step 4) | the pruning pass (step 3 of the phase) |
| Skip policy | `lib/graph/probes/discuss-critique.sh` answers `gate=skip` (maintenance ∪ spec already gated; never on a security signal or ITERATE re-entry) | structural fast-path ∪ maintenance profile (no security signal) |
| Phase deltas | no-op-revision hash shortcut; lead-authored fixes when there is no spec-writer | the fix-list is the union of `lib/phase-exit.sh plan` FLAG lines and the adjudicated findings; after the one revision, re-extract `tasks.json` (`lib/plan-tasks.sh extract`), re-run the gate command, and count surviving FLAGs with the delta survivors |

The phase skill also declares the two adjudication actions that differ by phase:
`{user_intent_action}` (what to do when a finding depends on user intent) and
`{ungrounded_action}` (where the probed evidence goes). Skip policies and the
`gate_round` / `dispatch` telemetry emits stay in the phase skill — they carry
phase-specific arguments and are pinned there.

## The calls

`cycle-driver.sh critique <step>` (`lib/critique-step.sh`) is the only writer this
protocol uses: it drives `lib/graph/gate.sh` (the sole writer of `currentGate` /
`gateHistory`), writes every gate-log, counts every round, emits every `gate_round`
event, and runs `lib/delta-findings-lint.sh`. The lead never copies a reply into a
file, never counts a round, and never calls `gate.sh` directly. Six steps, in order:

```bash
DRV="${LOOP_SPEC_SKILL_DIR}/../../lib/cycle-driver.sh"
bash "$DRV" critique open     --feature-dir "$feature_dir" --phase {phase} --gate {gate} --artifact {artifact_path}   # {..., model}
bash "$DRV" critique findings --feature-dir "$feature_dir" --reply <path|->      # round 1: {verdict, lines[]}; snapshots the artifact
bash "$DRV" critique fail     --feature-dir "$feature_dir" --fix-list <path|->   # {answer: rerun|close, reason, fixList|residue}
bash "$DRV" critique revised  --feature-dir "$feature_dir"                        # {diffPath, changed, lines, fixList}
bash "$DRV" critique delta    --feature-dir "$feature_dir" --reply <path|-> [--flags <path>]   # {round, verified, survivors[]}
bash "$DRV" critique pass     --feature-dir "$feature_dir"                        # the fix-list-empty close
```

Opening over an already-open gate is refused rather than overwritten: on a resume the
gate is already open, and "Resume" below is the entry point, not `open`. The reset a
`pass` or a `close` performs is a zeroed OBJECT, never null: `graph/cycle.graph.json`
declares `currentGate` in the `reads[]` of both critique subgraph nodes, and
`lib/graph/state.sh assert-reads` fails a node whose declared read is null.

## Single-critic pass

`critique open`, then send `challenger-1` the solo-critic brief. Under the `oneshot`
spawn kind (`skills/shared/dispatch.md`) this and every later message is a nameless
`Agent({description, subagent_type: "loop-spec:challenger", run_in_background: false,
model: <open's .model>, prompt})` with the prior gate-logs inlined; omit `model` only
when `open` answered null:

```
SendMessage({
  to: "challenger-1",
  message: """
    [Populate from skills/shared/team-prompts/critic.md with these substitutions:
      {slug} = slug
      {N} = 1
      {phase} = {phase}
      {artifact} = {artifact}
    ]

    Run your findings pass on {artifact} now and report to lead.
  """
})
```

Stop after SendMessage. The harness resumes this turn on `TeammateIdle` from
`challenger-1`. Never AskUserQuestion as a wait. Hand the reply to
`critique findings --reply -` on stdin, verbatim: it writes `gate-logs/{gate}-round-1.md`,
counts the round, emits the event, and answers `{verdict: findings|no-findings,
lines[]}`. Adjudicate `lines[]`; never count rounds by hand.

A security signal still runs this pass (never skip). It does not spawn a second
critic.

## Adjudication

| Situation | Action |
|-----------|--------|
| `[major]` finding the lead agrees with | Add to fix-list. |
| `[major]` finding the lead disputes | Do NOT drop it — add it to the fix-list. A solo gate may only bias stricter, never looser. There is no advocate tiebreak. |
| `[minor]` finding | Lead's judgment: add to fix-list or drop. Every dropped `[minor]` is logged in the gate-log with a one-line reason — never silently. |
| Finding depends on user intent | Escalate via `AskUserQuestion`. Autonomous mode: no escalation — `{user_intent_action}` per the phase skill, and add it to the fix-list so the artifact states it explicitly. |
| Finding is an ungrounded external claim (`UNGROUNDED:` line) | Lead runs the suggested read-only probe ITSELF (teammates have no Bash), appends it to the evidence ledger, then `{ungrounded_action}` per the phase skill (or converts the claim to an ASSUMPTION if the probe is impossible). |

Build `fix_list` (may be empty). PLAN prepends its mechanical FLAG lines verbatim.

## fix_list non-empty

One item per line, verbatim, to `critique fail --fix-list -`. It appends the fail entry
BEFORE anything else and asks `gate.sh next` whether another delta round is inside the
ceiling:

- `{answer: "rerun", fixList}`: the artifact is snapshotted for the diff. Re-dispatch
  `{author}` via `SendMessage` (not a fresh Agent call) with `fixList` as written,
  instructing it to read the current artifact, apply every item in place, send lead
  its completion message, then go idle. (Phase deltas apply: DISCUSS has the LEAD edit
  directly when there is no spec-writer.)
- `{answer: "close", reason, residue}`: the gate is closed with `--convergence cap-reached`,
  the open items are in `gate-logs/{gate}-residue.md`, and the phase proceeds to
  `{next_step}` with the artifact as it stands. The residue goes nowhere else: not into
  the artifact, not into the backlog, not to the user.

A non-zero exit is a message on stderr (no open gate, a graph with no ceiling, a
malformed override): relay it and stop.

When the revision lands, `critique revised` diffs the snapshot `findings` took against
the artifact and answers `{diffPath, lines, fixList}`. The author may have edited the
artifact before or after `fail`; the snapshot is what the challenger read. Send the
**delta re-verify** naming the diff file, never pasting it (the challenger has Read,
and the diff in the lead's context is paid on every later call) — and never the full
gate protocol again (`skills/shared/tier-matrix.md`, critique gate ladder):

```
SendMessage({
  to: "challenger-1",
  message: """
    Delta re-verify (per your solo-critic brief). The fix-list below was applied to {artifact}.
    Confirm each item is addressed and check the CHANGED sections only for new issues.
    Every DELTA-FINDINGS line is `unaddressed: <item>` or `introduced: "<added line>" ... [major]`.

    Fix-list applied:
    {.fixList}

    Diff: Read {.diffPath} ({.lines} lines).

    Reply to lead with DELTA-VERIFIED or DELTA-FINDINGS, then go idle.
  """
})
```

The challenger reads the round's diff from `diffPath` (`gate-logs/{gate}-delta.diff`)
itself; the lead does not inline it into the message. Stop after SendMessage. The
harness resumes this turn on `TeammateIdle` from `challenger-1`, under `claude -p` as
well. Never AskUserQuestion as a wait. Hand the reply to
`critique delta --reply -` (PLAN adds `--flags` with the re-run gate's FLAG lines): it
writes the round's gate-log with the lint's `DROP` lines, counts the round, emits the
event, and answers `{verified, survivors[]}`.

- **`verified: true`**: the gate is already closed with `--convergence delta-verified`;
  proceed to `{next_step}`.
- **`survivors[]`**: adjudicate only these per the table above (an `unaddressed:` item,
  a `[major]` `introduced:` line quoting text the revision added, or a FLAG line). A
  surviving item stays: keep it on the fix-list (stricter bias), in the exact words the
  first fail entry recorded — that identity is what the probe's deadlock rule matches
  on — and call `critique fail` again; with the shipped ceiling it answers `close`.
  Never spawn a second critic and never loop without the probe's answer. `close` ends
  the gate now: first apply, as lead edits with no re-dispatch and no re-verify, every
  fix-list item the lead already ACCEPTED as `[minor]` (the ceiling bounds challenger
  rounds, not agreed one-line fixes; a live gate closed with two accepted minors
  unapplied), then record the pass entry with the items still open in its notes.
  Dispatch, then stop, holds here under `claude -p` as well: a pending teammate keeps
  the process alive and its reply re-invokes the lead.

## fix_list empty

`critique pass` appends the `single-critic` pass entry and closes the gate, in that
order. Proceed to `{next_step}`.

## Resume (gate in progress)

When the phase resumes with `currentGate.round > 0`: the gate is open and
`gate-logs/{gate}-state.json` names the artifact, so skip `open` and re-run from the
single-critic findings pass with the existing gate-logs inlined as prior context. There
is no advocate transcript to reload.
