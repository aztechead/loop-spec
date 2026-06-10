# QUALITY

## Test Framework

The project uses hand-rolled bash test harnesses. There is no third-party test framework. Each test file implements a `check()` helper that compares expected vs actual values and accumulates PASS/FAIL counts, then exits 1 if any failures occurred. Tests have no external dependencies beyond bash, git, jq, and python3 (python3 is used only in `task-created.sh`'s test helper to strip JSON fields, not in the harness itself).

## Test Suite Status

`tests/run-all.sh` covers the suites listed below; the deleted `tests/lib/state-write.test.sh` (removed in v1.0.0 alongside `lib/state-write.sh`) is no longer referenced.

| Suite | File | Assertions | Notes |
|---|---|---|---|
| validate-agents (schema) | `tests/validate-agents.sh` | 14 agents x 6 checks = 84 | PASS (run manually) |
| validate-agents (fixture) | `tests/validate-agents.test.sh` | 1 | PASS |
| restrict-agent-paths | `hooks/restrict-agent-paths.test.sh` | 12 | PASS |
| lib/git-ops | `tests/lib/git-ops.test.sh` | 10 | PASS |
| lib/gsd-ingest | `tests/lib/gsd-ingest.test.sh` | 17 | PASS |
| lib/feature-write | `tests/lib/feature-write.test.sh` | 8 | PASS |
| lib/team-ops | `tests/lib/team-ops.test.sh` | 8 | PASS |
| hooks/team/task-completed | `hooks/team/task-completed.test.sh` | 11 | PASS |
| hooks/team/task-created | `hooks/team/task-created.test.sh` | 10 | PASS |
| hooks/team/teammate-idle | `hooks/team/teammate-idle.test.sh` | 6 | PASS |

Total unit assertions: 83 (excluding the 84 validate-agents schema checks which run as a single pass/fail).

The `smoke.sh` end-to-end test requires a live Claude CLI with the plugin installed and is not included in `run-all.sh`. It is the required gate for every release tag.

## Coverage Summary

Source units with tests:

| Source | Test File |
|---|---|
| `lib/feature-write.sh` | `tests/lib/feature-write.test.sh` |
| `lib/git-ops.sh` | `tests/lib/git-ops.test.sh` |
| `lib/gsd-ingest.sh` | `tests/lib/gsd-ingest.test.sh` |
| `lib/team-ops.sh` | `tests/lib/team-ops.test.sh` |
| `hooks/restrict-agent-paths.sh` | `hooks/restrict-agent-paths.test.sh` |
| `hooks/team/task-completed.sh` | `hooks/team/task-completed.test.sh` |
| `hooks/team/task-created.sh` | `hooks/team/task-created.test.sh` |
| `hooks/team/teammate-idle.sh` | `hooks/team/teammate-idle.test.sh` |
| `tests/validate-agents.sh` (structural rules) | `tests/validate-agents.test.sh` |

Source units without dedicated unit tests:

| Source | Coverage path |
|---|---|
| `skills/cycle/SKILL.md` | smoke.sh end-to-end only |
| `skills/plan/SKILL.md` | smoke.sh end-to-end only |
| `skills/verify/SKILL.md` | smoke.sh end-to-end only |
| `skills/execute/SKILL.md` | smoke.sh end-to-end only |
| `skills/map-codebase/SKILL.md` | smoke.sh end-to-end only |
| `skills/discuss/SKILL.md` | smoke.sh end-to-end only |
| `skills/shared/SKILL.md` | not covered |
| All 14 `agents/*.md` prompt bodies | validate-agents covers schema; prompt content is not tested |
| `skills/shared/team-prompts/*.md` | not covered |

Test file to source file ratio: 8 unit test files covering 8 of 8 bash lib and hook scripts (100% of bash library coverage). The 6 skill SKILL.md files, 14 agent definition bodies, and 4 team-prompt templates are prose-format prompts; they are not unit-testable and covered only at the integration level via smoke.sh.

## Lint Status

No linter is configured for this project.

- `shellcheck` is absent from the environment. No `.shellcheckrc` is present.
- `markdownlint` / `markdownlint-cli2` are absent. No markdownlint config is present.
- `yamllint` is installed but there are no `.yml` / `.yaml` files in the project (only JSON and Markdown).
- No CI pipeline exists (no `.github/` directory).

Lint status: not run (no configured linter).

## Type Check Status

The project is not a typed language project. Source is bash and Markdown. The only Python in the repository is a small inline snippet in `hooks/team/task-created.test.sh` (used to strip a JSON field in a test helper) and the fixture at `tests/fixtures/minimal-py/`. Neither is part of the project's own type surface.

No type checker (`mypy`, `pyright`, `tsc`) is configured or applicable to the core project.

Type check status: not applicable.

## Code Quality Standards

### Enforced at commit time

- `git commit --no-verify` is explicitly prohibited by `CLAUDE.md`. All commits must pass the pre-commit hook chain.
- Conventional commit format is required: `feat: NO_JIRA <message>`, `fix:`, `docs:`, `chore:`. Enforced by documented convention, not by a commit-msg hook.

### Enforced by the `validate-agents.sh` test

- Every agent file under `agents/` must have a YAML frontmatter block with `name`, `description`, `tools`, and `model` fields.
- `name` must match the filename exactly.
- `model` must be one of `claude-opus-4-7`, `claude-sonnet-4-6`, or `claude-haiku-4-5`.
- Role-restricted agents (`spec-compliance-reviewer`, `code-reviewer`, `advocate`, `challenger`) must not have `Write` or `Edit` in their tool allow-list.
- Agents must not contain `skills:` or `mcpServers:` frontmatter keys. This rule is exercised by `tests/validate-agents.test.sh` using the `tests/fixtures/agent-with-skills-key.md` fixture.
- The expected agent count is hard-coded to 14; adding an agent without updating the validator causes a suite failure.

### Enforced by the `restrict-agent-paths.sh` hook

- Write/Edit calls made by write-scoped agents are gated by a `PreToolUse` hook at runtime. Spec-writer, planner, and pattern-mapper agents are restricted to `docs/super-spec/features/**`. Mapper agents are restricted to `docs/super-spec/codebase/**`. Violations exit 2, blocking the tool call.

### Enforced by the `hooks/team/` hooks at runtime

- `task-created.sh` (`PreToolUse` on `TaskCreate`): requires every new task to carry metadata with `blockedBy`, `files`, `verifyCommand` (non-empty), and `acceptanceCriteria` (non-empty array). Missing or malformed metadata exits 2, blocking the tool call.
- `task-completed.sh` (`PostToolUse` on `TaskUpdate`): when a task is marked completed, runs the feature's `lint` and `typecheck` commands if `currentPhase` is `execute`. For `discuss` and `plan` phases, validates that task metadata includes `verifyCommand` and `acceptanceCriteria`. Failures exit 2.
- `teammate-idle.sh` (`TeammateIdle`): advisory only; always exits 0 with phase-aware guidance written to stderr.

### Library code conventions

- All bash scripts use `set -euo pipefail`.
- Scripts exit with documented exit codes (0 success, 1 bad invocation, 2 gate/I/O failure).
- Atomic writes in `lib/feature-write.sh`: writes to `.tmp`, syncs, rotates current to `.bak`, then renames. Invalid JSON is rejected before any file is touched.
- No external dependencies: the zero-dep philosophy from `CLAUDE.md` is reflected in the lib implementations (bash + jq + git only).

### Untested modules

- `skills/shared/SKILL.md`: shared prompt fragments are not tested independently.
- `skills/shared/team-prompts/*.md`: team role prompt templates have no unit or integration tests.
- Agent prompt bodies: validated structurally but prompt content quality is not mechanically verifiable.
