# Critique gate protocol — shared procedure for the DISCUSS and PLAN gates

Single source of truth for the critique-gate procedure both artifact gates run
(`spec-critique` in DISCUSS, `plan-critique` in PLAN). The phase skill invokes this
protocol with the parameters below and keeps only its deltas; the routing topology is
owned by `graph/critique.graph.json` and the skip policy by `skills/shared/tier-matrix.md`
— this file owns the operational procedure between those two. Critique is
**challenger-only**: there is no advocate and no debate round.

Contents: parameters · gate open · single-critic pass · adjudication · fix_list
    non-empty / empty · resume.

Delta rounds are bounded. The bound is the loop edge `graph/critique.graph.json`
declares from `critique.adjudicate` back to `critique.challenge`, and
`lib/graph/gate.sh next` is the only thing that reads it: after every fail entry it
answers `ANSWER=rerun` or `ANSWER=close` with a reason. No prose here restates the
number, and no round is counted by hand. `LOOP_SPEC_CRITIQUE_ROUNDS` outranks the graph
(`0` restores unbounded retries). A run once spent over an hour bouncing PLAN.md between
the challenger and the planner because the ceiling lived inside a `contain` loop the
engine never counts; the probe is what counts it.

## Parameters (declared by the invoking phase)

| Parameter | DISCUSS | PLAN |
|---|---|---|
| `{phase}` | `discuss` | `plan` |
| `{gate}` | `spec-critique` | `plan-critique` |
| `{artifact}` | `SPEC.md` | `PLAN.md` |
| `{artifact_path}` | `docs/loop-spec/features/{slug}/SPEC.md` | `docs/loop-spec/features/{slug}/PLAN.md` |
| `{author}` | `spec-writer-1` when SPEC.md was missing; otherwise the LEAD edits directly | `planner-1` |
| `{next_step}` | phase Step 5.75 | phase Step 5.7 (prune; mechanical gates already ran) |
| Skip policy | `lib/graph/probes/discuss-critique.sh` answers `gate=skip` (maintenance ∪ spec already gated; never on a security signal or ITERATE re-entry) | structural fast-path ∪ maintenance profile (no security signal) |
| Phase deltas | no-op-revision hash shortcut; lead-authored fixes when there is no spec-writer | re-parse `tasks[]` after every revision; re-run feasibility + coverage if PLAN.md changed |

The phase skill also declares the two adjudication actions that differ by phase:
`{user_intent_action}` (what to do when a finding depends on user intent) and
`{ungrounded_action}` (where the probed evidence goes). Skip policies and the
`gate_round` / `dispatch` telemetry emits stay in the phase skill — they carry
phase-specific arguments and are pinned there.

## Gate open

`lib/graph/gate.sh` owns every `currentGate` / `gateHistory` write in this protocol —
`lib/feature-write.sh` refuses those two keys to anything else. It stamps `startedAt`,
zeroes the round, and leaves `advocateName` null (schema key retained for resume; no
advocate is spawned):

```bash
feature_dir=".loop-spec/features/{slug}"
bash "${CLAUDE_SKILL_DIR}/../../lib/graph/gate.sh" open --feature-dir "$feature_dir" \
  --phase {phase} --gate {gate} --challenger challenger-1
mkdir -p "$feature_dir/gate-logs/"
```

Opening over an already-open gate is refused rather than overwritten: on a resume the
gate is already open, and "Resume" below is the entry point, not this one.

## Single-critic pass

Model: `feature.models.challenger`. Send `challenger-1` the solo-critic brief:

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

Stop after SendMessage. The harness resumes this turn on `TeammateIdle` from `challenger-1`. Never AskUserQuestion as a wait. Read its `FINDINGS:` / `NO-FINDINGS:`
message. Write it to `gate-logs/{gate}-round-1.md`:

```
# {gate} Round 1 (single-critic)

## challenger-1
<the FINDINGS/NO-FINDINGS message body>
```

Record the round before adjudicating — `Resume` below re-enters on `currentGate.round > 0`,
so a round that is logged to disk but never counted resumes as a gate that never opened:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/graph/gate.sh" round --feature-dir "$feature_dir"
```

Emit the phase's `gate_round` event (`"mode":"single-critic"`), then adjudicate.

A security signal still runs this pass (never skip). It does not spawn a second
critic.

## Adjudication

Read all `gate-logs/{gate}-round-*.md`.

| Situation | Action |
|-----------|--------|
| `[major]` finding the lead agrees with | Add to fix-list. |
| `[major]` finding the lead disputes | Do NOT drop it — add it to the fix-list. A solo gate may only bias stricter, never looser. There is no advocate tiebreak. |
| `[minor]` finding | Lead's judgment: add to fix-list or drop. Every dropped `[minor]` is logged in the gate-log with a one-line reason — never silently. |
| Finding depends on user intent | Escalate via `AskUserQuestion`. Autonomous mode: no escalation — `{user_intent_action}` per the phase skill, and add it to the fix-list so the artifact states it explicitly. |
| Finding is an ungrounded external claim (`UNGROUNDED:` line) | Lead runs the suggested read-only probe ITSELF (teammates have no Bash), appends it to the evidence ledger, then `{ungrounded_action}` per the phase skill (or converts the claim to an ASSUMPTION if the probe is impossible). |

Build `fix_list` (may be empty).

## fix_list non-empty

Append the fail entry BEFORE anything else (the re-dispatch path returns to the gate and
would never reach an append placed after the return). `attempt` is counted from the
entries already recorded for this phase and gate — never supplied:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/graph/gate.sh" fail --feature-dir "$feature_dir" \
  --rounds <N (single-critic: 1 + delta rounds)> \
  --convergence <single-critic | delta-verified> \
  --challenger-model "<model>" \
  --findings '<fix_list items as a JSON array of strings>'
```

