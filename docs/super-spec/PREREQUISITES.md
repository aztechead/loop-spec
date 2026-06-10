# Prerequisites

## CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS

The cycle skill's agent-teams mode requires the experimental agent teams feature to be enabled in Claude Code.

### Required environment variable

```bash
export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
```

Set this before launching `claude` or add it to the `env` section of your `.claude/settings.json`:

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  }
}
```

### Minimum Claude Code version

v2.1.32 or later is required. Check your current version:

```bash
claude --version
```

### Required harness capabilities

The cycle skill assumes the harness supports:

- **TeamCreate / TeamDelete** - create and tear down a named team of agents
- **TaskCreate / TaskUpdate / TaskGet / TaskList** - including `metadata` round-trip and `owner` release
- **SendMessage** - lead-to-teammate and teammate-to-teammate messaging
- **Concurrent `TaskUpdate` serialization** - only one of N concurrent self-claims for the same task id succeeds

These are exercised by `tests/smoke.sh`. If the harness lacks any of them, phases will fail at the first call site.
