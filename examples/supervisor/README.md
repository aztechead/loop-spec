# Reference supervisor (Claude Agent SDK)

For the engineer embedding loop-spec in a Python app on the Claude Agent SDK. When
you finish this page you can run one autonomous cycle under a supervisor that owns
the state store, the event stream, and every interview answer, and you can see which
SDK seam each port lands on.

**This is a reference supervisor, not a supported product surface.** Nothing here is
imported by loop-spec, and it carries no compatibility guarantee across releases. The
contract it implements is `docs/loop-spec/supervisor-interface.md`.

## Files

- `supervisor.py` — the loop: writes `.loop-spec/profile.json`, resolves it into the
  SDK `env`, loads the plugin from this checkout, answers questions, reissues the cycle
  after each phase handoff, and exits on the terminal result.
- `append-sink.sh` — the event-sink adapter it names in the profile: appends each
  event line to `LOOP_SPEC_EVENT_SINK_FILE`.

## Where each port lands on the SDK

| Port | SDK seam | In `supervisor.py` |
|---|---|---|
| profile | `ClaudeAgentOptions.env` | `resolved_env` merges `lib/profile.sh resolve` under the process environment |
| state store | the working directory (`cwd`); transcripts go through `session_store` | `write_profile` names `store-mirror.sh` and a mirror directory |
| event sink | `PostToolUse` hook on `Bash` (native), `LOOP_SPEC_EVENT_SINK` (port) | `phase_markers` prints the markers; `append-sink.sh` keeps every event line |
| decision oracle | `can_use_tool` with `tool_name == "AskUserQuestion"` | `answer_question` returns the `(Recommended)` label |
| lifecycle | one `query()` per phase; `ResultMessage`; `.loop-spec/last-result.json` | the `for round_no` loop reissues `/loop-spec:cycle autonomous` on `phase-handoff` |

## Run it

Prerequisites: Python 3.10 or later, `pip install claude-agent-sdk`, a Claude login or
`ANTHROPIC_API_KEY`, and `git`. DELIVER also needs `gh auth status` and an `origin`
remote; without them the run ends at delivery with `gh_missing`.

```bash
mkdir -p /tmp/demo-app && git -C /tmp/demo-app init -q
python3 examples/supervisor/supervisor.py \
  --project /tmp/demo-app \
  --task "a Python CLI that prints the n-th Fibonacci number, with tests" \
  --model haiku
```

Success looks like one `[init]` line naming the loaded plugin, `[oracle]` lines for
each question the supervised path asked, `[hook]` and sink lines for every phase
marker, and a final `[round N] ... result={"status": "completed", ...}` line with
exit code 0. The mirror directory beside the project holds a copy of the feature
directory after every write, and the events file holds every event line.

When it fails: no `[init]` plugin means the path passed to `plugins` is not this
checkout; a `result=None` line means no terminal result was published, and
`bash lib/cycle-reconcile.sh` in the project turns the armed run into one; a result
with `"reason": "gh_missing"` is delivery without GitHub, and the verified branch is
still in the project.
