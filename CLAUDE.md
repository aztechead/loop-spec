# loop-spec Contributor Guidelines

## Philosophy

- **Lean deps.** No npm/pip/brew package managers for shipped code. Runtime requires `bash >= 4`, `git`, `jq >= 1.5`, `python3 >= 3.6` (all ship on stock macOS; Alpine/distroless Linux needs `apk add jq python3`). All shipped code is markdown + bash + jq + python3 inline.
- **Graphify is a hard requirement.** loop-spec's de-facto code-graph solution is [graphify](https://github.com/safishamsi/graphify) (PyPI `graphifyy`, `uv tool install graphifyy`, needs Python 3.10+). The cycle aborts at startup if it is missing (`lib/graphify-preflight.sh check`); the design phases (SPEC/DISCUSS/PLAN) query the graph (`graphify query|path|explain`, `graphify-out/GRAPH_REPORT.md`) to ground their work. Escape hatch for constrained environments: `LOOP_SPEC_REQUIRE_GRAPHIFY=0` (degraded Glob/Grep fallback). The offline test suite never invokes the cycle, so it does not require graphify.
- **Skills are code.** Don't restructure tested skill content without eval evidence.
- **Spec-driven self-host.** All non-trivial changes go through the cycle skill.

## Adding a Skill

1. New dir under `skills/{name}/`.
2. `SKILL.md` with required frontmatter (`name`, `description`).
3. Reference shared/ infra; do not duplicate.
4. Add to README's skills list.

## Adding an Agent

1. New file `agents/{role}.md` (bare role name, no `loop-spec-` prefix). The harness namespaces it as `loop-spec:{role}`; reference it from skills as `subagent_type: "loop-spec:{role}"`.
2. Frontmatter: `name` (must equal the filename `{role}`), `description`, `tools` (allow-list), `model` (default).
3. Document role boundary in prompt body.
4. If write-access scoped, add a `{role})` case in `hooks/restrict-agent-paths.sh` (the hook normalizes the namespaced caller to the bare role) and a test case.

## Referencing bundled files from a skill

Skills must use `${CLAUDE_SKILL_DIR}` (the documented skill substitution) to reach bundled scripts, NOT `${CLAUDE_PLUGIN_ROOT}` (a hooks/MCP variable that is empty in skill Bash). A skill at `skills/<name>/` reaches `lib/` and `hooks/` via `${CLAUDE_SKILL_DIR}/../../lib/...` and `${CLAUDE_SKILL_DIR}/../../hooks/...`. `${CLAUDE_PLUGIN_ROOT}` remains correct in `hooks/hooks.json` and MCP/LSP configs only.

## Tests

- Test runner: `bash tests/run-all.sh` from repo root (validators + hook + lib units + workflow syntax + the bundled loop-runner offline suite).
- Manual end-to-end matrix: see `tests/README.md` (run against a live Claude Code session; there is no scripted headless e2e test).
- All commits must keep `tests/run-all.sh` passing.

## Commits

- Conventional commits: `feat: NO_JIRA <message>`, `fix:`, `docs:`, `chore:`.
- Never `--no-verify`.
- Always co-author Claude when AI-assisted.
