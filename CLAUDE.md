# loop-spec Contributor Guidelines

## Philosophy

- **Lean deps.** No npm/pip/brew package managers for base shipped code. Runtime requires `bash >= 3.2`, `git`, `jq >= 1.5`, and `python3 >= 3.7`; Alpine/distroless Linux needs `apk add jq python3`. Shipped code is markdown, Bash, jq, and Python. Keep substantial Python programs in named `.py` modules; shell launchers own only argument and path setup. Two scoped exceptions, both for harness bridges that a harness loads natively in its own language, and both narrow: `extensions/opencode/loop-spec.ts` is TypeScript and must import node builtins ONLY (no npm/bun install, ever; `tests/opencode-plugin.test.sh` enforces this). `extensions/adk/loop_spec_adk/*.py` may import `google-adk>=2.7,<3` and requires Python >=3.10 — the only third-party import in the tree — because an ADK bridge is not expressible without it; nothing outside that directory may import it, no other harness gains a dependency from it, and `lib/adk-install.sh` wires it into a user's project rather than generating a copy (`tests/adk-harness-coverage.test.sh` and `tests/adk-extension.test.sh` enforce both halves).
- **Multi harness, no reference harness.** loop-spec ships from one source tree for three PEER harnesses: Claude Code (including the Claude Agent SDK), opencode (opencode.ai), and Google's Agent Development Kit. None is the reference implementation and none is a port of another — each expresses the same cycle through the surface it actually has. `lib/harness.sh` is the detection seam; `skills/shared/claude-harness.md`, `skills/shared/opencode-harness.md`, and `skills/shared/adk-harness.md` are the adaptation contracts, and every harness has one. A capability that exists on only some harnesses (agent teams, `Workflow`, harness task lists, worktree execution roots) stays — gated by a deterministic probe that answers for ALL harnesses and fails safe, never by a name check written from one harness's point of view. Adding a harness means adding branches, never editing another harness's path. Keep `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` in version lockstep with the README line — use `bash lib/bump-version.sh <version>` to set all three declaration sites at once rather than editing them by hand, and `--check` to report drift — and pin new cross-file harness couplings in `tests/opencode-harness-coverage.test.sh` / `tests/adk-harness-coverage.test.sh`.
- **No stored code map; derive structure fresh.** loop-spec ships no code graph, no symbol index, and no embedding store. Structure is read from the tree when a phase needs it (Glob/Grep/read, fanned out to subagents so a large tree never grinds through one context), and a claim about the code is grounded by citing `file:line` — never by quoting a stored artifact. Graphify was a hard requirement from 2.29 to 2.34 and was removed in 2.35 on the evidence: across every feature authored while it was mandatory it produced zero citations, zero recorded refreshes, and zero evidence entries, while costing a Python 3.10+/uv dependency and a cycle-aborting startup gate. Stored maps rot, and a rotted map is worse than none because it is wrong with authority. Durable project knowledge that the code genuinely cannot express belongs in a curated, budgeted, human-verified artifact (`docs/loop-spec/bmad-scan-proposals.md` B6), not in a generated one.
- **Skills are code.** Don't restructure tested skill content without eval evidence.
- **Probes, not judgments.** A model judgment that SELECTS A CODE PATH must become a deterministic probe with a test. Prose criteria ("escalate if this looks security-relevant", "set `teamsAvailable` if teammates seem capable") make a consequential branch depend on how a model read a document that day: unreproducible, unauditable, and invisible when wrong. Each one that bit us became a script — `lib/security-signal.sh` (word-boundary terms, reports the matched term), `lib/teams-capability.sh` (version + flag gate), `lib/harness.sh entrypoint` (the harness's own stamp), `lib/execute-rung.sh` (width + capability, logs its reason). Judgment still belongs everywhere it is not selecting a branch. When you add a probe: emit the ANSWER and the REASON on one line, fail safe when the answer is unknown, and let an explicit operator override outrank it.
- **Spec-driven self-host.** All non-trivial changes go through the cycle skill.
- **As little code as possible: the ponytail ladder.** The best code is the code never written. Before writing, stop at the first rung that holds: YAGNI → **DRY** (already here? reuse it) → stdlib → native → installed dep → one line → the minimum that works. Rung 1 fails at the moment of writing — a wrapper always looks like decomposition while you produce it — so it is counted afterwards by `lib/indirection-scan.sh`, which names each small private helper a change added that is called exactly once (and stays silent on long single-caller functions, exported symbols, and dead code). Rung 2 is the one a fresh context cannot climb by trying harder — it cannot find a helper in a file it never opened — so it is measured, not recalled: `lib/duplication-scan.sh scan <files>` names each duplicated block and the file it already lives in, and `diff <base> [head]` reports only what a change introduced. It matches at two tiers — `duplicate=` (same lines) and `similar=` (same lines, every name changed), the second being the shape generated code actually takes and the one a verbatim matcher calls clean. Reuse means calling the existing thing or lifting the shared part into one place; a second copy that drifts is the failure. Duplication is one *reason to change* expressed twice — blocks that merely resemble each other stay apart, because merging those couples them. Canonical: `skills/shared/laziness-ladder.md`, enforced by `tests/ponytail-coverage.test.sh`.
- **Code for humans: house style over habit.** Code is read far more than it is written. Read the neighbors before writing a line and match them — naming, error idiom, test structure, layout; the house convention outranks your defaults, and disagreeing with it is a finding, never a licence to deviate mid-diff. Comments carry why, never what, and comment *density* is set by the file, not by an absolute — a good name deletes a comment. Measured, not recalled: `lib/house-style.sh probe <files>` reports the conventions and `lib/comment-tells.sh` flags comments that narrate the edit, narrate history, or restate the next line. Carve-outs that are never cut: `simplicity:` markers, file-header purpose blocks, TODO/FIXME/NOTE/HACK/SAFETY markers, spec-required contract docs. The other half of the same directive is the **failure path**, the half nobody rereads because it only runs when something is already wrong: when this code breaks at 03:00 the person on call has only what it said. Never swallow an error — a handler that catches and does nothing erases the one record of what happened; log it, re-raise it, or state why the failure is uninteresting (a narrow exception type states it for you, `except Exception: pass` states nothing). An error message names what broke and, where you know it, the next move; a non-zero exit says why before it goes. Measured, not recalled: `lib/failure-tells.sh scan|diff` flags a handler that does nothing, a silent non-zero exit, and a message whose every word is a synonym for "it broke" — and stays quiet where the code already says why (a narrow type, a comment in the handler, an exit guarded by a command that reports itself). It judges nothing else: whether an error should have been retried, whether a log line is at the right level, or whether the handling is correct at all stay judgments. Canonical: `skills/shared/human-code.md`, enforced by `tests/human-code-coverage.test.sh`.
- **Docs for humans: the markdown is a deliverable too.** Every cycle writes documents — SPEC, PLAN, VERIFICATION, the reviewer's guide, a PR body, and whatever README, guide, or runbook the change makes true or false — and a person maintains and operates all of it after the run ends. A document names its reader (someone about to CHANGE this system, or someone about to RUN it) and holds one job: a how-to gets a task done, a reference states facts, an explanation says why (Diátaxis); blending them serves neither reader. A procedure states its prerequisites, then the exact copy-pasteable command, then what success looks like, then what to do when the step fails. Cite, never copy: prose that restates code is the fastest thing in a repository to go stale, and stale documentation is worse than none because it is wrong with authority — the same evidence that removed graphify in 2.35. A change that makes a document false fixes it in the SAME diff; a follow-up documentation task is the deferred scope this repo already refuses. Measured, not recalled: `lib/doc-tells.sh scan|diff` names each relative link with no target, each inline-code path the tree no longer holds (fired only where git tracks files of that kind, so runtime state and foreign examples stay quiet), and each shell command holding a placeholder the prose never explains. What it does not decide — who the reader is, whether the modes are blended, whether a snippet earns its place — stays a judgment, and the contract says so per rule rather than claiming enforcement it lacks. Canonical: `skills/shared/human-docs.md`, enforced by `tests/human-docs-coverage.test.sh`.
- **Design for change: seams, not speculation.** Design to an interface, not an implementation; one unit, one reason to change; units receive their collaborators (params/args/env) instead of constructing them deep inside. Place boundaries where change is likely so the next tweak is a local diff — but never build speculation behind a seam (YAGNI cuts artifacts, never seams). Tests come first (TDD), simplicity beats cleverness, and a confirmed root cause gets a sibling sweep — same mechanism fixed in the same change, new mechanisms backlogged. Canonical: `skills/shared/design-for-change.md`, enforced by `tests/design-coverage.test.sh`.

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
