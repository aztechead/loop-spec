# loop-spec

Spec-driven development loops for [Claude Code](https://claude.com/claude-code), [opencode](https://opencode.ai), [OpenAI Codex](https://developers.openai.com/codex), and an experimental [Google ADK](https://google.github.io/adk-docs/) adapter — four peer harness contracts from one source tree.

Give the cycle a feature description, or a pre-authored spec file, and it runs seven phases: SPEC, DISCUSS, PLAN, EXECUTE, VERIFY, ITERATE, DELIVER. ITERATE judges the integrated result against your original request and rewinds until the goal is met or the iteration limit (10 by default, configurable with `LOOP_SPEC_ITERATE_MAX_ITERATIONS`) is spent. DELIVER then pushes the exact verified SHA, creates or reuses one PR, waits for required checks, and marks it ready for review. Phase state and evidence are durable in `feature.json` and committed artifacts, so interrupted runs resume instead of starting over.

Adjacent entry points on the same machinery:

- `/loop-spec:cycle new <description>` — greenfield bootstrap in an empty directory
- `/loop-spec:debug <error or symptom>` — bounded debug loop; red reproduction before any fix
- `/loop-spec:intake <anything>` — Slack / Jira / email / prompt → spec draft → cycle
- `autonomous` — question-free; recommended answers land in an auditable decision log
- `/loop-spec:sentinel` — watch work sources and drive the queue within script-enforced bounds

Design constraints:

- The base runtime is bash, jq, python3, and markdown. The optional ADK harness
  installs Google's Python package; no loop-spec daemon or database is required.
- Whether the loop may act without a human is decided by tested shell scripts, not skill prose.
- No stored code map. Structure is derived from the tree when a phase needs it and grounded by citing `file:line`.
- `lib/surface.sh find|show|covers` locates any bundled script, shared contract, or agent role — derived from the tree at call time, never a stored index.
- Generated code is written for the person who maintains and operates it: `lib/house-style.sh` and `lib/comment-tells.sh` measure how it reads, and `lib/failure-tells.sh` measures what it says when it breaks — no swallowed errors, no silent exits, no message a person cannot act on.
- The markdown is a deliverable too. A change that makes a document false fixes it in the same diff, and `lib/doc-tells.sh` flags the dead links, moved paths, and unrunnable commands a reader would trip over.
- Works with or without Claude Code agent teams, and on both team harness generations.

Current version: 4.5.0 (renamed from super-spec at v2.5.2). Direction: [docs/loop-spec/ROADMAP-3.0.md](docs/loop-spec/ROADMAP-3.0.md). Architecture: [docs/loop-spec/gdd.md](docs/loop-spec/gdd.md).

## Install

Base prerequisites for every harness: `bash >= 3.2`, `git`, `jq >= 1.5`, `python3 >= 3.7`. Google ADK additionally requires Python >=3.10. Prompt-to-PR delivery also needs an authenticated GitHub CLI (`gh auth status`) and an `origin` remote. Details: [docs/loop-spec/PREREQUISITES.md](docs/loop-spec/PREREQUISITES.md).

### Claude Code

```bash
claude plugin marketplace add https://github.com/aztechead/loop-spec.git
claude plugin install loop-spec@loop-spec-marketplace
```

Optional: `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` enables agent teams. Without it, critique/verify use one-shot subagents and EXECUTE uses the loop-fleet rung (needs `claude` on PATH). Every role inherits the model that launched the session; model-specific routing is optional (`skills/shared/model-matrix.md`).

Adoption walkthrough: [docs/adopting.md](docs/adopting.md).

Differences: [`skills/shared/claude-harness.md`](skills/shared/claude-harness.md). The Claude Agent SDK (Python and TypeScript) is the SAME harness — it loads plugins and skills natively — so nothing extra is needed to embed loop-spec in an SDK app.

### opencode

```bash
git clone https://github.com/aztechead/loop-spec
bash loop-spec/lib/opencode-install.sh install            # ~/.config/opencode
bash loop-spec/lib/opencode-install.sh install --project . # or ./.opencode
```

Generates namespaced skills/commands/agents and installs `extensions/opencode/loop-spec.ts`. Preferred headless entry: `opencode run --format json "Load the loop-spec-auto skill and run: <description>"`. Differences: [`skills/shared/opencode-harness.md`](skills/shared/opencode-harness.md).

### Codex

```bash
git clone https://github.com/aztechead/loop-spec
bash loop-spec/lib/codex-install.sh install            # ~/.codex + ~/.agents/skills
bash loop-spec/lib/codex-install.sh install --project . # or ./.codex + ./.agents/skills
```

Alternatively, from a clone that already contains `.codex-plugin/plugin.json` and
`.agents/plugins/marketplace.json`:

```bash
codex plugin marketplace add https://github.com/aztechead/loop-spec.git
codex plugin add loop-spec
```

The installer generates namespaced `$loop-spec-<name>` skill adapters, custom
agent TOML for `spawn_agent`, a marked `shell_environment_policy.set` block
so Bash subprocesses receive `LOOP_SPEC_HARNESS=codex` without waiting on plugin
hook trust, and `[features] default_mode_request_user_input = true` so Default
mode's `request_user_input` tool can block SPEC/DISCUSS/PLAN interviews the
way Claude Code's `AskUserQuestion` and OpenCode's `question` do. Start a new
Codex session after installing so custom agents are loaded. Interactive entry:
`$loop-spec-cycle <description>`. Preferred headless entry:
`LOOP_SPEC_HARNESS=codex LOOP_SPEC_NON_INTERACTIVE=1 codex exec --json --sandbox workspace-write '$loop-spec-auto <description>'`.
Plugin-bundled hooks stay skipped until `/hooks` trusts them. Differences:
[`skills/shared/codex-harness.md`](skills/shared/codex-harness.md).

### Google ADK

```bash
python3 -m pip install 'google-adk>=2.7,<3'
git clone https://github.com/aztechead/loop-spec
bash loop-spec/lib/adk-install.sh install --project .    # writes ./adk_agents/
export LOOP_SPEC_ADK_AGENT_DIR="$PWD/adk_agents/loop_spec"
```

Mounts two agents — a working agent and a read-only judge — over
`extensions/adk/loop_spec_adk/` (skills, a real shell starting in your project, and
`dispatch_subagent` over ADK's `AgentTool`). Preferred headless entry:
`LOOP_SPEC_NON_INTERACTIVE=1 adk run "$LOOP_SPEC_ADK_AGENT_DIR" "Load the loop-spec auto skill and run: <description>" --jsonl`.
The shell inherits the ADK process user's host permissions; use an isolated
container or restricted service account for untrusted repositories. ADK
sessions share the mounted working tree even though their bridge state is
isolated, so do not expose the working agent to untrusted or multi-tenant
`adk web` / `adk api_server` clients.
Or mount it yourself: `from loop_spec_adk import build_app`. Differences:
[`skills/shared/adk-harness.md`](skills/shared/adk-harness.md).

## Quick start

```
/loop-spec:cycle add a --json flag to the export command
```

1. Startup probes cache to `.loop-spec/runtime.json`. The first run also builds a 5-domain codebase map under `docs/loop-spec/codebase/`.
2. Claude Code creates a feature worktree at `.claude/worktrees/{slug}` on `feat/{slug}`. OpenCode, Codex, and ADK create the branch in place on a clean checkout — none of them has a session-root switch, so `executionRootMode` records the difference rather than faking it.
3. SPEC interviews you (up to 6 rounds) until the ambiguity gate passes, then writes `docs/loop-spec/features/{slug}/SPEC.md`.
4. DISCUSS critiques the spec. PLAN writes `PATTERNS.md` + `PLAN.md` (task DAG with verify commands).
5. EXECUTE implements tasks in parallel where the DAG allows, one commit per task.
6. VERIFY runs marker/tamper scans, acceptance criteria, and a blocking code review.
7. ITERATE judges the result against your original request and rewinds on gaps.
8. DELIVER pushes the verified SHA, reconciles one PR, waits for required checks, and marks it ready.

VERIFY also writes `REVIEW-ORDER.md` (ordered `path:line` stops for the reviewer); DELIVER inlines it in the PR body. `/loop-spec:walkthrough --walk` presents the same trail conversationally.

Variations: `style:step` pauses after every phase; pass a spec file path to skip the interview; re-invoke `/loop-spec:cycle` to resume from durable state.

On Claude Code, installing the plugin binds the `loop-spec` output style (`output-styles/loop-spec.md`): name the phase when it changes, one thought per action, then one outcome-first close. Built-in Concise does not do that. OpenCode, Codex, and ADK have no output-style slot; they follow [`skills/shared/report-style.md`](skills/shared/report-style.md).

## Skills

Invoked as `/loop-spec:<name>` (or `Skill(loop-spec:<name>)`). Per-phase skills can run alone; `cycle` chains them.

| Skill | Purpose |
|---|---|
| `auto` | Preferred headless/SDK entry. Routes to micro, debug, or full cycle fail-closed. |
| `cycle` | Seven-phase prompt-to-ready-PR loop. Also: `new`, `backlog`, spec-file ingest, resume. |
| `intake` | Any input → spec draft → cycle. `--no-run` stops after the draft. |
| `debug` | Bounded debug: triage, red reproduction, fix, verify. Writes `BUG.md`. |
| `loop-debug` | One-shot debug with autonomous mode forced on. |
| `assess` | Read-only fragility/health assessment → `docs/loop-spec/assessment/ASSESSMENT.md`. |
| `quality-loop` | Iterative pre-commit review until convergence. |
| `revise` | Ingest PR review feedback, fix on the branch, answer or backlog the rest. |
| `retro` | Mine telemetry for rule candidates and parameter tuning. |
| `status` | Read-only dashboard: features, stats, metrics, trust, needs-human. |
| `sentinel` | Watch work sources (`scan`); drive the queue (`run`). |
| `watch` | Post-merge check: default branch green? feature files patched? |
| `walkthrough` | Reviewer's guide: ordered `path:line` stops; writes/lints `REVIEW-ORDER.md`. |
| `micro` | Lightweight ad-hoc protocol (on by default as a session mode). |
| `loop-runner` | Bundled loop engine, standalone. |
| `grill` / `simplicity` / `human-code` / `discipline` / `rules` | Session-mode toggles. |
| `onboard` | Guided one-time setup for optional modes. |
| `pause` / `rollback` / `forensics` | Cycle lifecycle utilities. |

## The cycle

| Phase | Produces | Gates |
|---|---|---|
| SPEC | `SPEC.md` with `ambiguity_scores` | Interview (max 6); ambiguity ≤ 0.20 |
| DISCUSS | revised SPEC.md | Spec critique (debate on escalation) |
| PLAN | `PATTERNS.md` + `PLAN.md` | Critique + feasibility + criteria coverage |
| EXECUTE | per-task commits on `feat/{slug}` | Spec-compliance review; dispatch by DAG width |
| VERIFY | `VERIFICATION.md`, `REVIEW-ORDER.md` | Marker/tamper scans, acceptance, blocking review |
| ITERATE | `ITERATION.md` | Goal re-judge; rewind or advance |
| DELIVER | `delivery.targets[]`, final PR | Exact-SHA push, one-PR reconcile, required checks |

Mechanics in brief:

- **ITERATE** is the outer loop: VERIFY proves the checklist; ITERATE asks whether the original request is met. Gap classes `execute` / `plan` / `spec` rewind to that phase.
- **Critique** climbs skip → single critic → advocate/challenger debate (security signal, disputed major, or deadlock).
- **EXECUTE** picks dispatch from DAG width and probed capability (`lib/execute-rung.sh`): sequential, batched subagents, agent team, optional Workflow, or loop-fleet.
- **VERIFY** defends the oracle (test-tamper + marker scans). An advisory verification-gap pass records coverage holes without blocking.
- **Sequencing is a declared graph** from 3.0 (`graph/cycle.graph.json`, run by `lib/graph/run.sh`): typed `reads[]`/`writes[]` over `feature.json`, per-node checkpoints, probe-conditioned `route` edges, and dual-process effort (`lib/effort-probe.sh`). Phase *content* is unchanged. Upgrading from 2.x needs no action: schema stays v7 and every new variable defaults to 2.x behaviour.
- **DELIVER** owns the final mile (`lib/pr-delivery.sh`): never force-pushes, merges, or enables auto-merge.

Styles (`style:step`, default `auto`): `auto` · `step` · `interactive` · `review-only`. Every role inherits the session model. Optional Claude routes use `LOOP_SPEC_PHASE_MODEL_<PHASE>` or `LOOP_SPEC_MODEL_<ROLE>`; OpenCode routes use native generated-agent configuration.

Greenfield: `/loop-spec:cycle new autonomous a CLI tool that ...` in an empty directory. Backlog drain: `/loop-spec:cycle backlog`. Diagrams, artifact tree, and team lifecycle: [docs/loop-spec/architecture.md](docs/loop-spec/architecture.md).

## Headless and autonomous use

```bash
claude -p "/loop-spec:auto update CLAUDE.md with relevant changes"
# Force the full seven-phase cycle:
claude -p "/loop-spec:cycle autonomous add rate limiting to the public API"
```

`/loop-spec:auto` inspects likely files/tests, proposes a route, and `lib/task-route.sh` validates it fail-closed. Small maintenance → micro; bounded bugs → debug; everything else → full cycle (maintenance-shaped work that outgrew micro takes the full cycle's maintenance profile, not a `protocol-mismatch` decline). SDK callers get one `AUTONOMOUS_ROUTE {...}` line; route selection writes nothing into the target repo. Full contract: [`skills/shared/autonomous-mode.md`](skills/shared/autonomous-mode.md).

Ephemeral containers: [Cloud Run autonomous profile](docs/loop-spec/cloud-run-autonomous.md).

Non-interactive (CI) pre-pins answers instead of letting the model choose:

```bash
export LOOP_SPEC_NON_INTERACTIVE=1
export LOOP_SPEC_ANSWER_STYLE=auto
export LOOP_SPEC_ANSWER_TITLE="add subtract function"
```

Machine-readable results (`LOOP_SPEC_RESULT {...}`, `.loop-spec/last-result.json`, phase markers): [docs/loop-spec/agent-output-contract.md](docs/loop-spec/agent-output-contract.md).

Issue-to-PR: `bash <plugin>/lib/issue-intake.sh run --label loop-spec --limit 1` (example Action: [`docs/examples/issue-to-pr.yml`](docs/examples/issue-to-pr.yml)).

Unattended sentinel / watch / trust: [docs/loop-spec/sentinel.md](docs/loop-spec/sentinel.md). Trust levels L0–L3 are computed from committed metrics by `lib/trust.sh`; auto-merge is denied at every level in this release.

## Configuration

Everything is optional; empty projects get working defaults. Env vars (per session) and files under `.loop-spec/` (per project).

**Canonical contract** — precedence, every supported variable, skill args, loop-runner flags, and names that are *not* controls: [`docs/loop-spec/configuration.md`](docs/loop-spec/configuration.md).

Common knobs:

| Variable | Default | Effect |
|---|---|---|
| `LOOP_SPEC_AUTONOMOUS` | unset | `1` ≡ inline `autonomous` token |
| `LOOP_SPEC_WORKTREES` | `1` | `0` = in-place branch, serial EXECUTE |
| `LOOP_SPEC_PHASE_HANDOFF` | unset | `1` = one durable phase per invocation |
| `LOOP_SPEC_MAX_FEATURES` | `1` | Backlog / sentinel batch size (L1+ for sentinel) |
| `LOOP_SPEC_CHECKPOINT_PR` | on | `0` disables draft checkpoint PRs |
| `LOOP_SPEC_CMD_TEST` (and `LOOP_SPEC_CMD_*`) | detected | Pin test/lint/typecheck/prepare commands |
| `LOOP_SPEC_HARNESS` | detected | Force `claude`, `opencode`, `adk`, or `codex` |
| `LOOP_SPEC_ADK_AGENT_DIR` | unset | Mounted ADK agent directory (written by `lib/adk-install.sh`) |
| `CODEX_HOME` | `~/.codex` | Codex config tree used by `lib/codex-install.sh` when `--project` is omitted |

Config files under `.loop-spec/`: `workflow.json`, `workspace.json`, `sentinel.conf`, `trust.conf`, `tuning.json`, session-mode `*.conf`, `extensions.json`, `RULES.md`. Extensions add review layers and phase instructions; they never disable built-in gates.

Multi-repo workspaces: [docs/adopting.md](docs/adopting.md#workspace-multi-repo-adoption).

## Troubleshooting

- Health check fails: allow every alias from `bash lib/feature-init.sh all-models` in `CLAUDE.md`.
- Critique gate keeps bouncing: the spec/plan is ambiguous — use `style:step`, edit, resume.
- Loop-fleet halt: read `halt_reason` in `.loop/fleet-result.json` (table in `skills/shared/execute-loop-fleet.md`).
- Teams unavailable: not a failure; set `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` to restore persistent teams.

More: [docs/adopting.md](docs/adopting.md). Architecture: [docs/loop-spec/architecture.md](docs/loop-spec/architecture.md). Historical design doc: [docs/design.md](docs/design.md).

## Docs map

| Doc | What it covers |
|---|---|
| [docs/adopting.md](docs/adopting.md) | First cycle, pitfalls, multi-repo workspaces |
| [docs/loop-spec/PREREQUISITES.md](docs/loop-spec/PREREQUISITES.md) | Runtime + agent-teams setup |
| [docs/loop-spec/configuration.md](docs/loop-spec/configuration.md) | Exhaustive configuration contract |
| [docs/loop-spec/architecture.md](docs/loop-spec/architecture.md) | Diagrams, artifact tree, design notes, limitations |
| [docs/loop-spec/agent-output-contract.md](docs/loop-spec/agent-output-contract.md) | `LOOP_SPEC_RESULT` / result.json schema |
| [docs/loop-spec/sentinel.md](docs/loop-spec/sentinel.md) | Unattended scan/run/watch recipes |
| [docs/loop-spec/cloud-run-autonomous.md](docs/loop-spec/cloud-run-autonomous.md) | Ephemeral-container profile |
| [docs/loop-spec/ROADMAP-3.0.md](docs/loop-spec/ROADMAP-3.0.md) | Direction |

## Tests

```bash
bash tests/run-unit.sh         # fast edit loop; tests coupled to uncommitted changes
bash tests/run-unit.sh main    # tests coupled to the whole branch diff
bash tests/run-all.sh          # full offline gate, parallel by default
```

`RUN_ALL_JOBS` controls concurrency and `RUN_ALL_VERBOSE=1` restores every successful
suite's detailed log. The fast gate uses the coverage index plus same-name unit suites to
select the checks coupled to the changed files. Every suite is offline — no network, no
live model calls; end-to-end coverage is the manual matrix in
[`tests/README.md`](tests/README.md).

## License

MIT.
