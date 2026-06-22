# Agent Frontmatter Reference

This directory contains agent definitions for the loop-spec system. Each agent is a Markdown file with YAML frontmatter followed by the agent's prompt body.

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

## Agents roster

| Name | Description | Model |
|------|-------------|-------|
| `advocate` | Makes the case for a SPEC or PLAN in the critique gate. Read-only. Argues the design is sound. | claude-opus-4-8 |
| `challenger` | Critiques a SPEC or PLAN in the critique gate. Read-only. Surfaces gaps, ambiguities, and flawed assumptions. | claude-opus-4-8 |
| `code-reviewer` | Quality + security review of feature branch diff. Read-only. | claude-sonnet-4-6 |
| `implementer` | Implements one task per dispatch in its own git worktree. Commits to worktree branch; orchestrator merges. | claude-sonnet-4-6 |
| `iterate-judge` | Judges the integrated result against the original goal (not just the SPEC checklist) in the ITERATE phase and classifies the highest-leverage gap (execute/plan/spec). Read-only; returns verdict JSON. | claude-opus-4-8 |
| `mapper-concerns` | Maps security, perf hotspots, tech debt. Writes only to docs/loop-spec/codebase/CONCERNS.md. | claude-sonnet-4-6 |
| `mapper-domain` | Maps business concepts, glossary, entity model. Writes only to docs/loop-spec/codebase/DOMAIN.md. | claude-sonnet-4-6 |
| `mapper-quality` | Maps test coverage, lint state, type safety. Writes only to docs/loop-spec/codebase/QUALITY.md. | claude-sonnet-4-6 |
| `pattern-mapper` | Maps feature concepts to existing-codebase analogs (imports, core pattern, error handling) so the planner can write house-style-conformant tasks. Writes only to docs/loop-spec/features/{slug}/PATTERNS.md. | claude-sonnet-4-6 |
| `planner` | Produces PATTERNS.md then PLAN.md (task DAG, files, verify cmds) from SPEC.md. Writes only to docs/loop-spec/features/**. | claude-opus-4-8 |
| `security-reviewer` | Adversarial security review persona. Checks input handling, authz, injection, secrets exposure, and unsafe defaults. Returns severity-ranked findings (CRITICAL/HIGH/MEDIUM/LOW). Never suppresses its own findings. | claude-sonnet-4-6 |
| `spec-compliance-reviewer` | Verifies one implementer's commit matches its task spec. Read-only. | claude-opus-4-8 |
| `spec-writer` | Produces SPEC.md from a discuss-phase conversation. Writes only to docs/loop-spec/features/**. | claude-opus-4-8 |
| `verifier` | Runs every acceptance criterion's verify command, writes VERIFICATION.md. | claude-sonnet-4-6 |

## Validation

Run `bash tests/validate-agents.sh` from the project root to verify all agent files pass schema checks.
