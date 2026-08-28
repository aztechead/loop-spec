# Critique gate protocol — shared procedure for the DISCUSS and PLAN gates

Single source of truth for the critique-gate procedure both artifact gates run
(`spec-critique` in DISCUSS, `plan-critique` in PLAN). The phase skill invokes this
protocol with the parameters below and keeps only its deltas; the routing topology is
owned by `graph/critique.graph.json` and the ladder policy by `skills/shared/tier-matrix.md`
— this file owns the operational procedure between those two.

Contents: parameters · gate open · mode selection · single-critic pass · escalated
debate · adjudication · fix_list non-empty / empty · resume.

## Parameters (declared by the invoking phase)

| Parameter | DISCUSS | PLAN |
|---|---|---|
| `{phase}` | `discuss` | `plan` |
| `{gate}` | `spec-critique` | `plan-critique` |
| `{artifact}` | `SPEC.md` | `PLAN.md` |
| `{artifact_path}` | `docs/loop-spec/features/{slug}/SPEC.md` | `docs/loop-spec/features/{slug}/PLAN.md` |
| `{author}` | `spec-writer-1` (LEAD edits directly on the autonomous fast path) | `planner-1` |
| `{next_step}` | phase Step 5.75 | phase Step 4b |
| Skip policy | never (maintenance profile only, no security signal) | structural fast-path ∪ maintenance profile (no security signal) |
| Phase deltas | no-op-revision hash shortcut; lead-authored autonomous fixes | re-parse `tasks[]` after every revision |

The phase skill also declares the two adjudication actions that differ by phase:
`{user_intent_action}` (what to do when a finding depends on user intent) and
`{ungrounded_action}` (where the probed evidence goes). Security-signal handling, skip
policies, and the `gate_round` / `dispatch` telemetry emits stay in the phase skill —
they carry phase-specific arguments and are pinned there.

## Gate open

Update `feature.json` via `lib/feature-write.sh` and create the log directory:

```json
{
  "currentGate": {
    "phase": "{phase}",
    "gate": "{gate}",
    "round": 0,
    "advocateName": "advocate-1",
    "challengerName": "challenger-1",
    "startedAt": "<ISO-8601 now>"
  }
}
```

```bash
mkdir -p .loop-spec/features/{slug}/gate-logs/
```

## Mode selection

The escalation trigger is declared on the critique graph, not here:
`graph/critique.graph.json` routes `critique.escalate -> critique.debate` when
`lib/security-signal.sh` reports a match. The phase skill runs the probe (its file list
differs by phase) and obeys the declaration: signal non-empty → start directly in the
**Escalated debate**; otherwise **Single-critic pass**.

## Single-critic pass (default)

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

Wait for `TeammateIdle` from `challenger-1` and read its `FINDINGS:` / `NO-FINDINGS:`
message. Write it to `gate-logs/{gate}-round-1.md`:

```
# {gate} Round 1 (single-critic)

## challenger-1
<the FINDINGS/NO-FINDINGS message body>
```

Emit the phase's `gate_round` event (`"mode":"single-critic"`), then adjudicate.

## Escalated debate

Runs only when a ladder trigger fires (security signal; contested `[major]` or delta
deadlock from adjudication). `maxCritiqueRounds = 2` (fixed;
`skills/shared/tier-matrix.md`). When escalating from a single-critic pass, include all
existing `gate-logs/{gate}-round-*.md` content as `{prior_round_summaries}` in both spawn
prompts; `challenger-1` is already live — re-send it the debate brief via `SendMessage`
instead of spawning fresh.

Spawn `advocate-1` (model: `feature.models.advocate`):

```
SendMessage({
  to: "advocate-1",
  message: """
    [Populate from skills/shared/team-prompts/advocate.md with these substitutions:
      {slug} = slug
      {N} = 1
      {phase} = {phase}
      {artifact} = {artifact}
      {maxRounds} = maxCritiqueRounds
      {N_round} = 1
      {prior_round_summaries} = (empty on first run; load from gate-logs/ on resume)
    ]

    You will receive the first message from challenger-1. Wait for it before starting your round-1 response.
  """
})
```

Brief `challenger-1` (model: `feature.models.challenger`) the same way from
`skills/shared/team-prompts/challenger.md`, closing with:

```
Start round 1 now: read {artifact} and send your critique to advocate-1 via SendMessage.
After sending to advocate-1, wait for their response before sending your ROUND-1 DONE message to lead.
```

### Debate loop

