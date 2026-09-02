# Agent Frontmatter Reference

This directory contains agent definitions for the loop-spec system. Each agent is a Markdown file with YAML frontmatter followed by the agent's prompt body.

## Required fields

| Field | Description |
|-------|-------------|
| `name` | Must match the filename without the `.md` extension. |
| `description` | One-line summary of the agent's role. Must be non-empty. Claude Code uses this field to decide **automatic delegation**, so every loop-spec agent description ends with the guard clause "Cycle-internal: dispatched by loop-spec skills with a structured brief; not for ad-hoc auto-delegation." — these agents assume a structured brief (paths, SHAs, slugs) and misbehave when auto-delegated a bare user request. |
| `tools` | YAML list of allowed tool names. |
| `model` | Claude model selector. Every shipped agent uses `inherit`; explicit aliases and full IDs are supported by current Claude Code. OpenCode's generated agents omit Claude selectors and inherit natively. |

## Optional fields

### `effort`

Signals the expected compute effort for a single dispatch of this agent.

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

Common candidates: `Agent` (for roles that must not nest a dispatch), `Push`, `CreatePullRequest` (for agents that must not touch the remote). Do not block `WebFetch` or `WebSearch`: the host program decides which lookup tools exist, and `skills/shared/engineering-directives.md` tells roles to use whatever version and advisory lookup the harness offers.

Example:

```yaml
disallowedTools:
  - Agent
```

### `isolation` — forbidden (`tests/validate-agents.sh` enforces this)

Claude Code supports `isolation: worktree` in agent frontmatter, and the harness (not
the orchestrator) creates the worktree. loop-spec does not use it, for two reasons:

1. **It is invisible to the tool boundary.** Frontmatter isolation never appears in the
   Agent call's `tool_input`, so `hooks/team/no-worktrees-guard.sh` cannot see it and
   `LOOP_SPEC_WORKTREES=0` could not be enforced for that agent. The equivalent
   *parameter* form, `Agent({isolation: "worktree"})`, is visible and is denied.
2. **It branches from the base commit,** which hides prior tasks' committed changes in a
   sequential DAG and strands work in a throwaway worktree (see `agents/implementer.md`).

Task worktrees are created explicitly by the EXECUTE dispatch contract
(`git worktree add <path> -b task/<id>-<slug> feat/<slug>`), which branches from the
feature-branch HEAD and is a single, auditable mechanism.

### `color`

Display color in the harness task list / transcript. loop-spec assigns colors by role family so a running cycle reads at a glance: authors (`spec-writer`, `planner`) blue, critique gate (`challenger`) purple, review gates (`code-reviewer`, `spec-compliance-reviewer`, `security-reviewer`) red, judge (`iterate-judge`) orange, `implementer` green, `verifier` yellow, `pattern-mapper` cyan. Allowed values: `red`, `blue`, `green`, `yellow`, `purple`, `orange`, `pink`, `cyan` (validated).

### `memory`

Persistent memory scope (`user` | `project` | `local`, validated). Grants the agent a directory that survives across dispatches; `project` scope (`.claude/agent-memory/<name>/`) is shareable via version control. **Setting `memory` auto-enables Write/Edit for the agent**, so a read-only role that gains memory MUST get a matching path-restriction case in `hooks/restrict-agent-paths.sh` confining its writes to `.claude/agent-memory/**` (see the `code-reviewer` case) plus test cases. Currently enabled for `code-reviewer` (recurring findings) and `pattern-mapper` (concept -> analog cache). Memory content is advisory: agents must re-verify remembered paths/claims against the current codebase before acting on them.

## Forbidden fields

`skills:`, `mcpServers:`, `hooks:`, `permissionMode:`, and `maxTurns:` are not valid loop-spec agent frontmatter fields and will cause `tests/validate-agents.sh` to fail. Claude Code ignores `hooks`, `mcpServers`, and `permissionMode` on plugin-distributed agents (security restriction) — a field that silently does nothing is a defect. `skills:` preloading is deliberately excluded: agents receive their full brief in the dispatch prompt. `maxTurns:` is forbidden by policy: loop-spec agents run full bore; the only bound the plugin respects is the ITERATE round limit, so no per-dispatch turn caps.

## Agents roster

| Name | Description |
|------|-------------|
| `advocate` | Not dispatched. Critique is challenger-only; retained for schema/validation. Read-only. |
| `challenger` | Critiques a SPEC or PLAN in the critique gate. Read-only. Surfaces gaps, ambiguities, and flawed assumptions. |
| `code-reviewer` | Quality + security review of feature branch diff. Read-only. |
| `implementer` | Implements one task per dispatch in its own git worktree. Commits to worktree branch; orchestrator merges. |
| `iterate-judge` | Judges the integrated result against the original goal (not just the SPEC checklist) in the ITERATE phase and classifies the highest-leverage gap (execute/plan/spec). Read-only; returns verdict JSON. |
| `pattern-mapper` | Maps feature concepts to existing-codebase analogs (imports, core pattern, error handling) so the planner can write house-style-conformant tasks. Writes only to docs/loop-spec/features/{slug}/PATTERNS.md. |
| `planner` | Produces PATTERNS.md then PLAN.md (task DAG, files, verify cmds) from SPEC.md. Writes only to docs/loop-spec/features/**. |
| `security-reviewer` | Adversarial security review persona. Checks input handling, authz, injection, secrets exposure, and unsafe defaults. Returns severity-ranked findings (CRITICAL/HIGH/MEDIUM/LOW). Never suppresses its own findings. |
| `spec-compliance-reviewer` | Verifies one implementer's commit matches its task spec. Read-only. |
| `spec-writer` | Produces SPEC.md from a discuss-phase conversation. Writes only to docs/loop-spec/features/**. |
| `verifier` | Runs every acceptance criterion's verify command, writes VERIFICATION.md. |

Every shipped agent declares `model: inherit`; there is no per-agent model column
to keep in sync. See `skills/shared/model-matrix.md` for the override precedence.

## Validation

Run `bash tests/validate-agents.sh` from the project root to verify all agent files pass schema checks.
