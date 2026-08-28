# Critique gate protocol — shared procedure for the DISCUSS and PLAN gates

Single source of truth for the critique-gate procedure both artifact gates run
(`spec-critique` in DISCUSS, `plan-critique` in PLAN). The phase skill invokes this
protocol with the parameters below and keeps only its deltas; the routing topology is
owned by `graph/critique.graph.json` and the skip policy by `skills/shared/tier-matrix.md`
— this file owns the operational procedure between those two. Critique is
**challenger-only**: there is no advocate and no debate round.

Contents: parameters · gate open · single-critic pass · adjudication · fix_list
    non-empty / empty · resume.

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

Update `feature.json` via `lib/feature-write.sh` and create the log directory.
`advocateName` stays null (schema key retained for resume; no advocate is spawned):

```json
{
  "currentGate": {
    "phase": "{phase}",
    "gate": "{gate}",
    "round": 0,
    "advocateName": null,
    "challengerName": "challenger-1",
    "startedAt": "<ISO-8601 now>"
  }
}
```

```bash
mkdir -p .loop-spec/features/{slug}/gate-logs/
```

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

Gate retries are unbounded (full bore): re-run the fix/verify loop until the gate passes.
The only bound the cycle respects is ITERATE's round limit.

Append the fail entry to `feature.json.gateHistory` via `lib/feature-write.sh` BEFORE
re-dispatching (the re-dispatch path returns to the gate and would never reach an append
placed after the return):

```json
{
  "phase": "{phase}",
  "gate": "{gate}",
  "attempt": <attempt number>,
  "result": "fail",
  "advocateModel": null,
  "challengerModel": "<model>",
  "rounds": <N (single-critic: 1 + delta rounds)>,
  "convergence": "<single-critic | delta-verified | deadlock-kept>",
  "findingsAddressed": [<fix_list items>],
  "notes": null
}
```

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

    Fix-list applied:
    {fix_list items, numbered}

    Diff:
    {content of /tmp/{gate}-delta.diff}

    Reply to lead with DELTA-VERIFIED or DELTA-FINDINGS, then go idle.
  """
})
```

Stop after SendMessage. The harness resumes this turn on `TeammateIdle` from `challenger-1`. Never AskUserQuestion as a wait. Append the reply to a new
`gate-logs/{gate}-round-{next}.md` (titled `(delta re-verify)`), and emit a `gate_round`
event with `"mode":"delta"`:

- **`DELTA-VERIFIED`**: the gate passes — append the `gateHistory` pass entry
  (convergence: `"delta-verified"`), reset `currentGate` (below), proceed to `{next_step}`.
- **`DELTA-FINDINGS`**: adjudicate the tagged findings per the table above and start a
  new fix round (retries unbounded). **Deadlock:** if the same finding survives two
  consecutive delta rounds, keep it on the fix-list (stricter bias) and continue the
  delta loop — do not hang the cycle and do not spawn a second critic. Record
  `convergence: "deadlock-kept"` on the next fail entry.

## fix_list empty

Append the pass entry to `feature.json.gateHistory` (same shape as the fail entry with
`"result": "pass"` and `"findingsAddressed": []`), then reset `currentGate` to zeroed
state via `lib/feature-write.sh`:

```json
{
  "currentGate": {
    "phase": null,
    "gate": null,
    "round": 0,
    "advocateName": null,
    "challengerName": null,
    "startedAt": null
  }
}
```

Proceed to `{next_step}`.

## Resume (gate in progress)

When the phase resumes with `currentGate.round > 0`: re-run from the single-critic
findings pass with the existing gate-logs inlined as prior context. There is no
advocate transcript to reload.
