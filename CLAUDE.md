# loop-spec Contributor Guidelines

## Philosophy

- **Lean deps.** No npm/pip/brew package managers for shipped code. Runtime requires `bash >= 4`, `git`, `jq >= 1.5`, `python3 >= 3.6` (all ship on stock macOS; Alpine/distroless Linux needs `apk add jq python3`). All shipped code is markdown + bash + jq + python3 inline. One scoped exception: `extensions/pi/loop-spec.ts` and `extensions/opencode/loop-spec.ts` are TypeScript because those harnesses load extensions/plugins natively — they must import node builtins ONLY (no npm/bun install, ever; `tests/pi-extension.test.sh` and `tests/opencode-plugin.test.sh` enforce this).
- **Multi harness.** loop-spec ships as a Claude Code plugin, a pi (pi.dev) package, AND an opencode (opencode.ai) install from one source tree. `lib/harness.sh` is the detection seam; `skills/shared/pi-harness.md` and `skills/shared/opencode-harness.md` are the adaptation contracts. Every non-claude accommodation must be an additive branch keyed on that probe — never a change to the Claude Code path. Keep `package.json` (pi manifest) in version lockstep with `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` (`tests/validate-pi-manifest.test.sh` enforces it), and pin new cross-file harness couplings in `tests/pi-harness-coverage.test.sh` / `tests/opencode-harness-coverage.test.sh`.
- **Graphify is a hard requirement.** loop-spec's de-facto knowledge-graph solution is [graphify](https://github.com/Graphify-Labs/graphify) (PyPI `graphifyy`, `uv tool install graphifyy`, needs Python 3.10+). `skills/shared/graphify-lifecycle.md` invokes Graphify's external assistant skill so semantic extraction uses the host model/authentication; `lib/graphify-preflight.sh` only checks, validates, and stages. The design phases query the graph (`graphify query|path|explain`, `graphify-out/GRAPH_REPORT.md`) to ground their work. Escape hatch: `LOOP_SPEC_REQUIRE_GRAPHIFY=0` (degraded Glob/Grep fallback). Offline tests do not invoke the live skill.
- **Skills are code.** Don't restructure tested skill content without eval evidence.
- **Spec-driven self-host.** All non-trivial changes go through the cycle skill.
- **Design for change: seams, not speculation.** Design to an interface, not an implementation; one unit, one reason to change; units receive their collaborators (params/args/env) instead of constructing them deep inside. Place boundaries where change is likely so the next tweak is a local diff — but never build speculation behind a seam (YAGNI cuts artifacts, never seams). Tests come first (TDD), simplicity beats cleverness, and a confirmed root cause gets a sibling sweep — same mechanism fixed in the same change, new mechanisms backlogged. Canonical: `skills/shared/design-for-change.md`, enforced by `tests/design-coverage.test.sh`.

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
- Manual end-to-end matrix: see `tests/README.md` (run against a live Claude Code session). Scripted headless e2e smoke: `bash tests/e2e/run-e2e.sh` (or `tests/run-all.sh --e2e`) — LIVE and opt-in, never part of the default offline suite.
- All commits must keep `tests/run-all.sh` passing.

## Commits

- Conventional commits: `feat: NO_JIRA <message>`, `fix:`, `docs:`, `chore:`.
- Never `--no-verify`.
- Always co-author Claude when AI-assisted.
