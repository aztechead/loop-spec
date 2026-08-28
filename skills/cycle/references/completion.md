# On completion — terminal result, summary, and chaining (cycle)

Read when the cycle's "On completion" section is reached: DELIVER wrote
`delivery.json.nextPhase = "completed"` and the graph traversal is at (or about to
enter) its terminal node. This file owns the terminal result write, the summary
contract, and the autonomous chain decision.


This section is reachable only after DELIVER wrote `delivery.json.nextPhase =
"completed"`. Assert sidecar `status == "ready-for-review"` or
`status == "delivered-draft"`; otherwise stop with
`delivery-incomplete` and leave tracked `feature.json.currentPhase = "deliver"`.
Never overwrite or commit the tracked phase pointer here.

Write the machine-readable result and completed event while the active feature root is
still available:

```bash
feature_dir=".loop-spec/features/${slug}"
_pr_url="$(jq -r '.prUrl // empty' "$feature_dir/feature.json")"
_summary="$(jq -r '.iterate.lastVerdict.summary // empty' "$feature_dir/feature.json")"
[[ -n "${_summary//[[:space:]]/}" ]] || _summary="Cycle completed; PR delivered."
_write_rc=0
bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-result.sh" write "$feature_dir" \
  --status completed --summary "$_summary" ${_pr_url:+--pr-url "$_pr_url"} || _write_rc=$?
if [[ "$_write_rc" -ne 0 ]]; then
  echo "cycle-result.sh write failed (rc=$_write_rc); retrying once" >&2
  bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-result.sh" write "$feature_dir" \
    --status completed --summary "$_summary" ${_pr_url:+--pr-url "$_pr_url"}
fi
```

`run.sh --step` already publishes this result when it enters the `completed`
node; a second write is idempotent. `write-terminal --outcome delivered` is
the same alias if the agent reaches for DELIVER's own word. A sidecar whose
`status` is `delivered-draft` is a successful completion with a green draft PR
(enterprise sign-off), not a gap: `outcome` is `delivered-draft`, `workDelivered`
is true, and `converged` stays false until the PR is marked ready. A non-zero write
is a publication failure — retry, then stop. Do not continue as if the pointer
landed. The maintenance short path still reaches this section: ITERATE and DELIVER still run, and a headless caller still gates on this pointer. Do not
exit after EXECUTE because the task felt like a sync. An empty ITERATE summary
does not block publication: the writer falls back to "Cycle completed; PR delivered."

The run digest was finalized immediately before DELIVER (machine-local by default;
part of the checked SHA only when `LOOP_SPEC_COMMIT_TELEMETRY=1` or the repo already
tracks its digest corpus). Do not rewrite or recommit it here: DELIVER's successful
target SHA is now immutable.

The summary follows `skills/shared/report-style.md`: outcome first, state restated,
wins marked, no preamble/closers, scores in percentages.

**The completion report contains no self-authored deferrals** — no "deferred items",
"follow-ups", "future work", or "next steps" the model chose on its own; everything
in the spec shipped or the run is not complete (`skills/shared/no-deferral.md`).
Draft the summary, then probe it before printing:

```bash
printf '%s' "$summary" | bash "${CLAUDE_SKILL_DIR}/../../lib/deferral-lint.sh" text -
```

A flag means dropped scope, not bad wording: resume the cycle and ship the flagged
item (gate-marked `iterate-budget-spent:` / `iterate-terminal:` / `verify-deferred`
lines are the only exemptions and pass the probe as written).

Print warnings first, then a durable per-target delivery summary from
`delivery.json.targets[]` (repo/name, PR URL, exact target SHA, checks status, and the
DELIVER Step 4 terminal PR feedback check result — review decision + unresolved count
per `skills/shared/pr-feedback-check.md`),
followed by elapsed time/cost and backlog count. Workspace mode prints every changed and
skipped repository. A single-repo run also prints top-level `prUrl`. If the feedback
check reported `changesRequested`, the summary's last line recommends
`/loop-spec:revise <pr-number>` as the next command.

`.loop-spec/last-result.json` and `events.jsonl` are local telemetry and are not committed.
The PR body (rendered by `lib/pr-body.sh`) is concise GitHub-flavored markdown: goal,
bounded Summary/Acceptance/Verification/Convergence excerpts, warnings, and links to
the committed full artifacts — captured before the exact-SHA check.

**Autonomous chaining (`feature.json.autonomous == true`).** The chain decision remains
deterministic:

```bash
verdict="$(bash "${CLAUDE_SKILL_DIR}/../../lib/autonomous-chain.sh" should-chain "$feature_dir" --completed "$features_completed_this_invocation")"
```

Only sidecar `delivery.status == "ready-for-review"` can chain. Stable no-chain reasons include
`delivery-incomplete`, `max-features-reached`, `feature-not-completed`,
`next-entry-terminal`, `backlog-empty`, `no-budget-spent-gaps`, and `not-autonomous`.

For a Claude single-repo feature worktree, `ExitWorktree({action:"keep"})` is the final
operation after DELIVER, result writing, summary, and chain-decision capture. Keep the
worktree until merge. OpenCode/ADK in-place features and workspace mode do not call an
exit tool. If the captured verdict chains, leave/adopt the next feature root only after
this final operation after DELIVER.
