# Operating the sentinel unattended

The sentinel is **not a daemon** — deliberately. `scan`, `run`, and the
post-merge `watch` are ordinary entry points; unattended cadence is a
scheduler you already run (cron, launchd, GitHub Actions) invoking them
headlessly. Composition with a scheduler is documentation, not machinery: no
resident process, no queue service, nothing to install or babysit.

## The invocation

Use the harness's own headless CLI (`lib/harness.sh cli` — the same seam
`lib/issue-intake.sh` uses):

```bash
# Claude Code
claude -p "/loop-spec:sentinel run" --permission-mode acceptEdits

# pi
pi --mode json "/skill:sentinel run"

# opencode
opencode run --format json "Load the loop-spec-sentinel skill and run: run"
```

Run it from the target repo's root (the directory containing `.loop-spec/`).
One invocation processes **one** queue item on an L0 repo — that is the trust
governor, not a suggestion (`lib/trust.sh authorize --action sentinel-batch`).
Once the repo has earned L1 (see `bash lib/trust.sh level`), exporting
`LOOP_SPEC_MAX_FEATURES=N` is honored up to the `BATCH_L1` cap
(`.loop-spec/trust.conf`, default 5).

### What a run can and cannot do

- Every run is **PR-terminated**: the cycle ends at a draft/checkpoint PR.
  Nothing merges without a human at any trust level in this release
  (`trust.sh authorize --action auto-merge` is hard-denied).
- It **never chains past a failure**: a paused/escalated cycle ends the batch
  (`lib/autonomous-chain.sh --scope queue`).
- A picked item **cools down** for `PICK_COOLDOWN_HOURS` (default 24,
  `.loop-spec/sentinel.conf`), so a failing item cannot thrash-loop overnight.
- Every decision (picked / skipped / needs-human) is appended to
  `.loop-spec/sentinel-events.jsonl`; `/loop-spec:status` and
  `/loop-spec:retro` read it. Items the triage policy cannot classify wait as
  `needs-human` — check `/loop-spec:status` periodically; they are never run
  and never dropped.

## cron

```cron
# nightly at 02:15: process the head of the sentinel queue
15 2 * * * cd /path/to/repo && /usr/local/bin/claude -p "/loop-spec:sentinel run" --permission-mode acceptEdits >> .loop-spec/sentinel-cron.log 2>&1

# mornings: post-merge watch over yesterday's merges (repeat per shipped slug,
# or script a loop over docs/loop-spec/telemetry/runs/*.json without a watch field)
45 8 * * * cd /path/to/repo && bash lib/watch.sh run --slug <slug> >> .loop-spec/watch-cron.log 2>&1
```

## launchd (macOS)

`~/Library/LaunchAgents/dev.loop-spec.sentinel.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>dev.loop-spec.sentinel</string>
  <key>WorkingDirectory</key><string>/path/to/repo</string>
  <key>ProgramArguments</key><array>
    <string>/usr/local/bin/claude</string>
    <string>-p</string>
    <string>/loop-spec:sentinel run</string>
    <string>--permission-mode</string>
    <string>acceptEdits</string>
  </array>
  <key>StartCalendarInterval</key><dict>
    <key>Hour</key><integer>2</integer>
    <key>Minute</key><integer>15</integer>
  </dict>
  <key>StandardOutPath</key><string>/path/to/repo/.loop-spec/sentinel-cron.log</string>
  <key>StandardErrorPath</key><string>/path/to/repo/.loop-spec/sentinel-cron.log</string>
</dict></plist>
```

`launchctl load ~/Library/LaunchAgents/dev.loop-spec.sentinel.plist` to arm it.

## GitHub Actions

Same shape as `docs/examples/issue-to-pr.yml` (which remains the
issue-specific recipe — the sentinel generalizes it to all sources):

```yaml
name: loop-spec sentinel
on:
  schedule:
    - cron: "15 2 * * *"
  workflow_dispatch: {}

jobs:
  sentinel:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
      issues: write
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - name: Install claude + plugin
        run: |
          npm install -g @anthropic-ai/claude-code
          claude plugin marketplace add aztechead/loop-spec
          claude plugin install loop-spec@loop-spec-marketplace
      - name: Sentinel run (one item, PR-terminated)
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          LOOP_SPEC_REQUIRE_GRAPHIFY: "0"
        run: claude -p "/loop-spec:sentinel run" --dangerously-skip-permissions
```

(`--dangerously-skip-permissions` is acceptable inside a throwaway CI runner;
on a workstation prefer `--permission-mode acceptEdits`.)

## The post-merge watch (C2)

After a sentinel (or any cycle) PR merges, close the loop past the merge:

```bash
bash lib/watch.sh run --slug <slug> --window-hours 24
```

Run it once the window has elapsed (re-runs overwrite — latest wins). The
verdict lands in the feature's committed run digest and feeds the trust
governor: clean windows are what promote a repo toward L1+; a dirty window
queues a `watch-regression` backlog entry that the next sentinel scan triages
as a bug. Commit the digest change (`docs/loop-spec/telemetry/runs/<slug>.json`)
so the signal survives ephemeral runners.

## Kill switches and bounds, in one place

| Control | Where | Effect |
|---|---|---|
| per-source enables/weights, queue depth | `.loop-spec/sentinel.conf` | what the scan sees |
| `PICK_COOLDOWN_HOURS` (24) | `.loop-spec/sentinel.conf` | re-pick thrash guard |
| `LOOP_SPEC_MAX_FEATURES` (1) | env | requested batch size |
| `BATCH_L1` (5) | `.loop-spec/trust.conf` | hard cap on L1 batches; L0 is always 1 |
| `L1_STREAK`/`L2_STREAK`/`L3_STREAK` | `.loop-spec/trust.conf` | promotion thresholds |
| checkpoint PR on interruption | `LOOP_SPEC_CHECKPOINT_PR` (leave ON for sentinel runs) | reviewable artifact |
