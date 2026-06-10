# Agent Frontmatter Reference

This directory contains agent definitions for the super-spec system. Each agent is a Markdown file with YAML frontmatter followed by the agent's prompt body.

## Required fields

| Field | Description |
|-------|-------------|
| `name` | Must match the filename without the `.md` extension. |
| `description` | One-line summary of the agent's role. Must be non-empty. |
| `tools` | YAML list of allowed tool names. |
| `model` | Model identifier. Allowed values: `claude-opus-4-8`, `claude-sonnet-4-6`, `claude-haiku-4-5`. |

## Optional fields

### `effort`

Signals the expected compute budget for a single dispatch of this agent.

Valid values:

| Value | Meaning |
|-------|---------|
| `low` | Narrow, well-defined task; typically under 10 tool calls. |
| `medium` | Moderate scope; 10-40 tool calls; default for most agents. |
| `high` | Complex multi-file task; 40-100 tool calls; may use a capable model. |
| `xhigh` | Extended analysis or large code generation pass; use sparingly. |
| `max` | Reserved for orchestrator-level agents making many sub-dispatches. |

Example:

```yaml
effort: high
```

### `disallowedTools`

YAML list of tool names the agent must not use, even if the harness would otherwise permit them. Use this to block destructive or out-of-scope operations for agents whose role boundary forbids them.

Common candidates: `WebFetch`, `WebSearch` (for agents that must stay offline), `Push`, `CreatePullRequest` (for agents that must not touch the remote).

Example:

```yaml
disallowedTools:
  - WebFetch
  - WebSearch
```

### `isolation`

Declares the execution environment the orchestrator must set up before dispatching this agent.

Valid values:

| Value | Meaning |
|-------|---------|
| `worktree` | Orchestrator creates a fresh `git worktree` for this agent. The agent receives `worktree_path` and `worktree_branch` in its input and must confine all writes to that path. Prevents cross-task file conflicts during parallel execution. |

Example:

```yaml
isolation: worktree
```

## Forbidden fields

`skills:` and `mcpServers:` are not valid agent frontmatter fields and will cause `tests/validate-agents.sh` to fail.

## Validation

Run `bash tests/validate-agents.sh` from the project root to verify all agent files pass schema checks.
