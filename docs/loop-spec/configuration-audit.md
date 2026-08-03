# Configuration utilization audit — 2.29.1

Date: 2026-07-30

This audit verifies the configuration contract in
[`configuration.md`](configuration.md) against the shipped plugin, rather than
treating documentation presence as proof of behavior.

## Scope and evidence standard

The audited surface contains:

- 104 explicitly named or family-form `LOOP_SPEC_*` operator inputs;
- host, credential, installer, and Cloud Agent SDK recipe environment inputs;
- 35 GNU-style flags across `loop.py`, `supervisor.py`, and `compile_spec.py`;
- 19 skills with public argument contracts, plus cycle inline tokens.

An environment input passes only when it has both:

1. a shipped consumer under `agents/`, `commands/`, `extensions/`, `hooks/`, `lib/`,
   or `skills/`; and
2. documentation of accepted values, default/precedence, and effect.

Shell/Python consumers are exercised behaviorally. Skill-owned controls are part of
the plugin’s executable instruction surface, so their evidence is an exact command
snippet/branch in the owning SKILL plus contract coverage. Host-owned variables are
classified separately and are never presented as plugin controls.

A CLI flag passes only when it is declared by the parser or skill frontmatter,
documented, and mapped to a runtime configuration field or explicit branch.

## Findings corrected by the audit

| Finding | Prior behavior | 2.29.1 resolution |
|---|---|---|
| Command override family was partly aspirational | `LOOP_SPEC_CMD_LINT` and `LOOP_SPEC_CMD_TYPECHECK` were documented but lacked a concrete resolver. | `lib/project-commands.sh` now applies prepare/test/lint/typecheck overrides identically in single-repo, workspace, interactive, and autonomous modes. Presence wins, including explicit empty disablement. |
| Worktree flag validation differed by consumer | Cycle rejected invalid values, but execute-rung, loop supervisor, the helper, and hook could treat them as enabled. | Every worktree boundary now accepts only `0` or `1` and fails closed otherwise. |
| Phase handoff could be bypassed by direct phase chaining | Phase skills invoked successors themselves, bypassing cycle’s boundary policy. | Phase skills return to cycle; the PreToolUse guard writes the paused result and rejects a second phase invocation. |
| Deferral protection could be bypassed by rewording | Removing a real deferred-scope declaration after a Stop denial could pass without implementing the omitted scope. | The structured guard persists an obligation tied to transcript position and repository state, then requires post-denial work, later verification, and a `Resolved scope:` evidence line. It does not infer dropped scope from an isolated reserved word. |
| Numeric CLI bounds were undocumented in code | Negative/zero limits could parse even where the docs required positive values. | Loop and supervisor reject out-of-contract bounds for flags and JSON config before execution. |
| Agent pass-through arguments were implicit | `loop.py` accepted unknown arguments, while a conventional `--` separator was forwarded incorrectly. | `-- <agent args>` is documented, the separator is stripped, and parser-level coverage proves the forwarded list. |
| Timeout zero semantics were misstated | The reference called watchdog values positive even though runtime treats `0` as disabled. | The contract now says non-negative and identifies exactly which deadline `0` disables; PR-check zero behavior is separately documented. |
| Headless SPEC answers had no `no` branch | The variables offered `yes/no`, but the skill simultaneously said it always wrote SPEC.md. | Invalid values fail fast; explicit `no` returns a durable, reason-coded pause without advancing SPEC. |
| Bounded skill controls lacked validation | Assess top-N, quality-loop rounds, phase timeout, checkpoint boolean, Ralph threshold, and max-feature zero could be misread or fail inside arithmetic. | Owning skills/helpers now validate before dispatch; max-feature zero falls back to the documented default of one. |
| Host and recipe environment was incomplete | OpenCode, credentials, and Cloud Agent SDK wrapper controls were scattered across examples. | All are classified in the canonical reference, with wrapper-owned variables explicitly separated from plugin-owned controls. |
| Phase model intent could not be expressed | Role routes existed, but one phase could not select a common model for its author, implementers, and gates; SDK examples reused one static main model. | `LOOP_SPEC_PHASE_MODEL_<PHASE>` is validated by executable code, activated before every phase Agent launch, persisted for handoff, included in the health-check alias set, and consumed per query by the Claude CLI/Python Agent SDK recipes. |

## Automated proof

`tests/configuration-coverage.test.sh` enforces both directions:

- every shipped `LOOP_SPEC_*` name is documented or classified internal;
- every documented `LOOP_SPEC_*` input has a shipped consumer;
- every host/installer/recipe input is classified;
- every argparse/skill flag is documented;
- every skill with public arguments has a command row;
- precedence, worktree opt-out, phase modes, and internal-variable boundaries remain
  present.

Behavioral evidence includes:

- `tests/lib/project-commands.test.sh` — all four command overrides, detection
  fallback, and explicit-empty disablement;
- `hooks/team/no-worktrees-guard.test.sh`, `tests/lib/git-ops.test.sh`,
  `tests/lib/execute-rung.test.sh`, and loop-runner supervisor tests — worktree
  enforcement and invalid-value rejection at every boundary;
- `hooks/team/phase-handoff-guard.test.sh` — environment and persisted-policy
  precedence plus deterministic paused results;
- `hooks/team/deferral-guard.test.sh` — wording-only retry rejection and
  work/verification evidence;
- `skills/loop-runner/tests/config_flags.py` and `run_tests.sh` — every `loop.py`
  option mapping, JSON/CLI precedence, pass-through args, numeric bounds, and
  supervisor execution;
- `tests/model-overrides.test.sh`, `tests/lib/feature-init.test.sh`, and
  `tests/lib/harness-call-shapes.test.sh` — phase/role precedence, durable phase
  activation, SDK/CLI resolver output, gate inheritance, dynamic health-check
  aliases, and explicit `model:` on every Agent launch template;
- the repository-wide `tests/run-all.sh` suite — integration coverage across plugin
  manifests, all harness adapters, hooks, libraries, phases, delivery, and workflows.

## Result

No documented plugin input remains without a shipped consumer. Proposed names found
only in historical feature artifacts are explicitly labeled as having no effect.
Internal transport/test variables are published but are not represented as supported
operator controls.