For each round N = 1 .. maxCritiqueRounds:

1. Update `feature.json.currentGate.round = N` via `lib/feature-write.sh`.
2. Wait for `TeammateIdle` from `advocate-1` (it has sent both its cross-debate message
   and its lead round-end message for round N).
3. Wait for `TeammateIdle` from `challenger-1` (same condition).
4. Read the two `ROUND-N DONE[...]` messages sent to `lead`.
5. Append both message bodies to `gate-logs/{gate}-round-{N}.md` under `## advocate-1` /
   `## challenger-1` headings.
6. Emit the phase's `gate_round` event for round N.
7. Convergence check:
   - **Mutual DONE**: both messages start with `ROUND-{N} DONE:` (not `DONE-WITH-ISSUES`). Break.
   - **One-sided DONE for two consecutive rounds**: one teammate sent `ROUND-{N} DONE:`
     in rounds N and N-1 while the other sent `DONE-WITH-ISSUES`. Break.
   - **Cap reached**: N == maxCritiqueRounds. Record `notes: "cap reached"` in gateHistory. Break.
   - Otherwise N += 1 and message both teammates to start the next round (challenger
     reads {artifact} and critiques to advocate; advocate waits then responds).

## Adjudication

Read all `gate-logs/{gate}-round-*.md`.

**Single-critic adjudication (default mode):**

| Situation | Action |
|-----------|--------|
| `[major]` finding the lead agrees with | Add to fix-list. |
| `[major]` finding the lead disputes | Do NOT drop it — ESCALATE to the full debate with all gate-logs as prior summaries. The debate is the tiebreak; a solo gate may only bias stricter, never looser. |
| `[minor]` finding | Lead's judgment: add to fix-list or drop. Every dropped `[minor]` is logged in the gate-log with a one-line reason — never silently. |
| Finding depends on user intent | Escalate via `AskUserQuestion`. Autonomous mode: no escalation — `{user_intent_action}` per the phase skill, and add it to the fix-list so the artifact states it explicitly. |
| Finding is an ungrounded external claim (`UNGROUNDED:` line) | Lead runs the suggested read-only probe ITSELF (teammates have no Bash), appends it to the evidence ledger, then `{ungrounded_action}` per the phase skill (or converts the claim to an ASSUMPTION if the probe is impossible). |

**Escalated-debate reconciliation (when the debate ran):**

| Situation | Action |
|-----------|--------|
| Challenger raises point advocate also flagged as risk | High-confidence. Add to fix-list. |
| Challenger raises point advocate explicitly defended | Evaluate; pick the stronger argument. Add to fix-list if challenger wins. |
| Both agree | No action. |
| Neither resolves (depends on user intent) | Same user-intent row as above. |
| `UNGROUNDED:` line | Same probe row as above. |

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
  "advocateModel": "<model | null when the gate never escalated>",
  "challengerModel": "<model>",
  "rounds": <N (single-critic: 1 + delta rounds)>,
  "convergence": "<single-critic | delta-verified | mutual-done | cap-reached | one-sided>",
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
lead its completion message, then go idle. (Phase deltas apply: the DISCUSS autonomous
fast path has the LEAD edit directly; PLAN re-parses `tasks[]` from the completion
message.)

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

Wait for `TeammateIdle` from `challenger-1`, append the reply to a new
`gate-logs/{gate}-round-{next}.md` (titled `(delta re-verify)`), and emit a `gate_round`
event with `"mode":"delta"`:

- **`DELTA-VERIFIED`**: the gate passes — append the `gateHistory` pass entry
  (convergence: `"delta-verified"`), reset `currentGate` (below), proceed to `{next_step}`.
- **`DELTA-FINDINGS`**: adjudicate the tagged findings per the tables above and start a
  new fix round (retries unbounded). **Deadlock escalation:** if the same finding
  survives two consecutive delta rounds, the author and critic are stuck — escalate to
  the full debate with all gate-logs as prior summaries.

(When the escalated debate produced the fix-list, the delta re-verify still applies — the
debate does not re-run for a revision; only a deadlock or a new contested `[major]`
re-enters it.)

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

When the phase resumes with `currentGate.round > 0`: gate-logs holding only
single-critic/delta rounds (no advocate entries) → re-run from the single-critic findings
pass with the existing gate-logs inlined as prior context. Advocate entries present
(escalated debate) → load all `gate-logs/{gate}-round-*.md` content into both spawn
prompts as `{prior_round_summaries}` and restart the debate from
`currentGate.round + 1`.
