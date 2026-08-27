# loop-spec Contributor Guidelines

## Philosophy

Each bullet names a moment you can recognize while working, an action with an artifact,
and what to do instead of stalling. A preference with no trigger does not fire.

- **When you would add a package.json, requirements.txt, or brew formula to shipped code**, don't. Runtime is `bash >= 3.2`, `git`, `jq >= 1.5`, and `python3 >= 3.7` (Alpine/distroless: `apk add jq python3`). Shipped code is markdown, Bash, jq, and Python. Keep substantial Python in named `.py` modules; shell launchers own only argument and path setup. If the work cannot be expressed in those, put it in the matching exception directory and stop: `extensions/opencode/loop-spec.ts` imports node builtins ONLY (no npm/bun; `tests/opencode-plugin.test.sh`). `extensions/adk/loop_spec_adk/*.py` may import `google-adk>=2.7,<3` on Python >=3.10 — the only third-party import in the tree — and `lib/adk-install.sh` wires it into a user's project rather than generating a copy (`tests/adk-harness-coverage.test.sh`, `tests/adk-extension.test.sh`).
- **When you add a harness-specific path or a capability that is not on every harness**, add a branch behind `lib/harness.sh` and a probe that answers for ALL harnesses and fails safe. Never name-check one harness from another's point of view, and never edit another harness's path to land your change. The four peers are Claude Code (including the Claude Agent SDK), opencode, Google's Agent Development Kit, and OpenAI Codex. Adaptation contracts: `skills/shared/claude-harness.md`, `opencode-harness.md`, `adk-harness.md`, `codex-harness.md`. When you change a version declaration, run `bash lib/bump-version.sh <version>` (or `--check`) so `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `.codex-plugin/plugin.json`, and the README line stay in lockstep. Pin new cross-file couplings in `tests/opencode-harness-coverage.test.sh` / `tests/adk-harness-coverage.test.sh` / `tests/codex-harness-coverage.test.sh`.
- **When a phase needs to know where something lives**, Glob/Grep/read the tree (fan out to subagents on a large tree). Cite `file:line`. Do not add a code graph, symbol index, or embedding store: stored maps rot, and a rotted map is worse than none because it is wrong with authority. Durable knowledge the code cannot express goes in a curated artifact (`docs/loop-spec/bmad-scan-proposals.md` B6).
- **When you would restructure a tested skill body** (`skills/*/SKILL.md` that `tests/run-all.sh` pins), don't. Change behavior with a probe or a test first. Eval evidence is the artifact.
- **When you add a skill `description:`**, write it in the words someone would type, including when not to use it. A description that only summarizes what the skill does will not fire.
- **When a model judgment would SELECT A CODE PATH**, replace it with a deterministic probe and a test. Emit ANSWER and REASON on one line, fail safe when unknown, and let an explicit operator override outrank it. Judgment still belongs everywhere it is not selecting a branch. Scripts this already bit: `lib/security-signal.sh`, `lib/teams-capability.sh`, `lib/harness.sh entrypoint`, `lib/execute-rung.sh`.
- **When the change is a new surface, contract, or phase behavior**, run it through `/loop-spec:cycle`. The artifact is the feature directory under `docs/loop-spec/features/`. A one-shot edit is for a pin, a doc trigger, or a bug whose failing test already exists.
- **When you add or edit a file under `lib/`, `hooks/`, `skills/`, `extensions/`, or `tests/`**, climb the ladder in `skills/shared/laziness-ladder.md` before writing a new helper. Stop at the first rung that holds (YAGNI, then DRY). Run `bash lib/indirection-scan.sh scan <those files>` and `bash lib/duplication-scan.sh scan <those files>` in the same turn. If a rung says skip, ship the skip and say so in one line. Enforced by `tests/ponytail-coverage.test.sh`.
- **When you write or edit those same files**, match the neighbors (house style over habit); comments carry why, never what; fail loudly (the failure path). Read `skills/shared/human-code.md`. Before you finish, run `bash lib/house-style.sh compare <files>`, `bash lib/comment-tells.sh scan <files>`, `bash lib/failure-tells.sh scan <files>`. Enforced by `tests/human-code-coverage.test.sh`.
- **When you write or edit markdown the project ships**, name the reader (Docs for humans). One job per document; cite, never copy; fix the stale doc in the same diff. Read `skills/shared/human-docs.md`. Before you finish, run `bash lib/doc-tells.sh scan <markdown you touched>`. Enforced by `tests/human-docs-coverage.test.sh`.
- **When you add a boundary, a new helper, or a second implementation**, design to an interface (seams, not speculation); one unit, one reason to change; receive collaborators. Read `skills/shared/design-for-change.md`. Enforced by `tests/design-coverage.test.sh`.
- **When you would put mid-turn chatter or "be concise" into a hook, a skill, or this file**, don't. On Claude Code that only binds in `output-styles/loop-spec.md`. On the other harnesses, follow `skills/shared/report-style.md` because they have no output-style slot.

## Finding what is already bundled

`bash lib/surface.sh` answers "which bundled script, shared contract, or agent role covers
X?" from the tree, at call time. The bundled surface is well past a hundred scripts under
`lib/` and `hooks/`, plus every shared contract and role charter — more than a fresh
context can hold — and glob-then-grep-then-open-three-files is the tax every agent pays
otherwise.

- `surface.sh find <term> [term ...]` — entries whose path or purpose matches EVERY term.
- `surface.sh show <name>` — one entry's header block: usage, exit codes, tool allow-list.
  Read this before opening the file; it is usually the whole answer.
- `surface.sh covers <path>` — the suites `tests/run-all.sh` REGISTERS that name a path,
  so "what must I run after changing this?" is one call instead of a sweep. It reports
  mentions, not proven coverage: a suite using the path as a fixture is listed too, and
  over-reporting costs a test run while under-reporting ships an unpinned change.
- `surface.sh list [lib|shared|agent|all]` — the whole surface.

A bare name two files share (`checkpoint`) is refused with both candidates named, never
resolved to whichever sorts first.

This is NOT a stored map and must never become one: it writes nothing, caches nothing, and
derives every answer from the files that exist right now, so there is no artifact to rot
(the reason graphify was removed in 2.35). Each entry's purpose line is that file's OWN
header, which is why `tests/lib/surface.test.sh` fails when a bundled file's header does
not say what the file is for. Writing the header IS writing the index entry.

## Adding a Skill

1. New dir under `skills/{name}/`.
2. `SKILL.md` with required frontmatter (`name`, `description`). The `description` names when to use the skill in the words someone would type, and when not to.
3. Reference shared/ infra; do not duplicate.
4. Add to README's skills list.

## Adding an output style

Claude Code is the only harness with an output-style slot. When you change how the
plugin talks in chat (silence, length, shape), edit `output-styles/loop-spec.md`.
Keep `force-for-plugin: true` and `keep-coding-instructions: true`. Do not copy
those instructions into a SessionStart hook or this file: that slot is the only
place mid-turn silence binds. Other harnesses follow `skills/shared/report-style.md`.

Pin the file from `tests/output-style-coverage.test.sh`.

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

- **When you commit a change in this repo**, use a conventional subject: `feat: NO_JIRA <message>`, `fix:`, `docs:`, or `chore:`. Include `Co-Authored-By: Claude <noreply@anthropic.com>` when the commit is AI-assisted.
- **When a hook blocks the commit**, fix the finding or extend the hook with a test in the same change. Do not pass `--no-verify`.