The gate stays open across a fail — only `pass` closes it.

Then ask the probe whether another delta round is inside the ceiling:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/graph/gate.sh" next --feature-dir "$feature_dir"
# ANSWER=rerun REASON=<n> of <ceiling> delta rounds spent
# ANSWER=close REASON=ceiling: ... | deadlock: finding survived two consecutive delta rounds: ...
```

`close` ends the gate now: append the pass entry with `--convergence cap-reached` and
`--notes` carrying every fix-list item still open, write those items to
`gate-logs/{gate}-residue.md`, and proceed to `{next_step}` with the artifact as it
stands. The residue goes nowhere else: not into the artifact, not into the backlog, not
to the user. `rerun` continues below. A non-zero exit is a message on stderr (no open
gate, a graph with no ceiling, a malformed override): relay it and stop, and
never count rounds by hand in its place.

Snapshot the artifact (feeds the delta re-verify diff; DISCUSS also hashes it for the
no-op shortcut):

```bash
cp {artifact_path} .loop-spec/features/{slug}/gate-logs/{artifact}.pre-revision.md
```

Re-dispatch `{author}` via `SendMessage` (not a fresh Agent call) with the numbered
fix-list, instructing it to read the current artifact, apply every item in place, send
lead its completion message, then go idle. (Phase deltas apply: DISCUSS has the LEAD
edit directly when there is no spec-writer; PLAN re-parses `tasks[]` from the
completion message.)

When the revision lands, run the **delta re-verify** — do NOT re-run the full gate
protocol (`skills/shared/tier-matrix.md`, critique gate ladder):

```bash
diff -u .loop-spec/features/{slug}/gate-logs/{artifact}.pre-revision.md \
        {artifact_path} > /tmp/{gate}-delta.diff || true
```

```
SendMessage({
  to: "challenger-1",
  message: """
    Delta re-verify (per your solo-critic brief). The fix-list below was applied to {artifact}.
    Confirm each item is addressed and check the CHANGED sections only for new issues.
    Every DELTA-FINDINGS line is `unaddressed: <item>` or `introduced: "<added line>"`.

    Fix-list applied:
    {fix_list items, numbered}

    Diff:
    {content of /tmp/{gate}-delta.diff}

    Reply to lead with DELTA-VERIFIED or DELTA-FINDINGS, then go idle.
  """
})
```

Stop after SendMessage. The harness resumes this turn on `TeammateIdle` from `challenger-1`. Never AskUserQuestion as a wait. Append the reply to a new
`gate-logs/{gate}-round-{next}.md` (titled `(delta re-verify)`) — `gate.sh round` supplies
`{next}` — and emit a `gate_round` event with `"mode":"delta"`:

- **`DELTA-VERIFIED`**: the gate passes — append the `gateHistory` pass entry
  (convergence: `"delta-verified"`), reset `currentGate` (below), proceed to `{next_step}`.
- **`DELTA-FINDINGS`**: adjudicate the tagged findings per the table above. A delta
  finding is in scope only when it names an unaddressed fix-list item or quotes a line
  the revision added (`skills/shared/team-prompts/critic.md`); anything else is dropped
  with a one-line reason in the gate-log. A surviving item stays:
  keep it on the fix-list (stricter bias). Then start a new fix round from the top of
  this section — the fail entry, then `gate.sh next`, which decides whether the round
  runs. Never spawn a second critic and never loop without the probe's answer.

## fix_list empty

One call appends the pass entry and closes the gate, in that order:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/graph/gate.sh" pass --feature-dir "$feature_dir" \
  --rounds <N> --convergence <single-critic | delta-verified | cap-reached> \
  --challenger-model "<model>"
```

Do not clear `currentGate` any other way, and never before this call. The reset is a
zeroed OBJECT, never null: `graph/cycle.graph.json` declares `currentGate` in the
`reads[]` of both critique subgraph nodes, and `lib/graph/state.sh assert-reads` fails a
node whose declared read is null. A run that nulled it by hand dead-ended the engine
mid-gate and lost a human gate during the hand-repair that followed.

Proceed to `{next_step}`.

## Resume (gate in progress)

When the phase resumes with `currentGate.round > 0`: re-run from the single-critic
findings pass with the existing gate-logs inlined as prior context. There is no
advocate transcript to reload.
